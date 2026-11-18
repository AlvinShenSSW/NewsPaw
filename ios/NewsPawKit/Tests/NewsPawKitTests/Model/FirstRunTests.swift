import Foundation
@testable import NewsPawKit
import Testing

/// RD21 decisions 4 and 6: the reading language preselected from the
/// system's languages, and the suggested categories' icons.
@Suite("First run")
struct FirstRunTests {
    @Test(
        "the reading language follows the system's first language: Chinese, Japanese, English, else Simplified Chinese",
        arguments: [
            (["zh-Hans-CN"], ReadingLocale.simplifiedChinese),
            (["zh-Hant-TW"], .simplifiedChinese),
            (["zh-HK"], .simplifiedChinese),
            (["zh"], .simplifiedChinese),
            (["ja-JP"], .japanese),
            (["ja"], .japanese),
            (["en-GB"], .english),
            (["en"], .english),
            (["de-DE"], .simplifiedChinese),
            ([], .simplifiedChinese),
            // The first language decides, not a later one.
            (["de-DE", "en-GB"], .simplifiedChinese),
            (["ja-JP", "zh-Hans-CN"], .japanese),
            // A language code is matched whole, not as a prefix of another.
            (["zha"], .simplifiedChinese),
            (["jam"], .simplifiedChinese),
            (["eng"], .simplifiedChinese),
            (["EN_us"], .english),
        ] as [([String], ReadingLocale)]
    )
    func preselection(languages: [String], expected: ReadingLocale) {
        #expect(ReadingLocale.preselected(from: languages) == expected)
    }

    @Test("each suggested category has its icon: a globe, three Asia-Pacific globes, a laptop, a chip")
    func icons() {
        let icons = SuggestedSourceGroup.allCases.map { ($0, $0.icon) }
        #expect(icons.map(\.0) == [.world, .japan, .australia, .china, .tech, .ai])
        #expect(icons.map(\.1) == [.globe, .globeAsia, .globeAsia, .globeAsia, .laptop, .cpu])
    }
}
