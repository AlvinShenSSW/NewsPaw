import Foundation
import NewsPawKit

/// An open article's body, ready to lay out (RD11 decisions 5 to 7): its
/// blocks, whether they were cut, whether they are a full text or an
/// excerpt, whether they came from the article's page (RD12), and the
/// images of this opening.
struct ReadingContent {
    let blocks: [ArticleBlock]
    /// The input or the block list was past its limit.
    let isCut: Bool
    /// False for an excerpt: the screen then says so and offers the page.
    let isFullText: Bool
    /// The body was extracted from the article's page (RD12): the screen
    /// says "Full text from the original page".
    let isExtracted: Bool
    /// The images of this opening. A new opening has a new one, so an
    /// image that failed is asked for again.
    let images: BodyImageSession

    /// What the conversion gives, before the images of the opening join it.
    struct Converted: Sendable {
        var blocks: [ArticleBlock]
        var isCut: Bool
        var isFullText: Bool
    }

    /// Converts `html`, off the main actor. A body with no block at all
    /// becomes the row's plain excerpt as one paragraph.
    @concurrent
    static func convert(html: String?, excerpt: String?, baseURL: URL?) async -> Converted {
        let converted = ArticleBlocks.make(html: html ?? "", baseURL: baseURL)
        var blocks = converted.blocks
        if blocks.isEmpty, let excerpt, !excerpt.isEmpty {
            blocks = [ArticleBlock(.paragraph([InlineRun(excerpt)]))]
        }
        return Converted(blocks: blocks, isCut: converted.isCut, isFullText: ArticleBlocks.isFullText(blocks))
    }

    /// - Parameter mayLoad: whether the opening's images may still be
    ///   loaded or viewed: false once the reading model is stopped (RD18
    ///   decision 4).
    @MainActor
    init(_ converted: Converted, images: BodyImageLoader, mayLoad: @escaping @MainActor () -> Bool) {
        blocks = converted.blocks
        isCut = converted.isCut
        isFullText = converted.isFullText
        isExtracted = false
        self.images = BodyImageSession(loader: images, mayLoad: mayLoad)
    }

    /// A body extracted from a page (RD12): a full text by the time it is
    /// shown, since only a usable extraction is.
    @MainActor
    init(extracted: ExtractedBody, images: BodyImageLoader, mayLoad: @escaping @MainActor () -> Bool) {
        blocks = extracted.blocks.blocks
        isCut = extracted.blocks.isCut
        isFullText = true
        isExtracted = true
        self.images = BodyImageSession(loader: images, mayLoad: mayLoad)
    }
}

/// The images of one opening of a body: the library's loader, and what this
/// opening has learnt about each address, so that an image that scrolls
/// back in keeps its place, one that failed is not asked for again until
/// the article is opened again, and a tracking pixel stays undrawn.
@MainActor
final class BodyImageSession {
    let loader: BodyImageLoader
    /// False once the workspace of the opening was dropped: no image is
    /// asked for or read from the cache, and the viewer does not open.
    var mayLoad: Bool {
        mayLoadNow()
    }
    private let mayLoadNow: @MainActor () -> Bool
    private(set) var failed: Set<URL> = []
    private(set) var undrawn: Set<URL> = []
    /// The pixel size of each image that arrived.
    private(set) var sizes: [URL: CGSize] = [:]

    init(loader: BodyImageLoader, mayLoad: @escaping @MainActor () -> Bool) {
        self.loader = loader
        mayLoadNow = mayLoad
    }

    func markFailed(_ url: URL) {
        failed.insert(url)
    }

    func markUndrawn(_ url: URL) {
        undrawn.insert(url)
    }

    func setSize(_ size: CGSize, of url: URL) {
        sizes[url] = size
    }
}
