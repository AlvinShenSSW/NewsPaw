import Foundation
@testable import NewsPawKit
import Testing

/// RD05 criteria 9 and 19: the suggested list and the UI tests' fixture
/// transport.
@Suite("Suggested sources")
struct SuggestedSourcesTests {
    /// The exact shipped set: every entry passed the manual check through
    /// the app (pull request, "Suggested sources").
    static let shipped: [(SuggestedSourceGroup, String, String)] = [
        (.world, "BBC News · World", "https://feeds.bbci.co.uk/news/world/rss.xml"),
        (.japan, "NHK News", "https://news.web.nhk/n-data/conf/na/rss/cat0.xml"),
        (.japan, "Yahoo! JAPAN News · Domestic", "https://news.yahoo.co.jp/rss/topics/domestic.xml"),
        (.japan, "Yahoo! JAPAN News · Entertainment", "https://news.yahoo.co.jp/rss/topics/entertainment.xml"),
        (.australia, "The Guardian · Australia news", "https://www.theguardian.com/australia-news/rss"),
        (.china, "China News Service · Domestic", "https://www.chinanews.com.cn/rss/china.xml"),
        (.china, "China News Service · Culture", "https://www.chinanews.com.cn/rss/culture.xml"),
        (.tech, "MacRumors", "https://feeds.macrumors.com/MacRumors-Front"),
        (.tech, "Apple Newsroom", "https://www.apple.com/newsroom/rss-feed.rss"),
        (.ai, "OpenAI News", "https://openai.com/news/rss.xml"),
        (.ai, "Hugging Face Blog", "https://huggingface.co/blog/feed.xml"),
    ]

    @Test("the list is the shipped set; each entry a unique https normal form with a name")
    func list() {
        let all = SuggestedSources.all
        #expect(all.map(\.group) == Self.shipped.map(\.0))
        #expect(all.map(\.name) == Self.shipped.map(\.1))
        #expect(all.map(\.address) == Self.shipped.map(\.2))
        #expect(all.count <= 11)
        #expect(Set(all.map(\.address)).count == all.count)
        for entry in all {
            #expect(SourceAddress.normalForm(of: entry.address) == entry.address, "\(entry.address)")
            #expect(entry.address.hasPrefix("https://"), "\(entry.address)")
            #expect(!entry.name.isEmpty)
        }
    }

    @Test("a normal library offers the list; an adult library is given none")
    func partitions() async throws {
        let fixture = try await SourceFixture.make()
        defer { fixture.remove() }
        #expect(fixture.library.suggestedSources == SuggestedSources.all)
        let adult = try await fixture.store.createAdultLibrary()
        #expect(adult.suggestedSources.isEmpty)
    }
}

@Suite("Fixture transport")
struct FixtureTransportTests {
    private func fetch(_ transport: FixtureTransport, _ address: String) async throws -> FetchResult {
        try await FeedFetcher(transport: transport).fetch(address)
    }

    @Test("the table answers, the suggested address among them; anything else is unreachable")
    func table() async throws {
        let transport = FixtureTransport()
        guard case .feed(let feed) = try await fetch(transport, FixtureTransport.Address.feed) else {
            Issue.record("not a feed")
            return
        }
        #expect(feed.feed.items.count == 3)
        guard case .feed(let suggested) = try await fetch(transport, FixtureTransport.Address.suggested) else {
            Issue.record("the suggested address is not answered")
            return
        }
        #expect(suggested.feed.items.count == 1)
        #expect(SuggestedSources.all.contains { $0.address == FixtureTransport.Address.suggested })
        guard case .notAFeed = try await fetch(transport, FixtureTransport.Address.twoFeeds) else {
            Issue.record("not a page")
            return
        }
        #expect(try await fetch(transport, FixtureTransport.Address.forbidden) == .failed(.httpStatus(403)))
        #expect(try await fetch(transport, FixtureTransport.Address.timesOut) == .failed(.timedOut))
        #expect(try await fetch(transport, FixtureTransport.Address.unreachable) == .failed(.unreachable))
        #expect(try await fetch(transport, "https://example.com/") == .failed(.unreachable))
        #expect(try await fetch(transport, "https://news.yahoo.co.jp/rss/topics/domestic.xml") == .failed(.unreachable))
    }

    @Test("the pages detect as the UI tests expect")
    func pages() async throws {
        let fixture = try await SourceFixture.make()
        defer { fixture.remove() }
        let detector = SourceDetector(transport: FixtureTransport(), candidateLimit: FixtureTransport.candidateLimit)
        guard case .page(let two) = try await detector.detect(FixtureTransport.Address.twoFeeds, in: fixture.library) else {
            Issue.record("not a page")
            return
        }
        #expect(two.candidates.count == 2)
        #expect(two.candidates.allSatisfy { if case .usable = $0.state { true } else { false } })
        guard case .page(let none) = try await detector.detect(FixtureTransport.Address.noFeed, in: fixture.library) else {
            Issue.record("not a page")
            return
        }
        #expect(none.title == "Plain Page" && none.candidates.isEmpty)
    }

    @Test("the reading feed's bodies convert as the UI tests expect: every block kind, an excerpt, a hostile body, cut bodies, pictures, an empty body")
    func readingFeed() async throws {
        let transport = FixtureTransport()
        guard case .feed(let fetched) = try await fetch(transport, FixtureTransport.Address.reading) else {
            Issue.record("not a feed")
            return
        }
        let items = fetched.feed.items
        #expect(items.map(\.title) == [
            "Every block", "Line heights", "Short note", "Hostile story", "Cut story", "Cut linkless story",
            "Picture story", "Hundred pictures", "Empty body",
        ])
        func body(_ title: String) throws -> ArticleBlocks {
            let item = try #require(items.first { $0.title == title })
            return ArticleBlocks.make(html: item.contentHTML ?? "", baseURL: item.url.flatMap(URL.init(string:)))
        }
        func kinds(_ blocks: [ArticleBlock]) -> Set<String> {
            Set(blocks.map { block in
                switch block.kind {
                case .paragraph: "paragraph"
                case .heading: "heading"
                case .image: "image"
                case .code: "code"
                case .rule: "rule"
                }
            })
        }

        let every = try body("Every block")
        #expect(kinds(every.blocks) == ["paragraph", "heading", "image", "code", "rule"])
        #expect(ArticleBlocks.isFullText(every.blocks))
        #expect(!every.isCut)
        #expect(every.blocks.contains { $0.quoteDepth == 2 })
        #expect(every.blocks.contains { $0.listDepth == 2 && $0.marker == .bullet })
        #expect(every.blocks.contains { $0.marker == .number(3) })
        #expect(every.blocks.contains { $0.isCaption })
        let links = every.blocks.flatMap { block -> [URL] in
            if case .paragraph(let runs) = block.kind { runs.compactMap(\.link) } else { [] }
        }
        #expect(links.map(\.absoluteString) == ["https://example.invalid/articles/linked-page"])
        #expect(every.blocks.contains { ArticleBlocks.containsKana($0.plainText ?? "") })

        let short = try body("Short note")
        #expect(short.blocks.count == 1)
        #expect(!ArticleBlocks.isFullText(short.blocks))

        let hostile = try body("Hostile story")
        let text = hostile.blocks.compactMap(\.plainText).joined(separator: "|")
        #expect(text == "Before the links.|A script link and a data link and a safe link.|After the links.")
        let images = hostile.blocks.compactMap { block -> ArticleImage? in
            if case .image(let image) = block.kind { image } else { nil }
        }
        #expect(images.map(\.url.absoluteString) == [FixtureTransport.Address.readingImages + "photo.png"])

        let cut = try body("Cut story")
        #expect(cut.isCut)
        #expect(cut.blocks.count == ArticleBlocks.maximumBlocks)
        #expect(ArticleBlocks.isFullText(cut.blocks))
        let longInput = try body("Cut linkless story")
        #expect(longInput.isCut)
        #expect(longInput.blocks.compactMap(\.plainText) == ["The start of a story too long to read whole."])
        #expect(try #require(items.first { $0.title == "Cut linkless story" }).url == nil)

        let pictures = try body("Picture story")
        #expect(pictures.blocks.filter { if case .image = $0.kind { true } else { false } }.count == 6)
        #expect(try body("Hundred pictures").blocks.filter { if case .image = $0.kind { true } else { false } }.count == 100)

        let empty = try #require(items.first { $0.title == "Empty body" })
        #expect(try body("Empty body").blocks.isEmpty)
        #expect(empty.excerpt == "Only the feed's summary is left of this one.")

        #expect(try body("Line heights").blocks.count == 6)
    }

    @Test("the reading feed's images: sizes as named, one that fails once per transport, one that is no image, the rest unreachable")
    func readingImages() async throws {
        let transport = FixtureTransport()
        func image(_ name: String) async throws -> TransportResponse {
            try await transport.fetch(TransportRequest(url: try #require(URL(string: FixtureTransport.Address.readingImages + name))))
        }
        func size(_ data: Data) -> [Int] {
            BodyImageLoader.pixelSize(of: data).map { [$0.width, $0.height] } ?? []
        }
        #expect(size(try await image("photo.png").body) == [600, 400])
        #expect(size(try await image("small.png").body) == [60, 40])
        #expect(size(try await image("pixel.png").body) == [1, 1])
        #expect(size(try await image("big/7.png").body) == [2_400, 1_600])
        #expect(ThumbnailLoader.reduced(try await image("vector.svg").body) == nil)
        await #expect(throws: TransportFailure.unreachable) { try await image("flaky.png") }
        #expect(size(try await image("flaky.png").body) == [600, 400])
        #expect(size(try await image("flaky.png").body) == [600, 400])
        await #expect(throws: TransportFailure.unreachable) { try await image("missing.png") }
        await #expect(throws: TransportFailure.unreachable) { try await image("tracker.png") }
    }

    @Test("the sequenced address answers a feed, then fails, then answers again")
    func sequence() async throws {
        let transport = FixtureTransport()
        guard case .feed = try await fetch(transport, FixtureTransport.Address.sequence) else {
            Issue.record("first")
            return
        }
        #expect(try await fetch(transport, FixtureTransport.Address.sequence) == .failed(.httpStatus(500)))
        guard case .feed = try await fetch(transport, FixtureTransport.Address.sequence) else {
            Issue.record("third")
            return
        }
        // Counted per transport.
        guard case .feed = try await fetch(FixtureTransport(), FixtureTransport.Address.sequence) else {
            Issue.record("a new transport starts again")
            return
        }
    }
}

extension TimedAndHeavySuites {
    @Suite("Fixture transport, timed")
    struct FixtureTransportTimedTests {
        @Test("the slow declared feed is not checked within the fixture limit, and answers when asked directly")
        func slowFeed() async throws {
            let fixture = try await SourceFixture.make()
            defer { fixture.remove() }
            let detector = SourceDetector(transport: FixtureTransport(), candidateLimit: FixtureTransport.candidateLimit)
            guard case .page(let page) = try await detector.detect(FixtureTransport.Address.slowFeeds, in: fixture.library) else {
                Issue.record("not a page")
                return
            }
            #expect(page.candidates.map(\.state).last == .notChecked)
            guard case .feed = try await detector.detect(FixtureTransport.Address.slowFeed, in: fixture.library) else {
                Issue.record("the slow feed did not answer")
                return
            }
        }
    }
}
