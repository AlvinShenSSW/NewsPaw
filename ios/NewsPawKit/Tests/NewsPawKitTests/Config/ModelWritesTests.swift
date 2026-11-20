import Foundation
@testable import NewsPawKit
import Testing

/// Gate review of batch 2 (RD20 with RD19): a write of model slots or keys
/// and a configuration import's write are never interleaved. A write the
/// owner starts during the import's write is refused; one under way when
/// the import's write begins ends before it (`ModelWrites.settle`, which
/// `AppModel.settleLibraryEdits` awaits). Afterwards every slot's reference
/// names a keychain item and no item is left that no slot names.
/// What the writes in a test did, in order, and the continuation that
/// lets a held write go.
@MainActor
final class WriteLog {
    var events: [String] = []
    var release: CheckedContinuation<Void, Never>?
}

@MainActor
@Suite("Model writes and an import's write", .serialized)
struct ModelWritesTests {
    typealias J = ConfigurationJSON

    static let address = "https://models.example/v1"

    static func draft(newKey: String?, address: String = Self.address) -> ModelSlotDraft {
        ModelSlotDraft(role: .primary, preset: .custom, address: address, model: "m", newKey: newKey.map(secretKey))
    }

    /// A Replace whose normal primary has another address: the import clears
    /// the slot's reference and removes its keychain item.
    static func replacingDocument() throws -> ConfigurationDocument {
        try readDocument(J.with { object in
            ConfigurationImportTests.normalOnly(&object)
            object["model_slots"] = [J.slot(partition: "normal", role: "primary", address: "https://elsewhere.example/v1", model: "m")]
        })
    }

    /// Every slot's reference names an item, and every item is named.
    static func expectSlotsAndKeychainAgree(_ fixture: ConfigurationFixture, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let named = Set(try await fixture.normal.configurationSlotReferences().values.compactMap { $0 })
        #expect(named == fixture.normalKeys.references, "slots name \(named), the keychain holds \(fixture.normalKeys.references)",
                sourceLocation: sourceLocation)
    }

    @Test("the gate's order: a save asked for while the import writes is refused; the slot and the keychain agree after Replace")
    func refusedDuringTheImportsWrite() async throws {
        let fixture = try await ConfigurationFixture.make(adult: false)
        defer { fixture.remove() }
        let models = fixture.models(.normal)
        try await models.save(Self.draft(newKey: "sk-before-the-import-0001"), testedOutcome: nil)

        var operations = PartitionOperations()
        let begun = operations.begin(.configurationImport)
        let token = try #require(begun)
        let writes = ModelWrites()
        let log = WriteLog()
        // The owner's Save of the unchanged form: it would read the slot
        // before the import and write its reference back after it.
        let started = writes.start(refused: operations.refusesModelEdits) {
            log.events.append("ran")
            _ = try? await models.save(Self.draft(newKey: nil), testedOutcome: nil)
        }
        await writes.settle()
        _ = await fixture.importDocument(try Self.replacingDocument(), mode: .replace)
        operations.end(token)

        #expect(!started, "a model write began during the import's write")
        #expect(log.events.isEmpty)
        let status = try #require(try await models.statuses()[.primary])
        #expect(status.slot.baseURL == "https://elsewhere.example/v1")
        #expect(status.key == .missing)
        try await Self.expectSlotsAndKeychainAgree(fixture)
        // Once the import's write has ended, a save begins again.
        #expect(writes.start(refused: operations.refusesModelEdits) {})
    }

    @Test("the reverse order: a save under way when the import's write begins ends before the write reads the library")
    func runningSaveEndsFirst() async throws {
        let fixture = try await ConfigurationFixture.make(adult: false)
        defer { fixture.remove() }
        let models = fixture.models(.normal)
        try await models.save(Self.draft(newKey: "sk-before-the-import-0001"), testedOutcome: nil)

        let writes = ModelWrites()
        let log = WriteLog()
        let held = AsyncStream<Void>.makeStream()
        // The save is under way: its task began and waits to be let go.
        #expect(writes.start(refused: false) {
            await withCheckedContinuation { continuation in
                log.release = continuation
                held.continuation.yield()
            }
            _ = try? await models.save(Self.draft(newKey: "sk-during-the-import-02"), testedOutcome: nil)
            log.events.append("saved")
        })
        var waiting = held.stream.makeAsyncIterator()
        _ = await waiting.next()
        #expect(writes.isRunning)

        // The import's write begins: the drain first, as AppModel's settle.
        let document = try Self.replacingDocument()
        let importing = Task { @MainActor in
            await writes.settle()
            log.events.append("settled")
            _ = await fixture.importDocument(document, mode: .replace)
            log.events.append("imported")
        }
        for _ in 0..<200 {
            await Task.yield()
        }
        #expect(log.events.isEmpty, "the import's write began while a save was under way: \(log.events)")
        log.release?.resume()
        await importing.value

        #expect(log.events == ["saved", "settled", "imported"])
        let status = try #require(try await models.statuses()[.primary])
        #expect(status.slot.baseURL == "https://elsewhere.example/v1")
        #expect(status.key == .missing)
        try await Self.expectSlotsAndKeychainAgree(fixture)
    }
}
