import Foundation
@testable import NewsPawKit
import Testing

/// RD15 decision 3: segments, chunks, hashes, a block's shown text and the
/// copy text. Criteria 1, 2 (a mixed block), 15 (rows found by hash) and 16
/// (the copy text).
@Suite("Body segments")
struct BodySegmentsTests {
    static func paragraph(_ text: String) -> ArticleBlock {
        ArticleBlock(.paragraph([InlineRun(text)]))
    }

    /// An English sentence of exactly `length` characters, ending in a full
    /// stop.
    static func sentence(_ length: Int, letter: Character = "a") -> String {
        String(repeating: letter, count: length - 1) + "."
    }

    // MARK: - Criterion 1: which blocks give texts

    @Test("criterion 1: paragraphs, headings, captions, list items and quotes give texts; code, images and rules never")
    func blockKinds() throws {
        let image = ArticleImage(url: try #require(URL(string: "https://example.invalid/a.png")), alternativeText: "A picture of the quay")
        let blocks = [
            ArticleBlock(.heading(level: 2, [InlineRun("The heading")])),
            Self.paragraph("A paragraph."),
            ArticleBlock(.paragraph([InlineRun("A caption")]), isCaption: true),
            ArticleBlock(.paragraph([InlineRun("A list item")]), listDepth: 1, marker: .bullet),
            ArticleBlock(.paragraph([InlineRun("A quote")]), quoteDepth: 1),
            ArticleBlock(.image(image)),
            ArticleBlock(.code("let text = \"Never sent\"")),
            ArticleBlock(.rule),
            ArticleBlock(.paragraph([InlineRun("Bold", isBold: true), InlineRun(" and a "), InlineRun("link", link: URL(string: "https://example.invalid"))])),
        ]
        let plan = BodySegments.plan(blocks, locale: .simplifiedChinese)
        #expect(plan.chunks.count == 1)
        #expect(plan.chunks[0].map(\.text) == ["The heading", "A paragraph.", "A caption", "A list item", "A quote", "Bold and a link"])
        #expect(plan.chunks[0].map(\.block) == [0, 1, 2, 3, 4, 8])
        #expect(Set(plan.lines.keys) == [0, 1, 2, 3, 4, 8])
    }

    @Test("criterion 1: a block is split at its line breaks, each line trimmed; a line without a letter is shown and never sent")
    func lines() {
        let plan = BodySegments.plan([Self.paragraph("  First line of the poem  \n— 42 —\nSecond line of the poem")], locale: .simplifiedChinese)
        #expect(plan.chunks.flatMap { $0.map(\.text) } == ["First line of the poem", "Second line of the poem"])
        let lines = try? #require(plan.lines[0])
        #expect(lines?.map { $0.map(\.text) } == [["First line of the poem"], ["— 42 —"], ["Second line of the poem"]])
        #expect(lines?[1].first?.role == .kept)
    }

    // MARK: - Criterion 1: cutting a long line

    @Test("criterion 1: a line of exactly 1,500 characters is one segment; one of 1,501 is cut")
    func boundary() {
        let exact = Self.sentence(1_500)
        #expect(BodySegments.pieces(of: exact) == [exact])
        let over = Self.sentence(800) + " " + Self.sentence(700, letter: "b")
        #expect(over.count == 1_501)
        #expect(BodySegments.pieces(of: over) == [Self.sentence(800), Self.sentence(700, letter: "b")])
    }

    @Test("criterion 1: a long line is cut after the last sentence end inside the bound, Latin (followed by white space) and CJK")
    func sentenceEnds() {
        // Latin: the last ". " inside the first 1,500 characters.
        let first = Self.sentence(600) + " " + Self.sentence(600, letter: "b")
        let latin = first + " " + Self.sentence(600, letter: "c")
        #expect(BodySegments.pieces(of: latin) == [first, Self.sentence(600, letter: "c")])
        // A full stop not followed by white space is not a sentence end.
        let decimals = String(repeating: "x", count: 1_000) + "3.14" + String(repeating: "y", count: 600)
        #expect(BodySegments.pieces(of: decimals).first?.count == 1_500)
        // CJK: 。！？ anywhere.
        let chinese = String(repeating: "海", count: 999) + "。" + String(repeating: "港", count: 599) + "！" + String(repeating: "湾", count: 600)
        let pieces = BodySegments.pieces(of: chinese)
        #expect(pieces == [String(repeating: "海", count: 999) + "。", String(repeating: "港", count: 599) + "！" + String(repeating: "湾", count: 600)])
        #expect(pieces.allSatisfy { $0.count <= BodySegments.maximumCharacters })
    }

    @Test("criterion 1: without a sentence end a line is cut at the last white space, else hard at 1,500 characters")
    func whiteSpaceAndHard() {
        let words = String(repeating: "word ", count: 400).trimmingCharacters(in: .whitespaces)
        let pieces = BodySegments.pieces(of: words)
        #expect(pieces.allSatisfy { $0.count <= 1_500 && !$0.hasPrefix(" ") && !$0.hasSuffix(" ") })
        #expect(pieces.joined(separator: " ") == words)
        #expect(pieces[0].count == 1_499)
        let solid = String(repeating: "z", count: 3_200)
        #expect(BodySegments.pieces(of: solid).map(\.count) == [1_500, 1_500, 200])
        #expect(BodySegments.pieces(of: String(repeating: "长", count: 20_000)).count == 14)
    }

    // MARK: - Criterion 1: chunks

    @Test("criterion 1: chunks hold at most 20 texts and 1,500 characters, never split a text, and keep reading order")
    func chunks() {
        // 45 short paragraphs: 20, 20, 5.
        let short = BodySegments.plan((1...45).map { Self.paragraph("Paragraph number \($0) of the harbour story.") }, locale: .japanese)
        #expect(short.chunks.map(\.count) == [20, 20, 5])
        #expect(short.chunks.flatMap { $0.map(\.block) } == Array(0..<45))
        // Paragraphs of 700 characters: two to a chunk.
        let long = BodySegments.plan((1...5).map { Self.paragraph(Self.sentence(700, letter: Character(UnicodeScalar(96 + $0)!))) }, locale: .japanese)
        #expect(long.chunks.map(\.count) == [2, 2, 1])
        #expect(long.chunks.allSatisfy { $0.reduce(0) { $0 + $1.text.count } <= 1_500 })
        // Exactly 1,500 together still fits; one more character does not.
        let fits = BodySegments.plan([Self.paragraph(Self.sentence(750)), Self.paragraph(Self.sentence(750, letter: "b"))], locale: .japanese)
        #expect(fits.chunks.map(\.count) == [2])
        let over = BodySegments.plan([Self.paragraph(Self.sentence(750)), Self.paragraph(Self.sentence(751, letter: "b"))], locale: .japanese)
        #expect(over.chunks.map(\.count) == [1, 1])
    }

    @Test("criterion 1: the same blocks and locale give the same chunks; a repeated text is sent once and shown twice")
    func deterministicAndRepeated() {
        let blocks = (1...30).map { Self.paragraph($0 % 3 == 0 ? "Advertisement: read more on the harbour site." : "Text \($0) about the quay.") }
        let first = BodySegments.plan(blocks, locale: .simplifiedChinese)
        let second = BodySegments.plan(blocks, locale: .simplifiedChinese)
        #expect(first == second)
        let sent = first.chunks.flatMap { $0.map(\.text) }
        #expect(sent.filter { $0.hasPrefix("Advertisement") }.count == 1)
        #expect(sent.count == 21)
        let repeated = BodySegments.hash("Advertisement: read more on the harbour site.")
        let done = Dictionary(uniqueKeysWithValues: first.chunks.flatMap { $0.map { ($0.hash, "T:" + $0.text) } })
        #expect(first.text(of: 2, done: done) == "T:Advertisement: read more on the harbour site.")
        #expect(first.text(of: 29, done: done) == "T:Advertisement: read more on the harbour site.")
        #expect(done[repeated] != nil)
    }

    @Test("criterion 1: hashes are SHA-256 of the UTF-8, lower-case hex")
    func hashes() {
        #expect(BodySegments.hash("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(BodySegments.hash("海港议会") == "91367631059fb1e3f32a211e46ed4e2281fa53e5f5f3832c476bbc96c01ad88d")
        let plan = BodySegments.plan([Self.paragraph("  The harbour office posts the tide tables.  ")], locale: .simplifiedChinese)
        #expect(plan.chunks.first?.first?.hash == "50b7f97bd869c311dae0c7a9fd9a5df0863bcdce49d2bd3749e27f6b519a7f1d")
    }

    @Test("the fixture's long story is eight chunks of two paragraphs, its seventh paragraph in chunk 4")
    func fixtureLongStory() {
        let paragraphs = (1...16).map {
            FixtureTransport.bodyParagraph($0, of: "Long story", word: $0 == 7 ? FixtureModelHTTP.Word.stallOnce : nil)
        }
        #expect(paragraphs.allSatisfy { (600...750).contains($0.count) }, "\(paragraphs.map(\.count))")
        let plan = BodySegments.plan(paragraphs.map(Self.paragraph), locale: .simplifiedChinese)
        #expect(plan.chunks.map(\.count) == Array(repeating: 2, count: 8))
        #expect(plan.chunks[3].contains { $0.text.contains(FixtureModelHTTP.Word.stallOnce) })
    }

    // MARK: - Criterion 2: what a block shows

    @Test("criterion 2: a block mixing kept and sent lines shows the kept ones as they are; converted lines are shown converted")
    func mixedBlock() {
        let block = Self.paragraph("苹果公司今天发布了新的笔记本电脑。\nThe company said the laptops are faster.\n台灣半導體產業持續擴張，台積電宣布在高雄興建新廠。\n— 3 —")
        let plan = BodySegments.plan([block], locale: .simplifiedChinese)
        #expect(plan.chunks.flatMap { $0.map(\.text) } == ["The company said the laptops are faster."])
        #expect(plan.text(of: 0, done: [:]) == nil, "waiting for its sent line")
        let done = [BodySegments.hash("The company said the laptops are faster."): "公司表示这些笔记本电脑更快。"]
        #expect(plan.text(of: 0, done: done)
            == "苹果公司今天发布了新的笔记本电脑。\n公司表示这些笔记本电脑更快。\n台湾半导体产业持续扩张，台积电宣布在高雄兴建新厂。\n— 3 —")
        #expect(plan.finishedChunks(done: done) == 1)
        // A block with only a conversion is shown converted at once.
        let converted = BodySegments.plan([Self.paragraph("台灣半導體產業持續擴張。")], locale: .simplifiedChinese)
        #expect(converted.chunks.isEmpty)
        #expect(converted.hasWork && converted.hasConversion)
        #expect(converted.text(of: 0, done: [:]) == "台湾半导体产业持续扩张。")
        // A block in the reading language alone gives no work.
        let kept = BodySegments.plan([Self.paragraph("苹果公司今天发布了新的笔记本电脑。")], locale: .simplifiedChinese)
        #expect(!kept.hasWork)
        #expect(kept.text(of: 0, done: [:]) == nil)
    }

    @Test("the pieces of one line are joined with nothing in Chinese and Japanese and with a space in English")
    func joiningPieces() {
        let line = Self.sentence(1_000) + " " + Self.sentence(1_000, letter: "b")
        for locale in [ReadingLocale.simplifiedChinese, .japanese] {
            let plan = BodySegments.plan([Self.paragraph(line)], locale: locale)
            let segments = plan.chunks.flatMap { $0 }
            #expect(segments.count == 2)
            let done = Dictionary(uniqueKeysWithValues: segments.enumerated().map { ($1.hash, "T\($0)") })
            #expect(plan.text(of: 0, done: done) == "T0T1")
        }
        let french = BodySegments.plan([Self.paragraph(String(repeating: "Le gouvernement a annoncé un plan. ", count: 60))], locale: .english)
        let pieces = french.chunks.flatMap { $0 }
        #expect(pieces.count == 2)
        let done = Dictionary(uniqueKeysWithValues: pieces.enumerated().map { ($1.hash, "T\($0)") })
        #expect(french.text(of: 0, done: done) == "T0 T1")
    }

    @Test("a title planned with the body is its first segment, under the title block")
    func titleFirst() {
        let plan = BodySegments.plan([Self.paragraph("The first paragraph of the page.")], title: "The ferry at dawn", locale: .simplifiedChinese)
        #expect(plan.chunks.first?.map(\.text) == ["The ferry at dawn", "The first paragraph of the page."])
        #expect(plan.chunks.first?.first?.block == BodySegments.titleBlock)
        let done = Dictionary(uniqueKeysWithValues: plan.chunks[0].map { ($0.hash, "T:" + $0.text) })
        #expect(plan.text(of: BodySegments.titleBlock, done: done) == "T:The ferry at dawn")
    }

    @Test("chunks restricted to the texts being sent keep the plan's grouping")
    func restrictedChunks() {
        let plan = BodySegments.plan((1...6).map { Self.paragraph(Self.sentence(700, letter: Character(UnicodeScalar(96 + $0)!))) }, locale: .japanese)
        let hashes = Set([plan.chunks[0][1].hash, plan.chunks[2][0].hash, plan.chunks[2][1].hash])
        #expect(plan.chunks(sending: hashes).map { $0.map(\.hash) } == [[plan.chunks[0][1].hash], [plan.chunks[2][0].hash, plan.chunks[2][1].hash]])
        #expect(plan.sentHashes.count == 6)
    }

    // MARK: - Criterion 16: the copy text

    @Test("criterion 16: Copy Translation's text for a fully, a partly and a not translated body")
    func copyText() throws {
        let image = ArticleImage(url: try #require(URL(string: "https://example.invalid/a.png")), alternativeText: "A picture")
        let blocks = [
            ArticleBlock(.heading(level: 2, [InlineRun("The heading")])),
            Self.paragraph("The first paragraph."),
            ArticleBlock(.image(image)),
            ArticleBlock(.code("swift build")),
            ArticleBlock(.rule),
            Self.paragraph("The second paragraph."),
        ]
        let plan = BodySegments.plan(blocks, locale: .simplifiedChinese)
        let all = Dictionary(uniqueKeysWithValues: plan.chunks.flatMap { $0.map { ($0.hash, "译：" + $0.text) } })
        #expect(BodySegments.copyText(title: "译：Title", blocks: blocks, plan: plan, done: all)
            == "译：Title\n\n译：The heading\n\n译：The first paragraph.\n\nswift build\n\n译：The second paragraph.")
        let part = all.filter { $0.key == BodySegments.hash("The first paragraph.") }
        #expect(BodySegments.copyText(title: "Title", blocks: blocks, plan: plan, done: part)
            == "Title\n\nThe heading\n\n译：The first paragraph.\n\nswift build\n\nThe second paragraph.")
        #expect(BodySegments.copyText(title: "Title", blocks: blocks, plan: plan, done: [:])
            == "Title\n\nThe heading\n\nThe first paragraph.\n\nswift build\n\nThe second paragraph.")
    }

    @Test("the plain-text rule: a translation holding Markdown, an HTML link and a javascript: address is copied verbatim")
    func copyIsVerbatim() {
        let blocks = [Self.paragraph(FixtureTransport.markupParagraph)]
        let plan = BodySegments.plan(blocks, locale: .simplifiedChinese)
        let reply = "译[zh-Hans]：" + FixtureTransport.markupParagraph
        let done = [BodySegments.hash(FixtureTransport.markupParagraph): reply]
        #expect(plan.text(of: 0, done: done) == reply)
        #expect(BodySegments.copyText(title: "T", blocks: blocks, plan: plan, done: done) == "T\n\n" + reply)
    }
}
