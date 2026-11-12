import Foundation
import GRDB

/// What a collection needs to know about its source before fetching.
struct CollectionTarget: Sendable, Hashable {
    var sourceID: UUID
    var url: String
    var etag: String?
    var lastModified: String?
}

/// Storing a collection (spec N04). One collection touches one source's
/// articles, that source's `seen` rows and its four status columns — `etag`,
/// `last_modified`, `last_success_at`, `last_error` — and nothing the owner
/// can edit.
extension Library {
    /// The feed source `id`, or `nil` when there is none or it is another
    /// kind. Columns are read one by one so that a kind this build does not
    /// know is "not a feed", not a decoding error.
    func collectionTarget(_ id: UUID) async throws -> CollectionTarget? {
        try await read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT kind, url, etag, last_modified FROM source WHERE id = ?", arguments: [id.databaseKey]
            ), (row["kind"] as String?) == SourceKind.feed.rawValue
            else { return nil }
            return CollectionTarget(sourceID: id, url: row["url"], etag: row["etag"], lastModified: row["last_modified"])
        }
    }

    /// Stores the result of fetching `target` in one write transaction.
    ///
    /// The source is read again inside the transaction: when it was deleted,
    /// or its address or kind changed, while the fetch was in flight, nothing
    /// is written. Its category is the one it has now.
    ///
    /// - Parameter now: the moment of collection. It stamps `first_seen_at`
    ///   of every new article and `last_success_at`, and a published time
    ///   later than it is not stored.
    func storeCollection(_ result: FetchResult, for target: CollectionTarget, at now: Date) async throws -> CollectionOutcome {
        let sourceKey = target.sourceID.databaseKey
        return try await write { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT category_id, kind, url FROM source WHERE id = ?", arguments: [sourceKey]
            ), (row["kind"] as String?) == SourceKind.feed.rawValue, (row["url"] as String?) == target.url
            else { return .nothingDone }
            let categoryKey: String = row["category_id"]

            switch result {
            case .notModified:
                try db.execute(
                    sql: "UPDATE source SET last_success_at = ?, last_error = NULL WHERE id = ?",
                    arguments: [now, sourceKey]
                )
                return .notModified
            case .feed(let fetched):
                let inserted = try Self.insertArticles(
                    fetched.feed.items, sourceKey: sourceKey, categoryKey: categoryKey, now: now, in: db
                )
                try db.execute(
                    sql: "UPDATE source SET etag = ?, last_modified = ?, last_success_at = ?, last_error = NULL WHERE id = ?",
                    arguments: [fetched.validators.etag, fetched.validators.lastModified, now, sourceKey]
                )
                if fetched.feed.isComplete {
                    // After the listed items have refreshed their rows, so a
                    // feed that still lists an item keeps it.
                    try db.execute(
                        sql: "DELETE FROM seen WHERE source_id = ? AND last_seen_at < ?",
                        arguments: [sourceKey, now.addingTimeInterval(-Self.seenLifetime)]
                    )
                }
                return .collected(newArticles: inserted, complete: fetched.feed.isComplete)
            case .notAFeed, .failed:
                let failure = result.failure ?? .unreachable
                try db.execute(sql: "UPDATE source SET last_error = ? WHERE id = ?", arguments: [failure.code, sourceKey])
                return .failed(failure)
            }
        }
    }

    /// The feed HTML stored with an article, read by its identifier; list
    /// queries never carry it.
    func contentHTML(ofArticle id: UUID) async throws -> String? {
        try await read { db in
            try String.fetchOne(db, sql: "SELECT content_html FROM article WHERE id = ?", arguments: [id.databaseKey])
        }
    }

    /// Whether an article of a category holds a link; arguments: the link,
    /// the category. It uses the index on `article(url)`.
    static let linkHeldSQL = """
        SELECT EXISTS (
            SELECT 1 FROM article JOIN source ON source.id = article.source_id
            WHERE article.url = ? AND source.category_id = ?
        )
        """

    /// Decides each listed item in feed order (RD06 decision 8), then
    /// inserts the survivors in reverse feed order, so that the table's row
    /// order follows the feed's age. Returns the number of new articles.
    ///
    /// 1. An identifier that is already an article of this source: nothing
    ///    to do. (An identifier repeated within the feed counts as decided
    ///    by its first occurrence.)
    /// 2. An identifier in `seen` for this source: the row's last-seen time
    ///    becomes `now` and its link joins the batch's links; not inserted.
    /// 3. A link that is one of the batch's links, or that an article of the
    ///    category holds: not inserted, and the identifier is put into
    ///    `seen` with `now`, so that it does not come back as new once the
    ///    article holding the link is cleaned up.
    /// 4. Otherwise inserted; its link joins the batch's links.
    ///
    /// Items without links are never duplicates of each other. Called inside
    /// the caller's transaction: the collection's, or the one that adds a
    /// feed source with its first articles (RD05).
    static func insertArticles(
        _ items: [ParsedItem], sourceKey: String, categoryKey: String, now: Date, in db: Database
    ) throws -> Int {
        let isArticle = try db.makeStatement(sql: """
            SELECT EXISTS (SELECT 1 FROM article WHERE source_id = ? AND external_id = ?)
            """)
        let refreshSeen = try db.makeStatement(sql: """
            UPDATE seen SET last_seen_at = ? WHERE source_id = ? AND external_id_hash = ?
            """)
        let linkHeld = try db.makeStatement(sql: linkHeldSQL)
        let remember = try db.makeStatement(sql: """
            INSERT INTO seen (source_id, external_id_hash, last_seen_at) VALUES (?, ?, ?)
            ON CONFLICT (source_id, external_id_hash) DO UPDATE SET last_seen_at = excluded.last_seen_at
            """)
        var decided = Set<String>()
        var linksInBatch = Set<String>()
        var survivors: [ParsedItem] = []
        for item in items {
            guard decided.insert(item.externalID).inserted else { continue }
            // 1. Already an article of this source.
            if try Bool.fetchOne(isArticle, arguments: [sourceKey, item.externalID]) == true {
                continue
            }
            // 2. Remembered for this source.
            let hash = seenHash(item.externalID)
            try refreshSeen.execute(arguments: [now, sourceKey, hash])
            if db.changesCount > 0 {
                if let link = item.url {
                    linksInBatch.insert(link)
                }
                continue
            }
            // 3. The same link as an earlier item or an article of the
            //    category.
            if let link = item.url {
                let held = try linksInBatch.contains(link) || Bool.fetchOne(linkHeld, arguments: [link, categoryKey]) == true
                if held {
                    try remember.execute(arguments: [sourceKey, hash, now])
                    continue
                }
                linksInBatch.insert(link)
            }
            // 4. New.
            survivors.append(item)
        }

        // Not the record's own insert: the list record does not carry the
        // content, and an ignore policy would also swallow other constraint
        // failures. Only an existing identity is skipped.
        let insert = try db.makeStatement(sql: """
            INSERT INTO article (
                id, source_id, external_id, url, title, excerpt, author, image_url,
                published_at, first_seen_at, content_html
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (source_id, external_id) DO NOTHING
            """)
        var inserted = 0
        for item in survivors.reversed() {
            let published = item.publishedAt.flatMap { $0 <= now ? $0 : nil }
            try insert.execute(arguments: [
                UUID().databaseKey, sourceKey, item.externalID, item.url, item.title, item.excerpt, item.author,
                item.imageURL, published, now, item.contentHTML,
            ])
            inserted += db.changesCount
        }
        return inserted
    }

    /// How long a `seen` row is kept after its feed last listed the item
    /// (spec N04): fixed, and independent of the retention setting.
    static let seenLifetime: TimeInterval = 30 * 24 * 60 * 60

    /// The form in which an external identifier is kept in `seen`: the
    /// lowercase hexadecimal SHA-256 of its UTF-8 bytes.
    static func seenHash(_ externalID: String) -> String {
        sha256Hex(externalID)
    }
}
