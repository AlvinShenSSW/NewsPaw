import Foundation

/// A feed as the parser read it (spec N03, N04). Every field a feed may omit
/// is optional; nothing in it has been fetched or executed.
public struct ParsedFeed: Sendable, Hashable {
    public enum Format: String, Sendable, Hashable {
        /// RSS 0.9x / 2.0.
        case rss
        /// RSS 1.0 (RDF).
        case rdf
        /// Atom 1.0.
        case atom
        /// JSON Feed.
        case json
    }

    public var format: Format
    /// The feed's title, as text.
    public var title: String?
    /// The site the feed belongs to, resolved against the final address.
    public var siteURL: String?
    /// The items that could be identified, in feed order.
    public var items: [ParsedItem]
    /// Whether the document was read to its end. A document that stops being
    /// well-formed part-way keeps the items completed before that point and
    /// is not complete.
    public var isComplete: Bool

    public init(format: Format, title: String?, siteURL: String?, items: [ParsedItem], isComplete: Bool) {
        self.format = format
        self.title = title
        self.siteURL = siteURL
        self.items = items
        self.isComplete = isComplete
    }
}

/// One item of a feed.
public struct ParsedItem: Sendable, Hashable {
    /// The item's identity: the feed's identifier, else the link, else
    /// `sha256:` and the digest of the raw title and raw date.
    public var externalID: String
    /// The item's link: an absolute http or https address.
    public var url: String?
    /// The title, as text.
    public var title: String?
    /// Up to 500 characters of text from the description, else from the
    /// content.
    public var excerpt: String?
    public var author: String?
    /// An image for the item: an absolute http or https address.
    public var imageURL: String?
    /// The published time the feed gives, when it is parseable. Whether it
    /// lies in the future is decided by the collector, which knows the moment
    /// of collection.
    public var publishedAt: Date?
    /// The feed's content as HTML, else its description; plain text is
    /// escaped. Stored as text and never executed.
    public var contentHTML: String?

    public init(
        externalID: String, url: String? = nil, title: String? = nil, excerpt: String? = nil, author: String? = nil,
        imageURL: String? = nil, publishedAt: Date? = nil, contentHTML: String? = nil
    ) {
        self.externalID = externalID
        self.url = url
        self.title = title
        self.excerpt = excerpt
        self.author = author
        self.imageURL = imageURL
        self.publishedAt = publishedAt
        self.contentHTML = contentHTML
    }
}

/// The raw values of one item, before identity, resolution and reduction.
/// Shared by the XML and JSON readers so that both apply the same rules.
struct RawItem {
    enum TextKind {
        /// Plain text: kept as written.
        case text
        /// HTML: reduced to text for titles and excerpts, kept for content.
        case html
    }

    var identifier: String?
    /// Whether `identifier` may be used as the link (RSS `guid` not marked
    /// otherwise).
    var identifierIsPermalink = false
    var link: String?
    var title: String?
    var titleKind: TextKind = .html
    var summary: String?
    var summaryKind: TextKind = .html
    var content: String?
    var contentKind: TextKind = .html
    var author: String?
    /// Dublin Core's creator, used when there is no author.
    var creator: String?
    var date: String?
    var fallbackDate: String?
    var enclosureImage: String?
    var thumbnail: String?
    var mediaImage: String?
    var jsonImage: String?

    /// The item as stored, or `nil` when it has no identity.
    func resolved(against base: URL) -> ParsedItem? {
        let url = Self.webAddress(link, base: base)
            ?? (identifierIsPermalink ? Self.webAddress(identifier, base: nil) : nil)
        let trimmedIdentifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawTitle = Self.present(title)
        let rawDate = Self.present(date) ?? Self.present(fallbackDate)
        let externalID: String
        if let trimmedIdentifier, !trimmedIdentifier.isEmpty {
            externalID = trimmedIdentifier
        } else if let link = Self.webAddress(link, base: base) {
            externalID = link
        } else if rawTitle != nil || rawDate != nil {
            externalID = ItemIdentity.hash(title: rawTitle, date: rawDate)
        } else {
            return nil
        }

        let titleText = title.map { titleKind == .html ? HTMLText.reduce($0) : HTMLText.collapseWhitespace($0) }
        var excerpt: String?
        if let summary, !summary.isEmpty {
            excerpt = summaryKind == .html ? HTMLText.excerpt(fromHTML: summary) : HTMLText.excerpt(fromText: summary)
        }
        if excerpt == nil, let content, !content.isEmpty {
            excerpt = contentKind == .html ? HTMLText.excerpt(fromHTML: content) : HTMLText.excerpt(fromText: content)
        }
        var contentHTML: String?
        if let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            contentHTML = contentKind == .html ? content : HTMLText.escape(content)
        } else if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            contentHTML = summaryKind == .html ? summary : HTMLText.escape(summary)
        }
        let publishedAt = date.flatMap(FeedDate.parse) ?? fallbackDate.flatMap(FeedDate.parse)
        let image = [enclosureImage, thumbnail, mediaImage, jsonImage].lazy.compactMap { Self.webAddress($0, base: base) }.first

        return ParsedItem(
            externalID: externalID,
            url: url,
            title: titleText.flatMap { $0.isEmpty ? nil : $0 },
            excerpt: excerpt,
            author: [author, creator].lazy.compactMap { $0.map(HTMLText.collapseWhitespace) }.first { !$0.isEmpty },
            imageURL: image,
            publishedAt: publishedAt,
            contentHTML: contentHTML
        )
    }

    /// `text` unchanged, unless it is missing or only white space.
    private static func present(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// `text` as an absolute http or https address, resolved against `base`
    /// when it is relative; `nil` for any other scheme or for an address
    /// that carries a user name or password.
    static func webAddress(_ text: String?, base: URL?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let url = URL(string: text, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false, url.user == nil, url.password == nil
        else { return nil }
        return url.absoluteString
    }
}
