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

/// The settings kept in the system preferences store (spec section 4): the
/// two refresh settings, background refresh (RD24) and the three
/// translation settings (RD14), under the names the configuration file
/// uses; the three reading settings (RD11), the two device settings of the
/// adult partition (RD18) and the record of background runs (RD24), which
/// the configuration file never carries. A stored value outside its set
/// reads as the default. Nothing about a partition's content is kept here.
///
/// Sendable by hand: its one stored property is a `UserDefaults`, which the
/// system documents as safe to use from any thread and does not mark so.
public struct Preferences: @unchecked Sendable {
    static let refreshIntervalKey = "refresh_minutes"
    static let retentionKey = "retention_days"
    static let readingTextSizeKey = "reading_text_size"
    static let readingLineSpacingKey = "reading_line_spacing"
    static let readingTypefaceKey = "reading_typeface"
    static let adultPartitionIsOnKey = "adult_partition_on"
    static let lockTimingKey = "adult_lock_timing"
    static let readingLocaleKey = "reading_locale"
    static let autoTranslateTitlesKey = "auto_translate_titles"
    static let showOriginalTitlesKey = "show_original_titles"
    static let backgroundRefreshKey = "background_refresh"
    static let backgroundRunsKey = "background_refresh_runs"

    /// How far back the record of background runs reaches (RD24).
    public static let backgroundRunWindow: TimeInterval = 7 * 24 * 60 * 60
    /// The most background runs the record keeps.
    public static let backgroundRunLimit = 100

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

    /// Whether the adult partition is turned on (spec N09): a device
    /// setting, off until the owner turns it on. Anything stored that is
    /// not a truth value reads as off.
    public var adultPartitionIsOn: Bool {
        get { truthValue(Self.adultPartitionIsOnKey) ?? false }
        nonmutating set {
            defaults.set(newValue, forKey: Self.adultPartitionIsOnKey)
        }
    }

    /// The reading language (spec N06; RD14 decision 1): Simplified
    /// Chinese until changed.
    public var readingLocale: ReadingLocale {
        get {
            (defaults.object(forKey: Self.readingLocaleKey) as? String).flatMap(ReadingLocale.init(rawValue:)) ?? .standard
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Self.readingLocaleKey)
        }
    }

    /// Whether titles and excerpts of sources that follow the global setting
    /// are translated without the owner asking: on until turned off.
    public var autoTranslateTitles: Bool {
        get { truthValue(Self.autoTranslateTitlesKey) ?? true }
        nonmutating set {
            defaults.set(newValue, forKey: Self.autoTranslateTitlesKey)
        }
    }

    /// Whether a list row shows the original title under its translation:
    /// off until turned on, as in the specification's sample.
    public var showOriginalTitles: Bool {
        get { truthValue(Self.showOriginalTitlesKey) ?? false }
        nonmutating set {
            defaults.set(newValue, forKey: Self.showOriginalTitlesKey)
        }
    }

    /// Whether the system may refresh the library in the background (spec
    /// N04, section 4; RD24 decision 5): a global setting, on until turned
    /// off. Anything stored that is not a truth value reads as on.
    public var backgroundRefresh: Bool {
        get { truthValue(Self.backgroundRefreshKey) ?? true }
        nonmutating set {
            defaults.set(newValue, forKey: Self.backgroundRefreshKey)
        }
    }

    /// When background runs started, oldest first (RD24 decision 6): device
    /// state, never exported. Anything stored that is not a list of dates
    /// reads as none; an entry that is not a date is skipped.
    public var backgroundRuns: [Date] {
        (defaults.array(forKey: Self.backgroundRunsKey) ?? []).compactMap { $0 as? Date }
    }

    /// The background runs of the seven days before `now`, oldest first.
    public func backgroundRuns(before now: Date) -> [Date] {
        backgroundRuns.filter { $0 > now.addingTimeInterval(-Self.backgroundRunWindow) }
    }

    /// Records that a background run started at `date`, and keeps only the
    /// runs of the seven days before it, at most `backgroundRunLimit`, the
    /// latest.
    public func recordBackgroundRun(at date: Date) {
        let kept = (backgroundRuns(before: date) + [date]).suffix(Self.backgroundRunLimit)
        defaults.set(Array(kept), forKey: Self.backgroundRunsKey)
    }

    /// A stored truth value, or `nil` for nothing or anything else.
    private func truthValue(_ key: String) -> Bool? {
        guard let number = defaults.object(forKey: key) as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// When the adult partition locks after the app is left: a device
    /// setting. Another stored value reads as "immediately".
    public var lockTiming: LockTiming {
        get {
            (defaults.object(forKey: Self.lockTimingKey) as? Int).flatMap(LockTiming.init(rawValue:)) ?? .immediately
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Self.lockTimingKey)
        }
    }
}
