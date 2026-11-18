import Foundation
@testable import NewsPawKit
import Testing

/// RD19 decision 7 and criterion 9: no image store lands after a clear. A
/// fetch already in flight when the cache is cleared — the move clears the
/// old partition's cache — stores nothing, through either loader; a fetch
/// that begins after the clear stores as before.
@Suite("Image cache generation")
struct ImageCacheGenerationTests {
    private typealias Images = ThumbnailLoaderTests

    private func makeCache() throws -> (URL, ImageCache) {
        let root = try makeTemporaryDirectory()
        return (root, ImageCache(directory: root.appending(path: "cache")))
    }

    /// A transport that holds every fetch until `go` fires, counting those
    /// in flight.
    private static func held(_ body: Data, until go: Signal) -> CountingTransport {
        CountingTransport { url in
            await go.wait()
            return TransportResponse(finalURL: url, status: 200, headers: ["Content-Type": "image/png"], body: body)
        }
    }

    /// Waits, with a bound a stalled runner does not reach, until
    /// `condition` holds.
    private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @Test("a store made with a generation read before a clear writes nothing; the current generation stores")
    func storeAfterClear() async throws {
        let (root, cache) = try makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = await cache.generation
        #expect(await cache.store(Data([1]), for: "a"))
        await cache.clear()
        #expect(await cache.generation == before + 1)
        #expect(!(await cache.store(Data([2]), for: "b", generation: before)))
        #expect(await cache.size() == 0)
        #expect(await cache.data(for: "b") == nil)
        #expect(await cache.store(Data([3]), for: "c", generation: cache.generation))
        #expect(await cache.store(Data([4]), for: "d"))
        #expect(await cache.size() == 2)
    }

    @Test("criterion 9: a thumbnail whose fetch was in flight when the cache was cleared stores nothing")
    func thumbnailInFlightAcrossAClear() async throws {
        let (root, cache) = try makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let go = Signal()
        let transport = Self.held(Images.png(width: 400, height: 300), until: go)
        let loader = ThumbnailLoader(transport: transport, cache: cache)
        let loading = Task { await loader.thumbnail(for: "https://images.example.invalid/moved.png") }
        try await waitUntil { transport.inFlight == 1 }

        await cache.clear()
        go.fire()

        // The row still gets its picture; the cache keeps nothing of it.
        #expect(await loading.value != nil)
        #expect(await cache.size() == 0)
        #expect(await cache.data(for: ThumbnailLoader.cacheKey(for: "https://images.example.invalid/moved.png")) == nil)
        // A fetch that begins after the clear stores as before.
        #expect(await loader.thumbnail(for: "https://images.example.invalid/later.png") != nil)
        #expect(await cache.size() > 0)
    }

    @Test("criterion 9: a body image whose fetch was in flight when the cache was cleared stores nothing")
    func bodyImageInFlightAcrossAClear() async throws {
        let (root, cache) = try makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let go = Signal()
        let transport = Self.held(Images.png(width: 400, height: 300), until: go)
        let loader = BodyImageLoader(transport: transport, cache: cache)
        let address = try #require(URL(string: "https://images.example.invalid/body.png"))
        let loading = Task { await loader.image(for: address) }
        try await waitUntil { transport.inFlight == 1 }

        await cache.clear()
        go.fire()

        #expect(await loading.value != nil)
        #expect(await cache.size() == 0)
        #expect(await loader.cachedImage(for: address) == nil)
        let later = try #require(URL(string: "https://images.example.invalid/later.png"))
        #expect(await loader.image(for: later) != nil)
        #expect(await cache.size() > 0)
    }
}
