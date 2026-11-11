import Foundation
import GRDB

/// What happens to a category's sources when the category is deleted
/// (spec N02).
public enum CategorySourcesDisposition: Sendable, Hashable {
    /// The sources are deleted with the category, and their articles, bodies
    /// and seen identifiers with them.
    case deleteSources
    /// The sources move to another category of the same library.
    case move(to: UUID)
}

/// Category management (spec N02). Every operation checks and writes inside
/// one write transaction and sets `updated_at` from the store's clock.
extension Library {
    /// The longest category name accepted, in characters.
    public static let maximumCategoryNameLength = 100

    /// The library's categories in the owner's order.
    public func categories() async throws -> [Category] {
        try await read { db in
            try Category.order(Column("sort_order"), Column("id")).fetchAll(db)
        }
    }

    /// Creates a category placed after every existing one. Duplicate names
    /// are allowed.
    ///
    /// - Throws: `emptyName`, `nameTooLong`.
    public func createCategory(name: String, icon: CategoryIcon) async throws -> Category {
        let name = try Self.validatedName(name)
        let now = now()
        return try await write { db in
            let last = try Int.fetchOne(db, sql: "SELECT MAX(sort_order) FROM category")
            let category = Category(
                id: UUID(),
                name: name,
                sortOrder: last.map { $0 + 1 } ?? 0,
                iconName: icon.rawValue,
                overview: .auto,
                updatedAt: now
            )
            try category.insert(db)
            return category
        }
    }

    /// Renames a category. Writes only its name and `updated_at`.
    ///
    /// - Throws: `emptyName`, `nameTooLong`, `unknownCategory`.
    public func renameCategory(_ id: UUID, to name: String) async throws {
        let name = try Self.validatedName(name)
        let now = now()
        try await write { db in
            try db.execute(
                sql: "UPDATE category SET name = ?, updated_at = ? WHERE id = ?",
                arguments: [name, now, id.databaseKey]
            )
            if db.changesCount == 0 {
                throw LibraryError.unknownCategory
            }
        }
    }

    /// Changes a category's icon. Writes only its icon and `updated_at`.
    ///
    /// - Throws: `unknownCategory`.
    public func setCategoryIcon(_ id: UUID, to icon: CategoryIcon) async throws {
        let now = now()
        try await write { db in
            try db.execute(
                sql: "UPDATE category SET icon = ?, updated_at = ? WHERE id = ?",
                arguments: [icon.rawValue, now, id.databaseKey]
            )
            if db.changesCount == 0 {
                throw LibraryError.unknownCategory
            }
        }
    }

    /// Puts the categories in the given order, numbering them from 0.
    ///
    /// - Parameter ids: every category of the library, each exactly once.
    /// - Throws: `invalidOrder` when `ids` is not a permutation of the
    ///   library's categories.
    public func reorderCategories(_ ids: [UUID]) async throws {
        let keys = ids.map(\.databaseKey)
        let now = now()
        try await write { db in
            let existing = try String.fetchSet(db, sql: "SELECT id FROM category")
            guard keys.count == existing.count, Set(keys) == existing else {
                throw LibraryError.invalidOrder
            }
            for (index, key) in keys.enumerated() {
                try db.execute(
                    sql: "UPDATE category SET sort_order = ?, updated_at = ? WHERE id = ? AND sort_order <> ?",
                    arguments: [index, now, key, index]
                )
            }
        }
    }

    /// Deletes a category, and either deletes its sources or moves them to
    /// another category of this library. Moved sources get a new
    /// `updated_at`, since their category changed.
    ///
    /// - Throws: `unknownCategory` when `id` is not a category of this
    ///   library; `invalidMoveTarget` when the destination is `id` itself or
    ///   not a category of this library. Nothing changes when it throws.
    public func deleteCategory(_ id: UUID, sources: CategorySourcesDisposition) async throws {
        let key = id.databaseKey
        let now = now()
        try await write { db in
            guard try Self.categoryExists(key, in: db) else {
                throw LibraryError.unknownCategory
            }
            switch sources {
            case .deleteSources:
                // Articles, their bodies and seen identifiers follow through
                // the foreign keys' cascades.
                try db.execute(sql: "DELETE FROM source WHERE category_id = ?", arguments: [key])
            case .move(let destination):
                let destinationKey = destination.databaseKey
                guard destinationKey != key, try Self.categoryExists(destinationKey, in: db) else {
                    throw LibraryError.invalidMoveTarget
                }
                try db.execute(
                    sql: "UPDATE source SET category_id = ?, updated_at = ? WHERE category_id = ?",
                    arguments: [destinationKey, now, key]
                )
            }
            try db.execute(sql: "DELETE FROM category WHERE id = ?", arguments: [key])
        }
    }

    private static func categoryExists(_ key: String, in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM category WHERE id = ?)", arguments: [key]) ?? false
    }

    private static func validatedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw LibraryError.emptyName
        }
        if trimmed.count > maximumCategoryNameLength {
            throw LibraryError.nameTooLong
        }
        return trimmed
    }
}
