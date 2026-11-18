import Foundation
import NewsPawKit

/// The refresh settings (spec section 4: global settings), one object over
/// the preferences store: the interval, how long articles are kept, and
/// background refresh (RD24). Every workspace's refresh model reads them
/// here at each use, so a change made in one partition is the other's too
/// (RD18 decision 3). It holds nothing of a library's content.
@MainActor @Observable
final class RefreshSettings {
    var interval: RefreshInterval {
        didSet {
            preferences.refreshInterval = interval
            onScheduleChanged?()
        }
    }
    var retention: Retention {
        didSet { preferences.retention = retention }
    }
    /// Whether the system may refresh the library in the background (RD24
    /// decision 5).
    var backgroundRefresh: Bool {
        didSet {
            preferences.backgroundRefresh = backgroundRefresh
            onScheduleChanged?()
        }
    }

    /// Called after the interval or background refresh changed: the app
    /// reconciles the background schedule (RD24 approach 1).
    @ObservationIgnored var onScheduleChanged: (@MainActor () -> Void)?

    @ObservationIgnored private let preferences: Preferences

    init(_ preferences: Preferences) {
        self.preferences = preferences
        interval = preferences.refreshInterval
        retention = preferences.retention
        backgroundRefresh = preferences.backgroundRefresh
    }

    /// The background runs of the seven days before `now`, oldest first.
    func backgroundRuns(before now: Date) -> [Date] {
        preferences.backgroundRuns(before: now)
    }

    /// Reads the preferences again after a configuration import wrote
    /// them (RD20 decision 7): a changed value acts as a change made here,
    /// so a changed interval or background refresh reconciles the
    /// background schedule (RD24).
    func reload() {
        let interval = preferences.refreshInterval
        let retention = preferences.retention
        let backgroundRefresh = preferences.backgroundRefresh
        if interval != self.interval {
            self.interval = interval
        }
        if retention != self.retention {
            self.retention = retention
        }
        if backgroundRefresh != self.backgroundRefresh {
            self.backgroundRefresh = backgroundRefresh
        }
    }
}
