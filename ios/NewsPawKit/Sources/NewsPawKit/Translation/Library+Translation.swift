import Foundation
import GRDB

/// One translation row to write (RD14 decision 2).
struct TranslationRecord: Sendable, Hashable {
    let articleID: UUID
    let locale: ReadingLocale
    let state: TranslationState
    let title: String?
    let excerpt: String?
    let failure: TranslationFailure?
    /// The model's name; `nil` when no model was called.
    let model: String?
}

/// What the translator reads of an article to judge it.
struct TranslationInput: Sendable, Hashable {
    let id: UUID
    let title: String?
    let excerpt: String?
    /// The source's setting.
    let autoTranslate: AutoTranslate
    /// Whether the article has a row for the locale asked about: it is not
    /// waiting.
    let hasTranslation: Bool
}

/// The translation rows, the pass's candidates and the daily automatic
/// limit of one library (spec N06, N11; RD14 decisions 2, 7, 8 and 11).
/// Every query works on this library alone.
extension Library {
    /// The `setting` key of the daily automatic limit (decision 8).
    static let dailyAutomaticLimitKey = "daily_automatic_limit"
    /// The limit when none is stored.
    public static let standardDailyAutomaticLimit = 200
    /// How many of each category's newest articles a pass looks at.
    static let passArticlesPerCategory = 50
    /// The most identifiers bound in one `IN (…)`.
    private static let identifiersPerStatement = 500

    /// The pass's candidates (decision 7): for each category, in the
    /// categories' order, its newest `passArticlesPerCategory` articles in
    /// list order, and of those the ones waiting in `locale` whose source
    /// translates automatically (`on`, or `inherit` with `automatic`).
    func translationPassCandidates(locale: ReadingLocale, automatic: Bool) async throws -> [UUID] {
        let sql = """
            SELECT article.id, source.auto_translate,
                EXISTS (SELECT 1 FROM translation WHERE translation.article_id = article.id AND translation.locale = ?) AS has_row
            FROM article JOIN source ON source.id = article.source_id
            WHERE article.source_id IN (SELECT id FROM source WHERE category_id = ?)
            ORDER BY \(Self.articleOrderSQL)
            LIMIT ?
            """
        return try await read { db in
            let categories = try String.fetchAll(db, sql: "SELECT id FROM category ORDER BY sort_order, id")
            var candidates: [UUID] = []
            for category in categories {
                let rows = try Row.fetchAll(db, sql: sql, arguments: [locale.rawValue, category, Self.passArticlesPerCategory])
                for row in rows where !(row["has_row"] as Bool) {
                    let setting = AutoTranslate(rawValue: row["auto_translate"]) ?? .inherit
                    guard Self.translatesAutomatically(setting, automatic: automatic) else { continue }
                    candidates.append(try Self.identifier(row["id"]))
                }
            }
            return candidates
        }
    }

    /// Whether a source's articles are translated without the owner asking.
    /// The app asks it too, to show a translation's block only on a row that
    /// is (RD21).
    public static func translatesAutomatically(_ setting: AutoTranslate, automatic: Bool) -> Bool {
        switch setting {
        case .on: true
        case .inherit: automatic
        case .off: false
        }
    }

    /// The articles of `ids` that exist, with what judging them needs, in
    /// the order of `ids`.
    func translationInputs(_ ids: [UUID], locale: ReadingLocale) async throws -> [TranslationInput] {
        guard !ids.isEmpty else { return [] }
        let order = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let inputs = try await read { db in
            var inputs: [TranslationInput] = []
            for chunk in Self.chunks(ids) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                let sql = """
                    SELECT article.id, article.title, article.excerpt, source.auto_translate,
                        EXISTS (SELECT 1 FROM translation WHERE translation.article_id = article.id AND translation.locale = ?)
                            AS has_row
                    FROM article JOIN source ON source.id = article.source_id
                    WHERE article.id IN (\(marks))
                    """
                let arguments = StatementArguments([locale.rawValue] + chunk.map(\.databaseKey))
                for row in try Row.fetchAll(db, sql: sql, arguments: arguments) {
                    inputs.append(TranslationInput(
                        id: try Self.identifier(row["id"]), title: row["title"], excerpt: row["excerpt"],
                        autoTranslate: AutoTranslate(rawValue: row["auto_translate"]) ?? .inherit, hasTranslation: row["has_row"]
                    ))
                }
            }
            return inputs
        }
        return inputs.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
    }

    /// Writes `records` in one transaction, one statement each, replacing
    /// the row of the same article and locale. Each statement is guarded by
    /// its article's existence, so an article deleted meanwhile loses only
    /// its own result (decision 11).
    ///
    /// - Returns: the articles whose row was written.
    @discardableResult
    func storeTranslations(_ records: [TranslationRecord]) async throws -> Set<UUID> {
        guard !records.isEmpty else { return [] }
        let now = now()
        return try await write { db in
            var stored = Set<UUID>()
            for record in records {
                try db.execute(
                    sql: """
                        INSERT INTO translation (article_id, locale, title, excerpt, state, error, model, updated_at)
                        SELECT ?, ?, ?, ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM article WHERE id = ?)
                        ON CONFLICT (article_id, locale) DO UPDATE SET
                            title = excluded.title, excerpt = excluded.excerpt, state = excluded.state,
                            error = excluded.error, model = excluded.model, updated_at = excluded.updated_at
                        """,
                    arguments: [
                        record.articleID.databaseKey, record.locale.rawValue, record.title, record.excerpt, record.state.rawValue,
                        record.failure?.rawValue, record.model, now, record.articleID.databaseKey,
                    ]
                )
                if db.changesCount > 0 {
                    stored.insert(record.articleID)
                }
            }
            return stored
        }
    }

    /// The stored translations of `ids` in `locale`; an article without one
    /// is absent.
    public func translations(of ids: some Collection<UUID>, locale: ReadingLocale) async throws -> [UUID: StoredTranslation] {
        let ids = Array(ids)
        guard !ids.isEmpty else { return [:] }
        return try await read { db in
            var result: [UUID: StoredTranslation] = [:]
            for chunk in Self.chunks(ids) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT article_id, state, title, excerpt, error FROM translation WHERE locale = ? AND article_id IN (\(marks))",
                    arguments: StatementArguments([locale.rawValue] + chunk.map(\.databaseKey))
                )
                for row in rows {
                    if let translation = StoredTranslation(state: row["state"], title: row["title"], excerpt: row["excerpt"], error: row["error"]) {
                        result[try Self.identifier(row["article_id"])] = translation
                    }
                }
            }
            return result
        }
    }

    /// The usage rows of automatic requests at or after `start`: what the
    /// daily automatic limit counts, cancelled and failed requests included
    /// (decision 8). Settings › Usage shows it since today's start beside
    /// the limit (RD17).
    public func automaticRequestCount(since start: Date) async throws -> Int {
        try await read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage WHERE automatic = 1 AND at >= ?", arguments: [start]) ?? 0
        }
    }

    /// The daily automatic limit: the stored value, else
    /// `standardDailyAutomaticLimit`. A stored value that is not a
    /// non-negative whole number reads as the standard.
    public func dailyAutomaticLimit() async throws -> Int {
        try await read { db in
            let text = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [Self.dailyAutomaticLimitKey])
            guard let text, let value = Int(text), value >= 0 else { return Self.standardDailyAutomaticLimit }
            return value
        }
    }

    /// Stores the daily automatic limit (RD17 gives it its screen; a debug
    /// launch option sets it for the UI tests).
    public func setDailyAutomaticLimit(_ limit: Int) async throws {
        try await write { db in
            try db.execute(
                sql: "INSERT INTO setting (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                arguments: [Self.dailyAutomaticLimitKey, String(max(0, limit))]
            )
        }
    }

    private static func chunks(_ ids: [UUID]) -> [[UUID]] {
        stride(from: 0, to: ids.count, by: identifiersPerStatement).map { Array(ids[$0..<min($0 + identifiersPerStatement, ids.count)]) }
    }

    private static func identifier(_ text: String) throws -> UUID {
        guard let id = UUID(uuidString: text) else { throw LibraryError.storage("Not an identifier: \(text)") }
        return id
    }
}
