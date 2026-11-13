import Foundation

/// Which articles a list shows (spec N05; RD09 decision 1).
public enum ArticleScope: Sendable, Hashable {
    /// Every article of the library.
    case library
    /// The articles of one category's sources.
    case category(UUID)
    /// The articles of one source.
    case source(UUID)
    /// Every starred article.
    case starred
}

/// Which of a scope's articles a list shows.
public enum ArticleFilter: Sendable, Hashable, CaseIterable {
    /// Unread articles only.
    case unread
    /// Every article.
    case all
}

/// Where a row stands in the list order (RD09 decision 2): the next page
/// starts after it. The values are the stored ones, compared as stored.
public struct ArticlePosition: Sendable, Hashable {
    let shownAt: String
    let firstSeenAt: String
    let rowID: Int64
}

/// One article as a list row and the interim reading screen show it, read
/// by `Library.articleRows` and `Library.article(_:)`. It never carries the
/// stored HTML.
public struct ArticleRow: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let sourceID: UUID
    public let sourceName: String
    public let title: String?
    public let excerpt: String?
    public let author: String?
    /// The article's link, when the feed gave one.
    public let link: String?
    /// The address of the image the feed named for the item.
    public let imageAddress: String?
    /// The time the row shows: the published time, else the first-seen time.
    public let shownAt: Date
    public var isRead: Bool
    public var isStarred: Bool
    /// Where the row stands in the list order.
    public let position: ArticlePosition
}
