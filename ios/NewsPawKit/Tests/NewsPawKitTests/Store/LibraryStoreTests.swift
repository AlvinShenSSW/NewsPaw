import Foundation
@testable import NewsPawKit
import Testing

@Suite("LibraryStore")
struct LibraryStoreTests {
    private func fileExists(_ directory: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: name).path)
    }

    @Test("a fresh directory gets normal.sqlite and no adult file")
    func freshInstallCreatesNormalOnly() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // The store creates its directory, as the app's does on first launch.
        let directory = root.appending(path: "Libraries", directoryHint: .isDirectory)
        let store = LibraryStore(directory: directory)

        let library = try await store.openNormal()

        #expect(library.partition == .normal)
        #expect(fileExists(directory, "normal.sqlite"))
        #expect(!fileExists(directory, "adult.sqlite"))
        #expect(!store.adultLibraryExists)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.allSatisfy { $0.hasPrefix("normal.sqlite") }, "unexpected files: \(names)")
        #expect(try await library.categories().isEmpty)
    }

    @Test("opening the adult library before it is created fails with missing and creates nothing")
    func openAdultBeforeCreationFails() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory)
        _ = try await store.openNormal()

        await #expect(throws: LibraryError.missing) { try await store.openAdultLibrary() }
        // A second attempt is not served a cached failure, and still creates nothing.
        await #expect(throws: LibraryError.missing) { try await store.openAdultLibrary() }

        #expect(!fileExists(directory, "adult.sqlite"))
        #expect(!store.adultLibraryExists)
    }

    @Test("creating the adult library makes both files exist")
    func createAdultLibrary() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory)
        let normal = try await store.openNormal()

        let adult = try await store.createAdultLibrary()

        #expect(adult.partition == .adult)
        #expect(adult !== normal)
        #expect(fileExists(directory, "normal.sqlite"))
        #expect(fileExists(directory, "adult.sqlite"))
        #expect(store.adultLibraryExists)
        #expect(try await store.openAdultLibrary() === adult)
        #expect(try await store.createAdultLibrary() === adult)
    }

    @Test("opening the same partition again returns the same library")
    func reopenReturnsSameInstance() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory)

        let first = try await store.openNormal()
        let second = try await store.openNormal()

        #expect(first === second)
    }

    @Test("simultaneous first opens share one library")
    func concurrentOpensShareOneLibrary() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory)

        let libraries = try await withThrowingTaskGroup(of: Library.self) { group in
            for _ in 0..<16 {
                group.addTask { try await store.openNormal() }
            }
            return try await group.reduce(into: [Library]()) { $0.append($1) }
        }

        #expect(libraries.count == 16)
        #expect(libraries.allSatisfy { $0 === libraries[0] })
        // One pool: writes through the shared library succeed.
        _ = try await libraries[0].createCategory(name: "World", icon: .globe)
    }

    @Test("a new store on the same directory reads the existing data")
    func newStoreReadsExistingData() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let created = try await createCategory(in: directory, clock: clock)

        let store = LibraryStore(directory: directory, now: clock.now)
        let categories = try await store.openNormal().categories()

        #expect(categories == [created])
    }

    /// Creates a category with a store that is released when this returns.
    private func createCategory(in directory: URL, clock: TestClock) async throws -> NewsPawKit.Category {
        let store = LibraryStore(directory: directory, now: clock.now)
        return try await store.openNormal().createCategory(name: "World", icon: .globe)
    }

    @Test("a failed open is tried again on the next call")
    func failedOpenIsRetried() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "normal.sqlite")
        try Data(repeating: 0x41, count: 8192).write(to: url)
        let store = LibraryStore(directory: directory)

        await #expect(throws: LibraryError.damaged) { try await store.openNormal() }

        try FileManager.default.removeItem(at: url)
        let library = try await store.openNormal()
        #expect(try await library.categories().isEmpty)
    }

    @Test("the default directory is Libraries in Application Support")
    func defaultDirectory() {
        let directory = LibraryStore.defaultDirectory()
        #expect(directory.lastPathComponent == "Libraries")
        #expect(directory.deletingLastPathComponent() == URL.applicationSupportDirectory)
    }
}
