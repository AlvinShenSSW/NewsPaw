import Foundation
@testable import NewsPawKit
import Testing

/// RD16 decision 5 and criterion 11 (the pure half): groups, pieces,
/// packing, joins and the cache key; and the block entry of
/// `TextLanguage` (criterion 15's judging).
@Suite("Page batcher")
struct PageBatcherTests {
    static func run(_ id: Int, block: Int, _ text: String, whole: Bool = false, inView: Bool = true) -> PageRun {
        PageRun(id: id, block: block, text: text, whole: whole, inView: inView)
    }

    // MARK: - Groups

    @Test("runs of one block form one group, placed where the block's first run comes; their order is kept")
    func grouping() {
        let runs = [
            Self.run(1, block: 7, "a"), Self.run(2, block: 3, "b"), Self.run(3, block: 7, "c"), Self.run(4, block: 9, "d", inView: false),
        ]
        let groups = PageBatcher.groups(runs)
        #expect(groups.map(\.block) == [7, 3, 9])
        #expect(groups[0].runs.map(\.id) == [1, 3])
        #expect(groups[0].texts == ["a", "c"])
    }

    // MARK: - Packing (criterion 11)

    static func groups(_ count: Int, runsEach: Int = 1, length: Int = 10) -> [PageGroup] {
        var id = 0
        return (1...count).map { block in
            PageGroup(block: block, runs: (0..<runsEach).map { _ in
                id += 1
                return Self.run(id, block: block, String(repeating: "x", count: length))
            })
        }
    }

    @Test("a request takes whole groups up to 40 entries: 40 fit, the 41st starts the next request")
    func entryBound() throws {
        let units = PageBatcher.units(Self.groups(41))
        #expect(units.map { $0.requests.map(\.count) } == [[40], [1]])
        #expect(units.allSatisfy { $0.requests.count == 1 })
        // Groups are not split while they fit: 13 groups of 3 then the next.
        let threes = PageBatcher.units(Self.groups(14, runsEach: 3))
        #expect(threes.map { $0.requests[0].count } == [39, 3])
    }

    @Test("a request takes whole groups up to 4,000 characters: exactly 4,000 fits, one more starts the next")
    func characterBound() {
        // 4 × 1,000 = 4,000 fits; the fifth does not.
        let units = PageBatcher.units(Self.groups(5, length: 1_000))
        #expect(units.map { PageBatcher.characters($0.requests[0]) } == [4_000, 1_000])
        // Characters, not UTF-16 units: an emoji is one.
        let emoji = PageGroup(block: 1, runs: [Self.run(1, block: 1, String(repeating: "😀", count: 4_000))])
        let unit = try? #require(PageBatcher.nextUnit(from: [emoji])?.unit)
        #expect(unit?.requests.count == 1)
    }

    @Test("visible groups go first: collection order is kept")
    func order() {
        let runs = [Self.run(5, block: 2, "in view"), Self.run(1, block: 1, "below", inView: false)]
        let unit = PageBatcher.nextUnit(from: PageBatcher.groups(runs))?.unit
        #expect(unit?.requests.first?.map(\.run) == [5, 1])
    }

    @Test("a group that alone exceeds a bound is split at entry boundaries into consecutive requests")
    func oversizedGroup() throws {
        let big = Self.groups(1, runsEach: 90)[0]
        let (unit, rest) = try #require(PageBatcher.nextUnit(from: [big] + Self.groups(1)))
        #expect(unit.groups == [big])
        #expect(unit.requests.map(\.count) == [40, 40, 10])
        #expect(unit.requests.flatMap { $0.map(\.run) } == big.runs.map(\.id))
        #expect(rest.count == 1)
        let long = PageGroup(block: 1, runs: (1...3).map { Self.run($0, block: 1, String(repeating: "y", count: 3_000)) })
        let split = try #require(PageBatcher.nextUnit(from: [long])?.unit)
        #expect(split.requests.map { PageBatcher.characters($0) } == [3_000, 3_000, 3_000])
    }

    // MARK: - Pieces

    @Test("a 9,000-character run is cut at sentence ends, then at white space, then hard; pieces are sent in order and joined")
    func pieces() {
        let sentence = String(repeating: "word ", count: 199) + "end. " // 1,000 characters
        let text = String(repeating: sentence, count: 9).trimmingCharacters(in: .whitespaces)
        #expect(text.count == 8_999)
        let pieces = PageBatcher.pieces(of: text)
        #expect(pieces.count == 3)
        #expect(pieces.allSatisfy { $0.count <= 4_000 })
        #expect(pieces[0].hasSuffix("end."), "cut after the last sentence end")
        #expect(pieces.joined(separator: " ") == text)

        let noSentence = String(repeating: "abcdefghi ", count: 900).trimmingCharacters(in: .whitespaces)
        let spaced = PageBatcher.pieces(of: noSentence)
        #expect(spaced.allSatisfy { $0.count <= 4_000 && !$0.hasPrefix(" ") && !$0.hasSuffix(" ") })
        #expect(spaced.joined(separator: " ") == noSentence)

        let solid = String(repeating: "x", count: 9_000)
        #expect(PageBatcher.pieces(of: solid).map(\.count) == [4_000, 4_000, 1_000])

        let chinese = String(repeating: "这是一个很长的句子。", count: 900)
        let chinesePieces = PageBatcher.pieces(of: chinese)
        #expect(chinesePieces.allSatisfy { $0.count <= 4_000 && $0.hasSuffix("。") })
        #expect(chinesePieces.joined() == chinese)

        #expect(PageBatcher.pieces(of: "short") == ["short"])
        #expect(PageBatcher.pieces(of: String(repeating: "z", count: 4_000)).count == 1)
    }

    @Test("a cut run's pieces are consecutive entries of its group; a cut run is not cacheable")
    func cutEntries() {
        let group = PageGroup(block: 1, runs: [Self.run(1, block: 1, String(repeating: "x", count: 4_001), whole: true)])
        #expect(PageBatcher.entries(of: group).map(\.run) == [1, 1])
        #expect(!group.isCacheable)
        #expect(PageGroup(block: 1, runs: [Self.run(1, block: 1, "whole", whole: true)]).isCacheable)
        #expect(!PageGroup(block: 1, runs: [Self.run(1, block: 1, "part")]).isCacheable)
    }

    @Test("joins: no separator for Chinese and Japanese, one space for English")
    func joins() {
        #expect(PageBatcher.join(["甲", "乙"], into: .simplifiedChinese) == "甲乙")
        #expect(PageBatcher.join(["甲", "乙"], into: .japanese) == "甲乙")
        #expect(PageBatcher.join(["a", "b"], into: .english) == "a b")
    }

    // MARK: - The cache key (decision 7)

    @Test("the cache key changes with the host and with the text; no host, no key; the host is case-insensitive")
    func cacheKey() throws {
        let key = try #require(PageBatcher.cacheKey(host: "pages.example.invalid", text: "ログイン"))
        #expect(key.count == 64 && key.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(PageBatcher.cacheKey(host: "PAGES.example.invalid", text: "ログイン") == key)
        #expect(PageBatcher.cacheKey(host: "bank.example.invalid", text: "ログイン") != key)
        #expect(PageBatcher.cacheKey(host: "pages.example.invalid", text: "ログアウト") != key)
        #expect(PageBatcher.cacheKey(host: nil, text: "ログイン") == nil)
        #expect(PageBatcher.cacheKey(host: "", text: "ログイン") == nil)
    }

    // MARK: - The block entry of TextLanguage (criterion 15)

    @Test("a block is judged as a whole by RD14's table: Japanese and English are sent under zh-Hans; Simplified Chinese is kept; digits only are kept")
    func blockJudgement() {
        #expect(TextLanguage.judge(block: ["新しいスマートフォンが発表されました"], reading: .simplifiedChinese, pageHasKana: false) == .send)
        #expect(TextLanguage.judge(block: ["The council approved the budget"], reading: .simplifiedChinese, pageHasKana: false) == .send)
        #expect(TextLanguage.judge(block: ["国务院发布新的数据安全管理条例"], reading: .simplifiedChinese, pageHasKana: false) == .keep)
        #expect(TextLanguage.judge(block: ["2026-11-17", "¥1,200"], reading: .simplifiedChinese, pageHasKana: false) == .keep)
        #expect(TextLanguage.judge(block: ["The council approved the budget"], reading: .english, pageHasKana: false) == .keep)
        // One text of another script sends the group.
        #expect(TextLanguage.judge(block: ["国务院发布新的数据安全管理条例", "The council approved"], reading: .simplifiedChinese, pageHasKana: false) == .send)
    }

    @Test("Traditional Chinese under zh-Hans is converted on the device, run by run")
    func blockConversion() {
        let decision = TextLanguage.judge(block: ["台灣半導體產業持續擴張", "2026"], reading: .simplifiedChinese, pageHasKana: false)
        #expect(decision == .converted(["台湾半导体产业持续扩张", nil]))
    }

    @Test("kanji-only items: kept or sent by the recognizer alone, always sent once the page has kana")
    func kanjiOnly() {
        // A kanji-only item that reads as Chinese.
        let item = "東京都知事選挙"
        #expect(TextLanguage.judge(block: [item], reading: .simplifiedChinese, pageHasKana: true) == .send)
        #expect(TextLanguage.judge(block: ["東京大学"], reading: .simplifiedChinese, pageHasKana: true) == .send)
        // Without kana on the page a Simplified Chinese item is kept.
        #expect(TextLanguage.judge(block: ["国务院"], reading: .simplifiedChinese, pageHasKana: false) == .keep)
        // A digits-only item stays kept on a kana page.
        #expect(TextLanguage.judge(block: ["2026"], reading: .simplifiedChinese, pageHasKana: true) == .keep)
        // Under en, the kana rule does not apply: the item is sent anyway.
        #expect(TextLanguage.judge(block: [item], reading: .english, pageHasKana: false) == .send)
    }
}
