import Foundation
@testable import NewsPawKit
import Testing

/// RD18 decision 9: `KeyStore.removeAll()`, on the in-memory store. The
/// keychain itself is not called by an offline test.
@Suite("KeyStore.removeAll")
struct KeyStoreRemoveAllTests {
    private func key(_ text: String) throws -> SecretKey {
        try SecretKey.validate(text).get()
    }

    @Test("every item of the store is removed, and an empty store counts as removed")
    func removesEverything() throws {
        let store = InMemoryKeyStore(partition: .adult)
        let first = try store.add(key("sk-first-key-0001"))
        let second = try store.add(key("sk-second-key-0002"))
        #expect(store.references == [first, second])

        try store.removeAll()

        #expect(store.references.isEmpty)
        #expect(try store.read(first) == nil)
        try store.removeAll()
    }

    @Test("another partition's store keeps its items")
    func otherPartitionKeepsItsItems() throws {
        let normal = InMemoryKeyStore(partition: .normal)
        let adult = InMemoryKeyStore(partition: .adult)
        let kept = try normal.add(key("sk-normal-key-0001"))
        _ = try adult.add(key("sk-adult-key-0002"))

        try adult.removeAll()

        #expect(adult.references.isEmpty)
        #expect(normal.references == [kept])
    }

    @Test("a store that refuses removals fails and keeps its items")
    func refusal() throws {
        let store = InMemoryKeyStore(partition: .adult)
        _ = try store.add(key("sk-first-key-0001"))
        store.refuseRemovals = true

        #expect(throws: KeyStoreError.self) { try store.removeAll() }
        #expect(store.references.count == 1)
    }

    @Test("the keychain store deletes by its own partition's service only")
    func keychainServices() {
        #expect(KeychainKeyStore(partition: .adult).service == "io.newspaw.reader.model-key.adult")
        #expect(KeychainKeyStore(partition: .normal).service == "io.newspaw.reader.model-key.normal")
        #expect(KeychainKeyStore(partition: .adult).service != KeychainKeyStore(partition: .normal).service)
        // Neither service is a prefix of the other's items' service: a
        // delete over one service matches that service exactly.
        #expect(KeychainKeyStore(partition: .adult, uiTestSuffix: "uitest-1").service == "io.newspaw.reader.model-key.adult.uitest-1")
    }
}
