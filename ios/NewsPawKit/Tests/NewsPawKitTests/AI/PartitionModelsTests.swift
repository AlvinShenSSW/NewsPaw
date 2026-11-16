import Foundation
import GRDB
@testable import NewsPawKit
import Testing

/// RD19 criteria 1, 2 and 3 (spec N08): each partition's text reaches only
/// that partition's own slots, with that partition's key, and is counted in
/// that partition's own usage table; there is no borrowing, and the same
/// service and key entered in both partitions are two separate items.
@Suite("Models of each partition")
struct PartitionModelsTests {
    static let normalAddress = "https://normal.example.invalid/v1"
    static let adultAddress = "https://adult.example.invalid/v1"
    static let normalKey = "sk-normal-key-0123456789"
    static let adultKey = "sk-adult-key-9876543210"

    /// Both libraries of one store, each with its own key store, and each
    /// partition's models on one recording HTTP stand-in, so that every
    /// request of either is seen.
    struct Partitions {
        let directory: URL
        let normal: Library
        let adult: Library
        let normalKeys: InMemoryKeyStore
        let adultKeys: InMemoryKeyStore
        let http: StubModelHTTP
        let normalModels: LibraryModels
        let adultModels: LibraryModels

        static func make() async throws -> Partitions {
            let directory = try makeTemporaryDirectory()
            let store = LibraryStore(directory: directory, cacheRoot: directory.appending(path: "Images"))
            let normal = try await store.openNormal()
            let adult = try await store.createAdultLibrary()
            let normalKeys = InMemoryKeyStore(partition: .normal)
            let adultKeys = InMemoryKeyStore(partition: .adult)
            let http = StubModelHTTP.completing()
            return Partitions(
                directory: directory, normal: normal, adult: adult, normalKeys: normalKeys, adultKeys: adultKeys, http: http,
                normalModels: LibraryModels(library: normal, keys: normalKeys, http: http),
                adultModels: LibraryModels(library: adult, keys: adultKeys, http: http)
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }

        static func usageCount(_ library: Library) async throws -> Int {
            try await library.pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage") ?? -1 }
        }
    }

    static func draft(_ address: String, key text: String?) -> ModelSlotDraft {
        ModelSlotDraft(role: .primary, preset: .custom, address: address, model: "test-model", newKey: text.map(key))
    }

    // MARK: - Criterion 1

    @Test("criterion 1: with working normal slots and no adult slot, the adult models send nothing and write no usage row anywhere")
    func noAdultSlotNoRequest() async throws {
        let partitions = try await Partitions.make()
        defer { partitions.remove() }
        try await partitions.normalModels.save(Self.draft(Self.normalAddress, key: Self.normalKey), testedOutcome: nil)
        // The normal slot works.
        _ = try await partitions.normalModels.send(texts: ["Hello"], instructions: "Repeat.", purpose: .titles, role: .primary)
        #expect(partitions.http.received.count == 1)

        for role in ModelRole.allCases {
            await #expect(throws: ModelFailure.noModelSetUp) {
                try await partitions.adultModels.send(texts: ["Adult text"], instructions: "Repeat.", purpose: .titles, role: role)
            }
        }

        #expect(partitions.http.received.count == 1)
        #expect(!partitions.http.received.contains { $0.url.host() == "adult.example.invalid" })
        #expect(try await Partitions.usageCount(partitions.adult) == 0)
        // The normal library has the one row of its own request, none of the adult's.
        #expect(try await Partitions.usageCount(partitions.normal) == 1)
    }

    @Test("criterion 1: RD14's translator on the adult library with no adult slot sends nothing and writes nothing, beside working normal slots")
    func adultTranslatorWithoutSlot() async throws {
        let partitions = try await Partitions.make()
        defer { partitions.remove() }
        try await partitions.normalModels.save(Self.draft(Self.normalAddress, key: Self.normalKey), testedOutcome: nil)
        let category = try await partitions.adult.createCategory(name: "Adult", icon: .folder)
        let source = Sample.source(in: category.id, url: "https://adult.example.invalid/feed", name: "Adult", at: Date())
        try await partitions.adult.insert(source)
        var ids: [UUID] = []
        for number in 1...3 {
            let article = Sample.article(in: source.id, externalID: "a-\(number)", title: "An adult story \(number)", at: Date())
            try await partitions.adult.insert(article)
            ids.append(article.id)
        }
        let translator = TitleTranslator(models: partitions.adultModels)
        await translator.configure(TranslationConfiguration(locale: .simplifiedChinese, automatic: true))
        await translator.ask(ids)
        await translator.resume(after: .refreshEnded)
        await translator.settled()
        for id in ids {
            _ = await translator.retry(id, backup: false)
        }
        await translator.settled()

        #expect(partitions.http.received.isEmpty)
        #expect(try await Partitions.usageCount(partitions.adult) == 0)
        #expect(try await Partitions.usageCount(partitions.normal) == 0)
        let rows = try await partitions.adult.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM translation WHERE state = 'done'") ?? -1
        }
        #expect(rows == 0)
        await translator.stop()
    }

    // MARK: - Criterion 2

    @Test("criterion 2: an adult request goes to the adult slot's address with the adult key and is counted in the adult library only; the reverse holds")
    func eachToItsOwn() async throws {
        let partitions = try await Partitions.make()
        defer { partitions.remove() }
        try await partitions.normalModels.save(Self.draft(Self.normalAddress, key: Self.normalKey), testedOutcome: nil)
        try await partitions.adultModels.save(Self.draft(Self.adultAddress, key: Self.adultKey), testedOutcome: nil)

        _ = try await partitions.adultModels.send(texts: ["Adult text"], instructions: "Repeat.", purpose: .titles, role: .primary)
        _ = try await partitions.adultModels.send(texts: ["More adult text"], instructions: "Repeat.", purpose: .titles, role: .primary)

        let adultRequests = partitions.http.received
        #expect(adultRequests.count == 2)
        #expect(adultRequests.allSatisfy { $0.url.host() == "adult.example.invalid" })
        #expect(adultRequests.allSatisfy { $0.authorization == key(Self.adultKey) })
        #expect(try await Partitions.usageCount(partitions.adult) == 2)
        #expect(try await Partitions.usageCount(partitions.normal) == 0)

        _ = try await partitions.normalModels.send(texts: ["Normal text"], instructions: "Repeat.", purpose: .titles, role: .primary)

        let normalRequest = try #require(partitions.http.received.last)
        #expect(normalRequest.url.host() == "normal.example.invalid")
        #expect(normalRequest.authorization == key(Self.normalKey))
        #expect(try await Partitions.usageCount(partitions.normal) == 1)
        #expect(try await Partitions.usageCount(partitions.adult) == 2)
        // A Test from the adult form is counted in the adult library too.
        _ = try await partitions.adultModels.test(Self.draft(Self.adultAddress, key: nil))
        #expect(try await Partitions.usageCount(partitions.adult) == 3)
        #expect(try await Partitions.usageCount(partitions.normal) == 1)
    }

    // MARK: - Criterion 3

    @Test("criterion 3: the keychain services of the two partitions differ")
    func twoServices() {
        #expect(KeychainKeyStore.service(for: .normal) != KeychainKeyStore.service(for: .adult))
        #expect(KeychainKeyStore(partition: .normal).service != KeychainKeyStore(partition: .adult).service)
    }

    @Test("criterion 3: the same address, model and key in both partitions are two items; removing, replacing and deleting the adult key leave the normal one usable")
    func sameKeyTwice() async throws {
        let partitions = try await Partitions.make()
        defer { partitions.remove() }
        let shared = "sk-shared-key-0123456789"
        try await partitions.normalModels.save(Self.draft(Self.normalAddress, key: shared), testedOutcome: nil)
        try await partitions.adultModels.save(Self.draft(Self.normalAddress, key: shared), testedOutcome: nil)
        #expect(partitions.normalKeys.references.count == 1)
        #expect(partitions.adultKeys.references.count == 1)
        #expect(partitions.normalKeys.references.isDisjoint(with: partitions.adultKeys.references))

        // Removing the adult key.
        try await partitions.adultModels.removeKey(.primary)
        #expect(partitions.adultKeys.references.isEmpty)
        #expect(try await partitions.adultModels.statuses()[.primary]?.key == .missing)
        #expect(try await partitions.normalModels.statuses()[.primary]?.key == .present(lastFour: "6789"))
        _ = try await partitions.normalModels.send(texts: ["Hello"], instructions: "Repeat.", purpose: .titles, role: .primary)

        // Replacing it.
        try await partitions.adultModels.save(Self.draft(Self.normalAddress, key: "sk-other-adult-key-4321"), testedOutcome: nil)
        try await partitions.adultModels.save(Self.draft(Self.normalAddress, key: shared), testedOutcome: nil)
        #expect(partitions.adultKeys.references.count == 1)
        #expect(try await partitions.normalModels.statuses()[.primary]?.key == .present(lastFour: "6789"))
        _ = try await partitions.normalModels.send(texts: ["Hello"], instructions: "Repeat.", purpose: .titles, role: .primary)

        // Delete of the adult partition removes every adult key.
        try partitions.adultKeys.removeAll()
        #expect(partitions.normalKeys.references.count == 1)
        let reply = try await partitions.normalModels.send(texts: ["Hello"], instructions: "Repeat.", purpose: .titles, role: .primary)
        #expect(!reply.texts.isEmpty)
        #expect(partitions.http.received.last?.authorization == key(shared))
    }
}
