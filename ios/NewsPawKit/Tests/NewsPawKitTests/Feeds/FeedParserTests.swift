import Foundation
@testable import NewsPawKit
import Testing

// Nested in the serialized group: see `TimedAndHeavySuites`.
extension TimedAndHeavySuites {
@Suite("Feed parser")
struct FeedParserTests {
    // MARK: - Criterion 1: the four formats

    @Test("RSS 2.0: feed and every mapped field")
    func rss2() throws {
        let feed = try #require(parse(try FeedFixture.data("rss2.xml")))
        #expect(feed.format == .rss)
        #expect(feed.title == "Synthetic Harbour & Gazette")
        #expect(feed.siteURL == "https://example.invalid/")
        #expect(feed.isComplete)
        #expect(feed.items == [
            ParsedItem(
                externalID: "gazette-0001",
                url: "https://example.invalid/articles/lighthouse",
                title: "Lighthouse keepers vote to repaint the tower",
                excerpt: "The keepers met on Tuesday & agreed.",
                author: "keeper@example.invalid (Ada Keeper)",
                imageURL: "https://example.invalid/images/tower.jpg",
                publishedAt: date("2026-11-09T23:00:00Z"),
                contentHTML: #"<p>Full text about the <em>tower</em>.</p><script>document.write("x")</script>"#
            ),
            ParsedItem(
                externalID: "https://example.invalid/articles/ferry-guid",
                url: "https://example.invalid/articles/ferry",
                title: "Ferry timetable changes for winter",
                excerpt: "Ferries run less often.",
                author: "Ben Pilot",
                imageURL: "https://example.invalid/images/ferry-thumb.jpg",
                publishedAt: date("2026-11-09T12:30:00Z"),
                contentHTML: "Ferries run less often."
            ),
            ParsedItem(
                externalID: "https://example.invalid/articles/market",
                url: "https://example.invalid/articles/market",
                title: "Market square reopens",
                imageURL: "https://example.invalid/images/market.png",
                publishedAt: date("2026-11-09T10:00:00Z")
            ),
        ])
    }

    @Test("RSS 1.0 (RDF): feed and every mapped field")
    func rss1() throws {
        let feed = try #require(parse(try FeedFixture.data("rss1.rdf")))
        #expect(feed.format == .rdf)
        #expect(feed.title == "Synthetic RDF feed")
        #expect(feed.siteURL == "https://example.invalid/rdf/")
        #expect(feed.items == [
            ParsedItem(
                externalID: "https://example.invalid/articles/first#about",
                url: "https://example.invalid/articles/first",
                title: "First synthetic item",
                excerpt: "The first item's excerpt.",
                author: "Fay Writer",
                publishedAt: date("2026-11-01T10:00:00Z"),
                contentHTML: "<p>The first item's <strong>body</strong>.</p>"
            ),
            ParsedItem(
                externalID: "https://example.invalid/articles/second#about",
                url: "https://example.invalid/articles/second",
                title: "Second synthetic item",
                excerpt: "The second item's excerpt.",
                publishedAt: date("2026-11-02T09:00:00Z"),
                contentHTML: "The second item's excerpt."
            ),
        ])
    }

    @Test("Atom: feed and every mapped field, XHTML content rebuilt as markup")
    func atom() throws {
        let feed = try #require(parse(try FeedFixture.data("atom.xml")))
        #expect(feed.format == .atom)
        #expect(feed.title == "Synthetic Observatory <Notes>")
        #expect(feed.siteURL == "https://example.invalid/observatory/")
        #expect(feed.items == [
            ParsedItem(
                externalID: "urn:uuid:00000000-0000-4000-8000-000000000002",
                url: "https://example.invalid/observatory/comet",
                title: "Comet <C/2026 X1> brightens",
                excerpt: "A bright comet.",
                author: "Cara Astronomer",
                imageURL: "https://example.invalid/images/comet.jpg",
                publishedAt: date("2026-11-09T23:00:00Z"),
                contentHTML: #"<p class="lead">Seen at 5 &lt; 6 o'clock &amp; later.<br>Next line <img alt="a &quot;q&quot;" src="/i.png"></p>"#
            ),
            ParsedItem(
                externalID: "tag:example.invalid,2026:telescope",
                url: "https://example.invalid/observatory/telescope",
                title: "Telescope upgrade & repairs",
                excerpt: "Plain text with <angle> brackets & an ampersand.",
                imageURL: "https://example.invalid/images/telescope.jpg",
                publishedAt: date("2026-11-09T07:00:00Z"),
                contentHTML: "Plain text with &lt;angle&gt; brackets &amp; an ampersand."
            ),
        ])
    }

    @Test("JSON Feed: feed and every mapped field")
    func jsonFeed() throws {
        let feed = try #require(parse(try FeedFixture.data("feed.json")))
        #expect(feed.format == .json)
        #expect(feed.title == "Synthetic Garden <Diary>")
        #expect(feed.siteURL == "https://example.invalid/garden/")
        #expect(feed.items == [
            ParsedItem(
                externalID: "garden-1",
                url: "https://example.invalid/garden/tulips",
                title: "Tulips <early> this year",
                excerpt: "Bulbs came up in November.",
                author: "Dee Gardener",
                imageURL: "https://example.invalid/garden/tulips.jpg",
                publishedAt: date("2026-11-08T06:00:00Z"),
                contentHTML: "<p>Tulip <b>text</b>.</p>"
            ),
            ParsedItem(
                externalID: "42",
                url: "https://example.invalid/garden/compost",
                title: "Compost notes",
                excerpt: "Turn it weekly. Keep it <moist> & warm.",
                author: "Eli Gardener",
                imageURL: "https://example.invalid/garden/compost.jpg",
                publishedAt: date("2026-11-07T05:00:00Z"),
                contentHTML: "Turn it weekly.\nKeep it &lt;moist&gt; &amp; warm."
            ),
        ])
    }

    @Test("elements are matched by namespace, whatever prefix the document uses")
    func unusualPrefixes() throws {
        let rdf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <r:RDF xmlns:r="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:x="http://purl.org/rss/1.0/" xmlns:c="http://purl.org/rss/1.0/modules/content/" xmlns:d="http://purl.org/dc/elements/1.1/" xmlns:m="http://search.yahoo.com/mrss/">
            <x:channel r:about="https://example.invalid/"><x:title>Odd prefixes</x:title><x:link>https://example.invalid/odd/</x:link></x:channel>
            <x:item r:about="https://example.invalid/about-1"><x:title>t &amp; <![CDATA[<b>cdata</b> 漢字]]> tail</x:title><c:encoded><![CDATA[<p>body</p>]]></c:encoded><d:creator>C</d:creator><d:date>2026-11-01T00:00:00Z</d:date><m:thumbnail url="https://example.invalid/t.jpg"/></x:item>
            </r:RDF>
            """
        let feed = try #require(parse(rdf))
        #expect(feed.title == "Odd prefixes")
        #expect(feed.siteURL == "https://example.invalid/odd/")
        #expect(feed.items == [ParsedItem(
            externalID: "https://example.invalid/about-1", title: "t & cdata 漢字 tail", excerpt: "body", author: "C",
            imageURL: "https://example.invalid/t.jpg", publishedAt: date("2026-11-01T00:00:00Z"), contentHTML: "<p>body</p>"
        )])

        let atom = """
            <a:feed xmlns:a="http://www.w3.org/2005/Atom" xmlns:h="http://www.w3.org/1999/xhtml"><a:title>prefixed</a:title><a:id>urn:f</a:id>
            <a:entry><a:id>urn:1</a:id><a:title type="xhtml"><h:div>Less: <h:em>a &lt; b</h:em></h:div></a:title><a:link rel="alternate" href="/1"/>
            <a:content type="xhtml"><h:div><h:p class="a&amp;b &quot;q&quot;">x &lt; y &amp; z<h:br/>line</h:p><svg xmlns="http://www.w3.org/2000/svg" width="1"><circle r="1"/></svg></h:div></a:content></a:entry>
            </a:feed>
            """
        let atomFeed = try #require(parse(atom))
        #expect(atomFeed.title == "prefixed")
        #expect(atomFeed.items.map(\.title) == ["Less: a < b"])
        #expect(atomFeed.items.map(\.url) == ["https://example.invalid/1"])
        #expect(atomFeed.items.map(\.contentHTML) == [
            #"<p class="a&amp;b &quot;q&quot;">x &lt; y &amp; z<br>line</p><svg width="1"><circle r="1"></circle></svg>"#,
        ])
        // An element of another namespace that shares a local name is not
        // taken for the feed's own.
        let foreign = rssDocument("""
            <item><other:title xmlns:other="https://example.invalid/ns">Wrong</other:title><title>Right</title><guid>g</guid></item>
            """)
        #expect(try #require(parse(foreign)).items.map(\.title) == ["Right"])
    }

    @Test("links and image addresses are resolved against the final address; other schemes are dropped")
    func addressResolution() throws {
        let document = rssDocument("""
            <item><guid>a</guid><link>../story?id=1</link><enclosure url="img/a.png" type="image/png"/></item>
            <item><guid>b</guid><link>javascript:alert(1)</link><media:thumbnail url="data:image/png;base64,AAAA"/></item>
            <item><guid>c</guid><link>//cdn.example.invalid/c</link></item>
            <item><guid>d</guid><link>https://user:secret@example.invalid/d</link></item>
            """, channel: "<title>t</title><link>/home/</link>")
        let feed = try #require(parse(document, base: URL(string: "https://feeds.example.invalid/news/rss.xml")!))
        #expect(feed.siteURL == "https://feeds.example.invalid/home/")
        #expect(feed.items.map(\.url) == [
            "https://feeds.example.invalid/story?id=1", nil, "https://cdn.example.invalid/c", nil,
        ])
        #expect(feed.items.map(\.imageURL) == ["https://feeds.example.invalid/news/img/a.png", nil, nil, nil])
    }

    // MARK: - Criterion 3: one unusable part does not fail the feed

    @Test("an unparseable date, a malformed enclosure or markup in a text field leaves that item with the field absent")
    func badFieldsAreAbsent() throws {
        let document = rssDocument("""
            <item><guid>bad-date</guid><title>Bad date</title><pubDate>the day after tomorrow</pubDate></item>
            <item><guid>bad-enclosure</guid><title>Bad enclosure</title><enclosure length="many" type="image/jpeg"/><enclosure url="" type="image/png" length="-1"/></item>
            <item><guid>markup-title</guid><title>Bold <b>title</b></title><description>Kept.</description></item>
            <item><guid>markup-date</guid><title>Markup date</title><pubDate><span>Tue, 10 Nov 2026 08:00:00 GMT</span></pubDate></item>
            <item><guid>fine</guid><title>Fine</title><pubDate>Tue, 10 Nov 2026 08:00:00 GMT</pubDate></item>
            """, channel: "<title><x>broken</x></title><link>javascript:void(0)</link>")
        let feed = try #require(parse(document))
        #expect(feed.isComplete)
        #expect(feed.title == nil)
        #expect(feed.siteURL == nil)
        #expect(feed.items.map(\.externalID) == ["bad-date", "bad-enclosure", "markup-title", "markup-date", "fine"])
        #expect(feed.items[0].publishedAt == nil)
        #expect(feed.items[0].title == "Bad date")
        #expect(feed.items[1].imageURL == nil)
        #expect(feed.items[1].title == "Bad enclosure")
        #expect(feed.items[2].title == nil)
        #expect(feed.items[2].excerpt == "Kept.")
        #expect(feed.items[3].publishedAt == nil)
        #expect(feed.items[4].publishedAt == date("2026-11-10T08:00:00Z"))
    }

    @Test("JSON Feed fields of the wrong type are absent and do not affect the others")
    func jsonWrongTypes() throws {
        let json = """
            {"version": "https://jsonfeed.org/version/1", "title": 7, "home_page_url": ["x"], "items": [
              {"id": {"nested": true}, "url": "https://example.invalid/a", "title": 12, "date_published": "yesterday"},
              {"id": true, "url": "https://example.invalid/b", "title": "B", "image": 5, "authors": "nobody"},
              "not an object",
              {"id": 1.5, "title": "C", "content_html": null, "content_text": "c"},
              {"summary": "no identity at all"}
            ]}
            """
        let feed = try #require(parse(json))
        #expect(feed.title == nil)
        #expect(feed.siteURL == nil)
        #expect(feed.items.map(\.externalID) == ["https://example.invalid/a", "https://example.invalid/b", "1.5"])
        #expect(feed.items.map(\.title) == [nil, "B", "C"])
        #expect(feed.items[0].publishedAt == nil)
        #expect(feed.items[1].imageURL == nil)
        #expect(feed.items[1].author == nil)
        #expect(feed.items[2].contentHTML == "c")
    }

    @Test(
        "a document that breaks part-way keeps its completed items and is incomplete",
        arguments: [
            ("unescaped ampersand", "<item><guid>3</guid><title>Fish & chips</title></item>"),
            ("undefined entity", "<item><guid>3</guid><title>Caf&eacute;</title></item>"),
            ("truncated download", "<item><guid>3</guid><title>Cut he"),
        ]
    )
    func brokenPartWay(_ label: String, _ tail: String) throws {
        let document = """
            <?xml version="1.0" encoding="UTF-8"?>
            <rss version="2.0"><channel><title>Breaks</title>
            <item><guid>1</guid><title>One</title></item>
            <item><guid>2</guid><title>Two</title></item>
            \(tail)
            """
        let feed = try #require(parse(document), "\(label)")
        #expect(feed.isComplete == false)
        #expect(feed.items.map(\.externalID) == ["1", "2"])
    }

    @Test("a document that breaks before any item is complete is not a feed")
    func brokenBeforeAnyItem() {
        #expect(parse("<rss version=\"2.0\"><channel><title>t</title><item><guid>1</guid><title>A & B</title></item></channel></rss>") == nil)
        #expect(parse("<rss version=\"2.0\"><channel><title>t</ti") == nil)
    }

    // MARK: - Criterion 4: not a feed

    @Test(
        "documents that are not feeds are refused, including ones a lenient parser reads as empty feeds",
        arguments: [
            ("XHTML page", #"<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>Page</title></head><body><p>rss feed</p></body></html>"#),
            ("HTML page", "<!DOCTYPE html><html><head><title>Page</title><link rel=\"alternate\" type=\"application/rss+xml\" href=\"/feed\"></head><body></body></html>"),
            ("RSS without a channel", #"<rss version="2.0"><item><guid>1</guid><title>Orphan</title></item></rss>"#),
            ("RDF without channel or item", #"<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description/></rdf:RDF>"#),
            ("Atom root without id, title or entry", #"<feed xmlns="http://www.w3.org/2005/Atom"><updated>2026-11-01T00:00:00Z</updated></feed>"#),
            ("feed root without the Atom namespace", "<feed><title>t</title><entry><id>1</id></entry></feed>"),
            ("JSON that is not JSON Feed", #"{"title": "Not a feed", "items": [{"id": "1"}]}"#),
            ("JSON with another version", #"{"version": "https://example.invalid/version/1", "items": []}"#),
            ("JSON array", #"[{"version": "https://jsonfeed.org/version/1"}]"#),
            ("plain text", "Just some words, not a feed."),
            ("empty", ""),
        ]
    )
    func notAFeed(_ label: String, _ document: String) {
        #expect(parse(document) == nil, "\(label)")
    }

    @Test("a JSON Feed behind a byte-order mark and white space is read")
    func jsonWithByteOrderMark() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("\n  ".utf8))
        data.append(try FeedFixture.data("feed.json"))
        #expect(parse(data) == parse(try FeedFixture.data("feed.json")))
        #expect(parse(data)?.items.count == 2)
    }

    @Test("a repeated Atom feed title keeps the first one and its type")
    func repeatedAtomTitle() throws {
        let feed = try #require(parse(#"<feed xmlns="http://www.w3.org/2005/Atom"><title>&lt;kept&gt;</title><title type="html">&lt;b&gt;second&lt;/b&gt;</title><id>x</id></feed>"#))
        #expect(feed.title == "<kept>")
    }

    @Test("a valid feed with zero items is a feed with nothing in it")
    func zeroItems() throws {
        for document in [
            rssDocument(""),
            #"<feed xmlns="http://www.w3.org/2005/Atom"><title>Empty</title><id>urn:e</id></feed>"#,
            #"<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/"><channel><title>Empty</title></channel></rdf:RDF>"#,
            #"{"version": "https://jsonfeed.org/version/1.1", "title": "Empty", "items": []}"#,
        ] {
            let feed = try #require(parse(document))
            #expect(feed.items.isEmpty)
            #expect(feed.isComplete)
        }
    }

    // MARK: - Criterion 8: identity

    @Test("identity is the feed's identifier: RSS guid, RDF rdf:about, Atom id, JSON id")
    func identityFromIdentifier() throws {
        #expect(try #require(parse(rssDocument("<item><guid>  spaced-guid \n</guid><link>https://example.invalid/x</link></item>"))).items.map(\.externalID) == ["spaced-guid"])
        #expect(try #require(parse(try FeedFixture.data("rss1.rdf"))).items.first?.externalID == "https://example.invalid/articles/first#about")
        #expect(try #require(parse(try FeedFixture.data("atom.xml"))).items.first?.externalID == "urn:uuid:00000000-0000-4000-8000-000000000002")
        #expect(try #require(parse(try FeedFixture.data("feed.json"))).items.map(\.externalID) == ["garden-1", "42"])
    }

    @Test("without an identifier the identity is the link")
    func identityFromLink() throws {
        let rss = try #require(parse(rssDocument("<item><title>T</title><link>/relative/x</link><guid>   </guid></item>")))
        #expect(rss.items.map(\.externalID) == ["https://example.invalid/relative/x"])
        let atom = try #require(parse(#"<feed xmlns="http://www.w3.org/2005/Atom"><title>F</title><entry><title>T</title><link href="https://example.invalid/e"/></entry></feed>"#))
        #expect(atom.items.map(\.externalID) == ["https://example.invalid/e"])
        let json = try #require(parse(#"{"version": "https://jsonfeed.org/version/1.1", "items": [{"url": "https://example.invalid/j", "title": "T"}]}"#))
        #expect(json.items.map(\.externalID) == ["https://example.invalid/j"])
    }

    @Test("without identifier or link the identity is a hash of the raw title and raw date")
    func identityFromHash() throws {
        let feed = try #require(parse(rssDocument("""
            <item><title>Raw &lt;b&gt;title&lt;/b&gt;</title><pubDate>Tue, 10 Nov 2026 08:00:00 GMT</pubDate></item>
            <item><title>Title only</title></item>
            <item><pubDate>Mon, 09 Nov 2026 08:00:00 GMT</pubDate><description>Date only</description></item>
            <item><title>Bad link</title><link>mailto:someone@example.invalid</link></item>
            """)))
        #expect(feed.items.map(\.externalID) == [
            ItemIdentity.hash(title: "Raw <b>title</b>", date: "Tue, 10 Nov 2026 08:00:00 GMT"),
            ItemIdentity.hash(title: "Title only", date: nil),
            ItemIdentity.hash(title: nil, date: "Mon, 09 Nov 2026 08:00:00 GMT"),
            ItemIdentity.hash(title: "Bad link", date: nil),
        ])
        for identity in feed.items.map(\.externalID) {
            #expect(identity.hasPrefix("sha256:"))
            #expect(identity.count == "sha256:".count + 64)
        }
        #expect(ItemIdentity.hash(title: "ab", date: "c") != ItemIdentity.hash(title: "a", date: "bc"))
        // The hash is stable: the same raw strings give the same identity.
        #expect(ItemIdentity.hash(title: "Title only", date: nil) == ItemIdentity.hash(title: "Title only", date: nil))
    }

    @Test("an item with no identifier, link, title or date is skipped")
    func identityMissing() throws {
        let feed = try #require(parse(rssDocument("""
            <item><description>Nothing to identify me</description></item>
            <item><guid>kept</guid></item>
            """)))
        #expect(feed.items.map(\.externalID) == ["kept"])
        let json = try #require(parse(#"{"version": "https://jsonfeed.org/version/1", "items": [{"summary": "none"}, {"id": "", "title": "kept"}]}"#))
        #expect(json.items.map(\.title) == ["kept"])
    }

    @Test("an RSS guid that is a permalink becomes the link when there is none; one marked otherwise does not")
    func permalinkIdentifier() throws {
        let feed = try #require(parse(rssDocument("""
            <item><guid>https://example.invalid/p1</guid></item>
            <item><guid isPermaLink="false">https://example.invalid/p2</guid></item>
            <item><guid isPermaLink="true">urn:not-a-web-address</guid></item>
            <item><guid>https://example.invalid/p4</guid><link>https://example.invalid/own-link</link></item>
            """)))
        #expect(feed.items.map(\.url) == ["https://example.invalid/p1", nil, nil, "https://example.invalid/own-link"])
    }

    // MARK: - Criterion 11: titles

    @Test("titles: JSON and Atom text titles are kept as written; HTML titles are reduced to text")
    func titles() throws {
        let atom = try #require(parse("""
            <feed xmlns="http://www.w3.org/2005/Atom"><title type="html">&lt;i&gt;Feed&lt;/i&gt;</title>
            <entry><id>1</id><title>a &lt; b &amp;&amp; c &gt; d</title></entry>
            <entry><id>2</id><title type="text">&lt;script&gt;x&lt;/script&gt; kept</title></entry>
            <entry><id>3</id><title type="html">&lt;script&gt;x&lt;/script&gt;Shown &amp;amp; decoded</title></entry>
            <entry><id>4</id><title type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><b>X</b>HTML</div></title></entry>
            </feed>
            """))
        #expect(atom.title == "Feed")
        #expect(atom.items.map(\.title) == ["a < b && c > d", "<script>x</script> kept", "Shown & decoded", "XHTML"])

        let json = try #require(parse(#"{"version": "https://jsonfeed.org/version/1.1", "title": "<b>as</b>  written", "items": [{"id": "1", "title": "  1 < 2 &amp; <i>x</i>\n"}]}"#))
        #expect(json.title == "<b>as</b> written")
        #expect(json.items.map(\.title) == ["1 < 2 &amp; <i>x</i>"])

        let rss = try #require(parse(rssDocument("<item><guid>1</guid><title>Tom &amp;amp; Jerry &lt;br&gt;  again</title></item>")))
        #expect(rss.items.map(\.title) == ["Tom & Jerry again"])
    }

    // MARK: - Criterion 12: content and excerpt

    @Test("content is the feed's content, else its description; a full text in the description is kept")
    func contentSources() throws {
        let long = String(repeating: "<p>Full text paragraph.</p>", count: 200)
        let feed = try #require(parse(rssDocument("""
            <item><guid>1</guid><description>Short</description><content:encoded>&lt;p&gt;Long&lt;/p&gt;</content:encoded></item>
            <item><guid>2</guid><description><![CDATA[\(long)]]></description></item>
            <item><guid>3</guid><title>Nothing else</title></item>
            """)))
        #expect(feed.items[0].contentHTML == "<p>Long</p>")
        #expect(feed.items[0].excerpt == "Short")
        #expect(feed.items[1].contentHTML == long)
        #expect(feed.items[2].contentHTML == nil)
        #expect(feed.items[2].excerpt == nil)
    }

    @Test("plain-text content is escaped so that it reads as text when treated as HTML")
    func plainTextEscaped() throws {
        let atom = try #require(parse(#"<feed xmlns="http://www.w3.org/2005/Atom"><title>F</title><entry><id>1</id><summary>Use &lt;b&gt; &amp; "quotes" 'too'</summary></entry></feed>"#))
        #expect(atom.items.map(\.contentHTML) == ["Use &lt;b&gt; &amp; &quot;quotes&quot; &#39;too&#39;"])
        #expect(atom.items.map(\.excerpt) == [#"Use <b> & "quotes" 'too'"#])
        #expect(HTMLText.reduce(atom.items[0].contentHTML!) == #"Use <b> & "quotes" 'too'"#)
    }

    @Test("the excerpt comes from the description, else from the content's text, cut at 500 characters")
    func excerptSources() throws {
        let words = String(repeating: "word ", count: 300)
        let feed = try #require(parse(rssDocument("""
            <item><guid>1</guid><content:encoded><![CDATA[<style>p{}</style><p>From <i>content</i></p><script>var x = "<p>";</script>]]></content:encoded></item>
            <item><guid>2</guid><description><![CDATA[<p>\(words)</p>]]></description></item>
            <item><guid>3</guid><description>   </description><content:encoded>Fallback</content:encoded></item>
            """)))
        #expect(feed.items[0].excerpt == "From content")
        let excerpt = try #require(feed.items[1].excerpt)
        #expect(excerpt.count <= 500)
        #expect(excerpt.count >= 495)
        #expect(words.hasPrefix(excerpt))
        #expect(feed.items[2].excerpt == "Fallback")
    }

    // MARK: - Criterion 15 (parser part): nothing is executed or followed

    @Test("a document type and entities naming files are not read")
    func localEntitiesNotRead() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secret = directory.appending(path: "secret.txt")
        try "LOCAL-FILE-CONTENT".write(to: secret, atomically: true, encoding: .utf8)
        let document = """
            <?xml version="1.0"?>
            <!DOCTYPE rss SYSTEM "\(secret.absoluteString)" [<!ENTITY x SYSTEM "\(secret.absoluteString)">]>
            <rss version="2.0"><channel><title>t</title><item><guid>1</guid><title>a &x; b</title><description>ok</description></item><item><guid>2</guid></item></channel></rss>
            """
        let feed = parse(document)
        let text = feed.map { "\($0)" } ?? ""
        #expect(!text.contains("LOCAL-FILE-CONTENT"))
    }

    @Test("nested entity expansion is refused at once")
    func entityExpansion() throws {
        var bomb = #"<?xml version="1.0"?><!DOCTYPE rss [<!ENTITY a0 "aaaaaaaaaa">"#
        for level in 1...9 {
            bomb += "<!ENTITY a\(level) \"" + String(repeating: "&a\(level - 1);", count: 10) + "\">"
        }
        bomb += #"]><rss version="2.0"><channel><title>t</title><item><guid>1</guid><title>&a9;</title></item></channel></rss>"#
        let start = ContinuousClock.now
        let feed = parse(bomb)
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect((feed?.items.first?.title?.count ?? 0) < 1_000_000)
    }

    // MARK: - Robustness

    @Test("truncations and byte edits of every fixture never crash the parser")
    func corruptedInputs() throws {
        var generator = SeededGenerator(seed: 0x5EED)
        for name in ["rss2.xml", "rss1.rdf", "atom.xml", "feed.json", "ja-utf8.xml", "ja-shift_jis.xml", "ja-euc-jp.xml"] {
            let original = try FeedFixture.data(name)
            for length in 0..<original.count {
                _ = parse(original.prefix(length), charset: "Shift_JIS")
            }
            for _ in 0..<400 {
                var edited = original
                for _ in 0..<Int.random(in: 1...4, using: &generator) {
                    let index = Int.random(in: 0..<edited.count, using: &generator)
                    edited[index] = UInt8.random(in: 0...255, using: &generator)
                }
                _ = parse(edited, charset: "EUC-JP")
            }
        }
    }
}
}

/// A small deterministic generator (SplitMix64) so that failures reproduce.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
