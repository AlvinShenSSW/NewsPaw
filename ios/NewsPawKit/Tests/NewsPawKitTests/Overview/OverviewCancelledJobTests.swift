import Foundation
@testable import NewsPawKit
import Testing

/// #189: the app returns to the front while a job the background cancelled
/// is still unwinding. The entry's due check owes that job's category
/// another job, queued behind the cancelled one: when it ends, the one
/// worker takes it in the same entry, and the job's own read judges it
/// afresh (mode, row of the day, first seen that day, language, limit, the
/// app's state). Interleavings are held by the writer's hold points and the
/// stub service.
@Suite("Overview: a cancelled job and the returning app (#189)")
struct OverviewCancelledJobTests {
    typealias Fixture = OverviewFixture
    typealias Box = OverviewReviewRoundOneTests.Box

    /// Where the cancelled job is held while the app leaves and returns.
    enum Hold: String, CaseIterable, Sendable {
        case jobRead
        case slotRead
        case limitRead
        case send
        /// Its request answered, the service holding the reply through the
        /// cancellation.
        case request
        /// Its reply accepted, before its store (the gate's interleaving).
        case store

        var point: OverviewWriter.SuspensionPoint? {
            switch self {
            case .jobRead: .jobRead
            case .slotRead: .slotRead
            case .limitRead: .limitRead
            case .send: .send(.primary)
            case .request: nil
            case .store: .store
            }
        }

        /// Whether the cancelled job's request had gone out.
        var sent: Bool {
            self == .request || self == .store
        }
    }

    /// Starts the run's due check, holds its first job at `hold`, and sends
    /// the app to the background and back to the front, where the entry's
    /// due check runs before the held job is released.
    private func cancelledThenEntered(_ fixture: Fixture, at hold: Hold) async {
        if let point = hold.point {
            fixture.gate.hold(point)
        } else {
            fixture.service.hold(request: 1, ignoringCancellation: true)
        }
        await fixture.writer.runDue()
        if let point = hold.point {
            await fixture.reach(point)
        } else {
            await fixture.requested(1)
        }
        await fixture.enterBackground()
        fixture.front.set(isInFront: true)
        await fixture.writer.runDue()
    }

    private func release(_ fixture: Fixture, at hold: Hold) {
        if let point = hold.point {
            fixture.gate.release(point)
        } else {
            fixture.service.release(request: 1)
        }
    }

    // MARK: - The gate's interleaving

    @Test("the entry's due check meets a cancelled job still unwinding: when it ends, the category is written in the same entry with one request, in the owner's order", arguments: Hold.allCases)
    func entryWritesTheCancelledJobsCategory(at hold: Hold) async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let (news, _, _) = try await fixture.filledCategory("News")
        let (later, _, _) = try await fixture.filledCategory("Later")
        let writer = fixture.writer
        await cancelledThenEntered(fixture, at: hold)

        // While the cancelled job unwinds: one worker, nothing sent, both
        // categories owed in the owner's order.
        #expect(await writer.workersAlive == 1, "the cancelled worker is not replaced while it unwinds")
        #expect(await writer.inFlightCategory == news)
        #expect(await writer.queuedAutomaticJobs == 2, "the cancelled job's category is owed, not filtered out")
        #expect(fixture.service.requests.count == (hold.sent ? 1 : 0))

        release(fixture, at: hold)
        await writer.settled()
        #expect(try await fixture.rows(of: news).map(\.state) == ["done"], "written in this entry, not at the next")
        #expect(try await fixture.rows(of: later).map(\.state) == ["done"])
        let before = hold.sent ? 1 : 0
        #expect(fixture.overviewRequests.count == before + 2, "one request per category in the entry")
        #expect(fixture.requests(for: "News").count == before + 1)
        #expect(fixture.requests(for: "Later").count == 1)
        #expect(fixture.overviewRequests.dropFirst(before).first?.texts.first?.hasPrefix("[1] News story") == true, "the owner's order")
        #expect(fixture.service.mostInFlight == 1, "one request at most in flight")
        #expect(fixture.blocked.isEmpty)
        #expect(await writer.dueChecks == 2, "no due check beyond the entry's")
        #expect(fixture.lastWorking == [])

        // A later run that day sends nothing more.
        await fixture.runDue()
        #expect(fixture.overviewRequests.count == before + 2)
    }

    @Test("a manual write asked for while the cancelled job unwinds runs first; a write of the owed category itself is the only request, and the automatic job drops", arguments: [false, true])
    func manualWriteMeanwhileKeepsItsOrder(ofTheOwedCategory: Bool) async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let (news, _, _) = try await fixture.filledCategory("News")
        let (desk, _, _) = try await fixture.filledCategory("Desk", mode: .manual)
        let writer = fixture.writer
        await cancelledThenEntered(fixture, at: .store)
        let target = ofTheOwedCategory ? news : desk
        let outcome = Box<OverviewWriteOutcome>()
        Task { outcome.set(await writer.write(category: target)) }
        await fixture.eventually { await writer.queuedManualJobs == 1 }
        #expect(fixture.service.requests.count == 1)

        release(fixture, at: .store)
        await fixture.eventually { outcome.current != nil }
        await writer.settled()
        #expect(outcome.current == .stored)
        #expect(try await fixture.rows(of: news).map(\.state) == ["done"])
        let names = fixture.overviewRequests.map { $0.texts.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "" }
        if ofTheOwedCategory {
            #expect(names == ["News", "News"], "the earlier, cancelled request and the manual one: the automatic job drops at its read")
        } else {
            #expect(names == ["News", "Desk", "News"], "the manual write before the owed automatic job")
            #expect(try await fixture.rows(of: desk).map(\.state) == ["done"])
        }
        #expect(fixture.service.mostInFlight == 1)
        #expect(fixture.blocked.isEmpty)
    }

    // MARK: - The owed job is judged afresh when it runs

    /// What happens while the cancelled job unwinds, after the entry's due
    /// check owed its category.
    enum Meanwhile: String, CaseIterable, Sendable {
        case turnedOff
        case setToManual
        case deleted
        case languageChanged
        case dayChanged
        case backgroundAgain
        case leftTheFrontOnly
        case dailyLimit
    }

    @Test("the owed job is judged at its own read and send, not replayed", arguments: Meanwhile.allCases)
    func owedJobIsJudgedAfresh(_ meanwhile: Meanwhile) async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let (news, _, _) = try await fixture.filledCategory("News")
        let writer = fixture.writer
        await cancelledThenEntered(fixture, at: .store)
        #expect(await writer.queuedAutomaticJobs == 1)
        switch meanwhile {
        case .turnedOff:
            try await fixture.library.setCategoryOverview(news, to: .off)
        case .setToManual:
            try await fixture.library.setCategoryOverview(news, to: .manual)
        case .deleted:
            try await fixture.library.deleteCategory(news, sources: .deleteSources)
        case .languageChanged:
            await writer.configure(locale: .english)
        case .dayChanged:
            fixture.setClock(to: OverviewDay.start(of: fixture.clock.now(), calendar: fixture.calendar).addingTimeInterval(86_400 + 3_600))
        case .backgroundAgain:
            await fixture.enterBackground()
        case .leftTheFrontOnly:
            // The state is read before its event arrives.
            fixture.front.set(isInFront: false)
        case .dailyLimit:
            // The cancelled job's request is the day's first.
            try await fixture.library.setDailyAutomaticLimit(1)
        }
        release(fixture, at: .store)
        await writer.settled()
        let rows = try await fixture.rows(of: news)
        switch meanwhile {
        case .turnedOff, .setToManual, .deleted, .dayChanged:
            #expect(fixture.overviewRequests.count == 1, "the owed job dropped at its read: nothing sent")
            #expect(rows.isEmpty)
            #expect(fixture.blocked.isEmpty)
        case .languageChanged:
            #expect(fixture.overviewRequests.count == 2, "one request in the entry")
            #expect(rows.map(\.locale) == ["en"], "written in the language read when it ran")
            #expect(fixture.overviewRequests.last?.system.contains("English (en)") == true)
        case .backgroundAgain, .leftTheFrontOnly:
            #expect(fixture.overviewRequests.count == 1, "nothing sent out of front")
            #expect(rows.isEmpty)
            #expect(fixture.blocked.isEmpty)
            // The next entry in front writes it.
            if meanwhile == .leftTheFrontOnly {
                await writer.enteredBackground()
            }
            fixture.front.set(isInFront: true)
            await fixture.runDue()
            #expect(try await fixture.rows(of: news).map(\.state) == ["done"])
            #expect(fixture.overviewRequests.count == 2)
        case .dailyLimit:
            #expect(fixture.overviewRequests.count == 1, "nothing sent at the limit")
            #expect(rows.isEmpty)
            #expect(fixture.blocked[news]?.reason == .dailyLimit)
        }
        #expect(fixture.service.mostInFlight == 1)
    }

    // MARK: - The reverse cases

    @Test("a due check out of front while the cancelled job unwinds owes nothing; the job ends sending nothing more")
    func outOfFrontEntryOwesNothing() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let (news, _, _) = try await fixture.filledCategory("News")
        let writer = fixture.writer
        fixture.gate.hold(.store)
        await writer.runDue()
        await fixture.reach(.store)
        await fixture.enterBackground()
        await writer.runDue()
        #expect(await writer.queuedAutomaticJobs == 0)
        fixture.gate.release(.store)
        await writer.settled()
        #expect(fixture.service.requests.count == 1)
        #expect(try await fixture.rows(of: news).isEmpty)
        #expect(fixture.blocked.isEmpty)
    }

    @Test("a job cancelled at its read, owed by the entry, blocks nothing on its way out; the owed job meets the limit itself")
    func cancelledAtItsReadBlocksNothing() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let (news, _, _) = try await fixture.filledCategory("News")
        try await fixture.library.setDailyAutomaticLimit(0)
        await cancelledThenEntered(fixture, at: .jobRead)
        fixture.gate.release(.jobRead)
        await fixture.writer.settled()
        #expect(fixture.service.requests.isEmpty)
        // Blocked once, by the owed job's own limit check: the cancelled job
        // reported no block of its own.
        let blockEvents = fixture.reported.filter { if case .blocked = $0 { true } else { false } }
        #expect(blockEvents.count == 1)
        #expect(fixture.blocked[news]?.reason == .dailyLimit)
    }
}
