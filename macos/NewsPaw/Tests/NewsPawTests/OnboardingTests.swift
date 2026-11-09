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
    var refuseToken = false
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

    var client: BackendClient {
        BackendClient { [unowned self] body, _ in
            let request = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            return await MainActor.run { self.answer(request) }
        }
    }

    private func ok(_ result: Any) -> Data { try! JSONSerialization.data(withJSONObject: ["ok": true, "result": result]) }
    private func refuse(_ code: String, _ domain: String = "setup") -> Data {
        try! JSONSerialization.data(withJSONObject: ["ok": false, "error": code, "error_detail": ["code": code, "domain": domain, "retryable": false]])
    }

    private var botStatus: [String: Any] {
        ["id": bots.first?["id"] ?? "bot", "name": "Telegram", "verified": verified, "paired": paired, "paused": false,
         "generation": generation, "status": paired ? "paired" : verified ? "awaiting_pair" : "unverified", "username": verified ? "np_bot" : NSNull()]
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
            if request["kind"] as? String == "bots", refuseToken { return refuse("invalid_token", "bots") }
            revision += 1
            // The earlier key's result reads as stale until the new key's check finishes.
            if request["kind"] as? String == "model_profiles" { probeReads = 0; probe = ["state": "stale", "status": "failed", "error_kind": "invalid_credential"] }
            return ok(["revision": revision])
        case "bots.status":
            statusReads += 1
            if verified, generation >= 2, statusReads > pairAfterReads { paired = true }
            return ok(botStatus)
        case "bots.verify":
            if request["generation"] as? Int != generation { return refuse("binding_changed", "bots") }
            verified = true
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
            probe = probeResult
            return ok(probeResult.filter { $0.key != "state" })
        case "schedule.status": return ok(["revision": 1, "settings": ["enabled": true], "activated_at": NSNull(), "occurrences": []])
        case "newspaper.policy": return ok(["revision": 1, "settings": ["enabled": false, "generation_profile": NSNull()]])
        case "sources.catalog", "sources.list": return ok([])
        case "subscriptions.save":
            if stale { return refuse("config_conflict") }
            var draft = request["draft"] as! [String: Any]
            if request["enable"] as? Bool == true, (draft["bot_ids"] as? [String] ?? []).isEmpty { return refuse("subscription_not_ready", "subscriptions") }
            draft["enabled"] = request["enable"] as? Bool ?? false
            var list = document["subscriptions"] as! [[String: Any]]
            if let index = list.firstIndex(where: { $0["id"] as? String == draft["id"] as? String }) { list[index] = draft }
            document["subscriptions"] = list
            revision += 1
            return ok(["revision": revision])
        case "subscriptions.preview": return ok(["blockers": ["no_ready_bot"], "bots": [], "sources": []])
        case "subscriptions.send_now": return ok(["job_id": "job1"])
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
    server.refuseToken = true
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
