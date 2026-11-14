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

/// The reading screen's text size, on top of the system's text size (spec
/// N05; RD11 decision 10). The raw values are what is stored.
public enum ReadingTextSize: Int, Sendable, CaseIterable {
    case smallest = 1
    case smaller = 2
    case standard = 3
    case larger = 4
    case largest = 5

    /// What the body's type size is multiplied by.
    public var factor: Double {
        switch self {
        case .smallest: 0.85
        case .smaller: 0.92
        case .standard: 1.0
        case .larger: 1.15
        case .largest: 1.3
        }
    }
}

/// The reading screen's line spacing. The raw values are what is stored.
public enum ReadingLineSpacing: Int, Sendable, CaseIterable {
    case compact = 1
    case standard = 2
    case relaxed = 3

    /// What a block's line height is multiplied by.
    public var factor: Double {
        switch self {
        case .compact: 0.9
        case .standard: 1.0
        case .relaxed: 1.15
        }
    }
}

/// The reading screen's typeface. The raw values are what is stored.
public enum ReadingTypeface: String, Sendable, CaseIterable {
    case sansSerif = "sans"
    case serif
}

/// The refresh settings and the reading settings in the system preferences
/// store (spec section 4: global settings). The refresh settings are under
/// the names the configuration file uses; the reading settings are device
/// settings and are not exported. A stored value outside its set reads as
/// the default. Nothing about a partition's content is kept here.
public struct Preferences {
    static let refreshIntervalKey = "refresh_minutes"
    static let retentionKey = "retention_days"
    static let readingTextSizeKey = "reading_text_size"
    static let readingLineSpacingKey = "reading_line_spacing"
    static let readingTypefaceKey = "reading_typeface"

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

    public var readingTextSize: ReadingTextSize {
        get {
            (defaults.object(forKey: Self.readingTextSizeKey) as? Int).flatMap(ReadingTextSize.init(rawValue:)) ?? .standard
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Self.readingTextSizeKey)
        }
    }

    public var readingLineSpacing: ReadingLineSpacing {
        get {
            (defaults.object(forKey: Self.readingLineSpacingKey) as? Int).flatMap(ReadingLineSpacing.init(rawValue:)) ?? .standard
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Self.readingLineSpacingKey)
        }
    }

    public var readingTypeface: ReadingTypeface {
        get {
            (defaults.object(forKey: Self.readingTypefaceKey) as? String).flatMap(ReadingTypeface.init(rawValue:)) ?? .sansSerif
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Self.readingTypefaceKey)
        }
    }
}
