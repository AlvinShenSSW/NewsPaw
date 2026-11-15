import NewsPawKit
import SwiftUI
import UIKit

/// The sizes, line heights and faces of the reading screen's text (ux
/// section 5; RD11 decision 8), from the body size at the current Dynamic
/// Type size and the three reading settings.
struct ReadingMetrics {
    /// No text is drawn larger than this.
    static let maximumSize = 60.0
    /// The line height of a block is its size times this for text that is
    /// mostly Chinese, Japanese or Korean, and for other text.
    static let cjkLineHeight = 1.7
    static let latinLineHeight = 1.5

    /// The body's size: 17 pt at the default Dynamic Type size, scaled with
    /// it and by the text-size setting.
    let bodySize: Double
    let lineSpacing: Double
    let typeface: ReadingTypeface
    /// The widths of a list marker's parts in the body's face and size: the
    /// widest digit, the full stop after a number, the bullet.
    private let digitWidth: Double
    private let fullStopWidth: Double
    private let bulletWidth: Double

    /// The space between a list marker and its item's text.
    static let markerGap = 6.0

    @MainActor
    init(scaledBodySize: Double, settings: ReadingSettings) {
        bodySize = min(scaledBodySize * settings.textSize.factor, Self.maximumSize)
        lineSpacing = settings.lineSpacing.factor
        typeface = settings.typeface
        let font = ReadingFont.uiFont(typeface, size: bodySize)
        func width(_ text: String) -> Double {
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        digitWidth = (0...9).map { width(String($0)) }.max() ?? 0
        fullStopWidth = width(".")
        bulletWidth = width(Self.bullet)
    }

    /// How a bullet marker is written.
    static let bullet = "•"

    /// The space between two blocks.
    var blockSpacing: Double {
        bodySize * 0.9
    }

    /// The indent of a list level: 20 pt at the default size, wider with
    /// larger text so that a marker has room, up to 32 pt.
    var listIndent: Double {
        20 * min(max(bodySize / 17, 1), 1.6)
    }

    /// The width of the marker column of a list whose widest marker is
    /// `widest`: the indent of a level, or, when it is wider, the marker
    /// with the gap after it. A number is measured as so many of the face's
    /// widest digit, so the column holds every number of that many digits.
    func markerColumnWidth(for widest: ArticleBlock.ListMarker) -> Double {
        let marker: Double
        switch widest {
        case .bullet:
            marker = bulletWidth
        case .number(let number):
            marker = Double(String(number).count) * digitWidth + fullStopWidth
        }
        return max(listIndent, (marker + Self.markerGap).rounded(.up))
    }

    /// The size of a heading of an HTML level: 1 and 2 at 1.3 times the
    /// body, 3 at 1.15, 4 to 6 at the body's size.
    func headingSize(level: Int) -> Double {
        let factor = level <= 2 ? 1.3 : level == 3 ? 1.15 : 1.0
        return min(bodySize * factor, Self.maximumSize)
    }

    var captionSize: Double {
        bodySize * 0.85
    }

    var codeSize: Double {
        bodySize * 0.9
    }

    /// The exact line height of text of `size`.
    func lineHeight(size: Double, isMostlyCJK: Bool) -> Double {
        size * (isMostlyCJK ? Self.cjkLineHeight : Self.latinLineHeight) * lineSpacing
    }

    func font(size: Double, weight: Font.Weight = .regular) -> Font {
        ReadingFont.font(typeface, size: size, weight: weight)
    }

    func codeFont() -> Font {
        .system(size: codeSize, design: .monospaced)
    }
}

/// The reading faces: the system face, or serif — New York, with Songti SC
/// behind it for Chinese when the system has it without a download
/// (assumption A7; the iOS 27 simulator does not).
enum ReadingFont {
    private static let chineseSerifFamily = "Songti SC"

    /// Whether the system can draw Chinese in a serif face now.
    static let hasChineseSerif: Bool = {
        let descriptor = UIFontDescriptor(fontAttributes: [.family: chineseSerifFamily])
        return !descriptor.matchingFontDescriptors(withMandatoryKeys: [.family]).isEmpty
    }()

    /// The regular face of `typeface` at `size` for Latin text, as UIKit
    /// has it: what a list marker is measured in.
    static func uiFont(_ typeface: ReadingTypeface, size: Double) -> UIFont {
        let system = UIFont.systemFont(ofSize: size)
        switch typeface {
        case .sansSerif:
            return system
        case .serif:
            return system.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? system
        }
    }

    static func font(_ typeface: ReadingTypeface, size: Double, weight: Font.Weight) -> Font {
        switch typeface {
        case .sansSerif:
            return .system(size: size, weight: weight)
        case .serif:
            guard hasChineseSerif else {
                return .system(size: size, weight: weight, design: .serif)
            }
            let system = UIFont.systemFont(ofSize: size, weight: weight == .semibold ? .semibold : .regular).fontDescriptor
            let serif = system.withDesign(.serif) ?? system
            let cascaded = serif.addingAttributes([
                .cascadeList: [UIFontDescriptor(fontAttributes: [.family: chineseSerifFamily])],
            ])
            return Font(UIFont(descriptor: cascaded, size: size))
        }
    }
}
