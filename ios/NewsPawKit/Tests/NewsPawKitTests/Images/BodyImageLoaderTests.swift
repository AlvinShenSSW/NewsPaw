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

    @Test("an image is reduced to at most 2,048 × 2,048 pixels in all, stored as JPEG under its own address, never as received, and then answered from the cache")
    func validImage() async throws {
        let (root, cache) = try makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let received = Images.png(width: 4_000, height: 2_000)
        let transport = Images.answering(received)
        let loader = BodyImageLoader(transport: transport, cache: cache)

        let data = try #require(await loader.image(for: url("wide.png")))
        let decoded = try Images.decode(data)
        #expect(decoded.type == UTType.jpeg.identifier)
        // Half of its 8,000,000 pixels and a little more: 2,896 × 1,448.
        #expect(decoded.width == 2_896)
        #expect(decoded.height == 1_448)
        #expect(await cache.data(for: "https://images.example.invalid/wide.png") == data)
        #expect(BodyImageLoader.cacheKey(for: url("wide.png")) == "https://images.example.invalid/wide.png")
        #expect(BodyImageLoader.pixelSize(of: data)?.width == 2_896)
        #expect(BodyImageLoader.pixelSize(of: data)?.height == 1_448)

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

    @Test("the stored size is bounded by the pixels in all and by 8,192 on a side, the shape kept: a long picture stays readable")
    func storedSize() async throws {
        #expect(BodyImageLoader.maximumPixelCount == 2_048 * 2_048)
        #expect(BodyImageLoader.maximumSide == 8_192)
        // Within both bounds: its own size.
        #expect(BodyImageLoader.storedLongerSide(width: 2_048, height: 2_048) == 2_048)
        #expect(BodyImageLoader.storedLongerSide(width: 4_000, height: 1_000) == 4_000)
        #expect(BodyImageLoader.storedLongerSide(width: 2_400, height: 1_600) == 2_400)
        #expect(BodyImageLoader.storedLongerSide(width: 512, height: 8_192) == 8_192)
        #expect(BodyImageLoader.storedLongerSide(width: 1, height: 1) == 1)
        // One pixel more than the count, or than the side.
        #expect(BodyImageLoader.storedLongerSide(width: 2_049, height: 2_048) == 2_048)
        #expect(BodyImageLoader.storedLongerSide(width: 100, height: 8_193) == 8_192)
        // Square, wide, and the long screenshot of a phone.
        #expect(BodyImageLoader.storedLongerSide(width: 3_000, height: 3_000) == 2_048)
        #expect(BodyImageLoader.storedLongerSide(width: 20_000, height: 2_000) == 6_472)
        #expect(BodyImageLoader.storedLongerSide(width: 1_080, height: 6_000) == 4_826)
        #expect(BodyImageLoader.storedLongerSide(width: 100, height: 30_000) == 8_192)
        // Whatever the shape, the stored image is within the count however
        // its shorter side is rounded.
        for (width, height) in [(1_080, 6_000), (6_000, 1_080), (3_001, 2_999), (7_000, 5_714), (39_999, 1_000), (1, 40_000), (4_097, 1_025)] {
            let longer = BodyImageLoader.storedLongerSide(width: width, height: height)
            let shorter = (Double(min(width, height)) * Double(longer) / Double(max(width, height))).rounded(.up)
            #expect(longer <= 8_192, "\(width) × \(height)")
            #expect(Double(longer) * shorter <= Double(2_048 * 2_048), "\(width) × \(height)")
            #expect(longer <= max(width, height), "never enlarged: \(width) × \(height)")
        }

        let (root, cache) = try makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        func stored(_ width: Int, _ height: Int, _ name: String) async throws -> (width: Int, height: Int) {
            let loader = BodyImageLoader(transport: Images.answering(Images.png(width: width, height: height, gray: true)), cache: cache)
            let data = try #require(await loader.image(for: url(name)))
            return try #require(BodyImageLoader.pixelSize(of: data))
        }
        // 1,080 × 6,000, ordinary in feeds: 369 pixels wide under the old
        // bound of 2,048 on the longer side.
        let long = try await stored(1_080, 6_000, "long.png")
        #expect(long.height == 4_826)
        #expect((868...869).contains(long.width))
        #expect(long.width * long.height <= 2_048 * 2_048)
        // Within the count: as received in size.
        let wide = try await stored(4_000, 1_000, "wide.png")
        #expect(wide.width == 4_000 && wide.height == 1_000)
        // A strip: the side bound.
        let strip = try await stored(100, 30_000, "strip.png")
        #expect(strip.height == 8_192)
        #expect((27...28).contains(strip.width))
        let square = try await stored(3_000, 3_000, "square.png")
        #expect(square.width == 2_048 && square.height == 2_048)
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

    @Test("the answer tells a failure from a cancelled request; a failure that arrives after the request was cancelled is still a failure")
    func outcomes() async throws {
        let (root, cache) = try makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = Images.png(width: 40, height: 40)
        let loaded = BodyImageLoader(transport: Images.answering(image), cache: cache)
        guard case .image(let data) = await loaded.load(url("ok.png")) else {
            Issue.record("not loaded")
            return
        }
        #expect(BodyImageLoader.pixelSize(of: data)?.width == 40)
        #expect(await loaded.load(url("ok.png")) == .image(data), "from the cache")
        #expect(await BodyImageLoader(transport: Images.answering(image, status: 500), cache: cache).load(url("500.png")) == .failed)
        #expect(await BodyImageLoader(transport: Images.answering(Data("text".utf8)), cache: cache).load(url("text.png")) == .failed)
        #expect(await loaded.load(URL(string: "file:///etc/hosts")!) == .failed)

        // The transport reports a failure after the request was cancelled.
        let go = Signal()
        let failing = CountingTransport { _ in
            await go.wait()
            throw TransportFailure.unreachable
        }
        let late = BodyImageLoader(transport: failing, cache: cache)
        let failed = Task { await late.load(url("late.png")) }
        try await waitUntil { failing.inFlight == 1 }
        failed.cancel()
        go.fire()
        #expect(await failed.value == .failed)

        // The exchange itself was cancelled: nothing is known.
        let stop = Signal()
        let cancelling = CountingTransport { _ in
            await stop.wait()
            throw CancellationError()
        }
        let cancelled = Task { await BodyImageLoader(transport: cancelling, cache: cache).load(url("cancelled.png")) }
        try await waitUntil { cancelling.inFlight == 1 }
        cancelled.cancel()
        stop.fire()
        #expect(await cancelled.value == .cancelled)

        // Cancelled while waiting for a slot: no request, nothing known.
        let hold = Signal()
        let slow = CountingTransport { url in
            await hold.wait()
            return TransportResponse(finalURL: url, status: 200, headers: [:], body: image)
        }
        let one = BodyImageLoader(transport: slow, cache: cache, limit: 1)
        let first = Task { await one.load(url("first.png")) }
        try await waitUntil { slow.inFlight == 1 }
        let waiting = Task { await one.load(url("waiting.png")) }
        try await Task.sleep(for: .milliseconds(100))
        waiting.cancel()
        #expect(await waiting.value == .cancelled)
        hold.fire()
        #expect(await first.value != .failed)
        #expect(slow.received.map(\.lastPathComponent) == ["first.png"])
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

    @Test("RD12: a loader that does not store fetches and answers, and leaves the cache directory untouched")
    func nonStoringLoaderWritesNothing() async throws {
        let (root, cache) = try makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = Images.answering(Images.png(width: 600, height: 400))
        let loader = BodyImageLoader(transport: transport, cache: cache, stores: false)
        let data = try #require(await loader.image(for: url("reader.png")))
        #expect(try Images.decode(data).type == UTType.jpeg.identifier)
        #expect(!FileManager.default.fileExists(atPath: cache.directory.path), "the cache directory was created")
        // Asked again: fetched again, still nothing written.
        #expect(await loader.image(for: url("reader.png")) == data)
        #expect(transport.received.count == 2)
        #expect(!FileManager.default.fileExists(atPath: cache.directory.path))

        // What the cache already holds is answered from it, and nothing is
        // added beside it.
        let stored = try #require(await BodyImageLoader(transport: transport, cache: cache).image(for: url("kept.png")))
        #expect(files(of: cache).count == 1)
        #expect(await loader.image(for: url("kept.png")) == stored)
        #expect(transport.received.count == 3, "the stored image was answered without a request")
        _ = await loader.image(for: url("other.png"))
        #expect(files(of: cache).count == 1)
    }

    private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
