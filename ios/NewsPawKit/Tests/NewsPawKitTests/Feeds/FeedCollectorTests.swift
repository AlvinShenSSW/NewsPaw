import Foundation
import GRDB
@testable import NewsPawKit
import Synchronization
import Testing

/// The collector with a fake transport and an injected clock (criteria 3, 5,
/// 9, 10, 12, 14, 15).
@Suite("Feed collector")
struct FeedCollectorTests {
    private func feedResponse(_ body: Data, headers: [String: String] = [:]) -> FakeTransport {
        FakeTransport.answering(body: body, headers: headers)
    }

    private func rss(_ items: String) -> Data {
        Data(rssDocument(items).utf8)
    }

    // MARK: - First and second collection (criterion 5)

    @Test("the first collection stores every item and the source's status")
    func firstCollection() async throws {
        let fixture = try await CollectionFixture.make()
        defer { fixture.remove() }
        let transport = feedResponse(try FeedFixture.data("rss2.xml"), headers: ["ETag": #"W/"v1""#, "Last-Modified": "Tue, 10 Nov 2026 08:00:00 GMT"])

        let outcome = try await FeedCollector(transport: transport).collect(fixture.source.id, in: fixture.library)

        #expect(outcome == .collected(newArticles: 3, complete: true))
        let articles = try await fixture.articles()
        #expect(Set(articles.map(\.externalID)) == ["gazette-0001", "https://example.invalid/articles/ferry-guid", "https://example.invalid/articles/market"])
        let lighthouse = try #require(articles.first { $0.externalID == "gazette-0001" })
        #expect(lighthouse.url == "https://example.invalid/articles/lighthouse")
        #expect(lighthouse.title == "Lighthouse keepers vote to repaint the tower")
        #expect(lighthouse.excerpt == "The keepers met on Tuesday & agreed.")
        #expect(lighthouse.author == "keeper@example.invalid (Ada Keeper)")
        #expect(lighthouse.imageURL == "https://example.invalid/images/tower.jpg")
        #expect(lighthouse.publishedAt == date("2026-11-09T23:00:00Z"))
        #expect(lighthouse.firstSeenAt == fixture.clock.now())
        #expect(lighthouse.language == nil)
        #expect(lighthouse.readAt == nil)
        #expect(lighthouse.starredAt == nil)
        let source = try await fixture.storedSource()
        #expect(source.etag == #"W/"v1""#)
        #expect(source.lastModified == "Tue, 10 Nov 2026 08:00:00 GMT")
        #expect(source.lastSuccessAt == fixture.clock.now())
        #expect(source.lastError == nil)
        try await expectIdentifiersAreLowercaseText(fixture.library)
    }

    @Test("collecting the same feed twice adds nothing the second time")
    func secondCollection() async throws {
        let fixture = try await CollectionFixture.make()
        defer { fixture.remove() }
        let collector = FeedCollector(transport: feedResponse(try FeedFixture.data("rss2.xml")))
        _ = try await collector.collect(fixture.source.id, in: fixture.library)
        let before = try await fixture.articles()
        fixture.clock.advance(seconds: 3600)

        let outcome = try await collector.collect(fixture.source.id, in: fixture.library)

        #expect(outcome == .collected(newArticles: 0, complete: true))
        #expect(try await fixture.articles() == before)
        #expect(try await fixture.storedSource().lastSuccessAt == fixture.clock.now())
    }

    @Test("stored validators are sent on the next request unchanged and replaced after a 200")
    func validators() async throws {
        let fixture = try await CollectionFixture.make()
        defer { fixture.remove() }
        let feed = try FeedFixture.data("rss2.xml")
        let answers = [
            ["ETag": #"W/"v1""#, "Last-Modified": "Tue, 10 Nov 2026 08:00:00 GMT"],
            ["ETag": #""v2""#],
            [:],
        ]
        let counter = CallCounter()
        let sequenced = FakeTransport { _ in
            let index = counter.next()
            return TransportResponse(finalURL: fixtureBase, status: 200, headers: answers[min(index, answers.count - 1)], body: feed)
        }
        let collector = FeedCollector(transport: sequenced)
        for _ in 0..<3 {
            _ = try await collector.collect(fixture.source.id, in: fixture.library)
        }
        #expect(sequenced.received.map(\.etag) == [nil, #"W/"v1""#, #""v2""#])
        #expect(sequenced.received.map(\.lastModified) == [nil, "Tue, 10 Nov 2026 08:00:00 GMT", nil])
        let source = try await fixture.storedSource()
        #expect(source.etag == nil)
        #expect(source.lastModified == nil)
    }

    @Test("a 304 is handled without parsing and counts as a success")
    func notModified() async throws {
        let fixture = try await CollectionFixture.make()
        defer { fixture.remove() }
        _ = try await FeedCollector(transport: feedResponse(try FeedFixture.data("rss2.xml"), headers: ["ETag": #"W/"v1""#]))
            .collect(fixture.source.id, in: fixture.library)
        try await fixture.library.pool.write { db in
            try db.execute(sql: "UPDATE source SET last_error = 'timed_out' WHERE id = ?", arguments: [fixture.source.id.databaseKey])
        }
        let before = try await fixture.articles()
        fixture.clock.advance()

        let outcome = try await FeedCollector(transport: FakeTransport.answering(status: 304, body: Data("garbage".utf8)))
            .collect(fixture.source.id, in: fixture.library)

        #expect(outcome == .notModified)
        let source = try await fixture.storedSource()
        #expect(source.lastSuccessAt == fixture.clock.now())
        #expect(source.lastError == nil)
        #expect(source.etag == #"W/"v1""#)
        #expect(try await fixture.articles() == before)
    }

    // MARK: - Criterion 3: an incomplete document

    @Test("an incomplete document stores its completed items, counts as a success and clears the validators")
    func incompleteDocument() async throws {
        let fixture = try await CollectionFixture.make()
        defer { fixture.remove() }
        try await fixture.library.pool.write { db in
            try db.execute(sql: "UPDATE source SET etag = 'old', last_modified = 'old', last_error = 'unreachable' WHERE id = ?", arguments: [fixture.source.id.databaseKey])
        }
        let broken = Data(#"<rss version="2.0"><channel><title>t</title><item><guid>1</guid><title>One</title></item><item><guid>2</guid><title>Two</title></item><item><guid>3</guid><title>Fish & chips</title></item></channel></rss>"#.utf8)
        let transport = feedResponse(broken, headers: ["ETag": "\"new\"", "Last-Modified": "new"])

        let outcome = try await FeedCollector(transport: transport).collect(fixture.source.id, in: fixture.library)

        #expect(outcome == .collected(newArticles: 2, complete: false))
        #expect(try await fixture.articles().map(\.externalID).sorted() == ["1", "2"])
        let source = try await fixture.storedSource()
        #expect(source.etag == nil)
        #expect(source.lastModified == nil)
        #expect(source.lastError == nil)
        #expect(source.lastSuccessAt == fixture.clock.now())
    }

    // MARK: - Criterion 9: published time and first seen

    @Test("the published time is the feed's when present, parseable and not in the future; first seen is the clock and never changes")
    func publishedTime() async throws {
        let fixture = try await CollectionFixture.make()
        defer { fixture.remove() }
        let now = fixture.clock.now()
        let body = rss("""
            <item><guid>past</guid><pubDate>Tue, 10 Nov 2026 08:00:00 GMT</pubDate></item>
            <item><guid>missing</guid></item>
            <item><guid>unparseable</guid><pubDate>soon</pubDate></item>
            <item><guid>future</guid><pubDate>Mon, 01 Feb 2027 00:00:00 GMT</pubDate></item>
            <item><guid>exactly-now</guid><pubDate>Fri, 15 Jan 2027 08:00:00 GMT</pubDate></item>
            """)
        #expect(now == date("2027-01-15T08:00:00Z"))
        let collector = FeedCollector(transport: feedResponse(body))
        _ = try await collector.collect(fixture.source.id, in: fixture.library)

        var articles = Dictionary(uniqueKeysWithValues: try await fixture.articles().map { ($0.externalID, $0) })
        #expect(articles["past"]?.publishedAt == date("2026-11-10T08:00:00Z"))
        #expect(articles["missing"]?.publishedAt == nil)
        #expect(articles["unparseable"]?.publishedAt == nil)
        #expect(articles["future"]?.publishedAt == nil)
        #expect(articles["exactly-now"]?.publishedAt == now)
        #expect(articles.values.allSatisfy { $0.firstSeenAt == now })

        // Later collections, even once the "future" date has passed, change neither.
        fixture.clock.advance(seconds: 60 * 86_400)
        _ = try await collector.collect(fixture.source.id, in: fixture.library)
        articles = Dictionary(uniqueKeysWithValues: try await fixture.articles().map { ($0.externalID, $0) })
        #expect(articles["future"]?.publishedAt == nil)
        #expect(articles.values.allSatisfy { $0.firstSeenAt == now })
    }

    // MARK: - Criterion 10: the same link within a category

    @Test("an item whose link an article of the category already holds is not stored; another category's is no obstacle")
    func sameLinkAcrossSources() async throws {
        let fixture = try await CollectionFixture.make()
        defer { fixture.remove() }
        let neighbour = try await fixture.addSource(url: "https://neighbour.example.invalid/feed")
        let otherCategory = try await fixture.library.createCategory(name: "Other", icon: .globe)
        let elsewhere = try await fixture.addSource(url: "https://elsewhere.example.invalid/feed", category: otherCategory.id)
        _ = try await FeedCollector(transport: feedResponse(rss("<item><guid>n1</guid><link>https://example.invalid/shared</link></item>")))
            .collect(neighbour.id, in: fixture.library)
        _ = try await FeedCollector(transport: feedResponse(rss("<item><guid>e1</guid><link>https://example.invalid/other-category</link></item>")))
            .collect(elsewhere.id, in: fixture.library)

        let outcome = try await FeedCollector(transport: feedResponse(rss("""
            <item><guid>a</guid><link>https://example.invalid/shared</link></item>
            <item><guid>b</guid><link>https://example.invalid/other-category</link></item>
            <item><guid>c</guid><link>https://example.invalid/new</link></item>
            """))).collect(fixture.source.id, in: fixture.library)

        #expect(outcome == .collected(newArticles: 2, complete: true))
        #expect(try await fixture.articles().map(\.externalID).sorted() == ["b", "c"])
    }

    @Test("within a batch the first item with a link is kept; items without a link are never duplicates of each other")
    func sameLinkWithinBatch() async throws {
        let fixture = try await CollectionFixture.make()
        defer { fixture.remove() }
        let outcome = try await FeedCollector(transport: feedResponse(rss("""
            <item><guid>first</guid><link>https://example.invalid/same</link><title>First</title></item>
            <item><guid>second</guid><link>https://example.invalid/same</link><title>Second</title></item>
            <item><guid>no-link-1</guid><title>A</title></item>
            <item><guid>no-link-2</guid><title>B</title></item>
            <item><guid>no-link-3</guid><title>A</title></item>
            """))).collect(fixture.source.id, in: fixture.library)

        #expect(outcome == .collected(newArticles: 4, complete: true))
        #expect(try await fixture.articles().map(\.externalID).sorted() == ["first", "no-link-1", "no-link-2", "no-link-3"])
    }

    @Test("survivors are inserted in reverse feed order")
    func insertOrder() async throws {
        let fixture = try await CollectionFixture.make()
        defer { fixture.remove() }
        _ = try await FeedCollector(transport: feedResponse(rss("""
            <item><guid>newest</guid></item><item><guid>middle</guid></item><item><guid>oldest</guid></item>
            """))).collect(fixture.source.id, in: fixture.library)
        #expect(try await fixture.articles().map(\.externalID) == ["oldest", "middle", "newest"])
    }

    // MARK: - Criterion 12: content

    @Test("content is stored verbatim, a script element included, and the description stands in when there is no content")
    func contentStored() async throws {
        let fixture = try await CollectionFixture.make()
        defer { fixture.remove() }
        let transport = feedResponse(try FeedFixture.data("rss2.xml"))
        _ = try await FeedCollector(transport: transport).collect(fixture.source.id, in: fixture.library)

        let articles = try await fixture.articles()
        let lighthouse = try #require(articles.first { $0.externalID == "gazette-0001" })
        let ferry = try #require(articles.first { $0.externalID == "https://example.invalid/articles/ferry-guid" })
        let market = try #require(articles.first { $0.externalID == "https://example.invalid/articles/market" })
        #expect(try await fixture.library.contentHTML(ofArticle: lighthouse.id) == #"<p>Full text about the <em>tower</em>.</p><script>document.write("x")</script>"#)
        #expect(try await fixture.library.contentHTML(ofArticle: ferry.id) == "Ferries run less often.")
        #expect(try await fixture.library.contentHTML(ofArticle: market.id) == nil)
        // Criterion 15: the only request made was for the source's own address.
        #expect(transport.received.map(\.url) == [URL(string: fixture.source.url)!])
    }

    // MARK: - Criterion 14: outcomes

    static let failures: [(String, FakeTransport, String)] = [
        ("unreachable", FakeTransport.failing(.unreachable), "unreachable"),
        ("timed out", FakeTransport.failing(.timedOut), "timed_out"),
        ("too large", FakeTransport.failing(.tooLarge), "too_large"),
        ("too many redirects", FakeTransport.failing(.tooManyRedirects), "too_many_redirects"),
        ("unsupported redirect", FakeTransport.failing(.unsupportedAddress), "unsupported_address"),
        ("declined 401", FakeTransport.failing(.declinedAuthentication(status: 401)), "http:401"),
        ("404", FakeTransport.answering(status: 404), "gone"),
        ("410", FakeTransport.answering(status: 410), "gone"),
        ("500", FakeTransport.answering(status: 500), "http:500"),
        ("redirect without target", FakeTransport.answering(status: 301), "http:301"),
        ("not a feed", FakeTransport.answering(body: Data("<html><body>page</body></html>".utf8)), "not_a_feed"),
    ]

    @Test("each failure is recorded as its code, keeping the last success and every article; the next success clears it", arguments: 0..<failures.count)
    func failureRecorded(_ index: Int) async throws {
        let (label, transport, code) = Self.failures[index]
        let fixture = try await CollectionFixture.make()
        defer { fixture.remove() }
        _ = try await FeedCollector(transport: feedResponse(try FeedFixture.data("rss2.xml"), headers: ["ETag": "\"e\""]))
            .collect(fixture.source.id, in: fixture.library)
        let succeededAt = fixture.clock.now()
        let articles = try await fixture.articles()
        fixture.clock.advance()

        let outcome = try await FeedCollector(transport: transport).collect(fixture.source.id, in: fixture.library)

        #expect(outcome == .failed(try #require(CollectionFailure(code: code))), "\(label)")
        var source = try await fixture.storedSource()
        #expect(source.lastError == code, "\(label)")
        #expect(source.lastFailure?.code == code)
        #expect(source.lastSuccessAt == succeededAt)
        #expect(source.etag == "\"e\"")
        #expect(source.paused == false)
        #expect(try await fixture.articles() == articles)

        fixture.clock.advance()
        _ = try await FeedCollector(transport: feedResponse(try FeedFixture.data("rss2.xml"))).collect(fixture.source.id, in: fixture.library)
        source = try await fixture.storedSource()
        #expect(source.lastError == nil)
        #expect(source.lastSuccessAt == fixture.clock.now())
    }

    @Test("an unsupported source address is recorded without a request")
    func unsupportedSourceAddress() async throws {
        let fixture = try await CollectionFixture.make(url: "ftp://example.invalid/feed")
        defer { fixture.remove() }
        let transport = feedResponse(try FeedFixture.data("rss2.xml"))
        #expect(try await FeedCollector(transport: transport).collect(fixture.source.id, in: fixture.library) == .failed(.unsupportedAddress))
        #expect(try await fixture.storedSource().lastError == "unsupported_address")
        #expect(transport.received.isEmpty)
    }

    @Test("a source that fails leaves every other source untouched and is neither paused nor deleted")
    func failureIsolated() async throws {
        let fixture = try await CollectionFixture.make()
        defer { fixture.remove() }
        let healthy = try await fixture.addSource(url: "https://healthy.example.invalid/feed")
        _ = try await FeedCollector(transport: feedResponse(rss("<item><guid>h</guid></item>"), headers: ["ETag": "\"h\""]))
            .collect(healthy.id, in: fixture.library)
        let healthyBefore = try await fixture.storedSource(healthy.id)
        let healthyArticles = try await fixture.articles(of: healthy.id)
        fixture.clock.advance()

        for _ in 0..<3 {
            _ = try await FeedCollector(transport: FakeTransport.failing(.unreachable)).collect(fixture.source.id, in: fixture.library)
        }

        #expect(try await fixture.storedSource(healthy.id) == healthyBefore)
        #expect(try await fixture.articles(of: healthy.id) == healthyArticles)
        let failing = try await fixture.storedSource()
        #expect(failing.lastError == "unreachable")
        #expect(failing.paused == false)
        #expect(try await fixture.library.sources().count == 2)
    }

    @Test("a stored text that is not a code reads as no known reason")
    func tolerantReader() {
        var source = Sample.source(in: UUID(), url: "https://example.invalid/x", at: Date())
        source.lastError = "Could not connect"
        #expect(source.lastFailure == nil)
        for text in ["http:", "http:abc", "http:1234", "http:٤٠٤", "HTTP:404", "gone "] {
            #expect(CollectionFailure(code: text) == nil, "\(text)")
        }
        #expect(CollectionFailure(code: "http:404") == .httpStatus(404))
    }

    @Test("cancelling a collection records nothing and rethrows the cancellation")
    func cancellation() async throws {
        let fixture = try await CollectionFixture.make()
        defer { fixture.remove() }
        let entered = Signal()
        let transport = FakeTransport { _ in
            entered.fire()
            try await Task.sleep(for: .seconds(30))
            return TransportResponse(finalURL: fixtureBase, status: 200, headers: [:], body: Data())
        }
        let before = try await fixture.storedSource()
        let task = Task { try await FeedCollector(transport: transport).collect(fixture.source.id, in: fixture.library) }
        await entered.wait()
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(try await fixture.storedSource() == before)
        #expect(try await fixture.articles().isEmpty)
    }

    @Test("a fetch that completes after its task was cancelled stores nothing")
    func cancellationAfterFetch() async throws {
        let fixture = try await CollectionFixture.make()
        defer { fixture.remove() }
        let entered = Signal()
        let release = Signal()
        let feed = try FeedFixture.data("rss2.xml")
        let transport = FakeTransport { _ in
            entered.fire()
            await release.wait()
            return TransportResponse(finalURL: fixtureBase, status: 200, headers: [:], body: feed)
        }
        let before = try await fixture.storedSource()
        let task = Task { try await FeedCollector(transport: transport).collect(fixture.source.id, in: fixture.library) }
        await entered.wait()
        task.cancel()
        release.fire()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(try await fixture.storedSource() == before)
        #expect(try await fixture.articles().isEmpty)
    }

    @Test("a source that does not exist, or is not a feed, ends in nothing done without a request")
    func nothingDone() async throws {
        let fixture = try await CollectionFixture.make()
        defer { fixture.remove() }
        let transport = feedResponse(try FeedFixture.data("rss2.xml"))
        let collector = FeedCollector(transport: transport)
        #expect(try await collector.collect(UUID(), in: fixture.library) == .nothingDone)
        for kind in ["webpage", "github", "huggingface", "a-kind-from-a-later-version"] {
            let other = try await fixture.addSource(url: "https://\(kind).example.invalid/")
            try await fixture.library.pool.write { db in
                try db.execute(sql: "UPDATE source SET kind = ? WHERE id = ?", arguments: [kind, other.id.databaseKey])
            }
            #expect(try await collector.collect(other.id, in: fixture.library) == .nothingDone, "\(kind)")
        }
        #expect(transport.received.isEmpty)
    }

    /// Runs a collection whose fetch waits until `meanwhile` has run.
    private func collect(
        _ fixture: CollectionFixture, body: Data, meanwhile: @Sendable () async throws -> Void
    ) async throws -> CollectionOutcome {
        let entered = Signal()
        let release = Signal()
        let transport = FakeTransport { _ in
            entered.fire()
            await release.wait()
            return TransportResponse(finalURL: fixtureBase, status: 200, headers: ["ETag": "\"in-flight\""], body: body)
        }
        let source = fixture.source.id
        let library = fixture.library
        let task = Task { try await FeedCollector(transport: transport).collect(source, in: library) }
        await entered.wait()
        try await meanwhile()
        release.fire()
        return try await task.value
    }

    @Test("a source deleted while its fetch is in flight ends in nothing done")
    func deletedDuringFetch() async throws {
        let fixture = try await CollectionFixture.make()
        defer { fixture.remove() }
        let library = fixture.library
        let key = fixture.source.id.databaseKey
        let outcome = try await collect(fixture, body: try FeedFixture.data("rss2.xml")) {
            try await library.pool.write { db in try db.execute(sql: "DELETE FROM source WHERE id = ?", arguments: [key]) }
        }
        #expect(outcome == .nothingDone)
        #expect(try await rowCounts(library)["article"] == 0)
    }

    @Test("a source given another address while its fetch is in flight ends in nothing done")
    func readdressedDuringFetch() async throws {
        let fixture = try await CollectionFixture.make()
        defer { fixture.remove() }
        let library = fixture.library
        let key = fixture.source.id.databaseKey
        let outcome = try await collect(fixture, body: try FeedFixture.data("rss2.xml")) {
            try await library.pool.write { db in
                try db.execute(sql: "UPDATE source SET url = 'https://example.invalid/other.xml' WHERE id = ?", arguments: [key])
            }
        }
        #expect(outcome == .nothingDone)
        #expect(try await fixture.articles().isEmpty)
        #expect(try await fixture.storedSource().etag == nil)
    }

    @Test("a rename, pause or move made while the fetch is in flight is not overwritten; the new category's links count")
    func editsDuringFetch() async throws {
        let fixture = try await CollectionFixture.make()
        defer { fixture.remove() }
        let library = fixture.library
        let destination = try await library.createCategory(name: "Destination", icon: .book)
        let holder = try await fixture.addSource(url: "https://holder.example.invalid/feed", category: destination.id)
        _ = try await FeedCollector(transport: feedResponse(rss("<item><guid>h</guid><link>https://example.invalid/articles/lighthouse</link></item>")))
            .collect(holder.id, in: library)
        let key = fixture.source.id.databaseKey
        let editedAt = fixture.clock.now().addingTimeInterval(30)

        let outcome = try await collect(fixture, body: try FeedFixture.data("rss2.xml")) {
            try await library.pool.write { db in
                try db.execute(
                    sql: "UPDATE source SET name = 'Renamed', paused = 1, category_id = ?, updated_at = ? WHERE id = ?",
                    arguments: [destination.id.databaseKey, editedAt, key]
                )
            }
        }

        // The lighthouse link is held in the category the source moved to.
        #expect(outcome == .collected(newArticles: 2, complete: true))
        let source = try await fixture.storedSource()
        #expect(source.name == "Renamed")
        #expect(source.paused)
        #expect(source.categoryID == destination.id)
        #expect(source.updatedAt == editedAt)
        #expect(source.etag == "\"in-flight\"")
    }

    @Test("a paused source is still collected: pausing is the caller's rule")
    func pausedIsCollected() async throws {
        let fixture = try await CollectionFixture.make()
        defer { fixture.remove() }
        try await fixture.library.pool.write { db in
            try db.execute(sql: "UPDATE source SET paused = 1 WHERE id = ?", arguments: [fixture.source.id.databaseKey])
        }
        let outcome = try await FeedCollector(transport: feedResponse(rss("<item><guid>p</guid></item>"))).collect(fixture.source.id, in: fixture.library)
        #expect(outcome == .collected(newArticles: 1, complete: true))
    }

    @Test("a feed with zero items is a success with nothing new")
    func zeroItems() async throws {
        let fixture = try await CollectionFixture.make()
        defer { fixture.remove() }
        let outcome = try await FeedCollector(transport: feedResponse(rss(""))).collect(fixture.source.id, in: fixture.library)
        #expect(outcome == .collected(newArticles: 0, complete: true))
        #expect(try await fixture.storedSource().lastSuccessAt == fixture.clock.now())
    }
}

/// Counts calls across tasks.
final class CallCounter: Sendable {
    private let value = Mutex(0)

    func next() -> Int {
        value.withLock { value in
            defer { value += 1 }
            return value
        }
    }
}
