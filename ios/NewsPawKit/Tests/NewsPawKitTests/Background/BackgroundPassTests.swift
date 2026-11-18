import Foundation
import GRDB
@testable import NewsPawKit
import Testing

/// RD24 criteria 3, 6 and 7, approach 5: one background pass over the
/// normal library, its refresher and its translator.
@MainActor
@Suite("Background pass", .timeLimit(.minutes(5)))
struct BackgroundPassTests {
    @Test("not due: no request of any kind, and the pass still waits for a translator pass that was running")
    func notDueWaitsForTheTranslator() async throws {
        let fixture = try await PassFixture.make()
        defer { fixture.remove() }
        let source = try await fixture.source("Harbour")
        try await fixture.base.article("Story 01 about the harbour", in: source.id)
        try await fixture.library.setLastRefreshAt(fixture.clock.now())
        // A cold launch's pass: its first request held in flight.
        fixture.service.hold(request: 1)
        await fixture.translator.configure(TranslationConfiguration(locale: .simplifiedChinese, automatic: true))
        await fixture.eventually { fixture.service.requests.count == 1 }

        let control = BackgroundPassControl(refresher: fixture.refresher)
        let pass = fixture.pass(control)
        let ended = Flag()
        let run = Task { @MainActor in
            defer { ended.set() }
            return await pass.run()
        }
        // Three polls of the translator at least: still waiting.
        try await Task.sleep(for: .milliseconds(400))
        #expect(!ended.isSet, "the pass returned while the translator was still working")

        fixture.service.release(request: 1)
        #expect(await run.value == .notDue)
        #expect(fixture.transport.received.isEmpty)
        #expect(fixture.service.requests.count == 1)
        #expect(try await fixture.base.translation(fixture.articles(of: source.id)[0]) != nil)
    }

    @Test("Manual Only is never due: nothing is collected")
    func manualOnlyIsNotDue() async throws {
        let fixture = try await PassFixture.make()
        defer { fixture.remove() }
        try await fixture.source("Harbour")
        await fixture.startTranslator()
        let control = BackgroundPassControl(refresher: fixture.refresher)
        #expect(await fixture.pass(control, interval: .manualOnly).run() == .notDue)
        #expect(fixture.transport.received.isEmpty)
        #expect(try await fixture.library.lastRefreshAt() == nil)
    }

    @Test("due: collects once, records the time, resumes the translator and returns once it has settled, within a daily limit of 1")
    func dueCollectsAndTranslates() async throws {
        // 25 new stories: two requests' worth, and the limit allows one.
        let fixture = try await PassFixture.make(stories: 25)
        defer { fixture.remove() }
        let source = try await fixture.source("Harbour")
        try await fixture.library.setDailyAutomaticLimit(1)
        await fixture.startTranslator()
        var afterCollection = 0

        let control = BackgroundPassControl(refresher: fixture.refresher)
        let result = await fixture.pass(control) { afterCollection += 1 }.run()

        #expect(result == .collected)
        #expect(fixture.transport.received == [source.address])
        #expect(try await fixture.library.lastRefreshAt() == fixture.clock.now())
        #expect(afterCollection == 1)
        // The translator settled before the pass returned: the one request
        // allowed was sent and stored, and the rest are blocked by the limit.
        #expect(fixture.service.requests.count == 1)
        #expect(try await fixture.base.usage().count == 1)
        #expect(try await fixture.base.translationCount() == TitleTranslator.batchArticles)
        // Its reports are delivered after it has settled.
        await fixture.translator.settled()
        #expect(fixture.base.blocked.values.allSatisfy { $0 == .dailyLimit })
        #expect(fixture.base.blocked.count == 25 - TitleTranslator.batchArticles)
        #expect(await fixture.translator.sideWorkRunning == 0)
    }

    @Test("the cut: the held source is cancelled and keeps its status, articles and seen rows; nothing is recorded; the others' titles are translated")
    func cutCancelsTheUnfinished() async throws {
        let fixture = try await PassFixture.make()
        defer { fixture.remove() }
        let held = try await fixture.source("Held")
        let other = try await fixture.source("Other")
        // The held source was collected once before: it has a status,
        // articles and seen rows to keep.
        try await fixture.refresher.refresh(.source(held.id))
        await fixture.startTranslator()
        let before = try await fixture.state(of: held.id)
        #expect(before.contains { $0.hasPrefix("article:") })
        let requestsBefore = fixture.service.requests.count
        fixture.transport.hold(held.address)

        let control = BackgroundPassControl(refresher: fixture.refresher)
        let run = Task { @MainActor in await fixture.pass(control).run() }
        await fixture.eventually { fixture.refresher.collecting == [held.id] && fixture.transport.received.contains(other.address) }
        #expect(fixture.sleep.asked == [BackgroundPass.standardCut])
        fixture.sleep.wake()

        #expect(await run.value == .cancelled)
        #expect(try await fixture.state(of: held.id) == before)
        #expect(try await fixture.library.lastRefreshAt() == nil)
        let others = try await fixture.articles(of: other.id)
        #expect(others.count == 2)
        for id in others {
            #expect(try await fixture.base.translation(id)?.title?.hasPrefix("T:") == true)
        }
        #expect(fixture.service.requests.count > requestsBefore)
    }

    @Test("cancel() during the collection: the collection is cancelled, no further request is made and the pass does not wait")
    func cancelDuringCollection() async throws {
        let fixture = try await PassFixture.make()
        defer { fixture.remove() }
        let busy = try await fixture.source("Busy")
        try await fixture.base.article("Story 01 about the harbour", in: busy.id)
        let held = try await fixture.source("Held")
        let other = try await fixture.source("Other")
        // The translator is working on a request held in flight.
        fixture.service.hold(request: 1)
        await fixture.translator.configure(TranslationConfiguration(locale: .simplifiedChinese, automatic: true))
        await fixture.eventually { fixture.service.requests.count == 1 }
        fixture.transport.hold(held.address)

        let control = BackgroundPassControl(refresher: fixture.refresher)
        let run = Task { @MainActor in await fixture.pass(control).run() }
        await fixture.eventually { fixture.refresher.collecting == [held.id] && fixture.transport.received.contains(other.address) }
        control.cancel()
        #expect(fixture.refresher.collecting.isEmpty)

        // Returned with the translator's request still in flight.
        #expect(await run.value == .cancelled)
        #expect(fixture.service.requests.count == 1)
        #expect(try await fixture.library.lastRefreshAt() == nil)
        fixture.service.release(request: 1)
        await fixture.translator.settled()
        // The pass asked nothing more of the translator: the other source's
        // new stories were not looked at.
        for id in try await fixture.articles(of: other.id) {
            #expect(try await fixture.base.translation(id) == nil)
        }
    }

    @Test("release() during the collection: nothing is cancelled, the cut does nothing, the collection completes and records, and the pass does not wait")
    func releaseDuringCollection() async throws {
        let fixture = try await PassFixture.make()
        defer { fixture.remove() }
        let busy = try await fixture.source("Busy")
        try await fixture.base.article("Story 01 about the harbour", in: busy.id)
        let held = try await fixture.source("Held")
        fixture.service.hold(request: 1)
        await fixture.translator.configure(TranslationConfiguration(locale: .simplifiedChinese, automatic: true))
        await fixture.eventually { fixture.service.requests.count == 1 }
        fixture.transport.hold(held.address)

        let control = BackgroundPassControl(refresher: fixture.refresher)
        let run = Task { @MainActor in await fixture.pass(control).run() }
        await fixture.eventually { fixture.refresher.collecting == [held.id] }
        control.release()
        fixture.sleep.wake()
        // The cut's sleep has ended; give its task its turn.
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(fixture.refresher.collecting == [held.id], "the cut cancelled a released run")
        #expect(control.isCollecting)
        let ended = Flag()
        Task { @MainActor in
            await control.untilCollectionEnds()
            ended.set()
        }
        fixture.transport.release(held.address)

        #expect(await run.value == .collected)
        await fixture.eventually { ended.isSet }
        #expect(try await fixture.library.lastRefreshAt() == fixture.clock.now())
        // Returned with the translator's first request still held.
        #expect(fixture.service.requests.count == 1)
        fixture.service.release(request: 1)
        await fixture.translator.settled()
    }

    @Test("criterion 7: an entry made while a released run collects waits for that collection, then finds no refresh due: one collection, one record")
    func entryWaitsForTheCollection() async throws {
        let fixture = try await PassFixture.make()
        defer { fixture.remove() }
        let held = try await fixture.source("Held")
        await fixture.startTranslator()
        fixture.transport.hold(held.address)
        // Every write of the recorded time, counted by the database.
        try await fixture.library.pool.write { db in
            try db.execute(sql: "CREATE TEMP TABLE recorded (n INTEGER)")
            try db.execute(sql: """
                CREATE TEMP TRIGGER count_recorded AFTER UPDATE ON setting WHEN NEW.key = 'last_refresh_at'
                BEGIN INSERT INTO recorded VALUES (1); END
                """)
            try db.execute(sql: """
                CREATE TEMP TRIGGER count_recorded_insert AFTER INSERT ON setting WHEN NEW.key = 'last_refresh_at'
                BEGIN INSERT INTO recorded VALUES (1); END
                """)
        }

        let control = BackgroundPassControl(refresher: fixture.refresher)
        let run = Task { @MainActor in await fixture.pass(control).run() }
        await fixture.eventually { fixture.refresher.collecting == [held.id] }
        // The app comes to the front, and its entry is made at once, as
        // `AppModel.enter(_:)` makes it: the wait, then the entry's own due
        // check and refresh.
        control.release()
        let refresher = fixture.refresher
        let library = fixture.library
        let entry = Task { @MainActor () -> Bool in
            await control.untilCollectionEnds()
            guard try await library.refreshIsDue(every: .thirtyMinutes) else { return false }
            try await refresher.refresh(.library)
            return true
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(fixture.refresher.collecting == [held.id])
        fixture.transport.release(held.address)

        #expect(await run.value == .collected)
        #expect(try await entry.value == false, "the entry refreshed again")
        #expect(fixture.transport.received == [held.address])
        // On the writer's connection, which holds the temporary table.
        let records = try await fixture.library.pool.write { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recorded") ?? 0 }
        #expect(records == 1)
    }

    @Test("no clean-up: an unstarred article past the retention period is still there after a pass")
    func noCleanUp() async throws {
        let fixture = try await PassFixture.make()
        defer { fixture.remove() }
        let source = try await fixture.source("Old")
        let old = try await fixture.base.article("Story 01 about the harbour", in: source.id)
        // 400 days later: past every retention period.
        fixture.clock.advance(seconds: 400 * 86_400)
        await fixture.startTranslator()
        let control = BackgroundPassControl(refresher: fixture.refresher)
        #expect(await fixture.pass(control).run() == .collected)
        let kept = try await fixture.library.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article WHERE id = ?", arguments: [old.databaseKey]) ?? 0
        }
        #expect(kept == 1)
    }

    @Test("a run that ended before the collection starts none")
    func endedBeforeCollection() async throws {
        let fixture = try await PassFixture.make()
        defer { fixture.remove() }
        try await fixture.source("Harbour")
        await fixture.startTranslator()
        for end in [true, false] {
            let control = BackgroundPassControl(refresher: fixture.refresher)
            if end {
                control.cancel()
            } else {
                control.release()
            }
            #expect(await fixture.pass(control).run() == .cancelled)
        }
        #expect(fixture.transport.received.isEmpty)
    }

    @Test("the result carries no payload")
    func resultIsCaseIterable() {
        #expect(BackgroundPassResult.allCases == [.notDue, .collected, .cancelled, .failed])
    }
}
