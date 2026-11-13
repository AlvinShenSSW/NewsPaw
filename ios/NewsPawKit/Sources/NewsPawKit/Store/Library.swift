import Foundation
import GRDB

/// One partition's data: the only way to reach the rows of one database file
/// (spec N02, N04, section 6). Obtain it from a `LibraryStore`, which gives
/// out one instance per file.
///
/// No method takes a partition or another library: everything works on the
/// library's own database connection pool, whose connections cannot attach a
/// second database.
public final class Library: Sendable {
    /// Which partition this library holds. A label for the interface; it
    /// never selects rows.
    public let partition: Partition

    /// This library's image cache: the only way to reach it. Its directory
    /// is created by its first store, not by opening the library.
    public let imageCache: ImageCache

    let pool: DatabasePool
    let now: @Sendable () -> Date

    init(partition: Partition, pool: DatabasePool, cacheDirectory: URL, now: @escaping @Sendable () -> Date) {
        self.partition = partition
        self.pool = pool
        self.imageCache = ImageCache(directory: cacheDirectory)
        self.now = now
    }

    /// Runs `updates` in one write transaction and maps its errors to
    /// `LibraryError`.
    func write<T: Sendable>(_ updates: @Sendable (Database) throws -> T) async throws -> T {
        do {
            return try await pool.write(updates)
        } catch {
            throw LibraryError.wrapping(error)
        }
    }

    /// Runs `value` on a reader connection and maps its errors to
    /// `LibraryError`.
    func read<T: Sendable>(_ value: @Sendable (Database) throws -> T) async throws -> T {
        do {
            return try await pool.read(value)
        } catch {
            throw LibraryError.wrapping(error)
        }
    }
}

extension UUID {
    /// The form in which an identifier is stored and compared in SQL:
    /// lowercase text. A `UUID` bound directly to an SQL argument is sent as a
    /// 16-byte blob and matches no stored identifier, so every identifier
    /// crosses into SQL through this property.
    var databaseKey: String {
        uuidString.lowercased()
    }
}

// MARK: - Sources, articles and seen identifiers

// Package-internal until RD04 and RD05 give them public operations.
extension Library {
    /// Inserts a source. Fails with `duplicateAddress` when the library
    /// already holds a source with the same address.
    func insert(_ source: Source) async throws {
        try await write { db in
            do {
                try source.insert(db)
            } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
                // The address is the table's only UNIQUE constraint; a
                // repeated `id` reports SQLITE_CONSTRAINT_PRIMARYKEY instead.
                throw LibraryError.duplicateAddress
            }
        }
    }

    func insert(_ article: Article) async throws {
        try await write { db in try article.insert(db) }
    }

    func insert(_ body: ArticleBody) async throws {
        try await write { db in try body.insert(db) }
    }

    func insertSeen(sourceID: UUID, externalIDHash: String, lastSeenAt: Date) async throws {
        try await write { db in
            try db.execute(
                sql: "INSERT INTO seen (source_id, external_id_hash, last_seen_at) VALUES (?, ?, ?)",
                arguments: [sourceID.databaseKey, externalIDHash, lastSeenAt]
            )
        }
    }

    func sources() async throws -> [Source] {
        try await read { db in try Source.order(Column("url"), Column("id")).fetchAll(db) }
    }

    func articles() async throws -> [Article] {
        try await read { db in try Article.order(Column("first_seen_at"), Column("id")).fetchAll(db) }
    }
}
