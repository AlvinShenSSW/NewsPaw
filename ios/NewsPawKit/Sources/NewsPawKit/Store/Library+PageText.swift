import Foundation
import GRDB

/// The rows of `page_text` (RD16 decision 7): translations of whole-block
/// runs of web pages, keyed by the hash of the page's host and the text,
/// and the reading language. Every query works on this library alone.
extension Library {
    /// The stored translations of `hashes` in `locale`, by hash; each found
    /// row's `last_used_at` is set to now, in the same transaction.
    func pageTexts(_ hashes: [String], locale: ReadingLocale) async throws -> [String: String] {
        guard !hashes.isEmpty else { return [:] }
        let now = now()
        let unique = Array(Set(hashes))
        return try await write { db in
            var found: [String: String] = [:]
            // SQLite's variable limit is far above a collection's runs, but
            // the hashes are read in slices all the same.
            var start = 0
            while start < unique.count {
                let slice = Array(unique[start..<min(start + 500, unique.count)])
                start += slice.count
                let marks = Array(repeating: "?", count: slice.count).joined(separator: ", ")
                let rows = try Row.fetchAll(
                    db, sql: "SELECT text_hash, translated FROM page_text WHERE locale = ? AND text_hash IN (\(marks))",
                    arguments: StatementArguments([locale.rawValue] + slice)
                )
                for row in rows {
                    found[row["text_hash"]] = row["translated"]
                }
            }
            if !found.isEmpty {
                let touch = try db.makeStatement(sql: "UPDATE page_text SET last_used_at = ? WHERE text_hash = ? AND locale = ?")
                for hash in found.keys {
                    try touch.execute(arguments: [now, hash, locale.rawValue])
                }
            }
            return found
        }
    }

    /// Stores translations by hash in `locale`, with the model's name,
    /// replacing a row of the same hash and language.
    func storePageTexts(_ translations: [String: String], locale: ReadingLocale, model: String) async throws {
        guard !translations.isEmpty else { return }
        let now = now()
        try await write { db in
            let statement = try db.makeStatement(sql: """
                INSERT INTO page_text (text_hash, locale, translated, model, updated_at, last_used_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (text_hash, locale) DO UPDATE SET
                    translated = excluded.translated, model = excluded.model,
                    updated_at = excluded.updated_at, last_used_at = excluded.last_used_at
                """)
            for (hash, text) in translations {
                try statement.execute(arguments: [hash, locale.rawValue, text, model, now, now])
            }
        }
    }
}
