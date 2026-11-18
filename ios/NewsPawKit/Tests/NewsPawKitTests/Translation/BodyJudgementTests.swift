import Foundation
@testable import NewsPawKit
import Testing

/// RD15 decision 4 and assumption A2: each segment is judged by RD14's
/// per-text rule without its length cuts. Criterion 2. The table is the
/// critic's twelve paragraphs under the three reading languages, measured
/// alike on macOS 27, the iOS 26.5 and the iOS 27 simulators
/// (`assumptions.md`).
@Suite("Body judgement")
struct BodyJudgementTests {
    typealias Decision = TextLanguage.SegmentDecision

    /// The paragraph, then what happens to it under `zh-Hans`, `ja` and
    /// `en`.
    static let table: [(String, String, Decision, Decision, Decision)] = [
        ("zh with English product names",
         "苹果公司今天在 WWDC 上发布了 Swift 6.2 和 Xcode 26，新版本支持 Swift Package Manager 的 build plugins，开发者可以通过 GitHub Actions 自动构建。",
         .keep, .send, .send),
        // More Latin words than Chinese characters: sent, and returned as
        // it is (errs towards sending).
        ("zh term-heavy", "使用 Swift Package Manager 的 Xcode build settings", .send, .send, .send),
        ("zh caption", "图片来源：路透社", .keep, .send, .send),
        // Kana in a Chinese paragraph: sent under zh-Hans (errs towards
        // sending); kept under ja (reported: a wrong keep of RD14's kana
        // rule, not of the recognizer).
        ("zh quoting katakana", "索尼今天发布了新款 PlayStation，日本媒体称之为「プレイステーション6」。", .send, .keep, .send),
        ("Traditional", "台灣半導體產業持續擴張，台積電宣布在高雄興建新廠。", .converted("台湾半导体产业持续扩张，台积电宣布在高雄兴建新厂。"), .send, .send),
        ("Japanese", "政府は新たな経済対策を発表し、物価高への対応を強化する方針を示した。", .send, .keep, .send),
        ("kanji-only Japanese", "東京都知事選挙告示", .send, .keep, .send),
        ("English", "The company said on Tuesday that it would cut 5,000 jobs as part of a restructuring plan.", .send, .send, .keep),
        // A Han name in an English paragraph: sent under en (errs towards
        // sending).
        ("English with a Han name", "Chinese President Xi Jinping (习近平) met the delegation in Beijing on Monday.", .send, .send, .send),
        ("Advertisement", "Advertisement", .send, .send, .keep),
        ("French", "Le gouvernement a annoncé mardi un nouveau plan de relance économique.", .send, .send, .send),
        ("English with a shell command", "Run `swift build -c release` and then copy the binary to /usr/local/bin.", .send, .send, .keep),
    ]

    @Test("criterion 2: the critic's twelve paragraphs under the three reading languages", arguments: table.indices)
    func paragraph(_ index: Int) {
        let (name, text, chinese, japanese, english) = Self.table[index]
        #expect(TextLanguage.judge(segment: text, reading: .simplifiedChinese) == chinese, "\(name) zh-Hans")
        #expect(TextLanguage.judge(segment: text, reading: .japanese) == japanese, "\(name) ja")
        #expect(TextLanguage.judge(segment: text, reading: .english) == english, "\(name) en")
    }

    @Test("a segment without a letter is kept; a segment is judged on its first 2,000 scalars and converted whole")
    func cutsAndLetters() {
        #expect(TextLanguage.judge(segment: "— 2026 —", reading: .english) == .keep)
        let traditional = String(repeating: "臺灣的半導體產業持續擴張。", count: 400)
        guard case .converted(let converted) = TextLanguage.judge(segment: traditional, reading: .simplifiedChinese) else {
            Issue.record("not converted")
            return
        }
        #expect(converted.count == traditional.count)
        #expect(converted.hasSuffix("台湾的半导体产业持续扩张。"))
    }

    @Test("RD14's article rule is unchanged by the shared per-text checks")
    func articleRuleUnchanged() {
        #expect(TextLanguage.judge(title: "苹果发布新款 iPad mini", excerpt: nil, reading: .simplifiedChinese).decision == .keep)
        #expect(TextLanguage.judge(title: "国务院发布新的数据安全管理条例", excerpt: "The excerpt in English.", reading: .simplifiedChinese).decision == .send)
        #expect(TextLanguage.judge(title: "台灣半導體產業持續擴張", excerpt: nil, reading: .simplifiedChinese).decision
            == .converted(title: "台湾半导体产业持续扩张", excerpt: nil))
    }
}
