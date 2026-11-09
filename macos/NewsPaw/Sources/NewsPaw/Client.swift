import CoreFoundation
import Foundation

/// Every control operation the app sends. Views name a case, never an operation string.
enum Operation: String, CaseIterable, Sendable {
    case serviceStatus = "service.status"
    case serviceStop = "service.stop"
    case setupReadiness = "setup.readiness"
    case configGet = "config.get"
    case configSave = "config.save"
    case configChangesSince = "config.changes_since"
    case botsList = "bots.list"
    case scheduleStatus = "schedule.status"
    case scheduleConfigure = "schedule.configure"

    /// Socket deadline for an operation name, the one place the app sets timeouts.
    /// Network-bound operations wait for their bounded backend work; everything else
    /// uses the socket default.
    static func timeoutMilliseconds(for name: String) -> Int? {
        switch name {
        case "models.probe", "bots.test_send", "x.accounts.verify", "x.lists.refresh", "ops.verify_backup": 35_000
        // Long operations answer within ~1 s (a result or a handle); room for a busy backend.
        case "sources.discover", "sources.preview", "bots.verify", "x.accounts.add", "x.video.inspect",
             "requests.status": 5_000
        default: nil
        }
    }

    /// Operations the backend runs in the background (R05 `LONG_OPERATIONS`), with the backend's
    /// deadline in seconds: they reply within ~2 s, possibly with a pending handle to follow.
    static func longDeadlineSeconds(for name: String) -> Int? {
        switch name {
        case "sources.discover", "x.accounts.add": 60
        case "sources.preview", "bots.verify": 90
        case "x.video.inspect": 170
        default: nil
        }
    }
}

/// A structured backend failure (`error` plus `error_detail`, see R02).
struct BackendError: Error, Equatable, Sendable {
    let code: String
    let domain: String
    let field: String?
    let retryable: Bool

    /// Another writer changed the record first; reload and apply the change again.
    var isConflict: Bool { Self.conflicts.contains(code) }

    static let conflicts: Set<String> = [
        "config_conflict", "binding_changed", "alert_policy_changed", "video_policy_changed",
        "configuration_changed", "preview_changed", "schedule_policy_changed",
        "budget_policy_conflict", "media_policy_changed", "newspaper_policy_changed",
    ]

    init(code: String, domain: String = "protocol", field: String? = nil, retryable: Bool = false) {
        self.code = code
        self.domain = domain
        self.field = field
        self.retryable = retryable
    }

    init(reply object: [String: Any]) {
        let code = object["error"] as? String ?? "invalid_reply"
        let detail = object["error_detail"] as? [String: Any] ?? [:]
        self.init(
            code: code,
            domain: detail["domain"] as? String ?? "protocol",
            field: detail["field"] as? String,
            retryable: (detail["retryable"] as? Bool) ?? false
        )
    }
}

struct Readiness: Decodable, Equatable, Sendable {
    struct Step: Decodable, Equatable, Sendable, Identifiable {
        let step: String
        let state: String
        let blockerCode: String?
        let entityId: String?
        let fixOp: String?
        var id: String { step }
        var done: Bool { state == "done" }
    }

    let complete: Bool
    let next: String?
    let schedulingEnabled: Bool
    let steps: [Step]
}

/// Typed requests over the private socket. One envelope parser, one error shape.
/// Main-actor bound like every caller, so request dictionaries never cross isolation.
@MainActor
struct BackendClient {
    typealias Transport = @Sendable (Data, Int?) async throws -> Data

    private let transport: Transport
    /// How often a pending long operation is read back.
    var pollInterval: Duration = .milliseconds(500)

    init(transport: @escaping Transport) {
        self.transport = transport
    }

    init(socket: LocalSocket) {
        self.transport = { body, timeout in
            let target = timeout.map { LocalSocket(path: socket.path, timeoutMilliseconds: $0) } ?? socket
            return try await target.request(body)
        }
    }

    /// Sends one operation and returns its `result`; a failure reply throws `BackendError`.
    func call(_ operation: Operation, _ fields: [String: Any] = [:]) async throws -> Data {
        try await send(operation.rawValue, fields)
    }

    /// The string form exists only for the settings views that predate this client;
    /// each is replaced by a typed page in R07–R12.
    func send(_ name: String, _ fields: [String: Any]) async throws -> Data {
        var result = try await exchange(name, fields)
        if let deadline = Operation.longDeadlineSeconds(for: name) {
            // A long operation still running answers with a handle; read it until it finishes.
            // The backend ends it with `timeout` at its deadline; the margin covers the last read.
            let clock = ContinuousClock()
            let giveUp = clock.now.advanced(by: .seconds(deadline + 10))
            while let handle = Self.pendingHandle(result) {
                guard clock.now < giveUp else { throw BackendError(code: "timeout", domain: String(name.prefix { $0 != "." })) }
                try await Task.sleep(for: pollInterval)
                result = try await exchange("requests.status", ["request": handle])
            }
        }
        return try JSONSerialization.data(withJSONObject: result, options: .fragmentsAllowed)
    }

    /// One request and its `result`; a failure reply throws `BackendError`.
    private func exchange(_ name: String, _ fields: [String: Any]) async throws -> Any {
        var body = fields
        body["op"] = name
        let request = try JSONSerialization.data(withJSONObject: body)
        let reply = try await transport(request, Operation.timeoutMilliseconds(for: name))
        guard let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
              let ok = object["ok"] as? NSNumber,
              CFGetTypeID(ok) == CFBooleanGetTypeID() else {
            throw BackendFailure.invalidReply
        }
        guard ok.boolValue else { throw BackendError(reply: object) }
        guard let result = object["result"] else { throw BackendFailure.invalidReply }
        return result
    }

    nonisolated static func pendingHandle(_ result: Any) -> String? {
        guard let object = result as? [String: Any], let pending = object["pending"] as? NSNumber,
              CFGetTypeID(pending) == CFBooleanGetTypeID(), pending.boolValue else { return nil }
        return object["request"] as? String
    }

    func status() async throws -> ServiceStatus { try BackendRPC.decode(await call(.serviceStatus)) }
    func stop() async throws -> ServiceStatus { try BackendRPC.decode(await call(.serviceStop)) }
    func readiness() async throws -> Readiness { try BackendRPC.decode(await call(.setupReadiness)) }
    func config() async throws -> ConfigSnapshot { try BackendRPC.decode(await call(.configGet)) }
    func bots() async throws -> [BotStatus] { try BackendRPC.decode(await call(.botsList)) }

    /// What changed in the configuration since `revision` (R05); `history_unavailable` when
    /// that revision is older than the backend keeps, in which case reload everything.
    func changes(since revision: Int) async throws -> ConfigChanges {
        try BackendRPC.decode(await call(.configChangesSince, ["revision": revision]))
    }

    /// The stored configuration as a mutable document, so unknown fields survive a save.
    func configDocument() async throws -> (revision: Int, document: [String: Any]) {
        try Self.record(await call(.configGet), field: "document")
    }

    func saveConfig(_ document: [String: Any], revision: Int) async throws {
        _ = try await call(.configSave, ["document": document, "revision": revision])
    }

    func schedulePolicy() async throws -> (revision: Int, document: [String: Any]) {
        try Self.record(await call(.scheduleStatus, ["limit": 1]), field: "settings")
    }

    func configureSchedule(_ settings: [String: Any], revision: Int) async throws {
        _ = try await call(.scheduleConfigure, ["settings": settings, "revision": revision])
    }

    static func record(_ data: Data, field: String) throws -> (revision: Int, document: [String: Any]) {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let revision = object["revision"] as? NSNumber,
              CFGetTypeID(revision) != CFBooleanGetTypeID(),
              revision.intValue > 0,
              revision.doubleValue == Double(revision.intValue),
              let document = object[field] as? [String: Any] else {
            throw BackendFailure.invalidReply
        }
        return (revision.intValue, document)
    }
}

struct ConfigChanges: Decodable, Equatable, Sendable {
    struct Change: Decodable, Equatable, Sendable {
        let field: String?
        let collection: String?
        let id: String?
        let fields: [String]?
        let added: Bool?
        let removed: Bool?
    }
    let revision: Int
    let changes: [Change]
}
