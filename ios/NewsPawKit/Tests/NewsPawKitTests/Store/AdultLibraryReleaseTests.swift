import Foundation
@testable import NewsPawKit
import Testing

/// RD18 decisions 4 and 9, at the store: the adult library is held weakly
/// after a release, a living object is given out again, and deleting closes
/// the connections before the files go.
@Suite("LibraryStore: releasing and deleting the adult library")
struct AdultLibraryReleaseTests {
    private func makeStore() throws -> (store: LibraryStore, directory: URL, cacheRoot: URL, root: URL) {
        let root = try makeTemporaryDirectory()
        let directory = root.appending(path: "Libraries", directoryHint: .isDirectory)
        let cacheRoot = root.appending(path: "Images", directoryHint: .isDirectory)
        return (LibraryStore(directory: directory, cacheRoot: cacheRoot), directory, cacheRoot, root)
    }

    private func adultFiles(_ directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix("adult") }.sorted()
    }

    @Test("a store that never opened the adult library reports it released")
    func neverOpened() async throws {
        let (store, _, _, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await store.openNormal()

        #expect(await store.adultLibraryIsReleased)
        await store.releaseAdultLibrary()
        #expect(await store.adultLibraryIsReleased)
    }

    @Test("criterion 7: a released library is gone when its last reference is, and its file can be opened again")
    func releasedLibraryIsGone() async throws {
        let (store, _, _, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var adult: Library? = try await store.createAdultLibrary()
        _ = try await adult?.createCategory(name: "Kept", icon: .heart)
        #expect(!(await store.adultLibraryIsReleased))

        await store.releaseAdultLibrary()
        // Held by this test only.
        #expect(!(await store.adultLibraryIsReleased))
        adult = nil

        #expect(await waitForRelease(store))
        let reopened = try await store.openAdultLibrary()
        #expect(try await reopened.categories().map(\.name) == ["Kept"])
    }

    @Test("an open while the released library still lives returns that object, and holds it again")
    func livingObjectIsReused() async throws {
        let (store, _, _, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var first: Library? = try await store.createAdultLibrary()
        await store.releaseAdultLibrary()

        var second: Library? = try await store.openAdultLibrary()

        #expect(second === first)
        // The store holds it strongly again: dropping every other reference
        // does not release it.
        first = nil
        second = nil
        try await Task.sleep(for: .milliseconds(50))
        #expect(!(await store.adultLibraryIsReleased))
        await store.releaseAdultLibrary()
        #expect(await waitForRelease(store))
    }

    @Test("the normal library is never released")
    func normalIsUntouched() async throws {
        let (store, _, _, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let normal = try await store.openNormal()
        _ = try await store.createAdultLibrary()

        await store.releaseAdultLibrary()
        try await store.deleteAdultLibraryFiles()

        #expect(try await store.openNormal() === normal)
        _ = try await normal.createCategory(name: "Still here", icon: .globe)
    }

    @Test("a release during an open in flight leaves no second pool behind")
    func releaseDuringAnOpen() async throws {
        for round in 0..<50 {
            let (store, _, _, root) = try makeStore()
            defer { try? FileManager.default.removeItem(at: root) }
            // The tasks' handles would hold the library; they end with
            // this call.
            var opened: Library? = try await Self.openWhileReleasing(store)

            // Whichever came first: an open now is the same object while it
            // lives, and after a release and the last reference it is gone.
            let again = try await store.openAdultLibrary()
            #expect(again === opened, "round \(round)")
            await store.releaseAdultLibrary()
            opened = nil
            _ = consume again
            #expect(await waitForRelease(store), "round \(round)")
        }
    }

    private static func openWhileReleasing(_ store: LibraryStore) async throws -> Library {
        let opening = Task { try await store.createAdultLibrary() }
        let releasing = Task { await store.releaseAdultLibrary() }
        let opened = try await opening.value
        await releasing.value
        return opened
    }

    @Test("turning-on's creation makes the file and releases it; an existing file is not opened")
    func createFileIfMissing() async throws {
        let (store, directory, _, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.createAdultLibraryFileIfMissing()

        #expect(store.adultLibraryExists)
        #expect(await waitForRelease(store))
        // An existing file, here one that is no database, is left alone.
        let (second, secondDirectory, _, secondRoot) = try makeStore()
        defer { try? FileManager.default.removeItem(at: secondRoot) }
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let garbage = Data(repeating: 0x41, count: 4096)
        try garbage.write(to: secondDirectory.appending(path: "adult.sqlite"))
        try await second.createAdultLibraryFileIfMissing()
        #expect(try Data(contentsOf: secondDirectory.appending(path: "adult.sqlite")) == garbage)
        #expect(adultFiles(secondDirectory) == ["adult.sqlite"])
        _ = directory
    }

    @Test("assumption A3: deleting waits for the read and the write in flight, then the held object fails and the files are gone")
    func deleteClosesThePool() async throws {
        let (store, directory, _, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let adult = try await store.createAdultLibrary()
        _ = try await adult.createCategory(name: "Held", icon: .heart)
        #expect(adultFiles(directory).contains("adult.sqlite-wal"))
        // A read and a write that take a while, started before the delete.
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

        try await store.deleteAdultLibraryFiles()
        let deleted = Date()

        #expect(try await reading.value <= deleted)
        #expect(try await writing.value <= deleted)
        #expect(adultFiles(directory).isEmpty)
        #expect(await store.adultLibraryIsReleased)
        await #expect(throws: LibraryError.self) { try await adult.categories() }
        await #expect(throws: LibraryError.self) { try await adult.createCategory(name: "Late", icon: .heart) }
        #expect(adultFiles(directory).isEmpty)
        // A library created afterwards is another object, and empty.
        let fresh = try await store.createAdultLibrary()
        #expect(fresh !== adult)
        #expect(try await fresh.categories().isEmpty)
    }

    @Test("deleting a released library that still lives closes it too")
    func deleteAfterRelease() async throws {
        let (store, directory, _, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let adult = try await store.createAdultLibrary()
        _ = try await adult.createCategory(name: "Held", icon: .heart)
        await store.releaseAdultLibrary()

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
