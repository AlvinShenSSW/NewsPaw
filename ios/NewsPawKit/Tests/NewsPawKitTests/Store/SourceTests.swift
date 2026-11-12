import Foundation
import GRDB
@testable import NewsPawKit
import Testing

/// A candidate as detection would hand it over, from an RSS document.
func feedCandidate(
    address: String = "https://feeds.example/rss.xml", items: Int = 3, etag: String? = "\"v1\"", lastModified: String? = "Tue, 10 Nov 2026 08:00:00 GMT",
    siteURL: String? = nil
) throws -> FeedCandidate {
    let entries = (0..<items).map { index in
        "<item><title>Item \(index)</title><link>https://feeds.example/item\(index)</link><guid>item-\(index)</guid>"
            + "<pubDate>Tue, 0\(index + 1) Nov 2026 08:00:00 GMT</pubDate></item>"
    }.joined()
    let feed = try #require(parse(rssDocument(entries), base: URL(string: address)!))
    return FeedCandidate(
        address: address,
        fetched: FetchedFeed(feed: feed, validators: Validators(etag: etag, lastModified: lastModified), finalURL: URL(string: address)!),
        pageAddress: siteURL
    )
}

/// The raw text of every column of a source row, for byte-for-byte
/// comparison.
func rawSourceRow(_ library: Library, _ id: UUID) async throws -> [String: String] {
    try await library.pool.read { db in
        let row = try #require(try Row.fetchOne(db, sql: "SELECT * FROM source WHERE id = ?", arguments: [id.databaseKey]))
        var values: [String: String] = [:]
        for column in row.columnNames {
            let value: DatabaseValue = row[column]
            values[column] = value.description
        }
        return values
    }
}

/// The raw text of every column of the rows `sql` selects.
func rawRows(_ library: Library, _ sql: String, _ arguments: StatementArguments = []) async throws -> [[String]] {
    try await library.pool.read { db in
        try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in row.databaseValues.map(\.description) }
    }
}

/// RD05 criteria 5, 6, 8, 10–15: sources on `Library`.
@Suite("Sources")
struct SourceTests {
    // MARK: - Adding

    @Test("adding a feed stores the source, its articles, validators and success time under one clock reading")
    func addFeed() async throws {
        let fixture = try await SourceFixture.make()
        defer { fixture.remove() }
        let library = fixture.library
        let candidate = try feedCandidate(siteURL: "https://feeds.example/")
        let id = try await library.addFeedSource(candidate, name: "  Feeds  ", categoryID: fixture.category)
        let source = try #require(try await library.sources().first)
        #expect(source.id == id)
        #expect(source.kind == .feed)
        #expect(source.url == candidate.address)
        #expect(source.name == "Feeds")
        #expect(source.siteURL == "https://feeds.example/")
        #expect(source.etag == "\"v1\"")
        #expect(source.lastModified == "Tue, 10 Nov 2026 08:00:00 GMT")
        #expect(source.lastSuccessAt == fixture.clock.now())
        #expect(source.lastError == nil)
        #expect(source.updatedAt == fixture.clock.now())
        #expect(!source.paused)
        #expect(source.autoTranslate == .inherit)
        #expect(source.bodyMode == .auto)
        let articles = try await library.articles()
        #expect(articles.count == 3)
        #expect(articles.allSatisfy { $0.firstSeenAt == fixture.clock.now() && $0.sourceID == id })
        try await expectIdentifiersAreLowercaseText(library)
    }

    @Test("a save into an unknown category, of a stored address, or with a bad name writes nothing")
    func addRefusals() async throws {
        let fixture = try await SourceFixture.make()
        defer { fixture.remove() }
        let library = fixture.library
        let candidate = try feedCandidate()
        await #expect(throws: LibraryError.unknownCategory) {
            try await library.addFeedSource(candidate, name: "X", categoryID: UUID())
        }
        await #expect(throws: LibraryError.emptyName) {
            try await library.addFeedSource(candidate, name: "  ", categoryID: fixture.category)
        }
        await #expect(throws: LibraryError.nameTooLong) {
            try await library.addFeedSource(candidate, name: String(repeating: "n", count: 201), categoryID: fixture.category)
        }
        #expect(try await rowCounts(library) == ["category": 1, "source": 0, "article": 0, "article_body": 0, "seen": 0])

        try await library.addWebPageSource(address: candidate.address, name: "Page", categoryID: fixture.category)
        let before = try await rowCounts(library)
        await #expect(throws: LibraryError.duplicateAddress) {
            try await library.addFeedSource(candidate, name: "X", categoryID: fixture.category)
        }
        await #expect(throws: LibraryError.duplicateAddress) {
            try await library.addWebPageSource(address: "HTTPS://feeds.example/rss.xml#top", name: "X", categoryID: fixture.category)
        }
        #expect(try await rowCounts(library) == before)
        // A 200-character name is accepted.
        try await library.addFeedSource(try feedCandidate(address: "https://other.example/"),
                                        name: String(repeating: "n", count: 200), categoryID: fixture.category)
    }

    @Test("a failing article insert leaves neither the source nor any article")
    func atomicity() async throws {
        let fixture = try await SourceFixture.make()
        defer { fixture.remove() }
        let library = fixture.library
        try await library.pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER abort_article BEFORE INSERT ON article
                WHEN NEW.external_id = 'item-1'
                BEGIN SELECT RAISE(ABORT, 'test abort'); END
                """)
        }
        await #expect(throws: LibraryError.self) {
            try await library.addFeedSource(try feedCandidate(), name: "Feed", categoryID: fixture.category)
        }
        #expect(try await rowCounts(library) == ["category": 1, "source": 0, "article": 0, "article_body": 0, "seen": 0])
    }

    @Test("a web page: defaults, no articles, the address normalised by the function itself")
    func addWebPage() async throws {
        let fixture = try await SourceFixture.make()
        defer { fixture.remove() }
        let library = fixture.library
        try await library.addWebPageSource(address: "  Example.COM/News#top ", name: "Example", categoryID: fixture.category)
        let source = try #require(try await library.sources().first)
        #expect(source.kind == .webpage)
        #expect(source.url == "https://example.com/News")
        #expect(source.lastSuccessAt == nil && source.lastError == nil && source.etag == nil)
        #expect(!source.translatePage)
        #expect(try await library.articles().isEmpty)
        await #expect(throws: LibraryError.invalidAddress(.unsupportedScheme)) {
            try await library.addWebPageSource(address: "ftp://example.com/", name: "X", categoryID: fixture.category)
        }
        try await expectIdentifiersAreLowercaseText(library)
    }

    @Test("the source at an address names its category; none for an address not stored")
    func existing() async throws {
        let fixture = try await SourceFixture.make()
        defer { fixture.remove() }
        let id = try await fixture.library.addWebPageSource(address: "https://example.com/", name: "Example", categoryID: fixture.category)
        let found = try #require(try await fixture.library.existingSource(atAddress: "https://example.com/"))
        #expect(found == ExistingSource(sourceID: id, name: "Example", categoryID: fixture.category, categoryName: "News"))
        #expect(try await fixture.library.existingSource(atAddress: "http://example.com/") == nil)
    }

    // MARK: - The other partition (criterion 6)

    @Test("an address held by the adult library is a new address in the normal one, and the reverse")
    func otherPartition() async throws {
        let fixture = try await SourceFixture.make()
        defer { fixture.remove() }
        let address = "https://shared.example/rss.xml"
        let transport = RoutedTransport([address: RoutedTransport.rss("Shared")])
        let detector = SourceDetector(transport: transport)

        // What adding a new address gives, in a library that never saw it.
        let fresh = try await SourceFixture.make()
        defer { fresh.remove() }
        let expected = try await detector.detect(address, in: fresh.library)

        let adult = try await fixture.store.createAdultLibrary()
        let adultCategory = try await adult.createCategory(name: "Adult", icon: .folder)
        guard case .feed(let adultCandidate) = try await detector.detect(address, in: adult) else {
            Issue.record("not a feed")
            return
        }
        try await adult.addFeedSource(adultCandidate, name: "Adult copy", categoryID: adultCategory.id)

        let normal = try await detector.detect(address, in: fixture.library)
        #expect(normal == expected)
        guard case .feed(let candidate) = normal else { return }
        try await fixture.library.addFeedSource(candidate, name: "Normal copy", categoryID: fixture.category)
        #expect(try await fixture.library.sources().map(\.name) == ["Normal copy"])
        #expect(try await adult.sources().map(\.name) == ["Adult copy"])

        // The reverse: a second address saved in normal first, then adult.
        let second = "https://second.example/"
        try await fixture.library.addWebPageSource(address: second, name: "Normal", categoryID: fixture.category)
        try await adult.addWebPageSource(address: second, name: "Adult", categoryID: adultCategory.id)
        #expect(try await adult.existingSource(atAddress: second)?.name == "Adult")
        #expect(try await fixture.library.existingSource(atAddress: second)?.name == "Normal")
    }

    @Test("an address in an adult library file that is never opened is a new address in the normal one")
    func adultNeverOpened() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let address = "https://shared.example/rss.xml"
        do {
            let writer = LibraryStore(directory: directory)
            let adult = try await writer.createAdultLibrary()
            let category = try await adult.createCategory(name: "Adult", icon: .folder)
            try await adult.addWebPageSource(address: address, name: "Adult", categoryID: category.id)
        }
        let store = LibraryStore(directory: directory)
        let normal = try await store.openNormal()
        let category = try await normal.createCategory(name: "News", icon: .newspaper)
        let transport = RoutedTransport([address: RoutedTransport.rss("Shared")])
        guard case .feed(let candidate) = try await SourceDetector(transport: transport).detect(address, in: normal) else {
            Issue.record("not a feed")
            return
        }
        try await normal.addFeedSource(candidate, name: "Normal", categoryID: category.id)
        #expect(try await normal.sources().map(\.url) == [address])
    }

    // MARK: - Summaries

    @Test("summaries: counts, newest item, status and order by name")
    func summaries() async throws {
        let fixture = try await SourceFixture.make()
        defer { fixture.remove() }
        let library = fixture.library
        let feedID = try await library.addFeedSource(try feedCandidate(items: 2), name: "beta", categoryID: fixture.category)
        let pageID = try await library.addWebPageSource(address: "https://page.example/", name: "Alpha", categoryID: fixture.category)
        // An article without a published time counts by its first-seen time.
        let seen = fixture.clock.now().addingTimeInterval(3_600)
        let undated = Article(
            id: UUID(), sourceID: feedID, externalID: "undated", url: nil, title: "Undated", excerpt: nil, author: nil,
            imageURL: nil, publishedAt: nil, firstSeenAt: seen, language: nil, readAt: nil, starredAt: nil
        )
        try await library.insert(undated)
        for name in ["Gamma", "中文", "alpha2", "Beta"] {
            try await library.addWebPageSource(address: "https://\(UUID().uuidString.lowercased()).example/", name: name,
                                               categoryID: fixture.category)
        }
        let summaries = try await library.sourceSummaries()
        #expect(summaries.map(\.name) == summaries.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        #expect(summaries.prefix(2).map(\.name) == ["Alpha", "alpha2"])
        let feed = try #require(summaries.first { $0.id == feedID })
        #expect(feed.articleCount == 3)
        #expect(feed.unreadCount == 3)
        #expect(feed.newestItemAt == seen)
        #expect(feed.status == .working(lastSuccess: fixture.clock.now()))
        #expect(feed.isFeedLike)
        let page = try #require(summaries.first { $0.id == pageID })
        #expect(page.articleCount == 0 && page.newestItemAt == nil && page.status == nil && !page.isFeedLike)
    }

    @Test("the newest item is the newest published time when it differs from every first-seen time, rows out of order")
    func newestPublishedTime() async throws {
        let fixture = try await SourceFixture.make()
        defer { fixture.remove() }
        let library = fixture.library
        let id = try await library.addFeedSource(try feedCandidate(items: 0), name: "Feed", categoryID: fixture.category)
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        // (published, first seen), inserted with the newest published time in
        // the middle and every first-seen time later than every published one.
        let rows: [(TimeInterval, TimeInterval)] = [(100, 5_000), (300, 4_000), (200, 6_000)]
        for (index, row) in rows.enumerated() {
            try await library.insert(Article(
                id: UUID(), sourceID: id, externalID: "row-\(index)", url: nil, title: "Row \(index)", excerpt: nil,
                author: nil, imageURL: nil, publishedAt: base.addingTimeInterval(row.0),
                firstSeenAt: base.addingTimeInterval(row.1), language: nil, readAt: nil, starredAt: nil
            ))
        }
        let summary = try #require(try await library.sourceSummaries().first { $0.id == id })
        #expect(summary.newestItemAt == base.addingTimeInterval(300))
    }

    @Test("the status: paused, failing with a known or unknown code, working, not updated yet")
    func status() {
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(SourceStatus(kind: .feed, paused: true, lastError: "gone", lastSuccessAt: time) == .paused(lastSuccess: time))
        #expect(SourceStatus(kind: .feed, paused: false, lastError: "gone", lastSuccessAt: time) == .failing(reason: .gone, lastSuccess: time))
        #expect(SourceStatus(kind: .feed, paused: false, lastError: "http:503", lastSuccessAt: nil)
            == .failing(reason: .httpStatus(503), lastSuccess: nil))
        #expect(SourceStatus(kind: .github, paused: false, lastError: "a message from an older build", lastSuccessAt: nil)
            == .failing(reason: nil, lastSuccess: nil))
        #expect(SourceStatus(kind: .feed, paused: false, lastError: nil, lastSuccessAt: time) == .working(lastSuccess: time))
        #expect(SourceStatus(kind: .huggingface, paused: false, lastError: nil, lastSuccessAt: nil) == .notUpdatedYet)
        #expect(SourceStatus(kind: .webpage, paused: true, lastError: "gone", lastSuccessAt: time) == nil)
    }

    // MARK: - Updating

    @Test("each field alone and several together; nothing else and no status column changes")
    func update() async throws {
        let fixture = try await SourceFixture.make()
        defer { fixture.remove() }
        let library = fixture.library
        let other = try await library.createCategory(name: "Other", icon: .folder)
        let id = try await library.addFeedSource(try feedCandidate(), name: "Feed", categoryID: fixture.category)
        // Status columns a collection wrote.
        try await library.pool.write { db in
            try db.execute(sql: "UPDATE source SET last_error = 'gone' WHERE id = ?", arguments: [id.databaseKey])
        }
        // The stored values as text: strings quoted, integers bare.
        let changes: [(SourceChanges, String, String)] = [
            (SourceChanges(name: " Renamed "), "name", "\"Renamed\""),
            (SourceChanges(categoryID: other.id), "category_id", "\"\(other.id.databaseKey)\""),
            (SourceChanges(paused: true), "paused", "1"),
            (SourceChanges(autoTranslate: .off), "auto_translate", "\"off\""),
            (SourceChanges(bodyMode: .page), "body_mode", "\"page\""),
        ]
        for (change, column, value) in changes {
            fixture.clock.advance()
            let before = try await rawSourceRow(library, id)
            try await library.updateSource(id, change)
            let after = try await rawSourceRow(library, id)
            let changed = Set(after.keys.filter { after[$0] != before[$0] })
            #expect(changed == [column, "updated_at"], "\(column): \(changed)")
            #expect(after[column] == value, "\(column)")
        }
        // Several together, and an unchanged value written as nothing.
        fixture.clock.advance()
        let before = try await rawSourceRow(library, id)
        try await library.updateSource(id, SourceChanges(name: "Renamed", paused: false, bodyMode: .feed))
        let after = try await rawSourceRow(library, id)
        #expect(Set(after.keys.filter { after[$0] != before[$0] }) == ["paused", "body_mode", "updated_at"])
        try await library.updateSource(id, SourceChanges(name: "Renamed"))
        #expect(try await rawSourceRow(library, id) == after)

        let source = try #require(try await library.sources().first)
        #expect(source.lastError == "gone")
        #expect(source.etag == "\"v1\"")
        try await expectIdentifiersAreLowercaseText(library)
    }

    @Test("update refusals: wrong kind, unknown source, unknown category, bad name; nothing changes")
    func updateRefusals() async throws {
        let fixture = try await SourceFixture.make()
        defer { fixture.remove() }
        let library = fixture.library
        let feed = try await library.addFeedSource(try feedCandidate(), name: "Feed", categoryID: fixture.category)
        let page = try await library.addWebPageSource(address: "https://page.example/", name: "Page", categoryID: fixture.category)
        let feedBefore = try await rawSourceRow(library, feed)
        let pageBefore = try await rawSourceRow(library, page)
        await #expect(throws: LibraryError.optionNotApplicable) {
            try await library.updateSource(feed, SourceChanges(name: "New", translatePage: true))
        }
        for change in [SourceChanges(paused: true), SourceChanges(autoTranslate: .on), SourceChanges(bodyMode: .page)] {
            await #expect(throws: LibraryError.optionNotApplicable) { try await library.updateSource(page, change) }
        }
        await #expect(throws: LibraryError.unknownSource) { try await library.updateSource(UUID(), SourceChanges(name: "X")) }
        await #expect(throws: LibraryError.unknownCategory) { try await library.updateSource(feed, SourceChanges(categoryID: UUID())) }
        await #expect(throws: LibraryError.emptyName) { try await library.updateSource(feed, SourceChanges(name: " ")) }
        #expect(try await rawSourceRow(library, feed) == feedBefore)
        #expect(try await rawSourceRow(library, page) == pageBefore)

        try await library.updateSource(page, SourceChanges(translatePage: true))
        #expect(try await rawSourceRow(library, page)["translate_page"] == "1")
    }

    @Test("moving changes category_id and updated_at only; articles and status are byte for byte the same")
    func move() async throws {
        let fixture = try await SourceFixture.make()
        defer { fixture.remove() }
        let library = fixture.library
        let other = try await library.createCategory(name: "Other", icon: .folder)
        let id = try await library.addFeedSource(try feedCandidate(), name: "Feed", categoryID: fixture.category)
        try await library.pool.write { db in
            try db.execute(sql: "UPDATE article SET read_at = ?, starred_at = ? WHERE external_id = 'item-0'",
                           arguments: [Date(timeIntervalSince1970: 1_800_000_100), Date(timeIntervalSince1970: 1_800_000_200)])
        }
        let articlesBefore = try await rawRows(library, "SELECT * FROM article ORDER BY id")
        let before = try await rawSourceRow(library, id)
        fixture.clock.advance()
        try await library.updateSource(id, SourceChanges(categoryID: other.id))
        let after = try await rawSourceRow(library, id)
        #expect(Set(after.keys.filter { after[$0] != before[$0] }) == ["category_id", "updated_at"])
        let articlesAfter = try await rawRows(library, "SELECT * FROM article ORDER BY id")
        #expect(articlesAfter == articlesBefore)
    }

    // MARK: - Deleting

    @Test("deleting takes the articles, bodies and seen identifiers; every other source is untouched")
    func delete() async throws {
        let fixture = try await SourceFixture.make()
        defer { fixture.remove() }
        let library = fixture.library
        let sources = try await Sample.fill(library, category: fixture.category, prefix: "d", at: fixture.clock.now())
        let survivor = sources[1].id
        let survivorRow = try await rawSourceRow(library, survivor)
        let articlesSQL = "SELECT * FROM article WHERE source_id = ? ORDER BY id"
        let survivorArticles = try await rawRows(library, articlesSQL, [survivor.databaseKey])
        try await library.deleteSource(sources[0].id)
        #expect(try await rowCounts(library) == ["category": 1, "source": 1, "article": 2, "article_body": 2, "seen": 1])
        #expect(try await rawSourceRow(library, survivor) == survivorRow)
        #expect(try await rawRows(library, articlesSQL, [survivor.databaseKey]) == survivorArticles)
        await #expect(throws: LibraryError.unknownSource) { try await library.deleteSource(sources[0].id) }
    }

    // MARK: - Names

    @Test("the name rule: trimmed, 1 to 200 characters")
    func nameRule() {
        #expect(Library.sourceNameProblem("  ") == .empty)
        #expect(Library.sourceNameProblem(String(repeating: "a", count: 200)) == nil)
        #expect(Library.sourceNameProblem(" " + String(repeating: "a", count: 200) + " ") == nil)
        #expect(Library.sourceNameProblem(String(repeating: "a", count: 201)) == .tooLong)
    }
}
