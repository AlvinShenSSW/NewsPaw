import Foundation
@testable import NewsPawKit
import Testing

/// RD24 approach 4 and criteria 6 and 7: how one background run ends.
@MainActor
@Suite("Background run", .timeLimit(.minutes(5)))
struct BackgroundRunTests {
    /// A library whose one source's collection is held in flight by a
    /// refresh of the refresher, and the work of a run that waits for the
    /// test.
    @MainActor
    private struct Setup {
        let fixture: PassFixture
        let control: BackgroundPassControl
        let workStarted = Signal()
        let workMayEnd = Signal()
        let workEnded = Flag()
        let source: UUID

        static func make() async throws -> Setup {
            let fixture = try await PassFixture.make()
            let source = try await fixture.source("Held")
            fixture.transport.hold(source.address)
            Task { @MainActor in try await fixture.refresher.refresh(.library) }
            await fixture.eventually { fixture.refresher.collecting == [source.id] }
            return Setup(fixture: fixture, control: BackgroundPassControl(refresher: fixture.refresher), source: source.id)
        }

        func run() -> BackgroundRun {
            BackgroundRun(control: control) { [workStarted, workMayEnd, workEnded] in
                workStarted.fire()
                await workMayEnd.wait()
                workEnded.set()
                return .collected
            }
        }
    }

    @Test("the work ends: the run returns its result and cancels nothing")
    func workEnds() async throws {
        let setup = try await Setup.make()
        defer { setup.fixture.remove() }
        let run = setup.run()
        setup.workMayEnd.fire()
        #expect(await run.run() == .ended(.collected))
        #expect(!setup.control.isCancelled)
        #expect(!setup.control.isReleased)
        #expect(setup.fixture.refresher.collecting == [setup.source])
        setup.fixture.transport.release(setup.fixture.transport.received[0])
    }

    @Test("its task is cancelled (the time ran out): control.cancel() is called, and the refresher cancelled, before it returns")
    func cancellationCancelsFirst() async throws {
        let setup = try await Setup.make()
        defer { setup.fixture.remove() }
        let run = setup.run()
        let control = setup.control
        let refresher = setup.fixture.refresher
        let task = Task { @MainActor () -> (BackgroundRun.Ending, Bool, Bool) in
            let ending = await run.run()
            // What held at the moment it returned.
            return (ending, control.isCancelled, refresher.collecting.isEmpty)
        }
        await setup.workStarted.wait()
        task.cancel()
        let (ending, cancelled, refresherCancelled) = await task.value
        #expect(ending == .expired)
        #expect(cancelled)
        #expect(refresherCancelled)
        #expect(!setup.workEnded.isSet)
        // The work ending afterwards changes nothing.
        setup.workMayEnd.fire()
        await setup.fixture.eventually { setup.workEnded.isSet }
        #expect(!control.isReleased)
    }

    @Test("cameToFront(): the run releases the control and returns at once; the work goes on; a later cancellation does nothing more")
    func cameToFrontReleases() async throws {
        let setup = try await Setup.make()
        defer { setup.fixture.remove() }
        let run = setup.run()
        let control = setup.control
        let task = Task { @MainActor in await run.run() }
        await setup.workStarted.wait()
        run.cameToFront()
        #expect(await task.value == .cameToFront)
        #expect(control.isReleased)
        #expect(!setup.workEnded.isSet, "the run waited for the work")

        // The time running out afterwards: nothing is cancelled.
        task.cancel()
        control.cancel()
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(!control.isCancelled)
        #expect(setup.fixture.refresher.collecting == [setup.source])
        setup.workMayEnd.fire()
        await setup.fixture.eventually { setup.workEnded.isSet }
        setup.fixture.transport.release(setup.fixture.transport.received[0])
    }

    @Test("a task cancelled before the run starts: the run expires at once")
    func cancelledBeforeStart() async throws {
        let setup = try await Setup.make()
        defer { setup.fixture.remove() }
        let run = setup.run()
        let control = setup.control
        let task = Task { @MainActor () -> BackgroundRun.Ending in
            withUnsafeCurrentTask { $0?.cancel() }
            return await run.run()
        }
        #expect(await task.value == .expired)
        #expect(control.isCancelled)
        setup.workMayEnd.fire()
    }

    @Test("the control: cancel() after release() and release() after cancel() do nothing; the collection wait returns at once when none runs")
    func controlFirstWins() async throws {
        let fixture = try await PassFixture.make()
        defer { fixture.remove() }
        let released = BackgroundPassControl(refresher: fixture.refresher)
        released.release()
        released.cancel()
        #expect(released.isReleased && !released.isCancelled)
        let cancelled = BackgroundPassControl(refresher: fixture.refresher)
        cancelled.cancel()
        cancelled.release()
        #expect(cancelled.isCancelled && !cancelled.isReleased)
        await cancelled.untilCollectionEnds()
        var ended = 0
        let control = BackgroundPassControl(refresher: fixture.refresher)
        control.setWaitEnder { ended += 1 }
        control.cancel()
        control.release()
        control.cancel()
        #expect(ended == 1)
        control.setWaitEnder { ended += 1 }
        #expect(ended == 2, "a wait set after the end ends at once")
    }
}
