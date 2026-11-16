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
        #expect(texts(flags).map(\.count) == [10_000, 10_000, 1], "the byte bound comes first: 8 bytes a flag")
        let hands = ArticleBlocks.make(html: String(repeating: "👍", count: 20_001), baseURL: base).blocks
        #expect(texts(hands).map(\.count) == [20_000, 1])

        // A heading too.
        let heading = ArticleBlocks.make(html: "<h2>" + String(repeating: "a", count: 20_001) + "</h2>", baseURL: base).blocks
        #expect(heading.map(\.kind) == [
            .heading(level: 2, [InlineRun(String(repeating: "a", count: 20_000))]), .heading(level: 2, [InlineRun("a")]),
        ])
    }

    @Test("a block holds at most 80,000 bytes of text, whatever its characters are made of")
    func blockByteLimit() {
        #expect(ArticleBlocks.maximumBlockBytes == 80_000)
        // One letter under 600,000 combining marks is a single character
        // of 1.2 MB.
        let marked = "a" + String(repeating: "\u{301}", count: 600_000)
        #expect(marked.count == 1)
        let pieces = texts(ArticleBlocks.make(html: "<p>" + marked + "</p>", baseURL: base).blocks)
        #expect(pieces.count == 16)
        #expect(pieces.allSatisfy { $0.utf8.count <= 80_000 })
        #expect(pieces.joined() == marked, "nothing is lost, and each piece ends where a scalar ends")
        #expect(pieces.joined().unicodeScalars.count == 600_001)

        // Across runs the bytes of a piece add up as its characters do.
        let html = "<p>" + String(repeating: "🇯🇵", count: 9_000) + "<b>" + String(repeating: "🇯🇵", count: 9_000) + "</b></p>"
        let split = ArticleBlocks.make(html: html, baseURL: base).blocks
        // The first piece is full at 80,000 bytes: the plain run and 1,000
        // flags of the bold one. (Counts, not the blocks themselves: a
        // failure would print 144,000 flags.)
        let runs: [[InlineRun]] = split.map { if case .paragraph(let runs) = $0.kind { runs } else { [] } }
        #expect(runs.map { $0.map(\.text.count) } == [[9_000, 1_000], [8_000]])
        #expect(runs.map { $0.map(\.isBold) } == [[false, true], [true]])
        #expect(texts(split).joined() == String(repeating: "🇯🇵", count: 18_000))

        // The byte bound falls inside a three-byte scalar here (a character
        // of 20,000 enclosing marks): the piece ends before that scalar.
        let wide = String(repeating: "中", count: 19_999) + String(repeating: "\u{20DD}", count: 20_000)
        let widePieces = texts(ArticleBlocks.make(html: "<p>" + wide + "</p>", baseURL: base).blocks)
        #expect(widePieces.map(\.utf8.count) == [79_998, 39_999])
        #expect(widePieces.joined() == wide)

        // Code too, with and without line ends.
        let code = texts(ArticleBlocks.make(html: "<pre>y" + String(repeating: "\u{301}", count: 100_000) + "</pre>", baseURL: base).blocks)
        #expect(code.count == 3)
        #expect(code.allSatisfy { $0.utf8.count <= 80_000 })
        #expect(code.joined() == "y" + String(repeating: "\u{301}", count: 100_000))
        let line = String(repeating: "🇯🇵", count: 100) + "\n"
        let lines = texts(ArticleBlocks.make(html: "<pre>" + String(repeating: line, count: 150) + "</pre>", baseURL: base).blocks)
        // 99 lines of 801 bytes fill 79,299 bytes; the 100th would pass
        // the bound, so the cut is the line end before it.
        #expect(lines.map(\.utf8.count) == [99 * 801 - 1, 51 * 801 - 1])
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
/// for 16 to 240 KB) converts on a detached task, with at most 3,000
/// blocks, in time proportional to its size. The times are printed:
/// `criterion 3 | shape | …`.
///
/// The bound is relative (#170). Each shape is measured alternately with a
/// reference, ordinary paragraphs of the same number of characters that are
/// read whole, and its best time must stay within `allowedRatio` times the
/// reference's best. A slow or stalled runner slows both alike: an absolute
/// bound of one second failed twice on the hosted runner (1.04 and 1.54 s)
/// for shapes that take 0.1 to 0.4 s on the development Mac, with nothing
/// changed in the converter. A converter that is slow on the reference too
/// is caught by the absolute `ceiling`, the second line: 5 s for up to
/// 2,000,000 characters, where the tree builder took 3 to 16 s for an
/// eighth of that or less; and by "the time of ordinary paragraphs grows in
/// proportion to their number" below.
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
        Shape(name: "500 levels of div before 300,000 empty paragraphs") {
            String(repeating: "<div>", count: 500) + String(repeating: "<p>", count: 300_000)
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
        Shape(name: "65,000 misnested links and divs") {
            String(repeating: "<a href=x><div>", count: 65_000) + "x"
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
        Shape(name: "200,000 references") {
            String(repeating: "&amp;", count: 200_000)
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
        Shape(name: "one letter under 600,000 combining marks") {
            "<p>a" + String(repeating: "\u{301}", count: 600_000)
        },
        Shape(name: "one letter under 300,000 combining marks in a pre") {
            "<pre>a" + String(repeating: "\u{301}", count: 300_000)
        },
        Shape(name: "a megabyte of marks in an emoji image's alternative text") {
            "<p>a<img class=\"emoji\" alt=\"a" + String(repeating: "\u{301}", count: 524_288) + "\">b</p>"
        },
        Shape(name: "31 open lists around 100,000 short lists of one item") {
            String(repeating: "<ol><li>", count: 31) + String(repeating: "<ol start=\"9999\"><li>x</li></ol>", count: 100_000)
        },
        Shape(name: "31 open lists around 300,000 items") {
            String(repeating: "<ol><li>", count: 31) + String(repeating: "<li>x</li>", count: 300_000)
        },
        Shape(name: "an unclosed frame before 2,000,000 characters") {
            "<p>a</p><iframe>" + String(repeating: "<p>x</p>", count: 250_000)
        },
    ]

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// A shape may take at most this many times as long as the reference
    /// of its size. On the development Mac the highest ratio is 2.0 to 2.4
    /// (one letter under combining marks in a `pre`), whatever the load;
    /// most shapes take less than their reference. A quadratic step over
    /// only the first 30,000 of one shape's 200,000 list items made it 75
    /// times as long.
    static let allowedRatio = 10.0
    /// The reference's time counts as at least this much: below it a ratio
    /// measures the clock, not the work.
    static let referenceFloor = Duration.milliseconds(20)
    /// Whatever the reference took: the slowest shape takes 0.2 to 0.4 s
    /// on the development Mac and took up to 1.54 s on a stalled hosted
    /// runner.
    static let ceiling = Duration.seconds(5)

    /// About 930 characters of ordinary text with bold and links: 2,000,000
    /// characters of it are 2,150 paragraphs, under the block limit, so the
    /// whole input is read.
    private static let referenceParagraph = "<p>" + String(
        repeating: "Some <b>bold</b> and <a href=\"https://example.com/a\">a link</a>, then text that goes on for a while to make a paragraph of ordinary length. ",
        count: 7
    ) + "</p>\n"

    /// Ordinary paragraphs of as many characters as the converter reads of
    /// `html` (its first 2,000,000), rounded up to a whole paragraph.
    static func reference(for html: String) -> String {
        let characters = min(html.unicodeScalars.count, ArticleBlocks.maximumInputCharacters)
        let unit = referenceParagraph.unicodeScalars.count
        return String(repeating: referenceParagraph, count: max(1, (characters + unit - 1) / unit))
    }

    private static func convert(_ html: String) async -> (Duration, ArticleBlocks) {
        await Task.detached { () -> (Duration, ArticleBlocks) in
            let clock = ContinuousClock()
            var converted = ArticleBlocks(blocks: [], isCut: false)
            let time = clock.measure {
                converted = ArticleBlocks.make(html: html, baseURL: base)
            }
            return (time, converted)
        }.value
    }

    @Test("each shape converts in time proportional to its size, as ordinary paragraphs of that size do", arguments: shapes)
    func proportionalToSize(_ shape: Shape) async {
        let html = shape.html()
        let reference = Self.reference(for: html)
        // The best of up to five rounds, the reference and the shape one
        // after the other in each: other suites run beside this one, and load
        // only ever adds time. A round in which the bound holds ends it.
        var best = Duration.seconds(3_600)
        var referenceBest = Duration.seconds(3_600)
        var result = ArticleBlocks(blocks: [], isCut: false)
        var referenceResult = ArticleBlocks(blocks: [], isCut: false)
        func ratio() -> Double {
            Self.seconds(best) / Self.seconds(max(referenceBest, Self.referenceFloor))
        }
        for _ in 0..<5 {
            let (referenceTime, referenceConverted) = await Self.convert(reference)
            referenceBest = min(referenceBest, referenceTime)
            referenceResult = referenceConverted
            let (time, converted) = await Self.convert(html)
            best = min(best, time)
            result = converted
            if ratio() <= Self.allowedRatio, best < Self.ceiling {
                break
            }
        }
        print(String(
            format: "criterion 3 | %@ | %d bytes | %.3f s | %d blocks | cut: %@ | reference %.3f s | ratio %.2f",
            shape.name, html.utf8.count, Self.seconds(best), result.blocks.count, result.isCut ? "yes" : "no",
            Self.seconds(referenceBest), ratio()
        ))
        #expect(ratio() <= Self.allowedRatio, "\(shape.name): \(Self.seconds(best)) s, \(ratio()) times the reference's \(Self.seconds(referenceBest)) s")
        #expect(best < Self.ceiling, "\(shape.name): \(Self.seconds(best)) s")
        // The reference is read whole: what it measures is the input's size.
        #expect(!referenceResult.isCut || reference.unicodeScalars.count > ArticleBlocks.maximumInputCharacters)
        #expect(referenceResult.blocks.count < ArticleBlocks.maximumBlocks)
        #expect(result.blocks.count <= ArticleBlocks.maximumBlocks)
        // No block holds more than its limit of text.
        #expect(result.blocks.allSatisfy { ($0.plainText?.utf8.count ?? 0) <= ArticleBlocks.maximumBlockBytes })
        #expect(result.blocks.allSatisfy { ($0.plainText?.count ?? 0) <= ArticleBlocks.maximumBlockCharacters })
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
