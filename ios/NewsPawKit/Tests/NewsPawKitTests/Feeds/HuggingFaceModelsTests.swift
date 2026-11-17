import Foundation
@testable import NewsPawKit
import Testing

/// RD26 criterion 8: the reader of the Hub's model list, on synthetic
/// fixtures; and that neither reader falls back to the other.
@Suite("Hugging Face model list")
struct HuggingFaceModelsTests {
    private func read(_ text: String) -> ParsedFeed? {
        HuggingFaceModels.read(Data(text.utf8))
    }

    private func element(_ id: String, _ databaseID: String = "6ad2e0265a59c8bc18700009", createdAt: String = "2026-11-01T00:00:00.000Z") -> String {
        #"{"_id":"\#(databaseID)","id":"\#(id)","createdAt":"\#(createdAt)"}"#
    }

    @Test("the reduced list: identity from _id, title the name, link built on huggingface.co, time from createdAt; nothing else")
    func reduced() throws {
        let feed = try #require(HuggingFaceModels.read(try HubFixture.data("models-reduced.json")))
        #expect(feed.format == .huggingFace)
        #expect(feed.title == nil)
        #expect(feed.siteURL == nil)
        #expect(feed.isComplete)
        #expect(feed.items.map(\.externalID) == (1...5).map { "6ad2e0265a59c8bc1870000\($0)" })
        let names = [
            "lamplight-lab/Wick-7B-Instruct", "lamplight-lab/Wick-7B", "lamplight-lab/Glass-Vision-Exp",
            "lamplight-lab/Lantern.v2_tiny", "lamplight-lab/Quay-Embed",
        ]
        #expect(feed.items.map(\.title) == names)
        #expect(feed.items.map(\.url) == names.map { "https://huggingface.co/" + $0 })
        #expect(feed.items.map(\.publishedAt) == [
            date("2026-11-02T09:30:00Z"), date("2026-10-17T02:40:38Z"), date("2026-09-10T02:17:58.250Z"),
            date("2026-08-31T06:16:18Z"), date("2026-08-13T03:05:06Z"),
        ])
        for item in feed.items {
            #expect(item.excerpt == nil)
            #expect(item.imageURL == nil)
            #expect(item.author == nil)
            #expect(item.contentHTML == nil)
        }
    }

    @Test("the full shape reads to the same items as the reduced one")
    func fullShape() throws {
        let full = try #require(HuggingFaceModels.read(try HubFixture.data("models-full.json")))
        let reduced = try #require(HuggingFaceModels.read(try HubFixture.data("models-reduced.json")))
        #expect(full == reduced)
    }

    @Test("[] is a list with no items")
    func empty() throws {
        let feed = try #require(HuggingFaceModels.read(try HubFixture.data("models-empty.json")))
        #expect(feed.items.isEmpty)
        #expect(feed.isComplete)
        #expect(read(" [ ] ")?.items.isEmpty == true)
    }

    @Test("identity: _id when it is 1–64 ASCII letters and digits, else the name")
    func identity() throws {
        let cases: [(String, String)] = [
            (element("a/b", "abc123"), "abc123"),
            (element("a/b", String(repeating: "f", count: 64)), String(repeating: "f", count: 64)),
            (element("a/b", String(repeating: "f", count: 65)), "a/b"),
            (element("a/b", ""), "a/b"),
            (element("a/b", "abc-123"), "a/b"),
            (element("a/b", "https://x.example/"), "a/b"),
            (#"{"_id":12345,"id":"a/b"}"#, "a/b"),
            (#"{"id":"a/b"}"#, "a/b"),
        ]
        for (json, identity) in cases {
            let feed = try #require(read("[\(json)]"), "\(json)")
            #expect(feed.items.map(\.externalID) == [identity], "\(json)")
        }
    }

    @Test("time: none when createdAt is missing, not a string or unparseable")
    func time() throws {
        let feed = try #require(read("""
            [{"id":"a/one"},{"id":"a/two","createdAt":1700000000},{"id":"a/three","createdAt":"yesterday"},
             {"id":"a/four","createdAt":"2026-11-01T00:00:00Z"}]
            """))
        #expect(feed.items.map(\.publishedAt) == [nil, nil, nil, date("2026-11-01T00:00:00Z")])
    }

    @Test("an element whose id breaks the rule is skipped; the others are kept, and no link comes from the answer")
    func hostileElements() throws {
        let hostile = [
            #""a/../b""#, #""a/b?x=1""#, #""a/b#c""#, #""a/b/c""#, #""https://x.example/a""#, "42", #""a""#, #""/b""#, #""a/""#,
            #""a/.""#, #""a/..""#, #""a/b c""#, #""javascript:alert(1)/b""#, #""a/b%2Fc""#, #""ａ/b""#, "null", "true",
        ]
        var elements = hostile.map { #"{"_id":"6ad2e0265a59c8bc187000ff","id":\#($0),"url":"https://evil.example/x"}"# }
        elements += [#""a/b""#, "7", "null", #"["a/b"]"#]
        elements.insert(element("good/one", "abc1"), at: 3)
        elements.append(element("good/two", "abc2"))
        let feed = try #require(read("[" + elements.joined(separator: ",") + "]"))
        #expect(feed.items.map(\.title) == ["good/one", "good/two"])
        #expect(feed.items.map(\.url) == ["https://huggingface.co/good/one", "https://huggingface.co/good/two"])
    }

    @Test("only the first 30 elements are read")
    func firstThirty() throws {
        let forty = (0..<40).map { element("a/m\($0)", "id\($0)") }
        #expect(read("[" + forty.joined(separator: ",") + "]")?.items.map(\.title) == (0..<30).map { "a/m\($0)" })
        // Thirty elements that are not models, then a model: nothing.
        let late = Array(repeating: "{}", count: 30) + [element("a/late")]
        #expect(read("[" + late.joined(separator: ",") + "]")?.items == [])
    }

    @Test("an object, a JSON Feed, non-JSON and a document past the JSON limits are not a list")
    func notALists() throws {
        #expect(HuggingFaceModels.read(try HubFixture.data("organization-overview.json")) == nil)
        #expect(HuggingFaceModels.read(try HubFixture.data("not-found.json")) == nil)
        #expect(HuggingFaceModels.read(try FeedFixture.data("feed.json")) == nil)
        #expect(HuggingFaceModels.read(try FeedFixture.data("atom.xml")) == nil)
        #expect(HuggingFaceModels.read(try FeedFixture.data("rss2.xml")) == nil)
        #expect(read("") == nil)
        #expect(read("<!DOCTYPE html><html></html>") == nil)
        #expect(read(#"[{"id":"a/b"}"#) == nil)
        // Past the limits: nesting, members and a key's length.
        let deep = "[" + String(repeating: "[", count: JSONFeedReader.maximumNesting) + String(repeating: "]", count: JSONFeedReader.maximumNesting) + "]"
        #expect(read(deep) == nil)
        let members = (0...JSONFeedReader.maximumMembers).map { #""k\#($0)":0"# }.joined(separator: ",")
        #expect(read(#"[{"id":"a/b",\#(members)}]"#) == nil)
        #expect(read(#"[{"id":"a/b","\#(String(repeating: "k", count: JSONFeedReader.maximumKeyBytes + 1))":0}]"#) == nil)
        // A zero byte: not UTF-8 JSON.
        #expect(HuggingFaceModels.read(Data([UInt8(ascii: "["), 0, UInt8(ascii: "]")])) == nil)
    }

    @Test("a feed source answering the list is not a feed; a Hugging Face source answering a feed is not a list")
    func noFallback() async throws {
        let list = try HubFixture.data("models-reduced.json")
        #expect(FeedParser.parse(list, charset: nil, baseURL: fixtureBase) == nil)
        let feedResult = try await FeedFetcher(transport: FakeTransport.answering(body: list)).fetch("https://example.invalid/feed.xml")
        #expect(feedResult.failure == .notAFeed)

        for fixture in ["atom.xml", "rss2.xml", "feed.json"] {
            let transport = FakeTransport.answering(body: try FeedFixture.data(fixture))
            let result = try await FeedFetcher(transport: transport).fetch("https://huggingface.co/lamplight-lab", kind: .huggingface)
            #expect(result.failure == .notAFeed, "\(fixture)")
        }
    }
}
