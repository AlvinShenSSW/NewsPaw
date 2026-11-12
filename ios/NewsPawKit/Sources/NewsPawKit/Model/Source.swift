import Foundation
import GRDB

// Adding a case to any of these sets needs a schema migration, even an empty
// one, so that an older build refuses the database instead of failing to read
// the row.

/// What a source is (spec N03).
public enum SourceKind: String, Sendable, Codable, CaseIterable {
    case feed
    case github
    case huggingface
    case webpage
}

/// Whether a source's titles are translated automatically (spec N03).
public enum AutoTranslate: String, Sendable, Codable, CaseIterable {
    case inherit
    case on
    case off
}

/// How a source's article bodies are obtained (spec N03, N05).
public enum BodyMode: String, Sendable, Codable, CaseIterable {
    case auto
    case page
    case feed
}

/// Why the last collection of a source failed (spec N03, N04), stored in
/// `source.last_error` as a short code that RD05 words for the owner.
///
/// The column is free text, not one of the closed sets: a value that is not
/// a code (an older build's message, a later build's new code) reads as no
/// known reason rather than as an error.
public enum CollectionFailure: Sendable, Hashable {
    /// No answer: name lookup, connection, TLS, or any other transport error.
    case unreachable
    /// The 20-second deadline passed.
    case timedOut
    /// 404 or 410.
    case gone
    /// Any other status that is not 200 or 304, including a redirect without
    /// a target and a declined 401 or 407.
    case httpStatus(Int)
    /// The answer is not a feed.
    case notAFeed
    /// More than 10 MB decoded.
    case tooLarge
    /// More than 5 redirects.
    case tooManyRedirects
    /// The address or a redirect target is not http or https, or carries a
    /// user name or password.
    case unsupportedAddress

    /// The code stored in `source.last_error`.
    public var code: String {
        switch self {
        case .unreachable: "unreachable"
        case .timedOut: "timed_out"
        case .gone: "gone"
        case .httpStatus(let status): "http:\(status)"
        case .notAFeed: "not_a_feed"
        case .tooLarge: "too_large"
        case .tooManyRedirects: "too_many_redirects"
        case .unsupportedAddress: "unsupported_address"
        }
    }

    /// Reads a stored code; `nil` for any text that is not one.
    public init?(code: String) {
        switch code {
        case "unreachable": self = .unreachable
        case "timed_out": self = .timedOut
        case "gone": self = .gone
        case "not_a_feed": self = .notAFeed
        case "too_large": self = .tooLarge
        case "too_many_redirects": self = .tooManyRedirects
        case "unsupported_address": self = .unsupportedAddress
        default:
            let prefix = "http:"
            guard code.hasPrefix(prefix) else { return nil }
            let digits = code.dropFirst(prefix.count)
            guard (1...3).contains(digits.count), digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
                  let status = Int(digits)
            else { return nil }
            self = .httpStatus(status)
        }
    }
}

/// A source of one library (spec N03, section 4), public for reading.
/// Change it through the `Library` source methods; `url` holds the
/// address's normal form (`SourceAddress`).
public struct Source: Sendable, Hashable, Identifiable {
    public internal(set) var id: UUID
    public internal(set) var categoryID: UUID
    public internal(set) var kind: SourceKind
    public internal(set) var url: String
    public internal(set) var name: String
    public internal(set) var siteURL: String?
    public internal(set) var paused: Bool
    public internal(set) var autoTranslate: AutoTranslate
    public internal(set) var bodyMode: BodyMode
    public internal(set) var translatePage: Bool
    public internal(set) var etag: String?
    public internal(set) var lastModified: String?
    public internal(set) var lastSuccessAt: Date?
    /// Free text; a collection writes a `CollectionFailure` code.
    public internal(set) var lastError: String?
    public internal(set) var updatedAt: Date

    /// The reason of the last failed collection, when `lastError` holds a
    /// code this build knows.
    public var lastFailure: CollectionFailure? {
        lastError.flatMap(CollectionFailure.init(code:))
    }
}

extension Source: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "source"

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

    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .lowercaseString
    }
}
