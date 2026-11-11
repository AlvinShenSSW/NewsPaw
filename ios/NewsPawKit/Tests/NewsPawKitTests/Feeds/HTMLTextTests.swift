import Foundation
@testable import NewsPawKit
import Testing

@Suite("HTML text reduction")
struct HTMLTextTests {
    @Test(
        "markup is removed, script and style content dropped, references decoded, white space collapsed",
        arguments: [
            ("<p>Hello <b>world</b></p>", "Hello world"),
            ("a<b>c</b>d", "acd"),
            ("<p>one</p><p>two</p>", "one two"),
            ("line<br>break<br/>again", "line break again"),
            ("<td>a</td><td>b</td>", "a b"),
            ("<script>var a = '<p>x</p>';</script>kept", "kept"),
            ("<SCRIPT type=\"x\">if (a < b) {}</SCRIPT >kept", "kept"),
            ("<style>p { color: red }</style>kept", "kept"),
            ("<script>never closed", ""),
            ("<!-- a comment <p>x</p> -->kept", "kept"),
            ("<!-- unclosed comment", ""),
            ("<!DOCTYPE html>kept", "kept"),
            ("<?php echo 1 ?>kept", "kept"),
            ("<a title=\"a > b\" href='x>y'>link</a>", "link"),
            ("a < b and c > d", "a < b and c > d"),
            ("1 <2", "1 <2"),
            ("x <", "x <"),
            ("<b", ""),
            ("&amp; &lt; &gt; &quot; &#39; &apos;", "& < > \" ' '"),
            ("&hellip;&mdash;&eacute;&nbsp;x", "…—é x"),
            ("&#x1F600; &#128512; &#X41;", "😀 😀 A"),
            ("&#0; &#xD800; &#x110000; &#99999999999;", "\u{FFFD} \u{FFFD} \u{FFFD} \u{FFFD}"),
            ("&#150; &#x80;", "– €"),
            ("&amp &copy 2026 &ampx", "& © 2026 &ampx"),
            ("&notanentity; & alone &#; &#x;", "&notanentity; & alone &#; &#x;"),
            ("  spaced\n\tout \u{00A0} text \u{3000} ", "spaced out text"),
            ("", ""),
        ]
    )
    func reduce(_ html: String, _ text: String) {
        #expect(HTMLText.reduce(html) == text, "\(html)")
    }

    @Test("escaping makes text read as itself when treated as HTML")
    func escape() {
        let text = #"5 < 6 & "quoted" 'single' > 4"#
        #expect(HTMLText.escape(text) == "5 &lt; 6 &amp; &quot;quoted&quot; &#39;single&#39; &gt; 4")
        #expect(HTMLText.reduce(HTMLText.escape(text)) == text)
        #expect(HTMLText.reduce(HTMLText.escape("<script>alert(1)</script>")) == "<script>alert(1)</script>")
    }

    @Test("excerpts are cut at 500 characters")
    func excerptLength() throws {
        let long = String(repeating: "日本語", count: 400)
        let excerpt = try #require(HTMLText.excerpt(fromText: long))
        #expect(excerpt.count == 500)
        #expect(HTMLText.excerpt(fromHTML: "<p> </p>") == nil)
        #expect(HTMLText.excerpt(fromText: "  short  ") == "short")
    }
}
