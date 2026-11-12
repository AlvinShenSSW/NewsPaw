/// The group a suggested source is listed under. The app words each one.
public enum SuggestedSourceGroup: String, Sendable, Hashable, CaseIterable {
    case world
    case japan
    case australia
    case china
    case tech
    case ai
}

/// A feed offered in Add source (spec N03; RD05 decision 10).
public struct SuggestedSource: Sendable, Hashable, Identifiable {
    public let group: SuggestedSourceGroup
    /// A proper noun; not localised.
    public let name: String
    /// The feed's address in normal form.
    public let address: String

    public var id: String { address }
}

/// The suggested feeds: each one recorded in `docs/archive/source-strategy.md`
/// as answered by a manual probe on 2026-11-07 UTC, and checked once more by
/// hand through the app before shipping (RD05 criterion 9).
enum SuggestedSources {
    static let all: [SuggestedSource] = [
        SuggestedSource(group: .world, name: "BBC News · World", address: "https://feeds.bbci.co.uk/news/world/rss.xml"),
        SuggestedSource(group: .japan, name: "NHK News", address: "https://news.web.nhk/n-data/conf/na/rss/cat0.xml"),
        SuggestedSource(
            group: .japan, name: "Yahoo! JAPAN News · Domestic", address: "https://news.yahoo.co.jp/rss/topics/domestic.xml"
        ),
        SuggestedSource(
            group: .japan, name: "Yahoo! JAPAN News · Entertainment",
            address: "https://news.yahoo.co.jp/rss/topics/entertainment.xml"
        ),
        SuggestedSource(
            group: .australia, name: "The Guardian · Australia news", address: "https://www.theguardian.com/australia-news/rss"
        ),
        SuggestedSource(
            group: .china, name: "China News Service · Domestic", address: "https://www.chinanews.com.cn/rss/china.xml"
        ),
        SuggestedSource(
            group: .china, name: "China News Service · Culture", address: "https://www.chinanews.com.cn/rss/culture.xml"
        ),
        SuggestedSource(group: .tech, name: "MacRumors", address: "https://feeds.macrumors.com/MacRumors-Front"),
        SuggestedSource(group: .tech, name: "Apple Newsroom", address: "https://www.apple.com/newsroom/rss-feed.rss"),
        SuggestedSource(group: .ai, name: "OpenAI News", address: "https://openai.com/news/rss.xml"),
        SuggestedSource(group: .ai, name: "Hugging Face Blog", address: "https://huggingface.co/blog/feed.xml"),
    ]
}
