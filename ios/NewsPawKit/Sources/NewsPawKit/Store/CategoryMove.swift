import Foundation
import GRDB

/// Moving a category to the other partition (spec N02; RD19 decision 10).
/// Only the category and its sources move: the sources are copied into the
/// destination library without their validators, last success or last
/// error, so that they are collected there afresh, and then deleted in the
/// old library, where their articles, bodies, seen identifiers and
/// translations follow by the foreign keys' cascades. Read and starred
/// states are lost.
///
/// The only code that holds both libraries (with RD20's export and import).
/// The app runs it only while the adult partition is shown, so that both
/// libraries are open (RD18). Two files share no transaction, so the copy
/// comes first and the deletion second: a failure leaves nothing changed,
/// or a copy in both, never a loss, and moving again finishes.
public enum CategoryMove {
    /// What a move would do, read before it is confirmed.
    public struct Plan: Sendable, Hashable {
        /// The category, as the old library holds it.
        public let category: Category
        /// The sources that move, by name: no source of the destination has
        /// their address, or the one that has it has their identifier too
        /// (a move that was interrupted).
        public let moving: [Source]
        /// The sources that stay in the old library, in the category, by
        /// name: the destination already has their address under another
        /// identifier.
        public let staying: [Source]
        /// The articles of the moving sources, deleted in the old library.
        public let articleCount: Int
        /// The partition the category leaves.
        public let from: Partition
        /// The partition it moves to.
        public let to: Partition

        /// Whether the move would write nothing: every source of the
        /// category stays. A category without sources moves.
        public var movesNothing: Bool {
            moving.isEmpty && !staying.isEmpty
        }
    }

    /// How a move ended.
    public enum Outcome: Sendable, Hashable {
        /// The copy and the deletion were both committed. `staying` sources
        /// are left in the old library's category, which was removed when
        /// none is left.
        case moved(staying: Int, categoryRemoved: Bool)
        /// Every source of the category is in the destination under another
        /// identifier: nothing was written.
        case nothingToMove
        /// The copy failed: nothing changed in either library.
        case notMoved
        /// The copy was committed and the deletion failed: the category and
        /// its moved sources are in both libraries; moving again finds the
        /// copies by their identifiers and finishes.
        case copiedNotRemoved
    }

    /// The two steps of a run.
    public enum Step: Sendable, Hashable {
        case copy
        case deletion
    }

    /// Reads what moving the category `id` from `from` to `to` would do.
    ///
    /// - Throws: `LibraryError.unknownCategory` when `from` has no such
    ///   category, or a `LibraryError` when a library cannot be read.
    public static func plan(category id: UUID, from: Library, to: Library) async throws -> Plan {
        precondition(from.partition != to.partition, "a move within one partition")
        let key = id.databaseKey
        let (category, sources, articleCounts) = try await from.read { db in
            guard let category = try Category.fetchOne(db, key: key) else {
                throw LibraryError.unknownCategory
            }
            let sources = try Source.filter(Column("category_id") == key).order(Column("name"), Column("id")).fetchAll(db)
            let rows = try Row.fetchAll(
                db, sql: "SELECT source_id, COUNT(*) AS n FROM article WHERE source_id IN (SELECT id FROM source WHERE category_id = ?) GROUP BY source_id",
                arguments: [key]
            )
            var counts: [String: Int] = [:]
            for row in rows {
                counts[row["source_id"]] = row["n"]
            }
            return (category, sources, counts)
        }
        let addresses = sources.map(\.url)
        let twins = try await to.read { db in
            try Self.identifiers(byAddress: addresses, in: db)
        }
        var moving: [Source] = []
        var staying: [Source] = []
        for source in sources {
            if let twin = twins[source.url], twin != source.id.databaseKey {
                staying.append(source)
            } else {
                moving.append(source)
            }
        }
        let articleCount = moving.reduce(0) { $0 + (articleCounts[$1.id.databaseKey] ?? 0) }
        return Plan(
            category: category, moving: moving, staying: staying, articleCount: articleCount, from: from.partition, to: to.partition
        )
    }

    /// Moves what `plan` says: the copy in one write transaction of `to`,
    /// then the deletion in one write transaction of `from`. Both run in a
    /// task of their own whose end this awaits: a cancellation of the
    /// caller does not interrupt either step (the database's asynchronous
    /// write would refuse to start, or interrupt its statement, in a
    /// cancelled task), so each runs to its end.
    ///
    /// The old library's image cache is not cleared here: the app clears
    /// it with `clearOldCache(from:)` once the interface has let go of the
    /// moved articles (decision 11).
    public static func run(_ plan: Plan, from: Library, to: Library) async -> Outcome {
        await perform(plan, from: from, to: to, hooks: Hooks())
    }

    /// Empties the old library's whole image cache (decision 6): the body
    /// images of the moved articles are cached by addresses that only
    /// converting each article would find. A store whose fetch began before
    /// this writes nothing (the cache's generation).
    public static func clearOldCache(from: Library) async {
        await from.imageCache.clear()
    }

    // MARK: - The steps

    /// Points where a package test holds or fails a run.
    struct Hooks: Sendable {
        /// The step that fails, before it writes anything.
        var failing: Step?
        /// Runs inside each step's transaction, before its first statement.
        var inside: (@Sendable (Step) -> Void)?
        /// Runs after the copy was committed and before the deletion.
        var betweenSteps: (@Sendable () async -> Void)?
    }

    static func perform(_ plan: Plan, from: Library, to: Library, hooks: Hooks) async -> Outcome {
        precondition(from.partition == plan.from && to.partition == plan.to, "a plan of other libraries")
        return await Task {
            await steps(plan, from: from, to: to, hooks: hooks)
        }.value
    }

    private static func steps(_ plan: Plan, from: Library, to: Library, hooks: Hooks) async -> Outcome {
        let moved: [UUID]?
        do {
            moved = try await copy(plan, to: to, hooks: hooks)
        } catch {
            return .notMoved
        }
        guard let moved else { return .nothingToMove }
        await hooks.betweenSteps?()
        do {
            let (staying, removed) = try await delete(moved, category: plan.category.id, from: from, hooks: hooks)
            return .moved(staying: staying, categoryRemoved: removed)
        } catch {
            return .copiedNotRemoved
        }
    }

    /// Step 1. Returns the sources moved (copied now, or already there by
    /// their identifier), or `nil` when every source now has a twin in the
    /// destination and nothing was written.
    private static func copy(_ plan: Plan, to: Library, hooks: Hooks) async throws -> [UUID]? {
        let now = to.now()
        return try await to.write { db in
            hooks.inside?(.copy)
            if hooks.failing == .copy {
                throw LibraryError.storage("A failure of the copy, for a test")
            }
            // A source whose address has been taken in the destination
            // since the plan was read stays.
            let twins = try identifiers(byAddress: plan.moving.map(\.url), in: db)
            let moving = plan.moving.filter { source in
                twins[source.url].map { $0 == source.id.databaseKey } ?? true
            }
            if moving.isEmpty, !(plan.moving.isEmpty && plan.staying.isEmpty) {
                return nil
            }
            let categoryKey = plan.category.id.databaseKey
            if try !(Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM category WHERE id = ?)", arguments: [categoryKey]) ?? false) {
                let last = try Int.fetchOne(db, sql: "SELECT MAX(sort_order) FROM category")
                try Category(
                    id: plan.category.id, name: plan.category.name, sortOrder: last.map { $0 + 1 } ?? 0,
                    iconName: plan.category.iconName, overview: plan.category.overview, updatedAt: now
                ).insert(db)
            }
            for source in moving {
                // Copied by an earlier, interrupted move.
                if try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM source WHERE id = ?)", arguments: [source.id.databaseKey]) ?? false {
                    continue
                }
                try Source(
                    id: source.id, categoryID: plan.category.id, kind: source.kind, url: source.url, name: source.name,
                    siteURL: source.siteURL, paused: source.paused, autoTranslate: source.autoTranslate, bodyMode: source.bodyMode,
                    translatePage: source.translatePage, etag: nil, lastModified: nil, lastSuccessAt: nil, lastError: nil, updatedAt: now
                ).insert(db)
            }
            // The next entry of the destination refreshes it (RD06), so that
            // the moved sources are collected there.
            try db.execute(sql: "DELETE FROM setting WHERE key = ?", arguments: [Library.lastRefreshKey])
            return moving.map(\.id)
        }
    }

    /// Step 2. Deletes the moved sources in the old library, and the
    /// category when no source is left in it. Returns how many sources are
    /// left in it and whether it was removed.
    private static func delete(_ moved: [UUID], category: UUID, from: Library, hooks: Hooks) async throws -> (Int, Bool) {
        try await from.write { db in
            hooks.inside?(.deletion)
            if hooks.failing == .deletion {
                throw LibraryError.storage("A failure of the deletion, for a test")
            }
            for id in moved {
                // Articles, bodies, seen identifiers and translations follow
                // by the cascades.
                try db.execute(sql: "DELETE FROM source WHERE id = ?", arguments: [id.databaseKey])
            }
            let key = category.databaseKey
            let left = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source WHERE category_id = ?", arguments: [key]) ?? 0
            guard left == 0 else { return (left, false) }
            try db.execute(sql: "DELETE FROM category WHERE id = ?", arguments: [key])
            return (0, true)
        }
    }

    /// The identifiers of the sources of `db` with one of `addresses`, by
    /// address.
    private static func identifiers(byAddress addresses: [String], in db: Database) throws -> [String: String] {
        guard !addresses.isEmpty else { return [:] }
        let marks = addresses.map { _ in "?" }.joined(separator: ", ")
        let rows = try Row.fetchAll(db, sql: "SELECT id, url FROM source WHERE url IN (\(marks))", arguments: StatementArguments(addresses))
        var found: [String: String] = [:]
        for row in rows {
            found[row["url"]] = row["id"]
        }
        return found
    }
}

#if DEBUG
// MARK: - Under the UI tests (debug builds only)

extension CategoryMove {
    /// What the UI tests ask of a run.
    public struct DebugOptions: Sendable {
        /// The step that fails.
        public var failing: Step?
        /// How long the run waits between the copy and the deletion, so
        /// that a lock can come during it.
        public var pauseBetweenSteps: Duration?

        public init(failing: Step? = nil, pauseBetweenSteps: Duration? = nil) {
            self.failing = failing
            self.pauseBetweenSteps = pauseBetweenSteps
        }
    }

    /// `run(_:from:to:)` with what a UI test asked for.
    public static func run(_ plan: Plan, from: Library, to: Library, debug: DebugOptions) async -> Outcome {
        var hooks = Hooks()
        hooks.failing = debug.failing
        if let pause = debug.pauseBetweenSteps {
            hooks.betweenSteps = { @Sendable () async -> Void in
                try? await Task.sleep(for: pause)
            }
        }
        return await perform(plan, from: from, to: to, hooks: hooks)
    }
}
#endif
