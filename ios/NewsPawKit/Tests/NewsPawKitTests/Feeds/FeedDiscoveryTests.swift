import Foundation
@testable import NewsPawKit
import Testing

/// The synthetic pages under `Fixtures/pages/`.
enum PageFixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/pages"),
            "Missing page fixture \(name)"
        )
        return try Data(contentsOf: url)
    }
}

/// The page address the discovery tests pretend their documents came from.
let pageAddress = "https://site.example/blog/post"

func discover(
    _ html: String, mediaType: String? = "text/html", charset: String? = nil,
    requested: String = pageAddress, final: String = pageAddress
) -> DiscoveredPage {
    discover(Data(html.utf8), mediaType: mediaType, charset: charset, requested: requested, final: final)
}

func discover(
    _ body: Data, mediaType: String? = "text/html", charset: String? = nil,
    requested: String = pageAddress, final: String = pageAddress
) -> DiscoveredPage {
    FeedDiscovery.read(body: body, mediaType: mediaType, charset: charset, requested: requested, finalURL: URL(string: final)!)
}

func rssLink(_ href: String, extra: String = "") -> String {
    #"<link rel="alternate" type="application/rss+xml" href="\#(href)"\#(extra)>"#
}

/// RD05 criterion 3 and decisions 4–5: which declarations discovery reads.
@Suite("Feed discovery")
struct FeedDiscoveryTests {
    private func addresses(_ page: DiscoveredPage) -> [String] {
        page.feeds.map(\.address)
    }

    @Test("one feed, and several in document order with their types and titles")
    func oneAndSeveral() {
        let one = discover("<html><head>\(rssLink("https://site.example/feed.xml"))</head></html>")
        #expect(addresses(one) == ["https://site.example/feed.xml"])
        #expect(one.declaredCount == 1)

        let several = discover("""
            <html><head>
            <link rel="alternate" type="application/atom+xml" href="/atom.xml" title="Atom &amp; more">
            <link rel="alternate" type="application/rdf+xml" href="/rdf">
            <link rel="alternate" type="application/feed+json" href="/feed.json">
            \(rssLink("/rss.xml"))
            </head></html>
            """)
        #expect(addresses(several) == [
            "https://site.example/atom.xml", "https://site.example/rdf", "https://site.example/feed.json", "https://site.example/rss.xml",
        ])
        #expect(several.feeds.first?.title == "Atom & more")
    }

    @Test("relative, protocol-relative, dot-segment and white-space-padded hrefs")
    func resolution() {
        let page = discover("""
            <html><head>
            \(rssLink("feed.xml"))
            \(rssLink("//cdn.example/feed.xml"))
            \(rssLink("../up.xml"))
            \(rssLink("  /padded.xml\n"))
            \(rssLink("?format=rss"))
            </head></html>
            """)
        #expect(addresses(page) == [
            "https://site.example/blog/feed.xml", "https://cdn.example/feed.xml", "https://site.example/up.xml",
            "https://site.example/padded.xml", "https://site.example/blog/post?format=rss",
        ])
    }

    @Test("<base href> applies, also when it stands after the links; the first usable one wins")
    func base() {
        let after = discover("<html><head>\(rssLink("feed.xml"))<base href=\"https://other.example/dir/\"></head></html>")
        #expect(addresses(after) == ["https://other.example/dir/feed.xml"])

        let second = discover("""
            <html><head><base href="https://first.example/a/"><base href="https://second.example/b/">\(rssLink("feed.xml"))</head></html>
            """)
        #expect(addresses(second) == ["https://first.example/a/feed.xml"])

        let unusableFirst = discover("""
            <html><head><base target="_blank"><base href="javascript:void(0)"><base href="/root/">\(rssLink("feed.xml"))</head></html>
            """)
        #expect(addresses(unusableFirst) == ["https://site.example/root/feed.xml"])
    }

    @Test("rel and type are matched as specified")
    func relAndType() {
        let page = discover("""
            <html><head>
            <link rel="ALTERNATE" type="application/rss+xml" href="/a.xml">
            <link rel="home alternate nofollow" type="application/rss+xml" href="/b.xml">
            <link rel="alternate stylesheet" type="application/rss+xml" href="/c.xml">
            <link rel="alternate" type="Application/RSS+XML; charset=utf-8" href="/d.xml">
            <link rel="alternate" type="application/json" href="/wp-json/">
            <link rel="alternate" type="text/html" hreflang="de" href="/de/">
            <link rel="feed" type="application/rss+xml" href="/e.xml">
            <link rel="alternate" href="/f.xml">
            </head></html>
            """)
        #expect(addresses(page) == ["https://site.example/a.xml", "https://site.example/b.xml", "https://site.example/d.xml"])
    }

    @Test("missing, empty, javascript:, data: and credential-bearing hrefs are ignored")
    func unusableHrefs() {
        let page = discover("""
            <html><head>
            <link rel="alternate" type="application/rss+xml">
            \(rssLink(""))
            \(rssLink("   "))
            \(rssLink("javascript:alert(1)"))
            \(rssLink("data:application/rss+xml,<rss/>"))
            \(rssLink("https://user:pw@site.example/feed.xml"))
            \(rssLink("ftp://site.example/feed.xml"))
            \(rssLink("/good.xml"))
            </head></html>
            """)
        #expect(addresses(page) == ["https://site.example/good.xml"])
    }

    @Test("single-quoted, double-quoted and unquoted attributes in any order")
    func quoting() {
        let page = discover("""
            <html><head>
            <link href='/single.xml' type='application/rss+xml' rel='alternate'>
            <LINK TYPE=application/atom+xml HREF=/unquoted.xml REL=alternate />
            <link
              type = "application/rss+xml"
              rel = "alternate"
              href = "/spaced.xml" >
            </head></html>
            """)
        #expect(addresses(page) == [
            "https://site.example/single.xml", "https://site.example/unquoted.xml", "https://site.example/spaced.xml",
        ])
    }

    @Test("a feed declared twice and links to the page itself are dropped")
    func duplicatesAndSelf() {
        let page = discover("""
            <html><head>
            \(rssLink("/feed.xml"))
            \(rssLink("https://SITE.example:443/feed.xml#x"))
            \(rssLink("https://site.example/blog/post"))
            \(rssLink("https://site.example/final"))
            \(rssLink("#comments"))
            </head></html>
            """, final: "https://site.example/final")
        #expect(addresses(page) == ["https://site.example/feed.xml"])
        #expect(page.declaredCount == 1)
    }

    @Test("more than five feeds: the first five are kept and all are counted")
    func cap() {
        let links = (1...8).map { rssLink("/feed\($0).xml") }.joined()
        let page = discover("<html><head>\(links)</head></html>")
        #expect(addresses(page) == (1...5).map { "https://site.example/feed\($0).xml" })
        #expect(page.declaredCount == 8)
    }

    @Test("links in the body count")
    func body() {
        let page = discover("<html><head></head><body><div>\(rssLink("/body.xml"))</div></body></html>")
        #expect(addresses(page) == ["https://site.example/body.xml"])
    }

    @Test("a <link> inside a comment, script, style, textarea or another tag's attribute value is ignored")
    func hidden() {
        let page = discover("""
            <html><head>
            <!-- \(rssLink("/comment.xml")) -->
            <script>var s = '\(rssLink("/script.xml"))';</script>
            <SCRIPT type="text/javascript">document.write("<link rel=alternate type=application/rss+xml href=/script2.xml>")</SCRIPT >
            <style>/* \(rssLink("/style.xml")) */</style>
            <textarea>\(rssLink("/textarea.xml"))</textarea>
            <meta name="x" content='\(rssLink("/attribute.xml"))'>
            <div title="<link rel=alternate type=application/rss+xml href=/attribute2.xml>"></div>
            <title>\(rssLink("/title.xml"))</title>
            \(rssLink("/real.xml"))
            </head></html>
            """)
        #expect(addresses(page) == ["https://site.example/real.xml"])
    }

    @Test("a > inside a quoted attribute value does not end the <link>")
    func greaterThanInValue() {
        let page = discover(#"<html><head><link title="a > b" rel="alternate" type="application/rss+xml" href="/gt.xml"></head></html>"#)
        #expect(addresses(page) == ["https://site.example/gt.xml"])
        #expect(page.feeds.first?.title == "a > b")
    }

    @Test("<basefont> and <linker> are not <base> and <link>")
    func tagNameBoundaries() {
        let page = discover("""
            <html><head>
            <basefont href="https://wrong.example/">
            <linker rel="alternate" type="application/rss+xml" href="/linker.xml">
            \(rssLink("feed.xml"))
            </head></html>
            """)
        #expect(addresses(page) == ["https://site.example/blog/feed.xml"])
    }

    @Test("character references in href are decoded")
    func references() {
        let page = discover("""
            <html><head>
            \(rssLink("/feed?a=1&amp;b=2"))
            \(rssLink("/feed?c=1&#038;d=2"))
            \(rssLink("/feed?e=1&#x26;f=2"))
            </head></html>
            """)
        #expect(addresses(page) == [
            "https://site.example/feed?a=1&b=2", "https://site.example/feed?c=1&d=2", "https://site.example/feed?e=1&f=2",
        ])
    }

    @Test("<!DOCTYPE>, another <!…> and <!--> before the links")
    func declarations() {
        let page = discover("""
            <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
            <![CDATA[ x ]]>
            <!-->
            <?php echo 1 ?>
            <html><head>\(rssLink("/after.xml"))</head></html>
            """)
        #expect(addresses(page) == ["https://site.example/after.xml"])
    }

    @Test("the title: present, absent, with references and white space")
    func title() {
        #expect(discover("<html><head><title>\n  News &amp; <b>Views</b>\t</title></head></html>").title == "News & <b>Views</b>")
        #expect(discover("<html><head></head></html>").title == nil)
        #expect(discover("<html><head><title>   </title></head></html>").title == nil)
        #expect(discover("<html><head><TITLE>First</TITLE><title>Second</title></head></html>").title == "First")
        #expect(discover("<html><head><title>" + String(repeating: "x", count: 2_000)).title?.count == 1_000)
    }

    @Test("the charset from <meta charset> and from <meta http-equiv>")
    func metaCharset() {
        let title = "Café"
        let body = { (meta: String) -> Data in
            var data = Data("<html><head>\(meta)<title>".utf8)
            data.append(title.data(using: .isoLatin1)!)
            data.append(Data("</title></head></html>".utf8))
            return data
        }
        #expect(discover(body("<meta charset=\"ISO-8859-1\">")).title == title)
        #expect(discover(body("<meta http-equiv=\"Content-Type\" content=\"text/html; charset=iso-8859-1\">")).title == title)
        // A header charset outranks the page's own.
        #expect(discover(body("<meta charset=\"utf-8\">"), charset: "iso-8859-1").title == title)
    }

    @Test("a Shift_JIS page declared by the header and by <meta>")
    func shiftJIS() throws {
        let byHeader = discover(try PageFixture.data("ja-shift_jis.html"), charset: "Shift_JIS")
        #expect(byHeader.title == "日本語のニュース & 話題")
        #expect(byHeader.feeds == [DeclaredFeed(address: "https://site.example/rss/news.xml", title: "最新ニュース")])

        let byMeta = discover(try PageFixture.data("ja-shift_jis-meta.html"))
        #expect(byMeta.title == "日本語のニュース & 話題")
        #expect(byMeta.feeds == byHeader.feeds)
    }

    @Test("a Shift_JIS page cut in the middle of a character at the 1 MB edge keeps its title and feed")
    func shiftJISCutMidCharacter() throws {
        var page = try PageFixture.data("ja-shift_jis-meta.html")
        let character = try #require("日".data(using: .shiftJIS))
        #expect(character.count == 2)
        // Filler up to one byte before the edge, then a two-byte character
        // across it.
        page.append(Data(repeating: UInt8(ascii: " "), count: FeedDiscovery.examinedBytes - 1 - page.count))
        page.append(character)
        page.append(Data("</p></body></html>".utf8))
        let found = discover(page)
        #expect(found.title == "日本語のニュース & 話題")
        #expect(found.feeds.map(\.address) == ["https://site.example/rss/news.xml"])
    }

    @Test("a document that is not HTML is not scanned")
    func notHTML() {
        let pdf = discover("%PDF-1.7 <link rel=alternate type=application/rss+xml href=/x.xml>", mediaType: "application/pdf")
        #expect(!pdf.isHTML)
        #expect(pdf.feeds.isEmpty)
        #expect(pdf.title == nil)
        let text = discover("<title>Not a page</title>", mediaType: "text/plain")
        #expect(!text.isHTML)
    }

    @Test("an HTML document sent as application/octet-stream is recognised by its first bytes")
    func sniffed() {
        let page = discover("\n<!DocType HTML>\n<html><head><title>Sniffed</title>\(rssLink("/feed.xml"))</head></html>",
                            mediaType: "application/octet-stream")
        #expect(page.isHTML)
        #expect(page.title == "Sniffed")
        #expect(addresses(page) == ["https://site.example/feed.xml"])
        let noType = discover("<HTML><head>\(rssLink("/feed.xml"))</head></HTML>", mediaType: nil)
        #expect(addresses(noType) == ["https://site.example/feed.xml"])
    }

    @Test("malformed and truncated markup never throws and keeps what is readable")
    func malformed() {
        #expect(discover("").feeds.isEmpty)
        #expect(discover("<").feeds.isEmpty)
        #expect(discover("<html><head><link rel=\"alternate\" type=\"application/rss+xml\" href=\"/x.xml").feeds.isEmpty)
        #expect(discover("<html><!-- never closed \(rssLink("/c.xml"))").feeds.isEmpty)
        #expect(discover("<html><script>\(rssLink("/s.xml"))").feeds.isEmpty)
        // A tag that never closes is skipped after 8,192 bytes; what follows
        // is still read.
        let unclosed = "<html><div title=\"" + String(repeating: "a", count: 9_000) + " " + rssLink("/later.xml")
        #expect(addresses(discover(unclosed)) == ["https://site.example/later.xml"])
        // Invalid UTF-8 is replaced, not fatal.
        var bytes = Data("<html><head><title>A".utf8)
        bytes.append(contentsOf: [0xFF, 0xFE])
        bytes.append(Data("B</title>\(rssLink("/feed.xml"))</head></html>".utf8))
        let invalid = discover(bytes)
        #expect(invalid.title == "A\u{FFFD}\u{FFFD}B")
        #expect(addresses(invalid) == ["https://site.example/feed.xml"])
    }

    @Test("only the first megabyte is examined")
    func firstMegabyte() {
        let filler = String(repeating: " ", count: FeedDiscovery.examinedBytes)
        #expect(discover("<html>" + filler + rssLink("/late.xml")).feeds.isEmpty)
    }
}

extension TimedAndHeavySuites {
    /// RD05 criterion 3: discovery time grows in proportion to the size of
    /// a hostile document, not faster.
    @Suite("Feed discovery time")
    struct FeedDiscoveryTimeTests {
        private func bestOfThree(_ body: Data) -> Duration {
            let clock = ContinuousClock()
            return (0..<3).map { _ in
                clock.measure { _ = discover(body) }
            }.min()!
        }

        private func expectLinear(_ unit: String, count: Int) {
            let small = Data(("<html><body>" + String(repeating: unit, count: count)).utf8)
            let large = Data(("<html><body>" + String(repeating: unit, count: count * 4)).utf8)
            let smallTime = bestOfThree(small)
            let largeTime = bestOfThree(large)
            let ratio = largeTime / smallTime
            #expect(ratio < 8, "\(unit): \(smallTime) for \(small.count) bytes, \(largeTime) for \(large.count) bytes, ratio \(ratio)")
        }

        @Test("deeply nested table cells")
        func nestedCells() {
            expectLinear("<table><tr><td>", count: 15_000)
        }

        @Test("<link openings that never close")
        func unclosedLinks() {
            expectLinear("<link ", count: 40_000)
        }
    }
}
