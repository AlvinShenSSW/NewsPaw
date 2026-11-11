import FeedKit
import Foundation
import Testing

@Suite("FeedKit")
struct FeedKitCheck {
    @Test("parses an RSS 1.0 (RDF) feed into items")
    func parsesRSS1Feed() throws {
        let feed = try Feed(data: Fixture.data("rss1", "rdf"))

        guard case .rdf(let rdf) = feed else {
            Issue.record("Expected an RDF feed, got \(feed)")
            return
        }
        #expect(rdf.channel?.title == "Synthetic RDF feed")
        let items = try #require(rdf.items)
        #expect(items.map(\.title) == ["First synthetic item", "Second synthetic item"])
        #expect(items.map(\.link) == [
            "https://example.invalid/articles/first",
            "https://example.invalid/articles/second",
        ])
        #expect(items.first?.description == "The first item's excerpt.")
    }
}
