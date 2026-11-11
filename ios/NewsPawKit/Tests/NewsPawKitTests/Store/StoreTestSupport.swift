import Foundation
import GRDB
@testable import NewsPawKit
import Synchronization
import Testing

/// A clock the tests move by hand. Times are whole seconds so that they
/// survive the database's millisecond text form unchanged.
final class TestClock: Sendable {
    private let current = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

    func now() -> Date {
        current.withLock { $0 }
    }

    func advance(seconds: Int = 60) {
        current.withLock { $0 = $0.addingTimeInterval(TimeInterval(seconds)) }
    }
}

/// A migrator holding `v1` and then the given test-only migrations, each
/// creating a table named after it so that a test can see it ran.
func migrator(addingTestMigrations names: [String]) -> DatabaseMigrator {
    var migrator = DatabaseMigrator()
    Schema.registerV1(in: &migrator)
    for name in names {
        migrator.registerMigration(name) { db in
            try db.execute(sql: "CREATE TABLE \(name) (note TEXT)")
            try db.execute(sql: "INSERT INTO \(name) (note) VALUES ('\(name) ran')")
        }
    }
    return migrator
}

/// Restores `Fixtures/library-v1.sql` into a new file at `url` on a
/// throwaway connection, outside any transaction (the script carries its own
/// `BEGIN` / `COMMIT`), and closes that connection before returning.
func restoreVersion1Fixture(to url: URL) throws {
    let script = try Fixture.text("library-v1", "sql")
    let queue = try DatabaseQueue(path: url.path)
    try queue.writeWithoutTransaction { db in try db.execute(sql: script) }
    try queue.close()
}

/// What a database holds, compared logically rather than byte by byte:
/// applied migrations, schema text, every row of every table, and SQLite's
/// integrity check.
struct DatabaseSnapshot: Equatable {
    var appliedMigrations: [String]
    var schema: [[String?]]
    var rows: [String: [[String?]]]
    var integrity: [String]

    static func read(_ db: Database) throws -> DatabaseSnapshot {
        let schema = try Row.fetchAll(db, sql: "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name")
            .map { row in (0..<row.count).map { row[$0] as String? } }
        let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        var rows: [String: [[String?]]] = [:]
        for table in tables {
            rows[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table)")
                .map { row in row.databaseValues.map(render) }
                .sorted { $0.map { $0 ?? "" }.lexicographicallyPrecedes($1.map { $0 ?? "" }) }
        }
        return DatabaseSnapshot(
            appliedMigrations: try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier"),
            schema: schema,
            rows: rows,
            integrity: try String.fetchAll(db, sql: "PRAGMA integrity_check")
        )
    }

    /// Text as itself; other storage classes named, so that a value stored
    /// with another type does not compare equal.
    private static func render(_ value: DatabaseValue) -> String? {
        switch value.storage {
        case .null: nil
        case .int64(let integer): "integer \(integer)"
        case .double(let real): "real \(real)"
        case .string(let text): text
        case .blob(let data): "blob \(data.base64EncodedString())"
        }
    }
}

/// The columns that hold identifiers; every value must be lowercase text.
let identifierColumns: [(table: String, column: String)] = [
    ("category", "id"),
    ("source", "id"),
    ("source", "category_id"),
    ("article", "id"),
    ("article", "source_id"),
    ("article_body", "article_id"),
    ("seen", "source_id"),
]

/// Fails the test for each identifier that is not stored as lowercase text.
func expectIdentifiersAreLowercaseText(_ library: Library, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let offenders = try await library.pool.read { db in
        try identifierColumns.map { table, column in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(table) WHERE NOT (typeof(\(column)) = 'text' AND \(column) = lower(\(column)))"
            ) ?? -1
            return "\(table).\(column): \(count)"
        }
        .filter { !$0.hasSuffix(": 0") }
    }
    #expect(offenders.isEmpty, "identifiers not stored as lowercase text: \(offenders)", sourceLocation: sourceLocation)
}

/// Synthetic records for one library.
enum Sample {
    static func source(in categoryID: UUID, url: String, name: String = "Sample source", at date: Date) -> Source {
        Source(
            id: UUID(), categoryID: categoryID, kind: .feed, url: url, name: name,
            siteURL: nil, paused: false, autoTranslate: .inherit, bodyMode: .auto, translatePage: false,
            etag: nil, lastModified: nil, lastSuccessAt: nil, lastError: nil, updatedAt: date
        )
    }

    static func article(in sourceID: UUID, externalID: String, title: String, at date: Date) -> Article {
        Article(
            id: UUID(), sourceID: sourceID, externalID: externalID, url: "https://example.com/\(externalID)",
            title: title, excerpt: nil, author: nil, imageURL: nil, publishedAt: date, firstSeenAt: date,
            language: "en", readAt: nil, starredAt: nil
        )
    }

    static func body(of articleID: UUID, at date: Date) -> ArticleBody {
        ArticleBody(articleID: articleID, origin: .feed, blocks: #"[{"type":"paragraph","text":"Sample"}]"#, fetchedAt: date)
    }

    /// Fills a category with two sources, each with two articles, a body for
    /// each article, and one seen identifier. Returns the sources.
    @discardableResult
    static func fill(_ library: Library, category: UUID, prefix: String, at date: Date) async throws -> [Source] {
        var sources: [Source] = []
        for index in 0..<2 {
            let source = source(in: category, url: "https://\(prefix).example.com/feed\(index)", name: "\(prefix) source \(index)", at: date)
            try await library.insert(source)
            for item in 0..<2 {
                let article = article(in: source.id, externalID: "\(prefix)-\(index)-\(item)", title: "\(prefix) article \(index)-\(item)", at: date)
                try await library.insert(article)
                try await library.insert(body(of: article.id, at: date))
            }
            try await library.insertSeen(sourceID: source.id, externalIDHash: "\(prefix)-hash-\(index)", lastSeenAt: date)
            sources.append(source)
        }
        return sources
    }
}

/// Row counts per table of one library.
func rowCounts(_ library: Library) async throws -> [String: Int] {
    try await library.pool.read { db in
        var counts: [String: Int] = [:]
        for table in ["category", "source", "article", "article_body", "seen"] {
            counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
        }
        return counts
    }
}
