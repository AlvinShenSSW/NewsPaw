import Foundation
import GRDB
@testable import NewsPawKit
import Testing

/// RD23 decisions 6–11 through `OverviewWriter` over a stubbed service:
/// criteria 1–14 (the due rule, the request, the input, acceptance in
/// place, the failure kinds, the limit, one request in flight, the locale,
/// a failed Rewrite, the day, the partitions, and the held windows).
@Suite("Overview writer", .serialized)
struct OverviewWriterTests {
    typealias Fixture = OverviewFixture

    // MARK: - Criterion 1: the due rule over a run

    @Test("criterion 1: one request per auto category with new articles, none for manual; a second run the same day sends none")
    func oneOverviewPerAutoCategory() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let (first, firstSource, _) = try await fixture.filledCategory("First")
        let (second, _, _) = try await fixture.filledCategory("Second")
        let (manual, _, _) = try await fixture.filledCategory("Manual", mode: .manual)

        await fixture.runDue()

        #expect(fixture.overviewRequests.count == 2)
        #expect(fixture.requests(for: "First").count == 1)
        #expect(fixture.requests(for: "Second").count == 1)
        #expect(fixture.requests(for: "Manual").isEmpty)
        #expect(try await fixture.rows(of: first).map(\.state) == ["done"])
        #expect(try await fixture.rows(of: second).map(\.state) == ["done"])
        #expect(try await fixture.rows(of: manual).isEmpty)

        // More new articles, a second run the same day: nothing more.
        fixture.clock.advance(seconds: 600)
        try await fixture.articles(2, in: firstSource, prefix: "Later")
        await fixture.runDue()
        #expect(fixture.overviewRequests.count == 2)
        #expect(fixture.lastWorking == [])
    }

    @Test("criterion 1: the request is purpose overview, automatic, and the row holds summary, highlights, count, model, covered_until")
    func storedRow() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let (category, _, ids) = try await fixture.filledCategory(articles: 3)
        await fixture.runDue()
        let usage = try await fixture.usage()
        #expect(usage.map(\.purpose) == [.overview])
        #expect(usage.map(\.automatic) == [true])
        let row = try #require(try await fixture.rows(of: category).first)
        #expect(row.state == "done")
        #expect(row.text == "Summary of the day.")
        #expect(row.articleCount == 3)
        #expect(row.model == "primary-model")
        #expect(row.day == fixture.today)
        #expect(row.locale == "zh-Hans")
        #expect(row.error == nil)
        // [1] is the newest (the last inserted), [2] the one before.
        let stored = try await fixture.library.overviews(on: fixture.today, locale: .simplifiedChinese)[category]
        #expect(stored?.highlights == [
            OverviewHighlight(articleID: ids[2], text: "First matters."), OverviewHighlight(articleID: ids[1], text: "Second matters."),
        ])
        let newest = try await fixture.library.article(ids[2])
        #expect(row.coveredUntil == newest.position.firstSeenAt)
        #expect(fixture.reported.contains(.stored(category)))
    }

    // MARK: - Criterion 2

    @Test("criterion 2: no article first seen today is not due although there are new ones; the count is offered; a manual write sends")
    func notDueWithoutTodaysArticles() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let category = try await fixture.category()
        let source = try await fixture.source(in: category)
        let start = OverviewDay.start(of: fixture.clock.now(), calendar: fixture.calendar)
        // First seen yesterday evening: within the last 24 hours, not today.
        try await fixture.articles(2, in: source, at: start.addingTimeInterval(-3_600))

        await fixture.runDue()
        #expect(fixture.overviewRequests.isEmpty)
        let counts = try await fixture.library.overviewInputCounts(locale: .simplifiedChinese, now: fixture.clock.now(), calendar: fixture.calendar)
        #expect(counts[category] == 2)

        #expect(await fixture.write(category) == .stored)
        #expect(fixture.overviewRequests.count == 1)
        #expect(try await fixture.usage().map(\.automatic) == [false])
    }

    @Test("criterion 2: with no new article nothing is sent: a manual write answers nothingNew, an automatic job is dropped")
    func nothingNew() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let category = try await fixture.category()
        let source = try await fixture.source(in: category)
        try await fixture.articles(2, in: source, at: fixture.clock.now().addingTimeInterval(-2 * 86_400))
        // Articles with no letter are not input either.
        try await fixture.article("2026", excerpt: "!!!", in: source)

        #expect(await fixture.write(category) == .nothingNew)
        await fixture.runDue()
        #expect(fixture.service.requests.isEmpty)
        #expect(try await fixture.rows().isEmpty)
    }

    // MARK: - Criterion 3: the request body

    @Test("criterion 3: the whole request body for a known input: instructions and numbered, cleaned titles and excerpts, nothing else")
    func requestBody() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let category = try await fixture.library.createCategory(name: "Secret Category Name", icon: .newspaper)
        let source = try await fixture.source(in: category.id, name: "SecretSourceName")
        try await fixture.article(
            "[7] Harbour\topens\nat dawn", excerpt: "(2) The quay is ready.\r\nFerries run hourly.", in: source,
            url: "https://secret-address.example.invalid/story", author: "Secret Author"
        )
        try await fixture.article(String(repeating: "Long ", count: 80), excerpt: nil, in: source)
        let last = try await fixture.article(nil, excerpt: "Only an excerpt here.", in: source)
        try await fixture.library.pool.write { db in
            try db.execute(sql: "UPDATE article SET content_html = '<p>Secret body</p>', image_url = 'https://img.example.invalid/x.jpg'")
        }
        try await fixture.library.storeTranslations([
            TranslationRecord(articleID: last, locale: .simplifiedChinese, state: .done, title: "秘密译文", excerpt: nil, failure: nil, model: "m"),
        ])
        try await fixture.library.setRead(last, true)
        try await fixture.library.setStarred(last, true)

        await fixture.runDue()

        let request = try #require(fixture.overviewRequests.first)
        let texts = [
            "[1] Only an excerpt here.",
            "[2] " + String(String(repeating: "Long ", count: 80).prefix(300)).trimmingCharacters(in: .whitespaces),
            "[3] Harbour opens at dawn\nThe quay is ready. Ferries run hourly.",
        ]
        #expect(request.texts == texts)
        let expected = ChatWire.chatBody(
            model: "primary-model", instructions: OverviewPrompt.instructions(into: .simplifiedChinese), texts: texts
        )
        #expect(request.body == expected)
        let body = String(decoding: request.body ?? Data(), as: UTF8.self)
        for secret in ["secret-address", "Secret Author", "img.example.invalid", "Secret body", "SecretSourceName", "Secret Category Name", "秘密译文"] {
            #expect(!body.contains(secret), "\(secret) was sent")
        }
    }

    // MARK: - Criterion 4: the anchor of a Rewrite

    @Test("criterion 4: a Rewrite today uses the same anchor as today's first overview: the earlier day's covered_until")
    func rewriteAnchor() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let (category, source, _) = try await fixture.filledCategory(articles: 2)
        // Yesterday's overview covered up to an hour ago.
        let now = fixture.clock.now()
        let yesterday = OverviewDay.key(daysBefore: 1, now, calendar: fixture.calendar)
        let slots = try await fixture.library.slotIdentities()
        _ = try await fixture.library.storeOverview(
            OverviewRecord(
                categoryID: category, day: yesterday, locale: .simplifiedChinese, state: .done, text: "Yesterday.", highlights: [],
                articleCount: 1, coveredUntil: now.addingTimeInterval(-3_600), model: "m", failure: nil
            ), sent: [], slots: slots
        )
        try await fixture.article("Covered", in: source, at: now.addingTimeInterval(-7_200))
        await fixture.runDue()
        #expect(fixture.overviewRequests.first?.texts.count == 2)
        try await fixture.articles(1, in: source, prefix: "Later")
        #expect(await fixture.write(category) == .stored)
        #expect(fixture.overviewRequests.count == 2)
        #expect(fixture.overviewRequests.last?.texts.count == 3, "today's articles and the later one; not the one yesterday covered")
        #expect(try await fixture.rows(of: category).count == 2, "yesterday's and today's (replaced)")
    }

    // MARK: - Criterion 5: acceptance in place

    @Test(
        "criterion 5: an empty summary, one over 600, a cut-off reply and an empty reply are retried once on the primary, then stored failed",
        arguments: [
            (Fixture.reply(["   ", "[1] One."]), "stop", "empty"),
            (Fixture.reply([String(repeating: "x", count: 601)]), "stop", "length"),
            (Fixture.reply(["Summary.", "[1] One."]), "length", "cut_off"),
            (Fixture.reply([]), "stop", "malformed"),
            ("not json at all", "stop", "malformed"),
        ]
    )
    func rejectedReplies(content: String, finishReason: String, reason: String) async throws {
        let fixture = try await Fixture.make(service: TranslationService { _, _, _ in .content(content, finishReason: finishReason) }, backup: true)
        defer { fixture.remove() }
        let (category, _, _) = try await fixture.filledCategory()
        await fixture.runDue()
        #expect(fixture.service.requests.map(\.host) == [Fixture.primaryHost, Fixture.primaryHost], "retried once, never the backup")
        let rows = try await fixture.rows(of: category)
        #expect(rows.map(\.state) == ["failed"])
        #expect(rows.first?.error == reason)
        #expect(rows.first?.text == nil)
        #expect(rows.first?.model == "primary-model")
    }

    @Test("criterion 5: a reply rejected once and accepted on the retry is stored done")
    func retrySucceeds() async throws {
        let fixture = try await Fixture.make(service: TranslationService { _, _, number in
            number == 1 ? .content(Fixture.reply([""])) : Fixture.goodRule("", [], number)
        })
        defer { fixture.remove() }
        let (category, _, _) = try await fixture.filledCategory()
        await fixture.runDue()
        #expect(fixture.service.requests.count == 2)
        #expect(try await fixture.rows(of: category).map(\.state) == ["done"])
    }

    // MARK: - Criterion 6: service failures and refusals

    @Test("criterion 6: 429, 503 and no answer go once to a usable backup", arguments: [
        TranslationService.Answer.status(429), .status(503), .failure(.unreachable),
    ])
    func serviceFailureGoesToBackup(answer: TranslationService.Answer) async throws {
        let fixture = try await Fixture.make(
            service: TranslationService { host, texts, number in host == Fixture.primaryHost ? answer : Fixture.goodRule(host, texts, number) },
            backup: true
        )
        defer { fixture.remove() }
        let (category, _, _) = try await fixture.filledCategory()
        await fixture.runDue()
        #expect(fixture.service.requests.map(\.host) == [Fixture.primaryHost, Fixture.backupHost])
        let row = try await fixture.rows(of: category).first
        #expect(row?.state == "done")
        #expect(row?.model == "backup-model")
        #expect(try await fixture.usage().allSatisfy { $0.automatic && $0.purpose == .overview })
    }

    @Test("criterion 6: without a backup nothing is stored, the category shows the reason, the run's remaining categories are not sent; the next run tries again")
    func serviceFailureWithoutBackup() async throws {
        let fixture = try await Fixture.make(service: TranslationService { _, _, _ in .status(503) })
        defer { fixture.remove() }
        let (first, _, _) = try await fixture.filledCategory("First")
        let (second, _, _) = try await fixture.filledCategory("Second")
        await fixture.runDue()
        #expect(fixture.service.requests.count == 1)
        #expect(try await fixture.rows().isEmpty)
        let block = OverviewBlock(reason: .service(.serverError), day: fixture.today, locale: .simplifiedChinese)
        #expect(fixture.blocked == [first: block, second: block])

        fixture.service.answer(with: Fixture.goodRule)
        await fixture.runDue()
        #expect(fixture.service.requests.count == 3)
        #expect(try await fixture.rows().map(\.state) == ["done", "done"])
        #expect(fixture.blocked.isEmpty)
    }

    @Test("criterion 6: a backup that fails with a service or set-up failure blocks with the primary's reason", arguments: [
        TranslationService.Answer.status(500), .status(401),
    ])
    func backupFails(backupAnswer: TranslationService.Answer) async throws {
        let fixture = try await Fixture.make(
            service: TranslationService { host, _, _ in host == Fixture.primaryHost ? .status(429) : backupAnswer }, backup: true
        )
        defer { fixture.remove() }
        let (category, _, _) = try await fixture.filledCategory()
        await fixture.runDue()
        #expect(fixture.service.requests.count == 2)
        #expect(fixture.blocked[category]?.reason == .service(.limited))
        #expect(try await fixture.rows().isEmpty)
        #expect(await !fixture.writer.isHeld, "a backup's set-up failure does not hold the primary's work")
    }

    @Test("criterion 6: a refusal is retried once on the primary, never sent to the backup, and stored")
    func refusal() async throws {
        let fixture = try await Fixture.make(service: TranslationService { _, _, _ in .refusal }, backup: true)
        defer { fixture.remove() }
        let (category, _, _) = try await fixture.filledCategory()
        await fixture.runDue()
        #expect(fixture.service.requests.map(\.host) == [Fixture.primaryHost, Fixture.primaryHost])
        let row = try await fixture.rows(of: category).first
        #expect(row?.state == "failed")
        #expect(row?.error == "refused")
        let stored = try await fixture.library.overviews(on: fixture.today, locale: .simplifiedChinese)[category]
        #expect(stored?.failure == .refused)
        #expect(stored?.text == nil)
    }

    // MARK: - Criterion 7: set-up failures and the hold

    @Test("criterion 7: a set-up failure sends one request at most and stores nothing; later runs send nothing until the slots change", arguments: [
        (TranslationService.Answer.status(401), ModelFailure.keyRejected), (.status(404), .modelNotFound),
    ])
    func setUpFailure(answer: TranslationService.Answer, failure: ModelFailure) async throws {
        let fixture = try await Fixture.make(service: TranslationService { _, _, _ in answer })
        defer { fixture.remove() }
        let (first, _, _) = try await fixture.filledCategory("First")
        let (second, _, _) = try await fixture.filledCategory("Second")
        await fixture.runDue()
        #expect(fixture.service.requests.count == 1)
        #expect(try await fixture.rows().isEmpty)
        #expect(fixture.blocked[first]?.reason == .setUp(failure))
        #expect(fixture.blocked[second]?.reason == .setUp(failure))
        #expect(await fixture.writer.isHeld)

        // Later due checks send nothing while held.
        await fixture.runDue()
        await fixture.runDue()
        #expect(fixture.service.requests.count == 1)

        // A slot change starts nothing and ends the hold; the next run writes.
        fixture.service.answer(with: Fixture.goodRule)
        try await fixture.saveSlot(.primary, model: "repaired-model")
        await fixture.writer.slotsChanged()
        await fixture.writer.settled()
        #expect(fixture.service.requests.count == 1)
        #expect(fixture.blocked.isEmpty)
        #expect(await !fixture.writer.isHeld)
        await fixture.runDue()
        #expect(fixture.service.requests.count == 3)
        #expect(try await fixture.rows().map(\.state) == ["done", "done"])
    }

    @Test("criterion 7: key needed and no model send nothing and hold")
    func setUpWithoutRequest() async throws {
        for missingKey in [true, false] {
            let fixture = try await Fixture.make(primary: false)
            defer { fixture.remove() }
            if missingKey {
                try await fixture.saveSlot(.primary, key: nil)
            }
            let (category, _, _) = try await fixture.filledCategory()
            await fixture.runDue()
            #expect(fixture.service.requests.isEmpty)
            #expect(fixture.blocked[category]?.reason == .setUp(missingKey ? .keyNeeded : .noModelSetUp))
            #expect(await fixture.writer.isHeld)
            #expect(try await fixture.usage().isEmpty)
        }
    }

    @Test("criterion 7: a hold ends at a due check that finds the slots changed without a hook (an import)")
    func holdEndsOnChangedSlots() async throws {
        let fixture = try await Fixture.make(service: TranslationService { _, _, _ in .status(401) })
        defer { fixture.remove() }
        let (category, _, _) = try await fixture.filledCategory()
        await fixture.runDue()
        #expect(await fixture.writer.isHeld)
        fixture.service.answer(with: Fixture.goodRule)
        // A Test outcome does not count as a change.
        let slot = try await fixture.library.modelSlot(.primary)!
        try await fixture.library.setModelTestOutcome(.passed, role: .primary, baseURL: slot.baseURL, model: slot.model, keyRef: slot.keyRef!)
        await fixture.runDue()
        #expect(fixture.service.requests.count == 1)
        try await fixture.saveSlot(.primary, model: "imported-model")
        await fixture.runDue()
        #expect(fixture.service.requests.count == 2)
        #expect(try await fixture.rows(of: category).map(\.state) == ["done"])
    }

    // MARK: - Criterion 8: automatic requests and the daily limit

    @Test("criterion 8: at the limit, title requests counted, no automatic overview request is sent; Write Overview sends and is not counted")
    func dailyLimit() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        try await fixture.library.setDailyAutomaticLimit(2)
        for _ in 0..<2 {
            try await fixture.library.insertUsage(UsageRecord(
                id: UUID(), model: "m", purpose: .titles, inputTokens: nil, outputTokens: nil, outcome: .ok, at: fixture.clock.now(),
                automatic: true
            ))
        }
        let (first, _, _) = try await fixture.filledCategory("First")
        let (second, _, _) = try await fixture.filledCategory("Second")
        await fixture.runDue()
        #expect(fixture.service.requests.isEmpty)
        let block = OverviewBlock(reason: .dailyLimit, day: fixture.today, locale: .simplifiedChinese)
        #expect(fixture.blocked == [first: block, second: block])

        #expect(await fixture.write(first) == .stored)
        #expect(fixture.service.requests.count == 1)
        #expect(try await fixture.usage().filter { $0.purpose == .overview }.map(\.automatic) == [false])
        #expect(fixture.blocked == [second: block], "a manual success ends that category's block")
    }

    @Test("criterion 8: the limit is read before the retry and before the backup: neither is sent at the limit", arguments: [false, true])
    func limitBeforeRetryAndBackup(backupCase: Bool) async throws {
        let answer: TranslationService.Answer = backupCase ? .status(503) : .content(Fixture.reply([""]))
        let fixture = try await Fixture.make(service: TranslationService { _, _, _ in answer }, backup: true)
        defer { fixture.remove() }
        try await fixture.library.setDailyAutomaticLimit(1)
        let (category, _, _) = try await fixture.filledCategory()
        await fixture.runDue()
        #expect(fixture.service.requests.count == 1, "the first request reached the limit")
        #expect(fixture.blocked[category]?.reason == .dailyLimit)
        #expect(try await fixture.rows().isEmpty)
    }

    @Test("criterion 8: the limit lifts when the injected day changes")
    func limitLiftsNextDay() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        try await fixture.library.setDailyAutomaticLimit(1)
        let (_, source, _) = try await fixture.filledCategory("First")
        let (second, _, _) = try await fixture.filledCategory("Second")
        await fixture.runDue()
        #expect(fixture.service.requests.count == 1)
        #expect(fixture.blocked[second]?.reason == .dailyLimit)
        let tomorrow = OverviewDay.nextStart(after: fixture.clock.now(), calendar: fixture.calendar)
        fixture.setClock(to: tomorrow.addingTimeInterval(3_600))
        try await fixture.articles(1, in: source, prefix: "First")
        let secondSource = try await fixture.source(in: second, name: "Second2")
        try await fixture.articles(1, in: secondSource, prefix: "Second")
        await fixture.runDue()
        #expect(fixture.service.requests.count == 2, "one more, the new day's first; then the limit again")
    }

    @Test("criterion 8: an automatic request whose usage row cannot be written stops the run; a manual one goes on")
    func usageNotRecorded() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let (first, _, _) = try await fixture.filledCategory("First")
        let (second, _, _) = try await fixture.filledCategory("Second")
        try await fixture.failUsageWrites()
        await fixture.runDue()
        #expect(fixture.service.requests.count == 1)
        #expect(fixture.blocked[first]?.reason == .storage)
        #expect(fixture.blocked[second]?.reason == .storage)
        #expect(try await fixture.rows().isEmpty)
        #expect(await fixture.write(second) == .stored)
    }

    // MARK: - Criterion 9: one request in flight

    @Test("criterion 9: at most one request is in flight from the writer, manual writes among automatic ones")
    func oneInFlight() async throws {
        let fixture = try await Fixture.make(service: TranslationService(delay: .milliseconds(20), Fixture.goodRule))
        defer { fixture.remove() }
        var categories: [UUID] = []
        for index in 0..<4 {
            let (category, _, _) = try await fixture.filledCategory("C\(index)", mode: index < 2 ? .auto : .manual)
            categories.append(category)
        }
        await fixture.writer.runDue()
        async let third = fixture.writer.write(category: categories[2])
        async let fourth = fixture.writer.write(category: categories[3])
        #expect(await [third, fourth] == [.stored, .stored])
        await fixture.writer.settled()
        #expect(fixture.service.requests.count == 4)
        #expect(fixture.service.mostInFlight == 1)
    }

    @Test("criterion 9: one piece of work sends at most two primary requests and one backup request")
    func requestsPerJob() async throws {
        let fixture = try await Fixture.make(service: TranslationService { host, _, number in
            if host == Fixture.backupHost { return .content(Fixture.reply([""])) }
            return number == 1 ? .content(Fixture.reply([""])) : .status(503)
        }, backup: true)
        defer { fixture.remove() }
        let (category, _, _) = try await fixture.filledCategory()
        await fixture.runDue()
        #expect(fixture.service.requests.map(\.host) == [Fixture.primaryHost, Fixture.primaryHost, Fixture.backupHost])
        let row = try await fixture.rows(of: category).first
        #expect(row?.state == "failed")
        #expect(row?.model == "backup-model")
    }

    // MARK: - Criterion 10: the reading locale

    @Test("criterion 10: after a locale change the old overview is kept and not read; no automatic one that day; Write Overview writes in the new one")
    func localeChange() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let (category, source, _) = try await fixture.filledCategory()
        await fixture.runDue()
        await fixture.writer.configure(locale: .english)
        try await fixture.articles(1, in: source, prefix: "Later")
        await fixture.runDue()
        #expect(fixture.service.requests.count == 1)
        #expect(try await fixture.library.overviews(on: fixture.today, locale: .english).isEmpty)
        #expect(await fixture.write(category) == .stored)
        #expect(fixture.service.requests.last?.system.contains("English (en)") == true)
        #expect(try await fixture.rows(of: category).map(\.locale).sorted() == ["en", "zh-Hans"])
    }

    // MARK: - Criterion 11

    @Test("criterion 11: a failed Rewrite leaves today's done overview and reports its reason")
    func failedRewrite() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let (category, _, _) = try await fixture.filledCategory()
        await fixture.runDue()
        fixture.service.answer { _, _, _ in .refusal }
        #expect(await fixture.write(category) == .failed(.refused))
        let rows = try await fixture.rows(of: category)
        #expect(rows.map(\.state) == ["done"])
        #expect(rows.first?.text == "Summary of the day.")
        fixture.service.answer { _, _, _ in .status(429) }
        #expect(await fixture.write(category) == .notStored(OverviewBlock(reason: .service(.limited), day: fixture.today, locale: .simplifiedChinese)))
        #expect(try await fixture.rows(of: category).map(\.state) == ["done"])
    }

    // MARK: - Criterion 12: the day

    static let newYork: Calendar = OverviewDayTests.calendar("America/New_York")

    @Test("criterion 12: an article first seen at 23:59 makes the category due that day, on the eve of a daylight-saving change")
    func dueAt2359() async throws {
        let fixture = try await Fixture.make(calendar: Self.newYork)
        defer { fixture.remove() }
        fixture.setClock(to: OverviewDayTests.local("2026-03-07 23:59:00", "America/New_York"))
        let category = try await fixture.category()
        let source = try await fixture.source(in: category)
        try await fixture.article("News story 01", in: source, at: fixture.clock.now())
        fixture.clock.advance(seconds: 30)
        await fixture.runDue()
        #expect(try await fixture.rows(of: category).map(\.day) == ["2026-03-07"])
    }

    @Test("criterion 12: a job queued at 23:59 and started at 00:01 is stored under the new day")
    func queuedBeforeMidnight() async throws {
        let fixture = try await Fixture.make(calendar: Self.newYork)
        defer { fixture.remove() }
        fixture.setClock(to: OverviewDayTests.local("2026-03-07 23:58:00", "America/New_York"))
        let (busy, _, _) = try await fixture.filledCategory("Busy", mode: .manual)
        let (category, source, _) = try await fixture.filledCategory("Late")
        fixture.gate.hold(.jobRead)
        // The worker is held at the first job (Busy, manual); Late is queued at 23:59.
        let busyOutcome = Task { await fixture.writer.write(category: busy) }
        await fixture.reach(.jobRead)
        fixture.setClock(to: OverviewDayTests.local("2026-03-07 23:59:00", "America/New_York"))
        await fixture.writer.runDue()
        await fixture.eventually { fixture.lastWorking?.contains(category) == true }
        fixture.setClock(to: OverviewDayTests.local("2026-03-08 00:01:00", "America/New_York"))
        try await fixture.article("Late story 09", in: source, at: OverviewDayTests.local("2026-03-08 00:00:30", "America/New_York"))
        fixture.gate.release(.jobRead)
        #expect(await busyOutcome.value == .stored)
        await fixture.writer.settled()
        #expect(try await fixture.rows(of: busy).map(\.day) == ["2026-03-08"], "a job's day is fixed at its read")
        #expect(try await fixture.rows(of: category).map(\.day) == ["2026-03-08"])
    }

    @Test("criterion 12: a reply arriving after midnight is stored under the day fixed at the job's read")
    func replyAfterMidnight() async throws {
        let fixture = try await Fixture.make(calendar: Self.newYork)
        defer { fixture.remove() }
        fixture.setClock(to: OverviewDayTests.local("2026-11-01 23:59:00", "America/New_York"))
        let (category, _, _) = try await fixture.filledCategory()
        fixture.service.hold(request: 1)
        let run = Task { await fixture.runDue() }
        await fixture.requested(1)
        fixture.setClock(to: OverviewDayTests.local("2026-11-02 00:02:00", "America/New_York"))
        fixture.service.release(request: 1)
        await run.value
        #expect(try await fixture.rows(of: category).map(\.day) == ["2026-11-01"])
    }

    // MARK: - Criterion 13: partitions

    /// Both libraries of one store, each with its own models over one
    /// recording service, and a writer per library.
    struct Partitions {
        let directory: URL
        let normal: Library
        let adult: Library
        let service: TranslationService
        let normalModels: LibraryModels
        let adultModels: LibraryModels

        static func make() async throws -> Partitions {
            let directory = try makeTemporaryDirectory()
            let store = LibraryStore(directory: directory, cacheRoot: directory.appending(path: "Images"))
            let normal = try await store.openNormal()
            let adult = try await store.createAdultLibrary()
            let service = TranslationService(Fixture.goodRule)
            return Partitions(
                directory: directory, normal: normal, adult: adult, service: service,
                normalModels: LibraryModels(library: normal, keys: InMemoryKeyStore(partition: .normal), http: service),
                adultModels: LibraryModels(library: adult, keys: InMemoryKeyStore(partition: .adult), http: service)
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }

        static func save(_ models: LibraryModels, host: String) async throws {
            try await models.save(
                ModelSlotDraft(role: .primary, preset: .custom, address: "https://\(host)/v1", model: "m-\(host)", newKey: key("sk-\(host)-0123456789")),
                testedOutcome: nil
            )
        }

        static func usageCount(_ library: Library) async throws -> Int {
            try await library.pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage") ?? -1 }
        }

        static func dueCategory(_ library: Library) async throws -> UUID {
            let category = try await library.createCategory(name: "Private", icon: .newspaper)
            let source = Sample.source(in: category.id, url: "https://\(UUID().uuidString.prefix(8)).example.invalid/feed", at: Date())
            try await library.insert(source)
            try await library.insert(Sample.article(in: source.id, externalID: "x", title: "Private story 01", at: Date()))
            return category.id
        }
    }

    @Test("criterion 13: with working normal slots and none in the adult library, the adult writer sends nothing and writes no usage row anywhere")
    func adultWithoutSlots() async throws {
        let partitions = try await Partitions.make()
        defer { partitions.remove() }
        try await Partitions.save(partitions.normalModels, host: "normal.example.invalid")
        _ = try await partitions.normalModels.send(texts: ["Hello"], instructions: "Repeat.", purpose: .test, role: .primary)
        let category = try await Partitions.dueCategory(partitions.adult)
        let writer = OverviewWriter(models: partitions.adultModels, front: AppFront(isInFront: true))
        await writer.configure(locale: .simplifiedChinese)

        await writer.runDue()
        await writer.settled()
        let outcome = await writer.write(category: category)
        guard case .notStored(let block) = outcome else {
            Issue.record("expected notStored, got \(outcome)")
            return
        }
        #expect(block.reason == .setUp(.noModelSetUp))

        #expect(partitions.service.requests.count == 1, "the normal test request only")
        #expect(try await Partitions.usageCount(partitions.adult) == 0)
        #expect(try await Partitions.usageCount(partitions.normal) == 1)
        let rows = try await partitions.adult.pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM overview") ?? -1 }
        #expect(rows == 0)
    }

    @Test("criterion 13: with adult slots the adult overview's usage rows are in the adult library only, its request to the adult host")
    func adultWithSlots() async throws {
        let partitions = try await Partitions.make()
        defer { partitions.remove() }
        try await Partitions.save(partitions.normalModels, host: "normal.example.invalid")
        try await Partitions.save(partitions.adultModels, host: "adult.example.invalid")
        let category = try await Partitions.dueCategory(partitions.adult)
        let writer = OverviewWriter(models: partitions.adultModels, front: AppFront(isInFront: true))
        await writer.configure(locale: .simplifiedChinese)
        #expect(await writer.write(category: category) == .stored)
        #expect(partitions.service.requests.map(\.host) == ["adult.example.invalid"])
        #expect(try await Partitions.usageCount(partitions.adult) == 1)
        #expect(try await Partitions.usageCount(partitions.normal) == 0)
        let normalRows = try await partitions.normal.pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM overview") ?? -1 }
        #expect(normalRows == 0)
    }

    // MARK: - Criterion 14: each held window (decision 11)

    @Test("criterion 14 (a): a locale change during the job's read drops an automatic job; the next run writes in the new locale")
    func localeChangeDuringRead() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let (category, _, _) = try await fixture.filledCategory()
        fixture.gate.hold(.jobRead)
        let run = Task { await fixture.runDue() }
        await fixture.reach(.jobRead)
        await fixture.writer.configure(locale: .japanese)
        fixture.gate.release(.jobRead)
        await run.value
        #expect(fixture.service.requests.isEmpty)
        #expect(try await fixture.rows().isEmpty)
        await fixture.runDue()
        #expect(try await fixture.rows(of: category).map(\.locale) == ["ja"])
    }

    @Test("criterion 14 (a): a manual job whose read meets a locale change answers cancelled and sends nothing")
    func manualLocaleChangeDuringRead() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let (category, _, _) = try await fixture.filledCategory(mode: .manual)
        fixture.gate.hold(.jobRead)
        let outcome = Task { await fixture.writer.write(category: category) }
        await fixture.reach(.jobRead)
        await fixture.writer.configure(locale: .english)
        fixture.gate.release(.jobRead)
        #expect(await outcome.value == .cancelled)
        #expect(fixture.service.requests.isEmpty)
    }

    @Test("criterion 14 (a): a manual done stored before an automatic job's read makes it drop")
    func manualBeforeAutomaticRead() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let (first, _, _) = try await fixture.filledCategory("First")
        let (second, _, _) = try await fixture.filledCategory("Second")
        fixture.gate.hold(.jobRead)
        let run = Task { await fixture.writer.runDue() }
        await fixture.reach(.jobRead)
        await run.value
        // First is held at its read; Second waits behind it; a manual job for Second is served first.
        let manual = Task { await fixture.writer.write(category: second) }
        await fixture.eventually { await fixture.writer.queuedManualJobs == 1 }
        fixture.gate.release(.jobRead)
        #expect(await manual.value == .stored)
        await fixture.writer.settled()
        #expect(fixture.requests(for: "Second").count == 1)
        #expect(fixture.requests(for: "First").count == 1)
        #expect(try await fixture.rows(of: second).count == 1)
        #expect(try await fixture.usage().filter { !$0.automatic }.count == 1)
        _ = first
    }

    @Test("criterion 14 (d): a slot repair while a 401 is in flight leaves no hold and no block; the next run writes")
    func slotRepairDuringSend() async throws {
        let fixture = try await Fixture.make(service: TranslationService { _, _, _ in .status(401) })
        defer { fixture.remove() }
        let (category, _, _) = try await fixture.filledCategory()
        fixture.service.hold(request: 1)
        let run = Task { await fixture.runDue() }
        await fixture.requested(1)
        try await fixture.saveSlot(.primary, model: "repaired-model")
        await fixture.writer.slotsChanged()
        fixture.service.release(request: 1)
        await run.value
        fixture.service.answer(with: Fixture.goodRule)
        #expect(await !fixture.writer.isHeld)
        #expect(fixture.blocked.isEmpty)
        #expect(try await fixture.rows().isEmpty)
        await fixture.runDue()
        #expect(try await fixture.rows(of: category).map(\.state) == ["done"])
    }

    @Test("criterion 14 (d): an accepted reply of the old slots is stored even though the slots changed")
    func acceptedAfterSlotChange() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let (category, _, _) = try await fixture.filledCategory()
        fixture.service.hold(request: 1)
        let run = Task { await fixture.runDue() }
        await fixture.requested(1)
        try await fixture.saveSlot(.primary, model: "another-model")
        await fixture.writer.slotsChanged()
        fixture.service.release(request: 1)
        await run.value
        #expect(try await fixture.rows(of: category).map(\.state) == ["done"])
    }

    @Test("criterion 14 (d): stop while the request is held: nothing stored or blocked; a manual job answers cancelled")
    func stopDuringSend() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let (category, _, _) = try await fixture.filledCategory(mode: .manual)
        fixture.service.hold(request: 1)
        let outcome = Task { await fixture.writer.write(category: category) }
        await fixture.requested(1)
        await fixture.writer.stop()
        #expect(await outcome.value == .cancelled)
        await fixture.writer.settled()
        #expect(try await fixture.rows().isEmpty)
        #expect(fixture.blocked.isEmpty)
        #expect(await fixture.writer.write(category: category) == .cancelled, "nothing starts again")
    }

    @Test("criterion 14 (d): a category move with sources staying, committed while the request is held, leaves no overview in the old library",
          arguments: [false, true])
    func moveDuringSend(automatic: Bool) async throws {
        let move = try await CategoryMoveTests.Fixture.make(toAdult: true, twin: true)
        defer { move.remove() }
        let service = TranslationService(Fixture.goodRule)
        let models = LibraryModels(library: move.old, keys: InMemoryKeyStore(partition: .normal), http: service)
        try await models.save(
            ModelSlotDraft(role: .primary, preset: .custom, address: "https://primary.example.invalid/v1", model: "m", newKey: key("sk-move-0123456789")),
            testedOutcome: nil
        )
        let now = Date()
        let writer = OverviewWriter(models: models, front: AppFront(isInFront: true), now: { now }, calendar: OverviewFixture.utc)
        await writer.configure(locale: .simplifiedChinese)
        if !automatic {
            try await move.old.setCategoryOverview(move.category, to: .manual)
        }
        service.hold(request: 1)
        let job = Task {
            if automatic {
                await writer.runDue()
                await writer.settled()
                return OverviewWriteOutcome.cancelled
            }
            return await writer.write(category: move.category)
        }
        let deadline = ContinuousClock.now + TranslatorFixture.eventualBound
        while service.requests.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(service.requests.first?.texts.count == 6, "Alpha's, Beta's and Gamma's articles")
        let plan = try await move.plan()
        #expect(await CategoryMove.run(plan, from: move.old, to: move.destination) == .moved(staying: 1, categoryRemoved: false))
        service.release(request: 1)
        let outcome = await job.value
        await writer.settled()
        #expect(outcome == (automatic ? .cancelled : .gone))
        let category = move.category.databaseKey
        let rows = try await move.old.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM overview WHERE category_id = ?", arguments: [category]) ?? -1
        }
        #expect(rows == 0)
    }

    @Test("criterion 14 (e): a slot repair during the backup check sends nothing to the backup and blocks nothing")
    func slotRepairDuringBackupCheck() async throws {
        let fixture = try await Fixture.make(service: TranslationService { _, _, _ in .status(503) }, backup: true)
        defer { fixture.remove() }
        _ = try await fixture.filledCategory()
        fixture.gate.hold(.backupCheck)
        let run = Task { await fixture.runDue() }
        await fixture.reach(.backupCheck)
        try await fixture.saveSlot(.primary, model: "repaired-model")
        await fixture.writer.slotsChanged()
        fixture.gate.release(.backupCheck)
        await run.value
        #expect(fixture.service.requests.map(\.host) == [Fixture.primaryHost])
        #expect(fixture.blocked.isEmpty)
        #expect(try await fixture.rows().isEmpty)
    }

    @Test("criterion 14 (f): a slot save committed during the store, before the writer hears of it, stores no failed row")
    func slotSaveDuringStore() async throws {
        let fixture = try await Fixture.make(service: TranslationService { _, _, _ in .refusal })
        defer { fixture.remove() }
        let (category, _, _) = try await fixture.filledCategory(mode: .manual)
        fixture.gate.hold(.store)
        let outcome = Task { await fixture.writer.write(category: category) }
        await fixture.reach(.store)
        try await fixture.saveSlot(.primary, model: "repaired-model")
        fixture.gate.release(.store)
        #expect(await outcome.value == .cancelled)
        #expect(try await fixture.rows().isEmpty)
    }

    @Test("criterion 14 (f): a Test outcome written during the store does not prevent the failed row")
    func testOutcomeDuringStore() async throws {
        let fixture = try await Fixture.make(service: TranslationService { _, _, _ in .refusal })
        defer { fixture.remove() }
        let (category, _, _) = try await fixture.filledCategory(mode: .manual)
        fixture.gate.hold(.store)
        let outcome = Task { await fixture.writer.write(category: category) }
        await fixture.reach(.store)
        let slot = try await fixture.library.modelSlot(.primary)!
        try await fixture.library.setModelTestOutcome(.passed, role: .primary, baseURL: slot.baseURL, model: slot.model, keyRef: slot.keyRef!)
        fixture.gate.release(.store)
        #expect(await outcome.value == .failed(.refused))
        #expect(try await fixture.rows(of: category).map(\.state) == ["failed"])
    }

    @Test("criterion 14 (f): a sent article deleted during the store: nothing stored, a manual job answers gone, an automatic one is due again")
    func articleDeletedDuringStore() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let (category, source, ids) = try await fixture.filledCategory()
        fixture.gate.hold(.store)
        let run = Task { await fixture.runDue() }
        await fixture.reach(.store)
        try await fixture.library.pool.write { db in try db.execute(sql: "DELETE FROM article WHERE id = ?", arguments: [ids[0].databaseKey]) }
        fixture.gate.release(.store)
        await run.value
        #expect(try await fixture.rows().isEmpty)
        #expect(fixture.blocked.isEmpty)
        // Due again: the next run writes from the articles left.
        await fixture.runDue()
        #expect(fixture.overviewRequests.last?.texts.count == 2)
        #expect(try await fixture.rows(of: category).count == 1)
        _ = source
    }

    @Test("criterion 14 (f): the source deleted during a manual job's store: gone, and today's overview is kept")
    func sourceDeletedDuringManualStore() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let (category, _, _) = try await fixture.filledCategory(mode: .manual)
        let otherSource = try await fixture.source(in: category, name: "Other")
        #expect(await fixture.write(category) == .stored)
        try await fixture.articles(1, in: otherSource, prefix: "Other")
        let hold = OverviewGate()
        await fixture.writer.setSuspensionHook { point in await hold.arrive(point) }
        hold.hold(.store)
        let outcome = Task { await fixture.writer.write(category: category) }
        await fixture.eventually { hold.reached(.store) }
        try await fixture.library.deleteSource(otherSource)
        hold.release(.store)
        #expect(await outcome.value == .gone)
        #expect(try await fixture.rows(of: category).map(\.state) == ["done"])
    }
}
