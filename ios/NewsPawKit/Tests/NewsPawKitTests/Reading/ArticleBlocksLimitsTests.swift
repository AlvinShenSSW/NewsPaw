import Foundation
@testable import NewsPawKit
import Testing

private let base = URL(string: "https://news.example/2026/story.html")!

private func texts(_ blocks: [ArticleBlock]) -> [String] {
    blocks.compactMap(\.plainText)
}

/// RD11 decision 4 and criterion 3: the cuts are exact and end with the
/// marker.
@Suite("Article blocks: limits")
struct ArticleBlocksLimitsTests {
    @Test("3,000 blocks are kept whole; one more is cut and marked")
    func blockLimit() {
        let atLimit = ArticleBlocks.make(html: String(repeating: "<p>x</p>", count: 3_000), baseURL: base)
        #expect(atLimit.blocks.count == 3_000)
        #expect(!atLimit.isCut)

        let over = ArticleBlocks.make(html: String(repeating: "<p>x</p>", count: 3_000) + "<p>last</p>", baseURL: base)
        #expect(over.blocks.count == 3_000)
        #expect(over.isCut)
        #expect(over.blocks.last?.plainText == "x")

        // What follows the 3,000th block and is no block does not mark it.
        let trailing = ArticleBlocks.make(
            html: String(repeating: "<p>x</p>", count: 3_000) + "<p> </p><div><b></b></div><!-- c --> \n", baseURL: base
        )
        #expect(trailing.blocks.count == 3_000)
        #expect(!trailing.isCut)

        // Images, rules and code blocks count as blocks.
        let mixed = ArticleBlocks.make(html: String(repeating: "<hr><pre>c</pre>", count: 1_500) + "<hr>", baseURL: base)
        #expect(mixed.blocks.count == 3_000)
        #expect(mixed.isCut)
    }

    @Test("2,000,000 characters are read whole; one more is cut and marked")
    func inputLimit() {
        let atLimit = ArticleBlocks.make(html: String(repeating: "a", count: 2_000_000), baseURL: base)
        #expect(!atLimit.isCut)
        #expect(atLimit.blocks.count == 100)
        #expect(texts(atLimit.blocks).reduce(0) { $0 + $1.utf8.count } == 2_000_000)

        let over = ArticleBlocks.make(html: String(repeating: "a", count: 2_000_000) + "b", baseURL: base)
        #expect(over.isCut)
        #expect(texts(over.blocks).reduce(0) { $0 + $1.utf8.count } == 2_000_000)
        #expect(over.blocks.last?.plainText?.last == "a", "the character past the limit is not read")

        // Characters, not bytes: 2,000,000 three-byte characters are whole.
        let chinese = ArticleBlocks.make(html: String(repeating: "中", count: 2_000_000), baseURL: base)
        #expect(!chinese.isCut)
        #expect(texts(chinese.blocks).reduce(0) { $0 + $1.unicodeScalars.count } == 2_000_000)
        let chineseOver = ArticleBlocks.make(html: String(repeating: "中", count: 2_000_001), baseURL: base)
        #expect(chineseOver.isCut)
        #expect(texts(chineseOver.blocks).reduce(0) { $0 + $1.unicodeScalars.count } == 2_000_000)

        // A tag cut in two by the limit is not text.
        let cutTag = ArticleBlocks.make(
            html: "<p>" + String(repeating: "a", count: 1_999_990) + "</p><p class=\"more\">tail</p>", baseURL: base
        )
        #expect(cutTag.isCut)
        #expect(cutTag.blocks.allSatisfy { $0.plainText?.allSatisfy { $0 == "a" } == true })
    }

    @Test("a paragraph's text beyond 20,000 characters continues in a further paragraph")
    func paragraphLimit() {
        #expect(ArticleBlocks.make(html: "<p>" + String(repeating: "a", count: 20_000) + "</p>", baseURL: base).blocks.count == 1)
        let over = ArticleBlocks.make(html: "<p>" + String(repeating: "a", count: 20_001) + "</p>", baseURL: base)
        #expect(texts(over.blocks).map(\.count) == [20_000, 1])
        #expect(!over.isCut)

        // Across runs, each piece keeps its styles; only the first piece
        // of a list item carries the marker.
        let html = "<ul><li>" + String(repeating: "a", count: 15_000) + "<b>" + String(repeating: "b", count: 10_000) + "</b></li></ul>"
        let split = ArticleBlocks.make(html: html, baseURL: base).blocks
        #expect(split == [
            ArticleBlock(
                .paragraph([InlineRun(String(repeating: "a", count: 15_000)), InlineRun(String(repeating: "b", count: 5_000), isBold: true)]),
                listDepth: 1, marker: .bullet
            ),
            ArticleBlock(.paragraph([InlineRun(String(repeating: "b", count: 5_000), isBold: true)]), listDepth: 1),
        ])

        // Characters as the reader sees them: a flag is one, of two scalars
        // and eight bytes, and is not cut in two.
        let flags = ArticleBlocks.make(html: String(repeating: "🇯🇵", count: 20_001), baseURL: base).blocks
        #expect(texts(flags).map(\.count) == [20_000, 1])

        // A heading too.
        let heading = ArticleBlocks.make(html: "<h2>" + String(repeating: "a", count: 20_001) + "</h2>", baseURL: base).blocks
        #expect(heading.map(\.kind) == [
            .heading(level: 2, [InlineRun(String(repeating: "a", count: 20_000))]), .heading(level: 2, [InlineRun("a")]),
        ])
    }

    @Test("a code block beyond 20,000 characters continues in a further one, cut at a line's end where there is one")
    func codeLimit() {
        let line = String(repeating: "x", count: 99) + "\n"
        let lines = ArticleBlocks.make(html: "<pre>" + String(repeating: line, count: 300) + "</pre>", baseURL: base).blocks
        // 200 lines of 100 characters fill the first block; its last line
        // break is the cut and is not kept.
        #expect(texts(lines).map(\.count) == [19_999, 9_999])
        #expect(lines.allSatisfy { if case .code = $0.kind { true } else { false } })
        let oneLine = ArticleBlocks.make(html: "<pre>" + String(repeating: "y", count: 20_001) + "</pre>", baseURL: base).blocks
        #expect(texts(oneLine).map(\.count) == [20_000, 1])
    }

    @Test("300 images are kept; further ones are dropped without the marker")
    func imageLimit() {
        let html = (0..<305).map { "<img src=\"https://img.example/\($0).png\">" }.joined()
        let result = ArticleBlocks.make(html: html + "<p>after</p>", baseURL: base)
        #expect(result.blocks.count == 301)
        #expect(!result.isCut)
        #expect(result.blocks.last?.plainText == "after")
        guard case .image(let last)? = result.blocks.dropLast().last?.kind else {
            Issue.record("no image")
            return
        }
        #expect(last.url.absoluteString == "https://img.example/299.png")
    }

}

// Nested in the serialized group: see `TimedAndHeavySuites`.
extension TimedAndHeavySuites {
/// RD11 criterion 3: bounded work. Each shape the debate measured against
/// the tree builder (SwiftSoup 2.14.3: 3 to 16 seconds, or 0.5 to 1.9 GB,
/// for 16 to 240 KB) converts within one second on a detached task, with at
/// most 3,000 blocks. The times are printed: `criterion 3 | shape | …`.
@Suite("Article blocks: bounded work", .serialized)
struct ArticleBlocksBoundedWorkTests {
    struct Shape: CustomTestStringConvertible, Sendable {
        var name: String
        var html: @Sendable () -> String

        var testDescription: String { name }
    }

    private static let paragraph = "<p>Some <b>bold</b> and <a href=\"https://example.com/a\">a link</a>, then text that goes on for a while to make a paragraph of ordinary length.</p>\n"

    static let shapes: [Shape] = [
        Shape(name: "formatting tags reopened across 16,000 paragraphs") {
            let names = ["b", "big", "code", "em", "font", "i", "nobr", "s", "small", "strike", "strong", "tt", "u"]
            return "<p>" + names.map { "<\($0)><\($0)><\($0)>" }.joined() + "</p>" + String(repeating: "<p>x</p>", count: 16_000)
        },
        Shape(name: "attributed formatting tags reopened across 16,000 paragraphs") {
            "<p>" + (0..<20).map { "<b class=\"c\($0)\">" }.joined() + "</p>" + String(repeating: "<p>x</p>", count: 16_000)
        },
        Shape(name: "2,000 distinct formatting tags, then 100,000 paragraphs") {
            "<p>" + (0..<2_000).map { "<b a=\($0)>" }.joined() + String(repeating: "<p>x", count: 100_000)
        },
        Shape(name: "an unclosed link before 16,000 paragraphs") {
            "<div><a href=\"https://example.com/x\">Title</div>\n" + String(repeating: "<p>Ordinary paragraph text.</p>\n", count: 16_000)
        },
        Shape(name: "an unclosed font tag before 16,000 unclosed paragraphs") {
            "<p><font color=\"#333333\">Intro\n" + String(repeating: "<p>Ordinary paragraph text.\n", count: 16_000)
        },
        Shape(name: "500 levels of div before 300,000 paragraphs") {
            String(repeating: "<div>", count: 500) + String(repeating: "<p>x", count: 300_000)
        },
        Shape(name: "500 levels of div before 600,000 empty paragraphs") {
            String(repeating: "<div>", count: 500) + String(repeating: "<p>", count: 600_000)
        },
        Shape(name: "500,000 unclosed bold tags") {
            String(repeating: "<b>", count: 500_000) + "x"
        },
        Shape(name: "399,000 unclosed divs") {
            String(repeating: "<div>", count: 399_000) + "x"
        },
        Shape(name: "150,000 unclosed quotes") {
            String(repeating: "<blockquote>", count: 150_000) + "x"
        },
        Shape(name: "200,000 unclosed lists and items") {
            String(repeating: "<ul><li>", count: 200_000) + "x"
        },
        Shape(name: "120,000 unclosed tables") {
            String(repeating: "<table><tr><td>", count: 120_000) + "x"
        },
        Shape(name: "130,000 misnested links and divs") {
            String(repeating: "<a href=x><div>", count: 130_000) + "x"
        },
        Shape(name: "60,000 links with text in one paragraph") {
            String(repeating: "<a href=/y>x</a>", count: 60_000)
        },
        Shape(name: "380,000 end tags without a start") {
            String(repeating: "</div></x>", count: 190_000) + "x"
        },
        Shape(name: "a megabyte in one link's address") {
            "<p>before</p><a href=\"" + String(repeating: "a", count: 1_048_576) + "\">x</a><p>after</p>"
        },
        Shape(name: "a megabyte in one image's address") {
            "<p>before</p><img src=\"data:image/png;base64," + String(repeating: "A", count: 1_048_576) + "\" alt=\"inline\"><p>after</p>"
        },
        Shape(name: "a megabyte in an attribute that is not read") {
            "<p title=\"" + String(repeating: "t", count: 1_048_576) + "\">before</p><p>after</p>"
        },
        Shape(name: "a megabyte in an attribute left open") {
            "<p>before</p><p title=\"" + String(repeating: "t", count: 1_048_576)
        },
        Shape(name: "2,000,000 characters of ordinary paragraphs") {
            String(repeating: paragraph, count: 2_000_000 / paragraph.count + 1)
        },
        Shape(name: "2,000,000 characters of text in no tag") {
            String(repeating: "word ", count: 400_000)
        },
        Shape(name: "2,000,000 Chinese characters in no tag") {
            String(repeating: "中文段落", count: 500_000)
        },
        Shape(name: "2,000,000 characters in one pre") {
            "<pre>" + String(repeating: "let x = 1\n", count: 199_999)
        },
        Shape(name: "2,000,000 less-than signs") {
            String(repeating: "<", count: 2_000_000)
        },
        Shape(name: "400,000 references") {
            String(repeating: "&amp;", count: 400_000)
        },
        Shape(name: "500,000 unclosed comments") {
            String(repeating: "<!--", count: 500_000)
        },
        Shape(name: "200,000 line breaks") {
            String(repeating: "x<br>", count: 200_000)
        },
        Shape(name: "133,000 images") {
            String(repeating: "<img src=a.png>", count: 133_000)
        },
        Shape(name: "90,000 unclosed forms with controls") {
            "<p>before</p>" + String(repeating: "<form><select><option>", count: 90_000) + "x"
        },
        Shape(name: "a megabyte of alternative text") {
            "<img src=\"https://img.example/a.png\" alt=\"" + String(repeating: "word ", count: 200_000) + "\">"
        },
    ]

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    @Test("each shape converts within one second", arguments: shapes)
    func withinOneSecond(_ shape: Shape) async {
        let html = shape.html()
        // The best of three: other suites run beside this one, and load only
        // ever adds time.
        var best = Duration.seconds(3_600)
        var result = ArticleBlocks(blocks: [], isCut: false)
        for _ in 0..<3 {
            let (time, converted) = await Task.detached { () -> (Duration, ArticleBlocks) in
                let clock = ContinuousClock()
                var converted = ArticleBlocks(blocks: [], isCut: false)
                let time = clock.measure {
                    converted = ArticleBlocks.make(html: html, baseURL: base)
                }
                return (time, converted)
            }.value
            best = min(best, time)
            result = converted
            if best < .milliseconds(500) {
                break
            }
        }
        print(String(
            format: "criterion 3 | %@ | %d bytes | %.3f s | %d blocks | cut: %@",
            shape.name, html.utf8.count, Self.seconds(best), result.blocks.count, result.isCut ? "yes" : "no"
        ))
        #expect(best < .seconds(1), "\(shape.name): \(Self.seconds(best)) s")
        #expect(result.blocks.count <= ArticleBlocks.maximumBlocks)
        // No block holds more than its limit of characters.
        #expect(result.blocks.allSatisfy { ($0.plainText?.utf8.count ?? 0) <= ArticleBlocks.maximumBlockCharacters * 4 })
    }

    @Test("the time of ordinary paragraphs grows in proportion to their number")
    func linear() async {
        // Under the block limit, so that the whole input is read: 2,900
        // paragraphs of 10 and of 40 runs each.
        func time(runs: Int) async -> Duration {
            let html = String(repeating: "<p>" + String(repeating: "<b>x</b> y ", count: runs) + "</p>", count: 2_900)
            var best = Duration.seconds(3_600)
            for _ in 0..<3 {
                let once = await Task.detached {
                    ContinuousClock().measure { _ = ArticleBlocks.make(html: html, baseURL: base) }
                }.value
                best = min(best, once)
            }
            return best
        }
        let small = await time(runs: 10)
        let large = await time(runs: 40)
        let ratio = Self.seconds(large) / max(Self.seconds(small), 0.02)
        print(String(format: "criterion 3 | linear | N: %.3f s | 4N: %.3f s | ratio %.2f", Self.seconds(small), Self.seconds(large), ratio))
        #expect(ratio < 8, "four times the input took \(ratio) times as long")
    }
}
}
