import NewsPawKit
import SwiftUI

/// An article's blocks laid out natively (spec N05; ux S4 and section 5;
/// RD11 decision 8): a lazy stack of paragraphs, headings, images, code and
/// rules, in the reading settings' size, spacing and face. It takes the
/// blocks, the settings, the images of the opening and what a tapped link
/// does, and nothing of a library row, so that a body from another place
/// (RD12's reader mode) is laid out by the same view.
///
/// It sits inside the caller's vertical scroll view. A tapped link goes to
/// `openLink` and nowhere else; a tapped image opens the full-screen viewer.
///
/// With a translation (RD15 decision 11), a translated text block shows its
/// translation in its own kind and place (Translation), or its translation
/// followed by its original in the secondary colour (Side by Side); other
/// blocks show their originals, as every block does in Original.
struct BlocksView: View {
    let blocks: [ArticleBlock]
    let settings: ReadingSettings
    let images: BodyImageSession
    var translation: BlockTranslation?
    let openLink: (URL) -> Void

    @ScaledMetric(relativeTo: .body) private var scaledBodySize = 17.0
    @State private var viewed: ViewedImage?

    var body: some View {
        let metrics = ReadingMetrics(scaledBodySize: scaledBodySize, settings: settings)
        // Each block brings the space above it, rather than the stack
        // putting one between every two: an image that is not drawn then
        // leaves no gap of its own.
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(blocks.indices, id: \.self) { index in
                BlockRow(
                    block: blocks[index], index: index, metrics: metrics, images: images,
                    spaceAbove: index == 0 ? 0 : metrics.blockSpacing,
                    translated: translation?.mode == .original ? nil : translation?.text(index),
                    mode: translation?.mode ?? .original, language: translation?.language,
                    originalLanguage: translation?.originalLanguage(index)
                ) { image in
                    viewed = image
                }
            }
        }
        // Each block is a place the caller's scroll view can report and
        // return to, by its index.
        .scrollTargetLayout()
        .environment(\.openURL, OpenURLAction { url in
            openLink(url)
            return .handled
        })
        .fullScreenCover(item: $viewed) { image in
            ImageViewer(image: image)
        }
    }
}

/// Where each laid-out block row stands in the reading screen's scroll
/// content, and the content's visible top edge (RD15 decision 11): what a
/// display-mode switch keeps at the top. A plain reference, not observed:
/// written as rows lay out and as the reader scrolls, read at a switch.
@MainActor
final class BlockRowFrames {
    /// The coordinate space of the scroll content the frames are in.
    nonisolated static let space = "reading.content"

    private(set) var frames: [Int: CGRect] = [:]
    /// The content's y at the visible top edge, under the bars.
    var visibleTop = 0.0

    func set(_ frame: CGRect, of block: Int) {
        frames[block] = frame
    }

    func remove(_ block: Int) {
        frames[block] = nil
    }

    /// The block whose row holds `top`: its row begins at or above it and
    /// ends below it (a point of tolerance, so that a row set exactly at
    /// the top is still the one at the top).
    func block(atTop top: Double) -> Int? {
        frames.filter { $0.value.minY <= top + 1 && $0.value.maxY > top + 1 }.map(\.key).min()
    }

    /// The reader's place at `top`: the block at the top, or none when the
    /// top is above every laid-out row (the header); unknown (`nil`) while
    /// no row is laid out or the top is below them all.
    struct Place: Equatable {
        let block: Int?
    }

    /// The place last told to the reading model.
    var reported: Place?

    func place(atTop top: Double) -> Place? {
        if let block = block(atTop: top) {
            return Place(block: block)
        }
        guard let first = frames.values.map(\.minY).min(), top + 1 < first else { return nil }
        return Place(block: nil)
    }
}

extension EnvironmentValues {
    /// The reading screen's row frames; none elsewhere (reader mode).
    @Entry var blockRowFrames: BlockRowFrames?
}

/// How a body's blocks show its translation (RD15 decisions 11 and 13).
struct BlockTranslation {
    let mode: ReadingDisplayMode
    /// The reading language's tag: what a translated text is read in.
    let language: String
    /// A text block's translation, or `nil` while it shows its original.
    let text: (Int) -> String?
    /// The recognizer's language of a block's original, for VoiceOver.
    let originalLanguage: (Int) -> String?
}

/// One block where it stands: behind its quote bars, indented by its lists,
/// with its marker.
private struct BlockRow: View {
    let block: ArticleBlock
    let index: Int
    let metrics: ReadingMetrics
    let images: BodyImageSession
    /// The space between this block and the one before it.
    let spaceAbove: Double
    /// The block's translation, when it is shown (not in Original).
    let translated: String?
    let mode: ReadingDisplayMode
    let language: String?
    let originalLanguage: String?
    let view: (ViewedImage) -> Void
    /// The block is an image that is not drawn: it takes no room at all.
    @State private var isUndrawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.blockRowFrames) private var rowFrames

    private static let quoteBarWidth = 3.0
    private static let quoteStep = 12.0

    var body: some View {
        if isUndrawn || isKnownUndrawn {
            Color.clear
                .frame(height: 0)
                .accessibilityHidden(true)
        } else {
            row.padding(.top, spaceAbove)
                // A block that becomes translated fades in (ux section 5),
                // not under Reduce Motion.
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: translated)
                .onGeometryChange(for: CGRect.self) { geometry in
                    geometry.frame(in: .named(BlockRowFrames.space))
                } action: { frame in
                    rowFrames?.set(frame, of: index)
                }
                .onDisappear {
                    rowFrames?.remove(index)
                }
        }
    }

    /// An image this opening has already found to be a pixel.
    private var isKnownUndrawn: Bool {
        if case .image(let image) = block.kind {
            return images.undrawn.contains(image.url)
        }
        return false
    }

    private var row: some View {
        ListRowLayout(columns: (0..<block.listDepth).map { level in
            metrics.markerColumnWidth(for: block.widestMarkers.indices.contains(level) ? block.widestMarkers[level] : .bullet)
        }) {
            ForEach(0..<block.listDepth, id: \.self) { level in
                markerColumn(isLast: level == block.listDepth - 1)
            }
            content
        }
        .padding(.leading, Self.quoteStep * Double(block.quoteDepth))
        .background(alignment: .leading) {
            // One bar per quote, as tall as the block.
            HStack(spacing: Self.quoteStep - Self.quoteBarWidth) {
                ForEach(0..<block.quoteDepth, id: \.self) { _ in
                    Theme.hairline.frame(width: Self.quoteBarWidth)
                }
            }
            .accessibilityHidden(true)
        }
    }

    /// A list's marker column: the item's marker at its trailing end, on
    /// the first line, in the innermost list's column; empty otherwise. A
    /// marker is drawn smaller rather than cut when its column was narrowed
    /// (`ListRowLayout`).
    @ViewBuilder
    private func markerColumn(isLast: Bool) -> some View {
        if isLast, let marker = block.marker {
            Text(verbatim: Self.text(of: marker))
                .font(metrics.font(size: metrics.bodySize))
                .lineHeight(.exact(points: metrics.lineHeight(size: metrics.bodySize, isMostlyCJK: false)))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.1)
                .accessibilityIdentifier(AccessibilityID.readingMarker(index))
                .padding(.trailing, ReadingMetrics.markerGap)
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            Color.clear.frame(height: 0)
        }
    }

    private static func text(of marker: ArticleBlock.ListMarker) -> String {
        switch marker {
        case .bullet: ReadingMetrics.bullet
        case .number(let number): "\(number)."
        }
    }

    @ViewBuilder
    private var content: some View {
        switch block.kind {
        case .paragraph(let runs):
            let size = block.isCaption ? metrics.captionSize : metrics.bodySize
            shown(runs, size: size, weight: .regular, isSecondary: block.isCaption || block.quoteDepth > 0)
        case .heading(let level, let runs):
            shown(runs, size: metrics.headingSize(level: level), weight: .semibold, isSecondary: block.quoteDepth > 0)
                .accessibilityAddTraits(.isHeader)
        case .image(let image):
            BodyImageView(image: image, index: index, session: images, view: view) {
                isUndrawn = true
            }
        case .code(let code):
            ScrollView(.horizontal) {
                Text(verbatim: code)
                    .font(metrics.codeFont())
                    .lineHeight(.exact(points: metrics.lineHeight(size: metrics.codeSize, isMostlyCJK: false)))
                    .foregroundStyle(Theme.text)
                    .fixedSize()
                    .textSelection(.enabled)
                    .padding(Theme.Spacing.medium)
                    .accessibilityIdentifier(AccessibilityID.readingBlock(index))
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.thumbnail))
            // The surface is the page's colour in light appearance: the
            // hairline is what shows the box.
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.thumbnail).strokeBorder(Theme.hairline, lineWidth: 1)
            }
            .accessibilityIdentifier(AccessibilityID.readingCodeBox(index))
        case .rule:
            Theme.hairline
                .frame(height: 1)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
        }
    }

    /// A text block as the mode shows it: its translation; its translation
    /// over its original in the secondary colour; or its original.
    @ViewBuilder
    private func shown(_ runs: [InlineRun], size: Double, weight: Font.Weight, isSecondary: Bool) -> some View {
        if let translated, mode == .translation {
            translation(translated, size: size, weight: weight, isSecondary: isSecondary)
                .transition(.opacity)
        } else if let translated, mode == .sideBySide {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                translation(translated, size: size, weight: weight, isSecondary: isSecondary)
                text(runs, size: size, weight: weight, isSecondary: true, identifier: AccessibilityID.readingOriginalBlock(index))
            }
            .transition(.opacity)
        } else {
            text(runs, size: size, weight: weight, isSecondary: isSecondary)
        }
    }

    /// A model's text: drawn verbatim, never parsed, so no Markdown, HTML,
    /// link or style reaches the screen (decision 13). It carries the
    /// reading language for VoiceOver and, for Chinese and Japanese, for
    /// its forms.
    private func translation(_ text: String, size: Double, weight: Font.Weight, isSecondary: Bool) -> some View {
        let typesets = language == ReadingLocale.simplifiedChinese.rawValue || language == ReadingLocale.japanese.rawValue
        return Text(verbatim: text)
            .font(metrics.font(size: size, weight: weight))
            .lineHeight(.exact(points: metrics.lineHeight(size: size, isMostlyCJK: ArticleBlocks.isMostlyCJK(text))))
            .typesettingLanguage(Locale.Language(identifier: language ?? "en"), isEnabled: typesets)
            .foregroundStyle(isSecondary ? Theme.secondaryText : Theme.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .speechLanguage(language)
            .accessibilityIdentifier(AccessibilityID.readingBlock(index))
    }

    private func text(
        _ runs: [InlineRun], size: Double, weight: Font.Weight, isSecondary: Bool, identifier: String? = nil
    ) -> some View {
        let plain = runs.map(\.text).joined()
        let isMostlyCJK = ArticleBlocks.isMostlyCJK(plain)
        return Text(Self.attributed(runs))
            .font(metrics.font(size: size, weight: weight))
            .lineHeight(.exact(points: metrics.lineHeight(size: size, isMostlyCJK: isMostlyCJK)))
            // A block with kana is drawn in the Japanese forms of its
            // characters (assumption A8).
            .typesettingLanguage(Locale.Language(identifier: "ja"), isEnabled: ArticleBlocks.containsKana(plain))
            .foregroundStyle(isSecondary ? Theme.secondaryText : Theme.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .speechLanguage(originalLanguage)
            .accessibilityIdentifier(identifier ?? AccessibilityID.readingBlock(index))
    }

    /// The runs as one attributed string: bold, italic and code as inline
    /// intents on the block's font, a link underlined (the system draws it
    /// in the tint colour).
    private static func attributed(_ runs: [InlineRun]) -> AttributedString {
        var text = AttributedString()
        for run in runs {
            var part = AttributedString(run.text)
            var intent: InlinePresentationIntent = []
            if run.isBold {
                intent.insert(.stronglyEmphasized)
            }
            if run.isItalic {
                intent.insert(.emphasized)
            }
            if run.isCode {
                intent.insert(.code)
            }
            if !intent.isEmpty {
                part.inlinePresentationIntent = intent
            }
            if let link = run.link {
                part.link = link
                part.underlineStyle = .single
            }
            text.append(part)
        }
        return text
    }
}

/// A block in its lists: a marker column for each list it stands in, from
/// the outermost, then the block, top-aligned. Each column is as wide as it
/// asks (`ReadingMetrics.markerColumnWidth`), so that the blocks of one list
/// have their text at one edge. Columns that together would take more than
/// `maximumShare` of the width — numbers of many digits in nested lists at
/// the largest text sizes — are narrowed in proportion, and their markers
/// drawn smaller to fit.
private struct ListRowLayout: Layout {
    /// The width each column asks for; one subview per column, then the
    /// block.
    let columns: [Double]

    static let maximumShare = 0.5

    private func widths(within width: CGFloat?) -> [Double] {
        let total = columns.reduce(0, +)
        guard let width, total > 0, total > width * Self.maximumShare else { return columns }
        let factor = width * Self.maximumShare / total
        return columns.map { $0 * factor }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let block = subviews.last else { return .zero }
        let widths = widths(within: proposal.width)
        let indent = widths.reduce(0, +)
        let size = block.sizeThatFits(ProposedViewSize(width: proposal.width.map { max($0 - indent, 0) }, height: nil))
        var height = size.height
        for (column, subview) in zip(widths, subviews.dropLast()) {
            height = max(height, subview.sizeThatFits(ProposedViewSize(width: column, height: nil)).height)
        }
        return CGSize(width: proposal.width ?? indent + size.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let block = subviews.last else { return }
        var x = bounds.minX
        for (column, subview) in zip(widths(within: bounds.width), subviews.dropLast()) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: column, height: nil))
            x += column
        }
        block.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: max(bounds.maxX - x, 0), height: nil))
    }
}

extension View {
    /// The language VoiceOver reads this text in (RD15 decision 13): the
    /// environment's locale, which SwiftUI passes to the accessibility
    /// element as its speech language (assumption A1, measured on the iOS
    /// 27 simulator: a `languageIdentifier` on the attributed string did not
    /// reach it). Nothing changes without a language.
    @ViewBuilder
    func speechLanguage(_ language: String?) -> some View {
        if let language {
            environment(\.locale, Locale(identifier: language))
        } else {
            self
        }
    }
}
