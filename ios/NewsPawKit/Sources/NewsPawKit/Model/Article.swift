import Foundation
import GRDB

/// Where an article body came from (spec N05). Adding a case needs a schema
/// migration, even an empty one.
enum BodyOrigin: String, Sendable, Codable, CaseIterable {
    case feed
    case extracted
}

/// An article of one library (spec N04, section 4). Its operations become
/// public in RD05; until then only the package and its tests use it.
struct Article: Sendable, Hashable {
    var id: UUID
    var sourceID: UUID
    var externalID: String
    var url: String?
    var title: String?
    var excerpt: String?
    var author: String?
    var imageURL: String?
    var publishedAt: Date?
    var firstSeenAt: Date
    var language: String?
    var readAt: Date?
    var starredAt: Date?
}

extension Article: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "article"

    /// The columns a list reads: every column but `content_html`, which can
    /// be large and is read by article identifier when an article is opened.
    /// Without this declaration a record selects every column.
    static var databaseSelection: [any SQLSelectable] {
        CodingKeys.allCases.map { Column($0.rawValue) }
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case sourceID = "source_id"
        case externalID = "external_id"
        case url
        case title
        case excerpt
        case author
        case imageURL = "image_url"
        case publishedAt = "published_at"
        case firstSeenAt = "first_seen_at"
        case language
        case readAt = "read_at"
        case starredAt = "starred_at"
    }

    static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .lowercaseString
    }
}

/// The readable body of an article (spec N05, section 4). `blocks` is JSON
/// text whose structure the reading issues define.
struct ArticleBody: Sendable, Hashable {
    var articleID: UUID
    var origin: BodyOrigin
    var blocks: String
    var fetchedAt: Date
}

extension ArticleBody: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "article_body"

    enum CodingKeys: String, CodingKey {
        case articleID = "article_id"
        case origin
        case blocks
        case fetchedAt = "fetched_at"
    }

    static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .lowercaseString
    }
}
