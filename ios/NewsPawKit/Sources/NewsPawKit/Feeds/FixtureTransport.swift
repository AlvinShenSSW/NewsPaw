#if DEBUG
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// The transport of a debug build running under the UI tests (RD05
/// criterion 19): it answers a fixed table of synthetic documents and
/// reports every other address as unreachable, so no UI test reaches a real
/// host. Compiled into debug builds only; release builds do not contain it.
public final class FixtureTransport: Transport {
    /// The candidate limit the app uses with this transport, so that a
    /// declared feed that answers slowly is "not checked" in a second.
    public static let candidateLimit = Duration.seconds(1)
    /// How long the slow declared feed takes to answer.
    static let slowAnswer = Duration.seconds(3)

    /// The addresses of the table, in normal form.
    public enum Address {
        /// An RSS feed with three items.
        public static let feed = "https://feed.example.invalid/rss.xml"
        /// A page declaring two feeds, RSS and Atom.
        public static let twoFeeds = "https://twofeeds.example.invalid/"
        /// A page declaring one feed.
        public static let oneFeed = "https://onefeed.example.invalid/"
        /// A page with a title and no feed.
        public static let noFeed = "https://nofeed.example.invalid/"
        /// An address answering 403.
        public static let forbidden = "https://forbidden.example.invalid/"
        /// An address that does not answer.
        public static let unreachable = "https://unreachable.example.invalid/"
        /// An address whose exchange passes its deadline.
        public static let timesOut = "https://timeout.example.invalid/"
        /// A page declaring a feed that answers and one that answers only
        /// after the candidate limit.
        public static let slowFeeds = "https://slowfeeds.example.invalid/"
        /// The slow feed `slowFeeds` declares.
        public static let slowFeed = "https://slowfeeds.example.invalid/slow.xml"
        /// A feed that answers, then fails, then answers again, counted per
        /// transport.
        public static let sequence = "https://sequence.example.invalid/rss.xml"
        /// The suggested BBC World feed, answered with a synthetic feed.
        public static let suggested = "https://feeds.bbci.co.uk/news/world/rss.xml"
        /// A feed whose every answer holds one item with an identifier and
        /// a link that no earlier answer had, in this process or another, so
        /// that each request shows as one more unread article (RD06).
        public static let counting = "https://counting.example.invalid/rss.xml"
        /// A feed of three articles with authors and excerpts (RD09): "Image
        /// story" names `articleImage`, "Plain story" names no image, and
        /// "Linkless story" has no link.
        public static let articles = "https://articles.example.invalid/rss.xml"
        /// The image "Image story" names: a PNG made in code, larger than a
        /// thumbnail, with a transparent part.
        public static let articleImage = "https://articles.example.invalid/image.png"
        /// A feed of 40 fixed items, an hour apart, long enough to scroll,
        /// and in every answer one more undated item that no earlier answer
        /// had, so that each request adds a row at the top of its list
        /// (RD09).
        public static let longCounting = "https://longcounting.example.invalid/rss.xml"
        /// A feed whose items cover what the reading screen lays out (RD11):
        /// "Every block", "Line heights", "Short note" (an excerpt), "Hostile
        /// story", "Cut story" (more blocks than are shown), "Cut linkless
        /// story" (more characters than are read, and no link), "Picture
        /// story", "Hundred pictures" and "Empty body".
        public static let reading = "https://reading.example.invalid/rss.xml"
        /// The images of that feed's bodies, under this address: `photo.png`
        /// (600 × 400), `small.png` (60 × 40), `pixel.png` (1 × 1),
        /// `flaky.png` (no answer for `flakyImageWindow` from a transport's
        /// first request for it, the photo after that: it fails when an
        /// article is first opened, however many times it is asked for
        /// then, and answers when the article is opened again later),
        /// `vector.svg` (not an image the system decodes),
        /// `big/<number>.png` (2,400 × 1,600) and `tall.png` (1,080 ×
        /// 6,000, lines of text). Any other name does not answer.
        public static let readingImages = "https://reading.example.invalid/images/"
    }

    /// How long `flaky.png` fails from the first request for it.
    static let flakyImageWindow = Duration.seconds(4)

    private let sequenceRequests = Mutex(0)
    /// When `flaky.png` was first asked for.
    private let flakyImageFirstRequest = Mutex<ContinuousClock.Instant?>(nil)

    public init() {}

    public func fetch(_ request: TransportRequest) async throws -> TransportResponse {
        try Task.checkCancellation()
        let url = request.url
        func answer(_ body: String, type: String, status: Int = 200) -> TransportResponse {
            TransportResponse(finalURL: url, status: status, headers: ["Content-Type": type], body: Data(body.utf8))
        }
        let rss = "application/rss+xml; charset=utf-8"
        let html = "text/html; charset=utf-8"
        switch url.absoluteString {
        case Address.feed:
            return answer(Self.rss(title: "Fixture Feed", items: ["Fixture story one", "Fixture story two", "Fixture story three"]), type: rss)
        case Address.twoFeeds:
            return answer(Self.page(title: "Two Feeds Site", links: [
                ("application/rss+xml", "/news.xml", "News"), ("application/atom+xml", "/atom.xml", "Updates"),
            ]), type: html)
        case "https://twofeeds.example.invalid/news.xml":
            return answer(Self.rss(title: "Two Feeds News", items: ["News story one", "News story two"]), type: rss)
        case "https://twofeeds.example.invalid/atom.xml":
            return answer(Self.atom(title: "Two Feeds Updates", items: ["Update one", "Update two"]), type: "application/atom+xml")
        case Address.oneFeed:
            return answer(Self.page(title: "One Feed Site", links: [("application/rss+xml", "/feed.xml", "Feed")]), type: html)
        case "https://onefeed.example.invalid/feed.xml":
            return answer(Self.rss(title: "One Feed", items: ["One feed story"]), type: rss)
        case Address.noFeed:
            return answer(Self.page(title: "Plain Page", links: []), type: html)
        case Address.forbidden:
            return answer("", type: html, status: 403)
        case Address.timesOut:
            throw TransportFailure.timedOut
        case Address.slowFeeds:
            return answer(Self.page(title: "Slow Feeds Site", links: [
                ("application/rss+xml", "/fast.xml", "Fast"), ("application/rss+xml", "/slow.xml", "Slow"),
            ]), type: html)
        case "https://slowfeeds.example.invalid/fast.xml":
            return answer(Self.rss(title: "Fast Feed", items: ["Fast story"]), type: rss)
        case Address.slowFeed:
            try await Task.sleep(for: Self.slowAnswer)
            return answer(Self.rss(title: "Slow Feed", items: ["Slow story"]), type: rss)
        case Address.sequence:
            let number = sequenceRequests.withLock { count in
                count += 1
                return count
            }
            if number == 2 {
                return answer("", type: html, status: 500)
            }
            return answer(Self.rss(title: "Sequence Feed", items: ["Sequence story \(number)"]), type: rss)
        case Address.suggested:
            return answer(Self.rss(title: "BBC News (fixture)", items: ["Fixture world story"]), type: rss)
        case Address.counting:
            // The identifier and the link are built from the item's text.
            return answer(Self.rss(title: "Counting Feed", items: ["Counting story \(UUID().uuidString)"]), type: rss)
        case Address.articles:
            return answer(Self.articlesFeed, type: rss)
        case Address.articleImage:
            return TransportResponse(finalURL: url, status: 200, headers: ["Content-Type": "image/png"], body: Self.articleImagePNG)
        case Address.longCounting:
            return answer(Self.longCountingFeed(fresh: String(UUID().uuidString.prefix(8))), type: rss)
        case Address.reading:
            return answer(Self.readingFeed, type: rss)
        case let address where address.hasPrefix(Address.readingImages):
            return try readingImage(String(address.dropFirst(Address.readingImages.count)), at: url)
        default:
            throw TransportFailure.unreachable
        }
    }

    /// An image of the reading feed's bodies.
    private func readingImage(_ name: String, at url: URL) throws -> TransportResponse {
        func image(_ body: Data, type: String = "image/png") -> TransportResponse {
            TransportResponse(finalURL: url, status: 200, headers: ["Content-Type": type], body: body)
        }
        switch name {
        case "photo.png":
            return image(Self.articleImagePNG)
        case "small.png":
            return image(Self.smallImagePNG)
        case "pixel.png":
            return image(Self.pixelImagePNG)
        case "flaky.png":
            let now = ContinuousClock.now
            let first = flakyImageFirstRequest.withLock { first in
                first = first ?? now
                return first ?? now
            }
            if now - first < Self.flakyImageWindow {
                throw TransportFailure.unreachable
            }
            return image(Self.articleImagePNG)
        case "vector.svg":
            let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><rect width="40" height="40"/></svg>"#
            return image(Data(svg.utf8), type: "image/svg+xml")
        case let name where name.hasPrefix("big/") && name.hasSuffix(".png"):
            return image(Self.bigImagePNG)
        case "tall.png":
            return image(Self.tallImagePNG)
        default:
            throw TransportFailure.unreachable
        }
    }

    // MARK: - Documents

    /// Items dated an hour apart, the first the newest, all in the past.
    private static func rss(title: String, items: [String]) -> String {
        let entries = items.enumerated().map { index, item in
            """
            <item><title>\(item)</title><link>https://example.invalid/\(slug(title))/\(slug(item))</link>\
            <guid>\(slug(title))-\(index)-\(item)</guid><pubDate>\(date(hoursAgo: index + 1))</pubDate></item>
            """
        }.joined(separator: "\n")
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <rss version="2.0"><channel><title>\(title)</title><link>https://example.invalid/\(slug(title))</link>
            \(entries)
            </channel></rss>
            """
    }

    /// The articles feed: dated items with excerpts and authors, newest
    /// first.
    private static let articlesFeed: String = {
        let items = [
            """
            <item><title>Image story</title><link>https://example.invalid/articles/image-story</link>\
            <guid>articles-image-story</guid><author>Fixture Writer</author>\
            <description>The harbour at dusk, with the lights coming on along the quay.</description>\
            <enclosure url="\(Address.articleImage)" type="image/png" length="0"/>\
            <pubDate>\(date(hoursAgo: 1))</pubDate></item>
            """,
            """
            <item><title>Plain story</title><link>https://example.invalid/articles/plain-story</link>\
            <guid>articles-plain-story</guid><author>Fixture Writer</author>\
            <description>A market opens early, before the rain arrives.</description>\
            <pubDate>\(date(hoursAgo: 2))</pubDate></item>
            """,
            """
            <item><title>Linkless story</title><guid isPermaLink="false">articles-linkless-story</guid>\
            <description>A note that names no page of its own.</description>\
            <pubDate>\(date(hoursAgo: 3))</pubDate></item>
            """,
        ]
        return channel(title: "Articles Feed", items: items)
    }()

    /// The long counting feed: an undated new item, then the 40 fixed
    /// items, newest first.
    private static func longCountingFeed(fresh: String) -> String {
        let new = """
            <item><title>Fresh story \(fresh)</title><link>https://example.invalid/longcounting/fresh-\(fresh)</link>\
            <guid>longcounting-fresh-\(fresh)</guid><description>One more story.</description></item>
            """
        let fixed = (1...40).map { number in
            let name = String(format: "%02d", number)
            return """
                <item><title>Long story \(name)</title><link>https://example.invalid/longcounting/\(name)</link>\
                <guid>longcounting-\(name)</guid><description>Story number \(name).</description>\
                <pubDate>\(date(hoursAgo: number))</pubDate></item>
                """
        }
        return channel(title: "Long Counting Feed", items: [new] + fixed)
    }

    // MARK: - The reading feed (RD11)

    /// One item of the reading feed: its body in `content:encoded`.
    private static func readingItem(
        _ title: String, slug: String?, hoursAgo: Int, description: String? = nil, body: String
    ) -> String {
        let link = slug.map { "<link>https://example.invalid/articles/\($0)</link>" } ?? ""
        let summary = description.map { "<description>\($0)</description>" } ?? ""
        return """
            <item><title>\(title)</title>\(link)<guid isPermaLink="false">reading-\(slug ?? Self.slug(title))</guid>\
            <author>Fixture Writer</author>\(summary)\
            <content:encoded><![CDATA[\(body)]]></content:encoded>\
            <pubDate>\(date(hoursAgo: hoursAgo))</pubDate></item>
            """
    }

    /// A body with every block kind and more than 1,000 characters of text.
    static let everyBlockBody: String = {
        let filler = "The tide tables for the week ahead are posted at the harbour office each morning, and the pilots read them before the first ferry leaves."
        return """
            <h2>The harbour at dusk</h2>
            <p>A paragraph with <b>bold words</b>, <i>italic words</i>, <code>inline code</code> and \
            <a href="/articles/linked-page">a link to another page</a>. \(filler)</p>
            <h3>What the boats carry</h3>
            <ul><li>Bread from the mainland</li><li>Letters and parcels<ul><li>Sorted on the quay</li></ul></li></ul>
            <ol start="3"><li>Third on the list</li><li>Fourth on the list</li></ol>
            <ol start="99"><li><p>Ninety-ninth on the list</p><p>A second paragraph of the ninety-ninth item</p></li>\
            <li>The hundredth on the list<ol start="9998"><li>Nested at 9,998</li><li>Nested at 9,999</li></ol></li></ol>
            <blockquote><p>The lights come on along the quay.</p><blockquote><p>And the boats ride at their moorings.</p></blockquote></blockquote>
            <figure><img src="\(Address.readingImages)photo.png" alt="The harbour, drawn as a blue disc" width="600" height="400">\
            <figcaption>A caption under the picture</figcaption></figure>
            <pre>let tide = Tide(turning: .now)
            print(tide.height(at: quay, in: .metres), tide.next, tide.previous, harbour.pilots.count)</pre>
            <hr>
            <table><tr><th>Boat</th><th>Leaves</th></tr><tr><td>Ferry</td><td>07:10</td></tr></table>
            <h4>A smaller heading</h4>
            <p>First line of a paragraph<br>and its second line.</p>
            <p>这是一段中文正文，用来看中文的行高、换行和字形是否正确。\(String(repeating: "港口的灯沿着码头依次亮起，渡船在潮水转向时回到泊位。", count: 4))</p>
            <p>これは日本語の段落です。港の灯りが岸壁に沿って順に点り、渡し船は潮の変わり目に戻ってきます。</p>
            <p>\(filler) \(filler) \(filler)</p>
            <p>The last paragraph of the article.</p>
            """
    }()

    /// A body that tries what an article must not do (criterion 2).
    static let hostileBody = """
        <script>document.title = "script ran"</script><style>p { display: none }</style>
        <p onclick="alert('clicked')" style="color: red">Before the links.</p>
        <p><a href="javascript:alert('ran')">A script link</a> and <a href="data:text/html,<b>x</b>">a data link</a> \
        and <a href="/articles/safe-page">a safe link</a>.</p>
        <iframe src="https://frame.example.invalid/embed">Frame text</iframe>
        <form action="https://post.example.invalid/"><input name="q" value="Input text"><button>Button text</button></form>
        <img src="data:image/gif;base64,R0lGODlhAQABAAAAACw=" data-src="\(Address.readingImages)photo.png" alt="A lazy picture">
        <img src="\(Address.readingImages)tracker.png" width="1" height="1" alt="A tracker">
        <p>After the links.</p>
        """

    /// The pictures of "Picture story": one that loads, a small one, a
    /// pixel that declares no size, one that fails once, one the system
    /// cannot decode, one that never answers and has no alternative text,
    /// and a long one.
    static let pictureBody = """
        <p>A picture that loads:</p><img src="\(Address.readingImages)photo.png" alt="A photograph">
        <p>A small picture:</p><img src="\(Address.readingImages)small.png" alt="A small picture">
        <p>A pixel:</p><img src="\(Address.readingImages)pixel.png" alt="A pixel">
        <p>A picture that fails once:</p><img src="\(Address.readingImages)flaky.png" alt="A flaky picture">
        <p>A drawing the system cannot decode:</p><img src="\(Address.readingImages)vector.svg" alt="A vector drawing">
        <p>A picture that never answers:</p><img src="\(Address.readingImages)missing.png">
        <p>A long picture:</p><img src="\(Address.readingImages)tall.png" alt="A long picture">
        <p>After the pictures.</p>
        """

    /// Paragraphs of two and three short lines in Latin, Chinese and
    /// Japanese, whose heights give the line height (criterion 8).
    static let lineHeightsBody = """
        <p>Line one<br>Line two</p><p>Line one<br>Line two<br>Line three</p>
        <p>第一行字<br>第二行字</p><p>第一行字<br>第二行字<br>第三行字</p>
        <p>一行目の文<br>二行目の文</p><p>一行目の文<br>二行目の文<br>三行目の文</p>
        """

    private static let readingFeed: String = {
        let manyParagraphs = (1...3_050).map { "<p>Paragraph \($0) of a very long story.</p>" }.joined()
        // A short text, then a comment that runs past the input limit.
        let longInput = "<p>The start of a story too long to read whole.</p><!-- "
            + String(repeating: "x", count: ArticleBlocks.maximumInputCharacters) + " --><p>Never read.</p>"
        let hundredPictures = (1...100).map {
            "<p>Picture \($0) of a hundred.</p><img src=\"\(Address.readingImages)big/\($0).png\" alt=\"Big picture \($0)\" width=\"2400\" height=\"1600\">"
        }.joined() + "<p>After the hundred pictures.</p>"
        let items = [
            readingItem("Every block", slug: "every-block", hoursAgo: 1, body: everyBlockBody),
            readingItem("Line heights", slug: "line-heights", hoursAgo: 2, body: lineHeightsBody),
            readingItem("Short note", slug: "short-note", hoursAgo: 3, body: "<p>A short note with <b>one bold word</b> and nothing more.</p>"),
            readingItem("Hostile story", slug: "hostile-story", hoursAgo: 4, body: hostileBody),
            readingItem("Cut story", slug: "cut-story", hoursAgo: 5, body: manyParagraphs),
            readingItem("Cut linkless story", slug: nil, hoursAgo: 6, body: longInput),
            readingItem("Picture story", slug: "picture-story", hoursAgo: 7, body: pictureBody),
            readingItem("Hundred pictures", slug: "hundred-pictures", hoursAgo: 8, body: hundredPictures),
            readingItem(
                "Empty body", slug: "empty-body", hoursAgo: 9, description: "Only the feed's summary is left of this one.",
                body: "<script>document.write('nothing to show')</script>"
            ),
        ]
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>Reading Feed</title>\
            <link>https://example.invalid/readingfeed</link>
            \(items.joined(separator: "\n"))
            </channel></rss>
            """
    }()

    private static func channel(title: String, items: [String]) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel><title>\(title)</title><link>https://example.invalid/\(slug(title))</link>
        \(items.joined(separator: "\n"))
        </channel></rss>
        """
    }

    /// A 600 × 400 PNG: a transparent field with an opaque blue disc, so
    /// that a thumbnail of it shows the white it was flattened onto.
    static let articleImagePNG: Data = {
        let width = 600
        let height = 400
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return Data() }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0.16, green: 0.36, blue: 0.62, alpha: 1))
        context.fillEllipse(in: CGRect(x: 150, y: 50, width: 300, height: 300))
        let output = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return Data() }
        return output as Data
    }()

    /// A 60 × 40 PNG, smaller than any column: never shown larger.
    static let smallImagePNG = png(width: 60, height: 40) { context in
        context.setFillColor(CGColor(srgbRed: 0.75, green: 0.24, blue: 0.11, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
    }

    /// A 1 × 1 PNG: a tracking pixel that declares no size.
    static let pixelImagePNG = png(width: 1, height: 1) { context in
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// A 2,400 × 1,600 PNG, near the most pixels a stored body image has:
    /// bands of colour with a disc.
    static let bigImagePNG = png(width: 2_400, height: 1_600) { context in
        for band in 0..<8 {
            let shade = 0.25 + Double(band) * 0.08
            context.setFillColor(CGColor(srgbRed: shade, green: shade * 0.9, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: band * 200, width: 2_400, height: 200))
        }
        context.setFillColor(CGColor(srgbRed: 0.16, green: 0.36, blue: 0.62, alpha: 1))
        context.fillEllipse(in: CGRect(x: 800, y: 400, width: 800, height: 800))
    }

    /// A 1,080 × 6,000 PNG, as a long screenshot of a phone is: 50 numbered
    /// lines of text 36 pixels high on white, each beside a block of
    /// colour. It has more pixels than a body image is stored with, and is
    /// readable only when it is stored wide enough.
    static let tallImagePNG = png(width: 1_080, height: 6_000) { context in
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1_080, height: 6_000))
        let font = CTFontCreateWithName("Helvetica" as CFString, 36, nil)
        for line in 1...50 {
            // The context's origin is at the bottom: line 1 is at the top.
            let baseline = Double(6_000 - line * 120 + 40)
            let shade = Double(line % 5) * 0.15
            context.setFillColor(CGColor(srgbRed: 0.16 + shade, green: 0.36, blue: 0.62 - shade, alpha: 1))
            context.fill(CGRect(x: 40, y: baseline - 10, width: 60, height: 60))
            let text = NSAttributedString(
                string: "Line \(line) of a long picture, to be read when zoomed in",
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
                ]
            )
            context.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1))
            context.textPosition = CGPoint(x: 130, y: baseline)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
    }

    private static func png(width: Int, height: Int, draw: (CGContext) -> Void) -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return Data() }
        draw(context)
        let output = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return Data() }
        return output as Data
    }

    private static func atom(title: String, items: [String]) -> String {
        let formatter = ISO8601DateFormatter()
        let entries = items.enumerated().map { index, item in
            """
            <entry><title>\(item)</title><id>urn:\(slug(title)):\(index)</id>\
            <link href="https://example.invalid/\(slug(title))/\(index)"/>\
            <updated>\(formatter.string(from: fixtureNow.addingTimeInterval(-3600 * Double(index + 1))))</updated></entry>
            """
        }.joined(separator: "\n")
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom"><title>\(title)</title><id>urn:\(slug(title))</id>
            \(entries)
            </feed>
            """
    }

    private static func page(title: String, links: [(type: String, href: String, title: String)]) -> String {
        let declarations = links.map { "<link rel=\"alternate\" type=\"\($0.type)\" href=\"\($0.href)\" title=\"\($0.title)\">" }
            .joined(separator: "\n")
        return """
            <!DOCTYPE html>
            <html><head><title>\(title)</title>
            \(declarations)
            </head><body><p>\(title)</p></body></html>
            """
    }

    /// A fixed moment in the past, so that the documents are the same on
    /// every run and no item lies in the future.
    private static let fixtureNow = Date(timeIntervalSince1970: 1_793_000_000)

    private static func date(hoursAgo hours: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: fixtureNow.addingTimeInterval(-3600 * Double(hours)))
    }

    private static func slug(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
#endif
