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
}
