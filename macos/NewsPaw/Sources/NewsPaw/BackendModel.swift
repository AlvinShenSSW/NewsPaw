import CoreFoundation
import Foundation
import Observation

enum BackendFailure: Error, Equatable {
    case incompatible
    case invalidReply
    case conflict
    case freshInstanceRequired
    case rejected
}

enum LocaleField: String {
    case ui = "ui_locale"
    case news = "news_output_locale"
}

enum BackendRPC {
    static func decode<Value: Decodable>(_ data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Value.self, from: data)
    }
}

struct ServiceStatus: Decodable {
    let protocolVersion: Int
    let state: String
    let operations: [String]?
}

struct ConfigSnapshot: Decodable {
    let revision: Int
    let document: AppConfig
}

struct AppConfig: Decodable {
    let uiLocale: AppLanguage
    let newsOutputLocale: AppLanguage
    let timezone: String?
    let categories: [Category]
    let subscriptions: [Subscription]
    let sources: [Source]
    let accounts: [Account]
    let modelProfiles: [Profile]
    let bots: [ConfiguredBot]?
    let groupStyles: [String: String]?

    struct ConfiguredBot: Decodable { let id: String; let adultAllowed: Bool }

    func displaySubscription(for categoryId: String) -> Subscription? {
        let matching = subscriptions.filter { $0.categoryId == categoryId }
        return matching.first(where: \.enabled) ?? matching.first
    }

    struct Category: Decodable, Identifiable {
        let id, name, partition: String
        let primaryProfileId, backupProfileId: String?

        init(id: String, name: String, partition: String, primaryProfileId: String? = nil, backupProfileId: String? = nil) {
            self.id = id
            self.name = name
            self.partition = partition
            self.primaryProfileId = primaryProfileId
            self.backupProfileId = backupProfileId
        }
    }

    struct Subscription: Decodable, Identifiable {
        let id, categoryId, timezone: String
        let enabled: Bool
        let times: [String]
        let name, sourceMode, style: String?
        let sourceIds, botIds: [String]?
        let primaryProfileId, backupProfileId: String?
        let maxItems: Int?
        let focusWeights: [String: Int]?
    }

    struct Source: Decodable, Identifiable {
        let id, name, kind: String
        let enabled: Bool
        let url, partition, focus: String?
        let categoryIds: [String]?
    }

    struct Account: Decodable, Identifiable {
        let id, handle, priority: String
        let partition, subscriptionId: String?
    }

    struct Profile: Decodable, Identifiable {
        let id, partition, role, provider, model: String
        let baseUrl: String?
        let capabilities: [String]
    }
}

struct BotStatus: Decodable, Identifiable {
    let id, name: String
    let verified, paired, paused: Bool
    let generation: Int?
    let status, username: String?

    var label: Phrase {
        if paused { return .paused }
        if !verified { return .unverified }
        return paired ? .paired : .unpaired
    }
}

enum ConnectionState: Equatable {
    case connecting
    case connected
    case offline
    case stopping
    case incompatible

    var phrase: Phrase {
        switch self {
        case .connecting: .connecting
        case .connected: .connected
        case .offline: .offline
        case .stopping: .stopping
        case .incompatible: .incompatible
        }
    }
}

@MainActor @Observable
final class AppModel {
    private static let languageKey = "displayLanguage"
    let client: BackendClient
    private let defaults: UserDefaults
    private var hasLocalLanguage: Bool
    private var refreshing = false
    private var generation = 0
    @ObservationIgnored private var monitor: Task<Void, Never>?

    private(set) var connection: ConnectionState = .connecting
    private(set) var config: AppConfig?
    private(set) var configRevision = 0
    private(set) var bots: [BotStatus] = []
    private(set) var readiness: Readiness?
    /// The last failure from any request, so every view can say what happened.
    private(set) var lastFailure: BackendError?
    /// Repeats the shell action that produced `lastFailure` (language or pause).
    @ObservationIgnored private(set) var retryLast: (@MainActor () async -> Void)?
    var pendingModelProbes: [String: ModelProbeRequest] = [:]
    private(set) var uiLanguage: AppLanguage
    private(set) var busy = false
    private(set) var error: Phrase?
    var page: Page = .overview
    var schedulingPaused: Bool { readiness.map { !$0.schedulingEnabled } ?? false }

    init(socket: LocalSocket, defaults: UserDefaults = .standard) {
        self.client = BackendClient(socket: socket)
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.languageKey).flatMap(AppLanguage.init(rawValue:))
        self.uiLanguage = stored ?? .zhHans
        self.hasLocalLanguage = stored != nil
    }

    static func defaultSocket() -> LocalSocket {
        if let fixture = Bundle.main.object(forInfoDictionaryKey: "NewsPawDevelopmentSocket") as? String {
            return LocalSocket(path: fixture)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return LocalSocket(path: home.appendingPathComponent("Library/Application Support/NewsPaw/control.sock").path)
    }

    func text(_ key: Phrase) -> String {
        // Views written before the redesign report every failure as `.saveFailed`;
        // show what actually happened instead (R06).
        if key == .saveFailed, let lastFailure { return FailureCopy.message(for: lastFailure, uiLanguage) }
        return uiLanguage.text(key)
    }

    func text(_ words: Words) -> String { words(uiLanguage) }

    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func refresh() async {
        guard !refreshing, !busy else { return }
        refreshing = true
        defer { refreshing = false }
        await loadSnapshot(generation: generation)
    }

    private func loadSnapshot(generation started: Int) async {
        do {
            let status = try await client.status()
            guard started == generation else { return }
            guard status.protocolVersion == 1 else { throw BackendFailure.incompatible }
            if status.state == "stopping" {
                clear(.stopping)
                return
            }
            guard status.state == "running" else { throw BackendFailure.invalidReply }
            let ready = status.operations?.contains(Operation.setupReadiness.rawValue) == true
                ? try await client.readiness() : nil
            let current = try await client.config()
            let currentBots = try await client.bots()
            guard started == generation else { return }
            readiness = ready
            config = current.document
            configRevision = current.revision
            bots = currentBots
            connection = .connected
            if !hasLocalLanguage {
                uiLanguage = current.document.uiLocale
            }
        } catch {
            guard started == generation else { return }
            let incompatible = (error as? BackendFailure) == .incompatible
                || (error as? BackendError)?.code == "unknown_operation"
            clear(incompatible ? .incompatible : .offline)
        }
    }

    private func clear(_ state: ConnectionState) {
        connection = state
        config = nil
        configRevision = 0
        bots = []
        readiness = nil
    }

    func chooseDisplayLanguage(_ value: AppLanguage) async {
        guard !busy else { return }
        uiLanguage = value
        hasLocalLanguage = true
        defaults.set(value.rawValue, forKey: Self.languageKey)
        if connection == .connected { await saveLocale(.ui, value) }
    }

    func chooseNewsLanguage(_ value: AppLanguage) async {
        guard connection == .connected, !busy else { return }
        await saveLocale(.news, value)
    }

    private func saveLocale(_ field: LocaleField, _ value: AppLanguage) async {
        // The shell retry calls this directly, so it keeps the same one-edit-at-a-time rule.
        guard !busy else { return }
        generation += 1
        busy = true
        defer { busy = false }
        error = nil
        let editor = EditorState(client: client)
        let saved = await editor.apply { document in
            var document = document
            document[field.rawValue] = value.rawValue
            return document
        }
        if !saved, let failure = editor.failure {
            lastFailure = failure
            retryLast = { [weak self] in await self?.saveLocale(field, value) }
            error = failure.isConflict ? .conflict : .saveFailed
            if failure.code == "backend_unreachable" { clear(.offline) }
        }
        // A poll from before this save may still be in flight. Reload at the
        // current generation while the edit owns the model.
        await loadSnapshot(generation: generation)
    }

    /// String-named requests from the settings views that predate the typed client.
    /// Removed together with those views (R07–R12).
    func request(_ operation: String, fields: [String: Any] = [:]) async throws -> Data {
        // A failure from these views has no shell retry; never keep an older one.
        lastFailure = nil
        retryLast = nil
        do {
            guard connection == .connected else { throw SocketFailure.disconnected }
            return try await client.send(operation, fields)
        } catch let failure as SocketFailure {
            lastFailure = BackendError(code: "backend_unreachable")
            throw failure
        } catch BackendFailure.invalidReply {
            lastFailure = BackendError(code: "invalid_reply")
            throw BackendFailure.invalidReply
        } catch let failure as BackendError {
            lastFailure = failure
            // Keep the cases those views already distinguish.
            if failure.code == "unknown_operation" { throw BackendFailure.incompatible }
            if failure.code == "restore_requires_fresh_instance" { throw BackendFailure.freshInstanceRequired }
            if failure.isConflict { throw BackendFailure.conflict }
            throw failure
        }
    }

    /// Pauses or resumes every scheduled delivery (the menu-bar and Settings switch).
    func setPaused(_ paused: Bool) async {
        guard connection == .connected, !busy else { return }
        generation += 1
        busy = true
        defer { busy = false }
        let editor = EditorState(
            load: { [client] in try await client.schedulePolicy() },
            store: { [client] in try await client.configureSchedule($0, revision: $1) }
        )
        error = nil
        if !(await editor.apply({ settings in
            var settings = settings
            settings["enabled"] = !paused
            return settings
        })) {
            lastFailure = editor.failure
            error = .saveFailed
            retryLast = { [weak self] in await self?.setPaused(paused) }
        }
        await loadSnapshot(generation: generation)
    }

    func pauseCategory(_ id: String, revision: Int) async throws {
        guard !busy else { throw BackendFailure.rejected }
        generation += 1
        busy = true
        defer { busy = false }
        do {
            _ = try await request("subscriptions.pause_category", fields: ["category_id": id, "revision": revision])
        } catch {
            await loadSnapshot(generation: generation)
            throw error
        }
        await loadSnapshot(generation: generation)
    }

    func stopBackend() async {
        guard connection == .connected, !busy else { return }
        generation += 1
        busy = true
        error = nil
        defer { busy = false }
        do {
            let status = try await client.stop()
            guard status.protocolVersion == 1, status.state == "stopping" else {
                throw BackendFailure.invalidReply
            }
            clear(.stopping)
        } catch {
            self.error = .stopFailed
            if error is SocketFailure { clear(.offline) }
        }
    }
}
