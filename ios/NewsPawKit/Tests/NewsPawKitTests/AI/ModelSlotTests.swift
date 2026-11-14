import Foundation
import GRDB
@testable import NewsPawKit
import Testing

/// RD13 decisions 1, 3, 9 and 14 and the failure table: storing slots and
/// their keys. Criteria 1 (package side), 11, 12 and 13.
@Suite("Model slots and keys")
struct ModelSlotTests {
    // MARK: - Migration v5

    @Test("v5 creates model_slot and usage with their columns and the index on usage.at")
    func version5Columns() async throws {
        let fixture = try await ModelsFixture.make(http: StubModelHTTP.answering(500))
        defer { fixture.remove() }
        let (slot, usage, indexes) = try await fixture.library.pool.read { db in
            func columns(_ table: String) throws -> [SchemaTests.ColumnInfo] {
                try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { row in
                    SchemaTests.ColumnInfo(row["name"], row["type"], notNull: row["notnull"], default: row["dflt_value"], pk: row["pk"])
                }
            }
            let indexes = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'usage' AND sql IS NOT NULL")
            return (try columns("model_slot"), try columns("usage"), indexes)
        }
        #expect(slot == [
            SchemaTests.ColumnInfo("role", "TEXT", notNull: true, pk: 1),
            SchemaTests.ColumnInfo("preset", "TEXT", notNull: true),
            SchemaTests.ColumnInfo("base_url", "TEXT", notNull: true),
            SchemaTests.ColumnInfo("model", "TEXT", notNull: true),
            SchemaTests.ColumnInfo("key_ref", "TEXT", notNull: false),
            SchemaTests.ColumnInfo("test_outcome", "TEXT", notNull: false),
            SchemaTests.ColumnInfo("updated_at", "TEXT", notNull: true),
        ])
        #expect(usage == [
            SchemaTests.ColumnInfo("id", "TEXT", notNull: true, pk: 1),
            SchemaTests.ColumnInfo("model", "TEXT", notNull: true),
            SchemaTests.ColumnInfo("purpose", "TEXT", notNull: true),
            SchemaTests.ColumnInfo("input_tokens", "INTEGER", notNull: false),
            SchemaTests.ColumnInfo("output_tokens", "INTEGER", notNull: false),
            SchemaTests.ColumnInfo("outcome", "TEXT", notNull: true),
            SchemaTests.ColumnInfo("at", "TEXT", notNull: true),
        ])
        #expect(indexes == ["usage_at"])
    }

    @Test("a v4 database with rows migrates to v5, keeps every row and gains only the two tables and the index")
    func version4DatabaseMigratesToVersion5() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var upToVersion4 = DatabaseMigrator()
        Schema.registerV1(in: &upToVersion4)
        Schema.registerV2(in: &upToVersion4)
        Schema.registerV3(in: &upToVersion4)
        Schema.registerV4(in: &upToVersion4)
        let clock = TestClock()
        let before: DatabaseSnapshot
        do {
            let store = LibraryStore(directory: directory, now: clock.now)
            let library = try await store.open(.normal, migrator: upToVersion4, create: true)
            let world = try await library.createCategory(name: "World", icon: .globe)
            try await Sample.fill(library, category: world.id, prefix: "v4", at: clock.now())
            try await library.setLastRefreshAt(clock.now())
            before = try await library.pool.read { try DatabaseSnapshot.read($0) }
        }
        #expect(before.appliedMigrations == ["v1", "v2", "v3", "v4"])

        let library = try await LibraryStore(directory: directory).openNormal()

        let after = try await library.pool.read { try DatabaseSnapshot.read($0) }
        #expect(after.appliedMigrations == ["v1", "v2", "v3", "v4", "v5"])
        for (table, rows) in before.rows where table != "grdb_migrations" {
            #expect(after.rows[table] == rows, "rows of \(table)")
        }
        #expect(after.rows["model_slot"] == [])
        #expect(after.rows["usage"] == [])
        #expect(after.integrity == ["ok"])
        let added = after.schema.filter { !before.schema.contains($0) }.map { "\($0[0] ?? "") \($0[1] ?? "")" }
        #expect(added.sorted() == [
            "index sqlite_autoindex_model_slot_1", "index sqlite_autoindex_usage_1", "index usage_at", "table model_slot", "table usage",
        ])
        #expect(before.schema.allSatisfy { after.schema.contains($0) })
    }

    // MARK: - Saving

    @Test("a primary is saved with its key in the store and only a reference in the row; saving sends nothing")
    func savePrimary() async throws {
        let http = StubModelHTTP.answering(500)
        let fixture = try await ModelsFixture.make(http: http)
        defer { fixture.remove() }
        let status = try await fixture.save(address: " https://api.example.invalid/v1/ ", model: " test-model ", key: "  sk-saved-key-0123456789\n")
        #expect(status.key == .present(lastFour: "6789"))
        let slot = try #require(try await fixture.slot())
        #expect(slot.baseURL == "https://api.example.invalid/v1")
        #expect(slot.model == "test-model")
        #expect(slot.preset == .custom)
        #expect(slot.testOutcome == nil)
        let reference = try #require(slot.keyRef)
        #expect(fixture.keys.references == [reference])
        #expect(try fixture.keys.read(reference) == key("sk-saved-key-0123456789"))
        #expect(http.received.isEmpty)
        #expect(try await fixture.usage().isEmpty)
        let statuses = try await fixture.models.statuses()
        #expect(statuses[.primary]?.key == .present(lastFour: "6789"))
        #expect(statuses[.backup] == nil)
    }

    @Test("a short key shows only the dots")
    func shortKey() async throws {
        let fixture = try await ModelsFixture.make(http: StubModelHTTP.answering(500))
        defer { fixture.remove() }
        #expect(try await fixture.save(key: "sk-short").key == .present(lastFour: nil))
    }

    @Test("an address, model name or key that is refused saves nothing")
    func refusedValues() async throws {
        let fixture = try await ModelsFixture.make(http: StubModelHTTP.answering(500))
        defer { fixture.remove() }
        #expect(await thrown { try await fixture.save(address: "http://api.example.invalid/v1") } as? ModelSettingsError == .invalidAddress(.notHTTPS))
        #expect(await thrown { try await fixture.save(model: " ") } as? ModelSettingsError == .invalidModelName(.empty))
        #expect(try await fixture.slot() == nil)
        #expect(fixture.keys.references.isEmpty)
    }

    @Test("a backup needs a primary; the primary is not removed while a backup exists")
    func backupRules() async throws {
        let fixture = try await ModelsFixture.make(http: StubModelHTTP.answering(500))
        defer { fixture.remove() }
        #expect(await thrown { try await fixture.save(.backup) } as? ModelSettingsError == .primaryNeeded)
        #expect(fixture.keys.references.isEmpty)
        try await fixture.save(.primary)
        try await fixture.save(.backup, key: "sk-backup-key-0123456789")
        #expect(fixture.keys.references.count == 2)
        #expect(await thrown { try await fixture.models.removeSlot(.primary) } as? ModelSettingsError == .backupExists)
        #expect(try await fixture.slot(.primary) != nil)
        #expect(fixture.keys.references.count == 2)
        try await fixture.models.removeSlot(.backup)
        try await fixture.models.removeSlot(.primary)
        #expect(try await fixture.models.statuses().isEmpty)
        #expect(fixture.keys.references.isEmpty)
    }

    @Test("the database refuses a backup row without a primary even when asked directly")
    func backupRuleInStorage() async throws {
        let fixture = try await ModelsFixture.make(http: StubModelHTTP.answering(500))
        defer { fixture.remove() }
        let slot = ModelSlot(role: .backup, preset: .custom, baseURL: "https://a.invalid", model: "m", keyRef: nil, testOutcome: nil, updatedAt: Date())
        #expect(await thrown { try await fixture.library.saveModelSlot(slot) } as? ModelSettingsError == .primaryNeeded)
    }

    @Test("a new key: added under a new reference, the row written, then the old item removed")
    func replaceKey() async throws {
        let fixture = try await ModelsFixture.make(http: StubModelHTTP.answering(500))
        defer { fixture.remove() }
        try await fixture.save(key: "sk-first-key-0123456789")
        let first = try #require(try await fixture.slot()?.keyRef)
        try await fixture.save(key: "sk-second-key-987654321")
        let second = try #require(try await fixture.slot()?.keyRef)
        #expect(first != second)
        #expect(fixture.keys.references == [second])
        #expect(try fixture.keys.read(second) == key("sk-second-key-987654321"))
    }

    @Test("saving without a new key keeps the stored key while the origin is unchanged; a path change keeps it")
    func keepKeyOnSameOrigin() async throws {
        let fixture = try await ModelsFixture.make(http: StubModelHTTP.answering(500))
        defer { fixture.remove() }
        try await fixture.save(address: "https://api.example.invalid/v1")
        let reference = try #require(try await fixture.slot()?.keyRef)
        try await fixture.save(address: "https://API.example.invalid:443/v2", model: "other", key: nil)
        #expect(try await fixture.slot()?.keyRef == reference)
        #expect(fixture.keys.references == [reference])
    }

    @Test("criterion 13: after the host changes, Save removes the stored item and writes no reference")
    func changedOriginDropsKey() async throws {
        let fixture = try await ModelsFixture.make(http: StubModelHTTP.answering(500))
        defer { fixture.remove() }
        try await fixture.save(address: "https://api.openai.com/v1", preset: .openAI)
        let status = try await fixture.save(address: ModelPreset.deepSeek.address, key: nil, preset: .deepSeek)
        #expect(status.key == .missing)
        #expect(try await fixture.slot()?.keyRef == nil)
        #expect(fixture.keys.references.isEmpty)
        #expect(try await fixture.models.statuses()[.primary]?.key == .missing)
    }

    @Test("after the host changes, a newly typed key is kept and the old item removed")
    func changedOriginWithNewKey() async throws {
        let fixture = try await ModelsFixture.make(http: StubModelHTTP.answering(500))
        defer { fixture.remove() }
        try await fixture.save(address: "https://api.openai.com/v1")
        let status = try await fixture.save(address: "https://api.deepseek.com", key: "sk-deepseek-0123456789")
        let reference = try #require(try await fixture.slot()?.keyRef)
        #expect(status.key == .present(lastFour: "6789"))
        #expect(fixture.keys.references == [reference])
    }

    // MARK: - Failures

    @Test("the keychain refusing the new key fails the save and writes nothing")
    func keychainRefusesAdd() async throws {
        let fixture = try await ModelsFixture.make(http: StubModelHTTP.answering(500))
        defer { fixture.remove() }
        try await fixture.save(model: "first")
        let before = try await fixture.slot()
        fixture.keys.refuseAdds = true
        #expect(await thrown { try await fixture.save(model: "second", key: "sk-new-key-0123456789") } as? ModelSettingsError == .keyNotSaved)
        #expect(try await fixture.slot() == before)
        #expect(fixture.keys.references == [try #require(before?.keyRef)])
    }

    @Test("a row that cannot be written removes the new item and leaves the old slot unchanged")
    func rowWriteFails() async throws {
        let fixture = try await ModelsFixture.make(http: StubModelHTTP.answering(500))
        defer { fixture.remove() }
        try await fixture.save(model: "first", key: "sk-old-key-0123456789")
        let before = try #require(try await fixture.slot())
        try await fixture.failSlotWrites()
        let error = await thrown { try await fixture.save(model: "second", key: "sk-new-key-0123456789") }
        #expect(error is LibraryError)
        #expect(try await fixture.slot() == before)
        #expect(fixture.keys.references == [try #require(before.keyRef)])
        #expect(try fixture.keys.read(try #require(before.keyRef)) == key("sk-old-key-0123456789"))
    }

    @Test("a keychain that refuses a removal stops the removal; the row stays")
    func keychainRefusesRemoval() async throws {
        let fixture = try await ModelsFixture.make(http: StubModelHTTP.answering(500))
        defer { fixture.remove() }
        try await fixture.save()
        let before = try await fixture.slot()
        fixture.keys.refuseRemovals = true
        #expect(await thrown { try await fixture.models.removeKey(.primary) } as? ModelSettingsError == .keyNotRemoved)
        #expect(await thrown { try await fixture.models.removeSlot(.primary) } as? ModelSettingsError == .keyNotRemoved)
        #expect(try await fixture.slot() == before)
    }

    // MARK: - Key needed (criterion 12)

    @Test("removing the key leaves the slot at key needed, not tested")
    func removeKey() async throws {
        let fixture = try await ModelsFixture.make(http: StubModelHTTP.answering(500))
        defer { fixture.remove() }
        try await fixture.save(tested: .passed)
        try await fixture.models.removeKey(.primary)
        let slot = try #require(try await fixture.slot())
        #expect(slot.keyRef == nil)
        #expect(slot.testOutcome == nil)
        #expect(fixture.keys.references.isEmpty)
        #expect(try await fixture.models.statuses()[.primary]?.key == .missing)
    }

    @Test("a slot whose item is missing shows key needed and can still be removed")
    func missingItem() async throws {
        let fixture = try await ModelsFixture.make(http: StubModelHTTP.answering(500))
        defer { fixture.remove() }
        try await fixture.save()
        fixture.keys.lose(try #require(try await fixture.slot()?.keyRef))
        #expect(try await fixture.models.statuses()[.primary]?.key == .missing)
        try await fixture.models.removeSlot(.primary)
        #expect(try await fixture.slot() == nil)
    }

    @Test("a slot with no reference can be removed")
    func removeKeylessSlot() async throws {
        let fixture = try await ModelsFixture.make(http: StubModelHTTP.answering(500))
        defer { fixture.remove() }
        try await fixture.save(key: nil)
        #expect(try await fixture.models.statuses()[.primary]?.key == .missing)
        try await fixture.models.removeSlot(.primary)
        #expect(try await fixture.slot() == nil)
    }

    @Test("a keychain that cannot be read shows key needed")
    func unreadableKeychain() async throws {
        let fixture = try await ModelsFixture.make(http: StubModelHTTP.answering(500))
        defer { fixture.remove() }
        try await fixture.save()
        fixture.keys.refuseReads = true
        #expect(try await fixture.models.statuses()[.primary]?.key == .missing)
    }

    // MARK: - Test results kept and cleared (criterion 11)

    @Test("a result tested with the form is kept at Save; an unchanged save keeps it; a change clears it")
    func testOutcomeKeptAndCleared() async throws {
        let fixture = try await ModelsFixture.make(http: StubModelHTTP.answering(500))
        defer { fixture.remove() }
        try await fixture.save(model: "m1", tested: .passed)
        #expect(try await fixture.slot()?.testOutcome == .passed)
        // Saved unchanged (another preset label, same address, model, key).
        try await fixture.save(model: "m1", key: nil, preset: .openAI)
        #expect(try await fixture.slot()?.testOutcome == .passed)
        // A path change is a change of address.
        try await fixture.save(address: "https://api.example.invalid/v2", model: "m1", key: nil)
        #expect(try await fixture.slot()?.testOutcome == nil)
        try await fixture.save(address: "https://api.example.invalid/v2", model: "m1", key: nil, tested: .keyRejected)
        #expect(try await fixture.slot()?.testOutcome == .keyRejected)
        try await fixture.save(address: "https://api.example.invalid/v2", model: "m2", key: nil)
        #expect(try await fixture.slot()?.testOutcome == nil)
        try await fixture.save(address: "https://api.example.invalid/v2", model: "m2", key: nil, tested: .passed)
        try await fixture.save(address: "https://api.example.invalid/v2", model: "m2", key: "sk-another-0123456789")
        #expect(try await fixture.slot()?.testOutcome == nil)
    }
}
