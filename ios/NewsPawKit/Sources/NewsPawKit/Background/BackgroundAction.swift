import Foundation

/// The order of a delivered background task (RD24 approach 7; review G2).
@MainActor
public enum BackgroundAction {
    /// First the schedule is reconciled from the stored settings, which
    /// need no library, so that every delivery leaves the next request
    /// pending (or none while off), whatever becomes of the run; then the
    /// preparation is awaited; then, unless it failed, the task was
    /// cancelled meanwhile or the app came to the front, the run.
    ///
    /// - Parameters:
    ///   - settings: the stored settings.
    ///   - now: the clock.
    ///   - prepare: the shared preparation; whether the library is open.
    ///   - isInFront: whether the app is in front now.
    ///   - run: the run itself.
    public static func perform(
        settings: Preferences, now: Date, scheduler: any BackgroundScheduler,
        prepare: @MainActor () async -> Bool, isInFront: @MainActor () -> Bool, run: @MainActor () async -> Void
    ) async {
        BackgroundSchedule.reconcile(enabled: settings.backgroundRefresh, interval: settings.refreshInterval, now: now, scheduler: scheduler)
        guard await prepare() else { return }
        // Rechecked after the wait: the time ran out, or the app came to
        // the front (its entry refreshes), meanwhile.
        guard !Task.isCancelled, !isInFront() else { return }
        await run()
    }
}
