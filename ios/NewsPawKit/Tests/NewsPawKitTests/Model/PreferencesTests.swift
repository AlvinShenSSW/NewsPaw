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
}
