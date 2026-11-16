import Foundation
import GRDB

/// What a refresh collects (RD06 decision 2).
public enum RefreshScope: Sendable, Hashable {
    /// Every source of the library.
    case library
    /// The sources of one category.
    case category(UUID)
    /// One source.
    case source(UUID)
}

/// Refresh state of one library (spec N04; RD06 decisions 2, 4 and 5).
extension Library {
    /// The key of the recorded refresh time in `setting`.
    static let lastRefreshKey = "last_refresh_at"

    /// The sources a refresh of `scope` collects: those of a kind collected
    /// as a feed (`feed`, `github`) that are not paused, in a stable order.
    /// Paused, web-page and other kinds are never included.
    public func refreshTargets(_ scope: RefreshScope) async throws -> [UUID] {
        try await read { db in try Self.refreshTargets(scope, in: db) }
    }

    private static func refreshTargets(_ scope: RefreshScope, in db: Database) throws -> [UUID] {
        let kinds = SourceKind.allCases.filter(\.isCollectedAsFeed).map(\.rawValue)
        var sql = "SELECT id FROM source WHERE kind IN (\(kinds.map { _ in "?" }.joined(separator: ", "))) AND paused = 0"
        var arguments: [any DatabaseValueConvertible] = kinds
        switch scope {
        case .library:
            break
        case .category(let id):
            sql += " AND category_id = ?"
            arguments.append(id.databaseKey)
        case .source(let id):
            sql += " AND id = ?"
            arguments.append(id.databaseKey)
        }
        sql += " ORDER BY name, id"
        return try String.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map { text in
            guard let id = UUID(uuidString: text) else { throw LibraryError.storage("Not an identifier: \(text)") }
            return id
        }
    }

    /// The moment the last counted whole-library refresh ended, or `nil`
    /// when none has been recorded.
    public func lastRefreshAt() async throws -> Date? {
        try await read { db in
            try Date.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [Self.lastRefreshKey])
        }
    }

    /// Records the end of a counted whole-library refresh.
    func setLastRefreshAt(_ date: Date) async throws {
        try await write { db in try Self.writeLastRefreshAt(date, in: db) }
    }

    /// Records the end of a whole-library run that collected `targets`,
    /// unless the library has a source to collect that is not among them:
    /// one added while the run went on — a category moved in from the other
    /// partition (RD19, review round 1), or a source added — was not
    /// collected by it, so the run does not count as a refresh of the whole
    /// library, and the next entry refreshes it (RD06's rule). Checked and
    /// written in one transaction.
    ///
    /// - Returns: whether the time was recorded.
    @discardableResult
    func setLastRefreshAt(_ date: Date, collected targets: Set<UUID>) async throws -> Bool {
        try await write { db in
            guard try Set(Self.refreshTargets(.library, in: db)).isSubset(of: targets) else { return false }
            try Self.writeLastRefreshAt(date, in: db)
            return true
        }
    }

    private static func writeLastRefreshAt(_ date: Date, in db: Database) throws {
        try db.execute(
            sql: "INSERT INTO setting (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
            arguments: [lastRefreshKey, date]
        )
    }

    /// Whether entering the app should refresh the whole library, by the
    /// library's clock: never for manual only; otherwise when nothing is
    /// recorded, when the recorded time is at least `interval` ago, or when
    /// it lies in the future (the clock was changed).
    public func refreshIsDue(every interval: RefreshInterval) async throws -> Bool {
        guard interval != .manualOnly else { return false }
        guard let last = try await lastRefreshAt() else { return true }
        let now = now()
        return last > now || now.timeIntervalSince(last) >= TimeInterval(interval.rawValue * 60)
    }
}
