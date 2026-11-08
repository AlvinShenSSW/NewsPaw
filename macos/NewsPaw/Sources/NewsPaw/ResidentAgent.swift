import Darwin
import Foundation
import ServiceManagement
import SwiftUI

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

struct ResidentAgent {
    static let plist = "io.newspaw.resident.plist"
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
        if waitForWorker {
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
        try await SMAppService.agent(plistName: Self.plist).unregister()
    }

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

private enum ResidentCopy {
    case heading, off, approval, on, unavailable, enable, disable, systemSettings, legacy, failed

    func text(_ language: AppLanguage) -> String {
        let words: (String, String, String) = switch self {
        case .heading: ("登录项", "Login item", "ログイン項目")
        case .off: ("未注册", "Unregistered", "未登録")
        case .approval: ("需要在系统设置中批准", "Approval required in System Settings", "システム設定で承認が必要です")
        case .on: ("已注册", "Registered", "登録済み")
        case .unavailable: ("登录项状态不可用", "Login item unavailable", "ログイン項目を確認できません")
        case .enable: ("注册登录项", "Register login item", "ログイン項目を登録")
        case .disable: ("停止并取消注册", "Stop and unregister", "停止して登録を解除")
        case .systemSettings: ("打开登录项设置", "Open Login Items settings", "ログイン項目設定を開く")
        case .legacy: ("现有的旧版后台仍在运行。请先从原安装停止。", "The previous background service is still loaded. Stop it from its original installation first.", "以前のバックグラウンドサービスが稼働しています。以前のインストールから停止してください。")
        case .failed: ("登录项操作未完成。请检查后台与数据状态。", "The login item action did not complete. Check the backend and data state.", "ログイン項目の操作が完了しませんでした。バックエンドとデータ状態を確認してください。")
        }
        return switch language {
        case .zhHans: words.0
        case .en: words.1
        case .ja: words.2
        }
    }
}

struct ResidentControls: View {
    let model: AppModel
    private let agent = ResidentAgent()
    @State private var current: ResidentState = .notPackaged
    @State private var busy = false
    @State private var failure: ResidentCopy?

    private func label(_ key: ResidentCopy) -> String { key.text(model.uiLanguage) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if current != .notPackaged {
                Text(label(.heading)).font(.headline).accessibilityAddTraits(.isHeader)
                Text(label(statusCopy)).foregroundStyle(.secondary)
                if let failure { Text(label(failure)).foregroundStyle(.secondary) }
                HStack {
                    if current == .off {
                        Button(label(.enable)) { Task { await change(enable: true) } }
                    }
                    if current == .approval || current == .on {
                        Button(label(.disable)) { Task { await change(enable: false) } }
                    }
                    Button(label(.systemSettings)) { SMAppService.openSystemSettingsLoginItems() }
                }
            }
        }
        .disabled(busy)
        .task {
            while !Task.isCancelled {
                if !busy { current = agent.state }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var statusCopy: ResidentCopy {
        switch current {
        case .off: .off
        case .approval: .approval
        case .on: .on
        case .notPackaged, .unavailable: .unavailable
        }
    }

    private func change(enable: Bool) async {
        guard !busy else { return }
        busy = true
        failure = nil
        defer {
            current = agent.state
            busy = false
        }
        do {
            if enable {
                try await agent.enable()
            } else {
                let running = model.connection == .connected || model.connection == .stopping
                if model.connection == .connected {
                    await model.stopBackend()
                    guard model.connection == .stopping else { throw ResidentFailure.workerStillRunning }
                }
                try await agent.disable(waitForWorker: running)
            }
            await model.refresh()
        } catch ResidentFailure.legacyServiceActive {
            failure = .legacy
        } catch {
            failure = .failed
        }
    }
}
