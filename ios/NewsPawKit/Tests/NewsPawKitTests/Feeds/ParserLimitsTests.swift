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
}
