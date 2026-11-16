import Foundation
@testable import NewsPawKit
import Testing

/// RD08 decisions 1 to 3: what the OPML reader takes from a file, and every
/// file it refuses (criteria 2, 3 and 10).
@Suite("OPML reader")
struct OPMLReaderTests {
    static func opml(_ body: String, head: String = "<head><title>Subscriptions</title></head>") -> Data {
        Data(#"<?xml version="1.0" encoding="UTF-8"?><opml version="2.0">\#(head)<body>\#(body)</body></opml>"#.utf8)
    }

    static func feed(_ name: String, _ address: String, site: String? = nil) -> String {
        let site = site.map { #" htmlUrl="\#($0)""# } ?? ""
        return #"<outline text="\#(name)" title="\#(name)" type="rss" xmlUrl="\#(address)"\#(site)/>"#
    }

    static func read(_ data: Data) throws -> OPMLDocument {
        try OPMLReader.read(data).get()
    }

    static func refusal(_ data: Data) -> OPMLRefusal? {
        if case .failure(let refusal) = OPMLReader.read(data) { refusal } else { nil }
    }

    // MARK: - Structure (decision 1)

    @Test("top-level folders, nesting three deep flattened into the top folder, and feeds outside any folder")
    func foldersNestingAndOutside() throws {
        let document = try Self.read(Self.opml("""
            \(Self.feed("Loose one", "https://loose.example/one.xml"))
            <outline text="News" title="News">
              \(Self.feed("A", "https://a.example/feed", site: "https://a.example"))
              <outline text="World">
                <outline text="Deeper">
                  <outline text="Deepest">
                    \(Self.feed("B", "https://b.example/feed"))
                  </outline>
                </outline>
                \(Self.feed("C", "https://c.example/feed"))
              </outline>
            </outline>
            \(Self.feed("Loose two", "http://loose.example/two.xml"))
            <outline text="Tech">\(Self.feed("D", "https://d.example/feed"))</outline>
            """))

        #expect(document.entries == [
            .feed(OPMLFeed(address: "https://loose.example/one.xml", name: "Loose one", siteAddress: nil)),
            .folder(name: "News", feeds: [
                OPMLFeed(address: "https://a.example/feed", name: "A", siteAddress: "https://a.example"),
                OPMLFeed(address: "https://b.example/feed", name: "B", siteAddress: nil),
                OPMLFeed(address: "https://c.example/feed", name: "C", siteAddress: nil),
            ]),
            .feed(OPMLFeed(address: "http://loose.example/two.xml", name: "Loose two", siteAddress: nil)),
            .folder(name: "Tech", feeds: [OPMLFeed(address: "https://d.example/feed", name: "D", siteAddress: nil)]),
        ])
        #expect(document.feedCount == 6)
    }

    @Test("element and attribute names are matched ignoring ASCII case; type may be absent or anything")
    func nameCaseAndType() throws {
        let data = Data(#"""
            <OPML version="1.0"><Head/><BODY>
            <OUTLINE TEXT="Folder"><Outline XMLURL="https://a.example/feed" Title="A" HTMLURL="https://a.example/"/></OUTLINE>
            <outline text="No type" xmlUrl="https://b.example/feed"/>
            <outline text="Odd type" type="link" xmlurl="https://c.example/feed"/>
            </BODY></OPML>
            """#.utf8)

        #expect(try Self.read(data).entries == [
            .folder(name: "Folder", feeds: [OPMLFeed(address: "https://a.example/feed", name: "A", siteAddress: "https://a.example/")]),
            .feed(OPMLFeed(address: "https://b.example/feed", name: "No type", siteAddress: nil)),
            .feed(OPMLFeed(address: "https://c.example/feed", name: "Odd type", siteAddress: nil)),
        ])
    }

    @Test("a name is the title, else the text: white space collapsed, control characters dropped, cut to the library's limits")
    func names() throws {
        let longFolder = String(repeating: "f", count: 150)
        let longFeed = String(repeating: "é", count: 300)
        let document = try Self.read(Self.opml(#"""
            <outline text="Text only" xmlUrl="https://a.example/feed"/>
            <outline title="  Both  " text="Ignored" xmlUrl="https://b.example/feed"/>
            <outline title="" text="Empty title" xmlUrl="https://c.example/feed"/>
            <outline title="My &#9; &#10;  Feed&#x7F;!" xmlUrl="https://d.example/feed"/>
            <outline title="\#(longFeed)" xmlUrl="https://e.example/feed"/>
            <outline xmlUrl="https://f.example/feed"/>
            <outline text="\#(longFolder)"><outline xmlUrl="https://g.example/feed"/></outline>
            """#))

        let names = document.entries.map { entry -> String in
            switch entry {
            case .feed(let feed): feed.name
            case .folder(let name, _): name
            }
        }
        #expect(names == [
            "Text only", "Both", "Empty title", "My Feed!", String(repeating: "é", count: Library.maximumSourceNameLength), "",
            String(repeating: "f", count: Library.maximumCategoryNameLength),
        ])
    }

    @Test("a top-level outline without a name is no folder: the feeds under it are outside any folder")
    func unnamedTopLevelOutline() throws {
        let document = try Self.read(Self.opml(#"""
            <outline text="  "><outline><outline text="A" xmlUrl="https://a.example/feed"/></outline></outline>
            """#))

        #expect(document.entries == [.feed(OPMLFeed(address: "https://a.example/feed", name: "A", siteAddress: nil))])
    }

    @Test("the children of a feed outline are ignored, feeds among them")
    func childrenOfAFeed() throws {
        let document = try Self.read(Self.opml(#"""
            <outline text="Podcast" xmlUrl="https://a.example/feed">
              <outline text="Episode 1" type="podcast-episode"/>
              <outline text="Not a feed of its own" xmlUrl="https://b.example/feed"/>
            </outline>
            """#))

        #expect(document.entries == [.feed(OPMLFeed(address: "https://a.example/feed", name: "Podcast", siteAddress: nil))])
    }

    @Test("a top-level block with children and no feed is ignored; an empty top-level outline is a folder")
    func settingsBlockAndEmptyFolder() throws {
        let document = try Self.read(Self.opml(#"""
            <outline text="tt-rss-prefs" schema-version="1">
              <outline pref-name="ALLOW_DUPLICATE_POSTS" value="false"/>
            </outline>
            <outline text="Links"><outline text="A page" type="link" url="https://example.com/"/></outline>
            <outline text="Empty"/>
            <outline text="Empty with text">   </outline>
            <outline text="Feeds"><outline xmlUrl="https://a.example/feed" text="A"/></outline>
            """#))

        #expect(document.entries == [
            .folder(name: "Empty", feeds: []),
            .folder(name: "Empty with text", feeds: []),
            .folder(name: "Feeds", feeds: [OPMLFeed(address: "https://a.example/feed", name: "A", siteAddress: nil)]),
        ])
    }

    @Test("only outlines of the body of an opml root count; the head and other elements are ignored")
    func onlyTheBody() throws {
        let document = try Self.read(Self.opml(
            #"<other><outline text="Hidden" xmlUrl="https://hidden.example/feed"/></other><outline text="A" xmlUrl="https://a.example/feed"/>"#,
            head: #"<head><outline text="In head" xmlUrl="https://head.example/feed"/></head>"#
        ))

        #expect(document.entries == [.feed(OPMLFeed(address: "https://a.example/feed", name: "A", siteAddress: nil))])
    }

    @Test("an address or a site address longer than the byte limit is kept as too long or dropped")
    func overlongAddresses() throws {
        let long = "https://a.example/" + String(repeating: "x", count: OPMLReader.maximumAddressBytes)
        let document = try Self.read(Self.opml(#"""
            <outline text="Long" xmlUrl="\#(long)"/>
            <outline text="Long site" xmlUrl="https://b.example/feed" htmlUrl="\#(long)"/>
            """#))

        guard case .feed(let first) = document.entries.first, case .feed(let second) = document.entries.last else {
            Issue.record("expected two feeds: \(document.entries)")
            return
        }
        #expect(first.addressIsTooLong)
        #expect(first.address.utf8.count <= OPMLReader.maximumAddressBytes)
        #expect(second.addressIsTooLong == false)
        #expect(second.siteAddress == nil)
    }

    // MARK: - Byte limits before characters (criterion 10)

    @Test("a value is cut at a scalar boundary, never inside a character's bytes")
    func cutAtScalarBoundary() throws {
        // 1,023 ASCII bytes, then a three-byte character across the limit.
        let name = String(repeating: "a", count: 1_023) + "語語"
        let document = try Self.read(Self.opml(#"<outline text="\#(name)" xmlUrl="https://a.example/feed"/>"#))

        guard case .feed(let feed) = document.entries.first else {
            Issue.record("expected a feed")
            return
        }
        // Cut to 1,023 bytes, then to the source name limit.
        #expect(feed.name == String(repeating: "a", count: Library.maximumSourceNameLength))
        #expect(OPMLReader.prefix(ofUTF8: name, maximumBytes: 1_024) == String(repeating: "a", count: 1_023))
        #expect(OPMLReader.prefix(ofUTF8: name, maximumBytes: 1_026) == String(repeating: "a", count: 1_023) + "語")
    }

    // MARK: - Limits (decision 2)

    @Test("exactly 2,000 feeds are read; 2,001 are refused")
    func feedLimit() throws {
        func file(_ count: Int) -> Data {
            Self.opml((0..<count).map { Self.feed("F\($0)", "https://example.com/\($0)") }.joined())
        }

        #expect(try Self.read(file(OPMLReader.maximumFeeds)).feedCount == OPMLReader.maximumFeeds)
        #expect(Self.refusal(file(OPMLReader.maximumFeeds + 1)) == .tooManyFeeds)
    }

    @Test("feeds in folders count toward the 2,000 the same way")
    func feedLimitInFolders() throws {
        let half = (0..<1_001).map { Self.feed("F\($0)", "https://example.com/a\($0)") }.joined()
        let other = (0..<1_000).map { Self.feed("G\($0)", "https://example.com/b\($0)") }.joined()

        #expect(Self.refusal(Self.opml(#"<outline text="A">\#(half)</outline><outline text="B"><outline text="C">\#(other)</outline></outline>"#))
            == .tooManyFeeds)
    }

    @Test("exactly 500 top-level folders are read; 501 are refused, settings blocks among them")
    func folderLimit() throws {
        func file(_ count: Int) -> Data {
            Self.opml((0..<count).map { #"<outline text="Folder \#($0)"/>"# }.joined())
        }

        #expect(try Self.read(file(OPMLReader.maximumFolders)).entries.count == OPMLReader.maximumFolders)
        #expect(Self.refusal(file(OPMLReader.maximumFolders + 1)) == .tooManyFolders)
        let blocks = (0...OPMLReader.maximumFolders).map { #"<outline text="b\#($0)"><outline value="1"/></outline>"# }.joined()
        #expect(Self.refusal(Self.opml(blocks)) == .tooManyFolders)
    }

    @Test("data over 5 MB is refused before parsing")
    func dataOverLimit() throws {
        let padding = String(repeating: " ", count: OPMLReader.maximumBytes)
        #expect(Self.refusal(Self.opml(Self.feed("A", "https://a.example/feed") + padding)) == .tooLarge)
    }

    // MARK: - Refusals (criterion 2)

    @Test("refused files, each with its reason", arguments: [
        ("not well-formed", #"<?xml version="1.0"?>"# + "\n<opml version=\"2.0\"><body>\n<outline text=\"A\" xmlUrl=\"https://a.example/\">\n</body></opml>",
         OPMLRefusal.notWellFormed(line: 4)),
        ("an undeclared entity", #"<opml><body><outline text="&nbsp;" xmlUrl="https://a.example/"/></body></opml>"#, .notWellFormed(line: 1)),
        ("root not opml", #"<rss version="2.0"><body><outline text="A" xmlUrl="https://a.example/"/></body></rss>"#, .notOPML),
        ("no body", #"<opml version="2.0"><head/><outline text="A" xmlUrl="https://a.example/"/></opml>"#, .notOPML),
        ("neither a feed nor a folder", #"<opml version="2.0"><head/><body><outline text="b"><outline value="1"/></outline></body></opml>"#,
         .empty),
        ("an empty body", #"<opml version="2.0"><body/></opml>"#, .empty),
        // The parser gives line 0 for an empty document.
        ("an empty file", "", .notWellFormed(line: 0)),
    ])
    func refusals(label: String, text: String, expected: OPMLRefusal) {
        #expect(Self.refusal(Data(text.utf8)) == expected, "\(label)")
    }

    /// Every document-type shape of the design's measured table, before the
    /// root, after any prolog the walk skips.
    static let documentTypes = [
        "<!DOCTYPE opml>",
        "<!DOCTYPE opml []>",
        "<!DOCTYPE opml [ <!-- c --> ]>",
        #"<!DOCTYPE opml SYSTEM "file:///etc/hosts">"#,
        #"<!DOCTYPE opml PUBLIC "-//X//DTD OPML//EN" "http://127.0.0.1:9/opml.dtd">"#,
        #"<!DOCTYPE opml [<!ENTITY a "aaa">]>"#,
        #"<!DOCTYPE opml [<!ENTITY x SYSTEM "file:///etc/hosts">]>"#,
        #"<!DOCTYPE opml [<!ENTITY % p SYSTEM "file:///etc/hosts">]>"#,
        #"<!DOCTYPE opml [<!ELEMENT opml ANY>]>"#,
        #"<!DOCTYPE opml [<!NOTATION n SYSTEM "x">]>"#,
        #"<!DOCTYPE opml [<!NOTATION n SYSTEM "x"><!ENTITY u SYSTEM "u" NDATA n>]>"#,
        #"<!DOCTYPE opml [<?pi x?>]>"#,
        "<!doctype opml>",
    ]

    static let prologs = [
        "",
        #"<?xml version="1.0" encoding="UTF-8"?>"#,
        "\u{FEFF}" + #"<?xml version="1.0" encoding="utf-8" standalone="yes"?>"# + "\n\n",
        #"<?xml version="1.0"?><!-- a comment with <!DOCTYPE inside --> <?pi data?>"# + "\t\r\n",
    ]

    @Test("any document type before the root is refused, whatever comes before it", arguments: OPMLReaderTests.documentTypes)
    func documentTypeRefused(_ documentType: String) {
        let body = #"<opml version="2.0"><body><outline text="A" xmlUrl="https://a.example/feed"/></body></opml>"#
        for prolog in Self.prologs {
            #expect(Self.refusal(Data((prolog + documentType + body).utf8)) == .hasDocumentType, "\(prolog.debugDescription)")
        }
    }

    @Test("the prolog walk lets comments and processing instructions pass")
    func prologWithoutDocumentType() throws {
        let body = #"<opml version="2.0"><body><outline text="A" xmlUrl="https://a.example/feed"/></body></opml>"#
        for prolog in Self.prologs {
            #expect(try Self.read(Data((prolog + body).utf8)).feedCount == 1, "\(prolog.debugDescription)")
        }
    }

    @Test("the parser's declaration callbacks refuse a document type the byte walk did not see")
    func declarationCallbacksAreASecondGuard() {
        let body = #"<opml version="2.0"><body><outline text="A" xmlUrl="https://a.example/feed"/></body></opml>"#
        for declaration in [#"<!ENTITY a "aaa">"#, "<!ELEMENT opml ANY>", #"<!NOTATION n SYSTEM "x">"#] {
            let data = Data((#"<!DOCTYPE opml [\#(declaration)]>"# + body).utf8)
            #expect(OPMLReader.parse(data) == .failure(.hasDocumentType), "\(declaration)")
        }
    }

    @Test("a file the start-tag scan cuts is refused as unreadable", arguments: [
        ("257 attributes on one tag",
         "<opml><body><outline xmlUrl=\"https://a.example/\"" + (0..<256).map { " a\($0)=\"\"" }.joined() + "/></body></opml>"),
        ("an attribute-list declaration", #"<!DOCTYPE opml [<!ATTLIST outline a CDATA "x">]><opml><body/></opml>"#),
        ("an encoding label the scan does not know", #"<?xml version="1.0" encoding="x-unknown"?><opml><body/></opml>"#),
    ])
    func cutByStartTagScan(label: String, text: String) {
        #expect(Self.refusal(Data(text.utf8)) == .unreadable, "\(label)")
    }

    @Test("a UTF-16 file is refused as unreadable")
    func utf16() throws {
        let text = #"<?xml version="1.0" encoding="UTF-16"?><opml version="2.0"><body><outline text="A" xmlUrl="https://a.example/feed"/></body></opml>"#
        let data = try #require(text.data(using: .utf16))
        #expect(Self.refusal(data) == .unreadable)
    }

    @Test("a Shift_JIS file is read")
    func shiftJIS() throws {
        let text = #"<?xml version="1.0" encoding="Shift_JIS"?><opml version="2.0"><body><outline text="ニュース"><outline text="表示ソース" xmlUrl="https://a.example/feed"/></outline></body></opml>"#
        let data = try #require(text.data(using: .shiftJIS))

        #expect(try Self.read(data).entries == [
            .folder(name: "ニュース", feeds: [OPMLFeed(address: "https://a.example/feed", name: "表示ソース", siteAddress: nil)]),
        ])
    }

    @Test("a byte-order mark before UTF-8 is accepted")
    func byteOrderMark() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Self.opml(Self.feed("A", "https://a.example/feed")))
        #expect(try Self.read(data).feedCount == 1)
    }

    // MARK: - Criterion 3: nothing is read from an external identifier

    @Test("a named file's content never arrives: refused before parsing, and absent when parsed with the reader's settings")
    func externalIdentifiersAreNotRead() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secretText = directory.appending(path: "secret.txt")
        try "SECRET-FROM-TXT".write(to: secretText, atomically: true, encoding: .utf8)
        let secretDTD = directory.appending(path: "secret.dtd")
        try #"<!ENTITY leak "SECRET-FROM-DTD">"#.write(to: secretDTD, atomically: true, encoding: .utf8)

        let documents = [
            // An external subset, and an entity it would define used in an
            // attribute and in content.
            #"<!DOCTYPE opml SYSTEM "\#(secretDTD.absoluteString)"><opml version="2.0"><body><outline text="x&leak;y" xmlUrl="https://a.example/feed">&leak;</outline></body></opml>"#,
            // An external general entity used in content.
            #"<!DOCTYPE opml [<!ENTITY x SYSTEM "\#(secretText.absoluteString)">]><opml version="2.0"><body><outline text="A" xmlUrl="https://a.example/feed">&x;</outline></body></opml>"#,
            // An external parameter entity.
            #"<!DOCTYPE opml [<!ENTITY % p SYSTEM "\#(secretDTD.absoluteString)"> %p;]><opml version="2.0"><body><outline text="&leak;" xmlUrl="https://a.example/feed"/></body></opml>"#,
        ]
        for text in documents {
            let data = Data(text.utf8)
            #expect(OPMLReader.read(data) == .failure(.hasDocumentType))

            // The parser the reader uses, with its settings, on the same
            // bytes: every character and attribute it delivers.
            let collector = TextCollector()
            let parser = OPMLReader.makeParser(data)
            parser.delegate = collector
            _ = parser.parse()
            #expect(!collector.text.contains("SECRET"), "delivered: \(collector.text)")
        }
    }

    // MARK: - Reading a file (decision 3)

    @Test("a file of exactly 5 MB is read; one byte more is refused without being parsed")
    func fileAtTheLimit() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let head = Self.opml(Self.feed("A", "https://a.example/feed"))
        var data = head
        data.append(Data(repeating: 0x20, count: OPMLReader.maximumBytes - head.count))
        #expect(data.count == OPMLReader.maximumBytes)
        let atLimit = directory.appending(path: "at-limit.opml")
        try data.write(to: atLimit)
        data.append(0x20)
        let overLimit = directory.appending(path: "over-limit.opml")
        try data.write(to: overLimit)

        #expect(try OPMLReader.read(contentsOf: atLimit).get().feedCount == 1)
        #expect(OPMLReader.read(contentsOf: overLimit) == .failure(.tooLarge))
        #expect(OPMLReader.read(contentsOf: directory.appending(path: "missing.opml")) == .failure(.unreadable))
    }

    @Test("a file over the limit is refused by its size, before it is opened")
    func refusedBySize() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "large.opml")
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(OPMLReader.maximumBytes + 1))
        try handle.close()
        // Not readable: only its size can refuse it as too large; opening
        // it would be refused as unreadable.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }

        #expect(OPMLReader.read(contentsOf: url) == .failure(.tooLarge))
    }

    @Test("the bounded read stops at the limit plus one byte, whatever the file's size")
    func boundedRead() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "large.opml")
        try Data(repeating: 0x20, count: OPMLReader.maximumBytes + 100_000).write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let read = try OPMLReader.boundedRead(handle)

        #expect(read.count == OPMLReader.maximumBytes + 1)
        #expect(try handle.offset() == UInt64(OPMLReader.maximumBytes + 1))
    }
}

/// Every attribute value and piece of character data the parser delivers.
private final class TextCollector: NSObject, XMLParserDelegate {
    var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text += attributeDict.values.joined(separator: "|")
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }
}
