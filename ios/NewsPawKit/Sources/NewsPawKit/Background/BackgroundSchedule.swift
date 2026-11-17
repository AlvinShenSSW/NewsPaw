import Foundation

/// What asks the system for background refresh (RD24 approach 3): one
/// app-refresh request at a time. The app implements it over the system's
/// task scheduler; tests and the UI tests' debug build record instead.
@MainActor
public protocol BackgroundScheduler: AnyObject {
    /// Asks for one run no earlier than `earliest`, in place of a request
    /// that is pending. Throws when the system refuses.
    func submit(earliest: Date) throws
    /// Withdraws the pending request, if there is one.
    func cancel()
}

/// The schedule's one rule (RD24 decisions 2 and 5; criterion 2): with
/// background refresh on and an interval of 15, 30 or 60 minutes, one
/// request whose earliest start is now plus the interval; with it off or
/// "Manual Only", none.
public enum BackgroundSchedule {
    public enum Action: Sendable, Equatable {
        case submit(earliest: Date)
        case cancel
    }

    public static func action(enabled: Bool, interval: RefreshInterval, now: Date) -> Action {
        guard enabled, interval != .manualOnly else { return .cancel }
        return .submit(earliest: now.addingTimeInterval(TimeInterval(interval.rawValue * 60)))
    }

    /// Applies the rule: called at the end of each preparation, when either
    /// setting changes, when the scene enters the background and when a run
    /// starts. A submission the system refuses is ignored and changes
    /// nothing else.
    @MainActor
    public static func reconcile(enabled: Bool, interval: RefreshInterval, now: Date, scheduler: any BackgroundScheduler) {
        switch action(enabled: enabled, interval: interval, now: now) {
        case .submit(let earliest):
            try? scheduler.submit(earliest: earliest)
        case .cancel:
            scheduler.cancel()
        }
    }
}
