import Foundation
@testable import NewsPawKit
import Synchronization
import Testing

/// RD19 decision 5 and criterion 7: Delete removes the adult browser's
/// website data store with the rest of the partition's data, in its place
/// in the order, and a failure to remove it leaves the partition on.
@Suite("Adult gate and the adult browser's data")
struct AdultBrowserDataGateTests {
    /// An unlocked partition with a category, a key and a cached image,
    /// locked again.
    private func filled(_ fixture: GateFixture) async throws {
        let adult = try await fixture.turnOnAndUnlock()
        _ = try await adult.createCategory(name: "Adult", icon: .heart)
        _ = try fixture.keys.add(#require(try? SecretKey.validate("sk-adult-key-1234").get()))
        #expect(await adult.imageCache.store(Data([1, 2, 3]), for: "https://example.invalid/a.png"))
        await fixture.gate.lock()
    }

    @Test("criterion 7: Delete removes the browser store after the database and the keys, and before the image cache")
    func deleteRemovesTheStoreInOrder() async throws {
        let fixture = try GateFixture()
        defer { fixture.cleanUp() }
        try await filled(fixture)
        let seen = Mutex<(files: [String], keys: Int, cache: Bool)?>(nil)
        let keys = fixture.keys
        let cache = fixture.adultCacheDirectory
        let directory = fixture.directory
        fixture.browserData.atRemoval {
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix("adult") }
            seen.withLock { $0 = (files, keys.references.count, FileManager.default.fileExists(atPath: cache.path)) }
        }

        #expect(await fixture.gate.turnOff(deletingData: true) == .turnedOff)

        #expect(fixture.browserData.calls == ["removeStore"])
        let atRemoval = try #require(seen.withLock { $0 })
        // The database files and the keys were gone, the image cache was
        // still there: it is removed last.
        #expect(atRemoval.files.isEmpty)
        #expect(atRemoval.keys == 0)
        #expect(atRemoval.cache)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        #expect(await fixture.gate.state == .off)
    }

    @Test("criterion 7: a browser store that cannot be removed leaves the partition on, and Delete can be tried again")
    func deleteFailsOnTheStore() async throws {
        let fixture = try GateFixture()
        defer { fixture.cleanUp() }
        try await filled(fixture)
        fixture.browserData.refuseRemoval = true

        #expect(await fixture.gate.turnOff(deletingData: true) == .couldNotDelete)

        #expect(await fixture.gate.state == .locked)
        #expect(Preferences(fixture.defaults).adultPartitionIsOn)
        // The image cache comes after the store, so it is still there.
        #expect(FileManager.default.fileExists(atPath: fixture.adultCacheDirectory.path))
        fixture.browserData.refuseRemoval = false
        #expect(await fixture.gate.turnOff(deletingData: true) == .turnedOff)
        #expect(fixture.browserData.calls == ["removeStore", "removeStore"])
        #expect(!FileManager.default.fileExists(atPath: fixture.adultCacheDirectory.path))
        #expect(await fixture.gate.state == .off)
    }

    @Test("Keep Data Hidden leaves the browser's data as it is")
    func keepHiddenKeepsTheStore() async throws {
        let fixture = try GateFixture()
        defer { fixture.cleanUp() }
        try await filled(fixture)

        #expect(await fixture.gate.turnOff(deletingData: false) == .turnedOff)

        #expect(fixture.browserData.calls.isEmpty)
    }

    @Test("A2: an in-use refusal of the store, after its data were removed, counts as removed; any other error does not")
    func inUseCountsAsRemoved() {
        let inUse = NSError(domain: "WKWebSiteDataStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Data store is in use"])
        let other = NSError(domain: "WKWebSiteDataStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Identifier is invalid"])
        #expect(WebKitAdultBrowserData.isInUse(inUse))
        #expect(!WebKitAdultBrowserData.isInUse(other))
    }
}
