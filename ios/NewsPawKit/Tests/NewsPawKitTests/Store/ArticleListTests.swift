import Foundation
import GRDB
@testable import NewsPawKit
import Testing

/// RD09 criteria 1 and 3, and criterion 7's rows that no list has loaded.
@Suite("Article lists")
struct ArticleListTests {
    // MARK: - Criterion 1: queries

    @Test("each scope under each filter that applies holds exactly its articles, in the list order, paused sources included")
    func scopesAndFilters() async throws {
        let fixture = try await ArticleFixture.make()
        defer { fixture.remove() }
        let world = try await fixture.category("World")
        let tech = try await fixture.category("Tech")
        let news = try await fixture.source("News", in: world)
        let paused = try await fixture.source("Paused", in: world, paused: true)
        let gadgets = try await fixture.source("Gadgets", in: tech)
        // Mixed times: dated and undated, a published time shared by three
        // articles, and two of them also sharing their first-seen time.
        try await fixture.article("n1", in: news, published: fixture.at(100), firstSeen: fixture.at(500))
        try await fixture.article("n2", in: news, published: nil, firstSeen: fixture.at(300), read: true)
        try await fixture.article("n3", in: news, published: fixture.at(300), firstSeen: fixture.at(600), starred: true)
        try await fixture.article("n4", in: news, published: fixture.at(300), firstSeen: fixture.at(600))
        try await fixture.article("p1", in: paused, published: fixture.at(300), firstSeen: fixture.at(400), read: true, starred: true)
        try await fixture.article("p2", in: paused, published: nil, firstSeen: fixture.at(700))
        try await fixture.article("g1", in: gadgets, published: fixture.at(200), firstSeen: fixture.at(800), starred: true)
        try await fixture.article("g2", in: gadgets, published: fixture.at(900), firstSeen: fixture.at(900), read: true)
        try await fixture.article("g3", in: gadgets, published: nil, firstSeen: fixture.at(250))

        let cases: [(ArticleScope, ArticleFilter)] = [
            (.library, .unread), (.library, .all), (.starred, .all),
            (.category(world), .unread), (.category(world), .all), (.category(tech), .unread), (.category(tech), .all),
            (.source(news), .unread), (.source(news), .all), (.source(paused), .unread), (.source(paused), .all),
        ]
        for (scope, filter) in cases {
            let rows = try await fixture.library.articleRows(scope, filter: filter)
            let titles = fixture.stored.reduce(into: [UUID: String]()) { $0[$1.id] = $1.title }
            #expect(rows.map(\.id) == fixture.expected(scope, filter), "\(scope) \(filter): \(rows.map { titles[$0.id] ?? "?" })")
        }
        // Spelled out once, so that the model above is checked too.
        let all = try await fixture.library.articleRows(.library, filter: .all).map { $0.title ?? "" }
        #expect(all == ["g2", "p2", "n4", "n3", "p1", "n2", "g3", "g1", "n1"])
        let paused2 = try await fixture.library.articleRows(.source(paused), filter: .unread).map { $0.title ?? "" }
        #expect(paused2 == ["p2"], "a paused source's articles are listed")
        let starred = try await fixture.library.articleRows(.starred, filter: .all).map { $0.title ?? "" }
        #expect(starred == ["n3", "p1", "g1"])
    }

    @Test("a row carries the source's name, its fields and states, and never the stored HTML")
    func rowRecord() async throws {
        let fixture = try await ArticleFixture.make()
        defer { fixture.remove() }
        let world = try await fixture.category("World")
        let news = try await fixture.source("News", in: world)
        let id = try await fixture.article("Dated", in: news, published: fixture.at(100), firstSeen: fixture.at(200), starred: true)
        try await fixture.article("Undated", in: news, published: nil, firstSeen: fixture.at(50), read: true)

        let rows = try await fixture.library.articleRows(.library, filter: .all)
        #expect(rows.count == 2)
        let row = try #require(rows.first)
        #expect(row.id == id)
        #expect(row.sourceID == news)
        #expect(row.sourceName == "News")
        #expect(row.title == "Dated")
        #expect(row.excerpt == "Excerpt of Dated")
        #expect(row.author == "Author")
        #expect(row.link == "https://example.invalid/\(id.databaseKey)")
        #expect(row.imageAddress == nil)
        #expect(row.shownAt == fixture.at(100))
        #expect(!row.isRead)
        #expect(row.isStarred)
        #expect(rows[1].shownAt == fixture.at(50), "an undated article shows its first-seen time")
        #expect(rows[1].isRead)
        #expect(!rows[1].isStarred)
        #expect(try await fixture.library.article(id) == row)

        // No list query names content_html.
        let statementColumns = try await fixture.library.pool.read { db in
            try db.makeStatement(sql: Library.articleRowsSQL(where: [])).columnNames
        }
        #expect(!statementColumns.contains("content_html"), "\(statementColumns)")
        #expect(!Library.articleRowsSQL(where: []).contains("content_html"))
        #expect(!Library.articleRowColumns.contains("content_html"))
        await #expect(throws: LibraryError.unknownArticle) {
            try await fixture.library.article(UUID())
        }
    }

    @Test("a dateless feed's items list in feed order")
    func datelessFeedOrder() async throws {
        let fixture = try await ArticleFixture.make()
        defer { fixture.remove() }
        let world = try await fixture.category("World")
        let news = try await fixture.source("News", in: world)
        let items = (1...6).map { ParsedItem(externalID: "item-\($0)", url: "https://example.invalid/\($0)", title: "Item \($0)") }
        let now = fixture.clock.now()
        try await fixture.library.pool.write { db in
            _ = try Library.insertArticles(items, sourceKey: news.databaseKey, categoryKey: world.databaseKey, now: now, in: db)
        }
        let titles = try await fixture.library.articleRows(.source(news), filter: .all).map { $0.title ?? "" }
        #expect(titles == items.map { $0.title ?? "" })
        let library = try await fixture.library.articleRows(.library, filter: .unread).map { $0.title ?? "" }
        #expect(library == items.map { $0.title ?? "" })
    }

    @Test("pages of 200 never repeat or skip a row, with a run of articles sharing one time across a page boundary")
    func pagesAcrossATieRun() async throws {
        let fixture = try await ArticleFixture.make()
        defer { fixture.remove() }
        let world = try await fixture.category("World")
        let tech = try await fixture.category("Tech")
        let news = try await fixture.source("News", in: world)
        let more = try await fixture.source("More", in: world)
        let gadgets = try await fixture.source("Gadgets", in: tech)
        // 150 newer articles, then 300 sharing one published and first-seen
        // time (rows 151–450 straddle the boundary at 200 and at 400), then
        // 100 older ones; every fifth is read, a few are starred.
        var index = 0
        func add(published: Date?, firstSeen: Date) async throws {
            let source = [news, more, gadgets][index % 3]
            try await fixture.article(
                "a\(index)", in: source, published: published, firstSeen: firstSeen, read: index % 5 == 0, starred: index % 7 == 0
            )
            index += 1
        }
        for step in 0..<150 {
            try await add(published: fixture.at(100_000 - step), firstSeen: fixture.at(1))
        }
        for _ in 0..<300 {
            try await add(published: fixture.at(50_000), firstSeen: fixture.at(50_000))
        }
        for step in 0..<100 {
            try await add(published: nil, firstSeen: fixture.at(10_000 - step))
        }

        let cases: [(ArticleScope, ArticleFilter)] = [
            (.library, .all), (.library, .unread), (.category(world), .all), (.category(world), .unread),
            (.source(news), .all), (.starred, .all),
        ]
        for (scope, filter) in cases {
            let pages = try await fixture.allPages(scope, filter, limit: Library.articlePageSize)
            let ids = pages.flatMap { $0.map(\.id) }
            #expect(ids == fixture.expected(scope, filter), "\(scope) \(filter)")
            #expect(Set(ids).count == ids.count, "no row repeated")
            #expect(pages.dropLast().allSatisfy { $0.count == 200 }, "\(pages.map(\.count))")
        }
        // The first page boundary of the whole library falls inside the run.
        let pages = try await fixture.allPages(.library, .all, limit: 200)
        #expect(pages.count == 3)
        #expect(pages[0].last?.shownAt == fixture.at(50_000))
        #expect(pages[1].first?.shownAt == fixture.at(50_000))
        #expect(pages[1].last?.shownAt == fixture.at(50_000))
        #expect(pages[2].first?.shownAt == fixture.at(50_000))
        // Small pages walk the same order.
        let small = try await fixture.allPages(.library, .unread, limit: 7).flatMap { $0.map(\.id) }
        #expect(small == fixture.expected(.library, .unread))
    }

    // MARK: - Criterion 3: state changes

    @Test("read and star: each writes one column of one article, is idempotent, and throws unknownArticle for an unknown one")
    func stateChanges() async throws {
        let fixture = try await ArticleFixture.make()
        defer { fixture.remove() }
        let world = try await fixture.category("World")
        let news = try await fixture.source("News", in: world)
        let target = try await fixture.article("Target", in: news, published: fixture.at(1), firstSeen: fixture.at(1))
        try await fixture.article("Other", in: news, published: fixture.at(2), firstSeen: fixture.at(2))
        let key = target.databaseKey
        fixture.clock.advance(seconds: 3_600)

        func expectChange(_ column: String, _ change: () async throws -> Void) async throws {
            let before = try await fixture.articleTable()
            try await change()
            let after = try await fixture.articleTable()
            #expect(changedColumns(before, after) == ["\(key).\(column)"], "\(column)")
            // Again: nothing changes.
            try await change()
            #expect(try await fixture.articleTable() == after, "\(column) twice")
        }
        try await expectChange("read_at") { try await fixture.library.setRead(target, true) }
        #expect(try await fixture.library.article(target).isRead)
        try await expectChange("read_at") { try await fixture.library.setRead(target, false) }
        #expect(try await !fixture.library.article(target).isRead)
        try await expectChange("starred_at") { try await fixture.library.setStarred(target, true) }
        #expect(try await fixture.library.article(target).isStarred)
        try await expectChange("starred_at") { try await fixture.library.setStarred(target, false) }
        #expect(try await !fixture.library.article(target).isStarred)

        // Marking a read article read again keeps its time.
        try await fixture.library.setRead(target, true)
        let first = try await fixture.articleTable()[key]?["read_at"]
        fixture.clock.advance(seconds: 60)
        try await fixture.library.setRead(target, true)
        #expect(try await fixture.articleTable()[key]?["read_at"] == first)

        let before = try await fixture.articleTable()
        for change in [
            { try await fixture.library.setRead(UUID(), true) }, { try await fixture.library.setRead(UUID(), false) },
            { try await fixture.library.setStarred(UUID(), true) }, { try await fixture.library.setStarred(UUID(), false) },
        ] as [() async throws -> Void] {
            await #expect(throws: LibraryError.unknownArticle) { try await change() }
        }
        #expect(try await fixture.articleTable() == before)
    }

    @Test("mark all as read touches exactly the scope's unread articles first seen up to the moment, also those no list loaded, and returns their number")
    func markAllRead() async throws {
        let fixture = try await ArticleFixture.make()
        defer { fixture.remove() }
        let world = try await fixture.category("World")
        let tech = try await fixture.category("Tech")
        let news = try await fixture.source("News", in: world)
        let more = try await fixture.source("More", in: world, paused: true)
        let gadgets = try await fixture.source("Gadgets", in: tech)
        // 250 unread in World — more than one page — 10 already read, and
        // 3 first seen after the moment; Tech's 20 stay as they are.
        for index in 0..<250 {
            try await fixture.article("w\(index)", in: index % 2 == 0 ? news : more, published: nil, firstSeen: fixture.at(index))
        }
        for index in 0..<10 {
            try await fixture.article("r\(index)", in: news, published: nil, firstSeen: fixture.at(index), read: true)
        }
        let moment = fixture.at(1_000)
        for index in 0..<3 {
            try await fixture.article("late\(index)", in: news, published: nil, firstSeen: fixture.at(1_001 + index))
        }
        for index in 0..<20 {
            try await fixture.article("t\(index)", in: gadgets, published: nil, firstSeen: fixture.at(index))
        }
        fixture.clock.advance(seconds: 5_000)

        #expect(try await fixture.library.unreadCount(in: .category(world), firstSeenThrough: moment) == 250)
        #expect(try await fixture.library.unreadCount(in: .source(news), firstSeenThrough: moment) == 125)
        #expect(try await fixture.library.unreadCount(in: .library, firstSeenThrough: moment) == 270)

        let before = try await fixture.articleTable()
        let marked = try await fixture.library.markAllRead(in: .category(world), firstSeenThrough: moment)
        #expect(marked == 250)
        let after = try await fixture.articleTable()
        let expected = Set(fixture.stored.filter { $0.title.hasPrefix("w") }.map { "\($0.id.databaseKey).read_at" })
        #expect(changedColumns(before, after) == expected)
        #expect(try await fixture.library.articleRows(.category(world), filter: .unread).map { $0.title ?? "" }
            == ["late2", "late1", "late0"], "the articles first seen after the moment stay unread")
        #expect(try await fixture.library.unreadCount(in: .category(world), firstSeenThrough: moment) == 0)
        #expect(try await fixture.library.unreadCount(in: .category(tech), firstSeenThrough: moment) == 20)
        #expect(try await fixture.library.markAllRead(in: .category(world), firstSeenThrough: moment) == 0)

        // A source, then the whole library.
        #expect(try await fixture.library.markAllRead(in: .source(gadgets), firstSeenThrough: fixture.at(9)) == 10)
        #expect(try await fixture.library.markAllRead(in: .library, firstSeenThrough: fixture.at(2_000)) == 13)
        #expect(try await fixture.library.articleRows(.library, filter: .unread).isEmpty)
    }

    @Test("read, star and mark all as read survive closing and reopening the library")
    func survivesReopening() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ids: [UUID]
        let world: UUID
        do {
            let library = try await LibraryStore(directory: directory).openNormal()
            world = try await library.createCategory(name: "World", icon: .globe).id
            let source = Sample.source(in: world, url: "https://news.example.invalid/feed", name: "News", at: Date())
            try await library.insert(source)
            var made: [UUID] = []
            for index in 0..<4 {
                let article = Sample.article(in: source.id, externalID: "e\(index)", title: "A\(index)", at: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)))
                try await library.insert(article)
                made.append(article.id)
            }
            ids = made
            try await library.setRead(ids[0], true)
            try await library.setStarred(ids[1], true)
            try await library.setRead(ids[1], true)
            try await library.setRead(ids[1], false)
            #expect(try await library.markAllRead(in: .category(world), firstSeenThrough: Date(timeIntervalSince1970: 1_800_000_002)) == 2)
        }
        let reopened = try await LibraryStore(directory: directory).openNormal()
        let rows = try await reopened.articleRows(.library, filter: .all)
        let states = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, ($0.isRead, $0.isStarred)) })
        #expect(states[ids[0]]! == (true, false))
        #expect(states[ids[1]]! == (true, true))
        #expect(states[ids[2]]! == (true, false))
        #expect(states[ids[3]]! == (false, false))
        #expect(try await reopened.articleRows(.starred, filter: .all).map(\.id) == [ids[1]])
    }
}
