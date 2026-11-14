import Foundation
@testable import NewsPawKit
import Testing

/// RD06 criterion 8: the two settings in a throwaway preferences suite.
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
}
