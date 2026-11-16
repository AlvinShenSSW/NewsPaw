import Foundation
@testable import NewsPawKit
import Testing

/// RD14 decision 3: detection on the device. Criteria 4 and 15. Every case
/// here was measured to give the same answer on macOS 27, the iOS 27
/// simulator and the iOS 26.5 simulator (assumption A2), and the suite runs
/// on all three.
@Suite("Text language")
struct TextLanguageTests {
    typealias Decision = TextLanguage.Decision

    static let simplifiedTitle = "国务院发布新的数据安全管理条例"
    static let simplifiedExcerpt = "条例明确了数据处理者的责任，并将于明年一月起施行。"
    static let traditionalTitle = "台灣半導體產業持續擴張"
    static let traditionalExcerpt = "業者表示，新廠將於明年開始量產，並創造數千個工作機會。"
    static let japaneseTitle = "政府、新たな経済対策を発表"
    static let japaneseExcerpt = "政府は物価高への対応として、新たな経済対策をまとめた。"
    static let kanjiOnlyTitle = "東京都知事選挙告示"
    static let kanaExcerpt = "東京都知事選挙が告示され、過去最多の候補者が立候補を届け出た。"
    static let englishTitle = "Apple announces new MacBook Pro"
    static let englishExcerpt = "The new laptops feature faster chips and longer battery life."

    /// Criterion 4's table: (case, reading, title, excerpt, expected).
    static let table: [(String, ReadingLocale, String?, String?, Decision)] = [
        // Reading zh-Hans.
        ("Simplified", .simplifiedChinese, simplifiedTitle, simplifiedExcerpt, .keep),
        ("Traditional", .simplifiedChinese, traditionalTitle, traditionalExcerpt,
         .converted(title: "台湾半导体产业持续扩张", excerpt: "业者表示，新厂将于明年开始量产，并创造数千个工作机会。")),
        ("Traditional title alone", .simplifiedChinese, traditionalTitle, nil, .converted(title: "台湾半导体产业持续扩张", excerpt: nil)),
        ("Simplified with a Latin name", .simplifiedChinese, "苹果发布新款 iPad mini", nil, .keep),
        ("Simplified starting with Latin names", .simplifiedChinese, "GitHub Copilot 推出新功能", nil, .keep),
        ("Traditional with a Latin name", .simplifiedChinese, "微軟 Windows 12 發表會", nil, .converted(title: "微软 Windows 12 发表会", excerpt: nil)),
        ("Japanese with kana", .simplifiedChinese, japaneseTitle, japaneseExcerpt, .send),
        ("kanji-only Japanese title, excerpt in kana", .simplifiedChinese, kanjiOnlyTitle, kanaExcerpt, .send),
        ("kanji-only Japanese title alone", .simplifiedChinese, kanjiOnlyTitle, nil, .send),
        ("English", .simplifiedChinese, englishTitle, englishExcerpt, .send),
        ("Chinese title, English excerpt", .simplifiedChinese, "苹果发布新款笔记本电脑", englishExcerpt, .send),
        ("digits and symbols only", .simplifiedChinese, "2026 — 11/16 #42", "€ 3.50 + 7%", .keep),
        ("no title, no excerpt", .simplifiedChinese, nil, nil, .keep),
        // Reading ja.
        ("Japanese with kana", .japanese, japaneseTitle, japaneseExcerpt, .keep),
        ("Japanese with kana and a Latin name", .japanese, "Apple、新型iPhoneを発表", "Appleは新しいiPhoneを発表した。", .keep),
        ("kanji-only title, excerpt in kana", .japanese, kanjiOnlyTitle, kanaExcerpt, .keep),
        ("Chinese", .japanese, simplifiedTitle, simplifiedExcerpt, .send),
        ("Traditional Chinese", .japanese, traditionalTitle, traditionalExcerpt, .send),
        ("English", .japanese, englishTitle, englishExcerpt, .send),
        // Reading en.
        ("English", .english, englishTitle, englishExcerpt, .keep),
        ("short English title", .english, "Rust 2.0 released", nil, .keep),
        ("Chinese with Latin names", .english, "Nintendo Switch 2 发布", nil, .send),
        ("French", .english, "Le gouvernement annonce un nouveau plan pour l'économie",
         "Le plan prévoit des investissements dans les énergies renouvelables.", .send),
        ("German", .english, "Die Regierung kündigt einen neuen Plan an", "Der Plan sieht Investitionen in erneuerbare Energien vor.", .send),
        ("Russian", .english, "Правительство объявило новый план", nil, .send),
        ("Japanese", .english, japaneseTitle, nil, .send),
    ]

    @Test("criterion 4: the judgement table", arguments: table.indices)
    func judgementTable(_ index: Int) {
        let (name, reading, title, excerpt, expected) = Self.table[index]
        let judgement = TextLanguage.judge(title: title, excerpt: excerpt, reading: reading)
        #expect(judgement.decision == expected, "\(reading.rawValue): \(name)")
    }

    @Test("an article is sent whole: every text with a letter, the title first")
    func sentWhole() {
        let judgement = TextLanguage.judge(title: Self.kanjiOnlyTitle, excerpt: Self.kanaExcerpt, reading: .simplifiedChinese)
        #expect(judgement.decision == .send)
        #expect(judgement.textsToSend == [Self.kanjiOnlyTitle, Self.kanaExcerpt])
        let digits = TextLanguage.judge(title: Self.englishTitle, excerpt: "2026 — 42", reading: .simplifiedChinese)
        #expect(digits.textsToSend == [Self.englishTitle], "a text without a letter is not sent")
        let noTitle = TextLanguage.judge(title: "  ", excerpt: Self.englishExcerpt, reading: .simplifiedChinese)
        #expect(noTitle.title == nil)
        #expect(noTitle.textsToSend == [Self.englishExcerpt])
        #expect(!noTitle.sendsTitle)
    }

    @Test("units by script: Han, kana and other letters one each, a run of Latin letters one, the rest nothing")
    func units() {
        let units = TextLanguage.Units("Apple、新型iPhoneを発表 2026! Привет")
        #expect(units.latin == 2)
        #expect(units.kana == 1)
        #expect(units.han == 4)
        #expect(units.other == 6)
        #expect(!TextLanguage.Units("2026 — 11/16 #42 ★").hasLetter)
        #expect(TextLanguage.Units("l'économie").latin == 2)
    }

    // MARK: - Criterion 15

    @Test("criterion 15: a title of 100,000 characters and one character of 100,000 scalars are cut before judging")
    func cutBeforeJudging() {
        let long = String(repeating: "a", count: 100_000)
        let judged = TextLanguage.judge(title: long, excerpt: long, reading: .english)
        #expect(judged.title?.count == TextLanguage.titleCharacters)
        #expect(judged.excerpt?.count == TextLanguage.excerptCharacters)

        let heavy = "e" + String(repeating: "\u{301}", count: 99_999)
        #expect(heavy.count == 1)
        #expect(heavy.unicodeScalars.count == 100_000)
        let cut = TextLanguage.judge(title: heavy, excerpt: heavy + " more", reading: .simplifiedChinese)
        #expect(cut.title?.unicodeScalars.count == TextLanguage.maximumScalars)
        #expect(cut.excerpt?.unicodeScalars.count == TextLanguage.maximumScalars)
        #expect(cut.textsToSend.allSatisfy { $0.unicodeScalars.count <= TextLanguage.maximumScalars })

        let mixed = String(repeating: "国", count: 299) + heavy + "后面"
        let cutMixed = TextLanguage.cut(mixed, characters: TextLanguage.titleCharacters)
        #expect(cutMixed.unicodeScalars.count <= TextLanguage.maximumScalars)
        #expect(cutMixed.count <= TextLanguage.titleCharacters)
    }

    @Test("the transform converts Traditional and leaves Simplified, kana and Latin as they are")
    func transform() {
        #expect(TextLanguage.simplified("軟體 網路 乾隆") == "软体 网路 干隆")
        #expect(TextLanguage.simplified(Self.simplifiedTitle) == nil)
        #expect(TextLanguage.simplified("ひらがな カタカナ") == nil)
        #expect(TextLanguage.simplified(Self.englishTitle) == nil)
    }
}
