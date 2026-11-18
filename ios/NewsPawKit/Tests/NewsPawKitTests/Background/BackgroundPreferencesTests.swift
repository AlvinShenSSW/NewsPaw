import Foundation
@testable import NewsPawKit
import Testing

/// RD24 approach 1: the setting `background_refresh` and the record of
/// runs `background_refresh_runs`, in a throwaway preferences suite.
@Suite("Background refresh preferences")
struct BackgroundPreferencesTests {
    private func withSuite(_ body: (UserDefaults) throws -> Void) throws {
        let name = "NewsPawKitTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test("on by default; it round-trips under background_refresh; a stored value that is no truth value reads as on")
    func setting() throws {
        try withSuite { defaults in
            let preferences = Preferences(defaults)
            #expect(preferences.backgroundRefresh)
            preferences.backgroundRefresh = false
            #expect(!Preferences(defaults).backgroundRefresh)
            #expect(defaults.object(forKey: "background_refresh") as? Bool == false)
            preferences.backgroundRefresh = true
            #expect(Preferences(defaults).backgroundRefresh)
            for value: Any in [0, 1, "false", "no", 2.5, Data(), [false]] {
                defaults.set(value, forKey: "background_refresh")
                #expect(Preferences(defaults).backgroundRefresh, "\(value)")
            }
        }
    }

    @Test("the record keeps the runs of the last 7 days, at most 100, the latest; it is stored as dates")
    func record() throws {
        try withSuite { defaults in
            let preferences = Preferences(defaults)
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            #expect(preferences.backgroundRuns.isEmpty)
            preferences.recordBackgroundRun(at: start)
            #expect(Preferences(defaults).backgroundRuns == [start])
            #expect((defaults.array(forKey: "background_refresh_runs") as? [Date]) == [start])

            // Eight days later the first run is dropped when the next is recorded.
            let later = start.addingTimeInterval(8 * 86_400)
            #expect(preferences.backgroundRuns(before: later).isEmpty)
            preferences.recordBackgroundRun(at: later)
            #expect(preferences.backgroundRuns == [later])

            // At most 100, the latest.
            for minute in 1...150 {
                preferences.recordBackgroundRun(at: later.addingTimeInterval(TimeInterval(minute * 60)))
            }
            let runs = preferences.backgroundRuns
            #expect(runs.count == Preferences.backgroundRunLimit)
            #expect(runs.first == later.addingTimeInterval(51 * 60))
            #expect(runs.last == later.addingTimeInterval(150 * 60))
            // A run just inside the window counts; one just outside does not.
            let end = later.addingTimeInterval(150 * 60)
            #expect(preferences.backgroundRuns(before: end.addingTimeInterval(7 * 86_400 - 1)) == [end])
            #expect(preferences.backgroundRuns(before: end.addingTimeInterval(7 * 86_400)).isEmpty)
        }
    }

    @Test("a record that is not a list of dates reads as none; an entry that is not a date is skipped")
    func damagedRecord() throws {
        try withSuite { defaults in
            let date = Date(timeIntervalSince1970: 1_800_000_000)
            defaults.set("yesterday", forKey: "background_refresh_runs")
            #expect(Preferences(defaults).backgroundRuns.isEmpty)
            defaults.set([date, "x", 3] as [Any], forKey: "background_refresh_runs")
            #expect(Preferences(defaults).backgroundRuns == [date])
        }
    }
}
