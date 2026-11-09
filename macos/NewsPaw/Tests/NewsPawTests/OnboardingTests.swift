import Foundation
import Testing

@testable import NewsPaw

/// An in-memory backend for the first-run window: config document, one Bot's lifecycle,
/// key checks, and the digest operations the last step uses.
@MainActor
private final class SetupBackend {
    var revision = 1
    var document: [String: Any]
    var verified = false
    var paired = false
    var generation = 0
    /// bots.status reads before the owner "sends" the pairing code.
    var pairAfterReads = 2
    var probe: [String: Any] = ["state": "pending"]
    var probeReadsBeforeResult = 1
    var probeResult: [String: Any] = ["status": "verified", "state": "verified", "reported_model": "gpt-6-luna"]
    /// The Telegram error `bots.verify` records for a bad token (the real backend never refuses
    /// the token in `credentials.set`; verify reports the problem in the Bot's status).
    var tokenProblem: String?
    var exhaustAfterReads: Int?
    var sendNowRefusal: String?
    var readiness: [String: Any] = ["complete": false, "next": "bot", "scheduling_enabled": true, "steps": []]
    private(set) var requests: [[String: Any]] = []
    private var statusReads = 0
    private var probeReads = 0

    init() {
        document = [
            "ui_locale": "en", "news_output_locale": "en", "owner_id": NSNull(),
            "categories": [["id": "world", "name": "W", "partition": "normal"], ["id": "japan", "name": "J", "partition": "normal"]],
            "subscriptions": [
                ["id": "sub_world", "name": "W", "category_id": "world", "timezone": "Asia/Tokyo", "enabled": false, "times": ["08:00"], "bot_ids": [], "source_ids": []],
                ["id": "sub_japan", "name": "J", "category_id": "japan", "timezone": "Asia/Tokyo", "enabled": false, "times": ["08:30"], "bot_ids": [], "source_ids": []],
            ],
            "sources": [], "accounts": [], "bots": [],
            "model_profiles": [
                ["id": "normal_primary", "partition": "normal", "role": "primary", "provider": "mimo", "base_url": "https://api.xiaomimimo.com/v1", "model": "mimo-v2.6-flash", "credential_ref": NSNull(), "capabilities": []],
            ],
        ]
    }

    func calls(_ op: String) -> [[String: Any]] { requests.filter { $0["op"] as? String == op } }
    var bots: [[String: Any]] { document["bots"] as? [[String: Any]] ?? [] }
    func subscription(_ id: String) -> [String: Any]? {
        (document["subscriptions"] as? [[String: Any]])?.first { $0["id"] as? String == id }
    }

    /// The next models.probe connection fails like a socket timeout (the backend keeps checking).
    var probeConnectionDrops = false
    /// Every request fails as if the backend were gone; `dropAfterSave` turns it on after the
    /// first successful subscriptions.save.
    var unreachable = false
    var dropAfterSave = false
    /// How many calls for one probe id answer "pending" before its result.
    var probePendingCalls = 0
    private var probeCalls: [String: Int] = [:]

    var client: BackendClient {
        BackendClient { [unowned self] body, _ in
            let isProbe = (try JSONSerialization.jsonObject(with: body) as! [String: Any])["op"] as? String == "models.probe"
            let drop = await MainActor.run { () -> Bool in
                guard isProbe, self.probeConnectionDrops else { return false }
                self.probeConnectionDrops = false
                return true
            }
            if drop { throw SocketFailure.timeout }
            if await MainActor.run(body: { self.unreachable }) { throw SocketFailure.disconnected }
            let request = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            return await MainActor.run { self.answer(request) }
        }
    }

    private func ok(_ result: Any) -> Data { try! JSONSerialization.data(withJSONObject: ["ok": true, "result": result]) }
    private func refuse(_ code: String, _ domain: String = "setup") -> Data {
        try! JSONSerialization.data(withJSONObject: ["ok": false, "error": code, "error_detail": ["code": code, "domain": domain, "retryable": false]])
    }

    private var exhausted = false
    private var botStatus: [String: Any] {
        let status = exhausted ? "pair_attempts_exhausted" : paired ? "paired" : verified ? "awaiting_pair" : (tokenProblem ?? "unverified")
        return ["id": bots.first?["id"] ?? "bot", "name": "Telegram", "verified": verified, "paired": paired, "paused": false,
                "generation": generation, "status": status, "username": verified ? "np_bot" : NSNull()]
    }

    /// What the real route and preview check: a Bot, and a main model key that passed its check
    /// (the backup is optional and never blocks).
    private func blockers(_ draft: [String: Any]) -> [String] {
        var codes: [String] = []
        if (draft["bot_ids"] as? [String] ?? []).isEmpty { codes.append("no_ready_bot") }
        if probe["state"] as? String != "verified" { codes.append("primary_unverified") }
        return codes
    }

    private func answer(_ request: [String: Any]) -> Data {
        requests.append(request)
        let op = request["op"] as! String
        let stale = (request["revision"] as? Int).map { $0 != revision } ?? false
        switch op {
        case "service.status": return ok(["protocol_version": 1, "state": "running", "operations": ["setup.readiness"]])
        case "setup.readiness": return ok(readiness)
        case "config.get": return ok(["revision": revision, "document": document])
        case "config.save":
            if stale { return refuse("config_conflict") }
            document = request["document"] as! [String: Any]
            revision += 1
            return ok(["revision": revision])
        case "bots.list": return ok(bots.isEmpty ? [] : [botStatus])
        case "credentials.set":
            if stale { return refuse("config_conflict") }
            revision += 1
            // The earlier key's result reads as stale until the new key's check finishes.
            if request["kind"] as? String == "model_profiles" { probeReads = 0; probe = ["state": "stale", "status": "failed", "error_kind": "invalid_credential"] }
            return ok(["revision": revision])
        case "bots.status":
            statusReads += 1
            if let limit = exhaustAfterReads, verified, statusReads > limit { exhausted = true }
            if !exhausted, verified, generation >= 2, statusReads > pairAfterReads { paired = true }
            return ok(botStatus)
        case "bots.verify":
            if request["generation"] as? Int != generation { return refuse("binding_changed", "bots") }
            verified = tokenProblem == nil
            generation += 1
            return ok(botStatus)
        case "bots.pair_code":
            generation += 1
            statusReads = 0
            return ok(["code": "AbC_123", "expires_at": Date().timeIntervalSince1970 + 600, "max_attempts": 5])
        case "models.status":
            probeReads += 1
            if probeReads > probeReadsBeforeResult { probe = probeResult }
            return ok(["text": probe])
        case "models.probe":
            // The same probe id returns that check's record: pending until it finishes.
            let id = request["probe_id"] as! String
            probeCalls[id, default: 0] += 1
            let record: [String: Any] = probeCalls[id]! > probePendingCalls ? probeResult : ["status": "pending"]
            if record["status"] as? String != "pending" { probe = probeResult }
            return ok(record.filter { $0.key != "state" })
        case "schedule.status": return ok(["revision": 1, "settings": ["enabled": true], "activated_at": NSNull(), "occurrences": []])
        case "newspaper.policy": return ok(["revision": 1, "settings": ["enabled": false, "generation_profile": NSNull()]])
        case "sources.catalog", "sources.list": return ok([])
        case "subscriptions.save":
            if stale { return refuse("config_conflict") }
            var draft = request["draft"] as! [String: Any]
            if request["enable"] as? Bool == true, !blockers(draft).isEmpty { return refuse("subscription_not_ready", "subscriptions") }
            draft["enabled"] = request["enable"] as? Bool ?? false
            var list = document["subscriptions"] as! [[String: Any]]
            if let index = list.firstIndex(where: { $0["id"] as? String == draft["id"] as? String }) { list[index] = draft }
            document["subscriptions"] = list
            revision += 1
            if dropAfterSave { unreachable = true }
            return ok(["revision": revision])
        case "subscriptions.preview":
            let draft = request["draft"] as! [String: Any]
            return ok(["blockers": blockers(draft), "bots": draft["bot_ids"] ?? [], "sources": []])
        case "subscriptions.send_now":
            if let code = sendNowRefusal { return refuse(code, "subscriptions") }
            return ok(["job_id": "job1"])
        default: return refuse("unknown_operation")
        }
    }
}

@MainActor
private func connected(_ server: SetupBackend) async throws -> (AppModel, OnboardingData, () -> Void) {
    let name = "NewsPawTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    let model = AppModel(client: server.client, defaults: defaults)
    await model.refresh()
    #expect(model.connection == .connected)
    let data = OnboardingData()
    data.pollInterval = .milliseconds(5)
    return (model, data, { defaults.removePersistentDomain(forName: name) })
}

@Test @MainActor func aPastedTokenIsCheckedAndPairedWithoutLeavingTheWindow() async throws {
    let server = SetupBackend()
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    await data.connect(token: " 123:abc \n", model: model)

    // A Bot entry was created, its token stored, checked and a pairing code issued.
    let bot = try #require(server.bots.first)
    #expect((bot["id"] as? String)?.hasPrefix("bot_") == true && bot["credential_ref"] is NSNull)
    #expect(server.calls("credentials.set").first?["value"] as? String == "123:abc")
    #expect(data.bot?.verified == true && data.pair?.code == "AbC_123" && data.failures["bot"] == nil)

    await data.waitForPairing(model: model)
    #expect(data.botReady && data.pairedAt != nil && data.pair == nil)
}

@Test @MainActor func aRefusedTokenSaysWhyInTheStep() async throws {
    let server = SetupBackend()
    server.tokenProblem = "invalid_token"
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    await data.connect(token: "wrong", model: model)

    #expect(data.failures["bot"]?.code == "invalid_token")
    #expect(data.pair == nil && !data.botReady)
    #expect(FailureCopy.entry(for: try #require(data.failures["bot"])).action != nil)
}

@Test @MainActor func waitingStopsWhenTheCodeExpiresAndANewCodeCanBeMade() async throws {
    let server = SetupBackend()
    server.pairAfterReads = 1_000
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }
    await data.connect(token: "123:abc", model: model)
    let first = try #require(data.pair)

    await data.waitForPairing(model: model, now: { first.expires.addingTimeInterval(1) })
    #expect(!data.botReady && data.pair == first)

    await data.newCode(model: model)
    #expect(server.calls("bots.pair_code").count == 2 && data.failures["bot"] == nil)
}

@Test @MainActor func savingTheMainKeySetsTheChosenModelAndReadsItsCheck() async throws {
    let server = SetupBackend()
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    await data.saveKey("sk-test", profile: "normal_primary", choice: .luna, model: model)

    let profile = try #require((server.document["model_profiles"] as? [[String: Any]])?.first)
    #expect(profile["provider"] as? String == "openai" && profile["model"] as? String == "gpt-6-luna")
    #expect(profile["base_url"] as? String == "https://api.openai.com/v1")
    #expect(server.calls("credentials.set").last?["kind"] as? String == "model_profiles")
    #expect(data.keyReady("normal_primary") && data.probes["normal_primary"]?.reportedModel == "gpt-6-luna")
}

@Test @MainActor func aFailedKeyCheckShowsItsReason() async throws {
    let server = SetupBackend()
    server.probeResult = ["status": "failed", "state": "failed", "error_kind": "invalid_credential"]
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    await data.saveKey("sk-bad", profile: "normal_primary", choice: nil, model: model)

    #expect(!data.keyReady("normal_primary") && data.probes["normal_primary"]?.errorKind == "invalid_credential")
    #expect(FailureCopy.table["invalid_credential"] != nil)
    // Check again reads a fresh result.
    server.probeResult = ["status": "verified", "state": "verified", "reported_model": "mimo-v2.6-flash"]
    await data.recheck("normal_primary", model: model)
    #expect(data.keyReady("normal_primary"))
}

@Test @MainActor func aKeyCheckWithoutAnOutcomeIsReportedInsteadOfWaitingForever() async throws {
    let server = SetupBackend()
    server.probeReadsBeforeResult = 1_000_000
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }
    data.probeLimit = .milliseconds(30)

    await data.saveKey("sk", profile: "normal_primary", choice: nil, model: model)

    #expect(data.failures["normal_primary"]?.code == "probe_pending")
}

@Test @MainActor func finishingTurnsOnTheChosenDigestsAndSendsATrialOfTheFirst() async throws {
    let server = SetupBackend()
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }
    await data.connect(token: "123:abc", model: model)
    await data.waitForPairing(model: model)
    await model.refresh()
    // The fake reports the Bot paired; the config entry mirrors it for usableBots.
    server.document["bots"] = server.bots.map { var bot = $0; bot["paired"] = true; bot["verified"] = true; return bot }
    await model.refresh()
    await data.saveKey("sk", profile: "normal_primary", choice: nil, model: model)

    #expect(await data.finish(sendTrial: true, model: model))

    let subscriptions = server.document["subscriptions"] as! [[String: Any]]
    #expect(subscriptions.allSatisfy { $0["enabled"] as? Bool == true && ($0["bot_ids"] as? [String])?.count == 1 })
    #expect(server.calls("subscriptions.send_now").map { $0["subscription_id"] as? String } == ["sub_world"])
    #expect(data.sentTrial)
}

@Test @MainActor func aDigestThatCannotTurnOnStaysWithItsReason() async throws {
    let server = SetupBackend()
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    #expect(!(await data.finish(sendTrial: true, model: model)))

    #expect(data.failures["sub_world"]?.code == "subscription_not_ready")
    #expect(server.calls("subscriptions.send_now").isEmpty)
}

@Test @MainActor func theWindowOffersItselfOnlyUntilSeen() async throws {
    let server = SetupBackend()
    let (model, _, cleanup) = try await connected(server)
    defer { cleanup() }
    #expect(model.shouldOfferOnboarding)
    model.onboardingSeen = true
    #expect(!model.shouldOfferOnboarding)
    model.onboardingSeen = false
    server.readiness["complete"] = true
    await model.refresh()
    #expect(!model.shouldOfferOnboarding)
}

@Test func onboardingCopyHasAllLanguages() {
    for words in L10n.Onboarding.all {
        for language in AppLanguage.allCases {
            #expect(!words(language).isEmpty)
        }
    }
}


@Test @MainActor func aVerifiedButUnpairedBotCanGetANewCodeAfterReopening() async throws {
    let server = SetupBackend()
    server.pairAfterReads = 1_000
    let (model, first, cleanup) = try await connected(server)
    defer { cleanup() }
    await first.connect(token: "123:abc", model: model)
    await model.refresh()

    // The window was closed before pairing; a new visit starts from the stored Bot.
    let reopened = OnboardingData()
    await reopened.start(model: model)
    #expect(reopened.bot?.verified == true && !reopened.botReady && reopened.pair == nil && reopened.pairedAt == nil)
    await reopened.newCode(model: model)
    #expect(reopened.pair != nil && reopened.failures["bot"] == nil)
}

@Test @MainActor func waitingStopsWithTheReasonWhenPairingCanNoLongerSucceed() async throws {
    let server = SetupBackend()
    server.pairAfterReads = 1_000
    server.exhaustAfterReads = 1
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }
    await data.connect(token: "123:abc", model: model)

    await data.waitForPairing(model: model)

    #expect(data.failures["bot"]?.code == "pair_attempts_exhausted" && data.pair == nil && !data.botReady)
}

@Test @MainActor func aDigestThatCannotTurnOnListsWhatBlocksIt() async throws {
    let server = SetupBackend()
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }
    server.document["bots"] = [["id": "bot_x", "name": "T", "credential_ref": NSNull(), "telegram_id": NSNull(), "chat_id": NSNull(), "verified": true, "paired": true, "adult_allowed": false]]
    server.verified = true
    server.paired = true
    await model.refresh()

    #expect(!(await data.finish(sendTrial: false, model: model)))

    #expect(data.failures["sub_world"]?.code == "subscription_not_ready")
    #expect(data.blockers["sub_world"] == ["primary_unverified"])
    #expect(FailureCopy.table["primary_unverified"] != nil)
}

@Test @MainActor func aFailedTrialSendKeepsTheWindowWithItsReason() async throws {
    let server = SetupBackend()
    server.sendNowRefusal = "scheduling_paused"
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }
    server.document["bots"] = [["id": "bot_x", "name": "T", "credential_ref": NSNull(), "telegram_id": NSNull(), "chat_id": NSNull(), "verified": true, "paired": true, "adult_allowed": false]]
    server.verified = true
    server.paired = true
    await model.refresh()
    await data.saveKey("sk", profile: "normal_primary", choice: nil, model: model)

    #expect(!(await data.finish(sendTrial: true, model: model)))

    #expect(data.failures["trial"]?.code == "scheduling_paused" && !data.sentTrial)
}

@Test func botProblemsUseTheirOwnCopy() {
    #expect(OnboardingData.botProblem("invalid_token") == "invalid_token")
    #expect(OnboardingData.botProblem("token_revoked") == "token_revoked")
    #expect(OnboardingData.botProblem("unverified") == "bot_not_verified")
    #expect(OnboardingData.botProblem(nil) == "bot_not_verified")
    for code in ["authentication_failed", "model_unavailable", "permission_denied", "provider_failed", "protocol_error", "invalid_probe_output"] {
        #expect(FailureCopy.entry(for: BackendError(code: code, domain: "models")).action != nil, "no retry for \(code)")
    }
}


@Test @MainActor func reopeningWhileASavedKeyIsStillCheckingWaitsForItsResult() async throws {
    let server = SetupBackend()
    var profiles = server.document["model_profiles"] as! [[String: Any]]
    profiles[0]["credential_ref"] = "keychain:00000000-0000-0000-0000-000000000001"
    server.document["model_profiles"] = profiles
    server.probe = ["state": "stale"]
    server.probeReadsBeforeResult = 2
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }

    await data.start(model: model)

    #expect(data.keyReady("normal_primary"))
}

@Test @MainActor func aRecheckWhoseConnectionDropsReadsTheBackendsResult() async throws {
    let server = SetupBackend()
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }
    server.probeConnectionDrops = true
    // An earlier check failed; the recheck still running must not be confused with it.
    server.probe = ["state": "failed", "status": "failed", "error_kind": "authentication_failed"]
    server.probePendingCalls = 2

    await data.recheck("normal_primary", model: model)

    #expect(data.failures["normal_primary"] == nil && data.keyReady("normal_primary"))
}


@Test func aCustomGatewayServingAPresetModelStaysCustom() {
    #expect(ModelChoice.matching(provider: "openai", baseURL: "https://api.openai.com/v1/", model: "gpt-6-luna") == .luna)
    #expect(ModelChoice.matching(provider: "openai", baseURL: "https://gateway.example/v1", model: "gpt-6-luna") == .custom)
    #expect(ModelChoice.matching(provider: "mimo", baseURL: "https://api.xiaomimimo.com/v1", model: "mimo-v2.6-flash") == .mimo)
}


@Test @MainActor func finishingWhileTheBackendDisappearsReportsItInsteadOfClosing() async throws {
    let server = SetupBackend()
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }
    server.document["bots"] = [["id": "bot_x", "name": "T", "credential_ref": NSNull(), "telegram_id": NSNull(), "chat_id": NSNull(), "verified": true, "paired": true, "adult_allowed": false]]
    server.verified = true
    server.paired = true
    await model.refresh()
    await data.saveKey("sk", profile: "normal_primary", choice: nil, model: model)
    // The first digest turns on, then the backend goes away before the second.
    server.dropAfterSave = true

    #expect(!(await data.finish(sendTrial: true, model: model)))

    #expect(server.subscription("sub_world")?["enabled"] as? Bool == true)
    #expect(data.failures["sub_japan"]?.code == "backend_unreachable")
    #expect(!data.sentTrial)
}

@Test @MainActor func finishingWithNoConfigurationReportsIt() async throws {
    let server = SetupBackend()
    let (model, data, cleanup) = try await connected(server)
    defer { cleanup() }
    server.unreachable = true
    await model.refresh()
    #expect(!(await data.finish(sendTrial: false, model: model)))
    #expect(data.failures["trial"]?.code == "backend_unreachable")
}
