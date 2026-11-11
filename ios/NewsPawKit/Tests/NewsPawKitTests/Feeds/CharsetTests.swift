import Foundation
@testable import NewsPawKit
import Testing

/// Criterion 2: Japanese encodings, and the rule "parse as sent first".
@Suite("Feed charsets")
struct CharsetTests {
    private func utf8Twin() throws -> ParsedFeed {
        let feed = try #require(parse(try FeedFixture.data("ja-utf8.xml")))
        // The twin itself holds what the Japanese fixtures are about.
        #expect(feed.title == "架空ニュース 表示テスト")
        #expect(feed.items.map(\.title) == ["ソニー風の新しい表計算ソフトを発表", "構造改革、暴力ではなく対話を"])
        #expect(feed.items.first?.excerpt == "噂の機能は十分か。ｶﾀｶﾅとひらがな、漢字の混在。")
        #expect(feed.items.first?.author == "山田 太郎")
        #expect(feed.items.first?.publishedAt == date("2026-11-09T23:00:00Z"))
        #expect(feed.items.last?.excerpt == "東京から大阪まで & 京都へ。ﾃｽﾄ用の半角カナ。")
        return feed
    }

    @Test("a feed declared as Shift_JIS reads the same as its UTF-8 twin")
    func shiftJISDeclared() throws {
        #expect(parse(try FeedFixture.data("ja-shift_jis.xml")) == (try utf8Twin()))
    }

    @Test("a feed declared as EUC-JP reads the same as its UTF-8 twin")
    func eucJPDeclared() throws {
        #expect(parse(try FeedFixture.data("ja-euc-jp.xml")) == (try utf8Twin()))
    }

    @Test("a Shift_JIS feed declared only by the HTTP header reads the same as its UTF-8 twin")
    func shiftJISHeaderOnly() throws {
        let data = try FeedFixture.data("ja-shift_jis-undeclared.xml")
        #expect(parse(data, charset: "Shift_JIS") == (try utf8Twin()))
        #expect(parse(data, charset: "shift_jis") == (try utf8Twin()))
        // Without the header the bytes cannot be read as a feed.
        #expect(parse(data, charset: nil) != (try utf8Twin()))
    }

    @Test("a Shift_JIS feed whose own declaration wrongly says UTF-8 reads correctly when the header is right")
    func shiftJISMislabelled() throws {
        let data = try FeedFixture.data("ja-shift_jis-mislabelled.xml")
        #expect(parse(data, charset: "Shift_JIS") == (try utf8Twin()))
    }

    @Test("a feed that parses as sent is never re-read with the header's charset")
    func parsesAsSentFirst() throws {
        let declared = try FeedFixture.data("ja-utf8.xml")
        let text = String(decoding: declared, as: UTF8.self)
            .replacingOccurrences(of: #"<?xml version="1.0" encoding="UTF-8"?>"#, with: #"<?xml version="1.0"?>"#)
        #expect(!text.contains("encoding="))
        let undeclared = Data(text.utf8)
        let twin = try utf8Twin()
        #expect(parse(undeclared, charset: "ISO-8859-1") == twin)
        #expect(parse(undeclared, charset: "US-ASCII") == twin)
        #expect(parse(declared, charset: "Shift_JIS") == twin)
    }

    @Test("a header charset that is not a plain token is never written into the document")
    func charsetMustBeAPlainToken() throws {
        let data = try FeedFixture.data("ja-shift_jis-undeclared.xml")
        #expect(parse(data, charset: #"Shift_JIS"?><rss"#) == nil)
        #expect(parse(data, charset: "Shift JIS") == nil)
        #expect(parse(data, charset: "") == nil)
        #expect(FeedParser.isPlainToken("windows-31j"))
        #expect(FeedParser.isPlainToken("EUC-JP"))
        #expect(FeedParser.isPlainToken("x.y_z-1"))
        #expect(!FeedParser.isPlainToken("a\"b"))
        #expect(!FeedParser.isPlainToken("a b"))
        #expect(!FeedParser.isPlainToken("a;b"))
    }

    @Test("the header charset replaces an existing encoding, joins a declaration without one, or gets a declaration of its own")
    func declaringTheCharset() throws {
        func declared(_ document: String) -> String? {
            FeedParser.declaring("Shift_JIS", in: Data(document.utf8)).map { String(decoding: $0, as: UTF8.self) }
        }
        #expect(declared(#"<?xml version="1.0" encoding="UTF-8"?><rss/>"#) == #"<?xml version="1.0" encoding="Shift_JIS"?><rss/>"#)
        #expect(declared("<?xml version='1.0' encoding='utf-8' standalone='yes'?><rss/>") == "<?xml version='1.0' encoding='Shift_JIS' standalone='yes'?><rss/>")
        #expect(declared(#"<?xml version="1.0" standalone="yes"?><rss/>"#) == #"<?xml version="1.0" encoding="Shift_JIS" standalone="yes"?><rss/>"#)
        #expect(declared("<rss/>") == "<?xml version=\"1.0\" encoding=\"Shift_JIS\"?>\n<rss/>")
        #expect(declared("\u{FEFF}<rss/>") == nil)
    }
}
