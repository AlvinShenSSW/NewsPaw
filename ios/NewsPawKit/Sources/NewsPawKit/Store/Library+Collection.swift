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
/// articles and that source's four status columns — `etag`,
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

    /// Decides duplicates in feed order — an item whose link an article of
    /// the category already holds, or an earlier item of the batch, is
    /// dropped; items without a link are never duplicates of each other —
    /// then inserts the survivors in reverse feed order, so that the table's
    /// row order follows the feed's age. Returns the number of new articles.
    /// Called inside the caller's transaction: the collection's, or the one
    /// that adds a feed source with its first articles (RD05).
    static func insertArticles(
        _ items: [ParsedItem], sourceKey: String, categoryKey: String, now: Date, in db: Database
    ) throws -> Int {
        let linkHeld = try db.makeStatement(sql: linkHeldSQL)
        var linksInBatch = Set<String>()
        var survivors: [ParsedItem] = []
        for item in items {
            if let link = item.url {
                guard linksInBatch.insert(link).inserted else { continue }
                if try Bool.fetchOne(linkHeld, arguments: [link, categoryKey]) == true { continue }
            }
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
}
