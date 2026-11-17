import Foundation
import GRDB

/// What identifies a slot for the overview writer (RD23 decision 11 (f)):
/// its role, address, model and key reference — not its Test outcome or
/// its `updated_at`.
struct SlotIdentity: Sendable, Hashable {
    let role: ModelRole
    let baseURL: String
    let model: String
    let keyRef: String?

    init(_ slot: ModelSlot) {
        role = slot.role
        baseURL = slot.baseURL
        model = slot.model
        keyRef = slot.keyRef
    }
}

/// What one overview job reads, in one read transaction (decision 9 (a)).
struct OverviewJobRead: Sendable, Hashable {
    /// The job's day, fixed here: its row is stored under it.
    let day: String
    /// Where that day started: the daily limit counts from it.
    let dayStart: Date
    /// The category's mode; `nil` when the category no longer exists.
    let mode: OverviewMode?
    /// Whether the category has a row that day, in any locale.
    let hasRowThatDay: Bool
    /// Whether it has an article first seen since that day's start.
    let hasArticleFirstSeenThatDay: Bool
    /// The articles to send, at most `OverviewPrompt.maximumArticles`, in
    /// list order.
    let input: [OverviewArticle]
}

/// One overview row to write (decision 9 (f)).
struct OverviewRecord: Sendable, Hashable {
    let categoryID: UUID
    let day: String
    let locale: ReadingLocale
    let state: OverviewState
    let text: String?
    let highlights: [OverviewHighlight]
    let articleCount: Int
    let coveredUntil: Date?
    let model: String?
    let failure: TranslationFailure?
}

/// How a store ended (decision 11 (f)).
enum OverviewStoreResult: Sendable, Hashable {
    case stored
    /// The category, or an article that was sent, no longer exists in the
    /// category: nothing stored.
    case gone
    /// A failed row whose slots changed since the job read them: nothing
    /// stored (superseded).
    case slotsChanged
    /// A failed row meeting a `done` row of the same day and locale:
    /// nothing stored.
    case doneKept
}

/// The overview rows and the queries of the overview writer of one library
/// (spec N07, section 4; RD23 decisions 1–4, 7, 9, 11 and 15). Every query
/// works on this library alone.
extension Library {
    /// How far back the input reaches when the category has no earlier
    /// `done` overview in the locale (decision 2 of the spec review).
    static let overviewFallbackWindow: TimeInterval = 86_400

    // MARK: - The writer's reads

    /// The slots as the writer compares them.
    func slotIdentities() async throws -> [ModelRole: SlotIdentity] {
        try await read { db in try Self.slotIdentities(db) }
    }

    static func slotIdentities(_ db: Database) throws -> [ModelRole: SlotIdentity] {
        let slots = try ModelSlot.fetchAll(db)
        return Dictionary(slots.map { ($0.role, SlotIdentity($0)) }, uniquingKeysWith: { first, _ in first })
    }

    /// The categories due for an automatic overview (gap 1), in the owner's
    /// order: mode `auto`, no row on `day` in any locale, and an article
    /// first seen at or after `dayStart`.
    func overviewDueCategories(day: String, dayStart: Date) async throws -> [UUID] {
        try await read { db in
            let rows = try String.fetchAll(db, sql: """
                SELECT category.id FROM category
                WHERE category.overview = ?
                    AND NOT EXISTS (SELECT 1 FROM overview WHERE overview.category_id = category.id AND overview.day = ?)
                    AND EXISTS (
                        SELECT 1 FROM article JOIN source ON source.id = article.source_id
                        WHERE source.category_id = category.id AND article.first_seen_at >= ?
                    )
                ORDER BY category.sort_order, category.id
                """, arguments: [OverviewMode.auto.rawValue, day, dayStart])
            return try rows.map(Self.overviewIdentifier)
        }
    }

    /// Decision 9 (a): the job's day, the category's mode, whether it has a
    /// row that day, whether an article was first seen that day, and the
    /// input in `locale` (decision 2 of the spec review), read together.
    func overviewJobRead(category: UUID, locale: ReadingLocale, now: Date, calendar: Calendar) async throws -> OverviewJobRead {
        let day = OverviewDay.key(for: now, calendar: calendar)
        let dayStart = OverviewDay.start(of: now, calendar: calendar)
        return try await read { db in
            let key = category.databaseKey
            guard let modeText = try String.fetchOne(db, sql: "SELECT overview FROM category WHERE id = ?", arguments: [key]) else {
                return OverviewJobRead(day: day, dayStart: dayStart, mode: nil, hasRowThatDay: false, hasArticleFirstSeenThatDay: false, input: [])
            }
            let hasRow = try Bool.fetchOne(
                db, sql: "SELECT EXISTS (SELECT 1 FROM overview WHERE category_id = ? AND day = ?)", arguments: [key, day]
            ) ?? false
            let firstSeenToday = try Bool.fetchOne(db, sql: """
                SELECT EXISTS (
                    SELECT 1 FROM article JOIN source ON source.id = article.source_id
                    WHERE source.category_id = ? AND article.first_seen_at >= ?
                )
                """, arguments: [key, dayStart]) ?? false
            var input: [OverviewArticle] = []
            try Self.forEachOverviewInput(db, category: key, locale: locale, day: day, now: now) { article in
                guard OverviewPrompt.sends(article) else { return true }
                input.append(article)
                return input.count < OverviewPrompt.maximumArticles
            }
            return OverviewJobRead(
                day: day, dayStart: dayStart, mode: OverviewMode(rawValue: modeText), hasRowThatDay: hasRow, hasArticleFirstSeenThatDay: firstSeenToday,
                input: input
            )
        }
    }

    /// How many articles an overview of each category would be written
    /// from now in `locale`: the writer's input without its limit of 40
    /// (decision 12, the write state's count).
    public func overviewInputCounts(locale: ReadingLocale, now: Date, calendar: Calendar) async throws -> [UUID: Int] {
        let day = OverviewDay.key(for: now, calendar: calendar)
        return try await read { db in
            var counts: [UUID: Int] = [:]
            for key in try String.fetchAll(db, sql: "SELECT id FROM category ORDER BY sort_order, id") {
                var count = 0
                try Self.forEachOverviewInput(db, category: key, locale: locale, day: day, now: now) { article in
                    if OverviewPrompt.sends(article) {
                        count += 1
                    }
                    return true
                }
                counts[try Self.overviewIdentifier(key)] = count
            }
            return counts
        }
    }

    /// Walks the category's input articles in list order (RD09's order):
    /// those first seen after the `covered_until` of the newest `done`
    /// overview of an earlier day in `locale`, else those first seen in the
    /// 24 hours before `now`. `body` returns whether to go on.
    private static func forEachOverviewInput(
        _ db: Database, category key: String, locale: ReadingLocale, day: String, now: Date, _ body: (OverviewArticle) throws -> Bool
    ) throws {
        let anchor = try String.fetchOne(db, sql: """
            SELECT covered_until FROM overview
            WHERE category_id = ? AND locale = ? AND state = ? AND day < ? AND covered_until IS NOT NULL
            ORDER BY day DESC LIMIT 1
            """, arguments: [key, locale.rawValue, OverviewState.done.rawValue, day])
        let condition: String
        let bound: any DatabaseValueConvertible
        if let anchor {
            condition = "article.first_seen_at > ?"
            bound = anchor
        } else {
            condition = "article.first_seen_at >= ?"
            bound = now.addingTimeInterval(-overviewFallbackWindow)
        }
        let rows = try Row.fetchCursor(db, sql: """
            SELECT article.id, article.title, article.excerpt, article.first_seen_at
            FROM article JOIN source ON source.id = article.source_id
            WHERE source.category_id = ? AND \(condition)
            ORDER BY \(articleOrderSQL)
            """, arguments: [key, bound])
        while let row = try rows.next() {
            let firstSeenText: String = row["first_seen_at"]
            guard let firstSeenAt = Date.fromDatabaseValue(firstSeenText.databaseValue) else {
                throw LibraryError.storage("Not a time: \(firstSeenText)")
            }
            let article = OverviewArticle(
                id: try overviewIdentifier(row["id"]), title: row["title"], excerpt: row["excerpt"], firstSeenAt: firstSeenAt
            )
            guard try body(article) else { return }
        }
    }

    // MARK: - Storing (decision 11 (f))

    /// Writes `record` in one transaction, only when the category exists
    /// and every article of `sent` still exists in it; a `failed` record
    /// only when the slots read now equal `slots` on role, address, model
    /// and key reference, and never over a `done` row of the same day and
    /// locale. A `done` record replaces the row of its day and locale.
    func storeOverview(_ record: OverviewRecord, sent: [UUID], slots: [ModelRole: SlotIdentity]) async throws -> OverviewStoreResult {
        let now = now()
        let highlights = Self.highlightsJSON(record.highlights)
        return try await write { db in
            let key = record.categoryID.databaseKey
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM category WHERE id = ?)", arguments: [key]) ?? false else {
                return .gone
            }
            if !sent.isEmpty {
                let marks = Array(repeating: "?", count: sent.count).joined(separator: ", ")
                let present = try Int.fetchOne(
                    db, sql: """
                        SELECT COUNT(*) FROM article JOIN source ON source.id = article.source_id
                        WHERE source.category_id = ? AND article.id IN (\(marks))
                        """,
                    arguments: StatementArguments([key] + sent.map(\.databaseKey))
                ) ?? 0
                guard present == Set(sent).count else { return .gone }
            }
            if record.state == .failed, try Self.slotIdentities(db) != slots {
                return .slotsChanged
            }
            // A failed row replaces only a failed row: a done row is kept.
            let conflictGuard = record.state == .failed ? "WHERE overview.state = '\(OverviewState.failed.rawValue)'" : ""
            try db.execute(
                sql: """
                    INSERT INTO overview (
                        id, category_id, day, locale, text, highlights, article_count, covered_until, model, state, error, created_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (category_id, day, locale) DO UPDATE SET
                        text = excluded.text, highlights = excluded.highlights, article_count = excluded.article_count,
                        covered_until = excluded.covered_until, model = excluded.model, state = excluded.state,
                        error = excluded.error, created_at = excluded.created_at
                        \(conflictGuard)
                    """,
                arguments: [
                    UUID().databaseKey, key, record.day, record.locale.rawValue, record.text, highlights, record.articleCount,
                    record.coveredUntil, record.model, record.state.rawValue, record.failure?.rawValue, now,
                ]
            )
            return db.changesCount > 0 ? .stored : .doneKept
        }
    }

    private static func highlightsJSON(_ highlights: [OverviewHighlight]) -> String {
        let array = highlights.map { ["article_id": $0.articleID.databaseKey, "text": $0.text] }
        let data = (try? JSONSerialization.data(withJSONObject: array, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Reading for the screens (decision 12)

    /// Each category's row of `day` in `locale`, by category.
    public func overviews(on day: String, locale: ReadingLocale) async throws -> [UUID: StoredOverview] {
        try await read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT * FROM overview WHERE day = ? AND locale = ?", arguments: [day, locale.rawValue]
            )
            var result: [UUID: StoredOverview] = [:]
            for row in rows {
                if let overview = try Self.storedOverview(row, db) {
                    result[overview.categoryID] = overview
                }
            }
            return result
        }
    }

    /// The category's `done` rows in `locale` with a day from `oldest` up
    /// to but not including `today`, newest first: Earlier Overviews.
    public func earlierOverviews(of category: UUID, locale: ReadingLocale, from oldest: String, before today: String) async throws
        -> [StoredOverview] {
        try await read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM overview
                WHERE category_id = ? AND locale = ? AND state = ? AND day >= ? AND day < ?
                ORDER BY day DESC
                """, arguments: [category.databaseKey, locale.rawValue, OverviewState.done.rawValue, oldest, today])
            return try rows.compactMap { try Self.storedOverview($0, db) }
        }
    }

    /// A row as the screens read it, its highlights limited to the articles
    /// that still exist in its category; `nil` for a locale or state this
    /// build does not know.
    private static func storedOverview(_ row: Row, _ db: Database) throws -> StoredOverview? {
        guard let locale = ReadingLocale(rawValue: row["locale"]), let state = OverviewState(rawValue: row["state"]) else { return nil }
        let categoryKey: String = row["category_id"]
        let createdText: String = row["created_at"]
        guard let createdAt = Date.fromDatabaseValue(createdText.databaseValue) else {
            throw LibraryError.storage("Not a time: \(createdText)")
        }
        var highlights: [OverviewHighlight] = []
        if state == .done {
            let stored = decodeHighlights(row["highlights"])
            if !stored.isEmpty {
                let marks = Array(repeating: "?", count: stored.count).joined(separator: ", ")
                let present = try String.fetchSet(
                    db, sql: """
                        SELECT article.id FROM article JOIN source ON source.id = article.source_id
                        WHERE source.category_id = ? AND article.id IN (\(marks))
                        """,
                    arguments: StatementArguments([categoryKey] + stored.map(\.articleID.databaseKey))
                )
                highlights = stored.filter { present.contains($0.articleID.databaseKey) }
            }
        }
        return StoredOverview(
            id: try overviewIdentifier(row["id"]), categoryID: try overviewIdentifier(categoryKey), day: row["day"], locale: locale,
            state: state, text: state == .done ? row["text"] : nil, highlights: highlights, articleCount: row["article_count"],
            model: row["model"], failure: state == .failed ? (row["error"] as String?).flatMap(TranslationFailure.init(rawValue:)) ?? .malformed : nil,
            createdAt: createdAt
        )
    }

    /// The stored highlights; an entry that is not an identifier and a text
    /// is skipped.
    private static func decodeHighlights(_ text: String?) -> [OverviewHighlight] {
        guard let text, let array = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [Any] else { return [] }
        return array.compactMap { element in
            guard let entry = element as? [String: Any], let id = (entry["article_id"] as? String).flatMap(UUID.init(uuidString:)),
                  let text = entry["text"] as? String
            else { return nil }
            return OverviewHighlight(articleID: id, text: text)
        }
    }

    // MARK: - Clean-up (decision 15)

    /// Deletes every overview row with a day before `oldest`, whatever the
    /// article retention ("forever" included).
    ///
    /// - Returns: the number of rows deleted.
    @discardableResult
    public func cleanUpOverviews(before oldest: String) async throws -> Int {
        try await write { db in
            try db.execute(sql: "DELETE FROM overview WHERE day < ?", arguments: [oldest])
            return db.changesCount
        }
    }

    private static func overviewIdentifier(_ text: String) throws -> UUID {
        guard let id = UUID(uuidString: text) else { throw LibraryError.storage("Not an identifier: \(text)") }
        return id
    }
}
