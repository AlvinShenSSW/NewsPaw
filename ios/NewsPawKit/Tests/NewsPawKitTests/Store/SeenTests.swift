import Foundation
import GRDB
@testable import NewsPawKit
import Testing

/// RD06 criterion 6: what `seen` holds and how a collection decides each
/// listed item (decision 8).
@Suite("Seen identifiers")
struct SeenTests {
    private static let day = 86_400

    private func item(_ id: String, link: String? = nil) -> String {
        "<item><guid>\(id)</guid>" + (link.map { "<link>\($0)</link>" } ?? "") + "<title>\(id)</title></item>"
    }

    /// Collects `source` from a feed of `items`, complete unless `complete`
    /// is false.
    @discardableResult
    private func collect(_ fixture: RefreshFixture, _ source: UUID, _ items: [String], complete: Bool = true) async throws -> CollectionOutcome {
        var document = rssDocument(items.joined())
        if !complete {
            // Not well-formed after the listed items: an ampersand in a title.
            document = document.replacingOccurrences(of: "</channel>", with: "<item><guid>broken</guid><title>Fish & chips</title></item></channel>")
        }
        let transport = FakeTransport.answering(body: Data(document.utf8))
        return try await FeedCollector(transport: transport).collect(source, in: fixture.library)
    }

    private func externalIDs(_ fixture: RefreshFixture, _ source: UUID) async throws -> [String] {
        try await fixture.library.articles().filter { $0.sourceID == source }.map(\.externalID).sorted()
    }

    /// The seen rows of `source`: hash → last seen.
    private func seen(_ fixture: RefreshFixture, _ source: UUID) async throws -> [String: Date] {
        try await fixture.library.pool.read { db in
            var rows: [String: Date] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT external_id_hash, last_seen_at FROM seen WHERE source_id = ?", arguments: [source.databaseKey]) {
                rows[row["external_id_hash"]] = row["last_seen_at"]
            }
            return rows
        }
    }

    /// Ages every article past 30 days and cleans up.
    private func cleanUpEverything(_ fixture: RefreshFixture) async throws {
        try await fixture.library.pool.write { db in
            try db.execute(sql: "UPDATE article SET first_seen_at = ?", arguments: [fixture.clock.now().addingTimeInterval(-31 * 86_400)])
        }
        try await fixture.library.cleanUp(keeping: .thirtyDays)
    }

    @Test("after a clean-up a feed that still lists the item inserts nothing for it and refreshes its row; a new item is inserted")
    func cleanedUpItemStaysAway() async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let source = try await fixture.addFeed("one").id
        try await collect(fixture, source, [item("a", link: "https://example.invalid/a")])
        try await cleanUpEverything(fixture)
        #expect(try await externalIDs(fixture, source).isEmpty)
        fixture.clock.advance(seconds: 3_600)

        let outcome = try await collect(fixture, source, [item("a", link: "https://example.invalid/a"), item("b", link: "https://example.invalid/b")])

        #expect(outcome == .collected(newArticles: 1, complete: true))
        #expect(try await externalIDs(fixture, source) == ["b"])
        #expect(try await seen(fixture, source) == [Library.seenHash("a"): fixture.clock.now()])
    }

    @Test("collecting unchanged items adds no seen row for an article that exists")
    func existingArticlesAddNoSeenRow() async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let source = try await fixture.addFeed("one").id
        let items = [item("a", link: "https://example.invalid/a"), item("b", link: "https://example.invalid/b"), item("c")]
        try await collect(fixture, source, items)
        fixture.clock.advance()
        #expect(try await collect(fixture, source, items) == .collected(newArticles: 0, complete: true))
        #expect(try await seen(fixture, source).isEmpty)
        #expect(try await externalIDs(fixture, source) == ["a", "b", "c"])
    }

    @Test("same link in one feed: the second item is remembered, and after a clean-up of the first neither comes back")
    func sameLinkOneFeed() async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let source = try await fixture.addFeed("one").id
        let items = [item("first", link: "https://example.invalid/shared"), item("twin", link: "https://example.invalid/shared")]
        #expect(try await collect(fixture, source, items) == .collected(newArticles: 1, complete: true))
        #expect(try await externalIDs(fixture, source) == ["first"])
        #expect(try await seen(fixture, source) == [Library.seenHash("twin"): fixture.clock.now()])

        try await cleanUpEverything(fixture)
        fixture.clock.advance(seconds: 3_600)
        #expect(try await collect(fixture, source, items) == .collected(newArticles: 0, complete: true))
        #expect(try await externalIDs(fixture, source).isEmpty)
        #expect(Set(try await seen(fixture, source).keys) == [Library.seenHash("first"), Library.seenHash("twin")])
    }

    @Test("same link in two feeds of one category: B's twin is remembered, and after A's article is cleaned up B does not insert it")
    func sameLinkTwoFeeds() async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let a = try await fixture.addFeed("a").id
        let b = try await fixture.addFeed("b").id
        try await collect(fixture, a, [item("a-item", link: "https://example.invalid/shared")])
        #expect(try await collect(fixture, b, [item("b-item", link: "https://example.invalid/shared")]) == .collected(newArticles: 0, complete: true))
        #expect(try await seen(fixture, b) == [Library.seenHash("b-item"): fixture.clock.now()])

        try await cleanUpEverything(fixture)
        fixture.clock.advance(seconds: 3_600)
        #expect(try await collect(fixture, b, [item("b-item", link: "https://example.invalid/shared")]) == .collected(newArticles: 0, complete: true))
        #expect(try await externalIDs(fixture, b).isEmpty)
        #expect(try await seen(fixture, b) == [Library.seenHash("b-item"): fixture.clock.now()])
    }

    @Test("same link when B is added (RD05's path) while A holds the article: the twin is remembered and stays away after A's clean-up")
    func sameLinkWhenAdded() async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let a = try await fixture.addFeed("a").id
        try await collect(fixture, a, [item("a-item", link: "https://feeds.example/item0")])
        // The candidate's first item links to https://feeds.example/item0.
        let b = try await fixture.library.addFeedSource(try feedCandidate(items: 2), name: "B", categoryID: fixture.categoryID)
        #expect(try await externalIDs(fixture, b) == ["item-1"])
        #expect(try await seen(fixture, b) == [Library.seenHash("item-0"): fixture.clock.now()])

        try await cleanUpEverything(fixture)
        fixture.clock.advance(seconds: 3_600)
        let relisted = [item("item-0", link: "https://feeds.example/item0"), item("item-1", link: "https://feeds.example/item1")]
        #expect(try await collect(fixture, b, relisted) == .collected(newArticles: 0, complete: true))
        #expect(try await externalIDs(fixture, b).isEmpty)
    }

    @Test("a 304 and a failed collection change no seen row")
    func notModifiedAndFailureLeaveSeen() async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let source = try await fixture.addFeed("one").id
        try await fixture.library.insertSeen(sourceID: source, externalIDHash: Library.seenHash("old"), lastSeenAt: fixture.clock.now())
        let before = try await seen(fixture, source)
        fixture.clock.advance(seconds: 40 * Self.day)
        #expect(try await FeedCollector(transport: FakeTransport.answering(status: 304)).collect(source, in: fixture.library) == .notModified)
        #expect(try await seen(fixture, source) == before)
        #expect(try await FeedCollector(transport: FakeTransport.failing(.unreachable)).collect(source, in: fixture.library) == .failed(.unreachable))
        #expect(try await seen(fixture, source) == before)
    }

    @Test("an incomplete feed refreshes the rows of the items it listed and deletes none")
    func incompleteFeed() async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let source = try await fixture.addFeed("one").id
        let start = fixture.clock.now()
        for id in ["listed", "unlisted"] {
            try await fixture.library.insertSeen(sourceID: source, externalIDHash: Library.seenHash(id), lastSeenAt: start)
        }
        fixture.clock.advance(seconds: 40 * Self.day)

        let outcome = try await collect(fixture, source, [item("listed")], complete: false)

        #expect(outcome == .collected(newArticles: 0, complete: false))
        #expect(try await seen(fixture, source) == [Library.seenHash("listed"): fixture.clock.now(), Library.seenHash("unlisted"): start])
    }

    @Test("a complete feed that no longer lists an item deletes its row when last seen more than 30 days ago; 30 days or less stays")
    func oldRowsDeleted() async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let source = try await fixture.addFeed("one").id
        let other = try await fixture.addFeed("other").id
        let now = fixture.clock.now()
        let rows: [(String, Int)] = [("older", 30 * Self.day + 1), ("exactly", 30 * Self.day), ("younger", 29 * Self.day)]
        for (id, age) in rows {
            try await fixture.library.insertSeen(sourceID: source, externalIDHash: Library.seenHash(id), lastSeenAt: now.addingTimeInterval(-TimeInterval(age)))
        }
        try await fixture.library.insertSeen(sourceID: other, externalIDHash: Library.seenHash("older"), lastSeenAt: now.addingTimeInterval(-TimeInterval(90 * Self.day)))

        try await collect(fixture, source, [item("new")])

        #expect(Set(try await seen(fixture, source).keys) == [Library.seenHash("exactly"), Library.seenHash("younger")])
        #expect(try await seen(fixture, other).count == 1, "another source's rows are not touched")
    }

    @Test("a feed that still lists the item after 40 days of 304 keeps its row and still does not insert it")
    func listedAfterFortyDaysOfNotModified() async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let source = try await fixture.addFeed("one").id
        try await collect(fixture, source, [item("kept", link: "https://example.invalid/kept")])
        try await cleanUpEverything(fixture)
        for _ in 0..<40 {
            fixture.clock.advance(seconds: Self.day)
            #expect(try await FeedCollector(transport: FakeTransport.answering(status: 304)).collect(source, in: fixture.library) == .notModified)
        }

        let outcome = try await collect(fixture, source, [item("kept", link: "https://example.invalid/kept")])

        #expect(outcome == .collected(newArticles: 0, complete: true))
        #expect(try await externalIDs(fixture, source).isEmpty)
        #expect(try await seen(fixture, source) == [Library.seenHash("kept"): fixture.clock.now()])
    }
}

// Nested in the serialized group: see `TimedAndHeavySuites`.
extension TimedAndHeavySuites {
    @Suite("Seen identifiers at scale")
    struct SeenTimingTests {
        @Test("a 1,500-item feed stored against 1,500 seen rows: time recorded, nothing inserted, every row refreshed")
        func fifteenHundredItems() async throws {
            let fixture = try await RefreshFixture.make()
            defer { fixture.remove() }
            let source = try await fixture.addFeed("large").id
            let target = try #require(try await fixture.library.collectionTarget(source))
            let items = (0..<1_500).map { index in
                ParsedItem(externalID: "item-\(index)", url: "https://example.invalid/item/\(index)", title: "Item \(index)")
            }
            func result(_ items: [ParsedItem]) -> FetchResult {
                .feed(FetchedFeed(
                    feed: ParsedFeed(format: .rss, title: "Large", siteURL: nil, items: items, isComplete: true),
                    validators: Validators(etag: nil, lastModified: nil), finalURL: URL(string: target.url)!
                ))
            }
            let clock = ContinuousClock()

            // First collection: 1,500 new items, each with its link checks.
            var outcome: CollectionOutcome?
            let insertTime = try await clock.measure {
                outcome = try await fixture.library.storeCollection(result(items), for: target, at: fixture.clock.now())
            }
            #expect(outcome == .collected(newArticles: 1_500, complete: true))
            try await cleanUpEverythingAtScale(fixture)
            #expect(try await rowCounts(fixture.library)["seen"] == 1_500)
            fixture.clock.advance(seconds: 3_600)

            // Then against 1,500 seen rows.
            let seenTime = try await clock.measure {
                outcome = try await fixture.library.storeCollection(result(items), for: target, at: fixture.clock.now())
            }
            #expect(outcome == .collected(newArticles: 0, complete: true))
            let refreshed = try await fixture.library.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM seen WHERE last_seen_at = ?", arguments: [fixture.clock.now()])
            }
            #expect(refreshed == 1_500)
            print("RD06 timing: storing 1,500 new items took \(insertTime); storing 1,500 items against 1,500 seen rows took \(seenTime)")
        }

        private func cleanUpEverythingAtScale(_ fixture: RefreshFixture) async throws {
            try await fixture.library.pool.write { db in
                try db.execute(sql: "UPDATE article SET first_seen_at = ?", arguments: [fixture.clock.now().addingTimeInterval(-31 * 86_400)])
            }
            #expect(try await fixture.library.cleanUp(keeping: .thirtyDays) == 1_500)
        }
    }
}
