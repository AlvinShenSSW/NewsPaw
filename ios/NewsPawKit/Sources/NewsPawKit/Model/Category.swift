import Foundation
import GRDB

/// Whether a category gets a daily overview (spec N07, section 4).
///
/// Adding a case needs a schema migration, even an empty one, so that an
/// older build refuses the database instead of failing to read the row.
public enum OverviewMode: String, Sendable, Codable, CaseIterable {
    case auto
    case manual
    case off
}

/// A category of one library (spec N02, section 4). Read it through
/// `Library.categories()`; change it through the `Library` category methods.
public struct Category: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let name: String
    public let sortOrder: Int
    /// The stored SF Symbol name. It is kept as text because a configuration
    /// file from a later version may carry an icon this version does not know.
    public let iconName: String
    public let overview: OverviewMode
    public let updatedAt: Date

    /// The icon to show; a name this version does not know reads as `folder`.
    public var icon: CategoryIcon {
        CategoryIcon(rawValue: iconName) ?? .folder
    }
}

extension Category: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "category"

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case sortOrder = "sort_order"
        case iconName = "icon"
        case overview
        case updatedAt = "updated_at"
    }

    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .lowercaseString
    }
}
