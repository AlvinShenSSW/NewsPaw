import Foundation
@testable import NewsPawKit
import Synchronization
import Testing

/// A transport that answers by address, logs every request and records the
/// most requests in flight at once.
final class RoutedTransport: Transport {
    typealias Route = @Sendable (TransportRequest) async throws -> TransportResponse

    private struct State {
        var requests: [String] = []
        var inFlight = 0
        var maximumInFlight = 0
    }

    private let routes: [String: Route]
    private let state = Mutex(State())

    init(_ routes: [String: Route]) {
        self.routes = routes
    }

    var requested: [String] {
        state.withLock { $0.requests }
    }

    var maximumInFlight: Int {
        state.withLock { $0.maximumInFlight }
    }

    func fetch(_ request: TransportRequest) async throws -> TransportResponse {
        let address = request.url.absoluteString
        state.withLock { state in
            state.requests.append(address)
            state.inFlight += 1
            state.maximumInFlight = max(state.maximumInFlight, state.inFlight)
        }
        defer { state.withLock { $0.inFlight -= 1 } }
        guard let route = routes[address] else { throw TransportFailure.unreachable }
        return try await route(request)
    }

    /// Answers `body` with `type`, from `final` when given.
    static func answer(_ body: Data, type: String, status: Int = 200, final: String? = nil, delay: Duration? = nil) -> Route {
        { request in
            if let delay {
                try await Task.sleep(for: delay)
            }
            return TransportResponse(
                finalURL: final.flatMap(URL.init(string:)) ?? request.url, status: status, headers: ["Content-Type": type], body: body
            )
        }
    }

    static func answer(_ text: String, type: String, status: Int = 200, final: String? = nil, delay: Duration? = nil) -> Route {
        answer(Data(text.utf8), type: type, status: status, final: final, delay: delay)
    }

    static func rss(_ title: String, items: Int = 2, link: Bool = true, final: String? = nil, delay: Duration? = nil) -> Route {
        let entries = (0..<items).map { index in
            "<item><title>\(title) \(index)</title><guid>\(title)-\(index)</guid><pubDate>Tue, 1\(index) Nov 2026 08:00:00 GMT</pubDate></item>"
        }.joined()
        let channelLink = link ? "<link>https://example.invalid/\(title)</link>" : ""
        return answer(rssDocument(entries, channel: "<title>\(title)</title>\(channelLink)"), type: "application/rss+xml",
                      final: final, delay: delay)
    }

    /// Never answers until cancelled.
    static let never: Route = { _ in
        try await Task.sleep(for: .seconds(3_600))
        throw TransportFailure.timedOut
    }

    static func failing(_ failure: TransportFailure) -> Route {
        { _ in throw failure }
    }
}

/// A fresh library with one category, for detection and source tests.
struct SourceFixture {
    let directory: URL
    let clock: TestClock
    let store: LibraryStore
    let library: Library
    let category: UUID

    static func make() async throws -> SourceFixture {
        let directory = try makeTemporaryDirectory()
        let clock = TestClock()
        let store = LibraryStore(directory: directory, now: clock.now)
        let library = try await store.openNormal()
        let category = try await library.createCategory(name: "News", icon: .newspaper)
        return SourceFixture(directory: directory, clock: clock, store: store, library: library, category: category.id)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

func page(_ links: String, title: String = "A Page", extra: String = "") -> String {
    "<!DOCTYPE html><html><head><title>\(title)</title>\(links)</head><body>\(extra)</body></html>"
}

/// RD05 criteria 2–7: detection, with a fake transport.
@Suite("Source detection")
struct SourceDetectorTests {
    let site = "https://site.example/"

    @Test("each feed format: one candidate with its format, title, site link and latest items, from one request",
          arguments: [("rss2.xml", ParsedFeed.Format.rss), ("rss1.rdf", .rdf), ("atom.xml", .atom), ("feed.json", .json)])
    func feedFormats(fixture: String, format: ParsedFeed.Format) async throws {
        let library = try await SourceFixture.make()
        defer { library.remove() }
        let data = try FeedFixture.data(fixture)
        let address = "https://feeds.example/" + fixture
        let transport = RoutedTransport([address: RoutedTransport.answer(data, type: "application/xml")])
        let detection = try await SourceDetector(transport: transport).detect(address, in: library.library)
        guard case .feed(let candidate) = detection else {
            Issue.record("not a feed: \(detection)")
            return
        }
        let parsed = try #require(FeedParser.parse(data, charset: nil, baseURL: URL(string: address)!))
        #expect(candidate.address == address)
        #expect(candidate.format == format)
        #expect(candidate.title == parsed.title)
        #expect(candidate.siteURL == parsed.siteURL)
        #expect(candidate.itemCount == parsed.items.count)
        #expect(candidate.latestItems.count == min(3, parsed.items.count))
        let dated = parsed.items.compactMap(\.publishedAt).sorted(by: >)
        #expect(candidate.latestItems.compactMap(\.publishedAt) == Array(dated.prefix(candidate.latestItems.count)))
        #expect(candidate.newestItemAt == dated.first)
        #expect(transport.requested == [address])

        // Saving stores one feed source and its articles; no request is made.
        try await library.library.addFeedSource(candidate, name: "Saved", categoryID: library.category)
        let sources = try await library.library.sources()
        #expect(sources.map(\.kind) == [.feed])
        #expect(try await library.library.articles().count == parsed.items.count)
        #expect(transport.requested == [address])
    }

    @Test("latest items: dated ones newest first, then undated ones in feed order")
    func latestItemsOrder() async throws {
        let library = try await SourceFixture.make()
        defer { library.remove() }
        let address = "https://feeds.example/mixed.xml"
        let items = """
            <item><title>undated A</title><guid>a</guid></item>
            <item><title>old</title><guid>b</guid><pubDate>Mon, 02 Nov 2026 08:00:00 GMT</pubDate></item>
            <item><title>undated B</title><guid>c</guid></item>
            <item><title>new</title><guid>d</guid><pubDate>Tue, 10 Nov 2026 08:00:00 GMT</pubDate></item>
            """
        let transport = RoutedTransport([address: RoutedTransport.answer(rssDocument(items), type: "application/rss+xml")])
        guard case .feed(let candidate) = try await SourceDetector(transport: transport).detect(address, in: library.library) else {
            Issue.record("not a feed")
            return
        }
        #expect(candidate.latestItems.map(\.title) == ["new", "old", "undated A"])
        #expect(candidate.itemCount == 4)
    }

    @Test("a page with one feed: the page once, the feed once, nothing else it mentions")
    func pageWithOneFeed() async throws {
        let library = try await SourceFixture.make()
        defer { library.remove() }
        let html = page(
            rssLink("/feed.xml") + #"<link rel="icon" href="/favicon.ico"><link rel="stylesheet" href="/s.css"><script src="/app.js"></script>"#,
            extra: #"<img src="/a.png"><a href="/other">x</a><a href="/feed">y</a>"#
        )
        let transport = RoutedTransport([
            site: RoutedTransport.answer(html, type: "text/html"),
            "https://site.example/feed.xml": RoutedTransport.rss("Site", link: false),
        ])
        guard case .page(let found) = try await SourceDetector(transport: transport).detect("site.example", in: library.library) else {
            Issue.record("not a page")
            return
        }
        #expect(found.address == site)
        #expect(found.title == "A Page")
        #expect(found.declaredCount == 1)
        #expect(transport.requested == [site, "https://site.example/feed.xml"])
        let candidate = try #require(found.candidates.first)
        guard case .usable(let feed) = candidate.state else {
            Issue.record("not usable: \(candidate.state)")
            return
        }
        // The feed names no site link, so the page is its site link.
        #expect(feed.siteURL == site)

        try await library.library.addFeedSource(feed, name: "Site", categoryID: library.category)
        let stored = try #require(try await library.library.sources().first)
        #expect(stored.url == "https://site.example/feed.xml")
        #expect(stored.siteURL == site)
        #expect(try await library.library.articles().count == 2)
        #expect(transport.requested.count == 2)
    }

    @Test("a candidate already in the library is marked and not fetched")
    func candidateAlreadyStored() async throws {
        let library = try await SourceFixture.make()
        defer { library.remove() }
        try await library.library.addWebPageSource(address: "https://site.example/feed.xml", name: "Old", categoryID: library.category)
        let transport = RoutedTransport([
            site: RoutedTransport.answer(page(rssLink("/feed.xml")), type: "text/html"),
            "https://site.example/feed.xml": RoutedTransport.rss("Feed"),
        ])
        guard case .page(let found) = try await SourceDetector(transport: transport).detect(site, in: library.library) else {
            Issue.record("not a page")
            return
        }
        guard case .alreadyAdded(let existing) = found.candidates.first?.state else {
            Issue.record("\(found.candidates)")
            return
        }
        #expect(existing.name == "Old")
        #expect(existing.categoryName == "News")
        #expect(transport.requested == [site])
    }

    @Test("an address already in the library is a duplicate before any request")
    func typedAlreadyStored() async throws {
        let library = try await SourceFixture.make()
        defer { library.remove() }
        try await library.library.addWebPageSource(address: "https://site.example/", name: "Site", categoryID: library.category)
        let transport = RoutedTransport([:])
        let detection = try await SourceDetector(transport: transport).detect("  SITE.example ", in: library.library)
        guard case .duplicate(let existing) = detection else {
            Issue.record("\(detection)")
            return
        }
        #expect(existing.name == "Site")
        #expect(existing.categoryID == library.category)
        #expect(existing.categoryName == "News")
        #expect(transport.requested.isEmpty)
    }

    @Test("the https upgrade: stored when the fetch ended at the twin; a duplicate when the twin is stored")
    func httpsUpgrade() async throws {
        let library = try await SourceFixture.make()
        defer { library.remove() }
        let http = "http://feeds.example/rss.xml"
        let https = "https://feeds.example/rss.xml"
        let transport = RoutedTransport([http: RoutedTransport.rss("Up", final: https)])
        guard case .feed(let candidate) = try await SourceDetector(transport: transport).detect(http, in: library.library) else {
            Issue.record("not a feed")
            return
        }
        #expect(candidate.address == https)
        // Another final address is never stored.
        let moved = RoutedTransport([http: RoutedTransport.rss("Moved", final: "https://cdn.example/rss.xml")])
        guard case .feed(let kept) = try await SourceDetector(transport: moved).detect(http, in: library.library) else {
            Issue.record("not a feed")
            return
        }
        #expect(kept.address == http)

        try await library.library.addFeedSource(candidate, name: "Up", categoryID: library.category)
        let again = RoutedTransport([http: RoutedTransport.rss("Up", final: https)])
        guard case .duplicate(let existing) = try await SourceDetector(transport: again).detect(http, in: library.library) else {
            Issue.record("not a duplicate")
            return
        }
        #expect(existing.name == "Up")
        #expect(again.requested == [http])
    }

    @Test("a declared candidate whose https twin is stored is marked")
    func candidateUpgradeStored() async throws {
        let library = try await SourceFixture.make()
        defer { library.remove() }
        try await library.library.addWebPageSource(address: "https://site.example/feed.xml", name: "Twin", categoryID: library.category)
        let transport = RoutedTransport([
            site: RoutedTransport.answer(page(rssLink("http://site.example/feed.xml")), type: "text/html"),
            "http://site.example/feed.xml": RoutedTransport.rss("Feed", final: "https://site.example/feed.xml"),
        ])
        guard case .page(let found) = try await SourceDetector(transport: transport).detect(site, in: library.library),
              case .alreadyAdded(let existing) = found.candidates.first?.state
        else {
            Issue.record("not marked")
            return
        }
        #expect(existing.name == "Twin")
    }

    @Test("a page without feeds, and a PDF: a page with no candidates; saved as a web page with no further request")
    func pageWithoutFeeds() async throws {
        let library = try await SourceFixture.make()
        defer { library.remove() }
        let pdf = "https://site.example/doc.pdf"
        let transport = RoutedTransport([
            site: RoutedTransport.answer(page("", title: "Plain"), type: "text/html; charset=utf-8"),
            pdf: RoutedTransport.answer("%PDF-1.7", type: "application/pdf"),
        ])
        let detector = SourceDetector(transport: transport)
        guard case .page(let plain) = try await detector.detect(site, in: library.library) else {
            Issue.record("not a page")
            return
        }
        #expect(plain.title == "Plain")
        #expect(plain.candidates.isEmpty)
        guard case .page(let document) = try await detector.detect(pdf, in: library.library) else {
            Issue.record("not a page")
            return
        }
        #expect(document.title == nil)
        #expect(document.candidates.isEmpty)

        try await library.library.addWebPageSource(address: plain.address, name: "Plain", categoryID: library.category)
        #expect(transport.requested == [site, pdf])
        let stored = try #require(try await library.library.sources().first)
        #expect(stored.kind == .webpage)
        #expect(try await library.library.articles().isEmpty)
    }

    static let failures: [(TransportRoute, CollectionFailure, Bool)] = [
        (.failing(.unreachable), .unreachable, false),
        (.failing(.timedOut), .timedOut, false),
        (.status(404), .gone, false),
        (.status(410), .gone, false),
        (.status(403), .httpStatus(403), true),
        (.status(500), .httpStatus(500), true),
        (.failing(.declinedAuthentication(status: 401)), .httpStatus(401), true),
        (.failing(.tooLarge), .tooLarge, true),
        (.failing(.tooManyRedirects), .tooManyRedirects, true),
        (.failing(.unsupportedAddress), .unsupportedAddress, false),
    ]

    enum TransportRoute: Sendable {
        case failing(TransportFailure)
        case status(Int)

        var route: RoutedTransport.Route {
            switch self {
            case .failing(let failure): RoutedTransport.failing(failure)
            case .status(let status): RoutedTransport.answer("", type: "text/html", status: status)
            }
        }
    }

    @Test("each failure: its reason, whether a web page may be saved, and whether https:// was added", arguments: failures)
    func failure(route: TransportRoute, reason: CollectionFailure, offersWebPage: Bool) async throws {
        let library = try await SourceFixture.make()
        defer { library.remove() }
        let transport = RoutedTransport([site: route.route])
        let detector = SourceDetector(transport: transport)
        for (typed, added) in [("site.example", true), (site, false)] {
            guard case .failed(let failure) = try await detector.detect(typed, in: library.library) else {
                Issue.record("not a failure")
                return
            }
            #expect(failure.reason == reason)
            #expect(failure.offersWebPage == offersWebPage)
            #expect(failure.addedScheme == added)
            #expect(failure.address == site)
        }
        #expect(try await rowCounts(library.library)["source"] == 0)
    }

    @Test("an address refused by the normal form makes no request")
    func invalid() async throws {
        let library = try await SourceFixture.make()
        defer { library.remove() }
        let transport = RoutedTransport([:])
        #expect(try await SourceDetector(transport: transport).detect("feed://x.example/", in: library.library)
            == .invalidAddress(.unsupportedScheme))
        #expect(try await SourceDetector(transport: transport).detect("  ", in: library.library) == .invalidAddress(.empty))
        #expect(transport.requested.isEmpty)
    }

    @Test("cancellation before, during the page fetch and during candidate fetches throws and writes nothing")
    func cancellation() async throws {
        let library = try await SourceFixture.make()
        defer { library.remove() }
        let before = try await rowCounts(library.library)

        let idle = RoutedTransport([site: RoutedTransport.rss("Feed")])
        let cancelledFirst = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SourceDetector(transport: idle).detect(site, in: library.library)
        }
        await #expect(throws: CancellationError.self) { try await cancelledFirst.value }

        let pageStarted = Signal()
        let slowPage = RoutedTransport([site: { _ in
            pageStarted.fire()
            try await Task.sleep(for: .seconds(3_600))
            throw TransportFailure.timedOut
        }])
        let duringPage = Task { try await SourceDetector(transport: slowPage).detect(site, in: library.library) }
        await pageStarted.wait()
        duringPage.cancel()
        await #expect(throws: CancellationError.self) { try await duringPage.value }

        let candidateStarted = Signal()
        let slowCandidate = RoutedTransport([
            site: RoutedTransport.answer(page(rssLink("/feed.xml")), type: "text/html"),
            "https://site.example/feed.xml": { _ in
                candidateStarted.fire()
                try await Task.sleep(for: .seconds(3_600))
                throw TransportFailure.timedOut
            },
        ])
        let duringCandidates = Task { try await SourceDetector(transport: slowCandidate).detect(site, in: library.library) }
        await candidateStarted.wait()
        duringCandidates.cancel()
        await #expect(throws: CancellationError.self) { try await duringCandidates.value }

        #expect(try await rowCounts(library.library) == before)
    }

    @Test("no detection changes the library")
    func detectionNeverWrites() async throws {
        let library = try await SourceFixture.make()
        defer { library.remove() }
        try await library.library.addWebPageSource(address: "https://stored.example/", name: "Stored", categoryID: library.category)
        let before = try await rowCounts(library.library)
        let transport = RoutedTransport([
            site: RoutedTransport.answer(page(rssLink("/feed.xml") + rssLink("https://stored.example/")), type: "text/html"),
            "https://site.example/feed.xml": RoutedTransport.rss("Feed"),
            "https://feed.example/": RoutedTransport.rss("Direct"),
        ])
        let detector = SourceDetector(transport: transport)
        for typed in [site, "https://feed.example/", "https://stored.example/", "https://missing.example/", "mailto:x"] {
            _ = try await detector.detect(typed, in: library.library)
        }
        #expect(try await rowCounts(library.library) == before)
    }
}

extension TimedAndHeavySuites {
    /// RD05 criterion 3: the candidate phase's concurrency and its overall
    /// limit, which wait on the clock.
    @Suite("Source detection, timed")
    struct SourceDetectorTimedTests {
        let site = "https://site.example/"

        @Test("six declared: five kept, at most four in flight, the page once")
        func sixDeclared() async throws {
            let library = try await SourceFixture.make()
            defer { library.remove() }
            var routes: [String: RoutedTransport.Route] = [:]
            var links = ""
            for index in 1...6 {
                let address = "https://site.example/feed\(index).xml"
                routes[address] = RoutedTransport.rss("Feed\(index)", delay: .milliseconds(50))
                links += rssLink(address)
            }
            routes[site] = RoutedTransport.answer(page(links), type: "text/html")
            let transport = RoutedTransport(routes)
            guard case .page(let found) = try await SourceDetector(transport: transport).detect(site, in: library.library) else {
                Issue.record("not a page")
                return
            }
            #expect(found.candidates.map(\.address) == (1...5).map { "https://site.example/feed\($0).xml" })
            #expect(found.declaredCount == 6)
            #expect(transport.maximumInFlight <= SourceDetector.maximumConcurrentCandidates)
            #expect(transport.maximumInFlight > 1, "fetched in parallel")
            #expect(transport.requested.filter { $0 == site }.count == 1)
            #expect(Set(transport.requested) == Set([site] + (1...5).map { "https://site.example/feed\($0).xml" }))
            #expect(transport.requested.count == 6)
            for candidate in found.candidates {
                guard case .usable = candidate.state else {
                    Issue.record("\(candidate.address) is \(candidate.state)")
                    continue
                }
            }
        }

        @Test("a failing candidate beside good ones; one that never answers is not checked within the limit")
        func failingAndUnanswered() async throws {
            let library = try await SourceFixture.make()
            defer { library.remove() }
            let links = rssLink("/good.xml") + rssLink("/gone.xml") + rssLink("/page.xml") + rssLink("/never.xml")
            let transport = RoutedTransport([
                site: RoutedTransport.answer(page(links), type: "text/html"),
                "https://site.example/good.xml": RoutedTransport.rss("Good"),
                "https://site.example/gone.xml": RoutedTransport.answer("", type: "text/html", status: 404),
                "https://site.example/page.xml": RoutedTransport.answer(page(""), type: "text/html"),
                "https://site.example/never.xml": RoutedTransport.never,
            ])
            let clock = ContinuousClock()
            let start = clock.now
            let detection = try await SourceDetector(transport: transport, candidateLimit: .seconds(1))
                .detect(site, in: library.library)
            #expect(clock.now - start < .seconds(10))
            guard case .page(let found) = detection else {
                Issue.record("not a page")
                return
            }
            let states = found.candidates.map(\.state)
            guard states.count == 4, case .usable = states[0] else {
                Issue.record("\(states)")
                return
            }
            #expect(states[1] == .failed(.gone))
            #expect(states[2] == .failed(.notAFeed))
            #expect(states[3] == .notChecked)
        }
    }
}

/// RD05 version 5: white space before the XML declaration.
@Suite("Feed parser: leading white space")
struct LeadingWhiteSpaceTests {
    @Test("an RSS feed with white space before its XML declaration parses like the same feed without it")
    func leadingWhiteSpaceBeforeDeclaration() throws {
        let data = try FeedFixture.data("rss2.xml")
        let plain = try #require(parse(data))
        for prefix in ["\n", " \r\n\t "] {
            #expect(parse(Data(prefix.utf8) + data) == plain)
            #expect(parse(Data([0xEF, 0xBB, 0xBF]) + Data(prefix.utf8) + data) == plain)
        }
    }
}
