import Foundation
import GRDB
@testable import NewsPawKit
import Testing

/// A library with categories, sources and articles written row by row, and
/// a model of each article from which the tests compute what a list must
/// show (RD09).
final class ArticleFixture: @unchecked Sendable {
    struct Stored {
        var id: UUID
        var sourceID: UUID
        var categoryID: UUID
        var title: String
        var publishedAt: Date?
        var firstSeenAt: Date
        var read: Bool
        var starred: Bool
        /// Insertion order: the table's row order.
        var sequence: Int

        var shownAt: Date { publishedAt ?? firstSeenAt }
    }

    let directory: URL
    let clock: TestClock
    let library: Library
    private(set) var stored: [Stored] = []
    private var categoryOfSource: [UUID: UUID] = [:]

    private init(directory: URL, clock: TestClock, library: Library) {
        self.directory = directory
        self.clock = clock
        self.library = library
    }

    static func make() async throws -> ArticleFixture {
        let directory = try makeTemporaryDirectory()
        let clock = TestClock()
        let library = try await LibraryStore(directory: directory, cacheRoot: directory.appending(path: "Images"), now: clock.now)
            .openNormal()
        return ArticleFixture(directory: directory, clock: clock, library: library)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    func category(_ name: String) async throws -> UUID {
        try await library.createCategory(name: name, icon: .folder).id
    }

    func source(_ name: String, in category: UUID, paused: Bool = false) async throws -> UUID {
        var source = Sample.source(in: category, url: "https://\(name.lowercased()).example.invalid/feed", name: name, at: clock.now())
        source.paused = paused
        try await library.insert(source)
        categoryOfSource[source.id] = category
        return source.id
    }

    /// Writes one article with feed HTML in `content_html`.
    @discardableResult
    func article(
        _ title: String, in source: UUID, published: Date?, firstSeen: Date, read: Bool = false, starred: Bool = false
    ) async throws -> UUID {
        let id = UUID()
        let readAt: Date? = read ? firstSeen : nil
        let starredAt: Date? = starred ? firstSeen : nil
        try await library.pool.write { db in
            try db.execute(sql: """
                INSERT INTO article (id, source_id, external_id, url, title, excerpt, author, image_url,
                                     published_at, first_seen_at, read_at, starred_at, content_html)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    id.databaseKey, source.databaseKey, "ext-\(id.databaseKey)", "https://example.invalid/\(id.databaseKey)",
                    title, "Excerpt of \(title)", "Author", nil, published, firstSeen, readAt, starredAt,
                    "<p>Stored HTML of \(title)</p>",
                ])
        }
        stored.append(Stored(
            id: id, sourceID: source, categoryID: categoryOfSource[source] ?? UUID(), title: title, publishedAt: published,
            firstSeenAt: firstSeen, read: read, starred: starred, sequence: stored.count
        ))
        return id
    }

    /// A moment `seconds` after the clock's start.
    func at(_ seconds: Int) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000 + TimeInterval(seconds))
    }

    /// What `scope` under `filter` must show, in the list order.
    func expected(_ scope: ArticleScope, _ filter: ArticleFilter) -> [UUID] {
        stored
            .filter { article in
                let inScope = switch scope {
                case .library: true
                case .category(let id): article.categoryID == id
                case .source(let id): article.sourceID == id
                case .starred: article.starred
                }
                return inScope && (filter == .all || !article.read)
            }
            .sorted { first, second in
                if first.shownAt != second.shownAt { return first.shownAt > second.shownAt }
                if first.firstSeenAt != second.firstSeenAt { return first.firstSeenAt > second.firstSeenAt }
                return first.sequence > second.sequence
            }
            .map(\.id)
    }

    /// Every page of `scope` under `filter`, read with `limit` rows each.
    func allPages(_ scope: ArticleScope, _ filter: ArticleFilter, limit: Int) async throws -> [[ArticleRow]] {
        var pages: [[ArticleRow]] = []
        var cursor: ArticlePosition?
        while true {
            let page = try await library.articleRows(scope, filter: filter, after: cursor, limit: limit)
            if page.isEmpty { break }
            pages.append(page)
            cursor = page.last?.position
            if page.count < limit { break }
        }
        return pages
    }

    /// Every value of every article row, for comparing what a change wrote.
    func articleTable() async throws -> [String: [String: String?]] {
        try await library.pool.read { db in
            var table: [String: [String: String?]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM article") {
                var values: [String: String?] = [:]
                for column in row.columnNames {
                    let value = row[column] as DatabaseValue
                    values[column] = value.isNull ? nil : value.description
                }
                table[row["id"] as String] = values
            }
            return table
        }
    }
}

/// The columns of `before` and `after` that differ, as "article id.column".
func changedColumns(_ before: [String: [String: String?]], _ after: [String: [String: String?]]) -> Set<String> {
    var changed = Set<String>()
    for (id, values) in after {
        guard let old = before[id] else {
            changed.insert("\(id).*")
            continue
        }
        for (column, value) in values where old[column] != value {
            changed.insert("\(id).\(column)")
        }
    }
    for id in before.keys where after[id] == nil {
        changed.insert("\(id).*")
    }
    return changed
}
