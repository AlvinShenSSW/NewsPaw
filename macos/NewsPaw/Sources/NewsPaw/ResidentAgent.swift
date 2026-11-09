import Darwin
import Foundation
import ServiceManagement
import Observation

enum ResidentState {
    case notPackaged, off, approval, on, unavailable

    static func status(_ value: SMAppService.Status) -> Self {
        switch value {
        case .notRegistered: .off
        case .requiresApproval: .approval
        case .enabled: .on
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }
}

enum ResidentFailure: Error {
    case legacyServiceActive
    case serviceUnavailable
    case workerStillRunning
}

/// The login item that runs the backend. The app only uses these; the registration mechanism
/// itself (SMAppService + the bundled plist) is unchanged (R12 non-goal).
@MainActor
protocol ResidentService {
    var state: ResidentState { get }
    /// Registers the login item (launchd starts it at once: `RunAtLoad`).
    func enable() async throws
    /// Unregisters it, which also stops it; first waits for the worker to exit when asked.
    func disable(waitForWorker: Bool) async throws
    /// Waits until the backend process has exited after `service.stop`.
    func waitUntilStopped() async throws
    /// Starts the registered job again (it does not restart by itself after a clean stop).
    func start() async throws
    func openLoginItemsSettings()
}

struct ResidentAgent {
    static let plist = "io.newspaw.resident.plist"
    /// The `Label` in `packaging/io.newspaw.resident.plist`.
    static let label = "io.newspaw.resident"
    let bundle: Bundle

    init(bundle: Bundle = .main) { self.bundle = bundle }

    private var helper: URL {
        bundle.bundleURL.appendingPathComponent("Contents/Helpers/NewsPawResident")
    }

    var state: ResidentState {
        let agentPlist = bundle.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/" + Self.plist)
        guard FileManager.default.fileExists(atPath: agentPlist.path),
              FileManager.default.isExecutableFile(atPath: helper.path) else { return .notPackaged }
        return .status(SMAppService.agent(plistName: Self.plist).status)
    }

    func enable() async throws {
        guard state == .off else { throw ResidentFailure.serviceUnavailable }
        let helperPath = helper.path
        try await Task.detached(priority: .utility) {
            let loaded = try Self.run(
                "/bin/launchctl", ["print", "gui/\(getuid())/io.newspaw.agent"], timeout: 4
            )
            if loaded == 0 { throw ResidentFailure.legacyServiceActive }
            guard loaded == 3 || loaded == 113 else { throw ResidentFailure.serviceUnavailable }
            guard try Self.run(helperPath, ["--check-upgrade"], timeout: 18) == 0 else {
                throw ResidentFailure.serviceUnavailable
            }
        }.value
        guard state == .off else { throw ResidentFailure.serviceUnavailable }
        try SMAppService.agent(plistName: Self.plist).register()
    }

    func disable(waitForWorker: Bool) async throws {
        guard state == .on || state == .approval else { throw ResidentFailure.serviceUnavailable }
        if waitForWorker { try await waitUntilStopped() }
        try await SMAppService.agent(plistName: Self.plist).unregister()
    }

    func waitUntilStopped() async throws {
        let helperPath = helper.path
        try await Task.detached(priority: .utility) {
            let deadline = DispatchTime.now().uptimeNanoseconds + 6_000_000_000
            while DispatchTime.now().uptimeNanoseconds < deadline {
                if try Self.run(helperPath, ["--check-stopped"], timeout: 2) == 0 { return }
                try await Task.sleep(for: .milliseconds(120))
            }
            throw ResidentFailure.workerStillRunning
        }.value
    }

    func start() async throws {
        guard state == .on else { throw ResidentFailure.serviceUnavailable }
        let target = "gui/\(getuid())/" + Self.label
        try await Task.detached(priority: .utility) {
            guard try Self.run("/bin/launchctl", ["kickstart", target], timeout: 6) == 0 else {
                throw ResidentFailure.serviceUnavailable
            }
        }.value
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    private static func run(_ executable: String, _ arguments: [String], timeout: Double) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        while process.isRunning && DispatchTime.now().uptimeNanoseconds < deadline {
            Thread.sleep(forTimeInterval: 0.025)
        }
        if process.isRunning {
            process.terminate()
            throw ResidentFailure.serviceUnavailable
        }
        return process.terminationStatus
    }
}

extension ResidentAgent: ResidentService {}

/// What the login item row says when it is not simply on or off, or when a change failed.
enum LoginNote: CaseIterable, Equatable {
    case approval, unavailable, notPackaged, legacy, refused, startFailed, stillRunning

    var message: Words {
        switch self {
        case .approval: L10n.Settings.noteApproval
        case .unavailable: L10n.Settings.noteUnavailable
        case .notPackaged: L10n.Settings.noteNotPackaged
        case .legacy: L10n.Settings.noteLegacy
        case .refused: L10n.Settings.noteRefused
        case .startFailed: L10n.Settings.noteStartFailed
        case .stillRunning: L10n.Settings.noteStillRunning
        }
    }

    /// Whether System Settings › Login Items is the way out (interaction-spec §8.2).
    var offersSettings: Bool { self != .notPackaged && self != .stillRunning }
}

/// The login item switch, starting a stopped backend and restarting a running one
/// (interaction-spec §8.2, §4.6). The switch shows only what SMAppService reports.
@MainActor @Observable
final class BackendControl {
    private(set) var state: ResidentState
    private(set) var busy = false
    private(set) var failure: LoginNote?
    @ObservationIgnored private let service: any ResidentService
    @ObservationIgnored private var launched = false
    /// How long to wait for a started backend to answer (attempts × interval, about 10 s).
    @ObservationIgnored var settleInterval: Duration = .milliseconds(500)
    @ObservationIgnored var settleAttempts = 20

    init(service: any ResidentService = ResidentAgent()) {
        self.service = service
        state = service.state
    }

    var loginOn: Bool { state == .on }
    /// Only a plainly registered or unregistered item can be switched here.
    var canToggle: Bool { state == .on || state == .off }
    /// launchd can only start a job that is registered and allowed.
    var canRestart: Bool { state == .on }
    var note: LoginNote? { failure ?? stateNote }

    private var stateNote: LoginNote? {
        switch state {
        case .approval: .approval
        case .unavailable: .unavailable
        case .notPackaged: .notPackaged
        case .on, .off: nil
        }
    }

    func reload() {
        guard !busy else { return }
        state = service.state
    }

    func openSettings() { service.openLoginItemsSettings() }

    /// Turning it on registers (and so starts) the backend; turning it off stops the backend
    /// safely first, because unregistering a launch agent stops it.
    func setLoginItem(_ on: Bool, model: AppModel) async {
        reload()
        guard !busy, on ? state == .off : state == .on else { return }
        busy = true
        failure = nil
        defer {
            busy = false
            reload()
        }
        if on {
            do {
                try await service.enable()
            } catch ResidentFailure.legacyServiceActive {
                failure = .legacy
                return
            } catch {
                failure = .refused
                return
            }
            if service.state == .approval { return }
            await settle(model)
            if model.connection != .connected { failure = .startFailed }
            return
        }
        let running = model.connection == .connected || model.connection == .stopping
        if model.connection == .connected {
            await model.stopBackend()
            // A refused stop is shown by the shell with its own code.
            guard model.connection == .stopping else { return }
        }
        do {
            try await service.disable(waitForWorker: running)
        } catch ResidentFailure.workerStillRunning {
            failure = .stillRunning
        } catch {
            failure = .refused
        }
        await model.refresh()
    }

    /// Starts a backend that is not running: launchd starts the registered job, or the job is
    /// registered (which starts it).
    func start(model: AppModel) async {
        reload()
        guard !busy, model.connection != .connected else { return }
        let registered: Bool
        switch state {
        case .on: registered = true
        case .off: registered = false
        case .approval, .unavailable, .notPackaged: return
        }
        busy = true
        failure = nil
        defer {
            busy = false
            reload()
        }
        do {
            if registered { try await service.start() } else { try await service.enable() }
        } catch ResidentFailure.legacyServiceActive {
            failure = .legacy
            return
        } catch {
            failure = registered ? .startFailed : .refused
            return
        }
        // Registered but not allowed yet: the approval note says what to do.
        if service.state == .approval { return }
        await settle(model)
        if model.connection != .connected { failure = .startFailed }
    }

    /// Stop, wait for the process to exit, start it again.
    func restart(model: AppModel) async {
        reload()
        guard !busy, canRestart, model.connection == .connected else { return }
        busy = true
        failure = nil
        defer {
            busy = false
            reload()
        }
        await model.stopBackend()
        guard model.connection == .stopping else { return }
        do {
            try await service.waitUntilStopped()
            try await service.start()
        } catch ResidentFailure.workerStillRunning {
            failure = .stillRunning
            return
        } catch {
            failure = .startFailed
            return
        }
        await settle(model)
        if model.connection != .connected { failure = .startFailed }
    }

    /// Once per launch: a backend that starts at login but is not running (it was stopped from
    /// Settings) starts again when NewsPaw opens, as the stop confirmation says.
    func startIfStopped(model: AppModel) async {
        guard !launched else { return }
        launched = true
        // The first poll may still be on its way.
        var attempts = 0
        while model.connection == .connecting, attempts < settleAttempts {
            await model.refresh()
            attempts += 1
            if model.connection == .connecting { try? await Task.sleep(for: settleInterval) }
        }
        reload()
        guard model.connection == .offline, state == .on else { return }
        await start(model: model)
    }

    private func settle(_ model: AppModel) async {
        for attempt in 0..<settleAttempts {
            await model.refresh()
            if model.connection == .connected { return }
            if attempt + 1 < settleAttempts { try? await Task.sleep(for: settleInterval) }
        }
    }
}
