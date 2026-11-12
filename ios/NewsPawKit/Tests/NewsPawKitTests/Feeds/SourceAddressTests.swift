import Foundation
@testable import NewsPawKit
import Testing

/// RD05 criterion 1: the normal form of decision 1, rule by rule.
@Suite("Source address")
struct SourceAddressTests {
    /// Input, then its normal form.
    static let normalised: [(String, String)] = [
        // Surrounding white space is removed.
        ("  https://example.com/feed\n", "https://example.com/feed"),
        // `https://` is put in front of a text without a scheme.
        ("example.com/feed", "https://example.com/feed"),
        ("example.com:8080/feed", "https://example.com:8080/feed"),
        // A scheme counts only at the very start: a `://` in a query does not.
        ("example.com/go?to=http://other.example", "https://example.com/go?to=http://other.example"),
        // Scheme and host in lower case.
        ("HTTPS://Example.COM", "https://example.com/"),
        ("https://EXAMPLE.com/Feed/RSS.xml", "https://example.com/Feed/RSS.xml"),
        // A default port is removed; another port stays.
        ("https://example.com:443/feed", "https://example.com/feed"),
        ("http://example.com:80/feed", "http://example.com/feed"),
        ("http://example.com:443/feed", "http://example.com:443/feed"),
        ("http://[2001:DB8::1]:80/feed", "http://[2001:db8::1]/feed"),
        // An empty path is written `/`.
        ("https://example.com", "https://example.com/"),
        ("https://example.com?x=1", "https://example.com/?x=1"),
        // The fragment is removed.
        ("https://example.com#frag", "https://example.com/"),
        ("https://example.com/feed#", "https://example.com/feed"),
        // Not rewritten: path case and trailing slash, query and its order,
        // www., tracking parameters, percent-escapes, dot segments, http.
        ("https://example.com/feed/", "https://example.com/feed/"),
        ("https://example.com/feed?b=2&a=1", "https://example.com/feed?b=2&a=1"),
        ("https://example.com/feed?", "https://example.com/feed?"),
        ("https://www.example.com/feed", "https://www.example.com/feed"),
        ("https://example.com/feed?utm_source=x", "https://example.com/feed?utm_source=x"),
        ("https://example.com/a%2fb", "https://example.com/a%2fb"),
        ("https://example.com/%7Euser", "https://example.com/%7Euser"),
        ("https://example.com/?q=%e3%81%82", "https://example.com/?q=%e3%81%82"),
        ("https://example.com/a/../feed", "https://example.com/a/../feed"),
        ("http://example.com/feed", "http://example.com/feed"),
        // Pinned to what the debate measured: a Japanese path and query are
        // percent-encoded, an internationalised host is in its ASCII form.
        ("https://例え.jp/フィード?q=日本", "https://xn--r8jz45g.jp/%E3%83%95%E3%82%A3%E3%83%BC%E3%83%89?q=%E6%97%A5%E6%9C%AC"),
        ("https://bücher.example/", "https://xn--bcher-kva.example/"),
        ("https://example.com/a b", "https://example.com/a%20b"),
        ("http://localhost:8080/feed", "http://localhost:8080/feed"),
    ]

    @Test("each rule and each thing deliberately not rewritten", arguments: normalised)
    func normalForm(input: String, expected: String) throws {
        let address = try SourceAddress.parse(input).get()
        #expect(address.normalForm == expected)
        // The normal form of a normal form is itself.
        #expect(try SourceAddress.parse(address.normalForm).get().normalForm == address.normalForm)
    }

    @Test("whether https:// was put in front is reported")
    func addedScheme() throws {
        #expect(try SourceAddress.parse("example.com/feed").get().addedScheme)
        #expect(try !SourceAddress.parse("https://example.com/feed").get().addedScheme)
        #expect(try !SourceAddress.parse("http://example.com/feed").get().addedScheme)
    }

    static let refused: [(String, SourceAddressProblem)] = [
        ("", .empty),
        ("   \n", .empty),
        ("feed://example.com/rss", .unsupportedScheme),
        ("webcal://example.com/cal", .unsupportedScheme),
        ("ftp://example.com/feed", .unsupportedScheme),
        ("https://user:pw@example.com/feed", .hasCredentials),
        ("https://user@example.com/feed", .hasCredentials),
        ("https://", .malformed),
        ("https:///feed", .malformed),
        ("https://example.com\\feed", .malformed),
        ("https://example.com/" + String(repeating: "a", count: 2_048), .tooLong),
    ]

    @Test("the five refusals", arguments: refused)
    func refusal(input: String, problem: SourceAddressProblem) {
        #expect(throws: problem) { try SourceAddress.parse(input).get() }
    }

    @Test("feed: and javascript: are refused")
    func otherSchemes() {
        for input in ["feed:https://example.com/rss", "javascript:alert(1)", "mailto:someone@example.com"] {
            #expect(throws: SourceAddressProblem.self, "\(input)") { try SourceAddress.parse(input).get() }
        }
    }

    @Test("an address of exactly 2,048 characters is accepted")
    func longestAccepted() throws {
        let prefix = "https://example.com/"
        let address = prefix + String(repeating: "a", count: SourceAddress.maximumLength - prefix.count)
        #expect(try SourceAddress.parse(address).get().normalForm == address)
    }

    @Test("the https upgrade: taken for the https twin only")
    func upgrade() {
        let requested = "http://example.com/feed?x=1"
        #expect(SourceAddress.upgrade(requested: requested, finalURL: URL(string: "https://example.com/feed?x=1")!)
            == "https://example.com/feed?x=1")
        #expect(SourceAddress.upgrade(requested: requested, finalURL: URL(string: "https://EXAMPLE.com:443/feed?x=1#top")!)
            == "https://example.com/feed?x=1")
        // Another host, path, port or query: not taken.
        for final in [
            "https://www.example.com/feed?x=1", "https://example.com/feed/?x=1", "https://example.com:8443/feed?x=1",
            "https://example.com/feed?x=2", "http://example.com/feed?x=1",
        ] {
            #expect(SourceAddress.upgrade(requested: requested, finalURL: URL(string: final)!) == nil, "\(final)")
        }
        // An https address is never changed.
        #expect(SourceAddress.upgrade(requested: "https://example.com/", finalURL: URL(string: "https://example.com/")!) == nil)
    }
}
