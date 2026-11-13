import CoreGraphics
import Foundation
import ImageIO
@testable import NewsPawKit
import Testing
import UniformTypeIdentifiers

/// RD09 criterion 12, the loader: a fake transport and images made here.
@Suite("Thumbnail loader")
struct ThumbnailLoaderTests {
    /// A PNG of `width` × `height`: transparent, with an opaque red square in
    /// the middle when `transparent`, else filled with grey.
    static func png(width: Int, height: Int, transparent: Bool = false, gray: Bool = false) -> Data {
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)!
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        if transparent {
            context.clear(bounds)
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(bounds.insetBy(dx: CGFloat(width) / 4, dy: CGFloat(height) / 4))
        } else {
            context.setFillColor(gray ? CGColor(gray: 0.5, alpha: 1) : CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
            context.fill(bounds)
        }
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// A transport that answers every address with `body`.
    static func answering(_ body: Data, status: Int = 200) -> CountingTransport {
        CountingTransport { url in
            TransportResponse(finalURL: url, status: status, headers: ["Content-Type": "image/png"], body: body)
        }
    }

    struct Decoded {
        var type: String
        var width: Int
        var height: Int
        var image: CGImage
    }

    static func decode(_ data: Data) throws -> Decoded {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return Decoded(type: CGImageSourceGetType(source).map { $0 as String } ?? "", width: image.width, height: image.height, image: image)
    }

    /// The RGB value of one pixel of `image`, drawn into an RGBA bitmap.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> [Int] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let offset = (y * image.width + x) * 4
        return [Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2])]
    }

    private func makeCache() throws -> (URL, ImageCache) {
        let root = try makeTemporaryDirectory()
        return (root, ImageCache(directory: root.appending(path: "cache")))
    }

    @Test("a valid image is reduced to at most 288 pixels, stored as JPEG under the thumbnail key, and the next request is answered from the cache")
    func validImage() async throws {
        let (root, cache) = try makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = Self.answering(Self.png(width: 1_000, height: 500))
        let loader = ThumbnailLoader(transport: transport, cache: cache)
        let address = "https://images.example.invalid/wide.png"

        let data = try #require(await loader.thumbnail(for: address))
        let decoded = try Self.decode(data)
        #expect(decoded.type == UTType.jpeg.identifier)
        #expect(decoded.width == 288)
        #expect(decoded.height == 144)
        #expect(await cache.data(for: "thumbnail:" + address) == data)
        #expect(await cache.data(for: address) == nil, "not under the plain address")
        #expect(ThumbnailLoader.cacheKey(for: address) == "thumbnail:" + address)

        #expect(await loader.thumbnail(for: address) == data)
        #expect(transport.received.count == 1, "the second request was answered from the cache")
        // A new loader on the same cache, as after a relaunch.
        let again = ThumbnailLoader(transport: transport, cache: cache)
        #expect(await again.thumbnail(for: address) == data)
        #expect(transport.received.count == 1)

        // An image smaller than the bound keeps its size.
        let small = ThumbnailLoader(transport: Self.answering(Self.png(width: 120, height: 90)), cache: cache)
        let reduced = try Self.decode(try #require(await small.thumbnail(for: "https://images.example.invalid/small.png")))
        #expect(reduced.width == 120 && reduced.height == 90)
    }

    @Test("a transparent image comes out on white")
    func transparentOnWhite() async throws {
        let (root, cache) = try makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = ThumbnailLoader(transport: Self.answering(Self.png(width: 400, height: 400, transparent: true)), cache: cache)
        let decoded = try Self.decode(try #require(await loader.thumbnail(for: "https://images.example.invalid/clear.png")))
        #expect(decoded.width == 288 && decoded.height == 288)
        let corner = Self.pixel(decoded.image, x: 3, y: 3)
        #expect(corner.allSatisfy { $0 >= 245 }, "corner \(corner)")
        let middle = Self.pixel(decoded.image, x: 144, y: 144)
        #expect(middle[0] >= 200 && middle[1] <= 60 && middle[2] <= 60, "middle \(middle)")
    }

    @Test("something that is not an image, a failed answer and a failed fetch yield nothing, cache nothing, and are not asked again")
    func failuresYieldNothing() async throws {
        let (root, cache) = try makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = Self.answering(Data("<html>not an image</html>".utf8))
        let notFound = Self.answering(Self.png(width: 50, height: 50), status: 404)
        let unreachable = CountingTransport { _ in throw TransportFailure.unreachable }
        for (name, transport) in [("text", text), ("404", notFound), ("unreachable", unreachable)] {
            let loader = ThumbnailLoader(transport: transport, cache: cache)
            let address = "https://images.example.invalid/\(name)"
            #expect(await loader.thumbnail(for: address) == nil, "\(name)")
            #expect(await loader.thumbnail(for: address) == nil, "\(name) again")
            #expect(transport.received.count == 1, "\(name): a failed address is not asked again")
        }
        #expect(await cache.size() == 0)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: cache.directory.path)) ?? []
        #expect(files.isEmpty)
        // An address the transport may not request is never sent.
        let refused = Self.answering(Self.png(width: 50, height: 50))
        let loader = ThumbnailLoader(transport: refused, cache: cache)
        #expect(await loader.thumbnail(for: "file:///etc/hosts") == nil)
        #expect(await loader.thumbnail(for: "https://user:secret@images.example.invalid/a.png") == nil)
        #expect(refused.received.isEmpty)
    }

    @Test("requests that waited for a slot behind a failing request for the same address do not ask for it again")
    func waitersDoNotRepeatAFailedAddress() async throws {
        let (root, cache) = try makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let go = Signal()
        let transport = CountingTransport { _ in
            await go.wait()
            throw TransportFailure.unreachable
        }
        let loader = ThumbnailLoader(transport: transport, cache: cache, limit: 1)
        let address = "https://images.example.invalid/shared.png"
        let tasks = (0..<12).map { _ in Task { await loader.thumbnail(for: address) } }
        try await waitUntil { transport.inFlight == 1 }
        // Let every other request reach the queue.
        try await Task.sleep(for: .milliseconds(200))
        go.fire()
        for task in tasks {
            #expect(await task.value == nil)
        }
        #expect(transport.received.count == 1)
    }

    @Test("an image declaring more than 40 million pixels is refused and cached as nothing; one just under is reduced")
    func declaredPixelBound() async throws {
        let (root, cache) = try makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        // 7,000 × 6,000 = 42 million; 6,000 × 6,000 = 36 million.
        let over = Self.png(width: 7_000, height: 6_000, gray: true)
        let under = Self.png(width: 6_000, height: 6_000, gray: true)
        #expect(ThumbnailLoader.reduced(over) == nil)
        let loader = ThumbnailLoader(transport: Self.answering(over), cache: cache)
        #expect(await loader.thumbnail(for: "https://images.example.invalid/over.png") == nil)
        #expect(await cache.size() == 0)
        let reduced = try Self.decode(try #require(ThumbnailLoader.reduced(under)))
        #expect(reduced.width == 288 && reduced.height == 288)
    }

    @Test("never more than 4 requests in flight, also after many waiting requests were cancelled; no slot is lost")
    func atMostFourInFlight() async throws {
        let (root, cache) = try makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = Self.png(width: 40, height: 40)
        let go = Signal()
        let transport = CountingTransport { url in
            await go.wait()
            return TransportResponse(finalURL: url, status: 200, headers: [:], body: image)
        }
        let loader = ThumbnailLoader(transport: transport, cache: cache)
        let addresses = (0..<40).map { "https://images.example.invalid/\($0).png" }
        var tasks: [String: Task<Data?, Never>] = [:]
        for address in addresses {
            tasks[address] = Task { await loader.thumbnail(for: address) }
        }
        try await waitUntil { transport.inFlight == 4 }
        // Let every other request reach the queue.
        try await Task.sleep(for: .milliseconds(200))
        let requested = Set(transport.received.map(\.absoluteString))
        #expect(requested.count == 4)
        let waiting = addresses.filter { !requested.contains($0) }
        let cancelled = Array(waiting.prefix(30))
        for address in cancelled {
            tasks[address]?.cancel()
        }
        go.fire()
        var results: [String: Data?] = [:]
        for (address, task) in tasks {
            results[address] = await task.value
        }
        #expect(transport.mostInFlight == 4)
        #expect(cancelled.allSatisfy { results[$0] == .some(nil) }, "a cancelled request yields nothing")
        let completed = addresses.filter { !cancelled.contains($0) }
        #expect(completed.count == 10)
        #expect(completed.allSatisfy { results[$0] != .some(nil) })
        #expect(Set(transport.received.map(\.absoluteString)) == Set(completed), "a cancelled waiter made no request")
        for address in cancelled {
            #expect(await cache.data(for: ThumbnailLoader.cacheKey(for: address)) == nil)
        }

        // Afterwards the four slots are all there: eight more complete, at
        // most four at once.
        let more = (40..<48).map { "https://images.example.invalid/\($0).png" }
        let all = await withTaskGroup(of: Data?.self) { group in
            for address in more {
                group.addTask { await loader.thumbnail(for: address) }
            }
            return await group.reduce(into: [Data?]()) { $0.append($1) }
        }
        #expect(all.allSatisfy { $0 != nil })
        #expect(transport.mostInFlight == 4)
    }

    @Test("a request cancelled while its fetch is in flight stores nothing and is not taken as a failure")
    func cancelledStoresNothing() async throws {
        let (root, cache) = try makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = Self.png(width: 400, height: 300)
        let go = Signal()
        let transport = CountingTransport { url in
            await go.wait()
            return TransportResponse(finalURL: url, status: 200, headers: [:], body: image)
        }
        let loader = ThumbnailLoader(transport: transport, cache: cache)
        let address = "https://images.example.invalid/cancelled.png"
        let task = Task { await loader.thumbnail(for: address) }
        try await waitUntil { transport.inFlight == 1 }
        task.cancel()
        go.fire()
        #expect(await task.value == nil)
        #expect(await cache.data(for: ThumbnailLoader.cacheKey(for: address)) == nil)
        #expect(await cache.size() == 0)
        // Asked again, it is fetched and stored.
        #expect(await loader.thumbnail(for: address) != nil)
        #expect(transport.received.count == 2)
        #expect(await cache.data(for: ThumbnailLoader.cacheKey(for: address)) != nil)
    }

    private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
