import Foundation
@testable import NewsPawKit
import Testing

/// RD23 review round 2: a worker cancelled by the background leaves the
/// writer's state to the work after it (one worker at a time, and a
/// cancelled job changes nothing on its way out), and a change of the
/// reading language before a job's first request drops the job.
@Suite("Overview review round 2")
struct OverviewReviewRoundTwoTests {
    typealias Fixture = OverviewFixture
    typealias Box = OverviewReviewRoundOneTests.Box

    // MARK: - A cancelled worker on its way out

    @Test("a worker cancelled by the background, held on its way out: no second worker and no second request until it ends; then the next job runs as the one in flight")
    func cancelledWorkerOnItsWayOut() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let (first, _, _) = try await fixture.filledCategory("First", mode: .manual)
        let (second, _, _) = try await fixture.filledCategory("Second", mode: .manual)
        let writer = fixture.writer
        // The first job, answered, held before its store.
        fixture.gate.hold(.store)
        let firstOutcome = Box<OverviewWriteOutcome>()
        Task { firstOutcome.set(await writer.write(category: first)) }
        await fixture.reach(.store)
        await fixture.enterBackground()
        fixture.front.set(isInFront: true)

        // The second job, asked for while the cancelled worker is held.
        fixture.service.hold(request: 2)
        let secondOutcome = Box<OverviewWriteOutcome>()
        Task { secondOutcome.set(await writer.write(category: second)) }
        await fixture.eventually { await writer.queuedManualJobs == 1 }
        #expect(await writer.workersAlive == 1, "no second worker while the cancelled one unwinds")
        #expect(fixture.service.requests.count == 1, "no second request while the first job is in flight")

        fixture.gate.release(.store)
        await fixture.eventually { firstOutcome.current != nil }
        #expect(firstOutcome.current == .cancelled)
        // The second job's request is in flight: it is the job in flight
        // and reported as working.
        await fixture.requested(2)
        #expect(await writer.inFlightCategory == second)
        #expect(await writer.workersAlive == 1)
        await fixture.eventually { fixture.lastWorking == [second] }

        fixture.service.release(request: 2)
        await fixture.eventually { secondOutcome.current != nil }
        #expect(secondOutcome.current == .stored)
        await writer.settled()
        #expect(fixture.lastWorking == [])
        #expect(try await fixture.rows(of: first).isEmpty)
        #expect(try await fixture.rows(of: second).map(\.state) == ["done"])
    }

    @Test("an automatic job cancelled by the background while it reads blocks nothing on its way out, and is due again")
    func cancelledJobBlocksNothing() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let (category, _, _) = try await fixture.filledCategory()
        // At the limit: a job that went on after its read would be blocked.
        try await fixture.library.setDailyAutomaticLimit(0)
        fixture.gate.hold(.jobRead)
        await fixture.writer.runDue()
        await fixture.reach(.jobRead)
        await fixture.enterBackground()
        fixture.gate.release(.jobRead)
        await fixture.writer.settled()
        #expect(fixture.blocked.isEmpty, "the cancelled job blocked nothing")
        #expect(fixture.service.requests.isEmpty)

        // In front again, it is due, and its own run meets the limit.
        fixture.front.set(isInFront: true)
        await fixture.runDue()
        #expect(fixture.blocked[category]?.reason == .dailyLimit)
        #expect(fixture.service.requests.isEmpty)
    }

    // MARK: - The reading language before the first request

    @Test("a change of the reading language while a job reads the slots drops the job: nothing sent or stored; the next run writes in the new language", arguments: [OverviewWriter.SuspensionPoint.slotRead, .limitRead])
    func languageChangeBeforeTheFirstRequest(at point: OverviewWriter.SuspensionPoint) async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let (category, _, _) = try await fixture.filledCategory()
        fixture.gate.hold(point)
        await fixture.writer.runDue()
        await fixture.reach(point)
        await fixture.writer.configure(locale: .english)
        fixture.gate.release(point)
        await fixture.writer.settled()
        #expect(fixture.service.requests.isEmpty, "nothing sent in the old language")
        #expect(try await fixture.rows().isEmpty)
        #expect(try await fixture.usage().isEmpty, "not counted as the day's automatic request")
        #expect(fixture.blocked.isEmpty)

        await fixture.runDue()
        #expect(try await fixture.rows(of: category).map(\.locale) == ["en"])
        #expect(fixture.overviewRequests.allSatisfy { $0.system.contains("English (en)") })
    }

    @Test("a manual job whose reading language changed before its first request answers cancelled and sends nothing")
    func manualLanguageChangeBeforeTheFirstRequest() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let (category, _, _) = try await fixture.filledCategory(mode: .manual)
        fixture.gate.hold(.slotRead)
        let outcome = Task { await fixture.writer.write(category: category) }
        await fixture.reach(.slotRead)
        await fixture.writer.configure(locale: .english)
        fixture.gate.release(.slotRead)
        #expect(await outcome.value == .cancelled)
        await fixture.writer.settled()
        #expect(fixture.service.requests.isEmpty)
        #expect(try await fixture.rows().isEmpty)
    }

    @Test("a change of the reading language after the first request was sent keeps its result under the job's language (decision 11 (d))")
    func languageChangeAfterTheFirstRequest() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let (category, _, _) = try await fixture.filledCategory()
        fixture.service.hold(request: 1)
        await fixture.writer.runDue()
        await fixture.requested(1)
        await fixture.writer.configure(locale: .english)
        fixture.service.release(request: 1)
        await fixture.writer.settled()
        #expect(try await fixture.rows(of: category).map(\.locale) == ["zh-Hans"])
    }
}
