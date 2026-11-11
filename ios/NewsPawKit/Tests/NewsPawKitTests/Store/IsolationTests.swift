import Foundation
import GRDB
@testable import NewsPawKit
import Testing

@Suite("Partition isolation")
struct IsolationTests {
    // MARK: - Criterion 6: addresses

    @Test("a source address is unique inside a library")
    func duplicateAddressRefused() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let library = try await LibraryStore(directory: directory, now: clock.now).openNormal()
        let world = try await library.createCategory(name: "World", icon: .globe)
        let tech = try await library.createCategory(name: "Tech", icon: .cpu)
        let first = Sample.source(in: world.id, url: "https://example.com/feed", at: clock.now())
        try await library.insert(first)

        // Same address, another category of the same library.
        let second = Sample.source(in: tech.id, url: "https://example.com/feed", name: "Again", at: clock.now())
        await #expect(throws: LibraryError.duplicateAddress) { try await library.insert(second) }

        #expect(try await library.sources() == [first])
        // A repeated identifier is a different failure, not a duplicate address.
        var sameID = Sample.source(in: tech.id, url: "https://example.com/other", at: clock.now())
        sameID.id = first.id
        let error = await #expect(throws: LibraryError.self) { try await library.insert(sameID) }
        #expect(error != .duplicateAddress)
    }

    @Test("the same address can be stored in both libraries")
    func sameAddressInBothLibraries() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let store = LibraryStore(directory: directory, now: clock.now)
        let normal = try await store.openNormal()
        let adult = try await store.createAdultLibrary()
        let normalCategory = try await normal.createCategory(name: "World", icon: .globe)
        let adultCategory = try await adult.createCategory(name: "World", icon: .globe)
        let address = "https://example.com/feed"

        try await normal.insert(Sample.source(in: normalCategory.id, url: address, at: clock.now()))
        try await adult.insert(Sample.source(in: adultCategory.id, url: address, at: clock.now()))

        #expect(try await normal.sources().map(\.url) == [address])
        #expect(try await adult.sources().map(\.url) == [address])
    }

    // MARK: - Criterion 7: the normal library never returns adult rows

    @Test("nothing asked of the normal library returns a row of the adult library")
    func normalLibraryNeverReturnsAdultRows() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let store = LibraryStore(directory: directory, now: clock.now)
        let normal = try await store.openNormal()
        let adult = try await store.createAdultLibrary()

        let normalCategory = try await normal.createCategory(name: "Normal category", icon: .globe)
        try await Sample.fill(normal, category: normalCategory.id, prefix: "normal", at: clock.now())
        var adultCategories: [NewsPawKit.Category] = []
        for name in ["Adult one", "Adult two"] {
            let category = try await adult.createCategory(name: name, icon: .heart)
            try await Sample.fill(adult, category: category.id, prefix: "adult-\(name.suffix(3))", at: clock.now())
            adultCategories.append(category)
        }
        // The adult library really holds categories, sources and articles.
        #expect(try await rowCounts(adult) == ["category": 2, "source": 4, "article": 8, "article_body": 8, "seen": 4])
        let adultSources = try await adult.sources()
        let adultArticles = try await adult.articles()
        let adultIDs = Set(adultCategories.map(\.id.databaseKey) + adultSources.map(\.id.databaseKey) + adultArticles.map(\.id.databaseKey))

        // Everything the normal library answers.
        let categories = try await normal.categories()
        let sources = try await normal.sources()
        let articles = try await normal.articles()
        #expect(categories.map(\.name) == ["Normal category"])
        #expect(sources.count == 2 && sources.allSatisfy { $0.name.hasPrefix("normal") })
        #expect(articles.count == 4 && articles.allSatisfy { $0.title?.hasPrefix("normal") == true })
        #expect(try await rowCounts(normal) == ["category": 1, "source": 2, "article": 4, "article_body": 4, "seen": 2])
        let normalIDs = try await normal.pool.read { db in
            try identifierColumns.reduce(into: Set<String>()) { ids, entry in
                ids.formUnion(try String.fetchAll(db, sql: "SELECT \(entry.column) FROM \(entry.table)"))
            }
        }
        #expect(normalIDs.isDisjoint(with: adultIDs))
        let normalText = try await normal.pool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM category UNION ALL SELECT name FROM source UNION ALL SELECT title FROM article")
        }
        #expect(normalText.allSatisfy { !$0.lowercased().contains("adult") })

        // Naming an adult category to the normal library finds nothing and changes nothing.
        let adultCategory = adultCategories[0]
        await #expect(throws: LibraryError.unknownCategory) { try await normal.renameCategory(adultCategory.id, to: "Taken") }
        await #expect(throws: LibraryError.unknownCategory) { try await normal.setCategoryIcon(adultCategory.id, to: .star) }
        await #expect(throws: LibraryError.unknownCategory) { try await normal.deleteCategory(adultCategory.id, sources: .deleteSources) }
        await #expect(throws: LibraryError.invalidMoveTarget) {
            try await normal.deleteCategory(normalCategory.id, sources: .move(to: adultCategory.id))
        }
        await #expect(throws: LibraryError.invalidOrder) {
            try await normal.reorderCategories([normalCategory.id] + adultCategories.map(\.id))
        }
        #expect(try await adult.categories() == adultCategories)
        #expect(try await rowCounts(adult) == ["category": 2, "source": 4, "article": 8, "article_body": 8, "seen": 4])
    }

    // MARK: - Criterion 7: no connection can attach another database

    @Test("ATTACH fails on a library's writer and on its readers")
    func attachIsDisabled() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory)
        let normal = try await store.openNormal()
        let adult = try await store.createAdultLibrary()
        _ = try await adult.createCategory(name: "Adult", icon: .heart)
        let adultPath = store.fileURL(for: .adult).path
        let normalPath = store.fileURL(for: .normal).path

        let writerError = await #expect(throws: DatabaseError.self) {
            try await normal.pool.writeWithoutTransaction { db in
                try db.execute(sql: "ATTACH DATABASE ? AS other", arguments: [adultPath])
            }
        }
        let readerError = await #expect(throws: DatabaseError.self) {
            try await normal.pool.read { db in
                try db.execute(sql: "ATTACH DATABASE ? AS other", arguments: [adultPath])
            }
        }
        // The adult library's connections are prepared the same way.
        let adultWriterError = await #expect(throws: DatabaseError.self) {
            try await adult.pool.writeWithoutTransaction { db in
                try db.execute(sql: "ATTACH DATABASE ? AS other", arguments: [normalPath])
            }
        }
        for error in [writerError, readerError, adultWriterError] {
            #expect(error?.message?.contains("too many attached databases") == true, "\(String(describing: error))")
        }

        // Control: the same statement works on a connection without the
        // limit, so the failures above are the library's doing.
        let control = try DatabaseQueue()
        try await control.writeWithoutTransaction { db in
            try db.execute(sql: "ATTACH DATABASE ? AS other", arguments: [adultPath])
            #expect(try String.fetchAll(db, sql: "SELECT name FROM other.category") == ["Adult"])
            try db.execute(sql: "DETACH DATABASE other")
        }
    }

    @Test("ATTACH fails on every reader connection of the pool")
    func attachIsDisabledOnConcurrentReaders() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try await LibraryStore(directory: directory).openNormal()

        // Several simultaneous reads make the pool open several reader connections.
        let failures = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    do {
                        try await library.pool.read { db in
                            Thread.sleep(forTimeInterval: 0.05)
                            try db.execute(sql: "ATTACH DATABASE ':memory:' AS other")
                        }
                        return false
                    } catch {
                        return true
                    }
                }
            }
            return await group.reduce(into: [Bool]()) { $0.append($1) }
        }

        #expect(failures == Array(repeating: true, count: 8))
    }
}
