import Foundation
@testable import NewsPawKit
import Testing

/// RD18 decision 4 as built (see the design's post-implementation record)
/// and decision 9, at the store: the adult library's pool is closed
/// explicitly — at every lock and before its file is deleted, by one path —
/// so that a reference something still holds cannot keep the file open,
/// and the next open makes a new pool.
@Suite("LibraryStore: closing and deleting the adult library")
struct AdultLibraryCloseTests {
    private func makeStore() throws -> (store: LibraryStore, directory: URL, cacheRoot: URL, root: URL) {
        let root = try makeTemporaryDirectory()
        let directory = root.appending(path: "Libraries", directoryHint: .isDirectory)
        let cacheRoot = root.appending(path: "Images", directoryHint: .isDirectory)
        return (LibraryStore(directory: directory, cacheRoot: cacheRoot), directory, cacheRoot, root)
    }

    private func adultFiles(_ directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix("adult") }.sorted()
    }

    @Test("a store that never opened the adult library reports it closed and gone, and closing it does nothing")
    func neverOpened() async throws {
        let (store, directory, _, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await store.openNormal()

        #expect(await store.adultLibraryIsClosed)
        #expect(await store.adultLibraryObjectIsReleased)
        try await store.closeAdultLibrary()
        #expect(await store.adultLibraryIsClosed)
        #expect(adultFiles(directory).isEmpty)
    }

    @Test("criterion 7: closing closes the pool although the object is still held; the held object fails and the next open is a new pool with the data")
    func closeWithAHeldReference() async throws {
        let (store, _, _, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let held = try await store.createAdultLibrary()
        _ = try await held.createCategory(name: "Kept", icon: .heart)
        #expect(!(await store.adultLibraryIsClosed))
        #expect(!held.isClosed)

        try await store.closeAdultLibrary()

        // Closed at once, whatever holds the object.
        #expect(await store.adultLibraryIsClosed)
        #expect(held.isClosed)
        #expect(!(await store.adultLibraryObjectIsReleased))
        // The kept reference fails, with the library's own error and no
        // other effect.
        await #expect(throws: LibraryError.self) { try await held.categories() }
        await #expect(throws: LibraryError.self) { try await held.createCategory(name: "Late", icon: .heart) }
        // A new pool, not the closed object; the data is the file's.
        let reopened = try await store.openAdultLibrary()
        #expect(reopened !== held)
        #expect(!reopened.isClosed)
        #expect(try await reopened.categories().map(\.name) == ["Kept"])
        #expect(!(await store.adultLibraryIsClosed))
        // Closing twice is closing once.
        try await store.closeAdultLibrary()
        try await store.closeAdultLibrary()
        #expect(await store.adultLibraryIsClosed)
    }

    @Test("the closed object is gone from memory when its last reference is")
    func objectIsReleased() async throws {
        let (store, _, _, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var adult: Library? = try await store.createAdultLibrary()
        try await store.closeAdultLibrary()
        #expect(!(await store.adultLibraryObjectIsReleased))

        adult = nil

        #expect(await store.adultLibraryObjectIsReleased)
        #expect(await store.adultLibraryIsClosed)
        _ = adult
    }

    @Test("assumption A3: closing waits for the read and the write in flight; what they did is kept, and later use fails")
    func closeWaitsForWhatIsInFlight() async throws {
        let (store, directory, _, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let adult = try await store.createAdultLibrary()
        _ = try await adult.createCategory(name: "Held", icon: .heart)
        #expect(adultFiles(directory).contains("adult.sqlite-wal"))
        // A read and a write that take a while, started before the close.
        let reading = Task.detached {
            try await adult.pool.read { db in
                _ = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM category")
                Thread.sleep(forTimeInterval: 0.2)
                return Date()
            }
        }
        let writing = Task.detached {
            try await adult.pool.write { db in
                try db.execute(sql: "UPDATE category SET name = 'Written'")
                Thread.sleep(forTimeInterval: 0.2)
                return Date()
            }
        }
        try await Task.sleep(for: .milliseconds(50))

        try await store.closeAdultLibrary()
        let closed = Date()

        #expect(try await reading.value <= closed)
        #expect(try await writing.value <= closed)
        await #expect(throws: LibraryError.self) { try await adult.categories() }
        // The write that was in flight was committed.
        let reopened = try await store.openAdultLibrary()
        #expect(try await reopened.categories().map(\.name) == ["Written"])
    }

    @Test("a close during an open in flight leaves no open pool behind")
    func closeDuringAnOpen() async throws {
        for round in 0..<50 {
            let (store, _, _, root) = try makeStore()
            defer { try? FileManager.default.removeItem(at: root) }
            let opening = Task { try await store.createAdultLibrary() }
            let closing = Task { try await store.closeAdultLibrary() }
            let opened = try await opening.value
            try await closing.value

            // Whichever came first, there is at most one open pool: either
            // the close came after the open and `opened` is closed, or it
            // came before and `opened` is the store's open library.
            if opened.isClosed {
                #expect(await store.adultLibraryIsClosed, "round \(round)")
            } else {
                #expect(try await store.openAdultLibrary() === opened, "round \(round)")
            }
            try await store.closeAdultLibrary()
            #expect(opened.isClosed, "round \(round)")
            #expect(await store.adultLibraryIsClosed, "round \(round)")
        }
    }

    @Test("the normal library is never closed")
    func normalIsUntouched() async throws {
        let (store, _, _, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let normal = try await store.openNormal()
        _ = try await store.createAdultLibrary()

        try await store.closeAdultLibrary()
        try await store.deleteAdultLibraryFiles()

        #expect(try await store.openNormal() === normal)
        #expect(!normal.isClosed)
        _ = try await normal.createCategory(name: "Still here", icon: .globe)
    }

    @Test("turning-on's creation makes the file and closes it; an existing file is not opened")
    func createFileIfMissing() async throws {
        let (store, _, _, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.createAdultLibraryFileIfMissing()

        #expect(store.adultLibraryExists)
        #expect(await store.adultLibraryIsClosed)
        #expect(await store.adultLibraryObjectIsReleased)
        // An existing file, here one that is no database, is left alone.
        let (second, secondDirectory, _, secondRoot) = try makeStore()
        defer { try? FileManager.default.removeItem(at: secondRoot) }
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let garbage = Data(repeating: 0x41, count: 4096)
        try garbage.write(to: secondDirectory.appending(path: "adult.sqlite"))
        try await second.createAdultLibraryFileIfMissing()
        #expect(try Data(contentsOf: secondDirectory.appending(path: "adult.sqlite")) == garbage)
        #expect(adultFiles(secondDirectory) == ["adult.sqlite"])
    }

    @Test("deleting closes by the same path, then the files are gone and the held object creates nothing")
    func deleteClosesThePool() async throws {
        let (store, directory, _, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let adult = try await store.createAdultLibrary()
        _ = try await adult.createCategory(name: "Held", icon: .heart)

        try await store.deleteAdultLibraryFiles()

        #expect(adult.isClosed)
        #expect(adultFiles(directory).isEmpty)
        #expect(await store.adultLibraryIsClosed)
        await #expect(throws: LibraryError.self) { try await adult.categories() }
        await #expect(throws: LibraryError.self) { try await adult.createCategory(name: "Late", icon: .heart) }
        #expect(adultFiles(directory).isEmpty)
        // A library created afterwards is another object, and empty.
        let fresh = try await store.createAdultLibrary()
        #expect(fresh !== adult)
        #expect(try await fresh.categories().isEmpty)
    }

    @Test("deleting a library that was closed by a lock removes its files")
    func deleteAfterClose() async throws {
        let (store, directory, _, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let adult = try await store.createAdultLibrary()
        _ = try await adult.createCategory(name: "Held", icon: .heart)
        try await store.closeAdultLibrary()

        try await store.deleteAdultLibraryFiles()

        #expect(adultFiles(directory).isEmpty)
        await #expect(throws: LibraryError.self) { try await adult.categories() }
        #expect(adultFiles(directory).isEmpty)
    }

    @Test("deleting with nothing there is not a failure, and creates nothing")
    func deleteNothing() async throws {
        let (store, directory, cacheRoot, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.deleteAdultLibraryFiles()
        try store.deleteAdultImageCache()

        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(!FileManager.default.fileExists(atPath: cacheRoot.path))
    }

    @Test("the adult image cache is removed, and the normal one is not")
    func deleteImageCache() async throws {
        let (store, _, cacheRoot, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let normal = try await store.openNormal()
        let adult = try await store.createAdultLibrary()
        #expect(await normal.imageCache.store(Data([1]), for: "https://example.invalid/n.png"))
        #expect(await adult.imageCache.store(Data([2]), for: "https://example.invalid/a.png"))

        try store.deleteAdultImageCache()

        #expect(try FileManager.default.contentsOfDirectory(atPath: cacheRoot.path) == ["normal"])
        #expect(await normal.imageCache.size() == 1)
    }

    @Test("a file that cannot be removed fails the deletion with a storage error that names no path")
    func deleteFails() async throws {
        let (store, directory, _, root) = try makeStore()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: root)
        }
        _ = try await store.createAdultLibrary()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)

        do {
            try await store.deleteAdultLibraryFiles()
            Issue.record("the deletion did not fail")
        } catch let error as LibraryError {
            guard case .storage(let text) = error else {
                Issue.record("\(error)")
                return
            }
            #expect(!text.contains("/"), "the error names a path: \(text)")
            #expect(!text.contains("adult"), "the error names the partition's file: \(text)")
        }
        #expect(store.adultLibraryExists)
    }
}
