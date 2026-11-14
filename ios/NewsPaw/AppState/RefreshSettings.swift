import Foundation
import NewsPawKit

/// The two refresh settings (spec section 4: global settings), one object
/// over the preferences store. Every workspace's refresh model reads them
/// here at each use, so a change made in one partition is the other's too
/// (RD18 decision 3). It holds nothing of a library's content.
@MainActor @Observable
final class RefreshSettings {
    var interval: RefreshInterval {
        didSet { preferences.refreshInterval = interval }
    }
    var retention: Retention {
        didSet { preferences.retention = retention }
    }

    @ObservationIgnored private let preferences: Preferences

    init(_ preferences: Preferences) {
        self.preferences = preferences
        interval = preferences.refreshInterval
        retention = preferences.retention
    }
}
