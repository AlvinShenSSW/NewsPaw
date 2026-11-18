import Foundation
import GRDB
@testable import NewsPawKit
import Synchronization
import Testing

/// RD23 review round 1: the writer is foreground-only (R1), a manual job
/// waits for the calls sent before it (G1), a card shows only a row of
/// today and the reading language (G2), a manual set-up failure holds the
/// queued automatic jobs (R2), a one-text highlight is its own line (R3),
/// cleaning a title is linear (R4), and a failed due read blocks for
/// storage (R7).
@Suite("Overview review round 1")
struct OverviewReviewRoundOneTests {
    typealias Fixture = OverviewFixture

    /// Holds what a task returned, for a bounded wait on it.
    final class Box<Value: Sendable>: Sendable {
        private let value = Mutex<Value?>(nil)
        func set(_ new: Value) { value.withLock { $0 = new } }
        var current: Value? { value.withLock { $0 } }
    }

    // MARK: - R1: foreground only

    @Test("R1: entering the background cancels the request in flight: nothing stored, its usage row says cancelled, the writer goes on")
    func backgroundCancelsTheRequestInFlight() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let (category, _, _) = try await fixture.filledCategory(mode: .manual)
        fixture.service.hold(request: 1)
        let box = Box<OverviewWriteOutcome>()
        let writer = fixture.writer
        Task { box.set(await writer.write(category: category)) }
        await fixture.requested(1)
        await fixture.enterBackground()
        await fixture.eventually { box.current != nil }
        // Let a request that was not cancelled go, so that the test ends.
        fixture.service.release(request: 1)
        #expect(box.current == .cancelled)
        await fixture.writer.settled()
        #expect(try await fixture.rows().isEmpty)
        try await fixture.eventually { try await fixture.usage().count == 1 }
        #expect(try await fixture.usage().map(\.outcome) == [.cancelled])

        fixture.front.set(isInFront: true)
        #expect(await fixture.write(category) == .stored)
    }

    @Test("R1: in the background a due check and a manual job start nothing; in front again they do")
    func backgroundStartsNothing() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let (category, _, _) = try await fixture.filledCategory()
        await fixture.enterBackground()
        await fixture.runDue()
        #expect(await fixture.writer.queuedAutomaticJobs == 0, "the due check queued nothing")
        #expect(await fixture.write(category) == .cancelled)
        #expect(fixture.service.requests.isEmpty)
        #expect(try await fixture.rows().isEmpty)

        fixture.front.set(isInFront: true)
        await fixture.runDue()
        #expect(try await fixture.rows(of: category).map(\.state) == ["done"])
    }

    @Test("R1: entering the background drops the queued automatic jobs; they are due again at the next run in front")
    func backgroundDropsTheQueue() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let (first, _, _) = try await fixture.filledCategory("First")
        let (second, _, _) = try await fixture.filledCategory("Second")
        fixture.service.hold(request: 1)
        await fixture.writer.runDue()
        await fixture.requested(1)
        await fixture.enterBackground()
        // Let a request that was not cancelled go, so that the test ends.
        fixture.service.release(request: 1)
        await fixture.writer.settled()
        #expect(fixture.service.requests.count == 1, "the second category was not sent")
        #expect(try await fixture.rows().isEmpty, "nothing stored")

        fixture.front.set(isInFront: true)
        await fixture.runDue()
        #expect(try await fixture.rows(of: first).map(\.state) == ["done"])
        #expect(try await fixture.rows(of: second).map(\.state) == ["done"])
    }

    // MARK: - G1: a manual job after the calls before it

    @Test("G1: a manual job sent while a due check holds a language change behind it is written in the new language")
    func manualWriteWaitsForAQueuedConfiguration() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let (category, _, _) = try await fixture.filledCategory(mode: .manual)
        let chain = OverviewChain(writer: fixture.writer)
        fixture.gate.hold(.dueRead)
        chain.send { await $0.runDue() }
        await fixture.reach(.dueRead)
        chain.send { await $0.configure(locale: .english) }
        let outcome = Task { await chain.write(category: category) }
        fixture.gate.release(.dueRead)
        #expect(await outcome.value == .stored)
        #expect(try await fixture.rows(of: category).map(\.locale) == ["en"])
        #expect(fixture.overviewRequests.allSatisfy { $0.system.contains("English (en)") })
    }

    // MARK: - G2: only today's row in the reading language

    static func row(day: String, locale: ReadingLocale, state: OverviewState = .done) -> StoredOverview {
        StoredOverview(
            id: UUID(), categoryID: UUID(), day: day, locale: locale, state: state, text: state == .done ? "Summary." : nil,
            highlights: [], articleCount: 3, model: "m", failure: state == .failed ? .refused : nil, createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test("G2: a cached row of another day or another reading language is not shown, done or failed")
    func cachedRowOfAnotherDayOrLanguage() {
        func state(_ row: StoredOverview?) -> OverviewCardState {
            OverviewCardRule.state(
                mode: .auto, row: row, working: false, block: nil, hasPrimary: true, newCount: 4, day: "2027-01-15", locale: .simplifiedChinese
            )
        }
        let today = Self.row(day: "2027-01-15", locale: .simplifiedChinese)
        #expect(state(today) == .done(today, working: false))
        #expect(state(Self.row(day: "2027-01-14", locale: .simplifiedChinese)) == .write(count: 4))
        #expect(state(Self.row(day: "2027-01-15", locale: .english)) == .write(count: 4))
        #expect(state(Self.row(day: "2027-01-14", locale: .simplifiedChinese, state: .failed)) == .write(count: 4))
        #expect(state(Self.row(day: "2027-01-15", locale: .simplifiedChinese, state: .failed)) == .failed(.stored(.refused)))
    }

    @Test("the card rule keeps decision 12's order: off, done, working, failed or blocked, no model, write, nothing new")
    func cardRuleOrder() {
        let day = "2027-01-15"
        func state(
            mode: OverviewMode = .auto, row: StoredOverview? = nil, working: Bool = false, block: OverviewBlock? = nil,
            hasPrimary: Bool = true, newCount: Int = 0
        ) -> OverviewCardState {
            OverviewCardRule.state(
                mode: mode, row: row, working: working, block: block, hasPrimary: hasPrimary, newCount: newCount, day: day,
                locale: .simplifiedChinese
            )
        }
        let done = Self.row(day: day, locale: .simplifiedChinese)
        let block = OverviewBlock(reason: .dailyLimit, day: day, locale: .simplifiedChinese)
        #expect(state(mode: .off, row: done) == .off)
        #expect(state(row: done, working: true) == .done(done, working: true))
        #expect(state(working: true, block: block) == .working)
        #expect(state(block: block, hasPrimary: false) == .failed(.blocked(.dailyLimit)))
        #expect(state(block: OverviewBlock(reason: .dailyLimit, day: "2027-01-14", locale: .simplifiedChinese), newCount: 2) == .write(count: 2))
        #expect(state(hasPrimary: false, newCount: 2) == .noModel)
        #expect(state(newCount: 2) == .write(count: 2))
        #expect(state() == .nothingNew)
    }

    // MARK: - R2: a manual set-up failure holds the queued automatic jobs

    @Test("R2: a manual job's set-up failure holds the automatic jobs queued behind it: none is sent, each is blocked")
    func manualSetUpFailureHoldsTheQueue() async throws {
        let fixture = try await Fixture.make(service: TranslationService { _, _, _ in .status(401) })
        defer { fixture.remove() }
        let (manual, _, _) = try await fixture.filledCategory("Manual", mode: .manual)
        let (first, _, _) = try await fixture.filledCategory("Auto1")
        let (second, _, _) = try await fixture.filledCategory("Auto2")
        fixture.gate.hold(.jobRead)
        let outcome = Task { await fixture.writer.write(category: manual) }
        await fixture.reach(.jobRead)
        await fixture.writer.runDue()
        fixture.gate.release(.jobRead)
        let result = await outcome.value
        await fixture.writer.settled()
        #expect(result == .notStored(OverviewBlock(reason: .setUp(.keyRejected), day: fixture.today, locale: .simplifiedChinese)))
        #expect(fixture.service.requests.count == 1)
        #expect(try await fixture.usage().filter(\.automatic).isEmpty)
        #expect(await fixture.writer.isHeld)
        #expect(fixture.blocked[first]?.reason == .setUp(.keyRejected))
        #expect(fixture.blocked[second]?.reason == .setUp(.keyRejected))
    }

    // MARK: - R3: a one-text highlight is its own line

    @Test("R3: in a one-text reply the lines after a [n] line that are not [n] lines are left out, a trailing note included")
    func oneTextTrailingNote() {
        let reply = ModelReply(
            texts: ["Summary.\n[1] One.\n\nThese are based on titles only.\n[2] Two,\ncontinued."], isCutOff: false, inputTokens: nil, outputTokens: nil
        )
        guard case .success(let accepted) = OverviewAcceptance.check(reply: reply, count: 3) else {
            Issue.record("rejected")
            return
        }
        #expect(accepted.summary == "Summary.")
        #expect(accepted.highlights.map(\.text) == ["One.", "Two,"])
    }

    // MARK: - R4: cleaning is linear

    @Test("R4: cleaning a title of 40,000 leading [n] or (n) takes less than 20 times as long as cleaning a plain title of the same length")
    func cleaningLeadingNumbersIsCheap() {
        func fastest(_ text: String) -> Duration {
            var best = Duration.seconds(1_000)
            for _ in 0..<3 {
                let start = ContinuousClock.now
                _ = OverviewPrompt.clean(text)
                best = min(best, ContinuousClock.now - start)
            }
            return best
        }
        for unit in ["[1]", "(1) "] {
            let count = 40_000
            let numbered = fastest(String(repeating: unit, count: count) + " title")
            // The reference, measured beside it: a title of the same length
            // with no number to strip.
            let plain = fastest(String(repeating: String(repeating: "a", count: unit.count), count: count) + " title")
            #expect(numbered < plain * 20, "\(unit): \(numbered) numbered, \(plain) plain")
        }
        #expect(OverviewPrompt.clean(String(repeating: "[1]", count: 40_000) + " title") == "title")
        #expect(OverviewPrompt.clean(" [12] (3)\t[4] Title [5] kept") == "Title [5] kept")
        #expect(OverviewPrompt.clean("[1]") == nil)
        #expect(OverviewPrompt.clean("[] (x) Title") == "[] (x) Title")
        #expect(OverviewPrompt.clean("[12 Title") == "[12 Title")
    }

    // MARK: - R7: a failed due read blocks for storage

    @Test("R7: a due check whose read fails sends nothing and blocks the automatic categories for storage")
    func failedDueReadBlocks() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let (first, _, _) = try await fixture.filledCategory("First")
        let (manual, _, _) = try await fixture.filledCategory("Manual", mode: .manual)
        try await fixture.library.pool.write { db in try db.execute(sql: "DROP TABLE overview") }
        await fixture.runDue()
        #expect(fixture.service.requests.isEmpty)
        #expect(fixture.blocked[first] == OverviewBlock(reason: .storage, day: fixture.today, locale: .simplifiedChinese))
        #expect(fixture.blocked[manual] == nil)
    }
}
