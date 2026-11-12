import Foundation
import GRDB

/// Source management (spec N02, N03; RD05). Every operation works on this
/// library alone, checks and writes inside one transaction, and writes only
/// the columns it changes, so a collection in flight and an edit never
/// overwrite each other.
extension Library {
    /// The longest source name accepted, in characters.
    public static let maximumSourceNameLength = 200

    /// The rule every source name must meet: trimmed of surrounding white
    /// space, 1 to `maximumSourceNameLength` characters. Returns `nil` when
    /// `name` is accepted.
    public static func sourceNameProblem(_ name: String) -> CategoryNameProblem? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .empty
        }
        if trimmed.count > maximumSourceNameLength {
            return .tooLong
        }
        return nil
    }

    /// The feeds Add source suggests: the list for the normal library, none
    /// for any other, so no interface can show them in the adult partition.
    public var suggestedSources: [SuggestedSource] {
        partition == .normal ? SuggestedSources.all : []
    }

    /// The source stored at `address` (a normal form), with its category's
    /// name, for the duplicate message.
    public func existingSource(atAddress address: String) async throws -> ExistingSource? {
        try await read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT source.id AS id, source.name AS name, category.id AS category_id, category.name AS category_name
                FROM source JOIN category ON category.id = source.category_id
                WHERE source.url = ?
                """, arguments: [address])
            else { return nil }
            return ExistingSource(
                sourceID: try Self.uuid(row["id"]), name: row["name"],
                categoryID: try Self.uuid(row["category_id"]), categoryName: row["category_name"]
            )
        }
    }

    /// Adds a feed source with the articles, validators and success time of
    /// the fetch that detected it, in one transaction and under one clock
    /// reading; no request is made.
    ///
    /// - Returns: the new source's identifier.
    /// - Throws: `unknownCategory`, `duplicateAddress`, `emptyName`,
    ///   `nameTooLong`, `invalidAddress`. Nothing is written when it throws.
    @discardableResult
    public func addFeedSource(_ candidate: FeedCandidate, name: String, categoryID: UUID) async throws -> UUID {
        let address = try Self.normalAddress(candidate.address)
        let name = try Self.validatedSourceName(name)
        let fetched = candidate.fetched
        let now = now()
        let source = Source(
            id: UUID(), categoryID: categoryID, kind: .feed, url: address, name: name, siteURL: candidate.siteURL,
            paused: false, autoTranslate: .inherit, bodyMode: .auto, translatePage: false,
            etag: fetched.validators.etag, lastModified: fetched.validators.lastModified,
            lastSuccessAt: now, lastError: nil, updatedAt: now
        )
        try await write { db in
            try Self.insertNew(source, in: db)
            _ = try Self.insertArticles(
                fetched.feed.items, sourceKey: source.id.databaseKey, categoryKey: categoryID.databaseKey, now: now, in: db
            )
        }
        return source.id
    }

    /// Adds a web-page source. The address is normalised here.
    ///
    /// - Returns: the new source's identifier.
    /// - Throws: `invalidAddress`, `unknownCategory`, `duplicateAddress`,
    ///   `emptyName`, `nameTooLong`.
    @discardableResult
    public func addWebPageSource(address: String, name: String, categoryID: UUID) async throws -> UUID {
        let address = try Self.normalAddress(address)
        let name = try Self.validatedSourceName(name)
        let now = now()
        let source = Source(
            id: UUID(), categoryID: categoryID, kind: .webpage, url: address, name: name, siteURL: nil,
            paused: false, autoTranslate: .inherit, bodyMode: .auto, translatePage: false,
            etag: nil, lastModified: nil, lastSuccessAt: nil, lastError: nil, updatedAt: now
        )
        try await write { db in try Self.insertNew(source, in: db) }
        return source.id
    }

    /// Every source with its counts, newest item time and status, read in
    /// one transaction, ordered by name (localised, case ignored), then
    /// identifier. Article content is not read.
    public func sourceSummaries() async throws -> [SourceSummary] {
        let summaries = try await read { db in
            try Row.fetchAll(db, sql: """
                SELECT source.id, source.category_id, source.kind, source.url, source.name, source.site_url,
                       source.paused, source.auto_translate, source.body_mode, source.translate_page,
                       source.last_success_at, source.last_error,
                       COUNT(article.id) AS article_count,
                       COUNT(article.id) - COUNT(article.read_at) AS unread_count,
                       MAX(COALESCE(article.published_at, article.first_seen_at)) AS newest
                FROM source LEFT JOIN article ON article.source_id = source.id
                GROUP BY source.id
                """).map { row -> SourceSummary in
                let kind = SourceKind(rawValue: row["kind"]) ?? .feed
                let paused: Bool = row["paused"]
                let lastError: String? = row["last_error"]
                let lastSuccess: Date? = row["last_success_at"]
                return SourceSummary(
                    id: try Self.uuid(row["id"]), categoryID: try Self.uuid(row["category_id"]), kind: kind,
                    address: row["url"], name: row["name"], siteURL: row["site_url"], paused: paused,
                    autoTranslate: AutoTranslate(rawValue: row["auto_translate"]) ?? .inherit,
                    bodyMode: BodyMode(rawValue: row["body_mode"]) ?? .auto,
                    translatePage: row["translate_page"],
                    unreadCount: row["unread_count"], articleCount: row["article_count"], newestItemAt: row["newest"],
                    lastSuccessAt: lastSuccess,
                    status: SourceStatus(kind: kind, paused: paused, lastError: lastError, lastSuccessAt: lastSuccess)
                )
            }
        }
        // SQLite's NOCASE folds ASCII only.
        return summaries.sorted { first, second in
            switch first.name.localizedCaseInsensitiveCompare(second.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: first.id.databaseKey < second.id.databaseKey
            }
        }
    }

    /// Changes what the owner can change. Writes only the columns whose
    /// value differs, and `updated_at` when one does; never a status column.
    ///
    /// - Throws: `unknownSource`; `unknownCategory`; `emptyName`,
    ///   `nameTooLong`; `optionNotApplicable` for an option of the other
    ///   kind. Nothing changes when it throws.
    public func updateSource(_ id: UUID, _ changes: SourceChanges) async throws {
        let name = try changes.name.map(Self.validatedSourceName)
        let key = id.databaseKey
        let now = now()
        try await write { db in
            guard let source = try Source.fetchOne(db, key: key) else {
                throw LibraryError.unknownSource
            }
            if source.kind == .webpage {
                if changes.paused != nil || changes.autoTranslate != nil || changes.bodyMode != nil {
                    throw LibraryError.optionNotApplicable
                }
            } else if changes.translatePage != nil {
                throw LibraryError.optionNotApplicable
            }

            var assignments: [String] = []
            var arguments: [(any DatabaseValueConvertible)?] = []
            func set(_ column: String, _ value: (any DatabaseValueConvertible)?) {
                assignments.append("\(column) = ?")
                arguments.append(value)
            }
            if let name, name != source.name {
                set("name", name)
            }
            if let category = changes.categoryID, category != source.categoryID {
                let exists = try Bool.fetchOne(
                    db, sql: "SELECT EXISTS (SELECT 1 FROM category WHERE id = ?)", arguments: [category.databaseKey]
                ) ?? false
                guard exists else { throw LibraryError.unknownCategory }
                set("category_id", category.databaseKey)
            }
            if let paused = changes.paused, paused != source.paused {
                set("paused", paused)
            }
            if let autoTranslate = changes.autoTranslate, autoTranslate != source.autoTranslate {
                set("auto_translate", autoTranslate.rawValue)
            }
            if let bodyMode = changes.bodyMode, bodyMode != source.bodyMode {
                set("body_mode", bodyMode.rawValue)
            }
            if let translatePage = changes.translatePage, translatePage != source.translatePage {
                set("translate_page", translatePage)
            }
            guard !assignments.isEmpty else { return }
            set("updated_at", now)
            arguments.append(key)
            try db.execute(
                sql: "UPDATE source SET \(assignments.joined(separator: ", ")) WHERE id = ?",
                arguments: StatementArguments(arguments)
            )
        }
    }

    /// Deletes a source with its articles, their bodies and its seen
    /// identifiers.
    ///
    /// - Throws: `unknownSource`.
    public func deleteSource(_ id: UUID) async throws {
        try await write { db in
            // Articles, bodies and seen identifiers follow through the
            // foreign keys' cascades.
            try db.execute(sql: "DELETE FROM source WHERE id = ?", arguments: [id.databaseKey])
            if db.changesCount == 0 {
                throw LibraryError.unknownSource
            }
        }
    }

    // MARK: - Helpers

    /// Inserts a new source after checking its category. The address's
    /// unique constraint is the duplicate check that counts.
    private static func insertNew(_ source: Source, in db: Database) throws {
        let exists = try Bool.fetchOne(
            db, sql: "SELECT EXISTS (SELECT 1 FROM category WHERE id = ?)", arguments: [source.categoryID.databaseKey]
        ) ?? false
        guard exists else { throw LibraryError.unknownCategory }
        do {
            try source.insert(db)
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            throw LibraryError.duplicateAddress
        }
    }

    private static func normalAddress(_ address: String) throws -> String {
        switch SourceAddress.parse(address) {
        case .success(let parsed): parsed.normalForm
        case .failure(let problem): throw LibraryError.invalidAddress(problem)
        }
    }

    private static func validatedSourceName(_ name: String) throws -> String {
        switch sourceNameProblem(name) {
        case .empty: throw LibraryError.emptyName
        case .tooLong: throw LibraryError.nameTooLong
        case nil: return name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func uuid(_ text: String) throws -> UUID {
        guard let id = UUID(uuidString: text) else { throw LibraryError.storage("Not an identifier: \(text)") }
        return id
    }
}
