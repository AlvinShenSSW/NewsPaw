import Foundation
@testable import NewsPawKit
import Testing

/// RD24 review round 1, G1 and G2: the background action stops waiting for
/// the shared preparation when its task is cancelled, without stopping the
/// preparation; and every delivery leaves the schedule reconciled from the
/// stored settings, whatever becomes of the preparation.
@MainActor
@Suite("Background action", .timeLimit(.minutes(5)))
struct BackgroundActionTests {
    private struct Failure: Error {}

    private func withSuite(_ body: (Preferences) async throws -> Void) async throws {
        let name = "NewsPawKitTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try await body(Preferences(defaults))
    }

    // MARK: - G1: the shared preparation

    @Test("G1: a held preparation; the action's task is cancelled; the action returns while it is still held; a later start gets the finished preparation without running it again")
    func cancelledWaitLeavesThePreparation() async throws {
        let preparation = SharedPreparation()
        let held = Signal()
        let started = Signal()
        let runs = CallCounter()
        let work: @MainActor () async -> (any Error)? = {
            _ = runs.next()
            started.fire()
            await held.wait()
            return nil
        }
        let action = Task { @MainActor in await preparation.wait(stopsOnCancellation: true, starting: work) }
        await started.wait()
        action.cancel()
        let outcome = await action.value
        guard case .abandoned = outcome else {
            Issue.record("the action waited for the preparation: \(outcome)")
            return
        }
        #expect(preparation.isRunning, "the preparation was stopped with the action")

        // The scene's start waits for the same preparation.
        let start = Task { @MainActor in await preparation.wait(stopsOnCancellation: false, starting: work) }
        held.fire()
        guard case .finished(nil) = await start.value else {
            Issue.record("the start did not get the finished preparation")
            return
        }
        guard case .finished(nil) = await preparation.wait(stopsOnCancellation: false, starting: work) else {
            Issue.record("a later wait did not get the finished preparation")
            return
        }
        #expect(runs.next() == 1, "the preparation ran more than once")
    }

    @Test("G1: a wait that does not stop on cancellation still gets the result; a failed preparation is forgotten and runs again")
    func failureIsForgotten() async throws {
        let preparation = SharedPreparation()
        let runs = CallCounter()
        let failing: @MainActor () async -> (any Error)? = {
            _ = runs.next()
            return Failure()
        }
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await preparation.wait(stopsOnCancellation: false, starting: failing)
        }
        guard case .finished(let error?) = await task.value, error is Failure else {
            Issue.record("the start did not get the failure")
            return
        }
        #expect(!preparation.isRunning)
        guard case .finished(.some) = await preparation.wait(stopsOnCancellation: false, starting: failing) else {
            Issue.record("the second wait did not run the preparation again")
            return
        }
        #expect(runs.next() == 2)
    }

    @Test("G1: a task already cancelled starts no preparation")
    func alreadyCancelled() async throws {
        let preparation = SharedPreparation()
        let runs = CallCounter()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await preparation.wait(stopsOnCancellation: true) {
                _ = runs.next()
                return nil
            }
        }
        guard case .abandoned = await task.value else {
            Issue.record("expected abandoned")
            return
        }
        #expect(!preparation.isRunning)
        #expect(runs.next() == 0)
    }

    // MARK: - G2: the schedule on every delivery

    @Test("G2: a preparation that fails still leaves the next request, from the stored settings; nothing runs")
    func failedPreparationReschedules() async throws {
        try await withSuite { preferences in
            let scheduler = RecordingScheduler()
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            preferences.refreshInterval = .fifteenMinutes
            var ran = false
            await BackgroundAction.perform(
                settings: preferences, now: now, scheduler: scheduler,
                prepare: { false }, isInFront: { false }, run: { ran = true }
            )
            #expect(scheduler.pending == now.addingTimeInterval(900))
            #expect(!ran)

            // Stored off, or Manual Only: none.
            preferences.backgroundRefresh = false
            await BackgroundAction.perform(settings: preferences, now: now, scheduler: scheduler, prepare: { false }, isInFront: { false }, run: {})
            #expect(scheduler.pending == nil)
            preferences.backgroundRefresh = true
            preferences.refreshInterval = .manualOnly
            await BackgroundAction.perform(settings: preferences, now: now, scheduler: scheduler, prepare: { false }, isInFront: { false }, run: {})
            #expect(scheduler.pending == nil)
        }
    }

    @Test("the run runs only after a successful preparation, not cancelled and not in front")
    func runConditions() async throws {
        try await withSuite { preferences in
            let scheduler = RecordingScheduler()
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            var runs = 0
            await BackgroundAction.perform(settings: preferences, now: now, scheduler: scheduler, prepare: { true }, isInFront: { false }, run: { runs += 1 })
            #expect(runs == 1)
            await BackgroundAction.perform(settings: preferences, now: now, scheduler: scheduler, prepare: { true }, isInFront: { true }, run: { runs += 1 })
            #expect(runs == 1)
            let cancelled = Task { @MainActor in
                await BackgroundAction.perform(settings: preferences, now: now, scheduler: scheduler, prepare: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return true
                }, isInFront: { false }, run: { runs += 1 })
            }
            await cancelled.value
            #expect(runs == 1)
            #expect(scheduler.pending == now.addingTimeInterval(1800))
        }
    }
}
