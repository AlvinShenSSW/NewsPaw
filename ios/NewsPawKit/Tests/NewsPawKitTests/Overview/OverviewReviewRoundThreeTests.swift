import Foundation
@testable import NewsPawKit
import Testing

/// RD23 review round 3: an overview request is sent only while the app is
/// in front, read from `AppFront` where work starts and before every
/// request — not learnt from events, which can be late (behind a due check
/// held at its read) or sent before the writer existed.
@Suite("Overview review round 3")
struct OverviewReviewRoundThreeTests {
    typealias Fixture = OverviewFixture
    typealias Box = OverviewReviewRoundOneTests.Box

    @Test("a request in flight, a second due check held at its read, the app enters the background, a refusal arrives: no further request, nothing blocked, the category due again in front")
    func backgroundWhileADueCheckWaitsAtItsRead() async throws {
        let fixture = try await Fixture.make(service: TranslationService { _, _, _ in .refusal })
        defer { fixture.remove() }
        let (category, _, _) = try await fixture.filledCategory()
        let chain = OverviewChain(writer: fixture.writer)
        fixture.service.hold(request: 1)
        chain.send { await $0.runDue() }
        await fixture.requested(1)
        // Another run ends: its due check is held at its read.
        fixture.gate.hold(.dueRead)
        chain.send { await $0.runDue() }
        let gate = fixture.gate
        await fixture.eventually { gate.isHolding(.dueRead) }

        // The app enters the background as AppModel and OverviewModel make
        // it: the state first, then the cancellation outside the chain.
        fixture.front.set(isInFront: false)
        chain.enteredBackground()
        // The refusal arrives.
        fixture.service.release(request: 1)
        await fixture.writer.settled()
        #expect(fixture.service.requests.count == 1, "nothing sent after the app entered the background")
        #expect(fixture.blocked.isEmpty)
        #expect(try await fixture.rows().isEmpty)

        // The held due check, released in the background, starts nothing.
        fixture.gate.release(.dueRead)
        await chain.send { _ in }.value
        await fixture.writer.settled()
        #expect(fixture.service.requests.count == 1)
        #expect(await fixture.writer.queuedAutomaticJobs == 0)

        // In front again, the category is due and the next run writes it.
        fixture.front.set(isInFront: true)
        fixture.service.answer(with: OverviewFixture.goodRule)
        await fixture.runDue()
        #expect(try await fixture.rows(of: category).map(\.state) == ["done"])
    }

    @Test("a writer made while the app is in the background sends nothing at the first run's end or for a manual job; in front, the next run writes")
    func writerMadeInTheBackground() async throws {
        let fixture = try await Fixture.make(inFront: false)
        defer { fixture.remove() }
        let (category, _, _) = try await fixture.filledCategory()
        // No event reaches the writer: it reads the state.
        await fixture.runDue()
        #expect(fixture.service.requests.isEmpty)
        #expect(await fixture.writer.queuedAutomaticJobs == 0)
        #expect(await fixture.write(category) == .cancelled)
        #expect(fixture.service.requests.isEmpty)
        #expect(try await fixture.rows().isEmpty)

        fixture.front.set(isInFront: true)
        await fixture.runDue()
        #expect(try await fixture.rows(of: category).map(\.state) == ["done"])
    }

    /// Which request of a job the state is read before.
    enum Request: String, CaseIterable, Sendable {
        case first
        case retry
        case backup
    }

    @Test("the rule at the send site: with the app no longer in front and its cancellation not yet arrived, neither the first request, nor the retry, nor the backup request is sent", arguments: Request.allCases)
    func noRequestOutOfFront(_ request: Request) async throws {
        let service: TranslationService = switch request {
        case .first: TranslationService(OverviewFixture.goodRule)
        case .retry: TranslationService { _, _, _ in .refusal }
        case .backup: TranslationService { _, _, _ in .status(503) }
        }
        let fixture = try await Fixture.make(service: service, backup: request == .backup)
        defer { fixture.remove() }
        let (category, _, _) = try await fixture.filledCategory(mode: .manual)
        let writer = fixture.writer
        let outcome = Box<OverviewWriteOutcome>()
        if request == .first {
            fixture.gate.hold(.send(.primary))
            Task { outcome.set(await writer.write(category: category)) }
            await fixture.reach(.send(.primary))
            fixture.front.set(isInFront: false)
            fixture.gate.release(.send(.primary))
        } else {
            fixture.service.hold(request: 1)
            Task { outcome.set(await writer.write(category: category)) }
            await fixture.requested(1)
            fixture.front.set(isInFront: false)
            fixture.service.release(request: 1)
        }
        await fixture.eventually { outcome.current != nil }
        await writer.settled()
        #expect(outcome.current == .cancelled)
        #expect(fixture.service.requests.count == (request == .first ? 0 : 1), "no request out of front")
        #expect(fixture.blocked.isEmpty)
        #expect(try await fixture.rows().isEmpty)
    }
}
