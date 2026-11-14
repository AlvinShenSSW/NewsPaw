import Foundation
import GRDB

/// The rows of the model slots and the usage records (spec N08, N11; RD13).
/// Package-internal: `LibraryModels` is the only way to read and change
/// slots, so that a slot's key is handled with its row.
extension Library {
    /// The library's slots, at most one per role.
    func modelSlots() async throws -> [ModelRole: ModelSlot] {
        try await read { db in
            let slots = try ModelSlot.fetchAll(db)
            return Dictionary(slots.map { ($0.role, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    func modelSlot(_ role: ModelRole) async throws -> ModelSlot? {
        try await read { db in try ModelSlot.fetchOne(db, key: role.rawValue) }
    }

    /// Writes `slot`, replacing the row of its role. A backup is written
    /// only while a primary exists.
    ///
    /// - Throws: `ModelSettingsError.primaryNeeded` for a backup without a
    ///   primary.
    func saveModelSlot(_ slot: ModelSlot) async throws {
        try await write { db in
            if slot.role == .backup, try ModelSlot.fetchOne(db, key: ModelRole.primary.rawValue) == nil {
                throw ModelSettingsError.primaryNeeded
            }
            try slot.save(db)
        }
    }

    /// Deletes the row of `role`. The primary is not deleted while a backup
    /// exists.
    ///
    /// - Throws: `ModelSettingsError.backupExists`.
    func deleteModelSlot(_ role: ModelRole) async throws {
        try await write { db in
            if role == .primary, try ModelSlot.fetchOne(db, key: ModelRole.backup.rawValue) != nil {
                throw ModelSettingsError.backupExists
            }
            _ = try ModelSlot.deleteOne(db, key: role.rawValue)
        }
    }

    /// Clears the key reference and the Test result of `role`'s row when it
    /// still names `keyRef`.
    func clearModelKey(_ role: ModelRole, keyRef: String) async throws {
        let now = now()
        try await write { db in
            try db.execute(
                sql: "UPDATE model_slot SET key_ref = NULL, test_outcome = NULL, updated_at = ? WHERE role = ? AND key_ref = ?",
                arguments: [now, role.rawValue, keyRef]
            )
        }
    }

    /// Keeps a Test result with `role`'s row, if the row still has the
    /// tested address, model and key reference.
    func setModelTestOutcome(_ outcome: TestOutcome, role: ModelRole, baseURL: String, model: String, keyRef: String) async throws {
        try await write { db in
            try db.execute(
                sql: "UPDATE model_slot SET test_outcome = ? WHERE role = ? AND base_url = ? AND model = ? AND key_ref = ?",
                arguments: [outcome.rawValue, role.rawValue, baseURL, model, keyRef]
            )
        }
    }

    func insertUsage(_ record: UsageRecord) async throws {
        try await write { db in try record.insert(db) }
    }

    /// Every usage row, oldest first.
    func usageRecords() async throws -> [UsageRecord] {
        try await read { db in try UsageRecord.order(Column("at"), Column("id")).fetchAll(db) }
    }
}
