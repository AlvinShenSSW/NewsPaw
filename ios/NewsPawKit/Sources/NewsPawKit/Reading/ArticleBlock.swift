import Foundation

/// A stretch of a paragraph's or heading's text in one style (RD11 decision
/// 2). A line break inside the text is `"\n"`.
public struct InlineRun: Sendable, Hashable {
    public var text: String
    public var isBold: Bool
    public var isItalic: Bool
    public var isCode: Bool
    /// The link the text opens: always `http` or `https`.
    public var link: URL?

    public init(_ text: String, isBold: Bool = false, isItalic: Bool = false, isCode: Bool = false, link: URL? = nil) {
        self.text = text
        self.isBold = isBold
        self.isItalic = isItalic
        self.isCode = isCode
        self.link = link
    }
}

/// An image of an article's body.
public struct ArticleImage: Sendable, Hashable {
    /// Where the image is fetched from: always `http` or `https`.
    public var url: URL
    public var alternativeText: String?
    /// The size its tag declared, in pixels, when it declared both.
    public var declaredSize: DeclaredSize?

    public struct DeclaredSize: Sendable, Hashable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    public init(url: URL, alternativeText: String? = nil, declaredSize: DeclaredSize? = nil) {
        self.url = url
        self.alternativeText = alternativeText
        self.declaredSize = declaredSize
    }
}

/// One block of an article's body as the reading screen lays it out (spec
/// N05; RD11 decision 2): one of five kinds, with where it stands — inside
/// quotes, inside lists, in a figure's caption.
public struct ArticleBlock: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case paragraph([InlineRun])
        /// `level` is the HTML level, 1 to 6, as read.
        case heading(level: Int, [InlineRun])
        case image(ArticleImage)
        /// The text of a `pre`, white space kept.
        case code(String)
        case rule
    }

    /// What marks the first block of a list item.
    public enum ListMarker: Sendable, Hashable {
        case bullet
        case number(Int)
    }

    public var kind: Kind
    /// How many quotes the block stands in, 0 to `ArticleBlocks.maximumDepth`.
    public var quoteDepth: Int
    /// How many lists the block stands in, 0 to `ArticleBlocks.maximumDepth`.
    public var listDepth: Int
    /// The marker of its list item, on the item's first block only.
    public var marker: ListMarker?
    /// For each list the block is laid out in, from the outermost
    /// (`listDepth` of them): the widest marker that list gives, a bullet or
    /// its largest number. The reading screen sizes the list's marker
    /// column for it, so that every item of a list has its text at one edge
    /// and no marker is wider than its column. Beyond
    /// `ArticleBlocks.maximumDepth` the last one is the innermost list's.
    public var widestMarkers: [ListMarker]
    /// Whether the block is text of a `figcaption`.
    public var isCaption: Bool

    /// `widestMarkers` is a bullet for each list when not given.
    public init(
        _ kind: Kind, quoteDepth: Int = 0, listDepth: Int = 0, marker: ListMarker? = nil, widestMarkers: [ListMarker]? = nil,
        isCaption: Bool = false
    ) {
        self.kind = kind
        self.quoteDepth = quoteDepth
        self.listDepth = listDepth
        self.marker = marker
        self.widestMarkers = widestMarkers ?? Array(repeating: .bullet, count: listDepth)
        self.isCaption = isCaption
    }

    /// The block's text without its styles; `nil` for an image or a rule.
    public var plainText: String? {
        switch kind {
        case .paragraph(let runs), .heading(_, let runs): runs.map(\.text).joined()
        case .code(let text): text
        case .image, .rule: nil
        }
    }
}
