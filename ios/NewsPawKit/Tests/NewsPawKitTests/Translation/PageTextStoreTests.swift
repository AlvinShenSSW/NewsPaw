import Foundation
import GRDB
@testable import NewsPawKit
import Testing

/// RD16 decision 7: migration `v8`, the rows of `page_text` and their
/// clean-up. Criteria 10 (the store and the clean-up) and 17 (the
/// migration).
@Suite("Page text store")
struct PageTextStoreTests {
    // MARK: - Criterion 17: migration v8

    @Test("v8 creates page_text with its columns, key and index; neither the text nor the host has a column")
    func version8Columns() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try await LibraryStore(directory: directory).openNormal()
        let (columns, indexes, migrations) = try await library.pool.read { db in
            let migrations = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(page_text)").map { row in
                SchemaTests.ColumnInfo(row["name"], row["type"], notNull: row["notnull"], default: row["dflt_value"], pk: row["pk"])
            }
            var indexes: [String: [String]] = [:]
            for index in try Row.fetchAll(db, sql: "PRAGMA index_list(page_text)") where (index["origin"] as String) == "c" {
                let name: String = index["name"]
                indexes[name] = try Row.fetchAll(db, sql: "PRAGMA index_info(\(name))").map { $0["name"] as String }
            }
            return (columns, indexes, migrations)
        }
        #expect(migrations == currentMigrations)
        #expect(columns == [
            .init("text_hash", "TEXT", notNull: true, pk: 1),
            .init("locale", "TEXT", notNull: true, pk: 2),
            .init("translated", "TEXT", notNull: true),
            .init("model", "TEXT", notNull: true),
            .init("updated_at", "TEXT", notNull: true),
            .init("last_used_at", "TEXT", notNull: true),
        ])
        #expect(indexes == ["page_text_last_used": ["last_used_at"]])
    }

    @Test("criterion 17: a library before the page-text migration, with articles, translations, body rows and usage, migrates and keeps every row")
    func version7Migrates() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var upToVersion7 = DatabaseMigrator()
        Schema.registerV1(in: &upToVersion7)
        Schema.registerV2(in: &upToVersion7)
        Schema.registerV3(in: &upToVersion7)
        Schema.registerV4(in: &upToVersion7)
        Schema.registerV5(in: &upToVersion7)
        Schema.registerV6(in: &upToVersion7)
        Schema.registerSearch(in: &upToVersion7)
        Schema.registerBodyTranslation(in: &upToVersion7)
        let clock = TestClock()
        let before: DatabaseSnapshot
        do {
            let library = try await LibraryStore(directory: directory, now: clock.now).open(.normal, migrator: upToVersion7, create: true)
            let world = try await library.createCategory(name: "World", icon: .globe)
            try await Sample.fill(library, category: world.id, prefix: "v7", at: clock.now())
            let article = try #require(try await library.articles().first)
            try await library.storeTranslations([
                TranslationRecord(articleID: article.id, locale: .simplifiedChinese, state: .done, title: "译", excerpt: nil, failure: nil, model: "m"),
            ])
            _ = try await library.storeBodyTranslations(
                [BodyTextRecord(hash: "abc", state: .done, text: "译文", failure: nil, model: "m")], ofArticle: article.id, locale: .simplifiedChinese
            )
            try await library.pool.write { db in
                try db.execute(sql: """
                    INSERT INTO usage (id, model, purpose, input_tokens, output_tokens, outcome, at, automatic)
                    VALUES ('5b0c7a6e-0000-4000-8000-000000000007', 'm', 'body', 1, 2, 'ok', '2026-11-16 00:00:00.000', 0)
                    """)
            }
            before = try await library.pool.read { try DatabaseSnapshot.read($0) }
        }
        #expect(before.appliedMigrations == Array(currentMigrations.dropLast()))

        let library = try await LibraryStore(directory: directory).openNormal()

        let after = try await library.pool.read { try DatabaseSnapshot.read($0) }
        #expect(after.appliedMigrations == currentMigrations)
        for (table, rows) in before.rows where table != "grdb_migrations" {
            #expect(after.rows[table] == rows, "rows of \(table)")
        }
        #expect(after.rows["body_translation"]?.count == 1)
        #expect(after.rows["page_text"] == [])
        #expect(after.integrity == ["ok"])
        let added = after.schema.filter { !before.schema.contains($0) }.map { "\($0[0] ?? "") \($0[1] ?? "")" }
        #expect(added.sorted() == ["index page_text_last_used", "index sqlite_autoindex_page_text_1", "table page_text"])
    }

    // MARK: - Criterion 10: rows

    static let host = "pages.example.invalid"

    @Test("a row is stored by host, text and locale with the model's name; another host, another text or another locale misses; a hit refreshes last_used_at")
    func storeAndLookUp() async throws {
        let fixture = try await TranslatorFixture.make(primary: false)
        defer { fixture.remove() }
        let library = fixture.library
        let key = try #require(PageBatcher.cacheKey(host: Self.host, text: "ログイン"))
        try await library.storePageTexts([key: "登录"], locale: .simplifiedChinese, model: "primary-model")
        let row = try #require(try await library.pool.read { db -> [String: String]? in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM page_text") else { return nil }
            return Dictionary(uniqueKeysWithValues: row.columnNames.map { ($0, row[$0] as String? ?? "") })
        })
        #expect(row["text_hash"] == key)
        #expect(row["locale"] == "zh-Hans")
        #expect(row["translated"] == "登录")
        #expect(row["model"] == "primary-model")
        let stored: Date = try #require(try await library.pool.read { db in
            try Date.fetchOne(db, sql: "SELECT last_used_at FROM page_text")
        })
        // Neither the text nor the host is in the row.
        for (column, value) in row {
            #expect(!value.contains("ログイン") && !value.contains("example"), "\(column)")
        }

        let otherHost = try #require(PageBatcher.cacheKey(host: "other.example.invalid", text: "ログイン"))
        let otherText = try #require(PageBatcher.cacheKey(host: Self.host, text: "ログアウト"))
        #expect(try await library.pageTexts([otherHost, otherText], locale: .simplifiedChinese) == [:])
        #expect(try await library.pageTexts([key], locale: .english) == [:])

        fixture.clock.advance(seconds: 3_600)
        #expect(try await library.pageTexts([key, otherHost], locale: .simplifiedChinese) == [key: "登录"])
        let touched: Date = try #require(try await library.pool.read { db in
            try Date.fetchOne(db, sql: "SELECT last_used_at FROM page_text")
        })
        #expect(touched.timeIntervalSince(stored) == 3_600)

        // A second store replaces the row.
        try await library.storePageTexts([key: "登入"], locale: .simplifiedChinese, model: "backup-model")
        #expect(try await library.pageTexts([key], locale: .simplifiedChinese) == [key: "登入"])
        #expect(try await library.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM page_text") } == 1)
    }

    @Test("criterion 10: clean-up deletes rows unused for the retention period also on a day when no article expires, at the boundary; Forever keeps them")
    func cleanUp() async throws {
        let fixture = try await TranslatorFixture.make(primary: false)
        defer { fixture.remove() }
        let library = fixture.library
        let day = 86_400
        let old = try #require(PageBatcher.cacheKey(host: Self.host, text: "old"))
        let exact = try #require(PageBatcher.cacheKey(host: Self.host, text: "exact"))
        let fresh = try #require(PageBatcher.cacheKey(host: Self.host, text: "fresh"))
        try await library.storePageTexts([old: "旧"], locale: .simplifiedChinese, model: "m")
        fixture.clock.advance(seconds: 1)
        try await library.storePageTexts([exact: "刚好"], locale: .simplifiedChinese, model: "m")
        fixture.clock.advance(seconds: 7 * day - 1)
        try await library.storePageTexts([fresh: "新"], locale: .simplifiedChinese, model: "m")
        // Seven days after `exact` was stored: `old` is one second older.
        fixture.clock.advance(seconds: 1)
        #expect(try await library.articles().isEmpty, "no article expires today")

        #expect(try await library.cleanUp(keeping: .forever) == 0)
        #expect(try await rowCount(library) == 3, "Forever keeps every row")

        #expect(try await library.cleanUp(keeping: .sevenDays) == 0, "the count stays the articles'")
        let left = try await library.pool.read { try String.fetchAll($0, sql: "SELECT text_hash FROM page_text") }
        #expect(Set(left) == [exact, fresh])
    }

    private func rowCount(_ library: Library) async throws -> Int {
        try await library.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM page_text") ?? 0 }
    }
}
