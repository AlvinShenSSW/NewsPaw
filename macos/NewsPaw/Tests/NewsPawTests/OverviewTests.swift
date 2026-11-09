import Foundation
import Testing

@testable import NewsPaw

/// A backend that answers by operation name and records every request.
@MainActor
private final class ScriptedBackend {
    var replies: [String: String]
    /// Answers a request before `replies` when it returns non-nil (for replies that depend on fields).
    var responder: (([String: Any]) -> String?)?
    private(set) var requests: [[String: Any]] = []

    init(_ replies: [String: String]) { self.replies = replies }

    var client: BackendClient {
        BackendClient { [unowned self] body, _ in
            let request = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            let op = request["op"] as! String
            return await MainActor.run {
                self.requests.append(request)
                return Data((self.responder?(request) ?? self.replies[op] ?? #"{"ok":false,"error":"unknown_operation"}"#).utf8)
            }
        }
    }

    func calls(_ op: String) -> [[String: Any]] { requests.filter { $0["op"] as? String == op } }
}

private func occurrence(_ id: String, status: String, reason: String? = nil, date: String, time: String = "08:00", job: String? = "job1", offset: String = "+00:00") -> String {
    let reason = reason.map { "\"\($0)\"" } ?? "null"
    let job = job.map { "\"\($0)\"" } ?? "null"
    return #"{"id":"\#(id)","scope_id":"s","slot":1,"civil_date":"\#(date)","target_at":"\#(date)T\#(time):00\#(offset)","prepare_at":"\#(date)T07:45:00+00:00","cutoff_at":"\#(date)T14:00:00+00:00","status":"\#(status)","reason":\#(reason),"generation":1,"job_id":\#(job),"updated_at":"\#(date)T08:01:00+00:00","subscription_id":"sub_world","account_id":null}"#
}

private func fixtureDay(_ offset: Int, from now: Date) -> String {
    OverviewData.day(now.addingTimeInterval(TimeInterval(offset) * 86_400))
}

@MainActor
private func backend(now: Date, rows: [String], delivery: String = #"{"ok":true,"result":{"targets":{}}}"#) -> ScriptedBackend {
    ScriptedBackend([
        "schedule.status": #"{"ok":true,"result":{"revision":1,"settings":{"enabled":true},"activated_at":null,"occurrences":[\#(rows.joined(separator: ","))]}}"#,
        "delivery.status": delivery,
        "budget.get": #"""
            {"ok":true,"result":{"revision":1,"document":{"model":{"monthly_limit":20000000},"x":{"daily_limit":null}},"report":{"periods":[
             {"meter":"model","start":"2000-01-01T00:00:00+00:00","end":"2999-01-01T00:00:00+00:00","known_settled":3100000,"held":320000,"unpriced":2,
              "scopes":{"total":{"limit":20000000,"used":3420000},"image":{"limit":null,"used":320000}}},
             {"meter":"x","start":"2000-01-01T00:00:00+00:00","end":"2999-01-01T00:00:00+00:00","known_settled":84,"held":0,"unpriced":0,
              "scopes":{"total":{"limit":null,"used":84}}}]}}}
            """#,
        "sources.list": #"{"ok":true,"result":[{"source":{"name":"NHK","enabled":true},"health":{"freshness":"stale","latest_publication":"2000-01-01T00:00:00+00:00"}},{"source":{"name":"Asahi","enabled":true},"health":{"freshness":"current","latest_publication":null}}]}"#,
        "jobs.resume": #"{"ok":true,"result":{}}"#,
        "delivery.resolve": #"{"ok":true,"result":{}}"#,
        "schedule.resolve": #"{"ok":true,"result":{}}"#,
    ])
}

@Test @MainActor func overviewSplitsTodayFromTheWeekAndReadsSpendingInDollars() async {
    let now = Date()
    let rows = [
        occurrence("a", status: "delivered", date: fixtureDay(0, from: now), time: "08:00"),
        occurrence("b", status: "planned", date: fixtureDay(0, from: now), time: "18:00"),
        occurrence("c", status: "delivered", date: fixtureDay(-2, from: now)),
        occurrence("d", status: "delivered", date: fixtureDay(-9, from: now)),
    ]
    let server = backend(now: now, rows: rows)
    let data = OverviewData()
    await data.load(server.client, now: now)
    #expect(data.failure == nil)
    #expect(data.today.map(\.id) == ["a", "b"])
    #expect(data.week.map(\.id) == ["c"])
    #expect(data.spending == .init(used: 3_420_000, limit: 20_000_000, image: 320_000, unpriced: 2, xReads: 84, xLimit: nil))
    #expect(dollars(3_420_000) == "$3.42")
    #expect(data.staleSources.map(\.name) == ["NHK"])
    #expect(server.calls("schedule.status").first?["limit"] as? Int == 100)
}

@Test func occurrenceStatesFollowTheContractVocabulary() {
    func state(_ status: String, reason: String? = nil, paused: Bool = false, abandoned: Bool = false) -> OccurrenceState {
        let json = occurrence("x", status: status, reason: reason, date: "2026-11-10")
        let row = try! BackendRPC.decode(Data(json.utf8)) as Occurrence
        return OccurrenceState(row, paused: paused, abandoned: abandoned)
    }
    #expect(state("planned") == .waiting)
    #expect(state("preparing") == .preparing)
    #expect(state("late") == .late)
    #expect(state("delivered") == .delivered)
    #expect(state("no_news") == .skipped && state("superseded") == .skipped)
    #expect(state("outcome_unknown", reason: "model_outcome_unknown") == .modelUnknown)
    #expect(state("outcome_unknown") == .deliveryUnknown)
    #expect(state("held", reason: "partial_assignment_changed") == .held)
    #expect(state("blocked", reason: "no_target") == .failed)
    #expect(state("planned", paused: true) == .paused)
    #expect(state("delivered", paused: true) == .delivered)
    #expect(state("partial", abandoned: true) == .abandoned)
}

@Test @MainActor func eachUnknownOrHeldEditionUsesItsOwnRecovery() async {
    let now = Date()
    let today = fixtureDay(0, from: now)
    let delivery = #"{"ok":true,"result":{"targets":{"bot1":{"parts":[{"state":"delivered"},{"state":"outcome_unknown"}]}}}}"#
    let server = backend(now: now, rows: [occurrence("m", status: "outcome_unknown", reason: "model_outcome_unknown", date: today)], delivery: delivery)
    let data = OverviewData()
    await data.load(server.client, now: now)
    let row = data.today[0]
    await data.resolve(row, .retryModel, client: server.client)
    #expect(server.calls("jobs.resume").first?["acknowledge_duplicate_charge"] as? Bool == true)

    await data.resolve(row, .retryDelivery, client: server.client)
    let retry = server.calls("delivery.resolve")
    #expect(retry.count == 1 && retry[0]["ordinal"] as? Int == 1)
    #expect(retry[0]["action"] as? String == "retry" && retry[0]["acknowledge_duplicate_send"] as? Bool == true)

    await data.resolve(row, .stopResending, client: server.client)
    let skip = server.calls("delivery.resolve").last
    #expect(skip?["action"] as? String == "skip" && skip?["acknowledge_duplicate_send"] == nil)

    await data.resolve(row, .continueHeld, client: server.client)
    await data.resolve(row, .stopHeld, client: server.client)
    #expect(server.calls("schedule.resolve").map { $0["action"] as? String } == ["continue", "stop"])
}

@Test @MainActor func aSkipResolutionShowsAsAbandoned() async {
    let now = Date()
    let delivery = #"{"ok":true,"result":{"targets":{"bot1":{"parts":[{"state":"skipped","resolution":{"action":"skip"}}]}}}}"#
    let server = backend(now: now, rows: [occurrence("p", status: "partial", date: fixtureDay(0, from: now))], delivery: delivery)
    let data = OverviewData()
    await data.load(server.client, now: now)
    #expect(data.abandoned == ["p"])
}

@Test func overviewCopyHasAllLanguages() {
    for words in L10n.Overview.all + L10n.Attention.all + L10n.Setup.all {
        for language in AppLanguage.allCases {
            #expect(!words(language).isEmpty)
        }
    }
}


@Test @MainActor func beforeTheFirstPaidCallTheCapComesFromThePolicy() async {
    let server = ScriptedBackend([
        "schedule.status": #"{"ok":true,"result":{"revision":1,"settings":{"enabled":true},"activated_at":null,"occurrences":[]}}"#,
        "budget.get": #"{"ok":true,"result":{"revision":1,"document":{"model":{"monthly_limit":20000000},"x":{"daily_limit":200}},"report":{"periods":[]}}}"#,
        "sources.list": #"{"ok":true,"result":[]}"#,
    ])
    let data = OverviewData()
    await data.load(server.client)
    #expect(data.spending == .init(used: 0, limit: 20_000_000, image: 0, unpriced: 0, xReads: 0, xLimit: 200))
}

@Test func skippedEditionsSayWhy() {
    #expect(OccurrenceRow.skipNote(status: "no_news", reason: nil) == L10n.Overview.noNews)
    #expect(OccurrenceRow.skipNote(status: "skipped", reason: "scope_disabled") == L10n.Overview.digestOff)
    #expect(OccurrenceRow.skipNote(status: "skipped", reason: "catchup_expired") == L10n.Overview.missed)
    #expect(OccurrenceRow.skipNote(status: "superseded", reason: "newer_elapsed_slot") == L10n.Overview.superseded)
}


@Test @MainActor func digestTitlesFollowTheInterfaceLanguageUnlessSplit() async throws {
    let fixture = try FixtureSocket()
    let running = #"{"ok":true,"result":{"protocol_version":1,"state":"running"}}"# + "\n"
    let configuration = #"{"ok":true,"result":{"revision":1,"document":{"ui_locale":"ja","news_output_locale":"ja","categories":[{"id":"world","name":"世界新闻","partition":"normal"},{"id":"japan","name":"日本新闻","partition":"normal"}],"subscriptions":[{"id":"sub_world","name":"世界新闻","category_id":"world","timezone":"Asia/Tokyo","enabled":true,"times":["08:00"]},{"id":"sub_japan","name":"日本 · 国内","category_id":"japan","timezone":"Asia/Tokyo","enabled":true,"times":["08:30"]},{"id":"sub_japan2","name":"日本 · 娱乐","category_id":"japan","timezone":"Asia/Tokyo","enabled":true,"times":["18:30"]}],"sources":[],"accounts":[],"model_profiles":[]}}}"# + "\n"
    let bots = #"{"ok":true,"result":[]}"# + "\n"
    let replies = fixture.serve([running, configuration, bots])
    let name = "NewsPawTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("ja", forKey: "displayLanguage")
    let model = AppModel(socket: LocalSocket(path: fixture.path), defaults: defaults)
    await model.refresh()
    #expect(model.digestTitle("sub_world") == AppLanguage.ja.text(.world))
    #expect(model.digestTitle("sub_japan2") == "日本 · 娱乐")
    #expect(try await replies.value.count == 3)
}


/// The real `delivery.status`: a summary without parts, and parts only for one Bot.
@MainActor
private func realisticDelivery(_ server: ScriptedBackend, parts: String) {
    server.responder = { request in
        guard request["op"] as? String == "delivery.status" else { return nil }
        if let bot = request["bot_id"] as? String {
            return #"{"ok":true,"result":{"targets":{"\#(bot)":{"status":"partial","parts":\#(parts)}}}}"#
        }
        return #"{"ok":true,"result":{"targets":{"bot1":{"status":"partial","part_count":2}}}}"#
    }
}

@Test @MainActor func recoveryReadsEachBotsPartsLikeTheRealBackend() async {
    let now = Date()
    let server = backend(now: now, rows: [occurrence("d", status: "outcome_unknown", reason: "delivery_outcome_unknown", date: fixtureDay(0, from: now))])
    realisticDelivery(server, parts: #"[{"ordinal":0,"state":"delivered"},{"ordinal":1,"state":"outcome_unknown"}]"#)
    let data = OverviewData()
    await data.load(server.client, now: now)
    #expect(data.failure == nil)
    await data.resolve(data.today[0], .retryDelivery, client: server.client)
    let retry = server.calls("delivery.resolve")
    #expect(retry.count == 1 && retry.first?["bot_id"] as? String == "bot1" && retry.first?["ordinal"] as? Int == 1)
    #expect(server.calls("delivery.status").contains { $0["bot_id"] as? String == "bot1" })
}

@Test @MainActor func aSkipInThePastWeekAlsoShowsAsAbandoned() async {
    let now = Date()
    let server = backend(now: now, rows: [occurrence("old", status: "partial", date: fixtureDay(-2, from: now))])
    realisticDelivery(server, parts: #"[{"ordinal":0,"state":"skipped","resolution":{"action":"skip"}}]"#)
    let data = OverviewData()
    await data.load(server.client, now: now)
    #expect(data.abandoned == ["old"])
}

@Test @MainActor func anEditionStoppedBeforeDeliveryDoesNotBreakTheOverview() async {
    let now = Date()
    let server = backend(now: now, rows: [occurrence("s", status: "skipped", reason: "stopped_after_model_result", date: fixtureDay(0, from: now))],
                         delivery: #"{"ok":false,"error":"missing_delivery","error_detail":{"code":"missing_delivery","domain":"delivery","retryable":false}}"#)
    let data = OverviewData()
    await data.load(server.client, now: now)
    #expect(data.failure == nil)
    #expect(data.spending != nil && data.staleSources.map(\.name) == ["NHK"])
}

@Test @MainActor func aRefusedRecoveryStaysOnScreenAfterTheReload() async {
    let now = Date()
    let server = backend(now: now, rows: [occurrence("h", status: "held", reason: "partial_assignment_changed", date: fixtureDay(0, from: now))])
    server.replies["schedule.resolve"] = #"{"ok":false,"error":"job_busy","error_detail":{"code":"job_busy","domain":"schedule","retryable":true}}"#
    let data = OverviewData()
    await data.load(server.client, now: now)
    await data.resolve(data.today[0], .continueHeld, client: server.client)
    #expect(data.failure?.code == "job_busy")
}

@Test func unknownOutcomesShowWhileTheEditionIsStillOpen() {
    func state(_ status: String, _ reason: String) -> OccurrenceState {
        let row = try! BackendRPC.decode(Data(occurrence("x", status: status, reason: reason, date: "2026-11-10").utf8)) as Occurrence
        return OccurrenceState(row, paused: false, abandoned: false)
    }
    #expect(state("waiting", "model_outcome_unknown") == .modelUnknown)
    #expect(state("late", "model_outcome_unknown") == .modelUnknown)
    #expect(state("waiting", "delivery_outcome_unknown") == .deliveryUnknown)
    #expect(state("waiting", "job_paused") == .preparing)
}

@Test func editionsSortByTheirInstantAcrossTimeZones() {
    let tokyo = try! BackendRPC.decode(Data(occurrence("tokyo", status: "planned", date: "2026-11-10", time: "09:00", offset: "+09:00").utf8)) as Occurrence
    let london = try! BackendRPC.decode(Data(occurrence("london", status: "planned", date: "2026-11-10", time: "08:00", offset: "+00:00").utf8)) as Occurrence
    // 09:00 Tokyo is 00:00 UTC, before 08:00 London, though "09" sorts after "08" as text.
    #expect([london, tokyo].sorted(by: OverviewData.byTarget).map(\.id) == ["tokyo", "london"])
}

@Test @MainActor func aTrialSendNeverPicksAnAdultDigest() async throws {
    let fixture = try FixtureSocket()
    let running = #"{"ok":true,"result":{"protocol_version":1,"state":"running"}}"# + "\n"
    let configuration = #"{"ok":true,"result":{"revision":1,"document":{"ui_locale":"en","news_output_locale":"en","categories":[{"id":"world","name":"W","partition":"normal"},{"id":"av","name":"AV","partition":"adult"}],"subscriptions":[{"id":"sub_world","category_id":"world","timezone":"Asia/Tokyo","enabled":false,"times":["08:00"]},{"id":"sub_av","category_id":"av","timezone":"Asia/Tokyo","enabled":true,"times":["21:00"]}],"sources":[],"accounts":[],"model_profiles":[]}}}"# + "\n"
    let bots = #"{"ok":true,"result":[]}"# + "\n"
    let replies = fixture.serve([running, configuration, bots])
    let name = "NewsPawTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let model = AppModel(socket: LocalSocket(path: fixture.path), defaults: defaults)
    await model.refresh()
    #expect(model.config != nil && model.firstEnabledDigest == nil)
    #expect(try await replies.value.count == 3)
}


@Test @MainActor func aSkippedPartStaysAbandonedWhileTheEditionIsStillOpen() async {
    let now = Date()
    let server = backend(now: now, rows: [occurrence("o", status: "waiting", reason: "delivery_outcome_unknown", date: fixtureDay(0, from: now))])
    realisticDelivery(server, parts: #"[{"ordinal":0,"state":"skipped","resolution":{"action":"skip"}}]"#)
    let data = OverviewData()
    await data.load(server.client, now: now)
    #expect(data.abandoned == ["o"])
}

@Test @MainActor func onlyAMissingDeliveryRecordIsTreatedAsNothingSkipped() async {
    let now = Date()
    let server = backend(now: now, rows: [occurrence("p", status: "partial", date: fixtureDay(0, from: now))],
                         delivery: #"{"ok":false,"error":"storage_error","error_detail":{"code":"storage_error","domain":"delivery","retryable":true}}"#)
    let data = OverviewData()
    await data.load(server.client, now: now)
    #expect(data.failure?.code == "storage_error")
}

@Test func aRetimedEditionIsSkippedNotFailed() {
    let row = try! BackendRPC.decode(Data(occurrence("r", status: "rescheduled", reason: "schedule_changed", date: "2026-11-10").utf8)) as Occurrence
    #expect(OccurrenceState(row, paused: false, abandoned: false) == .skipped)
    #expect(OccurrenceRow.skipNote(status: "rescheduled", reason: "schedule_changed") == L10n.Overview.retimed)
}
