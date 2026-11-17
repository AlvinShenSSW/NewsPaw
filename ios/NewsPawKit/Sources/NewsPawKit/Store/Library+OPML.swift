import Foundation
import GRDB

/// Where an OPML file's feeds outside any folder go (RD08 decision 4).
public enum OPMLOutsideFeeds: Sendable, Hashable {
    /// A category of the library.
    case existing(UUID)
    /// A typed name: the first existing category of that name, else the
    /// category the import creates for a folder of that name, else a new
    /// category placed last. Validated like any category name.
    case named(String)
}

/// Why an entry of the file is not imported.
public enum OPMLSkipReason: Sendable, Hashable {
    /// Not an http or https address with a host.
    case invalidAddress
    /// The library already has a source at this address, in this category.
    case alreadyInLibrary(categoryName: String)
    /// An earlier entry of the file has the same address.
    case repeatedInFile
}

/// An entry of the file that is not imported, as the preview and the summary
/// list it.
public struct OPMLSkippedEntry: Sendable, Hashable {
    /// The entry's name from the file; may be empty.
    public let name: String
    /// The entry's address, cut to `OPMLImportSummary.displayedAddressLength`
    /// characters.
    public let address: String
    public let reason: OPMLSkipReason

    public init(name: String, address: String, reason: OPMLSkipReason) {
        self.name = name
        self.address = address
        self.reason = reason
    }
}

/// A category an import adds feeds to or creates.
public struct OPMLCategoryResult: Sendable, Hashable {
    public let name: String
    /// Whether the import creates it.
    public let isNew: Bool
    /// The feeds the import adds to it.
    public let addedFeeds: Int

    public init(name: String, isNew: Bool, addedFeeds: Int) {
        self.name = name
        self.isNew = isNew
        self.addedFeeds = addedFeeds
    }
}

/// What an import does, or did: the plan the preview shows and the summary
/// after the write are made by the same function.
public struct OPMLImportSummary: Sendable, Hashable {
    /// The longest address shown for a skipped entry, in characters.
    public static let displayedAddressLength = 200

    /// One per folder of the file (folders of one name are one), in file
    /// order; then the category of the feeds outside any folder, when it is
    /// none of those and outside feeds are added to it.
    public let categories: [OPMLCategoryResult]
    /// The feeds outside any folder that are added; a plan without a
    /// target counts them without placing them.
    public let outsideFeeds: Int
    /// Every feed added, outside feeds included.
    public let addedFeeds: Int
    /// Every entry that is not imported, in file order.
    public let skipped: [OPMLSkippedEntry]

    /// The names of the categories the import creates, in the order created.
    public var createdCategories: [String] {
        categories.filter(\.isNew).map(\.name)
    }

    /// The names of the existing categories the import adds to.
    public var matchedCategories: [String] {
        categories.filter { !$0.isNew }.map(\.name)
    }

    /// Whether a category must be chosen for the feeds outside any folder.
    public var needsOutsideCategory: Bool {
        outsideFeeds > 0
    }

    /// Whether the import would write anything: a feed or a category.
    public var changesSomething: Bool {
        addedFeeds > 0 || categories.contains(where: \.isNew)
    }
}

/// OPML import and export (spec N03, N10; RD08 decisions 4 and 6). Both act
/// on this library alone. Importing makes no request: the feeds are added
/// as the file states them, as kind `feed`, and the app's ordinary refresh
/// collects them afterwards.
extension Library {
    /// What importing `document` would do, read in one transaction: the
    /// preview's numbers. Without a target the feeds outside any folder are
    /// counted but placed nowhere.
    ///
    /// - Throws: `unknownCategory` for an `.existing` target that does not
    ///   exist; `emptyName`, `nameTooLong` for a `.named` one.
    public func opmlImportPlan(_ document: OPMLDocument, outsideFeeds target: OPMLOutsideFeeds? = nil) async throws -> OPMLImportSummary {
        let named = try Self.validatedTarget(target)
        let now = now()
        return try await read { db in
            try Self.runOPMLImport(document, target: named, requiresTarget: false, writing: false, now: now, in: db)
        }
    }

    /// Imports `document` in one write transaction: the categories its
    /// folders need and every feed whose address is valid and new. Nothing
    /// is written when it throws.
    ///
    /// - Parameter target: where the feeds outside any folder go; required
    ///   exactly when at least one of them is added.
    /// - Returns: what the transaction did, which is what a plan made now
    ///   would say even if the library changed since the preview.
    /// - Throws: `unknownCategory` when a target is required and none is
    ///   given, or its category no longer exists; `emptyName`,
    ///   `nameTooLong` for a `.named` target; a storage error.
    @discardableResult
    public func importOPML(_ document: OPMLDocument, outsideFeeds target: OPMLOutsideFeeds?) async throws -> OPMLImportSummary {
        let named = try Self.validatedTarget(target)
        let now = now()
        return try await write { db in
            try Self.runOPMLImport(document, target: named, requiresTarget: true, writing: true, now: now, in: db)
        }
    }

    /// The library as OPML 2.0, read in one transaction: every category in
    /// the owner's order and, inside each, its `feed` and `github` sources
    /// by name (as `sourceSummaries()` orders them). Web pages are not in
    /// the file, and nothing in it names the partition.
    public func opmlExport() async throws -> Data {
        let now = now()
        let folders = try await read { db -> [OPMLWriter.Folder] in
            let categories = try Category.order(Column("sort_order"), Column("id")).fetchAll(db)
            let rows = try Row.fetchAll(db, sql: "SELECT id, category_id, kind, url, name, site_url FROM source")
            var feeds: [String: [(key: String, feed: OPMLWriter.Feed)]] = [:]
            for row in rows {
                guard let kind = SourceKind(rawValue: row["kind"]), kind.isCollectedAsFeed else { continue }
                let feed = OPMLWriter.Feed(name: row["name"], address: row["url"], siteAddress: row["site_url"])
                feeds[row["category_id"], default: []].append((row["id"], feed))
            }
            return categories.map { category in
                let sorted = (feeds[category.id.databaseKey] ?? []).sorted { first, second in
                    switch first.feed.name.localizedCaseInsensitiveCompare(second.feed.name) {
                    case .orderedAscending: true
                    case .orderedDescending: false
                    case .orderedSame: first.key < second.key
                    }
                }
                return OPMLWriter.Folder(name: category.name, feeds: sorted.map(\.feed))
            }
        }
        return OPMLWriter.document(folders, created: now)
    }

    // MARK: - The plan and the import

    /// A target with a typed name already validated and trimmed.
    private enum Target {
        case existing(String)
        case named(String)
    }

    private static func validatedTarget(_ target: OPMLOutsideFeeds?) throws -> Target? {
        switch target {
        case nil: return nil
        case .existing(let id): return .existing(id.databaseKey)
        case .named(let name):
            switch categoryNameProblem(name) {
            case .empty: throw LibraryError.emptyName
            case .tooLong: throw LibraryError.nameTooLong
            case nil: return .named(name.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    /// A folder of the file, with the folders of the same name.
    private struct FolderPlan {
        let name: String
        var feeds: [Source] = []
        /// The existing category's identifier, else `nil` until one is
        /// made for it.
        var categoryKey: String?
        var isNew = false
    }

    /// The plan and the import: one pass over the file against the
    /// database, writing only when `writing` is set, so that a summary is
    /// always what the same transaction did.
    private static func runOPMLImport(
        _ document: OPMLDocument, target: Target?, requiresTarget: Bool, writing: Bool, now: Date, in db: Database
    ) throws -> OPMLImportSummary {
        // The first category of each name, in the owner's order. Names from
        // a file are bounded in bytes by the reader before they get here.
        let existing = try Category.order(Column("sort_order"), Column("id")).fetchAll(db)
        var firstCategory: [String: String] = [:]
        for category in existing where firstCategory[category.name] == nil {
            firstCategory[category.name] = category.id.databaseKey
        }
        var nextSortOrder = (try Int.fetchOne(db, sql: "SELECT MAX(sort_order) FROM category")).map { $0 + 1 } ?? 0
        var categoryOfAddress: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT source.url AS url, category.name AS name FROM source JOIN category ON category.id = source.category_id
            ORDER BY source.rowid
            """) {
            let url: String = row["url"]
            if categoryOfAddress[url] == nil {
                categoryOfAddress[url] = row["name"]
            }
        }

        var seen = Set<String>()
        var skipped: [OPMLSkippedEntry] = []
        var folders: [FolderPlan] = []
        var folderIndex: [String: Int] = [:]
        var outside: [Source] = []

        /// The source to add for `feed`, or `nil` with the reason listed.
        func evaluate(_ feed: OPMLFeed) -> Source? {
            func skip(_ reason: OPMLSkipReason) -> Source? {
                skipped.append(OPMLSkippedEntry(
                    name: feed.name, address: String(feed.address.prefix(OPMLImportSummary.displayedAddressLength)), reason: reason
                ))
                return nil
            }
            guard !feed.addressIsTooLong, case .success(let parsed) = SourceAddress.parse(feed.address, addingScheme: false) else {
                return skip(.invalidAddress)
            }
            let address = parsed.normalForm
            if let category = categoryOfAddress[address] {
                return skip(.alreadyInLibrary(categoryName: category))
            }
            guard seen.insert(address).inserted else {
                return skip(.repeatedInFile)
            }
            var name = feed.name
            if name.isEmpty {
                name = String((URLComponents(string: address)?.host ?? address).prefix(maximumSourceNameLength))
            }
            return Source(
                id: UUID(), categoryID: UUID(), kind: .feed, url: address, name: name,
                siteURL: RawItem.webAddress(feed.siteAddress, base: nil),
                paused: false, autoTranslate: .inherit, bodyMode: .auto, translatePage: false,
                etag: nil, lastModified: nil, lastSuccessAt: nil, lastError: nil, updatedAt: now
            )
        }

        for entry in document.entries {
            switch entry {
            case .feed(let feed):
                if let source = evaluate(feed) {
                    outside.append(source)
                }
            case .folder(let name, let feeds):
                let index: Int
                if let known = folderIndex[name] {
                    index = known
                } else {
                    index = folders.count
                    folderIndex[name] = index
                    folders.append(FolderPlan(name: name, categoryKey: firstCategory[name]))
                }
                for feed in feeds {
                    if let source = evaluate(feed) {
                        folders[index].feeds.append(source)
                    }
                }
            }
        }

        func createCategory(named name: String) throws -> String {
            let id = UUID()
            if writing {
                try Category(
                    id: id, name: name, sortOrder: nextSortOrder, iconName: CategoryIcon.folder.rawValue,
                    overview: .auto, updatedAt: now
                ).insert(db)
            }
            nextSortOrder += 1
            return id.databaseKey
        }

        // The folders' categories, matched or created in file order.
        for index in folders.indices where folders[index].categoryKey == nil {
            folders[index].categoryKey = try createCategory(named: folders[index].name)
            folders[index].isNew = true
        }

        // The outside feeds' category.
        var outsideResult: OPMLCategoryResult?
        var outsideKey: String?
        var outsideFolder: Int?
        if !outside.isEmpty {
            switch target {
            case nil:
                if requiresTarget {
                    throw LibraryError.unknownCategory
                }
            case .existing(let key):
                guard let category = existing.first(where: { $0.id.databaseKey == key }) else {
                    throw LibraryError.unknownCategory
                }
                outsideKey = key
                outsideFolder = folders.firstIndex { $0.categoryKey == key }
                if outsideFolder == nil {
                    outsideResult = OPMLCategoryResult(name: category.name, isNew: false, addedFeeds: outside.count)
                }
            case .named(let name):
                if let key = firstCategory[name] {
                    outsideKey = key
                    outsideFolder = folders.firstIndex { $0.categoryKey == key }
                    if outsideFolder == nil {
                        outsideResult = OPMLCategoryResult(name: name, isNew: false, addedFeeds: outside.count)
                    }
                } else if let index = folderIndex[name] {
                    outsideKey = folders[index].categoryKey
                    outsideFolder = index
                } else {
                    outsideKey = try createCategory(named: name)
                    outsideResult = OPMLCategoryResult(name: name, isNew: true, addedFeeds: outside.count)
                }
            }
        }

        if writing {
            for folder in folders {
                for source in folder.feeds {
                    try insert(source, categoryKey: folder.categoryKey, in: db)
                }
            }
            if let outsideKey {
                for source in outside {
                    try insert(source, categoryKey: outsideKey, in: db)
                }
            }
        }

        var categories = folders.enumerated().map { index, folder in
            OPMLCategoryResult(
                name: folder.name, isNew: folder.isNew,
                addedFeeds: folder.feeds.count + (index == outsideFolder ? outside.count : 0)
            )
        }
        if let outsideResult {
            categories.append(outsideResult)
        }
        return OPMLImportSummary(
            categories: categories,
            outsideFeeds: outside.count,
            addedFeeds: folders.reduce(0) { $0 + $1.feeds.count } + outside.count,
            skipped: skipped
        )
    }

    private static func insert(_ source: Source, categoryKey: String?, in db: Database) throws {
        guard let categoryKey, let categoryID = UUID(uuidString: categoryKey) else {
            throw LibraryError.unknownCategory
        }
        var source = source
        source.categoryID = categoryID
        do {
            try source.insert(db)
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            throw LibraryError.duplicateAddress
        }
    }
}
