import Foundation
@testable import NewsPawKit
import Testing

/// RD06 criterion 8 and RD11 decision 10: the settings in a throwaway
/// preferences suite.
@Suite("Preferences")
struct PreferencesTests {
    private func withSuite(_ body: (UserDefaults) throws -> Void) throws {
        let name = "NewsPawKitTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test("defaults are 30 minutes and 30 days")
    func defaults() throws {
        try withSuite { defaults in
            let preferences = Preferences(defaults)
            #expect(preferences.refreshInterval == .thirtyMinutes)
            #expect(preferences.retention == .thirtyDays)
        }
    }

    @Test("every value of both sets round-trips under the configuration file's names")
    func roundTrip() throws {
        try withSuite { defaults in
            let preferences = Preferences(defaults)
            for interval in RefreshInterval.allCases {
                preferences.refreshInterval = interval
                #expect(Preferences(defaults).refreshInterval == interval)
                #expect(defaults.integer(forKey: "refresh_minutes") == interval.rawValue)
            }
            for retention in Retention.allCases {
                preferences.retention = retention
                #expect(Preferences(defaults).retention == retention)
                #expect(defaults.integer(forKey: "retention_days") == retention.rawValue)
            }
            #expect(RefreshInterval.allCases.map(\.rawValue) == [0, 15, 30, 60])
            #expect(Retention.allCases.map(\.rawValue) == [0, 7, 30, 90])
        }
    }

    @Test("the reading settings default to the standard size and spacing and the system face")
    func readingDefaults() throws {
        try withSuite { defaults in
            let preferences = Preferences(defaults)
            #expect(preferences.readingTextSize == .standard)
            #expect(preferences.readingLineSpacing == .standard)
            #expect(preferences.readingTypeface == .sansSerif)
            #expect(ReadingTextSize.standard.factor == 1.0)
            #expect(ReadingLineSpacing.standard.factor == 1.0)
        }
    }

    @Test("every reading setting round-trips under its key; five sizes, three spacings, two faces")
    func readingRoundTrip() throws {
        try withSuite { defaults in
            let preferences = Preferences(defaults)
            for size in ReadingTextSize.allCases {
                preferences.readingTextSize = size
                #expect(Preferences(defaults).readingTextSize == size)
                #expect(defaults.integer(forKey: "reading_text_size") == size.rawValue)
            }
            for spacing in ReadingLineSpacing.allCases {
                preferences.readingLineSpacing = spacing
                #expect(Preferences(defaults).readingLineSpacing == spacing)
                #expect(defaults.integer(forKey: "reading_line_spacing") == spacing.rawValue)
            }
            for typeface in ReadingTypeface.allCases {
                preferences.readingTypeface = typeface
                #expect(Preferences(defaults).readingTypeface == typeface)
                #expect(defaults.string(forKey: "reading_typeface") == typeface.rawValue)
            }
            #expect(ReadingTextSize.allCases.map(\.factor) == [0.85, 0.92, 1.0, 1.15, 1.3])
            #expect(ReadingLineSpacing.allCases.map(\.factor) == [0.9, 1.0, 1.15])
            #expect(ReadingTypeface.allCases.map(\.rawValue) == ["sans", "serif"])
            // The refresh settings are untouched by them.
            #expect(preferences.refreshInterval == .thirtyMinutes)
            #expect(preferences.retention == .thirtyDays)
        }
    }

    @Test("a stored reading value outside its set reads as the default")
    func readingOutsideTheSet() throws {
        try withSuite { defaults in
            for value: Any in [0, 6, -1, 1_000, "3", 2.5, "serif "] {
                defaults.set(value, forKey: "reading_text_size")
                defaults.set(value, forKey: "reading_line_spacing")
                defaults.set(value, forKey: "reading_typeface")
                let preferences = Preferences(defaults)
                #expect(preferences.readingTextSize == .standard, "\(value)")
                #expect(preferences.readingLineSpacing == .standard, "\(value)")
                #expect(preferences.readingTypeface == .sansSerif, "\(value)")
            }
        }
    }

    @Test("a stored value outside the set reads as the default")
    func outsideTheSet() throws {
        try withSuite { defaults in
            for value: Any in [45, -1, 1_000, "30", 30.5, true] {
                defaults.set(value, forKey: "refresh_minutes")
                defaults.set(value, forKey: "retention_days")
                let preferences = Preferences(defaults)
                #expect(preferences.refreshInterval == .thirtyMinutes, "\(value)")
                #expect(preferences.retention == .thirtyDays, "\(value)")
            }
        }
    }

    // MARK: - RD18 criterion 8: the adult partition's two device settings

    @Test("the adult partition is off and locks immediately by default")
    func adultDefaults() throws {
        try withSuite { defaults in
            let preferences = Preferences(defaults)
            #expect(!preferences.adultPartitionIsOn)
            #expect(preferences.lockTiming == .immediately)
        }
    }

    @Test("the adult partition's settings round-trip under their own names")
    func adultRoundTrip() throws {
        try withSuite { defaults in
            let preferences = Preferences(defaults)
            preferences.adultPartitionIsOn = true
            #expect(Preferences(defaults).adultPartitionIsOn)
            #expect(defaults.bool(forKey: "adult_partition_on"))
            preferences.adultPartitionIsOn = false
            #expect(!Preferences(defaults).adultPartitionIsOn)
            for timing in LockTiming.allCases {
                preferences.lockTiming = timing
                #expect(Preferences(defaults).lockTiming == timing)
                #expect(defaults.integer(forKey: "adult_lock_timing") == timing.rawValue)
            }
            // They are not the refresh settings.
            #expect(preferences.refreshInterval == .thirtyMinutes)
            #expect(preferences.retention == .thirtyDays)
        }
    }

    @Test("a stored lock timing outside the set reads as immediately, and a stored value that is no truth value as off")
    func adultOutsideTheSet() throws {
        try withSuite { defaults in
            for value: Any in [45, -1, 61, 3_600, "60", 60.5, true] {
                defaults.set(value, forKey: "adult_lock_timing")
                #expect(Preferences(defaults).lockTiming == .immediately, "\(value)")
            }
            for value: Any in [1, "1", "true", 2.0, Date()] {
                defaults.set(value, forKey: "adult_partition_on")
                #expect(!Preferences(defaults).adultPartitionIsOn, "\(value)")
            }
        }
    }

    // MARK: - RD14 decision 1

    @Test("the translation settings: Simplified Chinese, automatic on, originals off; they round-trip under the file's names")
    func translationSettings() throws {
        try withSuite { defaults in
            let preferences = Preferences(defaults)
            #expect(preferences.readingLocale == .simplifiedChinese)
            #expect(preferences.autoTranslateTitles)
            #expect(!preferences.showOriginalTitles)
            for locale in ReadingLocale.allCases {
                preferences.readingLocale = locale
                #expect(Preferences(defaults).readingLocale == locale)
                #expect(defaults.string(forKey: "reading_locale") == locale.rawValue)
            }
            #expect(ReadingLocale.allCases.map(\.rawValue) == ["zh-Hans", "en", "ja"])
            preferences.autoTranslateTitles = false
            preferences.showOriginalTitles = true
            #expect(!Preferences(defaults).autoTranslateTitles)
            #expect(Preferences(defaults).showOriginalTitles)
            #expect(defaults.object(forKey: "auto_translate_titles") as? Bool == false)
            #expect(defaults.object(forKey: "show_original_titles") as? Bool == true)
        }
    }

    @Test("a stored translation value outside its set reads as the default")
    func translationSettingsOutsideTheirSets() throws {
        try withSuite { defaults in
            defaults.set("fr", forKey: "reading_locale")
            defaults.set("yes", forKey: "auto_translate_titles")
            defaults.set(1, forKey: "show_original_titles")
            let preferences = Preferences(defaults)
            #expect(preferences.readingLocale == .simplifiedChinese)
            #expect(preferences.autoTranslateTitles)
            #expect(!preferences.showOriginalTitles)
        }
    }
}
