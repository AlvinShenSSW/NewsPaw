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
/// library only through `AdultGate` (RD18 decision 2). The adult library's
/// pool is closed at every lock and opened anew by the next unlock.
public actor LibraryStore {
    private let directory: URL
    private let cacheRoot: URL
    private let now: @Sendable () -> Date
    /// The library of each partition, or the open in flight for it. Looking
    /// up and storing an entry happen without a suspension in between, so two
    /// simultaneous opens share one entry and one pool.
    private var libraries: [Partition: Task<Library, any Error>] = [:]
    /// The adult library last given out, held weakly. It answers two
    /// things: whether that object's pool is closed, and whether the object
    /// itself is gone (RD18 criterion 7). An object that is alive and not
    /// closed — its close failed — is given out again by the next open, so
    /// the file never has two open pools.
    private weak var lastAdult: Library?
    #if DEBUG
    /// How many times the adult library was asked for, opened or created
    /// (RD24 criterion 4): the UI tests' report shows that a background
    /// run asks for it never. A debug build only.
    public private(set) var adultOpensForUITests = 0
    #endif

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
    /// partition on): opened once to create it, then closed. An existing
    /// file is not opened, so a damaged one does not stop the partition
    /// from being turned on, and then deleted.
    func createAdultLibraryFileIfMissing() async throws {
        guard !adultLibraryExists, libraries[.adult] == nil else { return }
        _ = try await createAdultLibrary()
        try await closeAdultLibrary()
    }

    /// Closes the adult library's connections and forgets the object
    /// (RD18: every lock, and before the file is deleted). An open in
    /// flight is waited for first; then, with no suspension in between, the
    /// pool is closed, which waits for the one read and the one write in
    /// flight and for nothing else. A reference still held somewhere —
    /// UIKit keeps the views' models alive after a lock (assumption A4) —
    /// fails on use from then on instead of keeping the file open, and the
    /// next open makes a new pool. Then the library's image cache is
    /// closed: a store that is running ends first, and every later one
    /// writes nothing, so that a thumbnail that was ending cannot write
    /// adult images, or create their directory again, after a lock or a
    /// deletion. With nothing open this does nothing.
    ///
    /// - Throws: `LibraryError.storage` when the connections cannot be
    ///   closed. The object then stays the one the next open gives out, so
    ///   there are still never two open pools; its cache stays open with it.
    func closeAdultLibrary() async throws {
        var living = lastAdult
        while let entry = libraries[.adult] {
            let library = try? await entry.value
            // Unchanged across the suspension: this is still the entry.
            if libraries[.adult] == entry {
                libraries[.adult] = nil
                living = library ?? living
            }
        }
        // No suspension from here to the pool's close: nothing can open the
        // file meanwhile.
        lastAdult = living
        try living?.close()
        // An open after this point makes a new library with a cache of its
        // own; this one stays closed. (While a library is open the store
        // holds it, so the library with an open cache is always `living`.)
        await living?.imageCache.close()
    }

    /// Whether no pool is open on the adult library's file: the store
    /// holds none, and the last one it gave out is closed or gone.
    var adultLibraryIsClosed: Bool {
        libraries[.adult] == nil && (lastAdult?.isClosed ?? true)
    }

    /// Whether the adult library object last given out is gone from
    /// memory, not only closed. For reports: after a lock its release is
    /// outside the store's control.
    var adultLibraryObjectIsReleased: Bool {
        libraries[.adult] == nil && lastAdult == nil
    }

    /// Deletes the adult library's database (RD18 decision 9): closes its
    /// connections, by the one closing path, and removes the file with its
    /// `-wal` and `-shm` files. A missing file is not a failure, and no
    /// library is opened, so this works on a damaged file too.
    ///
    /// - Throws: `LibraryError.storage` when the connections cannot be
    ///   closed or a file cannot be removed. What was removed stays removed.
    func deleteAdultLibraryFiles() async throws {
        try await closeAdultLibrary()
        // No suspension between the close and the removals.
        let database = fileURL(for: .adult)
        for suffix in ["", "-wal", "-shm"] {
            try Self.removeIfPresent(URL(fileURLWithPath: database.path + suffix))
        }
    }

    /// Removes the adult image cache's directory; a missing one is not a
    /// failure. Called last when the partition's data is deleted, after
    /// `deleteAdultLibraryFiles()` has closed the cache, so that a thumbnail
    /// store that was ending has written before the removal or writes
    /// nothing, and cannot recreate the directory afterwards.
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
        #if DEBUG
        if partition == .adult {
            adultOpensForUITests += 1
        }
        #endif
        if let existing = libraries[partition] {
            return try await existing.value
        }
        // An adult library that is alive and still open — its close failed —
        // is given out again, so that the file never has two open pools.
        if partition == .adult, let living = lastAdult, !living.isClosed {
            libraries[.adult] = Task { living }
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
            let library = try await opening.value
            if partition == .adult {
                lastAdult = library
            }
            return library
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
                // The search triggers call it (RD25 decision 5): every
                // connection that can write `article` or `translation` —
                // the writer, and with it the migrations — has it. Measured
                // on iOS 26.5 and 27 (assumption A7): `trusted_schema` is
                // on, so a trigger may call it as registered.
                db.add(function: SearchQuery.makeFoldFunction())
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
