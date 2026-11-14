import Foundation
@testable import NewsPawKit
import Testing

/// The tag scanner as both of its users see it (RD05 decision 5; RD11
/// decision 1): its tokens, in order, for small documents. What feed
/// discovery reads through it is in `FeedDiscoveryTests`, `LengthBoundTests`
/// and `ScanBypassTests`; what the body converter reads, in
/// `ArticleBlocksTests`.
@Suite("Tag scanner")
struct TagScannerTests {
    private static let options = TagScanner.Options(
        maximumTagLength: 64, rawTextElements: ["script", "title"], tagsWithAttributes: ["a", "img"],
        attributes: ["href", "src"]
    )

    /// Each token as text: `text:…`, `<name k=v>`, `<name/>`, `raw:…`,
    /// `</name>`.
    private func tokens(_ html: String, options: TagScanner.Options = options) -> [String] {
        let bytes = Array(html.utf8)
        var result: [String] = []
        TagScanner.scan(bytes, options: options) { token in
            let name = String(decoding: token.name.bytes, as: UTF8.self)
            switch token.kind {
            case .text:
                result.append("text:" + String(decoding: bytes[token.range], as: UTF8.self))
            case .rawText:
                result.append("raw:" + String(decoding: bytes[token.range], as: UTF8.self))
            case .startTag:
                let attributes = token.attributes.sorted { $0.key < $1.key }.map { " \($0.key)=\($0.value)" }.joined()
                result.append("<\(name)\(attributes)\(token.isSelfClosing ? "/" : "")>")
            case .endTag:
                result.append("</\(name)>")
            }
            return true
        }
        return result
    }

    @Test("text, start tags, end tags and the text after the last tag, in order")
    func order() {
        #expect(tokens("a<P>b</p >c") == ["text:a", "<p>", "text:b", "</p>", "text:c"])
        #expect(tokens("") == [])
        #expect(tokens("only text") == ["text:only text"])
    }

    @Test("attributes are read on the named tags only, and only the named ones; the first of a repeated name is kept")
    func attributes() {
        #expect(tokens(#"<A HREF="x>y" title='t' href=second><b class=c><img src=/a.png alt="">"#)
            == ["<a href=x>y>", "<b>", "<img src=/a.png>"])
        var all = Self.options
        all.attributes = nil
        #expect(tokens(#"<a href=x Title='t' empty>"#, options: all) == ["<a empty= href=x title=t>"])
    }

    @Test("a quoted attribute value may hold a greater-than sign and markup")
    func quotedValues() {
        #expect(tokens(#"<p title="a > b <script>"x>"#) == ["<p>"])
    }

    @Test("comments, declarations and processing instructions are passed over; an unclosed comment ends the scan")
    func comments() {
        #expect(tokens("a<!-- <p> -->b<!DOCTYPE html>c<?php x ?>d<!-->e") == ["text:a", "text:b", "text:c", "text:d", "text:e"])
        #expect(tokens("a<!-- never closed <p>b") == ["text:a"])
    }

    @Test("a less-than sign that starts no tag is text")
    func strayLessThan() {
        #expect(tokens("1 < 2 <3 </ 4 <") == ["text:1 < 2 <3 </ 4 <"])
    }

    @Test("the content of a raw-text element is one token, to its end tag or the end")
    func rawText() {
        #expect(tokens("<script>if (a < b) { '<p>' }</SCRIPT x>t") == ["<script>", "raw:if (a < b) { '<p>' }", "</script>", "text:t"])
        #expect(tokens("<title>T</titles></title>") == ["<title>", "raw:T</titles>", "</title>"])
        #expect(tokens("<script>never closed") == ["<script>", "raw:never closed"])
    }

    @Test("a raw-text element written as empty has content unless the scan says otherwise")
    func selfClosing() {
        #expect(tokens("<script/>a</script>b") == ["<script/>", "raw:a", "</script>", "text:b"])
        var xml = Self.options
        xml.selfClosingHasNoContent = true
        #expect(tokens("<script/>a</script>b", options: xml) == ["<script/>", "text:a", "</script>", "text:b"])
        #expect(tokens("<br/><img src=a />") == ["<br/>", "<img src=a/>"])
    }

    @Test("a tag with no end within the limit is skipped with what was looked at")
    func tagLimit() {
        let long = "<a href=\"" + String(repeating: "x", count: 100) + "\">after"
        // 64 bytes are skipped; the scan goes on in what follows them.
        #expect(tokens("before" + long) == ["text:before", "text:" + String(repeating: "x", count: 45) + "\">after"])
        var unlimited = Self.options
        unlimited.maximumTagLength = .max
        #expect(tokens("before" + long, options: unlimited) == ["text:before", "<a href=\(String(repeating: "x", count: 100))>", "text:after"])
        #expect(tokens("before<a href=\"never closed", options: unlimited) == ["text:before"])
    }

    @Test("names compare without case and by all their bytes; names over 15 bytes are no known name")
    func names() {
        typealias Name = TagScanner.Name
        #expect(tokens("<SCRIPT>x</ScRiPt>") == ["<script>", "raw:x", "</script>"])
        // A NUL after the name is part of the name: not `script`.
        #expect(tokens("<script\u{0}>x</script>").first != "<script>")
        #expect(tokens("<script\u{0}>x</script>").contains("text:x"))
        let long: Name = "averyveryverylongname"
        #expect(long == Name.other)
        let fifteen: Name = "fifteen-letters"
        #expect(fifteen != Name.other)
        #expect(fifteen.bytes == Array("fifteen-letters".utf8))
        let upper: Name = "BlockQuote"
        #expect(upper == "blockquote")
    }

    @Test("the scan stops when the handler says so")
    func stops() {
        var seen = 0
        TagScanner.scan(Array("<p>a</p><p>b</p>".utf8), options: Self.options) { _ in
            seen += 1
            return seen < 2
        }
        #expect(seen == 2)
    }
}
