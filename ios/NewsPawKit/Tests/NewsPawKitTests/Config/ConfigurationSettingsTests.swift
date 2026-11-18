import Foundation
import GRDB
@testable import NewsPawKit
import Testing

/// RD20 decision 2 and criterion 2: the settings members go through the
/// typed accessors, and every stored key of the package is either exported
/// as a member or listed as not exported.
@Suite("Configuration settings")
struct ConfigurationSettingsTests {
    /// The package's sources, found from this file.
    static var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/NewsPawKit", directoryHint: .isDirectory)
    }

    /// Every `static let …Key = "…"` of the package's sources: the
    /// constant's name and its value.
    static func storedKeyConstants() throws -> [(name: String, value: String, file: String)] {
        let pattern = try Regex(#"static let ([A-Za-z0-9_]+Key) = "([^"]*)""#)
        var found: [(String, String, String)] = []
        let enumerator = FileManager.default.enumerator(at: sourcesDirectory, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for match in text.matches(of: pattern) {
                let name = String(match.output[1].substring ?? "")
                let value = String(match.output[2].substring ?? "")
                found.append((name, value, url.lastPathComponent))
            }
        }
        return found
    }

    @Test("criterion 2: every stored key of the package is exported as a settings member or listed as not exported, exactly once")
    func storedKeysAreClassified() throws {
        let constants = try Self.storedKeyConstants()
        // The scan sees the keys this issue was written against.
        #expect(constants.count >= 13)
        let exported = Array(ConfigurationSettings.storedKeys.values) + Array(ConfigurationPartitionSettings.storedKeys.values)
        let notExported = ConfigurationSettings.notExported
        for constant in constants {
            let classifications = exported.filter { $0 == constant.value }.count + (notExported.contains(constant.value) ? 1 : 0)
            #expect(
                classifications == 1,
                "a stored key named …Key must be exported (a member of the configuration's settings) or listed as not exported: \(constant.name) = \"\(constant.value)\" in \(constant.file) is classified \(classifications) times"
            )
        }
        let values = constants.map(\.value)
        #expect(Set(values).count == values.count, "two constants store under one key: \(values)")
    }

    @Test("every settings member names its stored key, and the file's names are the members' coding keys")
    func membersHaveStoredKeys() {
        #expect(Set(ConfigurationSettings.storedKeys.keys) == Set(ConfigurationSettings.CodingKeys.allCases))
        #expect(Set(ConfigurationPartitionSettings.storedKeys.keys) == Set(ConfigurationPartitionSettings.CodingKeys.allCases.filter { $0 != .partition }))
        // The global members are stored under their own names.
        for (member, key) in ConfigurationSettings.storedKeys {
            #expect(member.rawValue == key)
        }
        // Decision 8: the file's name for the daily limit, RD14's key.
        #expect(ConfigurationPartitionSettings.storedKeys[.dailyAutoLimit] == "daily_automatic_limit")
        #expect(Set(ConfigurationSettingName.allCases.map(\.rawValue))
            == Set(ConfigurationSettings.CodingKeys.allCases.map(\.rawValue) + ["daily_auto_limit", "list_thumbnails"]))
    }

    @Test("the not-exported list holds the device settings and the refresh state")
    func notExportedList() {
        #expect(ConfigurationSettings.notExported == [
            "reading_text_size", "reading_line_spacing", "reading_typeface", "adult_partition_on", "adult_lock_timing", "last_refresh_at",
            // RD21's first-run flag and RD24's record of background runs:
            // device state (batch 2).
            "first_run_done", "background_refresh_runs",
        ])
    }

    @Test("the values in effect are read through the typed accessors, a stored value outside its set as the default")
    func inEffect() throws {
        let suite = "NewsPawConfigurationSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults)
        #expect(ConfigurationSettings.inEffect(preferences) == ConfigurationSettings(
            refreshMinutes: 30, retentionDays: 30, readingLocale: "zh-Hans", autoTranslateTitles: true, showOriginalTitles: false,
            backgroundRefresh: true
        ))
        defaults.set(45, forKey: "refresh_minutes")
        defaults.set("fr", forKey: "reading_locale")
        #expect(ConfigurationSettings.inEffect(preferences).refreshMinutes == 30)
        #expect(ConfigurationSettings.inEffect(preferences).readingLocale == "zh-Hans")
    }

    @Test("apply writes every member the file has through the typed setters and leaves an absent one")
    func apply() throws {
        let suite = "NewsPawConfigurationSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults)
        preferences.retention = .ninetyDays
        preferences.readingTextSize = .largest
        ConfigurationSettings(
            refreshMinutes: 60, readingLocale: "ja", autoTranslateTitles: false, showOriginalTitles: true, backgroundRefresh: false
        ).apply(to: preferences)
        #expect(preferences.refreshInterval == .sixtyMinutes)
        #expect(preferences.retention == .ninetyDays)
        #expect(preferences.readingLocale == .japanese)
        #expect(!preferences.autoTranslateTitles)
        #expect(preferences.showOriginalTitles)
        #expect(!preferences.backgroundRefresh)
        #expect(preferences.readingTextSize == .largest)
    }

    @Test("differences list the members present with another value, typed")
    func differences() {
        let here = ConfigurationSettings(
            refreshMinutes: 30, retentionDays: 30, readingLocale: "zh-Hans", autoTranslateTitles: true, showOriginalTitles: false, backgroundRefresh: true
        )
        let file = ConfigurationSettings(refreshMinutes: 15, retentionDays: 30, readingLocale: "en", showOriginalTitles: true, backgroundRefresh: false)
        #expect(file.differences(from: here) == [
            ConfigurationSettingDifference(setting: .refreshMinutes, here: .refreshInterval(.thirtyMinutes), file: .refreshInterval(.fifteenMinutes)),
            ConfigurationSettingDifference(setting: .readingLocale, here: .readingLocale(.simplifiedChinese), file: .readingLocale(.english)),
            ConfigurationSettingDifference(setting: .showOriginalTitles, here: .flag(false), file: .flag(true)),
            ConfigurationSettingDifference(setting: .backgroundRefresh, here: .flag(true), file: .flag(false)),
        ])
        let partitionHere = ConfigurationPartitionSettings(partition: "normal", dailyAutoLimit: 200, listThumbnails: true)
        let partitionFile = ConfigurationPartitionSettings(partition: "normal", dailyAutoLimit: 20, listThumbnails: true)
        #expect(partitionFile.differences(from: partitionHere) == [
            ConfigurationSettingDifference(setting: .dailyAutoLimit, here: .number(200), file: .number(20)),
        ])
    }

    @Test("the partition settings are read and written through the setters' own statements")
    func partitionSettings() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try await LibraryStore(directory: directory).openNormal()
        #expect(try await library.pool.read { try ConfigurationPartitionSettings.inEffect(.normal, in: $0) }
            == ConfigurationPartitionSettings(partition: "normal", dailyAutoLimit: 200, listThumbnails: true))
        try await library.pool.write { db in
            try ConfigurationPartitionSettings(partition: "normal", dailyAutoLimit: 7, listThumbnails: false).apply(in: db)
        }
        #expect(try await library.dailyAutomaticLimit() == 7)
        #expect(try await library.listThumbnails() == false)
        // An absent member leaves the stored value.
        try await library.pool.write { db in
            try ConfigurationPartitionSettings(partition: "normal", listThumbnails: true).apply(in: db)
        }
        #expect(try await library.dailyAutomaticLimit() == 7)
        #expect(try await library.listThumbnails())
    }
}
