import Foundation
import GRDB

/// The partition settings of one library that are not the refresh state
/// or the daily limit (spec section 4; RD19 decision 6), in its `setting`
/// table, so that each partition has its own.
extension Library {
    /// The `setting` key of "Show Thumbnails in Lists".
    static let listThumbnailsKey = "list_thumbnails"

    /// Whether the article lists of this library show thumbnails: stored
    /// as `"1"` or `"0"`; absent, or any other value, reads as on.
    public func listThumbnails() async throws -> Bool {
        try await read { db in
            try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [Self.listThumbnailsKey]) != "0"
        }
    }

    /// Stores whether the article lists of this library show thumbnails.
    public func setListThumbnails(_ shows: Bool) async throws {
        try await write { db in
            try db.execute(
                sql: "INSERT INTO setting (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                arguments: [Self.listThumbnailsKey, shows ? "1" : "0"]
            )
        }
    }
}
