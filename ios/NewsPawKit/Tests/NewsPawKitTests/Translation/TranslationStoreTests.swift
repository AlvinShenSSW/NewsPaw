import Foundation
import GRDB
@testable import NewsPawKit
import Testing

/// RD14 decisions 2, 8 and 11: migration `v6`, the translation rows, the
/// list queries' join, the deletion of failed rows on a slot change and
/// the daily count. Criteria 6 (the deletion), 12 (rows carry their
/// translation) and 16 (the migration).
@Suite("Translation store", .serialized)
struct TranslationStoreTests {
    // MARK: - Criterion 16: migration v6

    @Test("v6 creates translation with its columns and key, and usage.automatic defaulting to 0")
    func version6Columns() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try await LibraryStore(directory: directory).openNormal()
        let (translation, usage, keys, migrations) = try await library.pool.read { db in
            func columns(_ table: String) throws -> [SchemaTests.ColumnInfo] {
                try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { row in
                    SchemaTests.ColumnInfo(row["name"], row["type"], notNull: row["notnull"], default: row["dflt_value"], pk: row["pk"])
                }
            }
            // After a statement that reads the schema: the foreign-key pragma
            // alone does not reload a reader's schema, which predates the
            // migration on this connection (measured).
            let migrations = try String.fetchAll(db, sql: migrationsInOrderSQL)
            let translation = try columns("translation")
            let usage = try columns("usage")
            let keys = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(translation)").map { row in
                SchemaTests.ForeignKeyInfo(column: row["from"], table: row["table"], destination: row["to"], onDelete: row["on_delete"])
            }
            return (translation, usage, keys, migrations)
        }
        #expect(migrations == currentMigrations)
        #expect(translation == [
            .init("article_id", "TEXT", notNull: true, pk: 1),
            .init("locale", "TEXT", notNull: true, pk: 2),
            .init("title", "TEXT", notNull: false),
            .init("excerpt", "TEXT", notNull: false),
            .init("state", "TEXT", notNull: true),
            .init("error", "TEXT", notNull: false),
            .init("model", "TEXT", notNull: false),
            .init("updated_at", "TEXT", notNull: true),
        ])
        #expect(keys == [.init(column: "article_id", table: "article", destination: "id", onDelete: "CASCADE")])
        #expect(usage.last == .init("automatic", "INTEGER", notNull: true, default: "0"))
    }

    @Test("a v5 library with usage rows and articles migrates to v6 and keeps every row; old usage rows are not automatic")
    func version5Migrates() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var upToVersion5 = DatabaseMigrator()
        Schema.registerV1(in: &upToVersion5)
        Schema.registerV2(in: &upToVersion5)
        Schema.registerV3(in: &upToVersion5)
        Schema.registerV4(in: &upToVersion5)
        Schema.registerV5(in: &upToVersion5)
        let clock = TestClock()
        let before: DatabaseSnapshot
        do {
            let library = try await LibraryStore(directory: directory, now: clock.now).open(.normal, migrator: upToVersion5, create: true)
            let world = try await library.createCategory(name: "World", icon: .globe)
            try await Sample.fill(library, category: world.id, prefix: "v5", at: clock.now())
            try await library.pool.write { db in
                try db.execute(sql: """
                    INSERT INTO usage (id, model, purpose, input_tokens, output_tokens, outcome, at)
                    VALUES ('5b0c7a6e-0000-4000-8000-000000000001', 'm', 'test', 1, 2, 'ok', '2026-11-15 00:00:00.000')
                    """)
            }
            before = try await library.pool.read { try DatabaseSnapshot.read($0) }
        }
        #expect(before.appliedMigrations == ["v1", "v2", "v3", "v4", "v5"])

        let library = try await LibraryStore(directory: directory).openNormal()

        let after = try await library.pool.read { try DatabaseSnapshot.read($0) }
        #expect(after.appliedMigrations == currentMigrations)
        for table in ["category", "source", "article", "article_body", "seen", "setting", "model_slot"] {
            #expect(after.rows[table] == before.rows[table], "rows of \(table)")
        }
        #expect(after.rows["usage"] == before.rows["usage"]?.map { $0 + ["integer 0"] })
        #expect(after.rows["translation"] == [])
        #expect(after.integrity == ["ok"])
        #expect(try await library.automaticRequestCount(since: .distantPast) == 0)
    }

    // MARK: - Rows

    @Test("a row per article and locale; a write replaces it; a write for a deleted article is dropped alone")
    func storing() async throws {
        let fixture = try await TranslatorFixture.make(primary: false)
        defer { fixture.remove() }
        let source = try await fixture.source()
        let kept = try await fixture.article("Kept", in: source)
        let deleted = try await fixture.article("Deleted", in: source)
        try await fixture.library.pool.write { db in
            try db.execute(sql: "DELETE FROM article WHERE id = ?", arguments: [deleted.databaseKey])
        }
        let stored = try await fixture.library.storeTranslations([
            TranslationRecord(articleID: kept, locale: .simplifiedChinese, state: .done, title: "留", excerpt: nil, failure: nil, model: "m"),
            TranslationRecord(articleID: deleted, locale: .simplifiedChinese, state: .done, title: "删", excerpt: nil, failure: nil, model: "m"),
            TranslationRecord(articleID: kept, locale: .japanese, state: .failed, title: nil, excerpt: nil, failure: .length, model: nil),
        ])
        #expect(stored == [kept])
        #expect(try await fixture.translation(kept) == StoredTranslation(state: .done, title: "留", excerpt: nil, failure: nil))
        #expect(try await fixture.translation(kept, .japanese) == StoredTranslation(state: .failed, title: nil, excerpt: nil, failure: .length))
        #expect(try await fixture.translationCount() == 2)
        try await fixture.library.storeTranslations([
            TranslationRecord(articleID: kept, locale: .simplifiedChinese, state: .none, title: nil, excerpt: nil, failure: nil, model: nil),
        ])
        #expect(try await fixture.translation(kept) == StoredTranslation(state: .none, title: nil, excerpt: nil, failure: nil))
        let raw = try #require(try await fixture.rawTranslation(kept, .japanese))
        #expect(raw.error == "length")
        #expect(raw.state == "failed")
    }

    @Test("a translation goes with its article")
    func cascade() async throws {
        let fixture = try await TranslatorFixture.make(primary: false)
        defer { fixture.remove() }
        let source = try await fixture.source()
        let article = try await fixture.article("Gone", in: source)
        try await fixture.library.storeTranslations([
            TranslationRecord(articleID: article, locale: .english, state: .none, title: nil, excerpt: nil, failure: nil, model: nil),
        ])
        try await fixture.library.deleteSource(source)
        #expect(try await fixture.translationCount() == 0)
    }

    @Test("criterion 12: list rows and the open article carry the translation of the locale asked for, and only it")
    func rowsCarryTranslations() async throws {
        let fixture = try await TranslatorFixture.make(primary: false)
        defer { fixture.remove() }
        let source = try await fixture.source()
        let translated = try await fixture.article("Translated", excerpt: "Its excerpt", in: source)
        let waiting = try await fixture.article("Waiting", in: source)
        try await fixture.library.storeTranslations([
            TranslationRecord(articleID: translated, locale: .simplifiedChinese, state: .done, title: "已译", excerpt: "摘要", failure: nil, model: "m"),
            TranslationRecord(articleID: translated, locale: .japanese, state: .done, title: "翻訳済み", excerpt: nil, failure: nil, model: "m"),
        ])
        let rows = try await fixture.library.articleRows(.library, filter: .all, translationsIn: .simplifiedChinese)
        #expect(rows.map(\.id) == [waiting, translated])
        #expect(rows[0].translation == nil)
        #expect(rows[1].translation == StoredTranslation(state: .done, title: "已译", excerpt: "摘要", failure: nil))
        #expect(rows[1].title == "Translated", "the original stays")
        let japanese = try await fixture.library.articleRows(.category(fixture.category), filter: .unread, translationsIn: .japanese)
        #expect(japanese.first { $0.id == translated }?.translation?.title == "翻訳済み")
        let english = try await fixture.library.articleRows(.source(source), filter: .all, translationsIn: .english)
        #expect(english.allSatisfy { $0.translation == nil })
        let none = try await fixture.library.articleRows(.library, filter: .all)
        #expect(none.allSatisfy { $0.translation == nil }, "without a locale nothing is joined")
        #expect(try await fixture.library.article(translated, translationsIn: .simplifiedChinese).translation?.title == "已译")
        #expect(try await fixture.library.article(translated).translation == nil)
        // Pages still continue each other with the join.
        let first = try await fixture.library.articleRows(.library, filter: .all, limit: 1, translationsIn: .simplifiedChinese)
        let second = try await fixture.library.articleRows(
            .library, filter: .all, after: first.last?.position, limit: 1, translationsIn: .simplifiedChinese
        )
        #expect(first.map(\.id) + second.map(\.id) == [waiting, translated])
        #expect(second.first?.translation?.title == "已译")
    }

    @Test("the joined page query still walks the order index, and the join uses the translation key")
    func joinedQueryPlan() async throws {
        let fixture = try await TranslatorFixture.make(primary: false)
        defer { fixture.remove() }
        var conditions: [String] = []
        var arguments: [(any DatabaseValueConvertible)?] = ["zh-Hans"]
        Library.appendListConditions(.library, filter: .unread, to: &conditions, arguments: &arguments)
        let sql = "EXPLAIN QUERY PLAN " + Library.articleRowsSQL(where: conditions, joiningTranslations: true)
        let planArguments = StatementArguments(arguments + [200])
        let plan = try await fixture.library.pool.read { db in
            try Row.fetchAll(db, sql: sql, arguments: planArguments).map { $0["detail"] as String }
        }
        #expect(plan.contains { $0.contains("article_order") }, "\(plan)")
        #expect(plan.contains { $0.contains("translation") && $0.contains("PRIMARY KEY") || $0.contains("sqlite_autoindex_translation") }, "\(plan)")
        #expect(!plan.contains { $0.contains("TEMP B-TREE") }, "\(plan)")
    }

    // MARK: - Criterion 6: a slot change deletes the failed rows

    @Test("criterion 6: saving a slot, removing its key or removing it deletes the failed rows, and only them")
    func slotChangeDeletesFailed() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let source = try await fixture.source()
        let failed = try await fixture.article("Failed", in: source)
        let done = try await fixture.article("Done", in: source)
        func fail() async throws {
            try await fixture.library.storeTranslations([
                TranslationRecord(articleID: failed, locale: .simplifiedChinese, state: .failed, title: nil, excerpt: nil, failure: .refused, model: nil),
                TranslationRecord(articleID: failed, locale: .japanese, state: .failed, title: nil, excerpt: nil, failure: .count, model: nil),
                TranslationRecord(articleID: done, locale: .simplifiedChinese, state: .done, title: "完成", excerpt: nil, failure: nil, model: "m"),
            ])
            #expect(try await fixture.translationCount() == 3)
        }
        try await fail()
        try await fixture.saveSlot(.primary, host: "other.example.invalid")
        #expect(try await fixture.translationCount() == 1)
        #expect(try await fixture.translation(done)?.state == .done)

        try await fail()
        try await fixture.saveSlot(.backup)
        #expect(try await fixture.translationCount() == 1, "saving the backup")

        try await fail()
        try await fixture.models.removeKey(.backup)
        #expect(try await fixture.translationCount() == 1, "removing a key")

        try await fail()
        try await fixture.models.removeSlot(.backup)
        #expect(try await fixture.translationCount() == 1, "removing a slot")

        try await fail()
        try await fixture.models.removeSlot(.backup)
        #expect(try await fixture.translationCount() == 3, "removing a slot that is not there changes nothing")
    }

    // MARK: - Decision 8

    @Test("the daily limit is 200 when absent, stored in setting, and the count reads automatic rows of the day")
    func dailyLimitAndCount() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        #expect(try await fixture.library.dailyAutomaticLimit() == 200)
        try await fixture.library.setDailyAutomaticLimit(3)
        #expect(try await fixture.library.dailyAutomaticLimit() == 3)
        try await fixture.library.pool.write { db in
            try db.execute(sql: "UPDATE setting SET value = 'many' WHERE key = 'daily_automatic_limit'")
        }
        #expect(try await fixture.library.dailyAutomaticLimit() == 200, "a stored value that is not a number reads as the standard")

        _ = try await fixture.models.send(texts: ["a"], instructions: "i", purpose: .titles, role: .primary, automatic: true)
        _ = try await fixture.models.send(texts: ["a"], instructions: "i", purpose: .titles, role: .primary)
        fixture.service.answer { _, _, _ in .status(503) }
        _ = await thrown { try await fixture.models.send(texts: ["a"], instructions: "i", purpose: .titles, role: .primary, automatic: true) }
        let usage = try await fixture.usage()
        #expect(usage.map(\.automatic).sorted { !$0 && $1 } == [false, true, true])
        let start = fixture.clock.now()
        #expect(try await fixture.library.automaticRequestCount(since: start) == 2, "failed requests count")
        #expect(try await fixture.library.automaticRequestCount(since: start.addingTimeInterval(1)) == 0)
    }
}
