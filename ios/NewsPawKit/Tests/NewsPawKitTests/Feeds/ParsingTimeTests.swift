import Foundation
@testable import NewsPawKit
import Testing

// Nested in the serialized group: see `TimedAndHeavySuites`.
extension TimedAndHeavySuites {
/// Criterion 13: parsing time grows in proportion to the document's size.
///
/// For each shape the test finds a size N whose parse takes at least about
/// 0.2 seconds on this machine (best of three, the same measure it then
/// uses), then times sizes N and 4N in turn, three times each, and requires
/// the best 4N time to be less than 8 times the best N time. Growth in
/// proportion to size gives a ratio near 4; growth with the square gives 16.
///
/// Other suites run beside this one and their load comes and goes. Taking
/// the best of three interleaved runs keeps a passing load from landing on
/// one size only, and a ratio over the limit is measured again, up to four
/// attempts in all, before the test fails. A quadratic parser still fails:
/// load only ever adds time, so its ratio of about 16 can fall under 8 only
/// if, within one attempt, every one of the three N runs is slowed at least
/// twofold while one of the interleaved 4N runs is not — in each of up to
/// four attempts in a row.
///
/// Some shapes are refused or cut short by the parser's limits; for them the
/// time is that of reading the document up to the limit, which can stay
/// near zero at any size. N never grows past a document of about 10 MB, the
/// transport's limit, and when N stops there the 0.15 s floor is waived;
/// times under 50 ms count as 50 ms in the ratio, so that a ratio of two
/// tiny times is not noise. A quadratic shape still fails: if its 10 MB
/// document takes under 50 ms, its 40 MB one takes some 16 times that. The
/// suite runs its tests one at a time.
@Suite("Parsing time", .serialized)
struct ParsingTimeTests {
    struct Measurement: CustomStringConvertible {
        var shape: String
        var attempt: Int
        var size: Int
        var smallBytes: Int
        var largeBytes: Int
        var small: Duration
        var large: Duration
        /// Whether every parse gave the result the shape expects.
        var resultsAsExpected: Bool
        /// Whether N stopped at the size cap rather than at 0.2 s.
        var capped: Bool

        var ratio: Double {
            seconds(large) / max(seconds(small), 0.05)
        }

        var description: String {
            String(
                format: "criterion 13 | %@ | attempt %d | N=%d (%d bytes): %.3f s | 4N (%d bytes): %.3f s | ratio %.2f",
                shape, attempt, size, smallBytes, seconds(small), largeBytes, seconds(large), ratio
            ) + (capped ? " | N at the size cap" : "")
        }

        private func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
    }

    /// What the parse of a shape must produce.
    enum Expectation {
        /// A feed, complete or not.
        case feed
        /// Not a feed: the document is refused before any item.
        case notAFeed
    }

    /// The parse whose time is measured: the whole path from bytes to a
    /// `ParsedFeed`, text reduction included.
    private static func parseOnce(_ data: Data, _ expectation: Expectation) -> (time: Duration, asExpected: Bool) {
        let clock = ContinuousClock()
        var feed: ParsedFeed?
        let elapsed = clock.measure {
            feed = FeedParser.parse(data, charset: nil, baseURL: fixtureBase)
        }
        let asExpected = switch expectation {
        case .feed: feed != nil
        case .notAFeed: feed == nil
        }
        return (elapsed, asExpected)
    }

    private static func bestOfThree(_ data: Data, _ expectation: Expectation) -> Duration {
        (0..<3).map { _ in parseOnce(data, expectation).time }.min()!
    }

    private static let attempts = 4

    /// The largest N document: about the transport's 10 MB limit.
    private static let sizeCap = 10 << 20

    private static func measure(
        _ shape: String, startingAt initial: Int, expecting expectation: Expectation = .feed, _ make: (Int) -> Data
    ) -> Measurement {
        var size = initial
        var capped = false
        func grow() {
            if make(size * 2).count > sizeCap || size >= initial << 12 {
                capped = true
            } else {
                size *= 2
            }
        }
        while !capped, bestOfThree(make(size), expectation) < .milliseconds(200) {
            grow()
        }
        var measurement: Measurement?
        for attempt in 1...attempts {
            let small = make(size)
            let large = make(size * 4)
            var smallTimes: [Duration] = []
            var largeTimes: [Duration] = []
            var asExpected = true
            for _ in 0..<3 {
                let smallRun = parseOnce(small, expectation)
                let largeRun = parseOnce(large, expectation)
                smallTimes.append(smallRun.time)
                largeTimes.append(largeRun.time)
                asExpected = asExpected && smallRun.asExpected && largeRun.asExpected
            }
            let current = Measurement(
                shape: shape, attempt: attempt, size: size, smallBytes: small.count, largeBytes: large.count,
                small: smallTimes.min()!, large: largeTimes.min()!, resultsAsExpected: asExpected, capped: capped
            )
            print(current)
            measurement = current
            if current.small < .milliseconds(150), !capped {
                // The load that sized N has gone: N is too small to time.
                grow()
            } else if current.ratio < 8 {
                break
            }
        }
        return measurement!
    }

    private static func check(_ measurement: Measurement) {
        #expect(measurement.resultsAsExpected, "the parse did not give the expected result: \(measurement)")
        #expect(measurement.small >= .milliseconds(150) || measurement.capped, "N too small to measure: \(measurement)")
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

    // MARK: - Shapes the parser's limits refuse or bound (fix round 1)

    private static let itemThenOpen = #"<?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>T</title><item><guid>first</guid><title>first</title></item>"#

    @Test("an internal entity declared once with a long value and referenced many times")
    func longInternalEntity() {
        let measurement = Self.measure("long internal entity, many references", startingAt: 20_000, expecting: .notAFeed) { bytes in
            var document = #"<?xml version="1.0"?><!DOCTYPE rss [<!ENTITY a ""# + String(repeating: "a", count: bytes / 2)
                + #"">]><rss version="2.0"><channel><title>T</title><item><guid>first</guid></item><item><guid>big</guid><description>"#
            document += String(repeating: "&a; ", count: bytes / 8)
            document += "</description></item></channel></rss>"
            return Data(document.utf8)
        }
        Self.check(measurement)
    }

    @Test("a short internal entity, as the limits still allow, referenced many times")
    func shortInternalEntity() {
        let measurement = Self.measure("short internal entity, many references", startingAt: 20_000) { references in
            var document = #"<?xml version="1.0"?><!DOCTYPE rss [<!ENTITY a ""# + String(repeating: "a", count: 256)
                + #"">]><rss version="2.0"><channel><title>T</title><item><guid>first</guid></item><item><guid>big</guid><description>"#
            document += String(repeating: "&a; ", count: references)
            document += "</description></item></channel></rss>"
            return Data(document.utf8)
        }
        Self.check(measurement)
    }

    @Test("one element with very many attributes")
    func manyAttributes() {
        let measurement = Self.measure("one element, many attributes", startingAt: 5_000) { count in
            var document = Self.itemThenOpen + "<x"
            for index in 0..<count {
                document += " a\(index)=\"\""
            }
            document += "/></channel></rss>"
            return Data(document.utf8)
        }
        Self.check(measurement)
    }

    @Test("many elements, each with as many attributes as the limit allows")
    func attributesAtTheLimit() {
        let measurement = Self.measure("many elements with 256 attributes each", startingAt: 50) { count in
            var tag = "<x"
            for index in 0..<256 {
                tag += " a\(index)=\"\""
            }
            tag += "/>"
            let document = Self.itemThenOpen + String(repeating: tag, count: count) + "</channel></rss>"
            return Data(document.utf8)
        }
        Self.check(measurement)
    }

    @Test("many namespace declarations in scope of many elements")
    func manyNamespaceMappings() {
        let measurement = Self.measure("N namespace declarations on the root, 20N elements", startingAt: 1_000, expecting: .notAFeed) { count in
            var document = #"<?xml version="1.0"?><rss version="2.0""#
            for index in 0..<count {
                document += " xmlns:p\(index)=\"u:\(index)\""
            }
            document += "><channel><title>T</title><item><guid>first</guid></item>"
            document += String(repeating: "<x/>", count: count * 20)
            document += "</channel></rss>"
            return Data(document.utf8)
        }
        Self.check(measurement)
    }

    @Test("namespace declarations on many nested levels")
    func namespaceMappingsOnNestedLevels() {
        let measurement = Self.measure("100 declarations on each of N nested levels, 2000N elements inside", startingAt: 8) { levels in
            var declarations = ""
            for index in 0..<100 {
                declarations += " xmlns:q\(index)=\"u:\(index)\""
            }
            let document = Self.itemThenOpen + String(repeating: "<y\(declarations)>", count: levels)
                + String(repeating: "<x/>", count: 2_000 * levels)
            return Data(document.utf8)
        }
        Self.check(measurement)
    }

    @Test("as many namespace mappings in scope as the limit allows, over many elements")
    func namespaceMappingsAtTheLimit() {
        let measurement = Self.measure("256 declarations on the root, N elements", startingAt: 20_000) { count in
            var document = #"<?xml version="1.0"?><rss version="2.0""#
            for index in 0..<255 {
                document += " xmlns:p\(index)=\"u:\(index)\""
            }
            document += "><channel><title>T</title><item><guid>first</guid></item>"
            document += String(repeating: "<p0:x/>", count: count)
            document += "</channel></rss>"
            return Data(document.utf8)
        }
        Self.check(measurement)
    }

    @Test("many distinct element names")
    func manyDistinctNames() {
        let measurement = Self.measure("N distinct element names", startingAt: 10_000) { count in
            var document = Self.itemThenOpen
            for index in 0..<count {
                document += "<e\(index)/>"
            }
            document += "</channel></rss>"
            return Data(document.utf8)
        }
        Self.check(measurement)
    }

    @Test("an attribute-list declaration with very many attributes")
    func attributeListDeclaration() {
        let measurement = Self.measure("ATTLIST with N default attributes", startingAt: 2_000, expecting: .notAFeed) { count in
            var document = #"<?xml version="1.0"?><!DOCTYPE rss [<!ATTLIST x"#
            for index in 0..<count {
                document += " a\(index) CDATA \"v\""
            }
            document += #">]><rss version="2.0"><channel><title>T</title><item><guid>first</guid></item><x/></channel></rss>"#
            return Data(document.utf8)
        }
        Self.check(measurement)
    }
}
}
