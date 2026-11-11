import Foundation
import GRDB

// Adding a case to any of these sets needs a schema migration, even an empty
// one, so that an older build refuses the database instead of failing to read
// the row.

/// What a source is (spec N03).
enum SourceKind: String, Sendable, Codable, CaseIterable {
    case feed
    case github
    case huggingface
    case webpage
}

/// Whether a source's titles are translated automatically (spec N03).
enum AutoTranslate: String, Sendable, Codable, CaseIterable {
    case inherit
    case on
    case off
}

/// How a source's article bodies are obtained (spec N03, N05).
enum BodyMode: String, Sendable, Codable, CaseIterable {
    case auto
    case page
    case feed
}

/// A source of one library (spec N03, section 4). Its operations become
/// public in RD04 and RD05; until then only the package and its tests use it.
struct Source: Sendable, Hashable {
    var id: UUID
    var categoryID: UUID
    var kind: SourceKind
    var url: String
    var name: String
    var siteURL: String?
    var paused: Bool
    var autoTranslate: AutoTranslate
    var bodyMode: BodyMode
    var translatePage: Bool
    var etag: String?
    var lastModified: String?
    var lastSuccessAt: Date?
    var lastError: String?
    var updatedAt: Date
}

extension Source: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "source"

    enum CodingKeys: String, CodingKey {
        case id
        case categoryID = "category_id"
        case kind
        case url
        case name
        case siteURL = "site_url"
        case paused
        case autoTranslate = "auto_translate"
        case bodyMode = "body_mode"
        case translatePage = "translate_page"
        case etag
        case lastModified = "last_modified"
        case lastSuccessAt = "last_success_at"
        case lastError = "last_error"
        case updatedAt = "updated_at"
    }

    static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .lowercaseString
    }
}
