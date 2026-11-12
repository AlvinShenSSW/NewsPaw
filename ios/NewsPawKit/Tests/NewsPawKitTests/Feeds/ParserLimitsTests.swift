import Foundation
@testable import NewsPawKit
import Testing

/// The parser's limits on documents that would otherwise crash it or take
/// time growing faster than their size (criteria 4, 13; fix round 1, R1–R3).
/// The numbers here are the limits in `JSONFeedReader` and `XMLFeedReader`.
@Suite("Parser limits")
struct ParserLimitsTests {
    // MARK: - R1: nested JSON

    private static let jsonHead = #"{"version":"https://jsonfeed.org/version/1","items":[{"id":"1","title":"One"}],"x":"#

    /// Parses on a detached task, so on a concurrency thread's small stack,
    /// as the app does.
    private static func parseDetached(_ text: String) async -> ParsedFeed? {
        let data = Data(text.utf8)
        return await Task.detached { FeedParser.parse(data, charset: nil, baseURL: fixtureBase) }.value
    }

    @Test("deeply nested JSON objects are not a feed and do not crash", arguments: [65, 600, 5_000, 200_000])
    func nestedJSONObjects(_ depth: Int) async {
        let closed = Self.jsonHead + String(repeating: #"{"a":"#, count: depth) + "1" + String(repeating: "}", count: depth) + "}"
        #expect(await Self.parseDetached(closed) == nil)
        let unclosed = Self.jsonHead + String(repeating: #"{"a":"#, count: depth)
        #expect(await Self.parseDetached(unclosed) == nil)
    }

    @Test("deeply nested JSON arrays, and arrays and objects mixed, are not a feed", arguments: [65, 600, 200_000])
    func nestedJSONArraysAndMixed(_ depth: Int) async {
        let arrays = Self.jsonHead + String(repeating: "[", count: depth) + String(repeating: "]", count: depth) + "}"
        #expect(await Self.parseDetached(arrays) == nil)
        let mixed = Self.jsonHead + String(repeating: #"[{"a":"#, count: depth / 2 + 1) + "1" + String(repeating: "}]", count: depth / 2 + 1) + "}"
        #expect(await Self.parseDetached(mixed) == nil)
        let unclosed = Self.jsonHead + String(repeating: #"[{"a":["#, count: depth)
        #expect(await Self.parseDetached(unclosed) == nil)
    }

    @Test("JSON nesting within the limit is read")
    func nestingWithinTheLimit() async throws {
        let depth = 60
        let text = Self.jsonHead + String(repeating: #"{"a":"#, count: depth) + "1" + String(repeating: "}", count: depth) + "}"
        let feed = try #require(await Self.parseDetached(text))
        #expect(feed.items.map(\.title) == ["One"])
    }

    @Test("brackets inside JSON strings, escaped quotes included, are not counted")
    func bracketsInsideStrings() async throws {
        let brackets = String(repeating: "{[", count: 10_000)
        let text = #"{"version":"https://jsonfeed.org/version/1.1","title":"\#(brackets) \"quoted {[ \\","items":[{"id":"\#(brackets)","title":"x \" [[[[ \\\\"}]}"#
        let feed = try #require(await Self.parseDetached(text))
        #expect(feed.items.count == 1)
        #expect(feed.items.first?.externalID == brackets)
        #expect(feed.items.first?.title == #"x " [[[[ \\"#)
    }

    @Test("a deeply nested JSON answer reaches the collector as not a feed")
    func nestedJSONThroughTheFetcher() async throws {
        let depth = 600
        let body = Data((Self.jsonHead + String(repeating: #"{"a":"#, count: depth) + "1" + String(repeating: "}", count: depth) + "}").utf8)
        let result = try await Task.detached {
            try await FeedFetcher(transport: FakeTransport.answering(body: body, headers: ["Content-Type": "application/feed+json"]))
                .fetch("https://example.invalid/feed.json")
        }.value
        #expect(result.failure == .notAFeed)
    }

    // MARK: - R2: internal entities

    private static func entityDocument(_ declarations: String, title: String = "Title") -> String {
        """
        <?xml version="1.0"?><!DOCTYPE rss [\(declarations)]><rss version="2.0"><channel><title>T</title>\
        <item><guid>1</guid><title>\(title)</title></item></channel></rss>
        """
    }

    @Test("an internal entity with a long value is refused: the document is not a feed")
    func longEntityRefused() {
        let value = String(repeating: "a", count: 257)
        #expect(parse(Self.entityDocument(#"<!ENTITY a "\#(value)">"#, title: "&a;")) == nil)
        #expect(parse(Self.entityDocument(#"<!ENTITY a "\#(String(repeating: "a", count: 2_000_000))">"#)) == nil)
    }

    @Test("an internal entity whose value refers to another entity is refused")
    func nestedEntityRefused() {
        #expect(parse(Self.entityDocument(#"<!ENTITY a "x"><!ENTITY b "&a;&a;">"#, title: "&b;")) == nil)
        #expect(parse(Self.entityDocument(#"<!ENTITY a "&amp;">"#)) == nil)
    }

    @Test("a short harmless entity, a character reference included, still parses")
    func shortEntityParses() throws {
        let value = String(repeating: "b", count: 256)
        let feed = try #require(parse(Self.entityDocument(#"<!ENTITY nbsp "&#160;"><!ENTITY co "\#(value)">"#, title: "a&nbsp;b &co;")))
        #expect(feed.items.map(\.externalID) == ["1"])
        #expect(feed.isComplete)
        // The parser hands over `&#160;` already decoded (U+00A0, two bytes,
        // no `&`), so it is allowed. The text of a document's own entities is
        // not delivered to the reader (recorded, not changed in this round).
        #expect(feed.items.first?.title == "ab")
    }

    @Test("an attribute-list declaration is refused: the document is not a feed")
    func attributeListRefused() {
        #expect(parse(Self.entityDocument(#"<!ATTLIST x a CDATA "v">"#)) == nil)
    }

    @Test("more declarations than the limit are refused; up to the limit they are read")
    func declarationCount() throws {
        let allowed = (0..<1024).map { #"<!ENTITY e\#($0) "v">"# }.joined()
        #expect(try #require(parse(Self.entityDocument(allowed))).items.count == 1)
        let refused = (0..<1025).map { #"<!ENTITY e\#($0) "v">"# }.joined()
        #expect(parse(Self.entityDocument(refused)) == nil)
    }

    // MARK: - R3: attributes and namespace mappings

    private static let itemThenOpen = #"<?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>T</title><item><guid>first</guid><title>first</title></item>"#

    private static func attributes(_ count: Int) -> String {
        (0..<count).map { #" a\#($0)="v""# }.joined()
    }

    @Test("a start tag with more attributes than the limit stops the document there; completed items are kept")
    func tooManyAttributes() throws {
        let document = Self.itemThenOpen + "<x\(Self.attributes(257))/><item><guid>after</guid></item></channel></rss>"
        let feed = try #require(parse(document))
        #expect(feed.items.map(\.externalID) == ["first"])
        #expect(feed.isComplete == false)
    }

    @Test("a start tag at the attribute limit is read")
    func attributesAtTheLimit() throws {
        let document = Self.itemThenOpen + "<x\(Self.attributes(256))/><item><guid>after</guid></item></channel></rss>"
        let feed = try #require(parse(document))
        #expect(feed.items.map(\.externalID) == ["first", "after"])
        #expect(feed.isComplete)
    }

    @Test("a root with more attributes than the limit is not a feed")
    func rootWithTooManyAttributes() {
        let declarations = (0..<300).map { #" xmlns:p\#($0)="u:\#($0)""# }.joined()
        #expect(parse(#"<rss version="2.0"\#(declarations)><channel><title>T</title><item><guid>1</guid></item></channel></rss>"#) == nil)
    }

    @Test("namespace mappings in scope past the limit stop the document; completed items are kept")
    func tooManyMappingsInScope() throws {
        let level = (0..<100).map { #" xmlns:q\#($0)="u:\#($0)""# }.joined()
        let document = Self.itemThenOpen + "<y\(level)><y\(level)><y\(level)><x/></y></y></y><item><guid>after</guid></item></channel></rss>"
        let feed = try #require(parse(document))
        #expect(feed.items.map(\.externalID) == ["first"])
        #expect(feed.isComplete == false)
        // Mappings that go out of scope do not add up.
        let siblings = Self.itemThenOpen + String(repeating: "<y\(level)><x/></y>", count: 10) + "<item><guid>after</guid></item></channel></rss>"
        let read = try #require(parse(siblings))
        #expect(read.items.map(\.externalID) == ["first", "after"])
        #expect(read.isComplete)
    }

    @Test("namespace mappings at the limit are read")
    func mappingsAtTheLimit() throws {
        let level = (0..<128).map { #" xmlns:q\#($0)="u:\#($0)""# }.joined()
        let document = Self.itemThenOpen + "<y\(level)><y\(level)><x/></y></y><item><guid>after</guid></item></channel></rss>"
        let feed = try #require(parse(document))
        #expect(feed.items.map(\.externalID) == ["first", "after"])
        #expect(feed.isComplete)
    }

    @Test("more distinct names than the limit stop the document; completed items are kept")
    func tooManyDistinctNames() throws {
        let names = (0..<5_000).map { "<e\($0)/>" }.joined()
        let feed = try #require(parse(Self.itemThenOpen + names + "<item><guid>after</guid></item></channel></rss>"))
        #expect(feed.items.map(\.externalID) == ["first"])
        #expect(feed.isComplete == false)
        let fewer = (0..<3_000).map { "<e\($0)/>" }.joined()
        let read = try #require(parse(Self.itemThenOpen + fewer + "<item><guid>after</guid></item></channel></rss>"))
        #expect(read.items.map(\.externalID) == ["first", "after"])
    }

    // MARK: - R12: a stop due in the namespace-mapping callback

    /// The review's shape (`crash-9884.xml`): after a completed item, four
    /// nested tags, each with 90 namespace declarations and 90 prefixed
    /// attributes. The third tag passes the limit of 256 mappings in scope
    /// inside the mapping callback, where aborting the parser used freed
    /// memory and ended the process.
    static func mappingCrashShape() -> String {
        var document = #"<?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>T</title><item><guid>1</guid><title>One</title></item><item><guid>2</guid>"#
        for level in 0..<4 {
            document += "<l\(level)" + (0..<90).map { #" xmlns:m\#(level)x\#($0)="u:\#($0)" m\#(level)x\#($0):a\#($0)="v""# }.joined() + ">"
        }
        return document
    }

    @Test("a mapping limit passed inside the mapping callback stops at the next element, without crashing")
    func mappingLimitInTheMappingCallback() async throws {
        let shape = Self.mappingCrashShape()
        let documents = [
            // The review's 9,884 bytes, cut inside the fourth tag.
            Data(Array(shape.utf8).prefix(9_884)),
            Data((shape + "</l3></l2></l1></l0></item><item><guid>3</guid></item></channel></rss>").utf8),
        ]
        // The review's crash came with a header charset, so that the cut
        // document is read a second time.
        for data in documents {
            for charset in [nil, "Shift_JIS"] {
                for _ in 0..<5 {
                    let feed = try #require(await Task.detached { FeedParser.parse(data, charset: charset, baseURL: fixtureBase) }.value)
                    #expect(feed.items.map(\.externalID) == ["1"])
                    #expect(feed.isComplete == false)
                }
            }
        }
    }

    // MARK: - R13 and R11: attribute-list declarations

    @Test("an enumerated attribute type of 25,000 values is not a feed and does not crash")
    func enumeratedAttributeType() async {
        let values = (0..<25_000).map { "v\($0)" }.joined(separator: "|")
        let body = #"<rss version="2.0"><channel><title>T</title><item><guid>1</guid></item></channel></rss>"#
        let documents = [
            #"<?xml version="1.0"?><!DOCTYPE rss [<!ATTLIST item kind (\#(values)) "v0">]>"# + body,
            // Unterminated: the parser would meet the enumeration all the same.
            #"<?xml version="1.0"?><!DOCTYPE rss [<!ATTLIST item kind (\#(values)"#,
        ]
        for document in documents {
            let data = Data(document.utf8)
            #expect(StartTagScan.cutOffset(in: data) == 0)
            #expect(await Task.detached { FeedParser.parse(data, charset: nil, baseURL: fixtureBase) }.value == nil)
        }
    }

    @Test("4,000 default attributes after an error return in milliseconds")
    func attributeDefaultsAfterAnError() async {
        let defaults = (0..<4_000).map { #" a\#($0) CDATA "v""# }.joined()
        let elements = String(repeating: "<x/>", count: 20_000)
        let data = Data((#"<?xml version="1.0"?><?xml x?><!DOCTYPE rss [<!ATTLIST x\#(defaults)>]><rss version="2.0"><channel><title>T</title>"#
            + elements + "<item><guid>1</guid></item></channel></rss>").utf8)
        let start = ContinuousClock.now
        let feed = await Task.detached { FeedParser.parse(data, charset: nil, baseURL: fixtureBase) }.value
        let elapsed = ContinuousClock.now - start
        print("R11 attribute defaults after an error | \(data.count) bytes | \(elapsed)")
        #expect(feed == nil)
        #expect(elapsed < .milliseconds(500))
    }

    // MARK: - R14: JSON that is not UTF-8

    @Test("600 nested JSON objects in UTF-16LE or UTF-32LE reach the collector as not a feed, without crashing")
    func nestedJSONInWideEncodings() async throws {
        let depth = 600
        // U+2200 in a string is the bytes 00 22 (00 00) in these
        // encodings: a byte pass that ignored the zero bytes would take it
        // for a quote and stop counting brackets (the review's bypass).
        let text = #"{"version":"https://jsonfeed.org/version/1","t":"\#u{2200}","items":[],"x":"#
            + String(repeating: #"{"a":"#, count: depth) + "1" + String(repeating: "}", count: depth) + "}"
        for encoding in [String.Encoding.utf16LittleEndian, .utf32LittleEndian] {
            let body = try #require(text.data(using: encoding))
            let result = try await Task.detached {
                try await FeedFetcher(transport: FakeTransport.answering(body: body, headers: ["Content-Type": "application/feed+json"]))
                    .fetch("https://example.invalid/feed.json")
            }.value
            #expect(result.failure == .notAFeed, "\(encoding)")
        }
    }

    // MARK: - R15: JSON objects with many members

    /// The review's colliding keys: 40 equal bytes, a number, 40 more, the
    /// number again, 40 more.
    static func collidingKeys(_ count: Int) -> Data {
        let edge = String(repeating: "x", count: 40)
        let middle = String(repeating: "m", count: 40)
        let keys = (0..<count).map { index -> String in
            let unique = String(format: "%08d", index)
            return "\"" + edge + unique + middle + unique + edge + "\":1"
        }
        return Data((#"{"version":"https://jsonfeed.org/version/1","items":[{"id":"1"}],"x":{"# + keys.joined(separator: ",") + "}}").utf8)
    }

    @Test("an object of 80,000 colliding keys is refused in milliseconds")
    func manyMembers() async {
        let data = Self.collidingKeys(80_000)
        let start = ContinuousClock.now
        let feed = await Task.detached { FeedParser.parse(data, charset: nil, baseURL: fixtureBase) }.value
        let elapsed = ContinuousClock.now - start
        print("R15 colliding keys | \(data.count) bytes | \(elapsed)")
        #expect(feed == nil)
        #expect(elapsed < .milliseconds(500))
    }

    @Test("4,096 members in one object are read, 4,097 are not; 4,000 items are array elements, not members")
    func memberLimit() async throws {
        let atLimit = Self.collidingKeys(4_096)
        #expect(try #require(await Task.detached { FeedParser.parse(atLimit, charset: nil, baseURL: fixtureBase) }.value).items.count == 1)
        let past = Self.collidingKeys(4_097)
        #expect(await Task.detached { FeedParser.parse(past, charset: nil, baseURL: fixtureBase) }.value == nil)
        let items = (0..<4_000).map { #"{"id":"\#($0)","title":"Item \#($0)"}"# }.joined(separator: ",")
        let feed = Data((#"{"version":"https://jsonfeed.org/version/1.1","title":"Many","items":["# + items + "]}").utf8)
        #expect(try #require(await Task.detached { FeedParser.parse(feed, charset: nil, baseURL: fixtureBase) }.value).items.count == 4_000)
    }
}
