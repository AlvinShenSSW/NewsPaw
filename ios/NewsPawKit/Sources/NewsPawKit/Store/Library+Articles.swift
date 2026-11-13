import Foundation
import GRDB

/// Article lists, read state and stars (spec N05; RD09). Every operation
/// works on this library alone. No query here selects `content_html`; a
/// state change writes one column and nothing else.
extension Library {
    /// The rows a list page holds at most, unless the caller asks for fewer.
    public static let articlePageSize = 200

    /// One page of `scope`'s articles under `filter`, in the list order
    /// (RD09 decision 2): newest first by the time the row shows, then by
    /// first-seen time, then by the table's row order, all descending.
    /// Articles of paused sources are included.
    ///
    /// - Parameters:
    ///   - cursor: the position of the last row of the previous page, or
    ///     `nil` for the first page. The page starts strictly after it, so
    ///     pages never repeat or skip a row.
    ///   - limit: the most rows returned.
    public func articleRows(
        _ scope: ArticleScope, filter: ArticleFilter, after cursor: ArticlePosition? = nil, limit: Int = articlePageSize
    ) async throws -> [ArticleRow] {
        var conditions: [String] = []
        var arguments: [(any DatabaseValueConvertible)?] = []
        Self.appendListConditions(scope, filter: filter, to: &conditions, arguments: &arguments)
        if let cursor {
            conditions.append("(\(Self.shownAtSQL), article.first_seen_at, article.rowid) < (?, ?, ?)")
            arguments += [cursor.shownAt, cursor.firstSeenAt, cursor.rowID]
        }
        arguments.append(max(0, limit))
        let sql = Self.articleRowsSQL(where: conditions)
        let finalArguments = StatementArguments(arguments)
        return try await read { db in
            try Row.fetchAll(db, sql: sql, arguments: finalArguments).map(Self.articleRow)
        }
    }

    /// The article `id` as its row, for the reading screen.
    ///
    /// - Throws: `unknownArticle` when the library holds no such article.
    public func article(_ id: UUID) async throws -> ArticleRow {
        let sql = """
            SELECT \(Self.articleRowColumns)
            FROM article JOIN source ON source.id = article.source_id
            WHERE article.id = ?
            """
        return try await read { db in
            guard let row = try Row.fetchOne(db, sql: sql, arguments: [id.databaseKey]) else {
                throw LibraryError.unknownArticle
            }
            return try Self.articleRow(row)
        }
    }

    /// Marks the article read or unread. Marking a read article read keeps
    /// its read time, so a repeated call changes nothing. Writes `read_at`
    /// of that article only.
    ///
    /// - Throws: `unknownArticle`.
    public func setRead(_ id: UUID, _ read: Bool) async throws {
        try await setTime(of: "read_at", id, read)
    }

    /// Stars or unstars the article. Starring a starred article keeps its
    /// starred time. Writes `starred_at` of that article only.
    ///
    /// - Throws: `unknownArticle`.
    public func setStarred(_ id: UUID, _ starred: Bool) async throws {
        try await setTime(of: "starred_at", id, starred)
    }

    /// The unread articles of `scope` first seen at or before `moment`: the
    /// number "Mark All as Read" names (decision 7).
    public func unreadCount(in scope: ArticleScope, firstSeenThrough moment: Date) async throws -> Int {
        var conditions = ["article.read_at IS NULL", "article.first_seen_at <= ?"]
        var arguments: [(any DatabaseValueConvertible)?] = [moment]
        Self.appendScopeCondition(scope, to: &conditions, arguments: &arguments)
        let sql = "SELECT COUNT(*) FROM article WHERE " + conditions.joined(separator: " AND ")
        let finalArguments = StatementArguments(arguments)
        return try await read { db in
            try Int.fetchOne(db, sql: sql, arguments: finalArguments) ?? 0
        }
    }

    /// Marks read, in one transaction, every unread article of `scope` first
    /// seen at or before `moment` — also those no list has loaded — and
    /// nothing else; an article first seen later stays unread. Writes
    /// `read_at` only.
    ///
    /// - Returns: the number of articles marked.
    @discardableResult
    public func markAllRead(in scope: ArticleScope, firstSeenThrough moment: Date) async throws -> Int {
        var conditions = ["article.read_at IS NULL", "article.first_seen_at <= ?"]
        var arguments: [(any DatabaseValueConvertible)?] = [now(), moment]
        Self.appendScopeCondition(scope, to: &conditions, arguments: &arguments)
        let sql = "UPDATE article SET read_at = ? WHERE " + conditions.joined(separator: " AND ")
        let finalArguments = StatementArguments(arguments)
        return try await write { db in
            try db.execute(sql: sql, arguments: finalArguments)
            return db.changesCount
        }
    }

    // MARK: - SQL

    /// The time a row shows. The same expression as the `article_order`
    /// index's first column, so that the index serves the order.
    static let shownAtSQL = "COALESCE(article.published_at, article.first_seen_at)"

    /// The list order of decision 2.
    static let articleOrderSQL = "\(shownAtSQL) DESC, article.first_seen_at DESC, article.rowid DESC"

    /// What a row reads: never `content_html`.
    static let articleRowColumns = """
        article.rowid AS row_id, article.id, article.source_id, source.name AS source_name,
        article.title, article.excerpt, article.author, article.url, article.image_url,
        \(shownAtSQL) AS shown_at, article.first_seen_at,
        article.read_at IS NOT NULL AS is_read, article.starred_at IS NOT NULL AS is_starred
        """

    /// A page query; its last argument is the limit.
    static func articleRowsSQL(where conditions: [String]) -> String {
        let filter = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ") + "\n"
        return """
            SELECT \(articleRowColumns)
            FROM article JOIN source ON source.id = article.source_id
            \(filter)ORDER BY \(articleOrderSQL)
            LIMIT ?
            """
    }

    static func appendListConditions(
        _ scope: ArticleScope, filter: ArticleFilter, to conditions: inout [String], arguments: inout [(any DatabaseValueConvertible)?]
    ) {
        appendScopeCondition(scope, to: &conditions, arguments: &arguments)
        if filter == .unread {
            conditions.append("article.read_at IS NULL")
        }
    }

    /// The condition on `article` that selects `scope`.
    static func appendScopeCondition(
        _ scope: ArticleScope, to conditions: inout [String], arguments: inout [(any DatabaseValueConvertible)?]
    ) {
        switch scope {
        case .library:
            break
        case .category(let id):
            conditions.append("article.source_id IN (SELECT id FROM source WHERE category_id = ?)")
            arguments.append(id.databaseKey)
        case .source(let id):
            conditions.append("article.source_id = ?")
            arguments.append(id.databaseKey)
        case .starred:
            conditions.append("article.starred_at IS NOT NULL")
        }
    }

    static func articleRow(_ row: Row) throws -> ArticleRow {
        let idText: String = row["id"]
        let sourceText: String = row["source_id"]
        guard let id = UUID(uuidString: idText), let sourceID = UUID(uuidString: sourceText) else {
            throw LibraryError.storage("Not an identifier: \(idText), \(sourceText)")
        }
        let shownText: String = row["shown_at"]
        let firstSeenText: String = row["first_seen_at"]
        guard let shownAt = Date.fromDatabaseValue(shownText.databaseValue),
              let firstSeenAt = Date.fromDatabaseValue(firstSeenText.databaseValue)
        else {
            throw LibraryError.storage("Not a time: \(shownText), \(firstSeenText)")
        }
        return ArticleRow(
            id: id, sourceID: sourceID, sourceName: row["source_name"], title: row["title"], excerpt: row["excerpt"],
            author: row["author"], link: row["url"], imageAddress: row["image_url"], shownAt: shownAt,
            firstSeenAt: firstSeenAt, isRead: row["is_read"], isStarred: row["is_starred"],
            position: ArticlePosition(shownAt: shownText, firstSeenAt: firstSeenText, rowID: row["row_id"])
        )
    }

    /// Sets or clears one time column of one article, keeping a time that is
    /// already set.
    private func setTime(of column: String, _ id: UUID, _ on: Bool) async throws {
        let now = now()
        let sql = on
            ? "UPDATE article SET \(column) = COALESCE(\(column), ?) WHERE id = ?"
            : "UPDATE article SET \(column) = NULL WHERE id = ?"
        let arguments: StatementArguments = on ? [now, id.databaseKey] : [id.databaseKey]
        try await write { db in
            try db.execute(sql: sql, arguments: arguments)
            // SQLite counts a matched row as changed even when its value
            // stays the same, so zero means no such article.
            if db.changesCount == 0 {
                throw LibraryError.unknownArticle
            }
        }
    }
}
