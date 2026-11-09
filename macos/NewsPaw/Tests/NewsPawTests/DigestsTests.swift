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
            if stale { return refuse("config_conflict") }
            let source = request["source"] as! [String: Any]
            return commit { document["sources"] = sources.filter { $0["id"] as? String != source["id"] as? String } + [source] }
        case "sources.preview":
            let id = request["source_id"] as! String
            let bad = (source(id)?["url"] as? String ?? "").contains("bad")
            if !bad { ready.insert(id) }
            return ok([
                "attempt": ["status": bad ? "failed" : "fresh"],
                "entries": bad ? [] : [["published_at": "2026-11-10T08:20:00+00:00"]],
                "preview_ready": !bad,
            ])
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
    #expect(data.failures[bad["id"] as! String]?.code == "failed")
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
