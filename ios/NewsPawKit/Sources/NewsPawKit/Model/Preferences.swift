import Foundation

/// How often the app refreshes the library when it is entered (spec N04).
/// The raw values are minutes as the configuration file writes them
/// (`refresh_minutes`, spec section 5); 0 means manual only.
public enum RefreshInterval: Int, Sendable, CaseIterable {
    case manualOnly = 0
    case fifteenMinutes = 15
    case thirtyMinutes = 30
    case sixtyMinutes = 60

    public static let standard = RefreshInterval.thirtyMinutes
}

/// How long articles are kept, counted from when each was first seen (spec
/// N04). The raw values are days as the configuration file writes them
/// (`retention_days`); 0 means forever.
public enum Retention: Int, Sendable, CaseIterable {
    case forever = 0
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90

    public static let standard = Retention.thirtyDays
}

/// The two refresh settings in the system preferences store (spec section
/// 4: global settings), under the names the configuration file uses. A
/// stored value outside its set reads as the default. Nothing about a
/// partition's content is kept here.
public struct Preferences {
    static let refreshIntervalKey = "refresh_minutes"
    static let retentionKey = "retention_days"

    private let defaults: UserDefaults

    /// - Parameter defaults: the store to use; the app passes the standard
    ///   one, or a suite of its own under the UI tests.
    public init(_ defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var refreshInterval: RefreshInterval {
        get {
            (defaults.object(forKey: Self.refreshIntervalKey) as? Int).flatMap(RefreshInterval.init(rawValue:)) ?? .standard
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Self.refreshIntervalKey)
        }
    }

    public var retention: Retention {
        get {
            (defaults.object(forKey: Self.retentionKey) as? Int).flatMap(Retention.init(rawValue:)) ?? .standard
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Self.retentionKey)
        }
    }
}
