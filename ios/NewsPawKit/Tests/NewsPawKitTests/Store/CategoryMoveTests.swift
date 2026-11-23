import Foundation
import GRDB
@testable import NewsPawKit
import Synchronization
import Testing

/// RD19 decision 10 and criteria 10, 11 and 12 (spec N02): moving a
/// category to the other partition, in both directions, over the two
/// libraries of one store.
@Suite("Category move", .serialized)
struct CategoryMoveTests {
    /// Both libraries of one store, with a category to move in the old one:
    /// "Moving" with three sources — "Alpha" and "Gamma", whose addresses the
    /// destination does not have, and "Beta", whose address the destination
    /// has under another identifier — each with articles, bodies, a seen
    /// identifier and translations, one article read and one starred; and
    /// "Kept", another category of the old library that the move does not
    /// touch. The destination has "Elsewhere" holding Beta's twin.
    struct Fixture {
        let directory: URL
        let old: Library
        let destination: Library
        let category: UUID
        let alpha: Source
        let beta: Source
        let gamma: Source
        let kept: UUID
        let twin: Source

        /// - Parameter toAdult: the direction: the normal library is the old
        ///   one when true.
        static func make(toAdult: Bool, twin hasTwin: Bool = true) async throws -> Fixture {
            let directory = try makeTemporaryDirectory()
            let store = LibraryStore(directory: directory, cacheRoot: directory.appending(path: "Images"))
            let normal = try await store.openNormal()
            let adult = try await store.createAdultLibrary()
            let (old, destination) = toAdult ? (normal, adult) : (adult, normal)
            let now = Date()
            // The destination's own category comes first, so that a copied
            // category is placed after it.
            let elsewhere = try await destination.createCategory(name: "Elsewhere", icon: .globe)
            let category = try await old.createCategory(name: "Moving", icon: .film)
            let kept = try await old.createCategory(name: "Kept", icon: .book)
            var alpha = Sample.source(in: category.id, url: "https://alpha.example.invalid/feed", name: "Alpha", at: now)
            alpha.etag = "\"alpha-etag\""
            alpha.lastModified = "Mon, 16 Nov 2026 10:00:00 GMT"
            alpha.lastSuccessAt = now
            alpha.lastError = "timed_out"
            alpha.paused = true
            alpha.autoTranslate = .on
            alpha.bodyMode = .page
            alpha.translatePage = true
            alpha.siteURL = "https://alpha.example.invalid/"
            let beta = Sample.source(in: category.id, url: "https://beta.example.invalid/feed", name: "Beta", at: now)
            var gamma = Sample.source(in: category.id, url: "https://gamma.example.invalid/feed", name: "Gamma", at: now)
            gamma.kind = .webpage
            for source in [alpha, beta, gamma] {
                try await old.insert(source)
                try await fillArticles(old, source: source, at: now)
            }
            let keptSource = Sample.source(in: kept.id, url: "https://kept.example.invalid/feed", name: "Kept source", at: now)
            try await old.insert(keptSource)
            try await fillArticles(old, source: keptSource, at: now)
            let twin = Sample.source(in: elsewhere.id, url: beta.url, name: "Beta elsewhere", at: now)
            if hasTwin {
                try await destination.insert(twin)
            }
            try await destination.setLastRefreshAt(now)
            try await old.setLastRefreshAt(now)
            return Fixture(
                directory: directory, old: old, destination: destination, category: category.id, alpha: alpha, beta: beta, gamma: gamma,
                kept: kept.id, twin: twin
            )
        }

        /// Two articles of `source`, each with a body and a translation, a
        /// seen identifier, the first read and the second starred.
        static func fillArticles(_ library: Library, source: Source, at date: Date) async throws {
            for item in 0..<2 {
                let article = Sample.article(in: source.id, externalID: "\(source.name)-\(item)", title: "\(source.name) story \(item)", at: date)
                try await library.insert(article)
                try await library.insert(Sample.body(of: article.id, at: date))
                try await library.storeTranslations([
                    TranslationRecord(
                        articleID: article.id, locale: .simplifiedChinese, state: .done, title: "译 \(item)", excerpt: nil, failure: nil,
                        model: "m"
                    ),
                ])
                if item == 0 {
                    try await library.setRead(article.id, true)
                } else {
                    try await library.setStarred(article.id, true)
                }
            }
            try await library.insertSeen(sourceID: source.id, externalIDHash: "\(source.name)-hash", lastSeenAt: date)
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }

        func plan() async throws -> CategoryMove.Plan {
            try await CategoryMove.plan(category: category, from: old, to: destination)
        }
    }

    /// Row counts of `library` for `sources`, per table.
    static func counts(_ library: Library, of sources: [Source]) async throws -> [String: Int] {
        let keys = sources.map(\.id.databaseKey)
        let marks = keys.map { _ in "?" }.joined(separator: ", ")
        return try await library.pool.read { db in
            let arguments = StatementArguments(keys)
            return [
                "source": try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source WHERE id IN (\(marks))", arguments: arguments) ?? -1,
                "article": try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article WHERE source_id IN (\(marks))", arguments: arguments) ?? -1,
                "article_body": try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM article_body WHERE article_id IN (SELECT id FROM article WHERE source_id IN (\(marks)))",
                    arguments: arguments
                ) ?? -1,
                "seen": try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM seen WHERE source_id IN (\(marks))", arguments: arguments) ?? -1,
                "translation": try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM translation WHERE article_id IN (SELECT id FROM article WHERE source_id IN (\(marks)))",
                    arguments: arguments
                ) ?? -1,
            ]
        }
    }

    /// Every row of `library` in the tables a move touches, as text, to
    /// show that a failed step changed nothing.
    static func snapshot(_ library: Library) async throws -> [String] {
        try await library.pool.read { db in
            var rows: [String] = []
            for table in ["category", "source", "article", "article_body", "seen", "translation", "setting"] {
                rows += try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY 1, 2").map { "\(table) \($0)" }
            }
            return rows
        }
    }

    static func orphans(_ library: Library) async throws -> Int {
        try await library.pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT (SELECT COUNT(*) FROM article WHERE source_id NOT IN (SELECT id FROM source))
                     + (SELECT COUNT(*) FROM article_body WHERE article_id NOT IN (SELECT id FROM article))
                     + (SELECT COUNT(*) FROM seen WHERE source_id NOT IN (SELECT id FROM source))
                     + (SELECT COUNT(*) FROM translation WHERE article_id NOT IN (SELECT id FROM article))
                """) ?? -1
        }
    }

    static let none = ["source": 0, "article": 0, "article_body": 0, "seen": 0, "translation": 0]

    // MARK: - Criterion 10: the plan

    @Test("criterion 10: the plan lists the sources that move and those that stay, and counts the articles deleted", arguments: [true, false])
    func plan(toAdult: Bool) async throws {
        let fixture = try await Fixture.make(toAdult: toAdult)
        defer { fixture.remove() }
        let plan = try await fixture.plan()
        #expect(plan.category.name == "Moving")
        #expect(plan.moving.map(\.name) == ["Alpha", "Gamma"])
        #expect(plan.staying.map(\.name) == ["Beta"])
        #expect(plan.articleCount == 4)
        #expect(!plan.movesNothing)
    }

    @Test("criterion 10: a category whose every source stays moves nothing and says so")
    func everySourceStays() async throws {
        let fixture = try await Fixture.make(toAdult: true)
        defer { fixture.remove() }
        // The destination gets twins of Alpha and Gamma too.
        let elsewhere = try #require(try await fixture.destination.categories().first)
        for source in [fixture.alpha, fixture.gamma] {
            try await fixture.destination.insert(Sample.source(in: elsewhere.id, url: source.url, name: "Twin", at: Date()))
        }
        let plan = try await fixture.plan()
        #expect(plan.moving.isEmpty)
        #expect(plan.movesNothing)
        let before = (try await Self.snapshot(fixture.old), try await Self.snapshot(fixture.destination))

        #expect(await CategoryMove.run(plan, from: fixture.old, to: fixture.destination) == .nothingToMove)

        #expect(try await Self.snapshot(fixture.old) == before.0)
        #expect(try await Self.snapshot(fixture.destination) == before.1)
    }

    @Test("criterion 10: a source whose address is in the destination under the same identifier — an interrupted move — counts as moved")
    func interruptedMoveCountsAsMoved() async throws {
        let fixture = try await Fixture.make(toAdult: false)
        defer { fixture.remove() }
        // A copy of Alpha with its own identifier is already there.
        try await CategoryMove.Hooks.failingDeletion(fixture)
        let plan = try await fixture.plan()
        #expect(plan.moving.map(\.name) == ["Alpha", "Gamma"])
        #expect(plan.staying.map(\.name) == ["Beta"])
    }

    @Test("an unknown category cannot be planned")
    func unknownCategory() async throws {
        let fixture = try await Fixture.make(toAdult: true)
        defer { fixture.remove() }
        await #expect(throws: LibraryError.unknownCategory) {
            try await CategoryMove.plan(category: UUID(), from: fixture.old, to: fixture.destination)
        }
    }

    // MARK: - Criterion 11: after a move

    @Test("criterion 11: the destination holds the category and the moved sources with their options and no collection state; the old library holds no row of them", arguments: [true, false])
    func moved(toAdult: Bool) async throws {
        let fixture = try await Fixture.make(toAdult: toAdult)
        defer { fixture.remove() }
        #expect(await fixture.old.imageCache.store(Data([1, 2, 3]), for: "https://alpha.example.invalid/picture.png"))
        let keptBefore = try await Self.counts(fixture.old, of: [try #require(try await fixture.old.sources().first { $0.name == "Kept source" })])

        let outcome = await CategoryMove.run(try await fixture.plan(), from: fixture.old, to: fixture.destination)

        #expect(outcome == .moved(staying: 1, categoryRemoved: false))
        // The old library: no row of the moved sources, their articles,
        // bodies, seen identifiers or translations; the category holds
        // exactly the staying source.
        #expect(try await Self.counts(fixture.old, of: [fixture.alpha, fixture.gamma]) == Self.none)
        #expect(try await Self.orphans(fixture.old) == 0)
        #expect(try await fixture.old.sources().filter { $0.categoryID == fixture.category }.map(\.name) == ["Beta"])
        #expect(try await fixture.old.categories().map(\.name) == ["Moving", "Kept"])
        // The other category is untouched.
        let keptSource = try #require(try await fixture.old.sources().first { $0.name == "Kept source" })
        #expect(try await Self.counts(fixture.old, of: [keptSource]) == keptBefore)

        // The destination: the category, placed last, with the moved
        // sources, their options kept, without validators, last success or
        // error, and without articles; its refresh time removed.
        let categories = try await fixture.destination.categories()
        #expect(categories.map(\.name) == ["Elsewhere", "Moving"])
        let copied = try #require(categories.last)
        #expect(copied.id == fixture.category)
        #expect(copied.icon == .film)
        let sources = try await fixture.destination.sources().filter { $0.categoryID == fixture.category }.sorted { $0.name < $1.name }
        #expect(sources.map(\.id) == [fixture.alpha.id, fixture.gamma.id])
        let alpha = try #require(sources.first)
        #expect(alpha.url == fixture.alpha.url)
        #expect(alpha.paused && alpha.autoTranslate == .on && alpha.bodyMode == .page && alpha.translatePage)
        #expect(alpha.siteURL == fixture.alpha.siteURL)
        #expect(alpha.etag == nil && alpha.lastModified == nil && alpha.lastSuccessAt == nil && alpha.lastError == nil)
        #expect(sources.last?.kind == .webpage)
        #expect(try await Self.counts(fixture.destination, of: [fixture.alpha, fixture.gamma]) == ["source": 2, "article": 0, "article_body": 0, "seen": 0, "translation": 0])
        #expect(try await fixture.destination.lastRefreshAt() == nil)
        // The twin stays where it was.
        #expect(try await fixture.destination.sources().contains { $0.id == fixture.twin.id && $0.name == "Beta elsewhere" })
        // The destination collects the moved feed sources.
        #expect(try await fixture.destination.refreshTargets(.category(fixture.category)).isEmpty, "Alpha is paused and Gamma a web page")

        // The old image cache is cleared when the app asks.
        await CategoryMove.clearOldCache(from: fixture.old)
        #expect(await fixture.old.imageCache.size() == 0)
    }

    @Test("criterion 11: when no source stays, the category leaves the old library", arguments: [true, false])
    func categoryLeaves(toAdult: Bool) async throws {
        let fixture = try await Fixture.make(toAdult: toAdult, twin: false)
        defer { fixture.remove() }

        let outcome = await CategoryMove.run(try await fixture.plan(), from: fixture.old, to: fixture.destination)

        #expect(outcome == .moved(staying: 0, categoryRemoved: true))
        #expect(try await fixture.old.categories().map(\.name) == ["Kept"])
        #expect(try await Self.counts(fixture.old, of: [fixture.alpha, fixture.beta, fixture.gamma]) == Self.none)
        #expect(try await Self.orphans(fixture.old) == 0)
        let moved = try await fixture.destination.sources().filter { $0.categoryID == fixture.category }
        #expect(Set(moved.map(\.id)) == [fixture.alpha.id, fixture.beta.id, fixture.gamma.id])
        // A feed source that is not paused is collected there.
        #expect(try await fixture.destination.refreshTargets(.category(fixture.category)) == [fixture.beta.id])
    }

    @Test("RD25 with RD19: after a move, search_text in both libraries equals its derivation; with sources left behind and without", arguments: [
        (true, true), (true, false), (false, true), (false, false),
    ])
    func searchIndexAfterAMove(toAdult: Bool, leavesSourcesBehind: Bool) async throws {
        let fixture = try await Fixture.make(toAdult: toAdult, twin: leavesSourcesBehind)
        defer { fixture.remove() }
        let before = (
            try await expectSearchTextMatchesDerivation(fixture.old, "old library before the move"),
            try await expectSearchTextMatchesDerivation(fixture.destination, "destination before the move")
        )
        #expect(before.0 > 0, "the fixture's articles and translations are indexed")

        let outcome = await CategoryMove.run(try await fixture.plan(), from: fixture.old, to: fixture.destination)

        #expect(outcome == .moved(staying: leavesSourcesBehind ? 1 : 0, categoryRemoved: !leavesSourcesBehind))
        let after = (
            try await expectSearchTextMatchesDerivation(fixture.old, "old library after the move"),
            try await expectSearchTextMatchesDerivation(fixture.destination, "destination after the move")
        )
        // Each moved source took two articles with a title and a done
        // translation each (four rows) out of the old index; the move copies
        // no article, so the destination's index is unchanged.
        let movedSources = leavesSourcesBehind ? 2 : 3
        #expect(after.0 == before.0 - movedSources * 4)
        #expect(after.1 == before.1)
        // A title of a moved source is no longer found in the old library,
        // and a staying one still is.
        let alphaRows = try await fixture.old.pool.read { db in
            try storedSearchText(db).filter { $0.text.contains(SearchQuery.fold("Alpha story")) }.count
        }
        #expect(alphaRows == 0)
        if leavesSourcesBehind {
            let betaRows = try await fixture.old.pool.read { db in
                try storedSearchText(db).filter { $0.text.contains(SearchQuery.fold("Beta story")) }.count
            }
            #expect(betaRows == 2)
        }
    }

    @Test("criterion 11: a category without sources moves")
    func emptyCategoryMoves() async throws {
        let fixture = try await Fixture.make(toAdult: true)
        defer { fixture.remove() }
        let empty = try await fixture.old.createCategory(name: "Empty", icon: .star)
        let plan = try await CategoryMove.plan(category: empty.id, from: fixture.old, to: fixture.destination)
        #expect(!plan.movesNothing)

        #expect(await CategoryMove.run(plan, from: fixture.old, to: fixture.destination) == .moved(staying: 0, categoryRemoved: true))

        #expect(!(try await fixture.old.categories().contains { $0.id == empty.id }))
        #expect(try await fixture.destination.categories().contains { $0.id == empty.id && $0.name == "Empty" })
    }

    @Test("a source whose address was taken in the destination after the plan was read stays")
    func newTwinStays() async throws {
        let fixture = try await Fixture.make(toAdult: true)
        defer { fixture.remove() }
        let plan = try await fixture.plan()
        let elsewhere = try #require(try await fixture.destination.categories().first)
        try await fixture.destination.insert(Sample.source(in: elsewhere.id, url: fixture.gamma.url, name: "New twin", at: Date()))

        #expect(await CategoryMove.run(plan, from: fixture.old, to: fixture.destination) == .moved(staying: 2, categoryRemoved: false))

        #expect(try await fixture.old.sources().filter { $0.categoryID == fixture.category }.map(\.name) == ["Beta", "Gamma"])
        #expect(try await fixture.destination.sources().filter { $0.categoryID == fixture.category }.map(\.id) == [fixture.alpha.id])
    }

    // MARK: - Criterion 12: failures and cancellation

    @Test("criterion 12: a failure of the copy changes nothing in either library", arguments: [true, false])
    func copyFails(toAdult: Bool) async throws {
        let fixture = try await Fixture.make(toAdult: toAdult)
        defer { fixture.remove() }
        let before = (try await Self.snapshot(fixture.old), try await Self.snapshot(fixture.destination))

        let outcome = await CategoryMove.perform(
            try await fixture.plan(), from: fixture.old, to: fixture.destination, hooks: CategoryMove.Hooks(failing: .copy)
        )

        #expect(outcome == .notMoved)
        #expect(try await Self.snapshot(fixture.old) == before.0)
        #expect(try await Self.snapshot(fixture.destination) == before.1)
    }

    @Test("criterion 12: a failure of the deletion leaves the category in both; moving again finishes with nothing lost", arguments: [true, false])
    func deletionFailsThenMoveAgain(toAdult: Bool) async throws {
        let fixture = try await Fixture.make(toAdult: toAdult)
        defer { fixture.remove() }
        let oldBefore = try await Self.snapshot(fixture.old)

        let outcome = await CategoryMove.perform(
            try await fixture.plan(), from: fixture.old, to: fixture.destination, hooks: CategoryMove.Hooks(failing: .deletion)
        )

        #expect(outcome == .copiedNotRemoved)
        // The old library is unchanged; the destination holds the copies.
        #expect(try await Self.snapshot(fixture.old) == oldBefore)
        #expect(try await fixture.destination.sources().filter { $0.categoryID == fixture.category }.map(\.id).sorted { $0.uuidString < $1.uuidString }
            == [fixture.alpha.id, fixture.gamma.id].sorted { $0.uuidString < $1.uuidString })

        // Moving again: the copies count as moved, and the move finishes.
        let again = try await fixture.plan()
        #expect(again.moving.map(\.name) == ["Alpha", "Gamma"])
        #expect(again.staying.map(\.name) == ["Beta"])
        #expect(await CategoryMove.run(again, from: fixture.old, to: fixture.destination) == .moved(staying: 1, categoryRemoved: false))
        #expect(try await Self.counts(fixture.old, of: [fixture.alpha, fixture.gamma]) == Self.none)
        let copies = try await fixture.destination.sources().filter { $0.categoryID == fixture.category }
        #expect(copies.count == 2)
        #expect(try await fixture.destination.categories().filter { $0.id == fixture.category }.count == 1)
    }

    @Test("criterion 12: cancelling the caller inside the copy, between the steps or inside the deletion changes nothing of the move", arguments: [
        CancelPoint.insideCopy, .betweenSteps, .insideDeletion,
    ])
    func cancelledCaller(at point: CancelPoint) async throws {
        let fixture = try await Fixture.make(toAdult: point != .betweenSteps)
        defer { fixture.remove() }
        let plan = try await fixture.plan()
        let reached = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        let between = Signal()
        var hooks = CategoryMove.Hooks()
        switch point {
        case .insideCopy, .insideDeletion:
            let step: CategoryMove.Step = point == .insideCopy ? .copy : .deletion
            // Holds the step's transaction until the test lets it go.
            hooks.inside = { current in
                guard current == step else { return }
                reached.withLock { $0 = true }
                release.wait()
            }
        case .betweenSteps:
            hooks.betweenSteps = {
                reached.withLock { $0 = true }
                await between.wait()
            }
        }
        let old = fixture.old
        let destination = fixture.destination
        let caller = Task { await CategoryMove.perform(plan, from: old, to: destination, hooks: hooks) }
        let deadline = ContinuousClock.now + .seconds(60)
        while !reached.withLock({ $0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(reached.withLock { $0 })

        caller.cancel()
        // The caller's cancellation has reached whatever it reaches.
        try await Task.sleep(for: .milliseconds(100))
        release.signal()
        between.fire()

        #expect(await caller.value == .moved(staying: 1, categoryRemoved: false))
        #expect(try await Self.counts(fixture.old, of: [fixture.alpha, fixture.gamma]) == Self.none)
        #expect(try await fixture.destination.sources().filter { $0.categoryID == fixture.category }.count == 2)
    }

    // MARK: - Review round 2: an edit saved after the plan was read

    @Test("a rename and a new icon saved after the plan was read move with the category; a category gone meanwhile moves nothing")
    func categoryReadAgainWhenTheMoveRuns() async throws {
        let fixture = try await Fixture.make(toAdult: false, twin: false)
        defer { fixture.remove() }
        let plan = try await fixture.plan()
        try await fixture.old.renameCategory(fixture.category, to: "Renamed")
        try await fixture.old.setCategoryIcon(fixture.category, to: .star)

        #expect(await CategoryMove.run(plan, from: fixture.old, to: fixture.destination) == .moved(staying: 0, categoryRemoved: true))

        let moved = try #require(try await fixture.destination.categories().first { $0.id == fixture.category })
        #expect(moved.name == "Renamed")
        #expect(moved.icon == .star)

        // A category deleted after its plan was read.
        let other = try await Fixture.make(toAdult: true, twin: false)
        defer { other.remove() }
        let gonePlan = try await other.plan()
        try await other.old.deleteCategory(other.category, sources: .deleteSources)
        let before = try await Self.snapshot(other.destination)
        #expect(await CategoryMove.run(gonePlan, from: other.old, to: other.destination) == .notMoved)
        #expect(try await Self.snapshot(other.destination) == before)
    }

    // MARK: - Review round 1: a refresh already running in the destination

    /// A whole-library refresh of the destination took its targets before
    /// the move and ends after it: it does not record its time, so the next
    /// entry refreshes, and that refresh collects the moved sources.
    @Test("criterion 11: a destination refresh that began before the move does not hide the moved sources from the next entry")
    @MainActor
    func olderRefreshKeepsTheInvalidation() async throws {
        let fixture = try await Fixture.make(toAdult: false, twin: false)
        defer { fixture.remove() }
        // The destination has a source of its own, whose fetch is held.
        let elsewhere = try #require(try await fixture.destination.categories().first)
        let own = Sample.source(in: elsewhere.id, url: "https://own.example.invalid/feed", name: "Own", at: Date())
        try await fixture.destination.insert(own)
        let go = Signal()
        let transport = CountingTransport { url in
            await go.wait()
            return CountingTransport.feed(url)
        }
        let refresher = Refresher(library: fixture.destination, transport: transport)
        let older = Task { try await refresher.refresh(.library) }
        let deadline = ContinuousClock.now + .seconds(60)
        while transport.inFlight < 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(transport.inFlight == 1)

        #expect(await CategoryMove.run(try await fixture.plan(), from: fixture.old, to: fixture.destination)
            == .moved(staying: 0, categoryRemoved: true))
        #expect(try await fixture.destination.lastRefreshAt() == nil)

        go.fire()
        let results = try await older.value
        #expect(results.keys.contains(own.id))
        #expect(!results.keys.contains(fixture.beta.id), "the older run took its targets before the move")
        // The older run did not record its time: the next entry is due.
        #expect(try await fixture.destination.lastRefreshAt() == nil)
        #expect(try await fixture.destination.refreshIsDue(every: .sixtyMinutes))

        // The next entry's refresh collects the moved feed source and counts.
        let next = try await refresher.refresh(.library)
        #expect(next.keys.contains(fixture.beta.id))
        #expect(transport.requests(for: fixture.beta.url) == 1)
        #expect(try await fixture.destination.lastRefreshAt() != nil)
    }

    enum CancelPoint: String, CustomTestStringConvertible, Sendable {
        case insideCopy
        case betweenSteps
        case insideDeletion

        var testDescription: String { rawValue }
    }
}

extension CategoryMove.Hooks {
    /// Runs a move of the fixture's category whose deletion fails, leaving
    /// the copies in the destination: an interrupted move.
    static func failingDeletion(_ fixture: CategoryMoveTests.Fixture) async throws {
        let outcome = await CategoryMove.perform(
            try await fixture.plan(), from: fixture.old, to: fixture.destination, hooks: CategoryMove.Hooks(failing: .deletion)
        )
        #expect(outcome == .copiedNotRemoved)
    }
}
