import Foundation

/// Which body an opening of an article shows (spec N03, N05; RD12 decision
/// 4), from the source's kind and body option and the feed's own content:
///
/// | Option | Feed's content | Plan |
/// | --- | --- | --- |
/// | Feed content only | any | the feed's |
/// | Automatic, a feed source | full text | the feed's |
/// | Automatic, a feed source | an excerpt | fetch, the excerpt shown meanwhile |
/// | Automatic, GitHub or Hugging Face | any | the feed's |
/// | Always fetch the page | any | fetch, the header alone shown meanwhile |
///
/// An article without an `http` or `https` link is never fetched. A fetch
/// first looks for a usable stored extraction; one that fails ends in the
/// feed's content as RD11 shows it.
public enum BodyPlan: Sendable, Hashable {
    /// The feed's content; nothing is fetched.
    case feed
    /// A usable stored extraction, else the page is fetched. While it is,
    /// the feed's content is shown under the loading line when
    /// `showsFeedMeanwhile`, else the loading line alone.
    case fetch(showsFeedMeanwhile: Bool)

    public static func make(kind: SourceKind, mode: BodyMode, feedIsFullText: Bool, link: URL?) -> BodyPlan {
        guard let link, link.isCollectableAddress else { return .feed }
        switch mode {
        case .feed:
            return .feed
        case .page:
            return .fetch(showsFeedMeanwhile: false)
        case .auto:
            switch kind {
            // Their short entries are the content, and their pages are an
            // interface.
            case .github, .huggingface:
                return .feed
            case .feed, .webpage:
                return feedIsFullText ? .feed : .fetch(showsFeedMeanwhile: true)
            }
        }
    }

    /// Whether an extraction may stand for an article, when it is fetched
    /// and again when it is read from the store: it is an article
    /// (`ArticleBlocks.isArticle`) and has more plain text than the feed's
    /// content, under either option.
    public static func isUsable(_ extracted: [ArticleBlock], over feed: [ArticleBlock]) -> Bool {
        ArticleBlocks.isArticle(extracted) && ArticleBlocks.plainTextLength(extracted) > ArticleBlocks.plainTextLength(feed)
    }
}
