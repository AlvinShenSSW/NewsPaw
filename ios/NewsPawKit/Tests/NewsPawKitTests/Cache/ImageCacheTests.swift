import Foundation
@testable import NewsPawKit
import Testing

/// RD06 criterion 13: the image cache in temporary directories.
@Suite("Image cache")
struct ImageCacheTests {
    private func bytes(_ count: Int, _ value: UInt8 = 1) -> Data {
        Data(repeating: value, count: count)
    }

    private func files(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    private func modificationDate(_ cache: ImageCache, _ address: String) throws -> Date {
        let url = cache.directory.appending(path: sha256Hex(address))
        return try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    @Test("store then read returns the same bytes; the size is the sum of the files' sizes")
    func storeAndRead() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ImageCache(directory: root.appending(path: "cache"), limit: 1_000)
        #expect(await cache.data(for: "https://example.invalid/a.png") == nil)
        #expect(await cache.store(bytes(100, 7), for: "https://example.invalid/a.png"))
        #expect(await cache.store(bytes(250, 8), for: "https://example.invalid/b.png"))
        #expect(await cache.data(for: "https://example.invalid/a.png") == bytes(100, 7))
        #expect(await cache.data(for: "https://example.invalid/b.png") == bytes(250, 8))
        #expect(await cache.size() == 350)
        // Storing the same address again replaces it.
        #expect(await cache.store(bytes(50, 9), for: "https://example.invalid/a.png"))
        #expect(await cache.data(for: "https://example.invalid/a.png") == bytes(50, 9))
        #expect(await cache.size() == 300)
    }

    @Test("the least recently used go first, and a read makes an item the most recently used")
    func leastRecentlyUsed() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ImageCache(directory: root.appending(path: "cache"), limit: 300)
        for name in ["a", "b", "c"] {
            #expect(await cache.store(bytes(100), for: name))
        }
        // a was stored first; reading it makes b the least recently used.
        #expect(await cache.data(for: "a") != nil)
        let dates = try ["a", "b", "c"].map { try modificationDate(cache, $0) }
        print("RD06 cache dates after reading a: a \(dates[0].timeIntervalSince1970), b \(dates[1].timeIntervalSince1970), c \(dates[2].timeIntervalSince1970)")
        #expect(dates[1] < dates[2] && dates[2] < dates[0], "no tie in the modification dates")

        #expect(await cache.store(bytes(150), for: "d"))

        // 450 > 300: b (100) and then c (100) go; a (100) + d (150) = 250.
        #expect(await cache.data(for: "b") == nil)
        #expect(await cache.data(for: "c") == nil)
        #expect(await cache.data(for: "a") != nil)
        #expect(await cache.data(for: "d") != nil)
        #expect(await cache.size() == 250)
    }

    @Test("an item larger than the limit is not stored and removes nothing")
    func tooLarge() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ImageCache(directory: root.appending(path: "cache"), limit: 300)
        #expect(await cache.store(bytes(200), for: "a"))
        #expect(await cache.store(bytes(301), for: "huge") == false)
        #expect(await cache.data(for: "huge") == nil)
        #expect(await cache.data(for: "a") != nil)
        #expect(await cache.size() == 200)
    }

    @Test("Clear leaves size zero; a directory that does not exist has size zero")
    func clear() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ImageCache(directory: root.appending(path: "cache"), limit: 1_000)
        #expect(await cache.size() == 0)
        #expect(!FileManager.default.fileExists(atPath: cache.directory.path))
        #expect(await cache.store(bytes(10), for: "a"))
        #expect(await cache.store(bytes(20), for: "b"))
        await cache.clear()
        #expect(await cache.size() == 0)
        #expect(files(in: cache.directory).isEmpty)
        #expect(await cache.data(for: "a") == nil)
    }

    @Test("every file is named by a hash, whatever the address")
    func fileNames() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ImageCache(directory: root.appending(path: "cache"), limit: 10_000)
        let addresses = [
            "https://example.invalid/a.png", "../../escape", "/etc/passwd", "", "with/slash", "日本語.jpg",
            "https://example.invalid/?q=1&r=../x", String(repeating: "long", count: 500),
        ]
        for address in addresses {
            #expect(await cache.store(bytes(5), for: address), "\(address)")
            #expect(await cache.data(for: address) == bytes(5), "\(address)")
        }
        let names = files(in: cache.directory)
        #expect(names.count == addresses.count)
        #expect(names.allSatisfy { $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } }, "\(names)")
        #expect(Set(names) == Set(addresses.map(sha256Hex)))
        #expect(files(in: root) == ["cache"], "nothing was written outside the cache's directory")
    }

    @Test("the two libraries of a store have separate cache directories under its root; storing in or clearing one leaves the other; opening creates none")
    func perLibrary() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheRoot = root.appending(path: "Images")
        let store = LibraryStore(directory: root.appending(path: "Libraries"), cacheRoot: cacheRoot)
        let normal = try await store.openNormal()
        let adult = try await store.createAdultLibrary()
        #expect(!FileManager.default.fileExists(atPath: cacheRoot.path), "opening a library creates no cache directory")

        let normalDirectory = normal.imageCache.directory.pathComponents
        let adultDirectory = adult.imageCache.directory.pathComponents
        #expect(normalDirectory != adultDirectory)
        #expect(Array(normalDirectory.dropLast()) == cacheRoot.pathComponents)
        #expect(Array(adultDirectory.dropLast()) == cacheRoot.pathComponents)

        #expect(await normal.imageCache.store(bytes(10), for: "shared-address"))
        #expect(await adult.imageCache.data(for: "shared-address") == nil)
        #expect(await adult.imageCache.size() == 0)
        #expect(await adult.imageCache.store(bytes(20), for: "shared-address"))
        await adult.imageCache.clear()
        #expect(await adult.imageCache.size() == 0)
        #expect(await normal.imageCache.size() == 10)
        #expect(await normal.imageCache.data(for: "shared-address") == bytes(10))
        #expect(normal.imageCache.limit == 500 * 1024 * 1024)
    }
}
