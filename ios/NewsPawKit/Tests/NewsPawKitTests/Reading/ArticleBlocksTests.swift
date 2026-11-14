import Foundation
@testable import NewsPawKit
import Testing

// Short forms for the expected blocks.

private typealias Block = ArticleBlock

private let base = URL(string: "https://news.example/2026/story.html")!

private func url(_ text: String) -> URL {
    URL(string: text)!
}

private func run(_ text: String, bold: Bool = false, italic: Bool = false, code: Bool = false, link: String? = nil) -> InlineRun {
    InlineRun(text, isBold: bold, isItalic: italic, isCode: code, link: link.map(url))
}

private func p(
    _ runs: [InlineRun], quote: Int = 0, list: Int = 0, marker: Block.ListMarker? = nil, caption: Bool = false
) -> Block {
    Block(.paragraph(runs), quoteDepth: quote, listDepth: list, marker: marker, isCaption: caption)
}

private func p(
    _ text: String, quote: Int = 0, list: Int = 0, marker: Block.ListMarker? = nil, caption: Bool = false
) -> Block {
    p([run(text)], quote: quote, list: list, marker: marker, caption: caption)
}

private func h(_ level: Int, _ text: String, quote: Int = 0, list: Int = 0) -> Block {
    Block(.heading(level: level, [run(text)]), quoteDepth: quote, listDepth: list)
}

private func image(
    _ address: String, alt: String? = nil, size: (Int, Int)? = nil, quote: Int = 0, list: Int = 0,
    marker: Block.ListMarker? = nil
) -> Block {
    Block(
        .image(ArticleImage(
            url: url(address), alternativeText: alt,
            declaredSize: size.map { ArticleImage.DeclaredSize(width: $0.0, height: $0.1) }
        )),
        quoteDepth: quote, listDepth: list, marker: marker
    )
}

private func code(_ text: String, quote: Int = 0, list: Int = 0, marker: Block.ListMarker? = nil) -> Block {
    Block(.code(text), quoteDepth: quote, listDepth: list, marker: marker)
}

private func blocks(_ html: String, base: URL? = base) -> [Block] {
    ArticleBlocks.make(html: html, baseURL: base).blocks
}

/// RD11 criterion 1: every block kind and attribute from its HTML, as exact
/// blocks.
@Suite("Article blocks")
struct ArticleBlocksTests {
    struct Case: CustomTestStringConvertible, Sendable {
        var name: String
        var html: String
        var expected: [ArticleBlock]

        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(
            name: "inline bold, italic, code and a link",
            html: #"<p>Plain <b>bold</b> and <i>italic</i>, <code>code</code>, <a href="https://example.com/x">a link</a>, <strong><em>both</em></strong>.</p>"#,
            expected: [p([
                run("Plain "), run("bold", bold: true), run(" and "), run("italic", italic: true), run(", "),
                run("code", code: true), run(", "), run("a link", link: "https://example.com/x"), run(", "),
                run("both", bold: true, italic: true), run("."),
            ])]
        ),
        Case(
            name: "the space between two styles belongs to the style it stands in",
            html: "<p><a href='https://example.com/a'>one </a>two <b> three</b></p>",
            expected: [p([run("one ", link: "https://example.com/a"), run("two "), run("three", bold: true)])]
        ),
        Case(
            name: "headings keep their HTML level",
            html: "<h1>One</h1><h2>Two</h2><h3>Three</h3><h4>Four</h4><h5>Five</h5><h6>Six</h6><p>Text</p>",
            expected: [h(1, "One"), h(2, "Two"), h(3, "Three"), h(4, "Four"), h(5, "Five"), h(6, "Six"), p("Text")]
        ),
        Case(
            name: "a heading written around a div; a heading left open ends at the next paragraph",
            html: "<h2><div>Inside</div></h2><h3>Open<p>Body</p>",
            expected: [h(2, "Inside"), h(3, "Open"), p("Body")]
        ),
        Case(
            name: "lists, nested, numbered from start",
            html: """
                <ul><li>One</li><li>Two<ul><li>Inner</li><li>Second inner</li></ul></li><li>Three</li></ul>
                <ol start="5"><li>Five</li><li>Six</li></ol><ol><li>First</li></ol>
                """,
            expected: [
                p("One", list: 1, marker: .bullet), p("Two", list: 1, marker: .bullet),
                p("Inner", list: 2, marker: .bullet), p("Second inner", list: 2, marker: .bullet),
                p("Three", list: 1, marker: .bullet),
                p("Five", list: 1, marker: .number(5)), p("Six", list: 1, marker: .number(6)),
                p("First", list: 1, marker: .number(1)),
            ]
        ),
        Case(
            name: "a list of lists only: the inner items carry the markers",
            html: "<ul><li><ul><li>Inner</li></ul>tail</li></ul>",
            expected: [p("Inner", list: 2, marker: .bullet), p("tail", list: 1)]
        ),
        Case(
            name: "ol start is kept between 1 and 9,999",
            html: "<ol start='0'><li>a</li></ol><ol start='-4'><li>b</li></ol><ol start='123456'><li>c</li><li>d</li></ol><ol start='x'><li>e</li></ol>",
            expected: [
                p("a", list: 1, marker: .number(1)), p("b", list: 1, marker: .number(1)),
                p("c", list: 1, marker: .number(9_999)), p("d", list: 1, marker: .number(10_000)),
                p("e", list: 1, marker: .number(1)),
            ]
        ),
        Case(
            name: "quotes, nested",
            html: "<blockquote><p>Outer</p><blockquote><p>Inner</p></blockquote><p>Outer again</p></blockquote><p>After</p>",
            expected: [p("Outer", quote: 1), p("Inner", quote: 2), p("Outer again", quote: 1), p("After")]
        ),
        Case(
            name: "a second paragraph, a pre and an image inside a list item",
            html: #"<ul><li><p>First</p><p>Second</p><pre>let x = 1</pre><img src="/a.png" alt="A"><h3>Head</h3></li><li>Next</li></ul>"#,
            expected: [
                p("First", list: 1, marker: .bullet), p("Second", list: 1), code("let x = 1", list: 1),
                image("https://news.example/a.png", alt: "A", list: 1), h(3, "Head", list: 1),
                p("Next", list: 1, marker: .bullet),
            ]
        ),
        Case(
            name: "a second paragraph, a pre and an image inside a quote",
            html: #"<blockquote><p>First</p><p>Second</p><pre>code</pre><img src="b.png"><h2>Head</h2></blockquote>"#,
            expected: [
                p("First", quote: 1), p("Second", quote: 1), code("code", quote: 1),
                image("https://news.example/2026/b.png", quote: 1), h(2, "Head", quote: 1),
            ]
        ),
        Case(
            name: "li p is one item; an image or a pre can be an item's first block",
            html: #"<ol><li><p>Item</p></li><li><img src="https://img.example/c.jpg"></li><li><pre>x</pre></li></ol>"#,
            expected: [
                p("Item", list: 1, marker: .number(1)), image("https://img.example/c.jpg", list: 1, marker: .number(2)),
                code("x", list: 1, marker: .number(3)),
            ]
        ),
        Case(
            name: "a list inside a quote, and a quote inside a list item",
            html: "<blockquote><ul><li>In both</li></ul></blockquote><ul><li><blockquote>Quoted item</blockquote>rest</li></ul>",
            expected: [
                p("In both", quote: 1, list: 1, marker: .bullet), p("Quoted item", quote: 1, list: 1, marker: .bullet),
                p("rest", list: 1),
            ]
        ),
        Case(
            name: "depth is shown up to 3",
            html: "<ul><li><ul><li><ul><li><ul><li><ul><li>Deep</li></ul></li></ul></li></ul></li></ul></li></ul>"
                + "<blockquote><blockquote><blockquote><blockquote>Deep quote</blockquote></blockquote></blockquote></blockquote>",
            expected: [p("Deep", list: 3, marker: .bullet), p("Deep quote", quote: 3)]
        ),
        Case(
            name: "a figure's caption",
            html: #"<figure><img src="https://img.example/f.png" alt="Fig" width="640" height="480"><figcaption>The <i>caption</i></figcaption></figure><p>After</p>"#,
            expected: [
                image("https://img.example/f.png", alt: "Fig", size: (640, 480)),
                p([run("The "), run("caption", italic: true)], caption: true), p("After"),
            ]
        ),
        Case(
            name: "an image inside a paragraph splits it; the styles around it go on",
            html: #"<p>Before <b>bold <img src="https://img.example/i.png"> still bold</b> after</p>"#,
            expected: [
                p([run("Before "), run("bold", bold: true)]), image("https://img.example/i.png"),
                p([run("still bold", bold: true), run(" after")]),
            ]
        ),
        Case(
            name: "an image inside a link keeps the image and loses the link",
            html: #"<p><a href="https://example.com/big"><img src="https://img.example/l.png" alt="Linked"></a></p><a href="https://example.com/t"><img src="https://img.example/m.png"> text</a>"#,
            expected: [
                image("https://img.example/l.png", alt: "Linked"), image("https://img.example/m.png"),
                p([run("text", link: "https://example.com/t")]),
            ]
        ),
        Case(
            name: "one br is a line break, two or more in a row a new paragraph",
            html: "First line<br>second line<br><br>Next paragraph<br/> <br/>\n<br>Third<br>",
            expected: [p("First line\nsecond line"), p("Next paragraph"), p("Third")]
        ),
        Case(
            name: "a double br keeps the style it stands in",
            html: "<p><b>one<br><br>two</b></p>",
            expected: [p([run("one", bold: true)]), p([run("two", bold: true)])]
        ),
        Case(
            name: "empty blocks are dropped",
            html: "<p>&nbsp;</p><div></div><p> \n\t</p><p><b></b></p><h2>&#8203;</h2><ul><li></li><li> </li></ul><blockquote></blockquote><pre>\n\n</pre><p>Text</p><p>\u{3000}</p>",
            expected: [p("Text")]
        ),
        Case(
            name: "a plain table is one line a row, its cells joined",
            html: "<table><caption>Scores</caption><thead><tr><th>Name</th><th>Score</th></tr></thead><tbody><tr><td>Ada</td><td><b>12</b></td><td></td></tr><tr><td></td><td>7</td></tr></tbody></table><p>After</p>",
            expected: [
                p("Scores"), p("Name · Score"), p([run("Ada · "), run("12", bold: true)]), p("7"), p("After"),
            ]
        ),
        Case(
            name: "a layout table is read as its content",
            html: #"<table><tr><td><p>Left one</p><p>Left two</p></td><td>Right</td></tr><tr><td>Below</td><td><img src="https://img.example/t.png"></td></tr></table>"#,
            expected: [p("Left one"), p("Left two"), p("Right"), p("Below"), image("https://img.example/t.png")]
        ),
        Case(
            name: "a pre inside a table cell is a code block",
            html: "<table><tr><td>Label</td><td><pre>a  b\n  c</pre></td></tr></table>",
            expected: [p("Label"), code("a  b\n  c")]
        ),
        Case(
            name: "a table inside a table",
            html: "<table><tr><td>Outer</td><td><table><tr><td>a</td><td>b</td></tr></table></td><td>tail</td></tr></table>",
            expected: [p("Outer"), p("a · b"), p("tail")]
        ),
        Case(
            name: "stray text and text between blocks",
            html: "Loose start<p>Para</p>between <i>blocks</i><div>Div</div>end",
            expected: [p("Loose start"), p("Para"), p([run("between "), run("blocks", italic: true)]), p("Div"), p("end")]
        ),
        Case(
            name: "entities",
            html: "<p>Fish &amp; chips &lt;b&gt; &#8212; &hellip; &quot;q&quot; caf&eacute; &#x4E2D;&#25991; a&nbsp;b &unknown; &amp</p>",
            expected: [p("Fish & chips <b> — … \"q\" café 中文 a b &unknown; &")]
        ),
        Case(
            name: "white space is collapsed outside pre and kept inside it",
            html: "<p>  A \n\n  lot\tof   space  </p><pre>\nline one\n    indented &lt;b&gt;\n\tlast  \n</pre>",
            expected: [p("A lot of space"), code("line one\n    indented <b>\n\tlast")]
        ),
        Case(
            name: "tags inside pre are dropped and their text kept",
            html: "<pre><code class=\"swift\"><span>let</span> a = <b>1</b><br>print(a)</code></pre>",
            expected: [code("let a = 1\nprint(a)")]
        ),
        Case(
            name: "a rule",
            html: "<p>Above</p><hr><p>Below</p><blockquote><hr/></blockquote>",
            expected: [p("Above"), Block(.rule), p("Below"), Block(.rule, quoteDepth: 1)]
        ),
        Case(
            name: "definition lists, details and sections are paragraphs",
            html: "<dl><dt>Term</dt><dd>Meaning</dd></dl><details><summary>More</summary>Hidden</details><section><header>Head</header><footer>Foot</footer></section>",
            expected: [p("Term"), p("Meaning"), p("More"), p("Hidden"), p("Head"), p("Foot")]
        ),
        Case(
            name: "any other tag contributes only its text",
            html: "<p>a<span>b</span><u>c</u><font color=red>d</font><custom-tag>e</custom-tag><nav>f</nav></p>",
            expected: [p("abcdef")]
        ),
        Case(
            name: "inline styles end with their block",
            html: "<b><p>one</p><p>two</p></b><p><i>three<p>four</p>",
            expected: [p("one"), p("two"), p([run("three", italic: true)]), p("four")]
        ),
        Case(
            name: "comments, a doctype and a processing instruction are passed over",
            html: "<!DOCTYPE html><?xml version='1.0'?><p>a<!-- <p>no</p> -->b</p><!-->c",
            expected: [p("ab"), p("c")]
        ),
        Case(
            name: "a less-than sign that starts no tag is text",
            html: "<p>1 < 2 and 3 <4</p>",
            expected: [p("1 < 2 and 3 <4")]
        ),
        Case(
            name: "end tags without a start close nothing",
            html: "</ul></blockquote></p><ul><li>a</li></ul></ul></blockquote><p>b</p>",
            expected: [p("a", list: 1, marker: .bullet), p("b")]
        ),
        Case(
            name: "a list left open inside a quote ends with the quote",
            html: "<blockquote><ul><li>a</blockquote><p>b</p>",
            expected: [p("a", quote: 1, list: 1, marker: .bullet), p("b")]
        ),
    ]

    @Test("blocks", arguments: cases)
    func exactBlocks(_ example: Case) {
        let result = ArticleBlocks.make(html: example.html, baseURL: base)
        #expect(result.blocks == example.expected, "\(example.name)")
        #expect(!result.isCut)
    }

    @Test("the converter's output is named by a version")
    func version() {
        #expect(ArticleBlocks.version == 1)
    }

    @Test("the same HTML gives the same blocks")
    func deterministic() {
        for example in Self.cases {
            #expect(ArticleBlocks.make(html: example.html, baseURL: base) == ArticleBlocks.make(html: example.html, baseURL: base))
        }
    }

    // MARK: - Contexts beyond the limit

    @Test("the context stack is capped at 32: deeper lists are counted and add no depth, and their end tags close none")
    func contextCap() {
        // 40 lists deep: the 8 beyond the cap are counted. Their 8 end tags
        // and the 32 kept ones close exactly what was opened, so the text
        // after them stands in no list.
        let html = String(repeating: "<ul><li>", count: 40) + "deep" + String(repeating: "</li></ul>", count: 40) + "<p>after</p>"
        #expect(blocks(html) == [p("deep", list: 3, marker: .bullet), p("after")])

        // The end tags of the 8 counted lists alone close no kept list.
        let partly = String(repeating: "<ul><li>", count: 40) + "deep" + String(repeating: "</li></ul>", count: 8) + "<p>still inside</p>"
        #expect(blocks(partly) == [p("deep", list: 3, marker: .bullet), p("still inside", list: 3)])

        // Quotes and lists share the stack.
        let mixed = String(repeating: "<blockquote>", count: 20) + String(repeating: "<ol><li>", count: 20) + "x"
        #expect(blocks(mixed) == [p("x", quote: 3, list: 3, marker: .number(1))])
    }

    // MARK: - Criterion 2: nothing of the article can run or reach out

    static let hostile = """
        <head><title>Stolen title</title><style>p { color: red }</style></head>
        <script>alert("script text")</script>
        <p onclick="alert('attr')" style="background:url(https://track.example/bg)">Safe <b onmouseover="evil()">text</b>.</p>
        <p><a href="javascript:alert('link')">script link</a> <a href="data:text/html,<script>x</script>">data link</a> \
        <a href=" JaVaScRiPt:alert(1)">mixed case</a> <a href="vbscript:x">vb</a> <a href="mailto:a@example.com">mail</a> \
        <a href="/relative/page?a=1&amp;b=2">relative</a> <a href="//cdn.example/x">scheme-relative</a> \
        <a href="https://example.com/ok" onclick="evil()">absolute</a> <a>no address</a></p>
        <iframe src="https://frame.example/embed">frame text</iframe>
        <form action="https://post.example/"><input name="q" value="input text"><button>Button text</button>\
        <select><option>Option text</option></select><textarea>Area text</textarea></form>
        <object data="x.swf">Object text</object><embed src="x.swf"><video src="v.mp4">Video text</video>\
        <audio>Audio text</audio><canvas>Canvas text</canvas><svg><text>Svg text</text><script>svgScript()</script></svg>\
        <math><mi>Math text</mi></math><template><p>Template text</p></template><noscript><img src="https://img.example/noscript.png">Noscript text</noscript>
        <p>Lazy:</p><img src="data:image/gif;base64,R0lGODlhAQABAAAAACw=" data-src="/lazy/real.jpg" alt="Lazy image">
        <img srcset="/set/small.jpg 320w, /set/large.jpg 1280w" alt="From srcset">
        <img src="https://track.example/pixel.gif" width="1" height="1"><img src="https://track.example/zero.gif" height="0">
        <img src="javascript:alert(1)" alt="Script image"><img alt="No address"><img src="ftp://files.example/a.png">
        <style>.x { display: none }</style><p>End.</p>
        """

    @Test("a hostile document yields no script text, no such link, no frame, no control, the lazy image's real address and no pixel")
    func hostileDocument() throws {
        let result = blocks(Self.hostile)
        #expect(result == [
            p([run("Safe "), run("text", bold: true), run(".")]),
            p([
                run("script link data link mixed case vb mail "),
                run("relative", link: "https://news.example/relative/page?a=1&b=2"), run(" "),
                run("scheme-relative", link: "https://cdn.example/x"), run(" "),
                run("absolute", link: "https://example.com/ok"), run(" no address"),
            ]),
            p("Lazy:"),
            image("https://news.example/lazy/real.jpg", alt: "Lazy image"),
            image("https://news.example/set/small.jpg", alt: "From srcset"),
            p("End."),
        ])
        // Nothing of what was dropped is anywhere in the output: its
        // texts, alternative texts and addresses.
        let everything = result.flatMap { block -> [String] in
            switch block.kind {
            case .paragraph(let runs), .heading(_, let runs):
                runs.flatMap { [$0.text, $0.link?.absoluteString ?? ""] }
            case .image(let image):
                [image.url.absoluteString, image.alternativeText ?? ""]
            case .code(let text):
                [text]
            case .rule:
                []
            }
        }.joined(separator: "\n")
        for gone in [
            "alert", "evil", "script text", "Stolen", "color", "frame", "input text", "Button", "Option", "Area text",
            "Object", "Video", "Audio", "Canvas", "Svg", "svgScript", "Math", "Template", "Noscript", "noscript.png",
            "pixel", "zero.gif", "track.example", "javascript", "vbscript", "mailto", "data:", "ftp", "onclick", "display",
        ] {
            #expect(!everything.contains(gone), "\(gone) is in the output")
        }
    }

    @Test("every link and image address that leaves the converter is http or https")
    func onlyWebAddresses() {
        let all = Self.cases.map(\.html).joined() + Self.hostile
        for block in blocks(all) {
            switch block.kind {
            case .image(let image):
                #expect(["http", "https"].contains(image.url.scheme))
            case .paragraph(let runs), .heading(_, let runs):
                for link in runs.compactMap(\.link) {
                    #expect(["http", "https"].contains(link.scheme))
                }
            case .code, .rule:
                break
            }
        }
    }

    @Test("without an article address relative links and images are dropped and absolute ones kept")
    func noBase() {
        let html = #"<p><a href="/relative">relative</a> <a href="page.html">sibling</a> <a href="https://example.com/abs">absolute</a></p><img src="/a.png"><img src="b.png"><img src="//cdn.example/c.png"><img src="https://img.example/d.png">"#
        #expect(blocks(html, base: nil) == [
            p([run("relative sibling "), run("absolute", link: "https://example.com/abs")]),
            image("https://img.example/d.png"),
        ])
        // A base that is not a web address resolves nothing to one.
        #expect(blocks(html, base: URL(string: "file:///private/var/article.html")) == [
            p([run("relative sibling "), run("absolute", link: "https://example.com/abs")]),
            image("https://img.example/d.png"),
        ])
    }

    @Test("an image's size is read only as two whole pixel counts; alternative text is collapsed and bounded")
    func imageAttributes() {
        #expect(blocks(#"<img src="https://i.example/a.png" width="100%" height="300">"#) == [image("https://i.example/a.png")])
        #expect(blocks(#"<img src="https://i.example/a.png" width="640px" height=" 480 ">"#) == [image("https://i.example/a.png", size: (640, 480))])
        #expect(blocks(#"<img src="https://i.example/a.png" width="640">"#) == [image("https://i.example/a.png")])
        #expect(blocks(#"<img src="https://i.example/a.png" width="1">"#).isEmpty)
        #expect(blocks(#"<img src="https://i.example/a.png" width="2" height="2">"#) == [image("https://i.example/a.png", size: (2, 2))])
        #expect(blocks("<img src=\"https://i.example/a.png\" alt=\"  A &amp;  B\n\">") == [image("https://i.example/a.png", alt: "A & B")])
        #expect(blocks(#"<img src="https://i.example/a.png" alt="">"#) == [image("https://i.example/a.png")])
        let long = String(repeating: "word ", count: 400)
        guard case .image(let found)? = blocks(#"<img src="https://i.example/a.png" alt="\#(long)">"#).first?.kind else {
            Issue.record("no image")
            return
        }
        #expect(found.alternativeText?.count == 500)
    }

    @Test("a tag written as empty by an XML serialiser drops nothing after it")
    func selfClosedDroppedElements() {
        let html = #"<p>a</p><iframe src="https://frame.example/x"/><video src="v.mp4"/><script src="x.js"/><svg/><object/><p>b</p>"#
        #expect(blocks(html) == [p("a"), p("b")])
    }

    @Test("a dropped element nested in itself ends at its own end tag")
    func nestedDroppedElements() {
        #expect(blocks("<p>a</p><svg><g><svg><text>inner</text></svg><text>outer</text></g></svg><p>b</p>") == [p("a"), p("b")])
    }

    // MARK: - Criterion 4: full text or excerpt

    private func paragraph(of character: String, count: Int) -> [Block] {
        [p(String(repeating: character, count: count))]
    }

    @Test("full text at 1,000 characters of Latin text, at its boundary")
    func fullTextLatin() {
        #expect(!ArticleBlocks.isFullText(paragraph(of: "a", count: 999)))
        #expect(ArticleBlocks.isFullText(paragraph(of: "a", count: 1_000)))
        #expect(!ArticleBlocks.isFullText([]))
        // White space is collapsed, and a block's end counts as one space.
        let words = Array(repeating: p("word"), count: 200)
        #expect(ArticleBlocks.isFullText(words) == false, "200 words of 4 letters and 199 spaces are 999 characters")
        #expect(ArticleBlocks.isFullText(words + [p("x")]))
        #expect(!ArticleBlocks.isFullText([p(String(repeating: "a", count: 500) + String(repeating: " ", count: 600) + String(repeating: "b", count: 498))]))
    }

    @Test("full text at 400 characters when more than half of the letters are Chinese, Japanese or Korean, at its boundary")
    func fullTextCJK() {
        for character in ["中", "あ", "ア", "한"] {
            #expect(!ArticleBlocks.isFullText(paragraph(of: character, count: 399)), "\(character)")
            #expect(ArticleBlocks.isFullText(paragraph(of: character, count: 400)), "\(character)")
        }
        // More than half: 200 of 400 letters is not, 201 of 400 is.
        let half = String(repeating: "中", count: 200) + String(repeating: "a", count: 200)
        #expect(!ArticleBlocks.isFullText([p(half)]))
        let more = String(repeating: "中", count: 201) + String(repeating: "a", count: 199)
        #expect(ArticleBlocks.isFullText([p(more)]))
        // Digits and punctuation are characters but not letters.
        let digits = String(repeating: "中", count: 150) + String(repeating: "1", count: 250)
        #expect(ArticleBlocks.isFullText([p(digits)]))
        // Mostly Latin text needs 1,000 whatever its Chinese part.
        let latin = String(repeating: "a", count: 600) + String(repeating: "中", count: 399)
        #expect(!ArticleBlocks.isFullText([p(latin)]))
    }

    @Test("headings, code and captions count as text; images and rules do not")
    func fullTextKinds() {
        let text = String(repeating: "a", count: 250)
        let mixed: [Block] = [
            h(2, text), code(text), p(text, caption: true), p(String(repeating: "a", count: 247)),
            image("https://img.example/a.png", alt: String(repeating: "alt", count: 400)), Block(.rule),
        ]
        #expect(ArticleBlocks.isFullText(mixed), "250 + 1 + 250 + 1 + 250 + 1 + 247 = 1,000")
        #expect(!ArticleBlocks.isFullText(Array(mixed.dropFirst())))
    }

    @Test("a block's script: more than half of its letters, and kana")
    func scripts() {
        #expect(ArticleBlocks.isMostlyCJK("今天天气很好 OK"))
        #expect(ArticleBlocks.isMostlyCJK("これは日本語です"))
        #expect(ArticleBlocks.isMostlyCJK("한국어 문장"))
        #expect(!ArticleBlocks.isMostlyCJK("An English sentence with 中文"))
        #expect(!ArticleBlocks.isMostlyCJK("ab中文"), "exactly half is not more than half")
        #expect(!ArticleBlocks.isMostlyCJK("1234 5678"))
        #expect(ArticleBlocks.containsKana("東京の天気"))
        #expect(ArticleBlocks.containsKana("カタカナ"))
        #expect(!ArticleBlocks.containsKana("东京的天气"))
        #expect(!ArticleBlocks.containsKana("한국어"))
    }
}
