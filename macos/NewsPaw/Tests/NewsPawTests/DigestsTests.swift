import Foundation
import Testing

@testable import NewsPaw

/// A small in-memory backend for the digests page: one configuration document with a
/// revision, the source and subscription operations the page uses, and a request log.
@MainActor
private final class DigestBackend {
    var revision = 1
    var document: [String: Any]
    var ready: Set<String> = []
    var requests: [[String: Any]] = []
    /// Changes the stored document once, just before the next subscriptions.save is checked,
    /// as another window would.
    var backgroundChange: (([String: Any]) -> [String: Any])?
    /// The same, before the next sources.save of an existing source.
    var sourceBackgroundChange: (([String: Any]) -> [String: Any])?
    var impactReply: [String: Any] = ["subscriptions": []]
    /// Per-operation delays applied before the reply is computed (to overlap requests).
    var delays: [String: [Duration]] = [:]

    func nextDelay(_ op: String) -> Duration? {
        guard var queue = delays[op], !queue.isEmpty else { return nil }
        let delay = queue.removeFirst()
        delays[op] = queue
        return delay
    }

    init(subscriptions: [[String: Any]], sources: [[String: Any]] = [], bots: [[String: Any]] = [["id": "bot1", "adult_allowed": false]]) {
        document = [
            "ui_locale": "en", "news_output_locale": "en", "owner_id": "owner",
            "categories": [
                ["id": "japan", "name": "日本新闻", "partition": "normal"],
                ["id": "av", "name": "AV", "partition": "adult"],
            ],
            "subscriptions": subscriptions, "sources": sources, "accounts": [], "model_profiles": [], "bots": bots,
        ]
    }

    func calls(_ op: String) -> [[String: Any]] { requests.filter { $0["op"] as? String == op } }

    var subscriptions: [[String: Any]] { document["subscriptions"] as? [[String: Any]] ?? [] }
    func subscription(_ id: String) -> [String: Any]? { subscriptions.first { $0["id"] as? String == id } }
    var sources: [[String: Any]] { document["sources"] as? [[String: Any]] ?? [] }
    func source(_ id: String) -> [String: Any]? { sources.first { $0["id"] as? String == id } }

    var client: BackendClient {
        BackendClient { [unowned self] body, _ in
            let request = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            let op = request["op"] as! String
            if let delay = await MainActor.run(body: { self.nextDelay(op) }) { try await Task.sleep(for: delay) }
            return await MainActor.run { self.answer(request) }
        }
    }

    private func ok(_ result: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: ["ok": true, "result": result])
    }

    private func refuse(_ code: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["ok": false, "error": code, "error_detail": ["code": code, "domain": "subscriptions", "retryable": false]])
    }

    private func commit(_ change: () -> Void) -> Data {
        change()
        revision += 1
        return ok(["revision": revision])
    }

    private func answer(_ request: [String: Any]) -> Data {
        requests.append(request)
        let op = request["op"] as! String
        let stale = (request["revision"] as? Int).map { $0 != revision } ?? false
        switch op {
        case "service.status": return ok(["protocol_version": 1, "state": "running", "operations": []])
        case "config.get": return ok(["revision": revision, "document": document])
        case "bots.list": return ok([["id": "bot1", "name": "Main", "verified": true, "paired": true, "paused": false, "username": "np_bot"]])
        case "schedule.status": return ok(["revision": 1, "settings": ["enabled": true], "activated_at": NSNull(), "occurrences": []])
        case "newspaper.policy": return ok(["revision": 1, "settings": ["enabled": false, "generation_profile": NSNull()]])
        case "sources.catalog":
            return ok([
                ["id": "nhk", "name": "NHK", "url": "https://nhk.example/rss", "kind": "rss", "category_id": "japan", "partition": "normal", "connection": "rss", "focus": "domestic"],
                ["id": "ent", "name": "Ent", "url": "https://bad.example/rss", "kind": "rss", "category_id": "japan", "partition": "normal", "connection": "rss", "focus": "entertainment"],
                ["id": "adapter", "name": "Adapter", "url": "https://adapter.example", "kind": "web", "category_id": "japan", "partition": "normal", "connection": "adapter_required", "focus": NSNull()],
            ])
        case "sources.list":
            return ok(sources.map { ["source": $0, "health": NSNull(), "preview_ready": ready.contains($0["id"] as! String)] })
        case "sources.save":
            if let change = sourceBackgroundChange {
                sourceBackgroundChange = nil
                document = change(document)
                revision += 1
            }
            if request["revision"] as? Int != revision { return refuse("config_conflict") }
            let source = request["source"] as! [String: Any]
            return commit { document["sources"] = sources.filter { $0["id"] as? String != source["id"] as? String } + [source] }
        case "sources.preview":
            let id = request["source_id"] as! String
            let url = source(id)?["url"] as? String ?? ""
            if url.contains("held") {
                return ok(["attempt": ["status": "interrupted", "error_kind": "collection_held"], "entries": [], "preview_ready": false])
            }
            if url.contains("quiet") {
                return ok(["attempt": ["status": "empty", "error_kind": NSNull()], "entries": [], "preview_ready": false])
            }
            let bad = url.contains("bad")
            if !bad { ready.insert(id) }
            let attempt: [String: Any] = bad ? ["status": "failed", "error_kind": "http_error"] : ["status": "fresh", "error_kind": NSNull()]
            let entries: [[String: Any]] = bad ? [] : [["published_at": "2026-11-10T08:20:00+00:00"]]
            return ok(["attempt": attempt, "entries": entries, "preview_ready": !bad] as [String: Any])
        case "subscriptions.save":
            if let change = backgroundChange {
                backgroundChange = nil
                document = change(document)
                revision += 1
            }
            if request["revision"] as? Int != revision { return refuse("config_conflict") }
            var draft = request["draft"] as! [String: Any]
            let enable = request["enable"] as? Bool ?? false
            if enable, (draft["bot_ids"] as? [String] ?? []).isEmpty { return refuse("subscription_not_ready") }
            draft["enabled"] = enable
            return commit {
                var list = subscriptions
                if let index = list.firstIndex(where: { $0["id"] as? String == draft["id"] as? String }) { list[index] = draft } else { list.append(draft) }
                document["subscriptions"] = list
            }
        case "subscriptions.preview":
            let draft = request["draft"] as! [String: Any]
            return ok(["blockers": (draft["bot_ids"] as? [String] ?? []).isEmpty ? ["no_ready_bot"] : [], "bots": draft["bot_ids"] ?? [], "sources": []])
        case "sources.impact":
            return ok(impactReply.merging(["revision": revision]) { $1 })
        case "sources.delete":
            if stale { return refuse("config_conflict") }
            return commit { document["sources"] = sources.filter { $0["id"] as? String != request["source_id"] as? String } }
        case "config.save":
            if stale { return refuse("config_conflict") }
            return commit { document = request["document"] as! [String: Any] }
        default:
            return refuse("unknown_operation")
        }
    }
}

private func subscription(_ id: String, category: String = "japan", enabled: Bool = false, bots: [String] = [], extra: [String: Any] = [:]) -> [String: Any] {
    ["id": id, "name": "", "category_id": category, "timezone": "Asia/Tokyo", "enabled": enabled, "times": ["08:30"],
     "bot_ids": bots, "source_ids": [], "max_items": 5].merging(extra) { $1 }
}

private func source(_ id: String, focus: String, enabled: Bool = true) -> [String: Any] {
    ["id": id, "name": id.uppercased(), "url": "https://\(id).example/rss", "kind": "rss", "partition": "normal",
     "category_ids": ["japan"], "enabled": enabled, "focus": focus]
}

@MainActor
private func connected(_ server: DigestBackend) async throws -> (AppModel, () -> Void) {
    let name = "NewsPawTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    let model = AppModel(client: server.client, defaults: defaults)
    await model.refresh()
    #expect(model.connection == .connected)
    return (model, { defaults.removePersistentDomain(forName: name) })
}

@Test @MainActor func turningOnBringsInRecommendedSourcesTriesThemAndChoosesTheOnlyBot() async throws {
    let server = DigestBackend(subscriptions: [subscription("sub_japan")])
    let (model, cleanup) = try await connected(server)
    defer { cleanup() }
    let data = DigestsData()
    await data.load(model.client)
    let digest = try #require(model.config?.subscriptions.first)

    #expect(await data.turnOn(digest, model: model))

    // Each readable catalog source arrives as an inactive draft in the digest's category.
    let drafts = server.calls("sources.save").map { $0["source"] as! [String: Any] }.filter { $0["enabled"] as? Bool == false }
    #expect(Set(drafts.compactMap { $0["url"] as? String }) == ["https://nhk.example/rss", "https://bad.example/rss"])
    #expect(drafts.allSatisfy { $0["category_ids"] as? [String] == ["japan"] && $0["partition"] as? String == "normal" })
    #expect(Set(drafts.compactMap { $0["focus"] as? String }) == ["domestic", "entertainment"])
    // The source that read fine is on; the one that failed stays off and says why.
    let nhk = try #require(server.sources.first { $0["url"] as? String == "https://nhk.example/rss" })
    let bad = try #require(server.sources.first { $0["url"] as? String == "https://bad.example/rss" })
    #expect(nhk["enabled"] as? Bool == true && bad["enabled"] as? Bool == false)
    // The reason is the attempt's error kind, with its own copy.
    #expect(data.failures[bad["id"] as! String]?.code == "http_error")
    // The digest is on, sent to the only usable Bot.
    let stored = try #require(server.subscription("sub_japan"))
    #expect(stored["enabled"] as? Bool == true && stored["bot_ids"] as? [String] == ["bot1"])
    #expect(data.savedAt["sub_japan"] != nil)
}

@Test @MainActor func anEditKeepsAChangeMadeElsewhereMeanwhile() async throws {
    let server = DigestBackend(subscriptions: [subscription("sub_japan", enabled: true, bots: ["bot1"])])
    let (model, cleanup) = try await connected(server)
    defer { cleanup() }
    let data = DigestsData()
    server.backgroundChange = { document in
        var document = document
        var list = document["subscriptions"] as! [[String: Any]]
        list[0]["times"] = ["07:00", "19:00"]
        document["subscriptions"] = list
        return document
    }

    #expect(await data.save("sub_japan", model: model) { var d = $0; d["max_items"] = 10; return d })

    let stored = try #require(server.subscription("sub_japan"))
    #expect(stored["max_items"] as? Int == 10)
    #expect(stored["times"] as? [String] == ["07:00", "19:00"])
    #expect(stored["enabled"] as? Bool == true)
    #expect(server.calls("subscriptions.save").count == 2)
}

@Test @MainActor func aRefusedSaveIsShownInlineWithWhatStillBlocksIt() async throws {
    let server = DigestBackend(subscriptions: [subscription("sub_japan")])
    let (model, cleanup) = try await connected(server)
    defer { cleanup() }
    let data = DigestsData()

    #expect(!(await data.save("sub_japan", model: model, enable: true)))

    #expect(data.failures["sub_japan"]?.code == "subscription_not_ready")
    #expect(data.previews["sub_japan"]?.blockers == ["no_ready_bot"])
    #expect(server.subscription("sub_japan")?["enabled"] as? Bool == false)
}

@Test @MainActor func splittingDividesSourcesByFocusAndMergingRestoresTheCategory() async throws {
    let server = DigestBackend(
        subscriptions: [subscription("sub_japan", enabled: true, bots: ["bot1"], extra: ["focus_weights": ["domestic": 70, "entertainment": 30]])],
        sources: [source("nhk", focus: "domestic"), source("oricon", focus: "entertainment")]
    )
    server.ready = ["nhk"]
    let (model, cleanup) = try await connected(server)
    defer { cleanup() }
    let data = DigestsData()
    await data.load(model.client)
    let digest = try #require(model.config?.subscriptions.first)

    let copyId = try #require(await data.split(digest, model: model))

    let original = try #require(server.subscription("sub_japan"))
    let copy = try #require(server.subscription(copyId))
    #expect(original["source_mode"] as? String == "explicit" && original["source_ids"] as? [String] == ["nhk"])
    #expect(copy["source_mode"] as? String == "explicit" && copy["source_ids"] as? [String] == ["oricon"])
    #expect(copy["enabled"] as? Bool == false && original["enabled"] as? Bool == true)
    #expect(original["focus_weights"] == nil && copy["focus_weights"] == nil)
    #expect((copy["name"] as? String)?.hasSuffix("Entertainment") == true)

    let split = try #require(model.config?.subscriptions.first { $0.id == copyId })
    await data.merge(split, model: model)

    #expect(server.subscriptions.count == 1)
    #expect(server.subscription("sub_japan")?["source_mode"] as? String == "category")
    #expect(server.subscription("sub_japan")?["source_ids"] as? [String] == [])
}

@Test @MainActor func aDigestWithItsOwnListAddsAndRemovesSourcesThere() async throws {
    let server = DigestBackend(
        subscriptions: [subscription("sub_japan", enabled: true, bots: ["bot1"], extra: ["source_mode": "explicit", "source_ids": ["nhk"]])],
        sources: [source("nhk", focus: "domestic"), source("oricon", focus: "entertainment")]
    )
    let (model, cleanup) = try await connected(server)
    defer { cleanup() }
    let data = DigestsData()
    await data.load(model.client)
    let digest = try #require(model.config?.subscriptions.first)
    let oricon = try #require(data.sources.first { $0.id == "oricon" })

    // Both category sources are listed; only its own one counts as on.
    #expect(data.listed(digest).map(\.id).sorted() == ["nhk", "oricon"])
    #expect(!data.included(oricon, in: digest))

    await data.toggle(oricon, in: digest, true, model: model)
    #expect(server.subscription("sub_japan")?["source_ids"] as? [String] == ["nhk", "oricon"])
    // The source itself is untouched: other digests that follow the category are unaffected.
    #expect(server.calls("sources.save").isEmpty)

    let updated = try #require(model.config?.subscriptions.first)
    let nhk = try #require(data.sources.first { $0.id == "nhk" })
    await data.toggle(nhk, in: updated, false, model: model)
    #expect(server.subscription("sub_japan")?["source_ids"] as? [String] == ["oricon"])
}

@Test @MainActor func adultDigestsNeedAnAdultBotAndAnAdultKey() async throws {
    let server = DigestBackend(subscriptions: [subscription("sub_av", category: "av")])
    let (model, cleanup) = try await connected(server)
    defer { cleanup() }
    #expect(model.usableBots(for: "japan") == ["bot1"])
    #expect(model.usableBots(for: "av").isEmpty)
    #expect(!model.adultModelReady)
}

@Test func timesAreStoredOnceEachInOrder() throws {
    let times = ["18:30", "08:00", "18:30"].compactMap(DigestTimes.parse)
    #expect(DigestTimes.stored(times) == ["08:00", "18:30"])
    #expect(DigestTimes.format(DigestTimes.next(after: DigestTimes.parse("23:30"))) == "00:30")
    #expect(DigestTimes.format(DigestTimes.next(after: nil)) == "08:00")
}

@Test func theNextEditionIsTodayOrTomorrowInTheDigestsZone() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-11-10T00:00:00Z")) // 09:00 in Tokyo
    #expect(NextSend.text(times: ["08:30", "18:30"], zone: "Asia/Tokyo", now: now, .en) == "today 18:30")
    #expect(NextSend.text(times: ["08:30"], zone: "Asia/Tokyo", now: now, .en) == "tomorrow 08:30")
    #expect(NextSend.text(times: [], zone: "Asia/Tokyo", now: now, .en) == nil)
}

@Test func storedDraftsDropTheirSwitchAndNameTheirSourceMode() {
    let draft = DigestsData.draft(["id": "s", "enabled": true, "source_ids": ["a"]])
    #expect(draft["enabled"] == nil && draft["source_mode"] as? String == "explicit")
    #expect(DigestsData.draft(["id": "s", "source_ids": []])["source_mode"] as? String == "category")
    #expect(DigestsData.draft(["id": "s", "source_mode": "category", "source_ids": []])["source_mode"] as? String == "category")
}

@Test func digestCopyHasAllLanguages() {
    for words in L10n.Digests.all {
        for language in AppLanguage.allCases {
            #expect(!words(language).isEmpty)
        }
    }
}

@Test @MainActor func anOnDigestIsNotLeftWithOnlySourcesItCannotRead() async throws {
    // The domestic source was never tried: dividing would leave the enabled original with nothing usable.
    let server = DigestBackend(
        subscriptions: [subscription("sub_japan", enabled: true, bots: ["bot1"])],
        sources: [source("nhk", focus: "domestic", enabled: false), source("oricon", focus: "entertainment")]
    )
    server.ready = ["oricon"]
    let (model, cleanup) = try await connected(server)
    defer { cleanup() }
    let data = DigestsData()
    await data.load(model.client)
    let digest = try #require(model.config?.subscriptions.first)

    let copyId = try #require(await data.split(digest, model: model))

    #expect(server.subscription("sub_japan")?["source_ids"] as? [String] == [])
    #expect(server.subscription(copyId)?["source_ids"] as? [String] == [])
    #expect(server.subscription(copyId)?["enabled"] as? Bool == false)
}

@Test @MainActor func aTrialThatDidNotReallyReadSaysWhyAndLeavesTheSourceOff() async throws {
    let server = DigestBackend(
        subscriptions: [subscription("sub_japan")],
        sources: [
            ["id": "held", "name": "Held", "url": "https://held.example", "kind": "web", "partition": "normal", "category_ids": ["japan"], "enabled": false],
            ["id": "quiet", "name": "Quiet", "url": "https://quiet.example", "kind": "web", "partition": "normal", "category_ids": ["japan"], "enabled": false],
        ]
    )
    let (model, cleanup) = try await connected(server)
    defer { cleanup() }
    let data = DigestsData()
    await data.load(model.client)

    #expect(!(await data.trial("held", model: model)))
    #expect(data.failures["held"]?.code == "collection_held" && data.notes["held"] == nil)
    #expect(!(await data.trial("quiet", model: model)))
    #expect(data.failures["quiet"]?.code == "preview_incomplete")
    #expect(server.calls("sources.save").isEmpty)
}

@Test @MainActor func importedFeedsStayReachableUntilFiledUnderADigest() async throws {
    let server = DigestBackend(
        subscriptions: [subscription("sub_japan")],
        sources: [["id": "source_1", "name": "Feed", "url": "https://feed.example/rss", "kind": "rss", "partition": NSNull(), "category_ids": [], "enabled": false]]
    )
    let (model, cleanup) = try await connected(server)
    defer { cleanup() }
    let data = DigestsData()
    await data.load(model.client)
    #expect(data.unfiled.map(\.id) == ["source_1"])

    #expect(await data.file(["source_1"], under: "japan", model: model) == nil)

    let filed = try #require(server.source("source_1"))
    #expect(filed["partition"] as? String == "normal" && filed["category_ids"] as? [String] == ["japan"] && filed["enabled"] as? Bool == false)
    #expect(data.unfiled.isEmpty)
    #expect(data.listed(try #require(model.config?.subscriptions.first)).map(\.id) == ["source_1"])
}

@Test @MainActor func aMutedFocusDoesNotCountAsOn() async throws {
    let server = DigestBackend(
        subscriptions: [subscription("sub_japan", enabled: true, bots: ["bot1"], extra: ["focus_weights": ["domestic": 100, "entertainment": 0]])],
        sources: [source("nhk", focus: "domestic"), source("oricon", focus: "entertainment")]
    )
    let (model, cleanup) = try await connected(server)
    defer { cleanup() }
    let data = DigestsData()
    await data.load(model.client)
    let digest = try #require(model.config?.subscriptions.first)
    #expect(data.listed(digest).filter { data.included($0, in: digest) }.map(\.id) == ["nhk"])
}

@Test @MainActor func aRefusalIsDroppedOnceTheConfigurationChanges() async throws {
    let server = DigestBackend(subscriptions: [subscription("sub_japan")])
    let (model, cleanup) = try await connected(server)
    defer { cleanup() }
    let data = DigestsData()
    #expect(!(await data.save("sub_japan", model: model, enable: true)))
    #expect(data.failures["sub_japan"] != nil && data.previews["sub_japan"] != nil)
    // Not cleared by a revision it was already checked against…
    data.configurationChanged(to: server.revision)
    #expect(data.failures["sub_japan"] != nil && data.previews["sub_japan"] != nil)
    // …but by a later one.
    data.configurationChanged(to: server.revision + 1)
    #expect(data.failures["sub_japan"] == nil && data.previews["sub_japan"] == nil)
}

@Test func everyCodeTheDigestsPageShowsHasItsOwnCopy() {
    let codes = [
        "subscription_not_ready", "source_preview_required", "preview_required", "source_disabled", "no_ready_bot",
        "primary_unverified", "backup_unverified", "schedule_missing", "invalid_subscription_draft", "missing_subscription",
        "missing_source", "duplicate_source", "unclassified_source", "adult_source_requires_adapter", "invalid_opml",
        "discovery_failed", "failed", "http_error", "network_error", "interrupted", "collection_held", "cancelled",
        "configuration_changed", "identity_changed", "redirect_rejected", "too_many_redirects", "private_address",
        "tls_hostname_mismatch", "response_too_large", "oversized_feed", "parse_limit", "invalid_html",
        "unsupported_encoding", "invalid_publication_date", "preview_incomplete", "unsupported_source", "timeout",
        "rate_limited", "unsafe_url", "missing_primary_credential",
    ]
    for code in codes {
        #expect(FailureCopy.table[code] != nil, "no copy for \(code)")
        for language in AppLanguage.allCases {
            #expect(FailureCopy.message(for: BackendError(code: code), language) != FailureCopy.fallback(language, ["code": code]))
        }
    }
}


@Test @MainActor func aRefusedTurnOnListsTheBlockersOfTheAttemptedChange() async throws {
    // The refused change (here max_items 8) is what the blocker preview examines, not the stored record.
    let server = DigestBackend(subscriptions: [subscription("sub_japan")], sources: [source("nhk", focus: "domestic")])
    server.ready = ["nhk"]
    let (model, cleanup) = try await connected(server)
    defer { cleanup() }
    let data = DigestsData()
    #expect(!(await data.save("sub_japan", model: model, enable: true) { var d = $0; d["max_items"] = 8; return d }))
    let attempt = try #require(server.calls("subscriptions.preview").last?["draft"] as? [String: Any])
    #expect(attempt["max_items"] as? Int == 8)
}


@Test @MainActor func splittingLeavesSourcesThatAreOffOutOfTheOriginalsList() async throws {
    let server = DigestBackend(
        subscriptions: [subscription("sub_japan", enabled: true, bots: ["bot1"])],
        sources: [source("nhk", focus: "domestic"), source("draft", focus: "domestic", enabled: false), source("oricon", focus: "entertainment")]
    )
    server.ready = ["nhk", "oricon"]
    let (model, cleanup) = try await connected(server)
    defer { cleanup() }
    let data = DigestsData()
    await data.load(model.client)
    let digest = try #require(model.config?.subscriptions.first)
    _ = try #require(await data.split(digest, model: model))
    #expect(server.subscription("sub_japan")?["source_ids"] as? [String] == ["nhk"])
}

@Test @MainActor func turningASourceOnKeepsAChangeMadeToItElsewhere() async throws {
    let server = DigestBackend(subscriptions: [subscription("sub_japan")], sources: [source("nhk", focus: "domestic", enabled: false)])
    server.ready = ["nhk"]
    let (model, cleanup) = try await connected(server)
    defer { cleanup() }
    let data = DigestsData()
    server.sourceBackgroundChange = { document in
        var document = document
        var sources = document["sources"] as! [[String: Any]]
        sources[0]["name"] = "NHK News"
        document["sources"] = sources
        return document
    }
    try await data.setSource("nhk", enabled: true, model: model)
    #expect(server.source("nhk")?["enabled"] as? Bool == true && server.source("nhk")?["name"] as? String == "NHK News")
}

@Test @MainActor func removingTheLastSourceWarnsAboutADigestLeftWithNothing() async throws {
    let server = DigestBackend(subscriptions: [subscription("sub_japan", enabled: true, bots: ["bot1"])], sources: [source("nhk", focus: "domestic")])
    server.impactReply = ["subscriptions": [
        ["id": "sub_japan", "name": "", "was_enabled": true, "enabled": true, "blockers": ["no_sources"]],
    ]]
    let (model, cleanup) = try await connected(server)
    defer { cleanup() }
    let data = DigestsData()
    #expect(await data.loadImpact("nhk", model: model))
    #expect(data.impacts["nhk"] == [model.digestTitle("sub_japan")])
}


@Test @MainActor func splittingUsesTheNewestSourcesNotThePagesSnapshot() async throws {
    let server = DigestBackend(
        subscriptions: [subscription("sub_japan", enabled: true, bots: ["bot1"])],
        sources: [source("nhk", focus: "domestic"), source("asahi", focus: "domestic"), source("oricon", focus: "entertainment")]
    )
    server.ready = ["nhk", "asahi", "oricon"]
    let (model, cleanup) = try await connected(server)
    defer { cleanup() }
    let data = DigestsData()
    await data.load(model.client)
    // Turned off in another window after this page loaded.
    var sources = server.document["sources"] as! [[String: Any]]
    sources[1]["enabled"] = false
    server.document["sources"] = sources
    server.revision += 1
    let digest = try #require(model.config?.subscriptions.first)
    _ = try #require(await data.split(digest, model: model))
    #expect(server.subscription("sub_japan")?["source_ids"] as? [String] == ["nhk"])
}

@Test @MainActor func aSourceIsRemovedOnlyAfterItsImpactIsKnown() async throws {
    let server = DigestBackend(subscriptions: [subscription("sub_japan")], sources: [source("nhk", focus: "domestic")])
    server.impactReply = ["unexpected": true]
    let (model, cleanup) = try await connected(server)
    defer { cleanup() }
    let data = DigestsData()
    #expect(!(await data.loadImpact("nhk", model: model)))
    #expect(data.failures["nhk"]?.code == "invalid_reply" && data.impacts["nhk"] == nil)
}

@Test func pastedLinksKeepTheirClassification() throws {
    let found = try BackendRPC.decode(Data(#"{"kind":"web","choices":[{"url":"https://example.av","kind":"web","name":"AV","partition":"adult","category_ids":["av"]}]}"#.utf8)) as Discovery
    #expect(found.choices.first?.partition == "adult" && found.choices.first?.categoryIds == ["av"])
}


@Test @MainActor func aFeedAlreadyInAnotherCategoryJoinsThisOne() async throws {
    var shared = source("nhk", focus: "domestic")
    shared["category_ids"] = ["world"]
    let server = DigestBackend(subscriptions: [subscription("sub_japan")], sources: [shared])
    let (model, cleanup) = try await connected(server)
    defer { cleanup() }
    let data = DigestsData()
    await data.load(model.client)
    let digest = try #require(model.config?.subscriptions.first)
    await data.addSource(name: "NHK", url: "https://nhk.example/rss", kind: "rss", focus: nil, to: digest, model: model)
    #expect(server.sources.count == 1)
    #expect(server.source("nhk")?["category_ids"] as? [String] == ["world", "japan"])
}

@Test func anOversizedOPMLFileIsRefusedBeforeLoading() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("np-opml-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let small = folder.appendingPathComponent("small.opml")
    try Data("<opml/>".utf8).write(to: small)
    let large = folder.appendingPathComponent("large.opml")
    try Data(repeating: 0x20, count: 2_000).write(to: large)
    #expect(DigestsPage.readOPML(small, limit: 1_000) == "<opml/>")
    #expect(DigestsPage.readOPML(large, limit: 1_000) == nil)
}


@Test @MainActor func twoQuickChangesToOneDigestSaveInTheOrderMade() async throws {
    let server = DigestBackend(subscriptions: [subscription("sub_japan", enabled: true, bots: ["bot1"])])
    let (model, cleanup) = try await connected(server)
    defer { cleanup() }
    let data = DigestsData()
    // The first save's request is slow; without ordering, its conflict retry would land last.
    server.delays["subscriptions.save"] = [.milliseconds(150)]
    async let first = data.save("sub_japan", model: model) { var d = $0; d["max_items"] = 3; return d }
    try await Task.sleep(for: .milliseconds(20))
    async let second = data.save("sub_japan", model: model) { var d = $0; d["max_items"] = 10; return d }
    _ = await (first, second)
    #expect(server.subscription("sub_japan")?["max_items"] as? Int == 10)
}

@Test @MainActor func aRemovalConfirmedBeforeAChangeIsRefusedAndAskedAgain() async throws {
    let server = DigestBackend(subscriptions: [subscription("sub_japan")], sources: [source("nhk", focus: "domestic")])
    let (model, cleanup) = try await connected(server)
    defer { cleanup() }
    let data = DigestsData()
    #expect(await data.loadImpact("nhk", model: model))
    server.revision += 1 // another window changed the configuration meanwhile
    await data.removeSource("nhk", model: model)
    #expect(server.source("nhk") != nil && data.failures["nhk"]?.isConflict == true)
    #expect(await data.loadImpact("nhk", model: model))
    await data.removeSource("nhk", model: model)
    #expect(server.source("nhk") == nil)
}

// MARK: - #107 follow-ups

@Test @MainActor func tryingASourceTheOwnerTurnedOffLeavesItOff() async throws {
    // R09-17: verified once, then unchecked; "Try Now" reads it without turning it back on.
    let server = DigestBackend(subscriptions: [subscription("sub_japan", enabled: true, bots: ["bot1"])],
                               sources: [source("nhk", focus: "domestic", enabled: false)])
    server.ready = ["nhk"]
    let (model, cleanup) = try await connected(server)
    defer { cleanup() }
    let data = DigestsData()
    await data.load(model.client)

    #expect(!(await data.trial("nhk", model: model)))

    #expect(server.calls("sources.preview").count == 1 && data.failures["nhk"] == nil && data.notes["nhk"] != nil)
    #expect(server.source("nhk")?["enabled"] as? Bool == false && server.calls("sources.save").isEmpty)

    // "Try, Then Turn On" (the checkbox) still turns it on after a good read.
    let digest = try #require(model.config?.subscriptions.first)
    let nhk = try #require(data.sources.first { $0.id == "nhk" })
    await data.toggle(nhk, in: digest, true, model: model)
    #expect(server.source("nhk")?["enabled"] as? Bool == true)
}

@Test @MainActor func splittingADigestWithItsOwnListUsesOnlyThatList() async throws {
    // R09-18: the owner left "asahi" and "oricon" out of this digest's own list.
    let server = DigestBackend(
        subscriptions: [subscription("sub_japan", enabled: true, bots: ["bot1"], extra: ["source_mode": "explicit", "source_ids": ["nhk", "natalie"]])],
        sources: [source("nhk", focus: "domestic"), source("asahi", focus: "domestic"),
                  source("natalie", focus: "entertainment"), source("oricon", focus: "entertainment")]
    )
    server.ready = ["nhk", "asahi", "natalie", "oricon"]
    let (model, cleanup) = try await connected(server)
    defer { cleanup() }
    let data = DigestsData()
    await data.load(model.client)
    let digest = try #require(model.config?.subscriptions.first)

    let copyId = try #require(await data.split(digest, model: model))

    #expect(server.subscription("sub_japan")?["source_ids"] as? [String] == ["nhk"])
    #expect(server.subscription(copyId)?["source_ids"] as? [String] == ["natalie"])
}
