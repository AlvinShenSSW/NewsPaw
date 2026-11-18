import Foundation

/// What a stored overview row says (spec N07; RD23 decision 7). Stored in
/// `overview.state`.
///
/// Adding a case needs a schema migration, even an empty one.
public enum OverviewState: String, Sendable, Hashable, CaseIterable {
    /// The summary and its highlights.
    case done
    /// The model's reply could not be used; the reason is kept in `error`
    /// as a `TranslationFailure` raw value.
    case failed
}

/// One highlight of an overview: the article it names and one sentence
/// about it, as the app wrote them (decision 5).
public struct OverviewHighlight: Sendable, Hashable, Codable {
    public let articleID: UUID
    public let text: String

    public init(articleID: UUID, text: String) {
        self.articleID = articleID
        self.text = text
    }

    enum CodingKeys: String, CodingKey {
        case articleID = "article_id"
        case text
    }
}

/// A stored overview as the screens read it (decision 12). Its highlights
/// are those whose article still exists and still belongs to the category
/// (invariant 3).
public struct StoredOverview: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let categoryID: UUID
    /// The local day, `yyyy-MM-dd` (`OverviewDay.key(for:calendar:)`).
    public let day: String
    public let locale: ReadingLocale
    public let state: OverviewState
    /// The summary; `nil` unless `done`.
    public let text: String?
    public let highlights: [OverviewHighlight]
    /// How many articles the request held.
    public let articleCount: Int
    /// The model's name; `nil` when no model answered.
    public let model: String?
    /// The reason, with `failed` only.
    public let failure: TranslationFailure?
    /// When the row was written: the footnote's time.
    public let createdAt: Date

    public init(
        id: UUID, categoryID: UUID, day: String, locale: ReadingLocale, state: OverviewState, text: String?,
        highlights: [OverviewHighlight], articleCount: Int, model: String?, failure: TranslationFailure?, createdAt: Date
    ) {
        self.id = id
        self.categoryID = categoryID
        self.day = day
        self.locale = locale
        self.state = state
        self.text = text
        self.highlights = highlights
        self.articleCount = articleCount
        self.model = model
        self.failure = failure
        self.createdAt = createdAt
    }
}
