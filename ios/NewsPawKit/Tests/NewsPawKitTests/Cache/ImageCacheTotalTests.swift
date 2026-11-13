import Foundation
@testable import NewsPawKit
import Testing

/// RD09 criterion 13: the image cache keeps a running total instead of
/// listing its directory on every store. RD06's tests in
/// `ImageCacheTests` stay as they were.
@Suite("Image cache running total")
struct ImageCacheTotalTests {
    private func bytes(_ count: Int, _ value: UInt8 = 1) -> Data {
        Data(repeating: value, count: count)
    }

    /// The sum of the sizes of the files in `directory`, listed afresh.
    private func listedSize(_ directory: URL) -> Int {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    @Test("the total is taken from a listing at first use")
    func totalFromListing() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "cache")
        let first = ImageCache(directory: directory, limit: 10_000)
        #expect(await first.store(bytes(120), for: "a"))
        #expect(await first.store(bytes(80), for: "b"))
        // Another instance on the same directory has never stored anything.
        let second = ImageCache(directory: directory, limit: 10_000)
        #expect(await second.size() == 200)
        #expect(await second.store(bytes(30), for: "c"))
        #expect(await second.size() == 230)
        #expect(listedSize(directory) == 230)
    }

    @Test("storing over an existing key counts the difference")
    func replacingCountsTheDifference() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ImageCache(directory: root.appending(path: "cache"), limit: 10_000)
        #expect(await cache.store(bytes(400), for: "a"))
        #expect(await cache.store(bytes(100), for: "b"))
        #expect(await cache.store(bytes(150), for: "a"))
        #expect(await cache.size() == 250)
        #expect(await cache.store(bytes(900), for: "b"))
        #expect(await cache.size() == 1_050)
        #expect(listedSize(cache.directory) == 1_050)
    }

    @Test("eviction removes the least recently used, and the total follows")
    func evictionKeepsTheTotal() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ImageCache(directory: root.appending(path: "cache"), limit: 300)
        for name in ["a", "b", "c"] {
            #expect(await cache.store(bytes(100), for: name))
        }
        #expect(await cache.data(for: "a") != nil)
        #expect(await cache.store(bytes(120), for: "d"))
        // b (the least recently used) and then c go: a + d = 220.
        #expect(await cache.data(for: "b") == nil)
        #expect(await cache.data(for: "c") == nil)
        #expect(await cache.size() == 220)
        #expect(listedSize(cache.directory) == 220)
    }

    @Test("Clear leaves zero, and later stores count from zero")
    func clearLeavesZero() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ImageCache(directory: root.appending(path: "cache"), limit: 1_000)
        #expect(await cache.store(bytes(300), for: "a"))
        #expect(await cache.store(bytes(200), for: "b"))
        await cache.clear()
        #expect(await cache.size() == 0)
        #expect(await cache.store(bytes(40), for: "c"))
        #expect(await cache.size() == 40)
        #expect(listedSize(cache.directory) == 40)
    }

    @Test("files removed behind the cache's back are noticed at the next eviction")
    func removalsNoticedAtEviction() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ImageCache(directory: root.appending(path: "cache"), limit: 300)
        for name in ["a", "b", "c"] {
            #expect(await cache.store(bytes(100), for: name))
        }
        try FileManager.default.removeItem(at: cache.directory.appending(path: sha256Hex("a")))
        // The running total does not list the directory.
        #expect(await cache.size() == 300)
        // 400 by the running total: an eviction lists the directory, finds
        // 300, and removes nothing.
        #expect(await cache.store(bytes(100), for: "d"))
        #expect(await cache.data(for: "b") != nil)
        #expect(await cache.data(for: "c") != nil)
        #expect(await cache.data(for: "d") != nil)
        #expect(await cache.size() == 300)
        #expect(listedSize(cache.directory) == 300)
    }
}

// Nested in the serialized group: see `TimedAndHeavySuites`.
extension TimedAndHeavySuites {
    @Suite("Image cache store time")
    struct ImageCacheStoreTimeTests {
        @Test("one store into a cache of 20,000 files, timed (recorded, not gated)")
        func storeIntoManyFiles() async throws {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = root.appending(path: "cache")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let thumbnail = Data(repeating: 7, count: 12_000)
            for index in 0..<20_000 {
                try thumbnail.write(to: directory.appending(path: sha256Hex("seed-\(index)")))
            }
            let cache = ImageCache(directory: directory)
            let clock = ContinuousClock()
            let first = try await clock.measure {
                #expect(await cache.store(thumbnail, for: "first"))
            }
            var later: [Duration] = []
            for index in 0..<20 {
                later.append(await clock.measure {
                    _ = await cache.store(thumbnail, for: "later-\(index)")
                })
            }
            later.sort()
            print("RD09 image cache store into 20,000 files: first store (with the listing) \(first); later stores median \(later[10]), slowest \(later[19])")
            #expect(await cache.size() == 20_021 * 12_000)
        }
    }
}
