import Foundation
import GRDB

/// A stored text of a body's translation (RD15 decision 2), as the reading
/// screen reads it.
public struct StoredBodyText: Sendable, Hashable {
    /// `done` or `failed`.
    public let state: TranslationState
    /// The accepted translation, with `done`.
    public let text: String?
    /// The reason, with `failed`.
    public let failure: TranslationFailure?
    /// The model's name, with `done`.
    public let model: String?
    public let updatedAt: Date

    public init(state: TranslationState, text: String?, failure: TranslationFailure?, model: String?, updatedAt: Date) {
        self.state = state
        self.text = text
        self.failure = failure
        self.model = model
        self.updatedAt = updatedAt
    }
}

/// One body text's row to write.
struct BodyTextRecord: Sendable, Hashable {
    let hash: String
    let state: TranslationState
    let text: String?
    let failure: TranslationFailure?
    let model: String?
}

/// The model and the time of an article's title translation (RD14's row),
/// for Article Info (RD15 decision 12).
public struct TitleTranslationDetails: Sendable, Hashable {
    public let state: TranslationState
    /// `nil` when no model was called (converted, or nothing to show).
    public let model: String?
    public let updatedAt: Date
}

/// The rows of `body_translation` (RD15 decision 2). Every query works on
/// this library alone.
extension Library {
    /// The article's stored texts in `locale`, by hash. A row of a state or
    /// reason this build does not know is left out.
    func bodyTranslations(ofArticle id: UUID, locale: ReadingLocale) async throws -> [String: StoredBodyText] {
        try await read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT source_hash, text, state, error, model, updated_at FROM body_translation
                    WHERE article_id = ? AND locale = ?
                    """,
                arguments: [id.databaseKey, locale.rawValue]
            )
            var result: [String: StoredBodyText] = [:]
            for row in rows {
                guard let state = (row["state"] as String?).flatMap(TranslationState.init(rawValue:)), let updatedAt = row["updated_at"] as Date?
                else { continue }
                switch state {
                case .done:
                    guard let text = row["text"] as String? else { continue }
                    result[row["source_hash"]] = StoredBodyText(state: .done, text: text, failure: nil, model: row["model"], updatedAt: updatedAt)
                case .failed:
                    let failure = (row["error"] as String?).flatMap(TranslationFailure.init(rawValue:)) ?? .malformed
                    result[row["source_hash"]] = StoredBodyText(state: .failed, text: nil, failure: failure, model: nil, updatedAt: updatedAt)
                case .none:
                    continue
                }
            }
            return result
        }
    }

    /// Writes one chunk's rows in one transaction, one statement each,
    /// replacing the row of the same text, unless the article is gone. A
    /// failed row never replaces a done one: a paid translation is not lost
    /// to a later failure of the same text.
    ///
    /// - Returns: false, with nothing written, when the article is gone.
    func storeBodyTranslations(_ records: [BodyTextRecord], ofArticle id: UUID, locale: ReadingLocale) async throws -> Bool {
        guard !records.isEmpty else { return true }
        let now = now()
        return try await write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM article WHERE id = ?)", arguments: [id.databaseKey]) == true
            else { return false }
            for record in records {
                try db.execute(
                    sql: """
                        INSERT INTO body_translation (article_id, locale, source_hash, text, state, error, model, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT (article_id, locale, source_hash) DO UPDATE SET
                            text = excluded.text, state = excluded.state, error = excluded.error,
                            model = excluded.model, updated_at = excluded.updated_at
                        WHERE body_translation.state <> 'done' OR excluded.state = 'done'
                        """,
                    arguments: [
                        id.databaseKey, locale.rawValue, record.hash, record.text, record.state.rawValue, record.failure?.rawValue,
                        record.model, now,
                    ]
                )
            }
            return true
        }
    }

    /// Whether the library holds the article.
    func articleExists(_ id: UUID) async throws -> Bool {
        try await read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM article WHERE id = ?)", arguments: [id.databaseKey]) ?? false
        }
    }

    /// The state, model and time of the article's title translation in
    /// `locale`; `nil` without a row.
    func titleTranslationDetails(ofArticle id: UUID, locale: ReadingLocale) async throws -> TitleTranslationDetails? {
        try await read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT state, model, updated_at FROM translation WHERE article_id = ? AND locale = ?",
                arguments: [id.databaseKey, locale.rawValue]
            ), let state = (row["state"] as String?).flatMap(TranslationState.init(rawValue:)), let updatedAt = row["updated_at"] as Date?
            else { return nil }
            return TitleTranslationDetails(state: state, model: row["model"], updatedAt: updatedAt)
        }
    }
}
