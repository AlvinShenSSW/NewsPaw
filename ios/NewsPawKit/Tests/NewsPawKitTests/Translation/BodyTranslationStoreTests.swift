import Foundation
import GRDB
@testable import NewsPawKit
import Testing

/// RD15 decision 2: migration `v7`, the rows of `body_translation`, and the
/// deletion of failed body rows with RD14's at every slot change. Criteria
/// 5 (the deletion) and 18 (the migration).
@Suite("Body translation store")
struct BodyTranslationStoreTests {
    // MARK: - Criterion 18: migration v7

    @Test("v7 creates body_translation with its columns, key and cascade")
    func version7Columns() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try await LibraryStore(directory: directory).openNormal()
        let (columns, keys, migrations) = try await library.pool.read { db in
            let migrations = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(body_translation)").map { row in
                SchemaTests.ColumnInfo(row["name"], row["type"], notNull: row["notnull"], default: row["dflt_value"], pk: row["pk"])
            }
            let keys = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(body_translation)").map { row in
                SchemaTests.ForeignKeyInfo(column: row["from"], table: row["table"], destination: row["to"], onDelete: row["on_delete"])
            }
            return (columns, keys, migrations)
        }
        #expect(migrations == ["v1", "v2", "v3", "v4", "v5", "v6", Schema.searchMigration, Schema.bodyTranslationMigration])
        #expect(columns == [
            .init("article_id", "TEXT", notNull: true, pk: 1),
            .init("locale", "TEXT", notNull: true, pk: 2),
            .init("source_hash", "TEXT", notNull: true, pk: 3),
            .init("text", "TEXT", notNull: false),
            .init("state", "TEXT", notNull: true),
            .init("error", "TEXT", notNull: false),
            .init("model", "TEXT", notNull: false),
            .init("updated_at", "TEXT", notNull: true),
        ])
        #expect(keys == [.init(column: "article_id", table: "article", destination: "id", onDelete: "CASCADE")])
    }

    @Test("criterion 18: a v6 library with articles, translations and usage rows migrates to the current version and keeps every row")
    func version6Migrates() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var upToVersion6 = DatabaseMigrator()
        Schema.registerV1(in: &upToVersion6)
        Schema.registerV2(in: &upToVersion6)
        Schema.registerV3(in: &upToVersion6)
        Schema.registerV4(in: &upToVersion6)
        Schema.registerV5(in: &upToVersion6)
        Schema.registerV6(in: &upToVersion6)
        let clock = TestClock()
        let before: DatabaseSnapshot
        do {
            let library = try await LibraryStore(directory: directory, now: clock.now).open(.normal, migrator: upToVersion6, create: true)
            let world = try await library.createCategory(name: "World", icon: .globe)
            try await Sample.fill(library, category: world.id, prefix: "v6", at: clock.now())
            let article = try #require(try await library.articles().first)
            try await library.storeTranslations([
                TranslationRecord(articleID: article.id, locale: .simplifiedChinese, state: .done, title: "译", excerpt: nil, failure: nil, model: "m"),
            ])
            try await library.pool.write { db in
                try db.execute(sql: """
                    INSERT INTO usage (id, model, purpose, input_tokens, output_tokens, outcome, at, automatic)
                    VALUES ('5b0c7a6e-0000-4000-8000-000000000006', 'm', 'titles', 1, 2, 'ok', '2026-11-16 00:00:00.000', 1)
                    """)
            }
            before = try await library.pool.read { try DatabaseSnapshot.read($0) }
        }
        #expect(before.appliedMigrations == ["v1", "v2", "v3", "v4", "v5", "v6"])

        let library = try await LibraryStore(directory: directory).openNormal()

        let after = try await library.pool.read { try DatabaseSnapshot.read($0) }
        #expect(after.appliedMigrations == ["v1", "v2", "v3", "v4", "v5", "v6", Schema.searchMigration, Schema.bodyTranslationMigration])
        for (table, rows) in before.rows where table != "grdb_migrations" {
            #expect(after.rows[table] == rows, "rows of \(table)")
        }
        #expect(after.rows["body_translation"] == [])
        #expect(after.integrity == ["ok"])
        let added = after.schema.filter { !before.schema.contains($0) }.map { "\($0[0] ?? "") \($0[1] ?? "")" }
        // The search migration (RD25) runs before it.
        #expect(Set(added) == SchemaTests.bodyTranslationMigrationObjects.union(SchemaTests.searchMigrationObjects))
    }

    // MARK: - Rows

    @Test("a row per article, locale and text; a write replaces it; a write for a deleted article writes nothing; rows go with their article")
    func storing() async throws {
        let fixture = try await TranslatorFixture.make(primary: false)
        defer { fixture.remove() }
        let source = try await fixture.source()
        let kept = try await fixture.article("Kept", in: source)
        let deleted = try await fixture.article("Deleted", in: source)
        let one = BodySegments.hash("One")
        let two = BodySegments.hash("Two")
        #expect(try await fixture.library.storeBodyTranslations([
            BodyTextRecord(hash: one, state: .done, text: "一", failure: nil, model: "m"),
            BodyTextRecord(hash: two, state: .failed, text: nil, failure: .refused, model: nil),
        ], ofArticle: kept, locale: .simplifiedChinese))
        #expect(try await fixture.library.storeBodyTranslations([
            BodyTextRecord(hash: one, state: .done, text: "ひとつ", failure: nil, model: "m"),
        ], ofArticle: kept, locale: .japanese))
        let stored = try await fixture.library.bodyTranslations(ofArticle: kept, locale: .simplifiedChinese)
        #expect(stored[one]?.state == .done)
        #expect(stored[one]?.text == "一")
        #expect(stored[one]?.model == "m")
        #expect(stored[one]?.updatedAt == fixture.clock.now())
        #expect(stored[two] == StoredBodyText(state: .failed, text: nil, failure: .refused, model: nil, updatedAt: fixture.clock.now()))
        #expect(try await fixture.library.bodyTranslations(ofArticle: kept, locale: .japanese).mapValues(\.text) == [one: "ひとつ"])
        #expect(try await fixture.library.bodyTranslations(ofArticle: kept, locale: .english).isEmpty)

        // A write replaces the row of the same text.
        _ = try await fixture.library.storeBodyTranslations([
            BodyTextRecord(hash: two, state: .done, text: "二", failure: nil, model: "backup-model"),
        ], ofArticle: kept, locale: .simplifiedChinese)
        #expect(try await fixture.library.bodyTranslations(ofArticle: kept, locale: .simplifiedChinese)[two]?.text == "二")

        try await fixture.library.pool.write { db in
            try db.execute(sql: "DELETE FROM article WHERE id = ?", arguments: [deleted.databaseKey])
        }
        #expect(try await !fixture.library.storeBodyTranslations([
            BodyTextRecord(hash: one, state: .done, text: "一", failure: nil, model: "m"),
        ], ofArticle: deleted, locale: .simplifiedChinese))
        #expect(try await fixture.library.articleExists(kept))
        #expect(try await !fixture.library.articleExists(deleted))
        #expect(try await Self.rowCount(fixture.library) == 3)
        try await fixture.library.pool.write { db in
            try db.execute(sql: "DELETE FROM article WHERE id = ?", arguments: [kept.databaseKey])
        }
        #expect(try await Self.rowCount(fixture.library) == 0)
    }

    @Test("a failed row never replaces a done one; a done row replaces a failed one")
    func failedNeverReplacesDone() async throws {
        let fixture = try await TranslatorFixture.make(primary: false)
        defer { fixture.remove() }
        let article = try await fixture.article("A", in: try await fixture.source())
        let hash = BodySegments.hash("One")
        #expect(try await fixture.library.storeBodyTranslations([
            BodyTextRecord(hash: hash, state: .done, text: "一", failure: nil, model: "m"),
        ], ofArticle: article, locale: .simplifiedChinese))
        #expect(try await fixture.library.storeBodyTranslations([
            BodyTextRecord(hash: hash, state: .failed, text: nil, failure: .refused, model: nil),
        ], ofArticle: article, locale: .simplifiedChinese), "the article is there: not reported gone")
        #expect(try await fixture.library.bodyTranslations(ofArticle: article, locale: .simplifiedChinese)[hash]?.text == "一")
        let other = BodySegments.hash("Two")
        _ = try await fixture.library.storeBodyTranslations([
            BodyTextRecord(hash: other, state: .failed, text: nil, failure: .refused, model: nil),
        ], ofArticle: article, locale: .simplifiedChinese)
        _ = try await fixture.library.storeBodyTranslations([
            BodyTextRecord(hash: other, state: .done, text: "二", failure: nil, model: "m"),
        ], ofArticle: article, locale: .simplifiedChinese)
        #expect(try await fixture.library.bodyTranslations(ofArticle: article, locale: .simplifiedChinese)[other]?.text == "二")
    }

    @Test("the title row read for an excerpt's pre-fill is the one of the language asked for")
    func titleRowByLocale() async throws {
        let fixture = try await TranslatorFixture.make(primary: false)
        defer { fixture.remove() }
        let article = try await fixture.article("A", excerpt: "An excerpt.", in: try await fixture.source())
        try await fixture.library.storeTranslations([
            TranslationRecord(articleID: article, locale: .simplifiedChinese, state: .done, title: "甲", excerpt: "摘要", failure: nil, model: "m"),
        ])
        let translator = BodyTranslator(models: fixture.models)
        #expect(try await translator.titleTranslation(ofArticle: article, locale: .simplifiedChinese)?.excerpt == "摘要")
        #expect(try await translator.titleTranslation(ofArticle: article, locale: .japanese) == nil)
    }

    @Test("a row of a state or reason this build does not know is read as nothing, or as malformed")
    func unknownValues() async throws {
        let fixture = try await TranslatorFixture.make(primary: false)
        defer { fixture.remove() }
        let article = try await fixture.article("A", in: try await fixture.source())
        try await fixture.library.pool.write { db in
            for (hash, state, error) in [("h1", "pending", nil), ("h2", "failed", "tired"), ("h3", "done", nil)] as [(String, String, String?)] {
                try db.execute(
                    sql: """
                        INSERT INTO body_translation (article_id, locale, source_hash, text, state, error, model, updated_at)
                        VALUES (?, 'zh-Hans', ?, NULL, ?, ?, NULL, '2026-11-16 00:00:00.000')
                        """,
                    arguments: [article.databaseKey, hash, state, error]
                )
            }
        }
        let stored = try await fixture.library.bodyTranslations(ofArticle: article, locale: .simplifiedChinese)
        #expect(stored.keys.sorted() == ["h2"], "a done row without text is no translation")
        #expect(stored["h2"]?.failure == .malformed)
    }

    @Test("the title row's state, model and time for Article Info; none without a row")
    func titleDetails() async throws {
        let fixture = try await TranslatorFixture.make(primary: false)
        defer { fixture.remove() }
        let article = try await fixture.article("A", in: try await fixture.source())
        #expect(try await fixture.library.titleTranslationDetails(ofArticle: article, locale: .simplifiedChinese) == nil)
        try await fixture.library.storeTranslations([
            TranslationRecord(articleID: article, locale: .simplifiedChinese, state: .done, title: "甲", excerpt: nil, failure: nil, model: "m1"),
        ])
        #expect(try await fixture.library.titleTranslationDetails(ofArticle: article, locale: .simplifiedChinese)
            == TitleTranslationDetails(state: .done, model: "m1", updatedAt: fixture.clock.now()))
    }

    // MARK: - Criterion 5: a slot change makes failed body texts wait again

    @Test("criterion 5: saving a slot, removing one and removing a key delete the failed body rows with RD14's, in the same transaction",
          arguments: ["save", "remove", "removeKey"])
    func slotChangeDeletesFailedRows(_ change: String) async throws {
        let fixture = try await TranslatorFixture.make(backup: true)
        defer { fixture.remove() }
        let article = try await fixture.article("A", in: try await fixture.source())
        try await fixture.library.storeTranslations([
            TranslationRecord(articleID: article, locale: .simplifiedChinese, state: .failed, title: nil, excerpt: nil, failure: .refused, model: "m"),
        ])
        _ = try await fixture.library.storeBodyTranslations([
            BodyTextRecord(hash: "done", state: .done, text: "好", failure: nil, model: "m"),
            BodyTextRecord(hash: "failed", state: .failed, text: nil, failure: .refused, model: nil),
        ], ofArticle: article, locale: .simplifiedChinese)
        switch change {
        case "save": try await fixture.saveSlot(.backup, host: "other.example.invalid")
        case "remove": try await fixture.models.removeSlot(.backup)
        default: try await fixture.models.removeKey(.backup)
        }
        #expect(try await fixture.library.bodyTranslations(ofArticle: article, locale: .simplifiedChinese).keys.sorted() == ["done"])
        #expect(try await fixture.translation(article) == nil)
    }

    @Test("the usage rows of one purpose are counted")
    func usageCount() async throws {
        let fixture = try await TranslatorFixture.make(primary: false)
        defer { fixture.remove() }
        for purpose in [UsagePurpose.body, .body, .titles] {
            try await fixture.library.insertUsage(UsageRecord(
                id: UUID(), model: "m", purpose: purpose, inputTokens: nil, outputTokens: nil, outcome: .ok, at: fixture.clock.now(), automatic: false
            ))
        }
        #expect(try await fixture.library.usageCount(purpose: .body) == 2)
        #expect(try await fixture.library.usageCount(purpose: .titles) == 1)
        #expect(try await fixture.library.usageCount(purpose: .page) == 0)
    }

    static func rowCount(_ library: Library) async throws -> Int {
        try await library.pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM body_translation") ?? 0 }
    }
}
