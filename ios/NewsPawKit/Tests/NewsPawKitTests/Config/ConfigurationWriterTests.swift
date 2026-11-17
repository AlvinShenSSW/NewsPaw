import Foundation
@testable import NewsPawKit
import Testing

/// RD20 decision 1 and 6: the file's exact form, and the export with and
/// without the adult partition (criteria 2 and 11).
@Suite("Configuration writer and export")
struct ConfigurationWriterTests {
    @Test("the exact JSON of a small library: sorted keys, pretty printed, slashes unescaped, whole seconds in UTC")
    func exactJSON() async throws {
        let fixture = try await ConfigurationFixture.make()
        defer { fixture.remove() }
        let news = try await fixture.normal.testCategory("News", icon: "newspaper", overview: .manual)
        let feed = try await fixture.normal.testSource("Feed", url: "https://feed.example/rss", category: news, paused: true, autoTranslate: .off, bodyMode: .page)
        let page = try await fixture.normal.testSource("Page", url: "https://page.example/", category: news, kind: .webpage, translatePage: true)
        try await fixture.models(.normal).save(
            ModelSlotDraft(role: .primary, preset: .deepSeek, address: "https://api.deepseek.com", model: "deepseek-chat", newKey: secretKey("sk-exact-json-000000001")),
            testedOutcome: .passed
        )
        let data = try await ConfigurationTransfer.export(
            normal: fixture.normal, adult: nil, preferences: fixture.preferences, appVersion: "0.1.0 (1)",
            now: Date(timeIntervalSince1970: 1_794_819_600.75)
        )
        let expected = """
            {
              "app_version" : "0.1.0 (1)",
              "categories" : [
                {
                  "icon" : "newspaper",
                  "id" : "\(news.databaseKey)",
                  "name" : "News",
                  "overview" : "manual",
                  "partition" : "normal",
                  "sort_order" : 0
                }
              ],
              "exported_at" : "2026-11-16T09:00:00Z",
              "includes_adult" : false,
              "model_slots" : [
                {
                  "base_url" : "https://api.deepseek.com",
                  "model" : "deepseek-chat",
                  "partition" : "normal",
                  "preset" : "deepseek",
                  "role" : "primary"
                }
              ],
              "partition_settings" : [
                {
                  "daily_auto_limit" : 200,
                  "list_thumbnails" : true,
                  "partition" : "normal"
                }
              ],
              "schema_version" : 1,
              "settings" : {
                "auto_translate_titles" : true,
                "reading_locale" : "zh-Hans",
                "refresh_minutes" : 30,
                "retention_days" : 30,
                "show_original_titles" : false
              },
              "sources" : [
                {
                  "auto_translate" : "off",
                  "body_mode" : "page",
                  "category_id" : "\(news.databaseKey)",
                  "id" : "\(feed.databaseKey)",
                  "kind" : "feed",
                  "name" : "Feed",
                  "paused" : true,
                  "translate_page" : false,
                  "url" : "https://feed.example/rss"
                },
                {
                  "auto_translate" : "inherit",
                  "body_mode" : "auto",
                  "category_id" : "\(news.databaseKey)",
                  "id" : "\(page.databaseKey)",
                  "kind" : "webpage",
                  "name" : "Page",
                  "paused" : false,
                  "translate_page" : true,
                  "url" : "https://page.example/"
                }
              ]
            }
            """
        #expect(String(decoding: data, as: UTF8.self) == expected)
        // Read back by the reader.
        let document = try readDocument(data)
        #expect(document.normal.sources.map(\.name) == ["Feed", "Page"])
        #expect(document.adult == nil)
    }

    @Test("decision 6: an export from inside the adult partition with the switch on has both partitions; without it, nothing of the adult partition")
    func withAndWithoutAdult() async throws {
        let fixture = try await ConfigurationFixture.make()
        defer { fixture.remove() }
        let normalCategory = try await fixture.normal.testCategory("Everyday")
        try await fixture.normal.testSource("Daily", url: "https://daily.example/feed", category: normalCategory)
        let adultCategory = try await fixture.adult.testCategory("SecretCategoryName")
        try await fixture.adult.testSource("SecretSourceName", url: "https://secret-adult.example/feed", category: adultCategory)
        try await fixture.models(.adult).save(
            ModelSlotDraft(role: .primary, preset: .custom, address: "https://adult-models.example/v1", model: "adult-model", newKey: secretKey("sk-adult-export-000001")),
            testedOutcome: nil
        )
        let both = try await fixture.export(adult: true)
        let document = try readDocument(both)
        #expect(document.adult?.categories.map(\.name) == ["SecretCategoryName"])
        #expect(document.adult?.slots.map(\.model) == ["adult-model"])
        #expect(document.normal.sources.map(\.name) == ["Daily"])

        let normalOnly = try await fixture.export(adult: false)
        let text = String(decoding: normalOnly, as: UTF8.self)
        for adultText in ["SecretCategoryName", "SecretSourceName", "secret-adult.example", "adult-models.example", "adult-model", "\"adult\""] {
            #expect(!text.contains(adultText), "\(adultText)")
        }
        #expect(text.contains("\"includes_adult\" : false"))
        #expect(try readDocument(normalOnly).adult == nil)
    }

    @Test("criterion 11: a library over the file's limits is refused and no file is made")
    func overTheLimits() async throws {
        let categories = try await ConfigurationFixture.make()
        defer { categories.remove() }
        try await categories.normal.pool.write { db in
            for index in 0..<301 {
                try Category(id: UUID(), name: "N\(index)", sortOrder: index, iconName: "folder", overview: .auto, updatedAt: Date()).insert(db)
            }
        }
        try await categories.adult.pool.write { db in
            for index in 0..<200 {
                try Category(id: UUID(), name: "A\(index)", sortOrder: index, iconName: "folder", overview: .auto, updatedAt: Date()).insert(db)
            }
        }
        // 501 together: refused with the adult partition, accepted without.
        await #expect(throws: ConfigurationExportError.tooLarge) { try await categories.export(adult: true) }
        _ = try await categories.export(adult: false)

        let sources = try await ConfigurationFixture.make()
        defer { sources.remove() }
        let category = try await sources.normal.testCategory("Many")
        try await sources.normal.pool.write { db in
            for index in 0..<5_001 {
                try Source(
                    id: UUID(), categoryID: category, kind: .feed, url: "https://s\(index).example/feed", name: "S\(index)", siteURL: nil,
                    paused: false, autoTranslate: .inherit, bodyMode: .auto, translatePage: false, etag: nil, lastModified: nil,
                    lastSuccessAt: nil, lastError: nil, updatedAt: Date()
                ).insert(db)
            }
        }
        await #expect(throws: ConfigurationExportError.tooLarge) { try await sources.export(adult: false) }
    }

    @Test("an export the reader would refuse is not made: a loopback http model address of a debug build")
    func unreadableExport() async throws {
        let fixture = try await ConfigurationFixture.make()
        defer { fixture.remove() }
        // Written directly: only a debug build's form accepts it.
        try await fixture.normal.pool.write { db in
            try ModelSlot(
                role: .primary, preset: .custom, baseURL: "http://127.0.0.1:8080/v1", model: "local", keyRef: nil, testOutcome: nil,
                updatedAt: Date()
            ).insert(db)
        }
        await #expect(throws: ConfigurationExportError.failed) { try await fixture.export(adult: false) }
    }
}
