import Foundation
@testable import NewsPawKit
import Testing

/// RD08 decision 6: the file the export writes.
@Suite("OPML writer")
struct OPMLWriterTests {
    static let created = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("attribute values escape markup, keep tab, line feed and carriage return, and drop characters XML does not allow")
    func escaping() {
        #expect(OPMLWriter.attribute(#"A & B <c> "d" 'e'"#) == "A &amp; B &lt;c&gt; &quot;d&quot; 'e'")
        #expect(OPMLWriter.attribute("a\tb\nc\rd") == "a&#9;b&#10;c&#13;d")
        #expect(OPMLWriter.attribute("x\u{0}\u{1}\u{1F}\u{7F}\u{FFFE}\u{FFFF}y\u{1F600}") == "x\u{7F}y\u{1F600}")
    }

    @Test("the date is RFC 822 in GMT")
    func date() {
        #expect(OPMLWriter.rfc822(Self.created) == "Fri, 15 Jan 2027 08:00:00 GMT")
    }

    @Test("an empty category is an empty element, the order is kept, and there is no document type")
    func shape() throws {
        let data = OPMLWriter.document([
            OPMLWriter.Folder(name: "B", feeds: [OPMLWriter.Feed(name: "Z", address: "https://z.example/", siteAddress: nil)]),
            OPMLWriter.Folder(name: "Empty", feeds: []),
            OPMLWriter.Folder(name: "A", feeds: []),
        ], created: Self.created)
        let text = try #require(String(data: data, encoding: .utf8))

        #expect(text.hasPrefix(#"<?xml version="1.0" encoding="UTF-8"?>"# + "\n" + #"<opml version="2.0">"#))
        #expect(!text.contains("<!DOCTYPE"))
        #expect(text.contains(#"<outline text="Empty" title="Empty"/>"#))
        #expect(try OPMLReader.read(data).get().entries == [
            .folder(name: "B", feeds: [OPMLFeed(address: "https://z.example/", name: "Z", siteAddress: nil)]),
            .folder(name: "Empty", feeds: []),
            .folder(name: "A", feeds: []),
        ])
    }

    @Test("what the writer writes, the reader reads back: names, addresses and site addresses")
    func readBack() throws {
        let feeds = [
            OPMLWriter.Feed(name: #"Fish & "Chips" <daily>"#, address: "https://a.example/feed?x=1&y=<2>", siteAddress: "https://a.example"),
            OPMLWriter.Feed(name: "日本語の名前", address: "https://b.example/フィード", siteAddress: nil),
        ]
        let data = OPMLWriter.document([OPMLWriter.Folder(name: "Name with 'quotes' & more", feeds: feeds)], created: Self.created)

        #expect(try OPMLReader.read(data).get().entries == [
            .folder(name: "Name with 'quotes' & more", feeds: [
                OPMLFeed(address: "https://a.example/feed?x=1&y=<2>", name: #"Fish & "Chips" <daily>"#, siteAddress: "https://a.example"),
                OPMLFeed(address: "https://b.example/フィード", name: "日本語の名前", siteAddress: nil),
            ]),
        ])
    }
}
