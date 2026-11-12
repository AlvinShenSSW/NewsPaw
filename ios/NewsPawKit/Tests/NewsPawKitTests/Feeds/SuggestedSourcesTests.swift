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
