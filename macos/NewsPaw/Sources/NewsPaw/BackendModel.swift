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

enum LocaleEdit {
    static func request(from result: Data, field: LocaleField, value: AppLanguage) throws -> Data {
        guard let envelope = try JSONSerialization.jsonObject(with: result) as? [String: Any],
              let revision = envelope["revision"] as? NSNumber,
              CFGetTypeID(revision) != CFBooleanGetTypeID(),
              revision.intValue > 0,
              revision.doubleValue == Double(revision.intValue),
              var document = envelope["document"] as? [String: Any] else {
            throw BackendFailure.invalidReply
        }
        document[field.rawValue] = value.rawValue
        return try JSONSerialization.data(withJSONObject: [
            "op": "config.save",
            "revision": revision,
            "document": document,
        ])
    }
}

struct BackendRPC {
    let socket: LocalSocket

    func get(_ operation: String) async throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: ["op": operation])
        return try await send(data)
    }

    func send(_ request: Data) async throws -> Data {
        let data = try await socket.request(request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = object["ok"] as? NSNumber,
              CFGetTypeID(ok) == CFBooleanGetTypeID() else {
            throw BackendFailure.invalidReply
        }
        if !ok.boolValue {
            switch object["error"] as? String {
            case "unknown_operation": throw BackendFailure.incompatible
            case "config_conflict", "binding_changed", "alert_policy_changed", "video_policy_changed",
                 "configuration_changed", "preview_changed":
                throw BackendFailure.conflict
            case "restore_requires_fresh_instance": throw BackendFailure.freshInstanceRequired
            default: throw BackendFailure.rejected
            }
        }
        guard let result = object["result"] else { throw BackendFailure.invalidReply }
        return try JSONSerialization.data(withJSONObject: result, options: .fragmentsAllowed)
    }

    static func decode<Value: Decodable>(_ data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Value.self, from: data)
    }
}

struct ServiceStatus: Decodable {
    let protocolVersion: Int
    let state: String
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
    private let rpc: BackendRPC
    private let defaults: UserDefaults
    private var hasLocalLanguage: Bool
    private var refreshing = false
    private var generation = 0
    @ObservationIgnored private var monitor: Task<Void, Never>?

    private(set) var connection: ConnectionState = .connecting
    private(set) var config: AppConfig?
    private(set) var configRevision = 0
    private(set) var bots: [BotStatus] = []
    private(set) var uiLanguage: AppLanguage
    private(set) var busy = false
    private(set) var error: Phrase?
    var page: SettingsPage? = .subscriptions

    init(socket: LocalSocket, defaults: UserDefaults = .standard) {
        self.rpc = BackendRPC(socket: socket)
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

    func text(_ key: Phrase) -> String { uiLanguage.text(key) }

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
            let status: ServiceStatus = try BackendRPC.decode(await rpc.get("service.status"))
            guard started == generation else { return }
            guard status.protocolVersion == 1 else { throw BackendFailure.incompatible }
            if status.state == "stopping" {
                clear(.stopping)
                return
            }
            guard status.state == "running" else { throw BackendFailure.invalidReply }
            let current: ConfigSnapshot = try BackendRPC.decode(await rpc.get("config.get"))
            let currentBots: [BotStatus] = try BackendRPC.decode(await rpc.get("bots.list"))
            guard started == generation else { return }
            config = current.document
            configRevision = current.revision
            bots = currentBots
            connection = .connected
            if !hasLocalLanguage {
                uiLanguage = current.document.uiLocale
            }
        } catch {
            guard started == generation else { return }
            clear((error as? BackendFailure) == .incompatible ? .incompatible : .offline)
        }
    }

    private func clear(_ state: ConnectionState) {
        connection = state
        config = nil
        configRevision = 0
        bots = []
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
        generation += 1
        busy = true
        defer { busy = false }
        error = nil
        do {
            let current = try await rpc.get("config.get")
            let request = try LocaleEdit.request(from: current, field: field, value: value)
            _ = try await rpc.send(request)
        } catch BackendFailure.conflict {
            error = .conflict
        } catch {
            self.error = .saveFailed
            if error is SocketFailure { clear(.offline) }
        }
        // A poll from before this save may still be in flight. Reload at the
        // current generation while the edit owns the model.
        await loadSnapshot(generation: generation)
    }

    func request(_ operation: String, fields: [String: Any] = [:]) async throws -> Data {
        guard connection == .connected else { throw SocketFailure.disconnected }
        var body = fields
        body["op"] = operation
        let data = try JSONSerialization.data(withJSONObject: body)
        let extended = ["sources.discover", "sources.preview", "models.probe", "bots.verify", "bots.test_send", "x.accounts.verify", "x.lists.refresh", "ops.verify_backup"].contains(operation)
        let timeout = operation == "x.video.inspect" ? 155_000 : extended ? 35_000 : nil
        let socket = timeout.map { LocalSocket(path: rpc.socket.path, timeoutMilliseconds: $0) } ?? rpc.socket
        return try await BackendRPC(socket: socket).send(data)
    }

    func stopBackend() async {
        guard connection == .connected, !busy else { return }
        generation += 1
        busy = true
        error = nil
        defer { busy = false }
        do {
            let status: ServiceStatus = try BackendRPC.decode(await rpc.get("service.stop"))
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
