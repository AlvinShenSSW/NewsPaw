import Foundation
@testable import NewsPawKit
import Testing

/// The pass that finds a start tag with too many attributes before the
/// system parser reads it (fix round 1, R3).
@Suite("Start-tag scan")
struct StartTagScanTests {
    private static let limit = StartTagScan.maximumAttributes
    private static let tooMany = "<x" + (0...limit).map { #" a\#($0)="v""# }.joined() + "/>"
    private static let enough = "<x" + (0..<limit).map { #" a\#($0)="v""# }.joined() + "/>"

    private func cut(_ text: String) -> Int? {
        StartTagScan.cutOffset(in: Data(text.utf8))
    }

    private func offset(of needle: String, in text: String) -> Int {
        text.utf8.count - text[text.range(of: needle)!.lowerBound...].utf8.count
    }

    @Test("the limits are the documented ones")
    func limits() {
        #expect(StartTagScan.maximumAttributes == 256)
        #expect(XMLFeedReader.maximumMappingsInScope == 256)
        #expect(XMLFeedReader.maximumDistinctNames == 4096)
        #expect(XMLFeedReader.maximumDeclarations == 1024)
        #expect(XMLFeedReader.maximumEntityValueBytes == 256)
        #expect(JSONFeedReader.maximumNesting == 64)
    }

    @Test("the cut is at the `<` of the first start tag past the limit; a tag at the limit is not cut")
    func cutAtTheTag() {
        let document = "<rss><channel>" + Self.enough + "<item/>" + Self.tooMany + Self.tooMany + "</channel></rss>"
        #expect(cut(document) == offset(of: Self.tooMany, in: document))
        #expect(cut("<rss><channel>" + Self.enough + "</channel></rss>") == nil)
        #expect(cut(Self.tooMany) == 0)
    }

    @Test("a tag past the limit is found even when it never ends")
    func unendedTag() {
        let document = "<rss>" + String(Self.tooMany.dropLast(2))
        #expect(cut(document) == 5)
    }

    @Test("quoted attribute values may hold `>`, `<` and the other quote")
    func quotedValues() {
        let document = #"<rss><y title="a > b" alt='say "hi" <x>'"# + Self.tooMany.dropFirst(2)
        #expect(cut(document) == 5)
    }

    @Test(
        "markup inside comments, CDATA sections, processing instructions and the document type is not a start tag",
        arguments: [
            "<!-- \(tooMany) -->",
            "<![CDATA[ \(tooMany) ]]>",
            "<?pi \(tooMany) ?>",
            "&lt;x a0=\"\" a1=\"\"&gt;",
        ]
    )
    func hiddenMarkupIsNotCounted(_ hidden: String) {
        let document = "<rss><channel>" + hidden + "<item>text</item></channel></rss>"
        #expect(cut(document) == nil)
        // A real tag after it is still found.
        let before = "<rss><channel>" + hidden
        #expect(cut(before + Self.tooMany + "</channel></rss>") == before.utf8.count)
    }

    @Test("the document type's literals, comments and processing instructions may hold `]` and `>`")
    func documentType() {
        let doctype = #"<!DOCTYPE rss PUBLIC "-//X//]>//EN" 'x]>.dtd' [<!ENTITY e "]> \#(Self.tooMany)"><!-- ]> --><?pi ]> ?><!ELEMENT rss ANY>]>"#
        #expect(cut(doctype + "<rss/>") == nil)
        let document = doctype + "<rss>" + Self.tooMany + "</rss>"
        #expect(cut(document) == doctype.utf8.count + 5)
    }

    @Test("the scan stops where the document stops being well-formed, as the parser does")
    func stopsAtMalformedMarkup() {
        for broken in ["<1x>", "< x>", "<!bogus>", "<x a=v>", "<x a>", "<!-- never closed"] {
            #expect(cut("<rss>" + broken + Self.tooMany + "</rss>") == nil, "\(broken)")
        }
    }

    // MARK: - Encodings

    @Test("a Shift_JIS character whose second byte is `]` does not end a CDATA section early")
    func shiftJISSecondByteInCDATA() throws {
        // ゾ is 0x83 0x5D in Shift_JIS. Read byte by byte, "ゾ]>" would look
        // like the CDATA section's end, and the `<!--` after it would hide
        // the tag.
        var bytes = Array(#"<?xml version="1.0" encoding="Shift_JIS"?><rss version="2.0"><channel><title>T</title><item><guid>1</guid></item><item><guid>2</guid><description><![CDATA["#.utf8)
        bytes += [0x83, 0x5D] + Array("]><!--".utf8)
        bytes += Array("]]></description></item>".utf8)
        let tagOffset = bytes.count
        bytes += Array(Self.tooMany.utf8) + Array("<item><guid>3</guid></item></channel></rss>".utf8)
        let data = Data(bytes)
        #expect(StartTagScan.cutOffset(in: data) == tagOffset)

        // The system parser reads the section the same way: without the
        // limit's tag the document is complete with all three items.
        let without = Data(bytes[..<tagOffset] + Array("<item><guid>3</guid></item></channel></rss>".utf8))
        let complete = try #require(parse(without))
        #expect(complete.items.map(\.externalID) == ["1", "2", "3"])
        #expect(complete.isComplete)
        #expect(complete.items[1].contentHTML == "ゾ]><!--")
        let refused = try #require(parse(data))
        #expect(refused.items.map(\.externalID) == ["1", "2"])
        #expect(refused.isComplete == false)
    }

    @Test("a Shift_JIS name whose second byte is `]` does not end the internal subset early")
    func shiftJISSecondByteInSubset() {
        var bytes = Array(#"<?xml version="1.0" encoding="Shift_JIS"?><!DOCTYPE rss [<!ENTITY "#.utf8)
        bytes += [0x83, 0x5D] + Array(#" "v">]><rss>"#.utf8)
        let tagOffset = bytes.count
        bytes += Array(Self.tooMany.utf8) + Array("</rss>".utf8)
        #expect(StartTagScan.cutOffset(in: Data(bytes)) == tagOffset)
    }

    @Test("EUC-JP and UTF-8 never use bytes below 0x80 inside a character")
    func asciiTransparentEncodings() throws {
        for name in ["ja-euc-jp.xml", "ja-utf8.xml", "ja-shift_jis.xml"] {
            #expect(StartTagScan.cutOffset(in: try FeedFixture.data(name)) == nil, "\(name)")
        }
    }

    @Test(
        "encoding labels map to how bytes form characters; labels not on the list are refused",
        arguments: [
            ("UTF-8", StartTagScan.ByteMode?.some(.asciiCompatible)), ("ISO-8859-1", .asciiCompatible), ("windows-1252", .asciiCompatible),
            ("EUC-JP", .asciiCompatible), ("euc-kr", .asciiCompatible), ("cseucpkdfmtjapanese", .asciiCompatible),
            ("GB2312", .asciiCompatible), ("unicode-1-1-utf-8", .asciiCompatible), ("US-ASCII", .asciiCompatible),
            ("Shift_JIS", .shiftJIS), ("shift-jis", .shiftJIS), ("windows-31j", .shiftJIS), ("MS_Kanji", .shiftJIS), ("x-sjis", .shiftJIS),
            ("Big5", .doubleByte), ("GBK", .doubleByte), ("GB18030", .doubleByte), ("ks_c_5601-1987", .doubleByte), ("windows-949", .doubleByte),
            // Labels the parser knows as double-byte sets but the list does
            // not hold, and labels nobody knows.
            ("pck", nil), ("ibm-942", nil), ("x-IBM942", nil), ("IBM-942_P12A-1999", nil), ("CP932", nil), ("ibm-1386", nil),
            ("cp1386", nil), ("ibm-5471", nil), ("ibm-1373", nil), ("johab", nil), ("SHIFTJIS", nil), ("nonsense-xyz", nil), ("", nil),
            (" Shift_JIS ", nil),
        ]
    )
    func labels(_ label: String, _ mode: StartTagScan.ByteMode?) {
        #expect(StartTagScan.mode(forLabel: label) == mode)
    }

    @Test("every label on the list is lowercase, so that matching ignores case exactly")
    func labelTable() {
        #expect(StartTagScan.labels.keys.allSatisfy { $0 == $0.lowercased() })
        #expect(StartTagScan.labels.count == 210)
    }

    private func declaration(_ text: String, bom: Bool = false) -> StartTagScan.Declaration {
        let bytes = (bom ? [0xEF, 0xBB, 0xBF] : []) + Array(text.utf8)
        return bytes.withUnsafeBufferPointer { StartTagScan.declaration(in: $0, from: bom ? 3 : 0) }
    }

    /// The odd declarations measured against the system parser in fix round
    /// 2. `parserReads` says what the parser does with the declaration
    /// before a UTF-8 body: reads the document (true) or refuses it (false).
    static let padding = String(repeating: " ", count: 2_000)
    static let declarationCases: [(String, StartTagScan.Declaration, Bool)] = [
            (#"<?xml version="1.0" encoding="Shift_JIS"?>"#, StartTagScan.Declaration.read(encoding: "Shift_JIS"), true),
            (#"<?xml version="1.0""# + padding + #"encoding="Shift_JIS"?>"#, .read(encoding: "Shift_JIS"), true),
            (#"<?xml version="1.0" encoding="Shift_JIS""# + padding + "?>", .read(encoding: "Shift_JIS"), false),
            (#"<?xml encoding="Shift_JIS" version="1.0"?>"#, .unreadable, false),
            (#"<?xml encoding="Shift_JIS"?>"#, .unreadable, false),
            (#"<?xml version="1.0" encoding="UTF-8" encoding="Shift_JIS"?>"#, .unreadable, false),
            ("<?xml version='1.0' encoding='Shift_JIS'?>", .read(encoding: "Shift_JIS"), true),
            (#"<?xml version="1.0" ENCODING="Shift_JIS"?>"#, .unreadable, false),
            (#"<?XML version="1.0" encoding="Shift_JIS"?>"#, .absent, false),
            (#"<?xml version="1.0 encoding='Shift_JIS'"?>"#, .read(encoding: nil), false),
            (#"<?xml version="1.0" standalone="yes" encoding="Shift_JIS"?>"#, .unreadable, false),
            (#"<?xml version="1.0" encoding="Shift_JIS" standalone="yes"?>"#, .read(encoding: "Shift_JIS"), true),
            (#"<?xml version = "1.0" encoding = "Shift_JIS" ?>"#, .read(encoding: "Shift_JIS"), true),
            ("<?xml\tversion=\"1.0\"\n\tencoding=\"Shift_JIS\"\r\n?>", .read(encoding: "Shift_JIS"), true),
            (#"<?xml version="1.0" encoding=" Shift_JIS "?>"#, .read(encoding: " Shift_JIS "), false),
            (#"<?xml version="1.0" encoding=""?>"#, .read(encoding: ""), false),
            (#"<?xml version="1.0"encoding="Shift_JIS"?>"#, .unreadable, false),
            (#"<?xml version="1.1" encoding="Shift_JIS"?>"#, .read(encoding: "Shift_JIS"), true),
            (#"<?xml version="1.0" foo="bar" encoding="Shift_JIS"?>"#, .unreadable, false),
            ("<?xml?>", .absent, false),
            (#"<?xml-stylesheet href="x"?>"#, .absent, true),
            (#" <?xml version="1.0" encoding="Shift_JIS"?>"#, .absent, false),
            (#"<?xml version="1.0" encoding="Shift_JIS""#, .unreadable, false),
            ("", .absent, true),
            (#"<?xml version="1.0"?>"#, .read(encoding: nil), true),
        ]

    @Test("the declaration is read exactly; whatever the scan cannot read the parser refuses as well", arguments: declarationCases)
    func declarations(_ text: String, _ expected: StartTagScan.Declaration, _ parserReads: Bool) {
        #expect(declaration(text) == expected)
        // The parser's own verdict, before a UTF-8 body. Shift_JIS reads
        // these ASCII bytes the same way.
        let document = Data((text + "<r>ok</r>").utf8)
        #expect(XMLParser(data: document).parse() == parserReads, "parser on \(text.prefix(60))")
        // The scan refuses a document only when the parser refuses it too.
        if parserReads {
            #expect(StartTagScan.cutOffset(in: document) != 0, "\(text.prefix(60))")
        }
    }

    @Test("a UTF-8 byte-order mark is followed by the declaration, which the parser honours")
    func byteOrderMarkThenDeclaration() {
        #expect(declaration(#"<?xml version="1.0" encoding="Shift_JIS"?>"#, bom: true) == .read(encoding: "Shift_JIS"))
        let bytes: [UInt8] = [0xEF, 0xBB, 0xBF] + Array(#"<?xml version="1.0" encoding="pck"?><r/>"#.utf8)
        #expect(StartTagScan.cutOffset(in: Data(bytes)) == 0)
    }

    @Test("a header charset not on the list, written into the declaration by the retry, is refused")
    func retryWithAnUnlistedHeaderCharset() throws {
        let data = try FeedFixture.data("ja-shift_jis-undeclared.xml")
        #expect(parse(data, charset: "pck") == nil)
        #expect(parse(data, charset: "ibm-942") == nil)
        #expect(try #require(parse(data, charset: "x-sjis")).title == "架空ニュース 表示テスト")
        let declared = try #require(FeedParser.declaring("pck", in: data))
        #expect(StartTagScan.cutOffset(in: declared) == 0)
    }

    @Test("a document in an encoding that is not ASCII-compatible is cut at its first byte: not a feed")
    func notASCIICompatible() throws {
        for label in ["UTF-16", "utf-16le", "UTF-32", "ISO-2022-JP", "UTF-7", "IBM037", "unicode"] {
            #expect(StartTagScan.mode(forLabel: label) == nil, "\(label)")
        }
        let text = #"<?xml version="1.0" encoding="UTF-16"?><rss version="2.0"><channel><title>T</title><item><guid>1</guid></item></channel></rss>"#
        var utf16 = Data([0xFF, 0xFE])
        utf16.append(text.data(using: .utf16LittleEndian)!)
        #expect(StartTagScan.cutOffset(in: utf16) == 0)
        #expect(parse(utf16) == nil)
        #expect(StartTagScan.cutOffset(in: Data(text.utf8)) == 0)
        #expect(StartTagScan.cutOffset(in: text.data(using: .utf16BigEndian)!) == 0)
    }
}
