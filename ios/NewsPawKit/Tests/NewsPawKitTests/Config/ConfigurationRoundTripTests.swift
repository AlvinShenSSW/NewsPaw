import Foundation
import GRDB
@testable import NewsPawKit
import Testing

/// RD20 criteria 1, 2 and 14: a file exported from two full libraries
/// restores them into an empty store by Merge and by Replace; no secret,
/// device setting or state is in it; nothing makes a request.
@Suite("Configuration round trip", .serialized)
struct ConfigurationRoundTripTests {
    static let keys: [Partition: [ModelRole: String]] = [
        .normal: [.primary: "sk-sentinel-normal-primary-AAAA", .backup: "sk-sentinel-normal-backup-BBBB"],
        .adult: [.primary: "sk-sentinel-adult-primary-CCCC", .backup: "sk-sentinel-adult-backup-DDDD"],
    ]

    /// Fills both libraries of `fixture` with every kind of content and
    /// every setting at a value that is not the default, device settings
    /// included.
    static func fill(_ fixture: ConfigurationFixture, http: any ModelHTTP) async throws {
        let normal = fixture.normal
        let world = try await normal.testCategory("World", icon: "globe", overview: .manual)
        let tech = try await normal.testCategory("Tech", icon: "cpu", overview: .off)
        try await normal.testCategory("Empty", icon: "star")
        try await normal.testSource("Daily Feed", url: "https://daily.example/rss", category: world, autoTranslate: .on, bodyMode: .feed)
        try await normal.testSource("Paused Feed", url: "https://paused.example/rss", category: world, paused: true)
        try await normal.testSource("Swift Releases", url: "https://github.com/swiftlang/swift/releases.atom", category: tech, kind: .github, autoTranslate: .off, bodyMode: .page)
        try await normal.testSource("Front Page", url: "https://front.example/", category: tech, kind: .webpage, translatePage: true)
        try await normal.testSource("Models", url: "https://huggingface.co/models", category: tech, kind: .huggingface)
        let adult = fixture.adult
        let hidden = try await adult.testCategory("Private", icon: "heart", overview: .manual)
        try await adult.testCategory("Second", icon: "film", overview: .off)
        try await adult.testSource("Hidden Feed", url: "https://hidden.example/rss", category: hidden, paused: true, autoTranslate: .off)
        try await adult.testSource("Hidden Page", url: "https://hidden.example/", category: hidden, kind: .webpage, translatePage: true)
        for partition in Partition.allCases {
            let models = fixture.models(partition, http: http)
            for role in ModelRole.allCases {
                let address = "https://\(partition.rawValue)-\(role.rawValue).models.example/v1"
                try await models.save(
                    ModelSlotDraft(role: role, preset: role == .primary ? .openRouter : .custom, address: address, model: "\(partition)-\(role)-model",
                                   newKey: secretKey(keys[partition]![role]!)),
                    testedOutcome: .passed
                )
            }
        }
        try await normal.setDailyAutomaticLimit(5)
        try await normal.setListThumbnails(false)
        try await adult.setDailyAutomaticLimit(7)
        try await adult.setListThumbnails(false)
        try await normal.setLastRefreshAt(Date(timeIntervalSince1970: 1_700_000_000))
        let preferences = fixture.preferences
        preferences.refreshInterval = .sixtyMinutes
        preferences.retention = .ninetyDays
        preferences.readingLocale = .japanese
        preferences.autoTranslateTitles = false
        preferences.showOriginalTitles = true
        setDeviceSettings(preferences, variant: 1)
    }

    /// Device settings at values that are not the defaults; two variants.
    static func setDeviceSettings(_ preferences: Preferences, variant: Int) {
        preferences.readingTextSize = variant == 1 ? .largest : .smallest
        preferences.readingLineSpacing = variant == 1 ? .relaxed : .compact
        preferences.readingTypeface = .serif
        preferences.adultPartitionIsOn = true
        preferences.lockTiming = variant == 1 ? .afterOneMinute : .afterFiveMinutes
    }

    static func deviceSettings(_ preferences: Preferences) -> [String] {
        [
            "\(preferences.readingTextSize)", "\(preferences.readingLineSpacing)", "\(preferences.readingTypeface)",
            "\(preferences.adultPartitionIsOn)", "\(preferences.lockTiming)",
        ]
    }

    struct PartitionContent: Equatable {
        var categories: [String]
        var sources: [String]
        var slots: [String]
    }

    /// What a round trip must restore of one library, in comparable form.
    static func content(_ library: Library) async throws -> PartitionContent {
        let categories = try await library.categories()
        let names = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })
        let sources = try await library.sourceSummaries().map { source in
            "\(source.address) | \(source.name) | \(source.kind) | \(names[source.categoryID] ?? "?") | "
                + "\(source.paused) \(source.autoTranslate) \(source.bodyMode) \(source.translatePage)"
        }.sorted()
        let slots = try await library.modelSlots().values.sorted { $0.role.rawValue < $1.role.rawValue }.map { slot in
            "\(slot.role) \(slot.preset) \(slot.baseURL) \(slot.model)"
        }
        return PartitionContent(
            categories: categories.map { "\($0.sortOrder) \($0.name) \($0.iconName) \($0.overview)" }, sources: sources, slots: slots
        )
    }

    @Test("criterion 1: Merge and Replace into an empty store restore both partitions; Replace the settings, Merge none; device settings stay")
    func roundTrip() async throws {
        let http = StubModelHTTP.completing()
        let transport = CountingTransport { url in CountingTransport.feed(url) }
        let source = try await ConfigurationFixture.make()
        defer { source.remove() }
        try await Self.fill(source, http: http)
        let data = try await source.export(adult: true)
        let document = try readDocument(data)
        let expected = (normal: try await Self.content(source.normal), adult: try await Self.content(source.adult))

        for mode in [ConfigurationImportMode.merge, .replace] {
            let target = try await ConfigurationFixture.make()
            defer { target.remove() }
            Self.setDeviceSettings(target.preferences, variant: 2)
            try await target.normal.setLastRefreshAt(Date(timeIntervalSince1970: 1_600_000_000))
            let devices = Self.deviceSettings(target.preferences)
            let targetSettings = ConfigurationSettings.inEffect(target.preferences)

            let preview = try await target.preview(document)
            if mode == .merge {
                // The settings that differ are listed under Conflicts.
                #expect(preview.settingDifferences.map(\.setting) == [.refreshMinutes, .retentionDays, .readingLocale, .autoTranslateTitles, .showOriginalTitles])
                #expect(preview.partitions.map { $0.merge.settingDifferences.map(\.setting) } == [[.dailyAutoLimit, .listThumbnails], [.dailyAutoLimit, .listThumbnails]])
            }
            let result = await target.importDocument(document, mode: mode)
            guard case .imported = result.normal, case .imported? = result.adult else {
                Issue.record("\(mode): not imported")
                continue
            }
            #expect(try await Self.content(target.normal) == expected.normal, "\(mode)")
            #expect(try await Self.content(target.adult) == expected.adult, "\(mode)")
            // No key reference, no Test result.
            for library in [target.normal, target.adult] {
                for slot in try await library.modelSlots().values {
                    #expect(slot.keyRef == nil)
                    #expect(slot.testOutcome == nil)
                }
            }
            #expect(target.normalKeys.references.isEmpty && target.adultKeys.references.isEmpty)
            switch mode {
            case .replace:
                #expect(ConfigurationSettings.inEffect(target.preferences) == ConfigurationSettings.inEffect(source.preferences))
                #expect(try await target.normal.dailyAutomaticLimit() == 5)
                #expect(try await target.adult.dailyAutomaticLimit() == 7)
                #expect(try await target.normal.listThumbnails() == false)
                #expect(try await target.adult.listThumbnails() == false)
            case .merge:
                #expect(ConfigurationSettings.inEffect(target.preferences) == targetSettings)
                #expect(try await target.normal.dailyAutomaticLimit() == 200)
                #expect(try await target.adult.listThumbnails())
            }
            #expect(Self.deviceSettings(target.preferences) == devices)
            #expect(try await target.normal.lastRefreshAt() == Date(timeIntervalSince1970: 1_600_000_000))
            #expect(try await target.adult.lastRefreshAt() == nil)
        }
        // Criterion 14: nothing asked the models or the transport.
        #expect(http.received.isEmpty)
        #expect(transport.received.isEmpty)
    }

    @Test("criterion 2: the file holds no key, no key reference, no Test result, no device setting and no refresh state")
    func noSecret() async throws {
        let fixture = try await ConfigurationFixture.make()
        defer { fixture.remove() }
        try await Self.fill(fixture, http: StubModelHTTP.completing())
        let references = fixture.normalKeys.references.union(fixture.adultKeys.references)
        #expect(references.count == 4)
        for data in [try await fixture.export(adult: true), try await fixture.export(adult: false)] {
            let text = String(decoding: data, as: UTF8.self)
            for partition in Self.keys.values {
                for key in partition.values {
                    #expect(!text.contains(key))
                    // Not even its last four characters with the prefix.
                    #expect(!text.contains(String(key.suffix(8))))
                }
            }
            for reference in references {
                #expect(!text.contains(reference))
                #expect(!text.contains(reference.lowercased()))
            }
            for member in ["key", "key_ref", "test_outcome", "passed", "last_refresh_at", "site_url", "etag", "last_error"]
                + Array(ConfigurationSettings.notExported) {
                #expect(!text.contains("\"\(member)\""), "\(member)")
            }
            #expect(!text.contains("\"passed\""))
            // The member names of the file are only those of decision 1.
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(Set(object.keys) == ["schema_version", "exported_at", "app_version", "includes_adult", "settings", "categories", "sources", "partition_settings", "model_slots"])
            for slot in object["model_slots"] as? [[String: Any]] ?? [] {
                #expect(Set(slot.keys) == ["partition", "role", "preset", "base_url", "model"])
            }
            for settings in object["partition_settings"] as? [[String: Any]] ?? [] {
                #expect(Set(settings.keys) == ["partition", "daily_auto_limit", "list_thumbnails"])
            }
            #expect(Set((object["settings"] as? [String: Any] ?? [:]).keys) == Set(ConfigurationSettings.CodingKeys.allCases.map(\.rawValue)))
        }
    }

    @Test("criterion 2: nothing from the file is written to a key store, whatever the file holds")
    func nothingIntoTheKeychain() async throws {
        let fixture = try await ConfigurationFixture.make()
        defer { fixture.remove() }
        let data = ConfigurationJSON.with { object in
            object["key"] = "sk-hostile-file-key-0000000000"
            ConfigurationJSON.change(&object, "model_slots", at: 0) { slot in
                slot["key"] = "sk-hostile-file-key-0000000000"
                slot["api_key"] = "sk-hostile-file-key-0000000000"
                slot["key_ref"] = "11111111-2222-3333-4444-555555555555"
            }
        }
        let document = try readDocument(data)
        for mode in [ConfigurationImportMode.merge, .replace] {
            await fixture.importDocument(document, mode: mode)
            #expect(fixture.normalKeys.references.isEmpty)
            #expect(fixture.adultKeys.references.isEmpty)
            for library in [fixture.normal, fixture.adult] {
                for slot in try await library.modelSlots().values {
                    #expect(slot.keyRef == nil)
                }
            }
        }
    }
}
