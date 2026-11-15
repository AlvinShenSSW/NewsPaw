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
struct BlocksView: View {
    let blocks: [ArticleBlock]
    let settings: ReadingSettings
    let images: BodyImageSession
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
                    spaceAbove: index == 0 ? 0 : metrics.blockSpacing
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

/// One block where it stands: behind its quote bars, indented by its lists,
/// with its marker.
private struct BlockRow: View {
    let block: ArticleBlock
    let index: Int
    let metrics: ReadingMetrics
    let images: BodyImageSession
    /// The space between this block and the one before it.
    let spaceAbove: Double
    let view: (ViewedImage) -> Void
    /// The block is an image that is not drawn: it takes no room at all.
    @State private var isUndrawn = false

    private static let quoteBarWidth = 3.0
    private static let quoteStep = 12.0

    var body: some View {
        if isUndrawn || isKnownUndrawn {
            Color.clear
                .frame(height: 0)
                .accessibilityHidden(true)
        } else {
            row.padding(.top, spaceAbove)
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
        HStack(alignment: .top, spacing: 0) {
            if block.listDepth > 0 {
                marker
                    .frame(width: metrics.listIndent * Double(block.listDepth), alignment: .trailing)
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

    /// The item's marker at the trailing end of the indent, on the first
    /// line; an empty column for the item's further blocks.
    @ViewBuilder
    private var marker: some View {
        if let marker = block.marker {
            Text(verbatim: Self.text(of: marker))
                .font(metrics.font(size: metrics.bodySize))
                .lineHeight(.exact(points: metrics.lineHeight(size: metrics.bodySize, isMostlyCJK: false)))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize()
                .padding(.trailing, 6)
                .accessibilityIdentifier(AccessibilityID.readingMarker(index))
        } else {
            Color.clear.frame(height: 0)
        }
    }

    private static func text(of marker: ArticleBlock.ListMarker) -> String {
        switch marker {
        case .bullet: "•"
        case .number(let number): "\(number)."
        }
    }

    @ViewBuilder
    private var content: some View {
        switch block.kind {
        case .paragraph(let runs):
            let size = block.isCaption ? metrics.captionSize : metrics.bodySize
            text(runs, size: size, weight: .regular, isSecondary: block.isCaption || block.quoteDepth > 0)
        case .heading(let level, let runs):
            text(runs, size: metrics.headingSize(level: level), weight: .semibold, isSecondary: block.quoteDepth > 0)
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

    private func text(_ runs: [InlineRun], size: Double, weight: Font.Weight, isSecondary: Bool) -> some View {
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
            .accessibilityIdentifier(AccessibilityID.readingBlock(index))
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
