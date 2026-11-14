import CoreGraphics
import Foundation
import ImageIO
@testable import NewsPawKit
import Testing
import UniformTypeIdentifiers

/// RD11 criterion 10, the loader's limits: a fake transport and images made
/// here.
@Suite("Body image loader")
struct BodyImageLoaderTests {
    private typealias Images = ThumbnailLoaderTests

    private func makeCache(_ name: String = "cache") throws -> (URL, ImageCache) {
        let root = try makeTemporaryDirectory()
        return (root, ImageCache(directory: root.appending(path: name)))
    }

    private func url(_ name: String) -> URL {
        URL(string: "https://images.example.invalid/\(name)")!
    }

    private func files(of cache: ImageCache) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: cache.directory.path)) ?? []
    }

    @Test("an image is reduced to at most 2,048 pixels, stored as JPEG under its own address, never as received, and then answered from the cache")
    func validImage() async throws {
        let (root, cache) = try makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let received = Images.png(width: 4_000, height: 1_000)
        let transport = Images.answering(received)
        let loader = BodyImageLoader(transport: transport, cache: cache)

        let data = try #require(await loader.image(for: url("wide.png")))
        let decoded = try Images.decode(data)
        #expect(decoded.type == UTType.jpeg.identifier)
        #expect(decoded.width == 2_048)
        #expect(decoded.height == 512)
        #expect(await cache.data(for: "https://images.example.invalid/wide.png") == data)
        #expect(BodyImageLoader.cacheKey(for: url("wide.png")) == "https://images.example.invalid/wide.png")
        #expect(BodyImageLoader.pixelSize(of: data)?.width == 2_048)
        #expect(BodyImageLoader.pixelSize(of: data)?.height == 512)

        #expect(await loader.image(for: url("wide.png")) == data)
        #expect(transport.received.count == 1, "the second request was answered from the cache")
        // A new loader on the same cache, as after a relaunch.
        #expect(await BodyImageLoader(transport: transport, cache: cache).image(for: url("wide.png")) == data)
        #expect(transport.received.count == 1)

        // Every stored file is the re-encoded JPEG; none holds what came in.
        for name in files(of: cache) {
            let stored = try Data(contentsOf: cache.directory.appending(path: name))
            #expect(stored != received)
            #expect(try Images.decode(stored).type == UTType.jpeg.identifier)
        }
    }

    @Test("an image smaller than the bound keeps its size: it is never enlarged")
    func smallImageKeepsItsSize() async throws {
        let (root, cache) = try makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let small = BodyImageLoader(transport: Images.answering(Images.png(width: 120, height: 90)), cache: cache)
        let data = try #require(await small.image(for: url("small.png")))
        #expect(BodyImageLoader.pixelSize(of: data)?.width == 120)
        #expect(BodyImageLoader.pixelSize(of: data)?.height == 90)
        // A pixel that declared no size is stored at its size; who draws
        // it sees that it is under 8 pixels.
        let pixel = BodyImageLoader(transport: Images.answering(Images.png(width: 1, height: 1)), cache: cache)
        let one = try #require(await pixel.image(for: url("pixel.png")))
        let size = try #require(BodyImageLoader.pixelSize(of: one))
        #expect(size.width == 1 && size.height == 1)
        #expect(size.width < BodyImageLoader.minimumDrawnSide)
        // Decoding for the screen does not enlarge either.
        #expect(BodyImageLoader.decoded(data, maximumPixelSize: 2_000)?.width == 120)
        #expect(BodyImageLoader.decoded(data, maximumPixelSize: 60)?.width == 60)
        #expect(BodyImageLoader.decoded(data, maximumPixelSize: 60)?.height == 45)
        #expect(BodyImageLoader.decoded(Data("not an image".utf8), maximumPixelSize: 60) == nil)
    }

    @Test("a transparent image comes out on white")
    func transparentOnWhite() async throws {
        let (root, cache) = try makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = BodyImageLoader(transport: Images.answering(Images.png(width: 400, height: 400, transparent: true)), cache: cache)
        let decoded = try Images.decode(try #require(await loader.image(for: url("clear.png"))))
        #expect(decoded.width == 400 && decoded.height == 400)
        #expect(Images.pixel(decoded.image, x: 3, y: 3).allSatisfy { $0 >= 245 })
    }

    @Test("an answer of more than 10 MB is refused and stores nothing; one of exactly 10 MB is taken")
    func receivedBytesBound() async throws {
        let (root, cache) = try makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        // A valid image followed by padding, which the decoder ignores.
        let image = Images.png(width: 300, height: 200)
        let limit = BodyImageLoader.maximumReceivedBytes
        #expect(limit == 10 * 1024 * 1024)
        let atLimit = image + Data(count: limit - image.count)
        let over = image + Data(count: limit - image.count + 1)
        let refused = BodyImageLoader(transport: Images.answering(over), cache: cache)
        #expect(await refused.image(for: url("over.png")) == nil)
        #expect(await cache.size() == 0)
        #expect(files(of: cache).isEmpty)
        let taken = BodyImageLoader(transport: Images.answering(atLimit), cache: cache)
        let data = try #require(await taken.image(for: url("at-limit.png")))
        #expect(BodyImageLoader.pixelSize(of: data)?.width == 300)
        #expect(data.count < 100_000, "the padding is not stored")
    }

    @Test("an image declaring more than 40 million pixels is refused and stores nothing")
    func declaredPixelBound() async throws {
        let (root, cache) = try makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let over = Images.png(width: 7_000, height: 6_000, gray: true)
        let loader = BodyImageLoader(transport: Images.answering(over), cache: cache)
        #expect(await loader.image(for: url("over.png")) == nil)
        #expect(await cache.size() == 0)
    }

    @Test("something that is not an image, a failed answer and a failed fetch yield nothing and store nothing; each is asked for again")
    func failuresAreNotRemembered() async throws {
        let (root, cache) = try makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = Images.answering(Data("<html>not an image</html>".utf8))
        let svg = Images.answering(Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>"#.utf8))
        let notFound = Images.answering(Images.png(width: 50, height: 50), status: 404)
        let unreachable = CountingTransport { _ in throw TransportFailure.unreachable }
        for (name, transport) in [("text", text), ("svg", svg), ("404", notFound), ("unreachable", unreachable)] {
            let loader = BodyImageLoader(transport: transport, cache: cache)
            #expect(await loader.image(for: url(name)) == nil, "\(name)")
            #expect(await loader.image(for: url(name)) == nil, "\(name) again")
            #expect(transport.received.count == 2, "\(name): a failure is not remembered by the loader")
        }
        #expect(await cache.size() == 0)
        #expect(files(of: cache).isEmpty)

        // An image that fails and then answers is shown the second time.
        let image = Images.png(width: 50, height: 50)
        let failedOnce = Holder<Bool>()
        let flaky = CountingTransport { url in
            if failedOnce.value == nil {
                failedOnce.set(true)
                throw TransportFailure.timedOut
            }
            return TransportResponse(finalURL: url, status: 200, headers: [:], body: image)
        }
        let loader = BodyImageLoader(transport: flaky, cache: cache)
        #expect(await loader.image(for: url("flaky.png")) == nil)
        #expect(await loader.image(for: url("flaky.png")) != nil)
    }

    @Test("an address the transport may not request is never sent")
    func refusedAddresses() async throws {
        let (root, cache) = try makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = Images.answering(Images.png(width: 50, height: 50))
        let loader = BodyImageLoader(transport: transport, cache: cache)
        #expect(await loader.image(for: URL(string: "file:///etc/hosts")!) == nil)
        #expect(await loader.image(for: URL(string: "https://user:secret@images.example.invalid/a.png")!) == nil)
        #expect(await loader.image(for: URL(string: "data:image/png;base64,AAAA")!) == nil)
        #expect(transport.received.isEmpty)
    }

    @Test("never more than 3 requests in flight, also after waiting requests were cancelled; no slot is lost")
    func atMostThreeInFlight() async throws {
        let (root, cache) = try makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(BodyImageLoader.standardLimit == 3)
        let image = Images.png(width: 40, height: 40)
        let go = Signal()
        let transport = CountingTransport { url in
            await go.wait()
            return TransportResponse(finalURL: url, status: 200, headers: [:], body: image)
        }
        let loader = BodyImageLoader(transport: transport, cache: cache)
        let urls = (0..<30).map { url("\($0).png") }
        var tasks: [URL: Task<Data?, Never>] = [:]
        for url in urls {
            tasks[url] = Task { await loader.image(for: url) }
        }
        try await waitUntil { transport.inFlight == 3 }
        // Let every other request reach the queue.
        try await Task.sleep(for: .milliseconds(200))
        let requested = Set(transport.received)
        #expect(requested.count == 3)
        let cancelled = Array(urls.filter { !requested.contains($0) }.prefix(20))
        for url in cancelled {
            tasks[url]?.cancel()
        }
        go.fire()
        var results: [URL: Data?] = [:]
        for (url, task) in tasks {
            results[url] = await task.value
        }
        #expect(transport.mostInFlight == 3)
        #expect(cancelled.allSatisfy { results[$0] == .some(nil) }, "a cancelled request yields nothing")
        let completed = urls.filter { !cancelled.contains($0) }
        #expect(completed.count == 10)
        #expect(completed.allSatisfy { results[$0] != .some(nil) })
        #expect(Set(transport.received) == Set(completed), "a cancelled waiter made no request")

        // Afterwards the three slots are all there.
        let more = (30..<38).map { url("\($0).png") }
        let all = await withTaskGroup(of: Data?.self) { group in
            for url in more {
                group.addTask { await loader.image(for: url) }
            }
            return await group.reduce(into: [Data?]()) { $0.append($1) }
        }
        #expect(all.allSatisfy { $0 != nil })
        #expect(transport.mostInFlight == 3)
    }

    @Test("a request cancelled while its fetch is in flight stores nothing")
    func cancelledStoresNothing() async throws {
        let (root, cache) = try makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = Images.png(width: 400, height: 300)
        let go = Signal()
        let transport = CountingTransport { url in
            await go.wait()
            return TransportResponse(finalURL: url, status: 200, headers: [:], body: image)
        }
        let loader = BodyImageLoader(transport: transport, cache: cache)
        let task = Task { await loader.image(for: url("cancelled.png")) }
        try await waitUntil { transport.inFlight == 1 }
        task.cancel()
        go.fire()
        #expect(await task.value == nil)
        #expect(await cache.size() == 0)
    }

    @Test("a loader stores in its own library's cache only, and a body image and a thumbnail of one address do not answer for each other")
    func oneCacheAndItsOwnKey() async throws {
        let (root, normal) = try makeCache("normal")
        defer { try? FileManager.default.removeItem(at: root) }
        let adult = ImageCache(directory: root.appending(path: "adult"))
        let transport = Images.answering(Images.png(width: 600, height: 400))
        let loader = BodyImageLoader(transport: transport, cache: adult)
        let address = url("shared.png")
        let body = try #require(await loader.image(for: address))
        #expect(files(of: adult).count == 1)
        #expect(files(of: normal).isEmpty, "nothing of one partition's images is in the other's cache")
        #expect(await normal.data(for: address.absoluteString) == nil)
        // The other library's loader does not find it and fetches for itself.
        #expect(await BodyImageLoader(transport: transport, cache: normal).image(for: address) != nil)
        #expect(transport.received.count == 2)

        // The same address as a thumbnail is another item of the cache.
        let thumbnails = ThumbnailLoader(transport: transport, cache: adult)
        let thumbnail = try #require(await thumbnails.thumbnail(for: address.absoluteString))
        #expect(transport.received.count == 3, "the body image did not answer for the thumbnail")
        #expect(try Images.decode(thumbnail).width == 288)
        #expect(await loader.image(for: address) == body, "the thumbnail did not replace the body image")
        #expect(files(of: adult).count == 2)
    }

    private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
