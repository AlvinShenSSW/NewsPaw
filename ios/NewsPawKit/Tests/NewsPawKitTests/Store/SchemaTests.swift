import Foundation
import GRDB
@testable import NewsPawKit
import Testing

@Suite("Schema")
struct SchemaTests {
    /// One column as `PRAGMA table_info` reports it.
    struct ColumnInfo: Equatable, CustomStringConvertible {
        var name: String
        var type: String
        var notNull: Bool
        var defaultValue: String?
        var primaryKeyIndex: Int

        init(_ name: String, _ type: String, notNull: Bool, default defaultValue: String? = nil, pk primaryKeyIndex: Int = 0) {
            self.name = name
            self.type = type
            self.notNull = notNull
            self.defaultValue = defaultValue
            self.primaryKeyIndex = primaryKeyIndex
        }

        var description: String {
            "\(name) \(type)\(notNull ? " NOT NULL" : "")\(defaultValue.map { " DEFAULT \($0)" } ?? "")\(primaryKeyIndex > 0 ? " PK\(primaryKeyIndex)" : "")"
        }
    }

    /// One foreign key as `PRAGMA foreign_key_list` reports it.
    struct ForeignKeyInfo: Equatable {
        var column: String
        var table: String
        var destination: String
        var onDelete: String
    }

    static let expectedColumns: [String: [ColumnInfo]] = [
        "category": [
            ColumnInfo("id", "TEXT", notNull: true, pk: 1),
            ColumnInfo("name", "TEXT", notNull: true),
            ColumnInfo("sort_order", "INTEGER", notNull: true),
            ColumnInfo("icon", "TEXT", notNull: true),
            ColumnInfo("overview", "TEXT", notNull: true, default: "'auto'"),
            ColumnInfo("updated_at", "TEXT", notNull: true),
        ],
        "source": [
            ColumnInfo("id", "TEXT", notNull: true, pk: 1),
            ColumnInfo("category_id", "TEXT", notNull: true),
            ColumnInfo("kind", "TEXT", notNull: true),
            ColumnInfo("url", "TEXT", notNull: true),
            ColumnInfo("name", "TEXT", notNull: true),
            ColumnInfo("site_url", "TEXT", notNull: false),
            ColumnInfo("paused", "INTEGER", notNull: true, default: "0"),
            ColumnInfo("auto_translate", "TEXT", notNull: true, default: "'inherit'"),
            ColumnInfo("body_mode", "TEXT", notNull: true, default: "'auto'"),
            ColumnInfo("translate_page", "INTEGER", notNull: true, default: "0"),
            ColumnInfo("etag", "TEXT", notNull: false),
            ColumnInfo("last_modified", "TEXT", notNull: false),
            ColumnInfo("last_success_at", "TEXT", notNull: false),
            ColumnInfo("last_error", "TEXT", notNull: false),
            ColumnInfo("updated_at", "TEXT", notNull: true),
        ],
        "article": [
            ColumnInfo("id", "TEXT", notNull: true, pk: 1),
            ColumnInfo("source_id", "TEXT", notNull: true),
            ColumnInfo("external_id", "TEXT", notNull: true),
            ColumnInfo("url", "TEXT", notNull: false),
            ColumnInfo("title", "TEXT", notNull: false),
            ColumnInfo("excerpt", "TEXT", notNull: false),
            ColumnInfo("author", "TEXT", notNull: false),
            ColumnInfo("image_url", "TEXT", notNull: false),
            ColumnInfo("published_at", "TEXT", notNull: false),
            ColumnInfo("first_seen_at", "TEXT", notNull: true),
            ColumnInfo("language", "TEXT", notNull: false),
            ColumnInfo("read_at", "TEXT", notNull: false),
            ColumnInfo("starred_at", "TEXT", notNull: false),
        ],
        "article_body": [
            ColumnInfo("article_id", "TEXT", notNull: true, pk: 1),
            ColumnInfo("origin", "TEXT", notNull: true),
            ColumnInfo("blocks", "TEXT", notNull: true),
            ColumnInfo("fetched_at", "TEXT", notNull: true),
        ],
        "seen": [
            ColumnInfo("source_id", "TEXT", notNull: true, pk: 1),
            ColumnInfo("external_id_hash", "TEXT", notNull: true, pk: 2),
            ColumnInfo("last_seen_at", "TEXT", notNull: true),
        ],
    ]

    static let expectedForeignKeys: [String: [ForeignKeyInfo]] = [
        "category": [],
        "source": [ForeignKeyInfo(column: "category_id", table: "category", destination: "id", onDelete: "RESTRICT")],
        "article": [ForeignKeyInfo(column: "source_id", table: "source", destination: "id", onDelete: "CASCADE")],
        "article_body": [ForeignKeyInfo(column: "article_id", table: "article", destination: "id", onDelete: "CASCADE")],
        "seen": [ForeignKeyInfo(column: "source_id", table: "source", destination: "id", onDelete: "CASCADE")],
    ]

    /// The columns of each unique constraint or primary key, by table.
    static let expectedUniqueKeys: [String: Set<[String]>] = [
        "category": [["id"]],
        "source": [["id"], ["url"]],
        "article": [["id"], ["source_id", "external_id"]],
        "article_body": [["article_id"]],
        "seen": [["source_id", "external_id_hash"]],
    ]

    // MARK: - Criterion 2: the first migration

    @Test("v1 creates the five tables with their columns, nullability and defaults")
    func version1Columns() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Up to v1 only: what v1 froze must not drift when later migrations
        // are added.
        let library = try await LibraryStore(directory: directory)
            .open(.normal, migrator: migrator(addingTestMigrations: []), create: true)

        let (tables, columns, foreignKeys, uniqueKeys) = try await library.pool.read { db in
            let tables = try String.fetchSet(
                db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
            )
            var columns: [String: [ColumnInfo]] = [:]
            var foreignKeys: [String: [ForeignKeyInfo]] = [:]
            var uniqueKeys: [String: Set<[String]>] = [:]
            for table in Self.expectedColumns.keys {
                columns[table] = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { row in
                    ColumnInfo(row["name"], row["type"], notNull: row["notnull"], default: row["dflt_value"], pk: row["pk"])
                }
                foreignKeys[table] = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table))").map { row in
                    ForeignKeyInfo(column: row["from"], table: row["table"], destination: row["to"], onDelete: row["on_delete"])
                }
                var keys: Set<[String]> = []
                for index in try Row.fetchAll(db, sql: "PRAGMA index_list(\(table))") where (index["unique"] as Int) == 1 {
                    let name: String = index["name"]
                    keys.insert(try Row.fetchAll(db, sql: "PRAGMA index_info(\(name))").map { $0["name"] })
                }
                // A rowid table's INTEGER PRIMARY KEY has no index; none is used here.
                uniqueKeys[table] = keys
            }
            return (tables, columns, foreignKeys, uniqueKeys)
        }

        #expect(tables == ["category", "source", "article", "article_body", "seen", "grdb_migrations"])
        for table in Self.expectedColumns.keys.sorted() {
            #expect(columns[table] == Self.expectedColumns[table], "columns of \(table)")
            #expect(foreignKeys[table] == Self.expectedForeignKeys[table], "foreign keys of \(table)")
            #expect(uniqueKeys[table] == Self.expectedUniqueKeys[table], "unique keys of \(table)")
        }
        let partitionColumns = columns.values.joined().filter { $0.name.contains("partition") }
        #expect(partitionColumns.isEmpty)
    }

    @Test("defaults fill the omitted columns and NOT NULL is enforced")
    func version1DefaultsAndNotNull() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try await LibraryStore(directory: directory).openNormal()

        let values = try await library.pool.write { db in
            try db.execute(sql: """
                INSERT INTO category (id, name, sort_order, icon, updated_at)
                    VALUES ('c', 'World', 0, 'globe', '2027-01-01 00:00:00.000');
                INSERT INTO source (id, category_id, kind, url, name, updated_at)
                    VALUES ('s', 'c', 'feed', 'https://example.com/feed', 'Feed', '2027-01-01 00:00:00.000');
                """)
            return try Row.fetchOne(db, sql: """
                SELECT category.overview, source.paused, source.auto_translate, source.body_mode, source.translate_page
                FROM source JOIN category ON category.id = source.category_id
                """).map { Array($0.databaseValues) }
        }
        #expect(values == ["auto".databaseValue, 0.databaseValue, "inherit".databaseValue, "auto".databaseValue, 0.databaseValue])

        await #expect(throws: DatabaseError.self) {
            try await library.pool.write { db in
                try db.execute(sql: "INSERT INTO category (id, name, sort_order, icon, updated_at) VALUES ('d', NULL, 1, 'globe', 'x')")
            }
        }
        await #expect(throws: DatabaseError.self) {
            try await library.pool.write { db in
                try db.execute(sql: "INSERT INTO article (id, source_id, external_id) VALUES ('a', 's', 'e')")
            }
        }
    }

    @Test("foreign keys are enforced on the writer and on readers")
    func foreignKeysEnforced() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let library = try await LibraryStore(directory: directory, now: clock.now).openNormal()
        let category = try await library.createCategory(name: "World", icon: .globe)
        let sources = try await Sample.fill(library, category: category.id, prefix: "fk", at: clock.now())

        #expect(try await library.pool.read { db in try Bool.fetchOne(db, sql: "PRAGMA foreign_keys") } == true)
        #expect(try await library.pool.write { db in try Bool.fetchOne(db, sql: "PRAGMA foreign_keys") } == true)

        // A source must name an existing category.
        let orphan = Sample.source(in: UUID(), url: "https://orphan.example.com/feed", at: clock.now())
        await #expect(throws: LibraryError.self) { try await library.insert(orphan) }
        // A category that still holds sources cannot be deleted directly.
        await #expect(throws: DatabaseError.self) {
            try await library.pool.write { db in
                try db.execute(sql: "DELETE FROM category WHERE id = ?", arguments: [category.id.databaseKey])
            }
        }
        // Deleting a source takes its articles, bodies and seen identifiers.
        try await library.pool.write { db in
            try db.execute(sql: "DELETE FROM source WHERE id = ?", arguments: [sources[0].id.databaseKey])
        }
        #expect(try await rowCounts(library) == ["category": 1, "source": 1, "article": 2, "article_body": 2, "seen": 1])
    }

    // MARK: - RD04 criterion 16: migration v2

    @Test("v2 adds a nullable content_html column to article and an index on the article's link")
    func version2() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try await LibraryStore(directory: directory).openNormal()

        let (migrations, columns, indexes) = try await library.pool.read { db in
            let migrations = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(article)").map { row in
                ColumnInfo(row["name"], row["type"], notNull: row["notnull"], default: row["dflt_value"], pk: row["pk"])
            }
            var indexes: [String: [String]] = [:]
            for index in try Row.fetchAll(db, sql: "PRAGMA index_list(article)") where (index["origin"] as String) == "c" {
                let name: String = index["name"]
                indexes[name] = try Row.fetchAll(db, sql: "PRAGMA index_info(\(name))").map { $0["name"] }
            }
            return (migrations, columns, indexes)
        }
        #expect(migrations == ["v1", "v2"])
        #expect(columns == Self.expectedColumns["article"]! + [ColumnInfo("content_html", "TEXT", notNull: false)])
        #expect(indexes == ["article_url": ["url"]])
    }

    @Test("the version-1 fixture migrates to v2 with its rows intact")
    func fixtureMigratesToVersion2() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "normal.sqlite")
        try restoreVersion1Fixture(to: url)
        let before = try await DatabaseQueue(path: url.path).read { try DatabaseSnapshot.read($0) }

        let library = try await LibraryStore(directory: directory).openNormal()

        let after = try await library.pool.read { try DatabaseSnapshot.read($0) }
        #expect(after.appliedMigrations == ["v1", "v2"])
        for table in ["category", "source", "article_body", "seen"] {
            #expect(after.rows[table] == before.rows[table], "rows of \(table)")
        }
        // Each article keeps every value and gains an empty content column.
        #expect(after.rows["article"] == before.rows["article"]?.map { $0 + [nil] })
        #expect(after.integrity == ["ok"])
        #expect(try await library.articles().count == 3)
        #expect(try await library.sources().count == 3)
    }

    @Test("the same-link query of collection uses the index on the article's link")
    func sameLinkQueryUsesIndex() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try await LibraryStore(directory: directory).openNormal()
        let plan = try await library.pool.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + Library.linkHeldSQL, arguments: ["https://example.invalid/x", "c"])
                .map { $0["detail"] as String }
        }
        #expect(plan.contains { $0.contains("article_url") }, "\(plan)")
    }

    @Test("list queries do not carry content_html; it is read by article identifier")
    func listRecordLeavesContentOut() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try await LibraryStore(directory: directory).openNormal()
        let columns = try await library.pool.read { db in
            try Article.all().makePreparedRequest(db, forSingleResult: false).statement.columnNames
        }
        #expect(columns == Self.expectedColumns["article"]!.map(\.name))
        #expect(!columns.contains("content_html"))
    }

    // MARK: - Criterion 3: the version-1 fixture

    @Test("the version-1 fixture has the schema that migrating up to v1 produces")
    func fixtureSchemaMatchesVersion1() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtureURL = directory.appending(path: "fixture.sqlite")
        try restoreVersion1Fixture(to: fixtureURL)
        let migratedQueue = try DatabaseQueue(path: directory.appending(path: "migrated.sqlite").path)
        try Schema.migrator.migrate(migratedQueue, upTo: "v1")
        let fixtureQueue = try DatabaseQueue(path: fixtureURL.path)

        let migrated = try await migratedQueue.read { try DatabaseSnapshot.read($0) }
        let fixture = try await fixtureQueue.read { try DatabaseSnapshot.read($0) }

        #expect(fixture.appliedMigrations == ["v1"])
        #expect(fixture.schema == migrated.schema)
        #expect(fixture.integrity == ["ok"])
        #expect(fixture.rows["category"]?.isEmpty == false)
        #expect(fixture.rows["source"]?.isEmpty == false)
        #expect(fixture.rows["article"]?.isEmpty == false)
        #expect(fixture.rows["article_body"]?.isEmpty == false)
        #expect(fixture.rows["seen"]?.isEmpty == false)
    }

    @Test("a database written by v1 opens with a later migration applied and its rows intact")
    func fixtureOpensWithLaterMigration() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try restoreVersion1Fixture(to: directory.appending(path: "normal.sqlite"))
        let before = try await DatabaseQueue(path: directory.appending(path: "normal.sqlite").path).read {
            try DatabaseSnapshot.read($0)
        }
        let store = LibraryStore(directory: directory)

        let library = try await store.open(.normal, migrator: migrator(addingTestMigrations: ["test_later"]), create: true)

        let after = try await library.pool.read { try DatabaseSnapshot.read($0) }
        #expect(after.appliedMigrations == ["test_later", "v1"])
        #expect(after.rows["test_later"] == [["test_later ran"]])
        for table in ["category", "source", "article", "article_body", "seen"] {
            #expect(after.rows[table] == before.rows[table], "rows of \(table)")
        }
        #expect(after.integrity == ["ok"])
        // The records read the old rows through the library.
        #expect(try await library.categories().map(\.name) == ["World", "Tech"])
        #expect(try await library.sources().count == 3)
        #expect(try await library.articles().count == 3)
    }

    // MARK: - Criterion 4: refusing a newer database

    @Test("a database with a migration the app does not know is refused and left logically unchanged")
    func newerSchemaRefusedUnchanged() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Built the way production builds it, through a pool, by a "newer" build.
        let before = try await buildDatabase(in: directory, migrator: migrator(addingTestMigrations: ["test_a"]))
        #expect(before.appliedMigrations == ["test_a", "v1"])

        // A build that knows v1 and a different later migration refuses it.
        try await expectRefusal(in: directory, migrator: migrator(addingTestMigrations: ["test_b"]))
        // So does the production migrator.
        try await expectRefusal(in: directory, migrator: Schema.migrator)

        let after = try await snapshot(in: directory, migrator: migrator(addingTestMigrations: ["test_a"]))
        #expect(after == before)
        #expect(!after.appliedMigrations.contains("test_b"))
        #expect(after.rows["test_b"] == nil)
        #expect(after.integrity == ["ok"])
    }

    @Test("the version-1 fixture after a later migration is refused by the app's migrator and left logically unchanged")
    func upgradedFixtureRefusedByProductionMigrator() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try restoreVersion1Fixture(to: directory.appending(path: "normal.sqlite"))
        let newer = migrator(addingTestMigrations: ["test_later"])
        let before = try await snapshot(in: directory, migrator: newer)

        let store = LibraryStore(directory: directory)
        await #expect(throws: LibraryError.newerSchema) { try await store.openNormal() }

        let after = try await snapshot(in: directory, migrator: newer)
        #expect(after == before)
    }

    /// Creates the database through a store with `migrator`, fills it, and
    /// returns its state; the store is released when this returns.
    private func buildDatabase(in directory: URL, migrator: DatabaseMigrator) async throws -> DatabaseSnapshot {
        let clock = TestClock()
        let store = LibraryStore(directory: directory, now: clock.now)
        let library = try await store.open(.normal, migrator: migrator, create: true)
        let world = try await library.createCategory(name: "World", icon: .globe)
        _ = try await library.createCategory(name: "Tech", icon: .cpu)
        try await Sample.fill(library, category: world.id, prefix: "newer", at: clock.now())
        return try await library.pool.read { try DatabaseSnapshot.read($0) }
    }

    /// Opens through a store with `migrator` and returns the state; the store
    /// is released when this returns.
    private func snapshot(in directory: URL, migrator: DatabaseMigrator) async throws -> DatabaseSnapshot {
        let store = LibraryStore(directory: directory)
        let library = try await store.open(.normal, migrator: migrator, create: false)
        return try await library.pool.read { try DatabaseSnapshot.read($0) }
    }

    private func expectRefusal(in directory: URL, migrator: DatabaseMigrator) async throws {
        let store = LibraryStore(directory: directory)
        await #expect(throws: LibraryError.newerSchema) {
            try await store.open(.normal, migrator: migrator, create: true)
        }
    }

    // MARK: - Criterion 4: damaged files

    @Test("a file that is not a database is refused as damaged and left byte for byte")
    func notADatabaseRefused() async throws {
        var content = Data("This is a note, not a NewsPaw library.\n".utf8)
        content.append(Data(repeating: 0x41, count: 8192))
        try await expectDamagedAndUnchanged(content)
    }

    @Test("a truncated database is refused as damaged and left byte for byte")
    func truncatedDatabaseRefused() async throws {
        let source = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: source) }
        try await fillLargeLibrary(in: source)
        let full = try Data(contentsOf: source.appending(path: "normal.sqlite"))
        #expect(full.count > 64 * 1024)

        try await expectDamagedAndUnchanged(full.prefix(full.count / 2))
    }

    /// A library with enough categories to span many pages; its store is
    /// released (and the file checkpointed) when this returns.
    private func fillLargeLibrary(in directory: URL) async throws {
        let library = try await LibraryStore(directory: directory).openNormal()
        try await library.pool.write { db in
            for index in 0..<400 {
                try Category(
                    id: UUID(), name: String(repeating: "n", count: 90) + "\(index)", sortOrder: index,
                    iconName: "folder", overview: .auto, updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
                ).insert(db)
            }
        }
    }

    private func expectDamagedAndUnchanged(_ content: Data) async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "normal.sqlite")
        try content.write(to: url)
        let store = LibraryStore(directory: directory)

        await #expect(throws: LibraryError.damaged) { try await store.openNormal() }

        #expect(try Data(contentsOf: url) == content)
    }
}
