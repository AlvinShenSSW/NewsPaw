import Foundation
@testable import NewsPawKit
import Testing

/// Criterion 13: parsing time grows in proportion to the document's size.
///
/// For each shape the test finds a size N whose parse takes at least about
/// 0.2 seconds on this machine, then requires the best of three parses of
/// size 4N to take less than 8 times the best of three of size N. Growth in
/// proportion to size gives a ratio near 4; growth with the square gives 16.
/// The suite runs its tests one at a time so that they do not compete for
/// the processor with each other.
@Suite("Parsing time", .serialized)
struct ParsingTimeTests {
    struct Measurement: CustomStringConvertible {
        var shape: String
        var size: Int
        var smallBytes: Int
        var largeBytes: Int
        var small: Duration
        var large: Duration

        var ratio: Double {
            seconds(large) / seconds(small)
        }

        var description: String {
            String(
                format: "criterion 13 | %@ | N=%d (%d bytes): %.3f s | 4N (%d bytes): %.3f s | ratio %.2f",
                shape, size, smallBytes, seconds(small), largeBytes, seconds(large), ratio
            )
        }

        private func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
    }

    /// The parse whose time is measured: the whole path from bytes to a
    /// `ParsedFeed`, text reduction included.
    private static func parseOnce(_ data: Data) -> Duration {
        let clock = ContinuousClock()
        var feed: ParsedFeed?
        let elapsed = clock.measure {
            feed = FeedParser.parse(data, charset: nil, baseURL: fixtureBase)
        }
        precondition(feed != nil, "the generated document must be a feed")
        return elapsed
    }

    private static func bestOfThree(_ data: Data) -> Duration {
        (0..<3).map { _ in parseOnce(data) }.min()!
    }

    private static func measure(_ shape: String, startingAt initial: Int, _ make: (Int) -> Data) -> Measurement {
        var size = initial
        while parseOnce(make(size)) < .milliseconds(200), size < initial << 12 {
            size *= 2
        }
        let small = make(size)
        let large = make(size * 4)
        let measurement = Measurement(
            shape: shape, size: size, smallBytes: small.count, largeBytes: large.count,
            small: bestOfThree(small), large: bestOfThree(large)
        )
        print(measurement)
        return measurement
    }

    private static func check(_ measurement: Measurement) {
        #expect(measurement.small >= .milliseconds(150), "N too small to measure: \(measurement)")
        #expect(measurement.ratio < 8, "\(measurement)")
    }

    @Test("many small items")
    func manySmallItems() {
        let measurement = Self.measure("many small items", startingAt: 500) { count in
            var document = #"<?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>Many</title>"#
            for index in 0..<count {
                document += "<item><guid>item-\(index)</guid><title>Item &lt;b&gt;\(index)&lt;/b&gt;</title>"
                    + "<link>https://example.invalid/items/\(index)</link><description>Short &amp;amp; plain text \(index)</description>"
                    + "<pubDate>Tue, 10 Nov 2026 08:00:00 GMT</pubDate></item>"
            }
            document += "</channel></rss>"
            return Data(document.utf8)
        }
        Self.check(measurement)
    }

    @Test("one item with a very large escaped text")
    func largeEscapedText() {
        let measurement = Self.measure("one item, large escaped text", startingAt: 2_000) { count in
            let unit = "Tom &amp;amp; Jerry &lt;p&gt;para &amp;hellip;&lt;/p&gt; &amp;#x3042; text "
            let text = String(repeating: unit, count: count)
            let document = #"<?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>Big</title>"#
                + "<item><guid>big</guid><title>\(text)</title><description>\(text)</description></item></channel></rss>"
            return Data(document.utf8)
        }
        Self.check(measurement)
    }

    @Test("one element with very many children")
    func manyChildren() {
        let measurement = Self.measure("one element, many children", startingAt: 2_000) { count in
            var document = #"<?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>Wide</title>"#
            document += String(repeating: "<extension/>", count: count)
            document += "<item><guid>wide</guid><title>Wide item</title>"
            document += String(repeating: "<category>c</category>", count: count)
            document += "</item></channel></rss>"
            return Data(document.utf8)
        }
        Self.check(measurement)
    }

    @Test("text reduction: a description of nested table markup")
    func nestedTableMarkup() {
        let measurement = Self.measure("text reduction, nested tables", startingAt: 2_000) { count in
            let markup = String(repeating: "<table><tr><td>cell &amp; ", count: count)
            let document = #"<?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>Tables</title>"#
                + "<item><guid>tables</guid><title><![CDATA[\(markup)]]></title><description><![CDATA[\(markup)]]></description></item>"
                + "</channel></rss>"
            return Data(document.utf8)
        }
        Self.check(measurement)
    }

    @Test("Atom XHTML content rebuilt as markup")
    func atomXHTMLContent() {
        let measurement = Self.measure("Atom XHTML content", startingAt: 1_000) { count in
            let paragraphs = String(repeating: "<p class=\"c\">x &lt; y &amp; <b>z</b><br/></p>", count: count)
            let document = #"<feed xmlns="http://www.w3.org/2005/Atom"><title>X</title><entry><id>x</id>"#
                + #"<content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml">\#(paragraphs)</div></content></entry></feed>"#
            return Data(document.utf8)
        }
        Self.check(measurement)
    }
}
