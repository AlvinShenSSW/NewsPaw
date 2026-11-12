import Foundation
@testable import NewsPawKit
import Testing

/// V1: Swift hashes and compares a string made of a long run of combining
/// marks in time growing with the square of its length. The reader bounds
/// the length of every feed string it hashes or compares instead; these
/// documents put 80,000 marks in each such position and must return well
/// under a second (the review measured up to 6.2 s before the bounds).
@Suite("Length bounds on compared strings", .serialized)
struct LengthBoundTests {
    /// "a" followed by 80,000 combining marks (160,001 UTF-8 bytes).
    static let marks = "a" + String(repeating: "\u{0301}\u{0316}", count: 40_000)

    static let rssHead = #"<?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>T</title><item><guid>1</guid><title>One</title></item>"#

    static func time(_ label: String, _ data: Data, charset: String? = nil) async -> (ParsedFeed?, Duration) {
        let start = ContinuousClock.now
        let feed = await Task.detached { FeedParser.parse(data, charset: charset, baseURL: fixtureBase) }.value
        let elapsed = ContinuousClock.now - start
        print("length bound | \(label) | \(data.count) bytes | \(elapsed)")
        return (feed, elapsed)
    }

    static let limit = Duration.milliseconds(500)

    @Test("a namespace address or prefix of 80,000 marks stops reading at its element; completed items are kept")
    func namespaces() async throws {
        let documents = [
            ("namespace address, declared twice", Self.rssHead + #"<y xmlns:p="\#(Self.marks)"/><y xmlns:p="\#(Self.marks)z"/></channel></rss>"#),
            ("default namespace address", Self.rssHead + #"<y xmlns="\#(Self.marks)"/><y xmlns="\#(Self.marks)z"/></channel></rss>"#),
            ("namespace prefix", Self.rssHead + #"<y xmlns:\#(Self.marks)="u:1"/><y xmlns:\#(Self.marks)z="u:2"/></channel></rss>"#),
        ]
        for (label, text) in documents {
            let (feed, elapsed) = await Self.time(label, Data(text.utf8))
            #expect(try #require(feed).items.map(\.externalID) == ["1"], "\(label)")
            #expect(feed?.isComplete == false, "\(label)")
            #expect(elapsed < Self.limit, "\(label)")
        }
        // Just past the limit, a prefix stops reading too.
        let prefix = String(repeating: "b", count: 1_025)
        let feed = try #require(parse(Self.rssHead + #"<y xmlns:\#(prefix)="u:1"/><item><guid>2</guid></item></channel></rss>"#))
        #expect(feed.items.map(\.externalID) == ["1"])
        #expect(feed.isComplete == false)
    }

    @Test("an element or attribute name of 20,000 or 80,000 marks stops reading there")
    func names() async throws {
        for count in [20_000, 80_000] {
            let name = "a" + String(repeating: "\u{0301}\u{0316}", count: count / 2)
            for (label, text) in [
                ("element name of \(count) marks", Self.rssHead + "<\(name)/><\(name)z/></channel></rss>"),
                ("attribute name of \(count) marks", Self.rssHead + #"<y \#(name)="1"/><y \#(name)z="1"/></channel></rss>"#),
            ] {
                let (feed, elapsed) = await Self.time(label, Data(text.utf8))
                #expect(try #require(feed).items.map(\.externalID) == ["1"], "\(label)")
                #expect(feed?.isComplete == false, "\(label)")
                #expect(elapsed < Self.limit, "\(label)")
            }
        }
        // At the limit a name is read.
        let atLimit = "n" + String(repeating: "\u{0301}", count: 511)
        #expect(atLimit.utf8.count == 1_023)
        let feed = try #require(parse(Self.rssHead + "<\(atLimit)/><item><guid>2</guid></item></channel></rss>"))
        #expect(feed.items.map(\.externalID) == ["1", "2"])
        #expect(feed.isComplete)
    }

    @Test("attribute values of 80,000 marks that the reader compares match nothing")
    func comparedAttributeValues() async throws {
        let atom = #"<feed xmlns="http://www.w3.org/2005/Atom"><title>X</title><entry><id>1</id><link rel="\#(Self.marks)" href="/a"/><link rel="enclosure" type="\#(Self.marks)" href="/i.png"/><title type="\#(Self.marks)">t</title><content type="\#(Self.marks)">c</content></entry></feed>"#
        let (atomFeed, atomTime) = await Self.time("Atom rel and type", Data(atom.utf8))
        let entry = try #require(atomFeed?.items.first)
        #expect(entry.url == nil)
        #expect(entry.imageURL == nil)
        #expect(entry.title == nil)
        #expect(atomTime < Self.limit)

        let rss = #"<rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/"><channel><title>T</title><item><guid isPermaLink="\#(Self.marks)">https://example.invalid/p</guid><enclosure url="/e.png" type="\#(Self.marks)"/><media:content url="/m.png" medium="\#(Self.marks)" type="\#(Self.marks)"/></item></channel></rss>"#
        let (rssFeed, rssTime) = await Self.time("RSS isPermaLink, enclosure type, media medium and type", Data(rss.utf8))
        let item = try #require(rssFeed?.items.first)
        // A value that is not "false" leaves the guid a permalink.
        #expect(item.url == "https://example.invalid/p")
        #expect(item.imageURL == nil)
        #expect(rssTime < Self.limit)

        // At the limit a value is still compared.
        let padded = "alternate" + String(repeating: " ", count: 247)
        let read = try #require(parse(#"<feed xmlns="http://www.w3.org/2005/Atom"><title>X</title><entry><id>1</id><link rel="\#(padded)" href="https://example.invalid/a"/></entry></feed>"#))
        #expect(read.items.first?.url == "https://example.invalid/a")
    }

    @Test("an encoding label of 80,000 marks, declared or sent as the charset, is refused at once")
    func labels() async {
        let body = #"<rss version="2.0"><channel><title>T</title><item><guid>1</guid></item></channel></rss>"#
        let (declared, declaredTime) = await Self.time("declared encoding label", Data((#"<?xml version="1.0" encoding="\#(Self.marks)"?>"# + body).utf8))
        #expect(declared == nil)
        #expect(declaredTime < Self.limit)
        #expect(StartTagScan.mode(forLabel: String(repeating: "a", count: 65)) == nil)

        // A broken document retried with the header's charset.
        let broken = Data(Array((#"<?xml version="1.0"?>"# + body.replacingOccurrences(of: "</channel></rss>", with: "")).utf8) + [0xFF] + Array("</channel></rss>".utf8))
        let (retried, retriedTime) = await Self.time("header charset", broken, charset: Self.marks)
        #expect(retried?.isComplete == false)
        #expect(retriedTime < Self.limit)
    }

    @Test("dates of 80,000 marks are no date, at once")
    func dates() async throws {
        let rss = Self.rssHead.replacingOccurrences(of: "<title>One</title>", with: "<title>One</title><pubDate>Mon, 02 Jan 2006 15:04:05 GMT\(Self.marks)</pubDate>")
            + "</channel></rss>"
        let (feed, elapsed) = await Self.time("RSS pubDate", Data(rss.utf8))
        #expect(try #require(feed).items.first?.publishedAt == nil)
        #expect(elapsed < Self.limit)
        #expect(FeedDate.parse(String(repeating: " ", count: 2_000) + "2006-01-02") == nil)
        #expect(FeedDate.parse(String(repeating: " ", count: 1_000) + "2006-01-02") != nil)
    }

    @Test("JSON: a key of 80,000 marks makes the document not a feed; the version and other values are read in linear time")
    func json() async throws {
        let key = #"{"version":"https://jsonfeed.org/version/1","items":[{"id":"1","title":"One"}],""# + Self.marks + #"":1}"#
        let (keyed, keyTime) = await Self.time("JSON object key", Data(key.utf8))
        #expect(keyed == nil)
        #expect(keyTime < Self.limit)

        let longKey = String(repeating: "k", count: 1_025)
        #expect(parse(#"{"version":"https://jsonfeed.org/version/1","items":[],"\#(longKey)":1}"#) == nil)
        #expect(parse(#"{"version":"https://jsonfeed.org/version/1","items":[],"\#(longKey.dropLast())":1}"#) != nil)
        // A long string that is a value, not a key, is not limited.
        #expect(parse(#"{"version":"https://jsonfeed.org/version/1","items":[{"id":"\#(longKey)"}]}"#)?.items.count == 1)

        let values = #"{"version":"https://jsonfeed.org/version/1\#(Self.marks)","items":[{"id":"1","date_published":"2006-01-02T15:04:05Z\#(Self.marks)"}]}"#
        let (valued, valueTime) = await Self.time("JSON version and date values", Data(values.utf8))
        #expect(try #require(valued).items.first?.publishedAt == nil)
        #expect(valueTime < Self.limit)
    }
}
