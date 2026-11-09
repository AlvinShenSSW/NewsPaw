import Foundation
import Testing

@testable import NewsPaw

/// An in-memory backend for the Connect page that follows the real operations' rules:
/// `credentials.set` stores a new reference and resets what depends on it (a Bot's check and
/// pairing, a profile's checks), a refused token shows up in `bots.verify`'s status, every
/// Bot change needs the current generation, and configuration, budget and media changes need
/// the current revision.
@MainActor
private final class ConnectBackend {
    struct Bot {
        var verified = false
        var paired = false
        var paused = false
        var generation = 0
        var status = "unverified"
        var username: String?
    }

    var revision = 1
    var document: [String: Any]
    var registry: [String: Bot] = [:]
    var keychain: [String: String] = [:]
    /// The Telegram error `bots.verify` records for a token (nil: Telegram accepts it).
    var tokenProblem: String?
    /// bots.status reads after a code is issued before the owner "sends" it.
    var pairAfterReads = 1
    private var statusReads = 0
    /// What `bots.test_send` reports.
    var testOutcome: (state: String, reason: String?) = ("confirmed", nil)
    private var tests: [String: [String: Any]] = [:]
    /// Text check results per profile, read one at a time; the last one repeats. A profile
    /// with a key and no script reads as checked (the backend checks a saved key by itself).
    var checks: [String: [[String: Any]]] = [:]
    var health: [[String: Any]] = []
    var budgetRevision = 1
    var budget: [String: Any] = [
        "model": ["monthly_limit": 20_000_000, "image_limit": NSNull(), "provider_limits": [String: Any](), "timezone": "Asia/Tokyo", "cycle_day": 1],
        "x": ["daily_limit": 200, "partition_limits": ["normal": NSNull(), "adult": NSNull()], "account_limits": [String: Any](), "timezone": "Asia/Tokyo"],
        "prices": [], "openai_credit": ["amount": 100_000_000, "organization": NSNull(), "expires_at": NSNull(), "source": "user_declared", "verified": false],
    ]
    var periods: [[String: Any]] = []
    var paperRevision = 1
    var paper: [String: Any] = [
        "enabled": false, "generation_profile": NSNull(), "backup_profile": NSNull(), "vision_profile": NSNull(),
        "pages": 1, "generation_hold": NSNull(), "vision_hold": NSNull(), "task_limit": NSNull(),
    ]
    var mediaRevision = 1
    var media: [String: Any] = ["vision_profile": NSNull(), "vision_hold": NSNull(), "stt_profile": NSNull(), "stt_hold": NSNull(), "listen_enabled": false]
    private(set) var requests: [[String: Any]] = []
    private var refs = 0

    init(bots: [[String: Any]] = [], botIds: [String] = [], adultBotIds: [String] = []) {
        document = [
            "ui_locale": "en", "news_output_locale": "en", "owner_id": 7, "x_api": ["credential_ref": NSNull()],
            "categories": [["id": "world", "name": "World", "partition": "normal"], ["id": "av", "name": "AV", "partition": "adult"]],
            "subscriptions": [
                ["id": "sub_world", "name": "World", "category_id": "world", "timezone": "Asia/Tokyo", "enabled": true, "times": ["08:00"], "bot_ids": botIds, "source_ids": []],
                ["id": "sub_av", "name": "AV", "category_id": "av", "timezone": "Asia/Tokyo", "enabled": true, "times": ["21:00"], "bot_ids": adultBotIds, "source_ids": []],
            ],
            "sources": [], "accounts": [], "bots": bots,
            "model_profiles": [
                Self.profile("normal_primary", "normal", "primary", "openai", "https://api.openai.com/v1", "gpt-6-luna"),
                Self.profile("normal_backup", "normal", "backup", "mimo", "https://api.xiaomimimo.com/v1", "mimo-v2.6-flash"),
                Self.profile("adult_primary", "adult", "primary", "deepseek", "https://api.deepseek.com", "deepseek-flash"),
                Self.profile("adult_backup", "adult", "backup", "grok", "https://api.x.ai/v1", "grok-4.3"),
            ],
        ]
        for bot in bots {
            let id = bot["id"] as! String
            let paired = bot["paired"] as? Bool ?? false
            registry[id] = Bot(verified: paired, paired: paired, generation: paired ? 3 : 0, status: paired ? "paired" : "unverified", username: paired ? "np_bot" : nil)
        }
    }

    static func profile(_ id: String, _ partition: String, _ role: String, _ provider: String, _ url: String, _ model: String) -> [String: Any] {
        ["id": id, "partition": partition, "role": role, "provider": provider, "base_url": url, "model": model, "credential_ref": NSNull(), "capabilities": []]
    }

    static func bot(_ id: String, paired: Bool = true, adult: Bool = false) -> [String: Any] {
        ["id": id, "name": "News", "credential_ref": "keychain:\(id)", "telegram_id": paired ? 99 : NSNull(), "chat_id": paired ? 7 : NSNull(),
         "verified": paired, "paired": paired, "adult_allowed": adult]
    }

    func calls(_ op: String) -> [[String: Any]] { requests.filter { $0["op"] as? String == op } }
    var bots: [[String: Any]] { document["bots"] as? [[String: Any]] ?? [] }
    func subscription(_ id: String) -> [String: Any]? { (document["subscriptions"] as? [[String: Any]])?.first { $0["id"] as? String == id } }
    func profileEntry(_ id: String) -> [String: Any]? { (document["model_profiles"] as? [[String: Any]])?.first { $0["id"] as? String == id } }

    /// `models.probe` outlasts the socket deadline: the app sees a timeout while the backend
    /// keeps running the check. Asking again with the same probe id returns that check's own
    /// record (pending once, then this result) without starting another one.
    var probeOutlastsSocket: [String: Any]?
    private var droppedProbes: [String: Int] = [:]
    /// Image / vision / speech check records per profile, as `models.status` reports them.
    var capabilityStates: [String: [String: [String: Any]]] = [:]
    /// What the next non-text `models.probe` finds; a repeated probe id returns its own record.
    var capabilityResult: [String: Any] = ["state": "verified", "status": "verified"]
    private var probeRecords: [String: [String: Any]] = [:]
    /// The next `bots.test_status` reply is lost (connection dropped).
    var dropNextTestStatus = false
    /// `config.save` answers only after this long (another writer holds the store).
    var configSaveDelay: Duration?

    var client: BackendClient {
        BackendClient { [unowned self] body, _ in
            let (delay, dropped) = await MainActor.run { () -> (Duration?, Bool) in
                let request = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
                let op = request["op"] as? String
                if op == "bots.test_status", self.dropNextTestStatus {
                    self.dropNextTestStatus = false
                    self.requests.append(request)
                    return (nil, true)
                }
                return (op == "config.save" ? self.configSaveDelay : nil, false)
            }
            if dropped { throw SocketFailure.disconnected }
            if let delay { try? await Task.sleep(for: delay) }
            let reply = await MainActor.run { () -> Data? in
                let request = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
                if request["op"] as? String == "models.probe", let result = self.probeOutlastsSocket,
                   let profile = request["profile_id"] as? String, let id = request["probe_id"] as? String {
                    self.requests.append(request)
                    let asked = self.droppedProbes[id, default: 0]
                    self.droppedProbes[id] = asked + 1
                    switch asked {
                    case 0: return nil
                    case 1: return self.ok(["status": "pending"])
                    default:
                        self.checks[profile] = [result]
                        return self.ok(result.filter { $0.key != "state" })
                    }
                }
                return self.answer(request)
            }
            guard let reply else { throw SocketFailure.timeout }
            return reply
        }
    }

    private func ok(_ result: Any) -> Data { try! JSONSerialization.data(withJSONObject: ["ok": true, "result": result]) }
    private func refuse(_ code: String, _ domain: String = "config") -> Data {
        try! JSONSerialization.data(withJSONObject: ["ok": false, "error": code, "error_detail": ["code": code, "domain": domain, "retryable": false]])
    }

    private func status(_ id: String) -> [String: Any] {
        let bot = registry[id] ?? Bot()
        let name = bots.first { $0["id"] as? String == id }?["name"] ?? "Telegram"
        return ["id": id, "name": name, "verified": bot.verified, "paired": bot.verified && bot.paired, "paused": bot.paused,
                "generation": bot.generation, "status": bot.status, "username": bot.username ?? ""]
    }

    private func editBots(_ change: (inout [[String: Any]]) -> Void) {
        var list = bots
        change(&list)
        document["bots"] = list
    }

    private func editSubscriptions(_ change: (inout [String: Any]) -> Void) {
        document["subscriptions"] = (document["subscriptions"] as! [[String: Any]]).map { var entry = $0; change(&entry); return entry }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func answer(_ request: [String: Any]) -> Data {
        requests.append(request)
        let op = request["op"] as! String
        let stale = (request["revision"] as? Int).map { $0 != revision } ?? false
        let id = request["bot_id"] as? String ?? ""
        let generationMismatch = (request["generation"] as? Int).map { $0 != (registry[id]?.generation ?? 0) } ?? false
        switch op {
        case "service.status": return ok(["protocol_version": 1, "state": "running", "operations": ["setup.readiness"]])
        case "setup.readiness": return ok(["complete": true, "next": NSNull(), "scheduling_enabled": true, "steps": []])
        case "config.get": return ok(["revision": revision, "document": document])
        case "config.save":
            if stale { return refuse("config_conflict") }
            document = request["document"] as! [String: Any]
            for bot in bots where registry[bot["id"] as! String] == nil { registry[bot["id"] as! String] = Bot() }
            revision += 1
            return ok(["revision": revision])
        case "bots.list": return ok(bots.map { status($0["id"] as! String) })
        case "credentials.set":
            if stale { return refuse("config_conflict") }
            let kind = request["kind"] as! String
            let value = request["value"] as! String
            refs += 1
            let ref = "keychain:ref\(refs)"
            keychain[ref] = value
            switch kind {
            case "bots":
                editBots { list in
                    list = list.map { entry in
                        guard entry["id"] as? String == request["id"] as? String else { return entry }
                        var entry = entry
                        entry["credential_ref"] = ref
                        entry["verified"] = false
                        entry["paired"] = false
                        return entry
                    }
                }
                // A new reference invalidates the registration (registry.invalidate_bots).
                var bot = registry[request["id"] as! String] ?? Bot()
                bot = Bot(generation: bot.generation + 1)
                registry[request["id"] as! String] = bot
            case "model_profiles":
                document["model_profiles"] = (document["model_profiles"] as! [[String: Any]]).map { entry in
                    guard entry["id"] as? String == request["id"] as? String else { return entry }
                    var entry = entry
                    entry["credential_ref"] = ref
                    entry["capabilities"] = []
                    return entry
                }
            default:
                document["x_api"] = ["credential_ref": ref]
            }
            revision += 1
            return ok(["revision": revision])
        case "credentials.status":
            var states: [String: String] = [:]
            var tails: [String: String] = [:]
            var refs: [String] = bots.compactMap { $0["credential_ref"] as? String }
            refs += (document["model_profiles"] as! [[String: Any]]).compactMap { $0["credential_ref"] as? String }
            if let x = (document["x_api"] as? [String: Any])?["credential_ref"] as? String { refs.append(x) }
            for ref in refs {
                let value = keychain[ref]
                states[ref] = value == nil ? "missing" : "available"
                if let value, value.count >= 8 { tails[ref] = String(value.suffix(4)) }
            }
            return ok(["pending": false, "references": states, "tails": tails, "cleanup_pending": 0])
        case "bots.status":
            statusReads += 1
            if var bot = registry[id], bot.status == "awaiting_pair", statusReads > pairAfterReads {
                bot.paired = true
                bot.status = "paired"
                registry[id] = bot
            }
            return ok(status(id))
        case "bots.verify":
            if generationMismatch { return refuse("binding_changed", "bots") }
            var bot = registry[id] ?? Bot()
            bot.generation += 1
            if let tokenProblem {
                bot.verified = false
                bot.status = tokenProblem
            } else {
                bot.verified = true
                bot.status = "verified"
                bot.username = "np_bot"
            }
            registry[id] = bot
            return ok(status(id))
        case "bots.pair_code":
            if generationMismatch { return refuse("binding_changed", "bots") }
            guard var bot = registry[id], bot.verified else { return refuse("bot_not_verified", "bots") }
            bot.generation += 1
            bot.paired = false
            bot.paused = false
            bot.status = "awaiting_pair"
            registry[id] = bot
            statusReads = 0
            return ok(["code": "Code\(bot.generation)", "expires_at": Date().timeIntervalSince1970 + 600, "max_attempts": 5])
        case "bots.action":
            if generationMismatch { return refuse("binding_changed", "bots") }
            var bot = registry[id] ?? Bot()
            bot.generation += 1
            switch request["action"] as! String {
            case "pause": bot.paused = true; bot.status = "paused"
            case "resume": bot.paused = false; bot.status = "paired"
            // Unpairing leaves a pause in place (registry.action).
            default: bot.paired = false; bot.status = "unpaired"
            }
            registry[id] = bot
            return ok(status(id))
        case "bots.test_send":
            if generationMismatch { return refuse("binding_changed", "bots") }
            guard let bot = registry[id], bot.paired, !bot.paused else { return refuse("binding_not_ready", "bots") }
            let record: [String: Any] = ["request_id": request["request_id"]!, "generation": bot.generation,
                                         "state": testOutcome.state, "reason": testOutcome.reason ?? NSNull()]
            tests[request["request_id"] as! String] = record
            return ok(record)
        case "bots.test_status":
            let identity = request["request_id"] as! String
            return ok(tests[identity] ?? ["request_id": identity, "generation": request["generation"]!, "state": "not_started", "reason": NSNull()])
        case "targets.bot_impact":
            let subs = (document["subscriptions"] as! [[String: Any]]).filter { ($0["bot_ids"] as! [String]).contains(id) }
            return ok(["revision": revision, "bot_id": id, "subscriptions": subs.map { $0["id"]! },
                       "categories": subs.map { $0["category_id"]! },
                       "last_target_subscriptions": subs.filter { ($0["bot_ids"] as! [String]) == [id] }.map { $0["id"]! },
                       "subscription_targets": [String: Any](), "accounts": []])
        case "targets.delete_bot":
            if stale { return refuse("config_conflict") }
            editBots { $0.removeAll { $0["id"] as? String == id } }
            editSubscriptions { $0["bot_ids"] = ($0["bot_ids"] as! [String]).filter { $0 != id } }
            registry[id] = nil
            revision += 1
            return ok(["revision": revision])
        case "targets.adult_permission":
            if stale { return refuse("config_conflict") }
            let allowed = request["allowed"] as! Bool
            editBots { list in list = list.map { var entry = $0; if entry["id"] as? String == id { entry["adult_allowed"] = allowed }; return entry } }
            if !allowed {
                editSubscriptions { entry in
                    if entry["category_id"] as? String == "av" { entry["bot_ids"] = (entry["bot_ids"] as! [String]).filter { $0 != id } }
                }
            }
            revision += 1
            return ok(["revision": revision])
        case "models.status":
            let profile = request["profile_id"] as! String
            let keyed = profileEntry(profile)?["credential_ref"] is String
            var text: [String: Any] = keyed ? ["state": "verified", "status": "verified"] : ["state": "untested"]
            if var queue = checks[profile], let first = queue.first {
                text = first
                if queue.count > 1 { queue.removeFirst(); checks[profile] = queue }
            }
            var states: [String: Any] = ["text": text, "vision": ["state": "untested"], "image": ["state": "untested"], "stt": ["state": "untested"]]
            for (capability, record) in capabilityStates[profile] ?? [:] { states[capability] = record }
            return ok(states)
        case "models.probe":
            let profile = request["profile_id"] as! String
            let capability = request["capability"] as! String
            if capability != "text" {
                // A probe id names one check: asking again returns its record, never a new check.
                let id = request["probe_id"] as! String
                let record = probeRecords[id] ?? capabilityResult
                probeRecords[id] = record
                capabilityStates[profile, default: [:]][capability] = record
                return ok(record.filter { $0.key != "state" })
            }
            let result = checks[profile]?.last ?? ["state": "verified", "status": "verified"]
            checks[profile] = [result]
            return ok(result.filter { $0.key != "state" })
        case "models.health": return ok(["profiles": health])
        case "budget.get":
            return ok(["revision": budgetRevision, "document": budget, "report": ["policy_revision": budgetRevision, "periods": periods]])
        case "budget.save":
            if request["revision"] as? Int != budgetRevision { return refuse("budget_policy_conflict", "budget") }
            let document = request["document"] as! [String: Any]
            let limit = (document["model"] as! [String: Any])["monthly_limit"]
            guard limit is NSNull || (limit as? Int).map({ $0 >= 0 }) == true else { return refuse("invalid_units", "budget") }
            budget = document
            budgetRevision += 1
            return ok(["revision": budgetRevision])
        case "newspaper.policy": return ok(["revision": paperRevision, "settings": paper])
        case "newspaper.configure":
            if request["revision"] as? Int != paperRevision { return refuse("newspaper_policy_changed", "media") }
            paper = request["settings"] as! [String: Any]
            paperRevision += 1
            return ok(["revision": paperRevision, "settings": paper])
        case "media.policy": return ok(["revision": mediaRevision, "settings": media])
        case "media.configure":
            if request["revision"] as? Int != mediaRevision { return refuse("media_policy_changed", "media") }
            let settings = request["settings"] as! [String: Any]
            // media.configure: a profile without an amount gets the default; no profile needs no amount.
            if settings["stt_profile"] is NSNull, !(settings["stt_hold"] is NSNull) { return refuse("invalid_media_settings", "media") }
            media = settings
            mediaRevision += 1
            return ok(["revision": mediaRevision, "settings": media])
        case "x.accounts.list":
            let ref = (document["x_api"] as? [String: Any])?["credential_ref"]
            return ok(["revision": revision, "credential_configured": ref is String, "accounts": []])
        default: return refuse("unknown_operation")
        }
    }
}

@MainActor
private func connected(_ server: ConnectBackend) async throws -> (AppModel, ConnectData, () -> Void) {
    let name = "NewsPawTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    let model = AppModel(client: server.client, defaults: defaults)
    await model.refresh()
    #expect(model.connection == .connected)
    let data = ConnectData()
    data.pollInterval = .milliseconds(5)
    data.keys.pollInterval = .milliseconds(5)
    data.keys.probeLimit = .seconds(5)
    await data.load(model: model)
    return (model, data, { defaults.removePersistentDomain(forName: name) })
}

// MARK: - Bots

@Test @MainActor func aBotIsAddedCheckedAndPairedInlineOnThePage() async throws {
    let server = ConnectBackend()
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    data.startAdding()
    let adding = try #require(data.adding)
    await adding.connect(token: "123456:synthetic-token", model: model)
    let id = try #require(adding.botId)
    #expect(adding.bot?.verified == true && adding.pair != nil && adding.failure == nil)
    #expect(server.calls("credentials.set").last?["kind"] as? String == "bots")

    await adding.waitForPairing(model: model)
    #expect(adding.paired && adding.pair == nil && adding.pairedAt != nil)
    data.finishAdding()
    #expect(data.adding == nil && data.pairing(id)?.pairedAt != nil)
    #expect(model.bots.map(\.id) == [id] && BotState(model.bots[0]) == .paired)
}

@Test @MainActor func aRefusedTokenIsNamedAndCancellingLeavesNoBotBehind() async throws {
    let server = ConnectBackend()
    server.tokenProblem = "invalid_token"
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    data.startAdding()
    await data.adding?.connect(token: "wrong", model: model)

    // The real backend accepts any token in credentials.set; bots.verify reports the refusal.
    #expect(data.adding?.failure?.code == "invalid_token")
    #expect(FailureCopy.entry(for: try #require(data.adding?.failure)).action != nil)
    #expect(server.bots.count == 1)
    await data.cancelAdding(model: model)
    #expect(server.bots.isEmpty && data.adding == nil && server.calls("targets.delete_bot").count == 1)
}

@Test @MainActor func anExpiredCodeStopsWaitingAndANewOneCanBeMadeInPlace() async throws {
    let server = ConnectBackend()
    server.pairAfterReads = 1_000
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }
    data.startAdding()
    let adding = try #require(data.adding)
    await adding.connect(token: "123456:synthetic-token", model: model)
    let first = try #require(adding.pair)

    await adding.waitForPairing(model: model, now: { first.expires.addingTimeInterval(1) })
    #expect(!adding.paired && adding.pair == first)

    await adding.newCode(model: model)
    #expect(server.calls("bots.pair_code").count == 2 && adding.pair != first && adding.failure == nil)
    // The second request carried the generation the first code left behind.
    #expect(server.calls("bots.pair_code").last?["generation"] as? Int == server.registry[adding.botId!]!.generation - 1)
}

@Test @MainActor func aStoredBotWaitingToPairGetsACodeFromItsGroup() async throws {
    let server = ConnectBackend(bots: [ConnectBackend.bot("b1", paired: false)])
    server.registry["b1"] = .init(verified: true, generation: 4, status: "unpaired", username: "np_bot")
    server.pairAfterReads = 1_000
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }
    #expect(BotState(model.bots[0]) == .unpaired)

    await data.newCode("b1", model: model)

    #expect(data.pairing("b1")?.pair != nil && server.calls("bots.pair_code").last?["generation"] as? Int == 4)
}

@Test @MainActor func deletingABotListsTheDigestsThatLoseItThenRemovesIt() async throws {
    let server = ConnectBackend(bots: [ConnectBackend.bot("b1")], botIds: ["b1"])
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    let impact = try #require(await data.loadImpact("b1", model: model))
    #expect(impact.subscriptions == ["sub_world"] && impact.lastTargetSubscriptions == ["sub_world"])
    #expect(server.calls("targets.delete_bot").isEmpty)

    #expect(await data.delete("b1", model: model))
    #expect(server.bots.isEmpty && (server.subscription("sub_world")?["bot_ids"] as? [String]) == [])
    // The digests page now reads "no bot chosen" for it.
    #expect(model.config?.subscriptions.first { $0.id == "sub_world" }?.botIds == [])
    #expect(model.bots.isEmpty)
}

@Test @MainActor func turningAdultOffListsTheAdultDigestsAndRemovesTheBotFromThem() async throws {
    let server = ConnectBackend(bots: [ConnectBackend.bot("b1", adult: true)], botIds: ["b1"], adultBotIds: ["b1"])
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    let affected = ConnectData.adultTargets("b1", config: try #require(model.config))
    #expect(affected == ["sub_av"])

    await data.setAdult("b1", false, model: model)
    #expect((server.subscription("sub_av")?["bot_ids"] as? [String]) == [])
    #expect((server.subscription("sub_world")?["bot_ids"] as? [String]) == ["b1"])
    #expect(model.config?.bots?.first?.adultAllowed == false)
    #expect(ConnectData.adultTargets("b1", config: try #require(model.config)).isEmpty)
}

@Test @MainActor func aTestMessageReportsDeliveryAndAnUnknownResultCanBeChecked() async throws {
    let server = ConnectBackend(bots: [ConnectBackend.bot("b1")])
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    await data.sendTest("b1", model: model)
    #expect(data.tests["b1"]?.state == "confirmed" && data.testedAt["b1"] != nil)
    #expect(server.calls("bots.test_send").last?["generation"] as? Int == 3)

    server.testOutcome = ("outcome_unknown", "outcome_unknown")
    await data.sendTest("b1", model: model)
    let unknown = try #require(data.tests["b1"])
    #expect(unknown.state == "outcome_unknown" && !data.stillUnknown.contains("b1"))

    await data.checkTest("b1", model: model)
    // The same request is read back; the backend keeps an unknown result unknown.
    #expect(server.calls("bots.test_status").last?["request_id"] as? String == unknown.requestId)
    #expect(data.stillUnknown.contains("b1"))

    server.testOutcome = ("failed", "forbidden")
    await data.sendTest("b1", model: model)
    #expect(data.failures["test.b1"]?.code == "forbidden")
}

@Test @MainActor func pausingAndUnpairingUseTheBotsCurrentGeneration() async throws {
    let server = ConnectBackend(bots: [ConnectBackend.bot("b1")])
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    await data.act("b1", "pause", model: model)
    #expect(BotState(model.bots[0]) == .paused && data.failures["bot.b1"] == nil)
    await data.act("b1", "resume", model: model)
    #expect(BotState(model.bots[0]) == .paired)
    await data.act("b1", "unbind", model: model)
    #expect(BotState(model.bots[0]) == .unpaired)
    #expect(server.calls("bots.action").map { $0["generation"] as? Int } == [3, 4, 5])
}

@Test @MainActor func renamingABotKeepsItsPairing() async throws {
    let server = ConnectBackend(bots: [ConnectBackend.bot("b1")])
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    await data.rename("b1", to: "  Morning bot ", model: model)

    #expect(server.bots.first?["name"] as? String == "Morning bot" && server.bots.first?["paired"] as? Bool == true)
    #expect(model.bots.first?.name == "Morning bot" && data.savedAt["name.b1"] != nil)
}

@Test func botStatesFollowTheBackendStatus() throws {
    func state(_ json: String) throws -> BotState {
        BotState(try BackendRPC.decode(Data(json.utf8)) as BotStatus)
    }
    #expect(try state(#"{"id":"b","name":"n","verified":false,"paired":false,"paused":false,"status":"unverified"}"#) == .unverified)
    #expect(try state(#"{"id":"b","name":"n","verified":false,"paired":false,"paused":false,"status":"verifying"}"#) == .verifying)
    #expect(try state(#"{"id":"b","name":"n","verified":false,"paired":false,"paused":false,"status":"webhook_conflict"}"#) == .problem("webhook_conflict"))
    #expect(try state(#"{"id":"b","name":"n","verified":true,"paired":false,"paused":false,"status":"awaiting_pair"}"#) == .waiting)
    #expect(try state(#"{"id":"b","name":"n","verified":true,"paired":false,"paused":false,"status":"pair_expired"}"#) == .expired)
    #expect(try state(#"{"id":"b","name":"n","verified":true,"paired":false,"paused":false,"status":"pair_attempts_exhausted"}"#) == .problem("pair_attempts_exhausted"))
    #expect(try state(#"{"id":"b","name":"n","verified":true,"paired":true,"paused":true,"status":"paused"}"#) == .paused)
    #expect(try state(#"{"id":"b","name":"n","verified":true,"paired":true,"paused":false,"status":"paired"}"#) == .paired)
}

// MARK: - Models

@Test @MainActor func aSavedKeyIsReadBackUntilItsCheckSettlesTreatingStaleAsWaiting() async throws {
    let server = ConnectBackend()
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }
    // The earlier key's result reads stale, then the new check is pending, then it finishes.
    server.checks["normal_primary"] = [
        ["state": "stale", "status": "failed", "error_kind": "authentication_failed"],
        ["state": "pending", "status": "pending"],
        ["state": "verified", "status": "verified", "checked_at": "2026-11-10T08:12:00+00:00"],
    ]

    await data.saveKey("sk-synthetic-7Qx2", profile: "normal_primary", model: model)

    #expect(data.keys.probes["normal_primary"]?.state == "verified")
    #expect(server.calls("models.status").filter { $0["profile_id"] as? String == "normal_primary" }.count >= 3)
    let ref = try #require(model.config?.modelProfiles.first { $0.id == "normal_primary" }?.credentialRef)
    #expect(data.tail(ref) == "7Qx2")
    let status = KeyStatus.of(credential: data.credentialState(ref), probe: data.keys.probes["normal_primary"], health: nil, working: false)
    #expect(status == .verified)
}

@Test @MainActor func rejectedRateLimitedAndUnansweredChecksSayDifferentThingsAndOfferDifferentFixes() async throws {
    let server = ConnectBackend()
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }
    server.checks["adult_primary"] = [["state": "failed", "status": "failed", "error_kind": "authentication_failed"]]
    await data.saveKey("sk-synthetic-adult", profile: "adult_primary", model: model)
    let rejected = KeyStatus.of(credential: "available", probe: data.keys.probes["adult_primary"], health: nil, working: false)

    let limited = KeyStatus.of(credential: "available", probe: ProbeState(state: "failed", errorKind: "rate_limited"), health: nil, working: false)
    // A provider that never answered (90 s timeout) is recorded as an unknown outcome.
    let silent = KeyStatus.of(credential: "available", probe: ProbeState(state: "outcome_unknown", errorKind: "outcome_unknown"), health: nil, working: false)
    let forbidden = KeyStatus.of(credential: "available", probe: ProbeState(state: "failed", errorKind: "permission_denied"), health: nil, working: false)

    #expect(rejected == .rejected("authentication_failed") && rejected.action == .reenterKey && rejected.color == .red)
    #expect(limited == .unavailable("rate_limited") && limited.action == .recheck && limited.color == .orange)
    #expect(silent == .unknown("outcome_unknown") && silent.action == .confirmRecheck)
    for language in AppLanguage.allCases {
        let notes = [rejected, limited, silent, forbidden].map { $0.note(language, provider: "DeepSeek") ?? "" }
        #expect(Set(notes).count == 4)
        #expect(notes[0].contains("401") && notes[1].contains("429") && notes[3].contains("403"))
        #expect(notes[0].contains("DeepSeek") && notes[2].contains("DeepSeek"))
    }

    // "Check again" runs one more check of the same key.
    server.checks["adult_primary"] = [["state": "verified", "status": "verified"]]
    await data.recheck("adult_primary", model: model)
    #expect(data.keys.probes["adult_primary"]?.passed == true && server.calls("models.probe").last?["hold_units"] as? Int == 10_000)
}

@Test func aCooldownShowsWhenItEndsAndOnlyWhileItLasts() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let checked = ProbeState(state: "verified", checkedAt: "2026-01-01T00:00:00+00:00")
    let until = ISO8601DateFormatter().string(from: now.addingTimeInterval(300))
    let health = ModelHealth(profileId: "normal_primary", generation: 2, failures: 3, cooldownUntil: until, errorKind: "rate_limited", checkedAt: "2027-01-15T08:00:00+00:00")

    let status = KeyStatus.of(credential: "available", probe: checked, health: health, working: false, now: now)
    guard case let .cooldown(end, failures) = status else { Issue.record("no cooldown: \(status)"); return }
    #expect(failures == 3 && abs(end.timeIntervalSince(now) - 300) < 1 && status.color == .orange && status.action == .none)
    #expect(status.note(.zhHans, provider: "OpenAI")?.contains("3") == true)
    #expect(status.title(.en).contains(Stamp.clock(end)))

    // Over, or older than the latest passing check of the key (a new key): back to working.
    #expect(KeyStatus.of(credential: "available", probe: checked, health: health, working: false, now: now.addingTimeInterval(400)) == .verified)
    let newer = ProbeState(state: "verified", checkedAt: "2028-01-01T00:00:00+00:00")
    #expect(KeyStatus.of(credential: "available", probe: newer, health: health, working: false, now: now) == .verified)
}

@Test func keyStatusesCoverMissingKeychainAndWaitingStates() {
    #expect(KeyStatus.of(credential: nil, probe: nil, health: nil, working: false) == .missing)
    #expect(KeyStatus.of(credential: "missing", probe: nil, health: nil, working: false).action == .enterKey)
    #expect(KeyStatus.of(credential: "keychain_locked", probe: nil, health: nil, working: false) == .keychain("keychain_locked"))
    #expect(KeyStatus.of(credential: "available", probe: ProbeState(state: "pending"), health: nil, working: false) == .checking)
    #expect(KeyStatus.of(credential: "available", probe: ProbeState(state: "stale"), health: nil, working: false) == .untested)
    #expect(KeyStatus.of(credential: "available", probe: ProbeState(state: "budget_blocked"), health: nil, working: false) == .budget)
    #expect(KeyStatus.of(credential: "available", probe: nil, health: nil, working: true) == .checking)
}

@Test @MainActor func turningExtrasOnAndOffEditsTheStoredPolicies() async throws {
    let server = ConnectBackend()
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    await data.setNewspaper(true, profile: "normal_primary", model: model)
    #expect(server.paper["enabled"] as? Bool == true && server.paper["generation_profile"] as? String == "normal_primary")
    #expect(server.paper["vision_profile"] as? String == "normal_primary" && data.extras.newspaperOn)

    await data.setTranscription("normal_primary", model: model)
    #expect(server.media["stt_profile"] as? String == "normal_primary" && data.extras.transcriptionProfile == "normal_primary")
    await data.setTranscription(nil, model: model)
    #expect(server.media["stt_profile"] is NSNull && server.media["stt_hold"] is NSNull && data.failures["transcription"] == nil)
    // Only OpenAI's own address can make images or transcribe.
    let profiles = try #require(model.config?.modelProfiles)
    #expect(profiles.filter(ModelNames.openAIOfficial).map(\.id) == ["normal_primary"])
}

@Test @MainActor func changingAModelsAddressChecksItsSavedKeyAgain() async throws {
    let server = ConnectBackend()
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }
    await data.saveKey("sk-synthetic-backup", profile: "normal_backup", model: model)
    let probes = server.calls("models.probe").count

    await data.saveEndpoint("normal_backup", baseURL: " https://llm.example/v1 ", modelId: "m-2", model: model)

    #expect(server.profileEntry("normal_backup")?["base_url"] as? String == "https://llm.example/v1")
    #expect(server.profileEntry("normal_backup")?["model"] as? String == "m-2")
    #expect(server.calls("models.probe").count == probes + 1)
}

// MARK: - Spending

@Test @MainActor func theMonthlyLimitIsTypedInWholeDollarsAndStoredInMicroDollars() async throws {
    let server = ConnectBackend()
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }
    #expect(data.budget?.monthlyLimit == 20_000_000 && BudgetSummary.dollarField(data.budget?.monthlyLimit) == "20")

    #expect(await data.saveMonthlyLimit("35", model: model))
    #expect((server.budget["model"] as? [String: Any])?["monthly_limit"] as? Int == 35_000_000)
    // Everything else in the policy document is kept as stored.
    #expect((server.budget["x"] as? [String: Any])?["daily_limit"] as? Int == 200 && server.budget["openai_credit"] != nil)

    #expect(await data.saveMonthlyLimit("", model: model))
    #expect((server.budget["model"] as? [String: Any])?["monthly_limit"] is NSNull && data.budget?.monthlyLimit == nil)

    let saves = server.calls("budget.save").count
    #expect(!(await data.saveMonthlyLimit("3.5", model: model)))
    #expect(data.failures["budget.monthly"]?.code == "invalid_amount" && server.calls("budget.save").count == saves)
    #expect(FailureCopy.table["invalid_amount"] != nil)

    #expect(await data.saveDailyReads("150", model: model))
    #expect((server.budget["x"] as? [String: Any])?["daily_limit"] as? Int == 150)
}

@Test func spendingIsReadForThisPeriodWithAPartPerOperation() throws {
    let now = Date(timeIntervalSince1970: 1_793_000_000)
    let start = ISO8601DateFormatter().string(from: now.addingTimeInterval(-86_400))
    let end = ISO8601DateFormatter().string(from: now.addingTimeInterval(86_400))
    let reply: [String: Any] = [
        "revision": 1,
        "document": [
            "model": ["monthly_limit": 20_000_000, "image_limit": 5_000_000, "provider_limits": ["openai": 2_000_000, "mimo": NSNull()]],
            "x": ["daily_limit": NSNull(), "partition_limits": ["normal": NSNull(), "adult": 50], "account_limits": ["acct1": 20]],
        ],
        "report": ["periods": [
            ["meter": "model", "start": start, "end": end, "known_settled": 3_100_000, "held": 320_000, "unpriced": 2,
             "operations": ["text": ["known_settled": 3_100_000, "held": 0], "image": ["known_settled": 0, "held": 320_000]],
             "scopes": ["total": ["limit": 20_000_000, "used": 3_420_000], "image": ["limit": 5_000_000, "used": 320_000],
                        "providers": ["openai": ["limit": 2_000_000, "used": 3_420_000]]]],
            ["meter": "x", "start": start, "end": end, "known_settled": 84, "held": 0, "unpriced": 0,
             "scopes": ["total": ["limit": NSNull(), "used": 84], "partitions": ["adult": ["limit": 50, "used": 10]], "accounts": [String: Any]()]],
        ]],
    ]
    let summary = try BudgetSummary(JSONSerialization.data(withJSONObject: reply), now: now)

    #expect(dollars(summary.used) == "$3.42" && summary.unpriced == 2 && summary.readsToday == 84 && summary.dailyReads == nil)
    #expect(summary.parts.map(\.operation) == ["text", "image"] && summary.parts.map { dollars($0.amount) } == ["$3.10", "$0.32"])
    #expect(summary.limits.map(\.id) == ["image", "provider.openai", "partition.adult", "account.acct1"])
    #expect(summary.limits[1].used >= summary.limits[1].value)
}

@Test @MainActor func anOtherLimitIsClearedWithoutTouchingTheRest() async throws {
    let server = ConnectBackend()
    var money = server.budget["model"] as! [String: Any]
    money["image_limit"] = 5_000_000
    money["provider_limits"] = ["openai": 2_000_000]
    server.budget["model"] = money
    var reads = server.budget["x"] as! [String: Any]
    reads["partition_limits"] = ["normal": NSNull(), "adult": 50]
    server.budget["x"] = reads
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }
    let limits = try #require(data.budget?.limits)
    #expect(limits.map(\.id) == ["image", "provider.openai", "partition.adult"])

    #expect(await data.clear(limits[1], model: model))
    #expect(((server.budget["model"] as? [String: Any])?["provider_limits"] as? [String: Any])?.isEmpty == true)
    #expect(await data.clear(try #require(data.budget?.limits.first { $0.id == "partition.adult" }), model: model))
    let partitions = try #require((server.budget["x"] as? [String: Any])?["partition_limits"] as? [String: Any])
    #expect(partitions["adult"] is NSNull && partitions["normal"] is NSNull)
    #expect(data.budget?.limits.map(\.id) == ["image"])
    #expect((server.budget["model"] as? [String: Any])?["image_limit"] as? Int == 5_000_000)
}

// MARK: - X and key tails

@Test @MainActor func theXKeyIsSavedAndNamedByItsLastFourCharacters() async throws {
    let server = ConnectBackend()
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    await data.saveXKey(" x-synthetic-Rk2m ", model: model)

    let call = try #require(server.calls("credentials.set").last)
    #expect(call["kind"] as? String == "x_api" && call["id"] as? String == "x" && call["value"] as? String == "x-synthetic-Rk2m")
    let ref = try #require(model.config?.xApi?.credentialRef)
    #expect(data.tail(ref) == "Rk2m" && data.credentialState(ref) == "available" && data.failures["x"] == nil)
}

@Test @MainActor func keyTailsMapEachReferenceAndShortKeysHaveNone() async throws {
    let server = ConnectBackend(bots: [ConnectBackend.bot("b1")])
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }
    await data.saveKey("short", profile: "normal_backup", model: model)
    await data.saveKey("sk-synthetic-ABCD", profile: "adult_primary", model: model)

    let profiles = try #require(model.config?.modelProfiles)
    let backup = try #require(profiles.first { $0.id == "normal_backup" }?.credentialRef)
    let adult = try #require(profiles.first { $0.id == "adult_primary" }?.credentialRef)
    #expect(data.tail(adult) == "ABCD" && data.tail(backup) == nil && data.tail(nil) == nil)
    #expect(data.tails.values.allSatisfy { $0.count <= 4 })
    // A Bot's reference with no stored value reads as missing.
    #expect(data.credentialState("keychain:b1") == "missing")
}

// MARK: - Vocabulary and contract

@Test func connectCopyHasAllLanguagesAndAvoidsInternalWords() {
    let banned = ["hold", "微美元", "µ", "cycle", "价格表", "price table", "probe", "revision", "subscription", "credential", "profile"]
    for words in L10n.Connect.all {
        for language in AppLanguage.allCases {
            let text = words(language)
            #expect(!text.trimmingCharacters(in: .whitespaces).isEmpty)
            for word in banned { #expect(!text.lowercased().contains(word), "\(word) in \(text)") }
        }
    }
    #expect(Set(L10n.Connect.all.map(\.zh)).count > 100)
    #expect(dollars(3_420_000) == "$3.42" && dollars(0) == "$0.00")
}

@Test func everyOperationTheAppSendsExistsInTheBackend() throws {
    let control = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("src/newspaw/control.py")
    let source = try String(contentsOf: control, encoding: .utf8)
    for operation in Operation.allCases {
        #expect(source.contains("\"\(operation.rawValue)\": ("), "\(operation.rawValue) is not a backend operation")
    }
}

@Test func relativeTimesSayTodayYesterdayOrTheDate() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))!
    let morning = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 8, minute: 12))!
    let evening = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 20, minute: 28))!
    let earlier = calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 9))!
    #expect(Stamp.relative(morning, now: now, .zhHans, calendar: calendar) == "今天 08:12")
    #expect(Stamp.relative(evening, now: now, .en, calendar: calendar) == "yesterday 20:28")
    #expect(Stamp.relative(earlier, now: now, .ja, calendar: calendar) == "11-08")
}

// MARK: - Review regressions

@Test @MainActor func aKeyCheckIsWaitedForLongerThanTheProviderTimeout() {
    // providers.py gives a model call 90 seconds; giving up first leaves a check still running.
    #expect(KeyChecks().probeLimit > .seconds(90))
}

@Test @MainActor func aStaleWaitingNoteGivesWayAndAnUnknownCheckIsNotRepeatedUnconfirmed() async throws {
    let server = ConnectBackend()
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }
    server.checks["normal_primary"] = [["state": "pending", "status": "pending"]]
    data.keys.probeLimit = .milliseconds(30)
    await data.saveKey("sk-synthetic-slow", profile: "normal_primary", model: model)
    #expect(data.keys.failures["normal_primary"]?.code == "probe_pending")

    // The provider never answered: the backend records an unknown outcome.
    server.checks["normal_primary"] = [["state": "outcome_unknown", "status": "outcome_unknown", "error_kind": "outcome_unknown"]]
    await data.load(model: model)
    #expect(data.keys.failures["normal_primary"] == nil)
    #expect(KeyStatus.of(credential: "available", probe: data.keys.probes["normal_primary"], health: nil, working: false).action == .confirmRecheck)

    // A paid check of an unknown result runs only once the owner confirms it.
    await data.recheck("normal_primary", model: model)
    #expect(server.calls("models.probe").isEmpty)
    await data.recheck("normal_primary", model: model, confirmed: true)
    #expect(server.calls("models.probe").count == 1)
}

@Test @MainActor func aRecheckThatOutlastsTheSocketReadsTheRunningCheckBack() async throws {
    let server = ConnectBackend()
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }
    await data.saveKey("sk-synthetic-7Qx2", profile: "normal_primary", model: model)
    server.probeOutlastsSocket = ["state": "failed", "status": "failed", "error_kind": "rate_limited"]

    await data.recheck("normal_primary", model: model)

    #expect(data.keys.failures["normal_primary"] == nil)
    #expect(data.keys.probes["normal_primary"]?.errorKind == "rate_limited")
    // Followed by its own probe id: one check, never a second paid one.
    let ids = server.calls("models.probe").compactMap { $0["probe_id"] as? String }
    #expect(ids.count == 3 && Set(ids).count == 1)
}

@Test @MainActor func aPausedBotThatLostItsPairingOffersPairingAgain() async throws {
    let server = ConnectBackend(bots: [ConnectBackend.bot("b1")])
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }
    await data.act("b1", "pause", model: model)
    #expect(BotMenu.canResume(model.bots[0]) && !BotMenu.canPause(model.bots[0]))
    await data.act("b1", "unbind", model: model)

    let bot = model.bots[0]
    #expect(bot.paused && !bot.paired)
    #expect(BotState(bot) == .unpaired)
    #expect(!BotMenu.canResume(bot) && !BotMenu.canPause(bot))

    // A pairing code clears the pause (registry.pair_code).
    await data.newCode("b1", model: model)
    #expect(data.pairing("b1")?.pair != nil && server.registry["b1"]?.paused == false)
}

@Test func anEmptyTelegramUsernameReadsAsNone() throws {
    let bot: BotStatus = try BackendRPC.decode(Data(#"{"id":"b","name":"News","verified":false,"paired":false,"paused":false,"status":"unverified","username":""}"#.utf8))
    #expect(bot.username == nil)
}

@Test func aTestMessageThatWasNeverSentOffersToSendAgain() {
    let test = TestSend(requestId: "test_1", generation: 3, state: "not_started", reason: nil)
    #expect(TestDisplay.of(test, stillUnknown: false) == .notSent)
}

@Test func savingAFirstKeyShowsItIsBeingChecked() {
    #expect(KeyStatus.of(credential: nil, probe: nil, health: nil, working: true) == .checking)
}

@Test @MainActor func theFirstRunWindowAsksBeforeRepeatingAnUnknownCheckLikeThisPage() async throws {
    let server = ConnectBackend()
    let (model, _, cleanup) = try await connected(server)
    defer { cleanup() }
    let setup = OnboardingData()
    server.checks["normal_primary"] = [["state": "outcome_unknown", "status": "outcome_unknown", "error_kind": "outcome_unknown"]]
    await setup.keys.load("normal_primary", model: model)
    #expect(setup.keys.needsConfirmation("normal_primary"))

    await setup.recheck("normal_primary", model: model)
    #expect(server.calls("models.probe").isEmpty)
    await setup.recheck("normal_primary", model: model, confirmed: true)
    #expect(server.calls("models.probe").count == 1)
}

// MARK: - External review regressions

@Test @MainActor func aFailedResultCheckAsksAboutTheSameMessageInsteadOfSendingAnother() async throws {
    let server = ConnectBackend(bots: [ConnectBackend.bot("b1")])
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }
    server.testOutcome = ("outcome_unknown", "outcome_unknown")
    await data.sendTest("b1", model: model)
    let unknown = try #require(data.tests["b1"])

    server.dropNextTestStatus = true
    await data.checkTest("b1", model: model)
    #expect(data.failures["test.b1"]?.code == "backend_unreachable")

    // While it is unknown whether the message arrived, retrying reads the same receipt again.
    await data.retryTest("b1", model: model)
    #expect(server.calls("bots.test_send").count == 1)
    #expect(server.calls("bots.test_status").map { $0["request_id"] as? String } == [unknown.requestId, unknown.requestId])

    // After a definite failure, retrying sends a new message.
    server.testOutcome = ("failed", "forbidden")
    await data.sendTest("b1", model: model)
    await data.retryTest("b1", model: model)
    #expect(server.calls("bots.test_send").count == 3)
}

@Test @MainActor func aFailedImageCheckIsCheckedAgainWithANewProbe() async throws {
    let server = ConnectBackend()
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }
    await data.saveKey("sk-synthetic-image", profile: "normal_primary", model: model)
    // The automatic check (its id is bound to the key's generation) failed.
    server.capabilityStates["normal_primary"] = ["image": ["state": "failed", "status": "failed", "error_kind": "rate_limited"]]
    await data.setNewspaper(true, profile: "normal_primary", model: model)
    server.capabilityStates["normal_primary"]?["vision"] = ["state": "verified", "status": "verified"]
    await data.load(model: model)
    let checks = data.extraChecks(newspaper: true)
    guard case .failed(CapabilityCheck(profile: "normal_primary", capability: "image"), _) =
        ExtraStatus.of(on: true, checks: checks, states: data.keys.states, working: data.keys.working) else {
        Issue.record("the failed image check is not shown"); return
    }

    await data.recheck("normal_primary", model: model, capability: "image")

    let probe = try #require(server.calls("models.probe").last)
    #expect(probe["capability"] as? String == "image" && !(probe["probe_id"] as? String ?? "auto.").hasPrefix("auto."))
    #expect(ExtraStatus.of(on: true, checks: data.extraChecks(newspaper: true), states: data.keys.states, working: data.keys.working) == .usable)

    // An unknown capability result is not paid for again without confirmation.
    server.capabilityStates["normal_primary"]?["image"] = ["state": "outcome_unknown", "status": "outcome_unknown", "error_kind": "outcome_unknown"]
    await data.load(model: model)
    let calls = server.calls("models.probe").count
    await data.recheck("normal_primary", model: model, capability: "image")
    #expect(server.calls("models.probe").count == calls)
    await data.recheck("normal_primary", model: model, capability: "image", confirmed: true)
    #expect(server.calls("models.probe").count == calls + 1)
}

@Test @MainActor func theNewspaperAlsoNeedsItsVisionCheck() async throws {
    let server = ConnectBackend()
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }
    await data.setNewspaper(true, profile: "normal_primary", model: model)
    server.capabilityStates["normal_primary"] = [
        "image": ["state": "verified", "status": "verified"],
        "vision": ["state": "failed", "status": "failed", "error_kind": "model_unavailable"],
    ]
    await data.load(model: model)

    let status = ExtraStatus.of(on: true, checks: data.extraChecks(newspaper: true), states: data.keys.states, working: data.keys.working)
    guard case let .failed(check, state) = status else { Issue.record("vision failure not shown: \(status)"); return }
    #expect(check == CapabilityCheck(profile: "normal_primary", capability: "vision") && state.errorKind == "model_unavailable")
}

@Test @MainActor func cancellingWhileTheBotIsBeingCreatedLeavesNoBotBehind() async throws {
    let server = ConnectBackend()
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }
    server.configSaveDelay = .milliseconds(80)
    data.startAdding()
    let adding = try #require(data.adding)

    let connecting = Task { await adding.connect(token: "123456:synthetic-token", model: model) }
    try await Task.sleep(for: .milliseconds(20))
    #expect(adding.botId == nil && adding.working)
    await data.cancelAdding(model: model)
    await connecting.value
    await model.refresh()

    #expect(data.adding == nil && server.bots.isEmpty && model.bots.isEmpty)
    #expect(server.calls("bots.pair_code").isEmpty && adding.pair == nil)
}
