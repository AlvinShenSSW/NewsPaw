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

    /// Writes `slot`, replacing the row of its role, and deletes the
    /// library's failed translations in the same transaction (RD14 decision
    /// 2): they wait again. A backup is written only while a primary exists.
    ///
    /// - Throws: `ModelSettingsError.primaryNeeded` for a backup without a
    ///   primary.
    func saveModelSlot(_ slot: ModelSlot) async throws {
        try await write { db in
            if slot.role == .backup, try ModelSlot.fetchOne(db, key: ModelRole.primary.rawValue) == nil {
                throw ModelSettingsError.primaryNeeded
            }
            try slot.save(db)
            try Self.deleteFailedTranslations(db)
        }
    }

    /// The statements that make every failed translation of the library
    /// wait again (RD14 decision 2), the titles' and the bodies' texts
    /// (RD15 decision 2): run with every change of a slot — a save, a
    /// removal, a key removed — so that a fault of the model stored on many
    /// articles is repaired by repairing the slot.
    static func deleteFailedTranslations(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM translation WHERE state = ?", arguments: [TranslationState.failed.rawValue])
        try db.execute(sql: "DELETE FROM body_translation WHERE state = ?", arguments: [TranslationState.failed.rawValue])
    }

    /// Deletes the row of `role`, and with it the library's failed
    /// translations. The primary is not deleted while a backup exists.
    ///
    /// - Throws: `ModelSettingsError.backupExists`.
    func deleteModelSlot(_ role: ModelRole) async throws {
        try await write { db in
            if role == .primary, try ModelSlot.fetchOne(db, key: ModelRole.backup.rawValue) != nil {
                throw ModelSettingsError.backupExists
            }
            if try ModelSlot.deleteOne(db, key: role.rawValue) {
                try Self.deleteFailedTranslations(db)
            }
        }
    }

    /// Clears the key reference and the Test result of `role`'s row when it
    /// still names `keyRef`, and then deletes the library's failed
    /// translations.
    func clearModelKey(_ role: ModelRole, keyRef: String) async throws {
        let now = now()
        try await write { db in
            try db.execute(
                sql: "UPDATE model_slot SET key_ref = NULL, test_outcome = NULL, updated_at = ? WHERE role = ? AND key_ref = ?",
                arguments: [now, role.rawValue, keyRef]
            )
            if db.changesCount > 0 {
                try Self.deleteFailedTranslations(db)
            }
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

    /// How many usage rows of `purpose` the library holds: the UI tests'
    /// report counts body requests with it (RD15 decision 16).
    public func usageCount(purpose: UsagePurpose) async throws -> Int {
        try await read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage WHERE purpose = ?", arguments: [purpose.rawValue]) ?? 0
        }
    }

    /// Every usage row, oldest first.
    func usageRecords() async throws -> [UsageRecord] {
        try await read { db in try UsageRecord.order(Column("at"), Column("id")).fetchAll(db) }
    }
}
