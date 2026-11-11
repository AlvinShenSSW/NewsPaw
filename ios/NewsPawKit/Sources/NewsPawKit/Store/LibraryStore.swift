import Foundation
import GRDB
import SQLite3

/// Owns the directory that holds the libraries and gives out, for this store,
/// at most one `Library`, and so one connection pool, per partition. The
/// guarantee is per store instance: the app creates one store.
///
/// The normal library always exists and is created on first use. The adult
/// library's file is created only by an explicit call (spec N02, N09).
public actor LibraryStore {
    private let directory: URL
    private let now: @Sendable () -> Date
    /// The library of each partition, or the open in flight for it. Looking
    /// up and storing an entry happen without a suspension in between, so two
    /// simultaneous opens share one entry and one pool.
    private var libraries: [Partition: Task<Library, any Error>] = [:]

    /// - Parameters:
    ///   - directory: where the database files live; created when a library
    ///     is first created.
    ///   - now: the clock for every `updated_at`; tests inject their own.
    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }

    /// `Application Support/Libraries/` inside the app's container.
    public static func defaultDirectory() -> URL {
        URL.applicationSupportDirectory.appending(path: "Libraries", directoryHint: .isDirectory)
    }

    /// Opens the normal library, creating its directory and file when they do
    /// not exist and migrating it to the current schema.
    ///
    /// - Throws: `LibraryError.newerSchema` when a newer version of the app
    ///   wrote the database; `LibraryError.damaged` when the file is not a
    ///   database or is corrupt; `LibraryError.storage` otherwise. A failed
    ///   open changes no row and is tried again on the next call.
    public func openNormal() async throws -> Library {
        try await open(.normal, migrator: Schema.migrator, create: true)
    }

    // MARK: - Adult partition (internal until RD18 adds authentication)

    /// Whether the adult library's file exists. Never creates it.
    nonisolated var adultLibraryExists: Bool {
        FileManager.default.fileExists(atPath: fileURL(for: .adult).path)
    }

    /// Creates the adult library's file when it does not exist, then opens it.
    func createAdultLibrary() async throws -> Library {
        try await open(.adult, migrator: Schema.migrator, create: true)
    }

    /// Opens the adult library. Fails with `LibraryError.missing` when its
    /// file does not exist, and then creates nothing.
    func openAdultLibrary() async throws -> Library {
        try await open(.adult, migrator: Schema.migrator, create: false)
    }

    // MARK: - Opening

    /// Returns the library already held for `partition`, or opens it with
    /// `migrator`. Tests pass migrators with extra migrations.
    func open(_ partition: Partition, migrator: DatabaseMigrator, create: Bool) async throws -> Library {
        if let existing = libraries[partition] {
            return try await existing.value
        }
        let url = fileURL(for: partition)
        // Checked here rather than in the open itself, so that an open of a
        // missing file never holds the entry a simultaneous create would join.
        if !create, !FileManager.default.fileExists(atPath: url.path) {
            throw LibraryError.missing
        }
        let directory = directory
        let now = now
        let opening = Task.detached {
            try Self.makeLibrary(
                partition: partition, directory: directory, url: url,
                migrator: migrator, create: create, now: now
            )
        }
        libraries[partition] = opening
        do {
            return try await opening.value
        } catch {
            // Forget a failed open so that the next call tries again.
            if libraries[partition] == opening {
                libraries[partition] = nil
            }
            throw error
        }
    }

    /// The one place that turns a partition into a file name.
    nonisolated func fileURL(for partition: Partition) -> URL {
        let name = switch partition {
        case .normal: "normal.sqlite"
        case .adult: "adult.sqlite"
        }
        return directory.appending(path: name, directoryHint: .notDirectory)
    }

    /// Opens a pool on the file, refuses a database written by a newer
    /// schema before running any migration, then migrates.
    private static func makeLibrary(
        partition: Partition,
        directory: URL,
        url: URL,
        migrator: DatabaseMigrator,
        create: Bool,
        now: @escaping @Sendable () -> Date
    ) throws -> Library {
        do {
            if create {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            var configuration = Configuration()
            configuration.label = "NewsPaw.\(partition.rawValue)"
            configuration.prepareDatabase { db in
                // No connection of a library can reach another database file.
                _ = sqlite3_limit(db.sqliteConnection, SQLITE_LIMIT_ATTACHED, 0)
            }
            let pool = try DatabasePool(path: url.path, configuration: configuration)
            if try pool.read({ db in try migrator.hasBeenSuperseded(db) }) {
                throw LibraryError.newerSchema
            }
            try migrator.migrate(pool)
            return Library(partition: partition, pool: pool, now: now)
        } catch {
            throw LibraryError.wrapping(error)
        }
    }
}
