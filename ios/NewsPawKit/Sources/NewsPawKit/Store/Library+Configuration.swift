import Foundation
import GRDB

/// The configuration file's reads and its write transaction on one library
/// (spec N10; RD20 decisions 4 and 5). Every function works on this library
/// alone; none takes another library or a key store.
extension Library {
    /// One read of the library for planning.
    func configurationSnapshot() async throws -> ConfigurationSnapshot {
        let partition = partition
        return try await read { db in try Self.configurationSnapshot(partition, in: db) }
    }

    static func configurationSnapshot(_ partition: Partition, in db: Database) throws -> ConfigurationSnapshot {
        let categories = try Category.order(Column("sort_order"), Column("id")).fetchAll(db)
        let rows = try Row.fetchAll(db, sql: """
            SELECT source.id, source.category_id, source.kind, source.url, source.name, source.paused, source.auto_translate,
                   source.body_mode, source.translate_page,
                   COUNT(article.id) AS article_count, COUNT(article.starred_at) AS starred_count
            FROM source LEFT JOIN article ON article.source_id = source.id
            GROUP BY source.id
            """)
        var sources: [ConfigurationSnapshot.SourceRow] = []
        for row in rows {
            guard let id = UUID(uuidString: row["id"]), let categoryID = UUID(uuidString: row["category_id"]) else {
                throw LibraryError.storage("Not an identifier")
            }
            // A kind this build does not know cannot be stored (the closed
            // sets need a migration); read as a feed, as the summaries do.
            let kind = SourceKind(rawValue: row["kind"]) ?? .feed
            sources.append(ConfigurationSnapshot.SourceRow(
                id: id, categoryID: categoryID, kind: kind, address: row["url"], name: row["name"],
                options: ConfigurationSourceOptions(
                    paused: row["paused"], autoTranslate: AutoTranslate(rawValue: row["auto_translate"]) ?? .inherit,
                    bodyMode: BodyMode(rawValue: row["body_mode"]) ?? .auto, translatePage: row["translate_page"]
                ).applying(to: kind),
                articleCount: row["article_count"], starredCount: row["starred_count"]
            ))
        }
        let slots = try ModelSlot.fetchAll(db)
        return ConfigurationSnapshot(
            partition: partition, categories: categories, sources: sources,
            slots: Dictionary(slots.map { ($0.role, $0) }, uniquingKeysWith: { first, _ in first }),
            settings: try ConfigurationPartitionSettings.inEffect(partition, in: db)
        )
    }

    /// Plans and writes `part` in one write transaction over a fresh
    /// snapshot (decision 5, steps 1 and 2): categories created and
    /// updated, sources inserted and updated, sources deleted (their
    /// articles, bodies, seen identifiers and translations follow through
    /// the cascades), categories deleted, the order rewritten, slot rows
    /// written (primary before backup, backup removed before primary), and
    /// the partition's settings (Replace). A changed slot makes the
    /// library's failed translations wait again, as a slot save does.
    /// Nothing is written when it throws.
    ///
    /// - Parameter inside: a test hook, run inside the transaction after
    ///   the writes and before the commit.
    /// - Returns: the plan the transaction carried out.
    func importConfiguration(
        _ part: ConfigurationPartition, mode: ConfigurationImportMode, inside: (@Sendable () throws -> Void)? = nil
    ) async throws -> ConfigurationPlan {
        precondition(part.partition == partition, "a part of another partition")
        let partition = partition
        let now = now()
        return try await write { db in
            let snapshot = try Self.configurationSnapshot(partition, in: db)
            let plan = ConfigurationPlan.make(part, snapshot: snapshot, mode: mode, now: now)
            try Self.carryOut(plan, now: now, in: db)
            try inside?()
            return plan
        }
    }

    private static func carryOut(_ plan: ConfigurationPlan, now: Date, in db: Database) throws {
        for creation in plan.categoryCreations {
            try Category(
                id: creation.id, name: creation.category.name, sortOrder: creation.sortOrder, iconName: creation.category.iconName,
                overview: creation.category.overview, updatedAt: now
            ).insert(db)
        }
        for update in plan.categoryUpdates {
            try db.execute(
                sql: "UPDATE category SET icon = ?, overview = ?, updated_at = ? WHERE id = ?",
                arguments: [update.iconName, update.overview.rawValue, now, update.id.databaseKey]
            )
        }
        for insertion in plan.sourceInsertions {
            let source = insertion.source
            let options = source.options.applying(to: source.kind)
            do {
                try Source(
                    id: UUID(), categoryID: insertion.categoryID, kind: source.kind, url: source.address, name: source.name,
                    siteURL: nil, paused: options.paused, autoTranslate: options.autoTranslate, bodyMode: options.bodyMode,
                    translatePage: options.translatePage, etag: nil, lastModified: nil, lastSuccessAt: nil, lastError: nil,
                    updatedAt: now
                ).insert(db)
            } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
                throw LibraryError.duplicateAddress
            }
        }
        for update in plan.sourceUpdates {
            try db.execute(
                sql: """
                    UPDATE source SET name = ?, category_id = ?, paused = ?, auto_translate = ?, body_mode = ?, translate_page = ?,
                        updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    update.name, update.categoryID.databaseKey, update.options.paused, update.options.autoTranslate.rawValue,
                    update.options.bodyMode.rawValue, update.options.translatePage, now, update.id.databaseKey,
                ]
            )
        }
        for id in plan.deletedSourceIDs {
            try db.execute(sql: "DELETE FROM source WHERE id = ?", arguments: [id.databaseKey])
        }
        for id in plan.deletedCategoryIDs {
            try db.execute(sql: "DELETE FROM category WHERE id = ?", arguments: [id.databaseKey])
        }
        if let order = plan.finalOrder {
            for (index, id) in order.enumerated() {
                try db.execute(
                    sql: "UPDATE category SET sort_order = ?, updated_at = ? WHERE id = ? AND sort_order <> ?",
                    arguments: [index, now, id.databaseKey, index]
                )
            }
        }
        for role in plan.slotDeletions {
            try ModelSlot.deleteOne(db, key: role.rawValue)
        }
        for slot in plan.slotWrites {
            try slot.save(db)
        }
        if !plan.slotWrites.isEmpty || !plan.slotDeletions.isEmpty {
            try deleteFailedTranslations(db)
        }
        try plan.settingsToApply?.apply(in: db)
    }

    /// What an export writes of this library, read in one transaction:
    /// the categories in the owner's order, the sources by category order
    /// and then by name (as `sourceSummaries()` orders them), the slots'
    /// non-secret part and the partition's settings in effect.
    func configurationExportSnapshot() async throws -> ConfigurationSnapshot {
        let snapshot = try await configurationSnapshot()
        let place = Dictionary(snapshot.categories.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sources = snapshot.sources.sorted { first, second in
            let firstPlace = place[first.categoryID] ?? Int.max
            let secondPlace = place[second.categoryID] ?? Int.max
            if firstPlace != secondPlace {
                return firstPlace < secondPlace
            }
            switch first.name.localizedCaseInsensitiveCompare(second.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return first.id.databaseKey < second.id.databaseKey
            }
        }
        return ConfigurationSnapshot(
            partition: snapshot.partition, categories: snapshot.categories, sources: sources, slots: snapshot.slots,
            settings: snapshot.settings
        )
    }

    /// Each slot's key reference, `nil` for a slot without one.
    func configurationSlotReferences() async throws -> [ModelRole: String?] {
        try await read { db in
            Dictionary(try ModelSlot.fetchAll(db).map { ($0.role, $0.keyRef) }, uniquingKeysWith: { first, _ in first })
        }
    }
}
