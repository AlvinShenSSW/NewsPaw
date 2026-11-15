import Foundation
import NewsPawKit

/// An open article's body, ready to lay out (RD11 decisions 5 to 7): its
/// blocks, whether they were cut, whether they are a full text or an
/// excerpt, and the images of this opening.
struct ReadingContent {
    let blocks: [ArticleBlock]
    /// The input or the block list was past its limit.
    let isCut: Bool
    /// False for an excerpt: the screen then says so and offers the page.
    let isFullText: Bool
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

    @MainActor
    init(_ converted: Converted, images: BodyImageLoader) {
        blocks = converted.blocks
        isCut = converted.isCut
        isFullText = converted.isFullText
        self.images = BodyImageSession(loader: images)
    }
}

/// The images of one opening of a body: the library's loader, and what this
/// opening has learnt about each address, so that an image that scrolls
/// back in keeps its place, one that failed is not asked for again until
/// the article is opened again, and a tracking pixel stays undrawn.
@MainActor
final class BodyImageSession {
    let loader: BodyImageLoader
    private(set) var failed: Set<URL> = []
    private(set) var undrawn: Set<URL> = []
    /// The pixel size of each image that arrived.
    private(set) var sizes: [URL: CGSize] = [:]

    init(loader: BodyImageLoader) {
        self.loader = loader
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
