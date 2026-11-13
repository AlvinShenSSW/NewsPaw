import Foundation

/// What the status section of a source says (spec N03, ux S13): a pure
/// function of the source's columns.
public enum SourceStatus: Sendable, Hashable {
    /// Paused by the owner; the last success time, if any.
    case paused(lastSuccess: Date?)
    /// The last collection failed. `reason` is `nil` for a stored code this
    /// build does not know.
    case failing(reason: CollectionFailure?, lastSuccess: Date?)
    /// The last collection succeeded.
    case working(lastSuccess: Date)
    /// Never collected.
    case notUpdatedYet

    /// The status of a source with these columns; `nil` for a web-page
    /// source, which is never collected. Paused comes first, then a stored
    /// failure, then a success.
    public init?(kind: SourceKind, paused: Bool, lastError: String?, lastSuccessAt: Date?) {
        guard kind != .webpage else { return nil }
        if paused {
            self = .paused(lastSuccess: lastSuccessAt)
        } else if let lastError {
            self = .failing(reason: CollectionFailure(code: lastError), lastSuccess: lastSuccessAt)
        } else if let lastSuccessAt {
            self = .working(lastSuccess: lastSuccessAt)
        } else {
            self = .notUpdatedYet
        }
    }
}

/// A source with what its row and its settings show, read in one
/// transaction by `Library.sourceSummaries()`.
public struct SourceSummary: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let categoryID: UUID
    public let kind: SourceKind
    /// The address's normal form.
    public let address: String
    public let name: String
    public let siteURL: String?
    public let paused: Bool
    public let autoTranslate: AutoTranslate
    public let bodyMode: BodyMode
    public let translatePage: Bool
    /// Articles not read.
    public let unreadCount: Int
    /// Every stored article, starred ones included.
    public let articleCount: Int
    /// The newest of the articles' published times (first-seen time for an
    /// article without one).
    public let newestItemAt: Date?
    public let lastSuccessAt: Date?
    /// `nil` for a web-page source.
    public let status: SourceStatus?

    /// Whether the source is read as a feed (feed, GitHub, Hugging Face),
    /// rather than opened as a web page.
    public var isFeedLike: Bool {
        kind != .webpage
    }
}

/// The fields of a source the owner can change, each `nil` when unchanged.
public struct SourceChanges: Sendable, Hashable {
    public var name: String?
    public var categoryID: UUID?
    /// Feed-like sources only.
    public var paused: Bool?
    /// Feed-like sources only.
    public var autoTranslate: AutoTranslate?
    /// Feed-like sources only.
    public var bodyMode: BodyMode?
    /// Web-page sources only.
    public var translatePage: Bool?

    public init(
        name: String? = nil, categoryID: UUID? = nil, paused: Bool? = nil, autoTranslate: AutoTranslate? = nil,
        bodyMode: BodyMode? = nil, translatePage: Bool? = nil
    ) {
        self.name = name
        self.categoryID = categoryID
        self.paused = paused
        self.autoTranslate = autoTranslate
        self.bodyMode = bodyMode
        self.translatePage = translatePage
    }
}

/// A source already stored at an address, for the duplicate message.
public struct ExistingSource: Sendable, Hashable {
    public let sourceID: UUID
    public let name: String
    public let categoryID: UUID
    public let categoryName: String
}
