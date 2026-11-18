import Foundation
import GRDB

/// A setting the configuration file carries (spec section 4; RD20 decision
/// 2), as the preview names it.
public enum ConfigurationSettingName: String, Sendable, Hashable, CaseIterable {
    case refreshMinutes = "refresh_minutes"
    case retentionDays = "retention_days"
    case readingLocale = "reading_locale"
    case autoTranslateTitles = "auto_translate_titles"
    case showOriginalTitles = "show_original_titles"
    case backgroundRefresh = "background_refresh"
    case dailyAutoLimit = "daily_auto_limit"
    case listThumbnails = "list_thumbnails"
}

/// A setting's value, typed, as the preview shows it.
public enum ConfigurationSettingValue: Sendable, Hashable {
    case refreshInterval(RefreshInterval)
    case retention(Retention)
    case readingLocale(ReadingLocale)
    case flag(Bool)
    case number(Int)
}

/// A setting whose value in the file differs from the value in effect here:
/// a conflict under Merge, which leaves it; replaced by Replace.
public struct ConfigurationSettingDifference: Sendable, Hashable {
    public let setting: ConfigurationSettingName
    public let here: ConfigurationSettingValue
    public let file: ConfigurationSettingValue
}

/// The global settings of the configuration file (`settings`; spec section
/// 4; RD20 decision 2): one optional member per global setting, under the
/// file's names. A member that is absent leaves this device's value as it
/// is; a member this version does not know is ignored by the decoder.
///
/// How a setting added later joins: one optional member here (or in
/// `ConfigurationPartitionSettings`), one line in `inEffect`, one in
/// `apply`, one in `differences` and one in `storedKeys` — or one entry on
/// `ConfigurationSettings.notExported`. Nothing else changes, and
/// `ConfigurationFile.version` stays (its comment says when it does not).
public struct ConfigurationSettings: Codable, Sendable, Hashable {
    public var refreshMinutes: Int?
    public var retentionDays: Int?
    public var readingLocale: String?
    public var autoTranslateTitles: Bool?
    public var showOriginalTitles: Bool?
    /// RD24's switch (spec section 4).
    public var backgroundRefresh: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case refreshMinutes = "refresh_minutes"
        case retentionDays = "retention_days"
        case readingLocale = "reading_locale"
        case autoTranslateTitles = "auto_translate_titles"
        case showOriginalTitles = "show_original_titles"
        case backgroundRefresh = "background_refresh"
    }

    public init(
        refreshMinutes: Int? = nil, retentionDays: Int? = nil, readingLocale: String? = nil, autoTranslateTitles: Bool? = nil,
        showOriginalTitles: Bool? = nil, backgroundRefresh: Bool? = nil
    ) {
        self.refreshMinutes = refreshMinutes
        self.retentionDays = retentionDays
        self.readingLocale = readingLocale
        self.autoTranslateTitles = autoTranslateTitles
        self.showOriginalTitles = showOriginalTitles
        self.backgroundRefresh = backgroundRefresh
    }

    /// The stored key each member is written under, in `Preferences`.
    static let storedKeys: [CodingKeys: String] = [
        .refreshMinutes: Preferences.refreshIntervalKey,
        .retentionDays: Preferences.retentionKey,
        .readingLocale: Preferences.readingLocaleKey,
        .autoTranslateTitles: Preferences.autoTranslateTitlesKey,
        .showOriginalTitles: Preferences.showOriginalTitlesKey,
        .backgroundRefresh: Preferences.backgroundRefreshKey,
    ]

    /// The stored keys that are never exported (spec section 4, N10): the
    /// device settings in `Preferences` and the `setting` state keys. Every
    /// `static let …Key = "…"` of the package is a member's stored key or
    /// on this list, exactly once (a test scans for it).
    static let notExported: Set<String> = [
        Preferences.readingTextSizeKey,
        Preferences.readingLineSpacingKey,
        Preferences.readingTypefaceKey,
        Preferences.adultPartitionIsOnKey,
        Preferences.lockTimingKey,
        Preferences.firstRunDoneKey,
        Preferences.backgroundRunsKey,
        Library.lastRefreshKey,
    ]

    /// The values in effect on this device, through the typed accessors.
    static func inEffect(_ preferences: Preferences) -> ConfigurationSettings {
        ConfigurationSettings(
            refreshMinutes: preferences.refreshInterval.rawValue,
            retentionDays: preferences.retention.rawValue,
            readingLocale: preferences.readingLocale.rawValue,
            autoTranslateTitles: preferences.autoTranslateTitles,
            showOriginalTitles: preferences.showOriginalTitles,
            backgroundRefresh: preferences.backgroundRefresh
        )
    }

    /// The first member whose value is outside its set, if any.
    var invalidMember: CodingKeys? {
        if let refreshMinutes, RefreshInterval(rawValue: refreshMinutes) == nil {
            return .refreshMinutes
        }
        if let retentionDays, Retention(rawValue: retentionDays) == nil {
            return .retentionDays
        }
        if let readingLocale, ReadingLocale(rawValue: readingLocale) == nil {
            return .readingLocale
        }
        return nil
    }

    /// Writes every member the file has through the typed setters (Replace).
    /// The values were validated by the reader.
    func apply(to preferences: Preferences) {
        if let value = refreshMinutes.flatMap(RefreshInterval.init(rawValue:)) {
            preferences.refreshInterval = value
        }
        if let value = retentionDays.flatMap(Retention.init(rawValue:)) {
            preferences.retention = value
        }
        if let value = readingLocale.flatMap(ReadingLocale.init(rawValue:)) {
            preferences.readingLocale = value
        }
        if let autoTranslateTitles {
            preferences.autoTranslateTitles = autoTranslateTitles
        }
        if let showOriginalTitles {
            preferences.showOriginalTitles = showOriginalTitles
        }
        if let backgroundRefresh {
            preferences.backgroundRefresh = backgroundRefresh
        }
    }

    /// The members present in the file whose value differs from `here`'s.
    func differences(from here: ConfigurationSettings) -> [ConfigurationSettingDifference] {
        var result: [ConfigurationSettingDifference] = []
        func compare<T: Equatable>(_ name: ConfigurationSettingName, _ file: T?, _ here: T?, _ value: (T) -> ConfigurationSettingValue?) {
            guard let file, let here, file != here, let fileValue = value(file), let hereValue = value(here) else { return }
            result.append(ConfigurationSettingDifference(setting: name, here: hereValue, file: fileValue))
        }
        compare(.refreshMinutes, refreshMinutes, here.refreshMinutes) { RefreshInterval(rawValue: $0).map { .refreshInterval($0) } }
        compare(.retentionDays, retentionDays, here.retentionDays) { Retention(rawValue: $0).map { .retention($0) } }
        compare(.readingLocale, readingLocale, here.readingLocale) { ReadingLocale(rawValue: $0).map { .readingLocale($0) } }
        compare(.autoTranslateTitles, autoTranslateTitles, here.autoTranslateTitles) { .flag($0) }
        compare(.showOriginalTitles, showOriginalTitles, here.showOriginalTitles) { .flag($0) }
        compare(.backgroundRefresh, backgroundRefresh, here.backgroundRefresh) { .flag($0) }
        return result
    }
}

/// One partition's settings in the configuration file (`partition_settings`;
/// spec section 4): the partition, and one optional member per partition
/// setting, stored in that library's `setting` table.
public struct ConfigurationPartitionSettings: Codable, Sendable, Hashable {
    /// The raw partition name; validated by the reader.
    var partition: String?
    /// Spec section 5's name; stored under RD14's `daily_automatic_limit`
    /// (decision 8).
    public var dailyAutoLimit: Int?
    public var listThumbnails: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case partition
        case dailyAutoLimit = "daily_auto_limit"
        case listThumbnails = "list_thumbnails"
    }

    /// The largest daily automatic limit a file may carry.
    static let maximumDailyAutoLimit = 100_000

    init(partition: String?, dailyAutoLimit: Int? = nil, listThumbnails: Bool? = nil) {
        self.partition = partition
        self.dailyAutoLimit = dailyAutoLimit
        self.listThumbnails = listThumbnails
    }

    /// The stored key each setting member is written under, in the
    /// library's `setting` table.
    static let storedKeys: [CodingKeys: String] = [
        .dailyAutoLimit: Library.dailyAutomaticLimitKey,
        .listThumbnails: Library.listThumbnailsKey,
    ]

    /// The values in effect in one library, read in `db` through the
    /// accessors' own rules.
    static func inEffect(_ partition: Partition, in db: Database) throws -> ConfigurationPartitionSettings {
        ConfigurationPartitionSettings(
            partition: partition.rawValue,
            dailyAutoLimit: try Library.dailyAutomaticLimit(in: db),
            listThumbnails: try Library.listThumbnails(in: db)
        )
    }

    /// The first setting member whose value is outside its set, if any.
    var invalidMember: CodingKeys? {
        if let dailyAutoLimit, !(0...Self.maximumDailyAutoLimit).contains(dailyAutoLimit) {
            return .dailyAutoLimit
        }
        return nil
    }

    /// Writes every member the file has, inside the partition's import
    /// transaction (Replace), through the setters' own statements.
    func apply(in db: Database) throws {
        if let dailyAutoLimit {
            try Library.writeDailyAutomaticLimit(dailyAutoLimit, in: db)
        }
        if let listThumbnails {
            try Library.writeListThumbnails(listThumbnails, in: db)
        }
    }

    /// The members present in the file whose value differs from `here`'s.
    func differences(from here: ConfigurationPartitionSettings) -> [ConfigurationSettingDifference] {
        var result: [ConfigurationSettingDifference] = []
        if let file = dailyAutoLimit, let value = here.dailyAutoLimit, file != value {
            result.append(ConfigurationSettingDifference(setting: .dailyAutoLimit, here: .number(value), file: .number(file)))
        }
        if let file = listThumbnails, let value = here.listThumbnails, file != value {
            result.append(ConfigurationSettingDifference(setting: .listThumbnails, here: .flag(value), file: .flag(file)))
        }
        return result
    }

    /// Whether the file has no setting member.
    var isEmpty: Bool {
        dailyAutoLimit == nil && listThumbnails == nil
    }
}
