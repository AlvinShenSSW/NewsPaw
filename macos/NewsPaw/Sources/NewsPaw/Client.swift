import CoreFoundation
import Foundation

/// Every control operation the app sends. Views name a case, never an operation string.
enum Operation: String, CaseIterable, Sendable {
    case serviceStatus = "service.status"
    case serviceStop = "service.stop"
    case setupReadiness = "setup.readiness"
    case configGet = "config.get"
    case configSave = "config.save"
    case botsList = "bots.list"
    case scheduleStatus = "schedule.status"
    case scheduleConfigure = "schedule.configure"
    case scheduleResolve = "schedule.resolve"
    case budgetGet = "budget.get"
    case sourcesList = "sources.list"
    case jobsResume = "jobs.resume"
    case deliveryStatus = "delivery.status"
    case deliveryResolve = "delivery.resolve"
    case sendNow = "subscriptions.send_now"
    case newspaperPolicy = "newspaper.policy"
    case subscriptionsSave = "subscriptions.save"
    case subscriptionsPreview = "subscriptions.preview"
    case sourcesCatalog = "sources.catalog"
    case sourcesDiscover = "sources.discover"
    case sourcesSave = "sources.save"
    case sourcesDelete = "sources.delete"
    case sourcesPreview = "sources.preview"
    case sourcesImpact = "sources.impact"
    case sourcesImportOPML = "sources.import_opml"

    /// Socket deadline for an operation name, the one place the app sets timeouts.
    /// Network-bound operations wait for their bounded backend work; everything else
    /// uses the socket default.
    static func timeoutMilliseconds(for name: String) -> Int? {
        switch name {
        case "x.video.inspect": 155_000
        case "sources.discover", "sources.preview", "models.probe", "bots.verify", "bots.test_send",
             "x.accounts.verify", "x.lists.refresh", "ops.verify_backup": 35_000
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
        return try JSONSerialization.data(withJSONObject: result, options: .fragmentsAllowed)
    }

    func status() async throws -> ServiceStatus { try BackendRPC.decode(await call(.serviceStatus)) }
    func stop() async throws -> ServiceStatus { try BackendRPC.decode(await call(.serviceStop)) }
    func readiness() async throws -> Readiness { try BackendRPC.decode(await call(.setupReadiness)) }
    func config() async throws -> ConfigSnapshot { try BackendRPC.decode(await call(.configGet)) }
    func bots() async throws -> [BotStatus] { try BackendRPC.decode(await call(.botsList)) }

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
