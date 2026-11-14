import Foundation
import GRDB
import SQLite3

/// Owns the directory that holds the libraries and gives out, for this store,
/// at most one `Library`, and so one connection pool, per partition. The
/// guarantee is per store instance: the app creates one store.
///
/// The normal library always exists and is created on first use. The adult
/// library's file is created only by an explicit call (spec N02, N09), and
/// its functions are internal: code outside the package reaches the adult
/// library only through `AdultGate` (RD18 decision 2).
public actor LibraryStore {
    private let directory: URL
    private let cacheRoot: URL
    private let now: @Sendable () -> Date
    /// The library of each partition, or the open in flight for it. Looking
    /// up and storing an entry happen without a suspension in between, so two
    /// simultaneous opens share one entry and one pool.
    private var libraries: [Partition: Task<Library, any Error>] = [:]
    /// The adult library after `releaseAdultLibrary()`: held weakly, so it
    /// is gone, and its connections closed, once nothing else holds it. An
    /// open while it still lives gets this same object, so there is never a
    /// second pool on the file (RD18 decision 4).
    private weak var releasedAdult: Library?

    /// - Parameters:
    ///   - directory: where the database files live; created when a library
    ///     is first created.
    ///   - cacheRoot: where the libraries' image caches live, each in its own
    ///     directory below it; nothing is created there until an image is
    ///     stored.
    ///   - now: the clock of every library; tests inject their own.
    public init(
        directory: URL, cacheRoot: URL = LibraryStore.defaultCacheRoot(), now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.cacheRoot = cacheRoot
        self.now = now
    }

    /// `Application Support/Libraries/` inside the app's container.
    public static func defaultDirectory() -> URL {
        URL.applicationSupportDirectory.appending(path: "Libraries", directoryHint: .isDirectory)
    }

    /// `Images/` in the app's caches directory.
    public static func defaultCacheRoot() -> URL {
        URL.cachesDirectory.appending(path: "Images", directoryHint: .isDirectory)
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

    // MARK: - Adult partition (internal: reached through `AdultGate`)

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

    /// Creates the adult library's file when it does not exist (turning the
    /// partition on): opened once to create it, then released. An existing
    /// file is not opened, so a damaged one does not stop the partition
    /// from being turned on, and then deleted.
    func createAdultLibraryFileIfMissing() async throws {
        guard !adultLibraryExists, libraries[.adult] == nil else { return }
        _ = try await createAdultLibrary()
        await releaseAdultLibrary()
    }

    /// Lets go of the adult library (locking): the store keeps only a weak
    /// reference, so the library is gone when nothing else holds it. An
    /// open in flight is waited for first, so that it cannot outlive the
    /// release as a second pool.
    func releaseAdultLibrary() async {
        while let entry = libraries[.adult] {
            let library = try? await entry.value
            // Unchanged across the suspension: this is still the entry.
            if libraries[.adult] == entry {
                libraries[.adult] = nil
                releasedAdult = library ?? releasedAdult
            }
        }
    }

    /// Whether the store holds no adult library and the one it released
    /// is gone: nothing in the process keeps the file open (RD18 criterion
    /// 7).
    var adultLibraryIsReleased: Bool {
        libraries[.adult] == nil && releasedAdult == nil
    }

    /// Deletes the adult library's database (RD18 decision 9): closes its
    /// connections explicitly, so that a reference still held somewhere
    /// fails on use instead of keeping the file open, forgets the object,
    /// and removes the file with its `-wal` and `-shm` files. A missing
    /// file is not a failure, and no library is opened, so this works on a
    /// damaged file too.
    ///
    /// - Throws: `LibraryError.storage` when the connections cannot be
    ///   closed or a file cannot be removed. What was removed stays removed.
    func deleteAdultLibraryFiles() async throws {
        var living = releasedAdult
        while let entry = libraries[.adult] {
            let library = try? await entry.value
            if libraries[.adult] == entry {
                libraries[.adult] = nil
                living = library ?? living
            }
        }
        // No suspension from here on: nothing can open the file meanwhile.
        do {
            try living?.close()
        } catch {
            // Still open: the next open gets this object, not a second pool.
            releasedAdult = living
            throw error
        }
        releasedAdult = nil
        let database = fileURL(for: .adult)
        for suffix in ["", "-wal", "-shm"] {
            try Self.removeIfPresent(URL(fileURLWithPath: database.path + suffix))
        }
    }

    /// Removes the adult image cache's directory; a missing one is not a
    /// failure. Called last when the partition's data is deleted, so that a
    /// thumbnail store that was ending cannot recreate it afterwards.
    nonisolated func deleteAdultImageCache() throws {
        try Self.removeIfPresent(cacheDirectory(for: .adult))
    }

    private static func removeIfPresent(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Already gone.
        } catch {
            throw LibraryError.storage(String(describing: (error as NSError).code))
        }
    }

    // MARK: - Opening

    /// Returns the library already held for `partition`, or opens it with
    /// `migrator`. Tests pass migrators with extra migrations.
    func open(_ partition: Partition, migrator: DatabaseMigrator, create: Bool) async throws -> Library {
        if let existing = libraries[partition] {
            return try await existing.value
        }
        // A released adult library that still lives is taken back, so that
        // the file never has two pools.
        if partition == .adult, let living = releasedAdult {
            libraries[.adult] = Task { living }
            releasedAdult = nil
            return living
        }
        let url = fileURL(for: partition)
        // Checked here rather than in the open itself, so that an open of a
        // missing file never holds the entry a simultaneous create would join.
        if !create, !FileManager.default.fileExists(atPath: url.path) {
            throw LibraryError.missing
        }
        let directory = directory
        let cache = cacheDirectory(for: partition)
        let now = now
        let opening = Task.detached {
            try Self.makeLibrary(
                partition: partition, directory: directory, url: url, cacheDirectory: cache,
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

    /// The one place that turns a partition into an image-cache directory:
    /// `<cache root>/<partition>/`, so the two caches never share one.
    nonisolated func cacheDirectory(for partition: Partition) -> URL {
        cacheRoot.appending(path: partition.rawValue, directoryHint: .isDirectory)
    }

    /// Opens a pool on the file, refuses a database written by a newer
    /// schema before running any migration, then migrates.
    private static func makeLibrary(
        partition: Partition,
        directory: URL,
        url: URL,
        cacheDirectory: URL,
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
            return Library(partition: partition, pool: pool, cacheDirectory: cacheDirectory, now: now)
        } catch {
            throw LibraryError.wrapping(error)
        }
    }
}
