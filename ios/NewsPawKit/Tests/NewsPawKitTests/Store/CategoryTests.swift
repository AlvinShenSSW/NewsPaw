import Foundation
import GRDB
@testable import NewsPawKit
import Testing

@Suite("Categories")
struct CategoryTests {
    /// A library in its own temporary directory, removed by `close()`.
    struct TestLibrary {
        let directory: URL
        let clock: TestClock
        let library: Library

        static func make() async throws -> TestLibrary {
            let directory = try makeTemporaryDirectory()
            let clock = TestClock()
            let library = try await LibraryStore(directory: directory, now: clock.now).openNormal()
            return TestLibrary(directory: directory, clock: clock, library: library)
        }

        func close() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Create

    @Test("create trims the name, places the category last and stamps it")
    func create() async throws {
        let fixture = try await TestLibrary.make()
        defer { fixture.close() }
        let library = fixture.library

        let world = try await library.createCategory(name: "  World \n", icon: .globe)
        fixture.clock.advance()
        let tech = try await library.createCategory(name: "Tech", icon: .cpu)
        let duplicate = try await library.createCategory(name: "Tech", icon: .sparkles)

        #expect(world.name == "World")
        #expect(world.icon == .globe)
        #expect(world.overview == .auto)
        #expect(world.updatedAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(tech.updatedAt == fixture.clock.now())
        #expect([world, tech, duplicate].map(\.sortOrder) == [0, 1, 2])
        #expect(try await library.categories() == [world, tech, duplicate])
        try await expectIdentifiersAreLowercaseText(library)
    }

    @Test("create accepts a name of exactly the maximum length")
    func createMaximumLength() async throws {
        let fixture = try await TestLibrary.make()
        defer { fixture.close() }
        let name = String(repeating: "é", count: Library.maximumCategoryNameLength)

        let category = try await fixture.library.createCategory(name: name, icon: .folder)

        #expect(category.name == name)
    }

    @Test("create refuses an empty or over-long name and creates nothing", arguments: [
        ("", LibraryError.emptyName),
        ("   \n\t", LibraryError.emptyName),
        (String(repeating: "a", count: 101), LibraryError.nameTooLong),
    ])
    func createRefused(name: String, error: LibraryError) async throws {
        let fixture = try await TestLibrary.make()
        defer { fixture.close() }

        await #expect(throws: error) { try await fixture.library.createCategory(name: name, icon: .folder) }

        #expect(try await fixture.library.categories().isEmpty)
    }

    // MARK: - Rename and icon

    @Test("rename changes only the name and updated_at")
    func rename() async throws {
        let fixture = try await TestLibrary.make()
        defer { fixture.close() }
        let library = fixture.library
        let world = try await library.createCategory(name: "World", icon: .globe)
        let other = try await library.createCategory(name: "Other", icon: .cpu)
        fixture.clock.advance()

        try await library.renameCategory(world.id, to: " Europe ")

        let categories = try await library.categories()
        #expect(categories[0].name == "Europe")
        #expect(categories[0].iconName == "globe")
        #expect(categories[0].sortOrder == 0)
        #expect(categories[0].updatedAt == fixture.clock.now())
        #expect(categories[1] == other)
        try await expectIdentifiersAreLowercaseText(library)
    }

    @Test("rename keeps an icon this version does not know")
    func renameKeepsUnknownIcon() async throws {
        let fixture = try await TestLibrary.make()
        defer { fixture.close() }
        let library = fixture.library
        let world = try await library.createCategory(name: "World", icon: .globe)
        try await library.pool.write { db in
            try db.execute(sql: "UPDATE category SET icon = 'symbol.from.a.later.version' WHERE id = ?", arguments: [world.id.databaseKey])
        }

        try await library.renameCategory(world.id, to: "Europe")

        let category = try #require(try await library.categories().first)
        #expect(category.iconName == "symbol.from.a.later.version")
        #expect(category.icon == .folder)
    }

    @Test("rename refuses a bad name or an unknown category and changes nothing", arguments: [
        ("", false, LibraryError.emptyName),
        (String(repeating: "a", count: 101), false, LibraryError.nameTooLong),
        ("Europe", true, LibraryError.unknownCategory),
    ])
    func renameRefused(name: String, unknown: Bool, error: LibraryError) async throws {
        let fixture = try await TestLibrary.make()
        defer { fixture.close() }
        let world = try await fixture.library.createCategory(name: "World", icon: .globe)
        fixture.clock.advance()

        await #expect(throws: error) { try await fixture.library.renameCategory(unknown ? UUID() : world.id, to: name) }

        #expect(try await fixture.library.categories() == [world])
    }

    @Test("set icon changes only the icon and updated_at")
    func setIcon() async throws {
        let fixture = try await TestLibrary.make()
        defer { fixture.close() }
        let library = fixture.library
        let world = try await library.createCategory(name: "World", icon: .globe)
        fixture.clock.advance()

        try await library.setCategoryIcon(world.id, to: .newspaper)

        let category = try #require(try await library.categories().first)
        #expect(category.icon == .newspaper)
        #expect(category.iconName == "newspaper")
        #expect(category.name == "World")
        #expect(category.updatedAt == fixture.clock.now())
        await #expect(throws: LibraryError.unknownCategory) { try await library.setCategoryIcon(UUID(), to: .star) }
        try await expectIdentifiersAreLowercaseText(library)
    }

    // MARK: - Reorder

    @Test("reorder numbers the categories from 0 in the given order")
    func reorder() async throws {
        let fixture = try await TestLibrary.make()
        defer { fixture.close() }
        let library = fixture.library
        let a = try await library.createCategory(name: "A", icon: .folder)
        let b = try await library.createCategory(name: "B", icon: .folder)
        let c = try await library.createCategory(name: "C", icon: .folder)
        fixture.clock.advance()

        try await library.reorderCategories([c.id, b.id, a.id])

        let categories = try await library.categories()
        #expect(categories.map(\.id) == [c.id, b.id, a.id])
        #expect(categories.map(\.sortOrder) == [0, 1, 2])
        // B kept its place, so it is unchanged.
        #expect(categories[1] == b)
        #expect(categories[0].updatedAt == fixture.clock.now())
        #expect(categories[2].updatedAt == fixture.clock.now())
        try await expectIdentifiersAreLowercaseText(library)
    }

    @Test("reorder of an empty library with an empty list succeeds")
    func reorderEmpty() async throws {
        let fixture = try await TestLibrary.make()
        defer { fixture.close() }

        try await fixture.library.reorderCategories([])

        #expect(try await fixture.library.categories().isEmpty)
    }

    @Test("reorder refuses a list that is not a permutation and changes nothing", arguments: [
        "missing", "extra", "duplicate", "unknown", "empty",
    ])
    func reorderRefused(kind: String) async throws {
        let fixture = try await TestLibrary.make()
        defer { fixture.close() }
        let library = fixture.library
        let a = try await library.createCategory(name: "A", icon: .folder)
        let b = try await library.createCategory(name: "B", icon: .folder)
        let c = try await library.createCategory(name: "C", icon: .folder)
        let before = try await library.categories()
        let ids: [UUID] = switch kind {
        case "missing": [c.id, b.id]
        case "extra": [c.id, b.id, a.id, UUID()]
        case "duplicate": [c.id, b.id, b.id]
        case "unknown": [c.id, b.id, UUID()]
        default: []
        }
        fixture.clock.advance()

        await #expect(throws: LibraryError.invalidOrder) { try await library.reorderCategories(ids) }

        #expect(try await library.categories() == before)
    }

    // MARK: - Delete

    @Test("delete with its sources removes them with their articles, bodies and seen identifiers")
    func deleteWithSources() async throws {
        let fixture = try await TestLibrary.make()
        defer { fixture.close() }
        let library = fixture.library
        let doomed = try await library.createCategory(name: "Doomed", icon: .folder)
        let kept = try await library.createCategory(name: "Kept", icon: .folder)
        try await Sample.fill(library, category: doomed.id, prefix: "doomed", at: fixture.clock.now())
        let keptSources = try await Sample.fill(library, category: kept.id, prefix: "kept", at: fixture.clock.now())
        #expect(try await rowCounts(library) == ["category": 2, "source": 4, "article": 8, "article_body": 8, "seen": 4])

        try await library.deleteCategory(doomed.id, sources: .deleteSources)

        #expect(try await library.categories() == [kept])
        #expect(try await rowCounts(library) == ["category": 1, "source": 2, "article": 4, "article_body": 4, "seen": 2])
        #expect(try await library.sources() == keptSources.sorted { $0.url < $1.url })
        let titles = try await library.articles().compactMap(\.title)
        #expect(titles.allSatisfy { $0.hasPrefix("kept") })
        try await expectIdentifiersAreLowercaseText(library)
    }

    @Test("delete moving its sources reassigns them and stamps them")
    func deleteMovingSources() async throws {
        let fixture = try await TestLibrary.make()
        defer { fixture.close() }
        let library = fixture.library
        let old = try await library.createCategory(name: "Old", icon: .folder)
        let destination = try await library.createCategory(name: "Destination", icon: .folder)
        let moved = try await Sample.fill(library, category: old.id, prefix: "moved", at: fixture.clock.now())
        let stayed = try await Sample.fill(library, category: destination.id, prefix: "stayed", at: fixture.clock.now())
        fixture.clock.advance()

        try await library.deleteCategory(old.id, sources: .move(to: destination.id))

        #expect(try await library.categories() == [destination])
        #expect(try await rowCounts(library) == ["category": 1, "source": 4, "article": 8, "article_body": 8, "seen": 4])
        let sources = try await library.sources()
        #expect(sources.allSatisfy { $0.categoryID == destination.id })
        for source in moved {
            let stored = try #require(sources.first { $0.id == source.id })
            #expect(stored.updatedAt == fixture.clock.now())
            #expect(stored.name == source.name)
        }
        for source in stayed {
            #expect(sources.first { $0.id == source.id } == source)
        }
        try await expectIdentifiersAreLowercaseText(library)
    }

    @Test("delete refuses an unknown category or a bad destination and changes nothing", arguments: [
        "unknown category", "move to itself", "move to unknown",
    ])
    func deleteRefused(kind: String) async throws {
        let fixture = try await TestLibrary.make()
        defer { fixture.close() }
        let library = fixture.library
        let category = try await library.createCategory(name: "Full", icon: .folder)
        _ = try await library.createCategory(name: "Other", icon: .folder)
        try await Sample.fill(library, category: category.id, prefix: "full", at: fixture.clock.now())
        let categoriesBefore = try await library.categories()
        let sourcesBefore = try await library.sources()
        let countsBefore = try await rowCounts(library)
        fixture.clock.advance()

        switch kind {
        case "unknown category":
            await #expect(throws: LibraryError.unknownCategory) {
                try await library.deleteCategory(UUID(), sources: .deleteSources)
            }
            await #expect(throws: LibraryError.unknownCategory) {
                try await library.deleteCategory(UUID(), sources: .move(to: category.id))
            }
        case "move to itself":
            await #expect(throws: LibraryError.invalidMoveTarget) {
                try await library.deleteCategory(category.id, sources: .move(to: category.id))
            }
        default:
            await #expect(throws: LibraryError.invalidMoveTarget) {
                try await library.deleteCategory(category.id, sources: .move(to: UUID()))
            }
        }

        #expect(try await library.categories() == categoriesBefore)
        #expect(try await library.sources() == sourcesBefore)
        #expect(try await rowCounts(library) == countsBefore)
    }
}

@Suite("Category summaries, name rule and UI-test seeding")
struct CategorySummaryTests {
    @Test("summaries list the categories in order with their source counts")
    func summaries() async throws {
        let fixture = try await CategoryTests.TestLibrary.make()
        defer { fixture.close() }
        let library = fixture.library
        #expect(try await library.categorySummaries().isEmpty)
        let empty = try await library.createCategory(name: "Empty", icon: .folder)
        let full = try await library.createCategory(name: "Full", icon: .globe)
        try await Sample.fill(library, category: full.id, prefix: "full", at: fixture.clock.now())
        try await library.reorderCategories([full.id, empty.id])

        let summaries = try await library.categorySummaries()

        #expect(summaries.map(\.category.id) == [full.id, empty.id])
        #expect(summaries.map(\.sourceCount) == [2, 0])
        #expect(summaries.map(\.category) == (try await library.categories()))
        #expect(summaries[0].id == full.id)
    }

    @Test("the name rule refuses empty and over-long names and accepts 1 to 100 characters", arguments: [
        ("", CategoryNameProblem?.some(.empty)),
        ("   \n\t", .some(.empty)),
        ("a", nil),
        ("  World  ", nil),
        (String(repeating: "a", count: 100), nil),
        (" " + String(repeating: "é", count: 100) + " ", nil),
        (String(repeating: "a", count: 101), .some(.tooLong)),
    ])
    func nameRule(name: String, problem: CategoryNameProblem?) {
        #expect(Library.categoryNameProblem(name) == problem)
    }

    @Test("the storage operations apply the same name rule")
    func nameRuleMatchesStorage() async throws {
        let fixture = try await CategoryTests.TestLibrary.make()
        defer { fixture.close() }
        for name in ["", " ", "ok", String(repeating: "a", count: 100), String(repeating: "a", count: 101)] {
            let problem = Library.categoryNameProblem(name)
            do {
                _ = try await fixture.library.createCategory(name: name, icon: .folder)
                #expect(problem == nil)
            } catch let error as LibraryError {
                #expect(error == (problem == .empty ? .emptyName : .nameTooLong))
            }
        }
    }

    #if DEBUG
    @Test("debug seeding fills only an empty first category and does nothing without a category")
    func seeding() async throws {
        let fixture = try await CategoryTests.TestLibrary.make()
        defer { fixture.close() }
        let library = fixture.library

        try await library.insertSyntheticSourcesForUITests(count: 3)
        #expect(try await library.sources().isEmpty)

        let first = try await library.createCategory(name: "First", icon: .folder)
        let second = try await library.createCategory(name: "Second", icon: .folder)
        try await library.insertSyntheticSourcesForUITests(count: 3)
        try await library.insertSyntheticSourcesForUITests(count: 3)

        let summaries = try await library.categorySummaries()
        #expect(summaries.map(\.sourceCount) == [3, 0])
        #expect(try await library.sources().allSatisfy { $0.categoryID == first.id })
        #expect(summaries.map(\.id) == [first.id, second.id])
        try await expectIdentifiersAreLowercaseText(library)
    }
    #endif
}
