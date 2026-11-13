import Foundation
import GRDB

/// Clean-up (spec N04; RD06 decision 7).
extension Library {
    /// Deletes, in one transaction, every article that is not starred and
    /// was first seen more than `retention` ago by the library's clock, with
    /// its body. Each deleted article leaves its identifier in `seen` with
    /// the clean-up's time, so that it does not come back as new while its
    /// feed still lists it. "Forever" deletes nothing. The published time and
    /// the read state play no part, and no `updated_at` changes.
    ///
    /// - Returns: the number of articles deleted.
    /// - Throws: a `LibraryError`; then nothing has been deleted.
    @discardableResult
    public func cleanUp(keeping retention: Retention) async throws -> Int {
        guard retention != .forever else { return 0 }
        let now = now()
        let cutoff = now.addingTimeInterval(-TimeInterval(retention.rawValue) * 24 * 60 * 60)
        return try await write { db in
            let expired = try Row.fetchAll(db, sql: """
                SELECT id, source_id, external_id FROM article
                WHERE starred_at IS NULL AND first_seen_at < ?
                """, arguments: [cutoff])
            guard !expired.isEmpty else { return 0 }
            let remember = try db.makeStatement(sql: """
                INSERT INTO seen (source_id, external_id_hash, last_seen_at) VALUES (?, ?, ?)
                ON CONFLICT (source_id, external_id_hash) DO UPDATE SET last_seen_at = excluded.last_seen_at
                """)
            let delete = try db.makeStatement(sql: "DELETE FROM article WHERE id = ?")
            for row in expired {
                let sourceKey: String = row["source_id"]
                let externalID: String = row["external_id"]
                try remember.execute(arguments: [sourceKey, Self.seenHash(externalID), now])
                // The body follows through the foreign key's cascade.
                try delete.execute(arguments: [row["id"] as String])
            }
            return expired.count
        }
    }
}
