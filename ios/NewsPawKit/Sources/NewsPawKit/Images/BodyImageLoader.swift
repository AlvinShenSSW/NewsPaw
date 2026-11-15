import CoreGraphics
import Foundation
import ImageIO

/// The images of an article's body (spec N05, N12; RD11 decision 9).
///
/// Fetched like thumbnails: made with the app's one transport and one
/// library's image cache, it never chooses between caches. For an image
/// address it answers from the cache, or fetches the address through the
/// transport under its rules, refuses an answer of more than
/// `maximumReceivedBytes` and an image that declares more than
/// `ThumbnailLoader.maximumDeclaredPixels` before decoding it, reduces it to
/// at most `maximumPixelCount` pixels in all and `maximumSide` on a side,
/// its shape kept (an image within both keeps its size), flattens it onto
/// white and re-encodes it as JPEG. Only that JPEG is stored, under the image's own address; no fetched
/// byte is written as received. An animated image is stored as its first
/// frame.
///
/// At most `limit` requests are in flight; a freed slot goes to the first
/// waiter, and a cancelled waiter leaves the queue (as in `ThumbnailLoader`,
/// whose queue this repeats). A cancelled request stores nothing. Unlike a
/// thumbnail, a failure is not remembered here: who shows the article
/// decides when to ask again, which is when the article is opened again.
/// So the answer says which it was: a request that was cancelled says
/// nothing about the image, one that failed does.
public actor BodyImageLoader {
    /// The most pixels a stored body image has in all: what a square of
    /// 2,048 on a side has. A bound on the pixels, not on the longer side,
    /// so that a long picture (a screenshot of 1,080 × 6,000) is stored
    /// wide enough to be read, at the same decoded size in memory.
    public static let maximumPixelCount = 2_048 * 2_048
    /// The longest side of a stored body image, in pixels.
    public static let maximumSide = 8_192
    /// The largest answer accepted, in bytes as received.
    public static let maximumReceivedBytes = 10 * 1024 * 1024
    /// At most this many requests are in flight.
    public static let standardLimit = 3
    /// An image under this many pixels on a side is not drawn: a tracking
    /// pixel that declared no size.
    public static let minimumDrawnSide = 8

    private let transport: any Transport
    private let cache: ImageCache
    private var freeSlots: Int
    /// Requests waiting for a slot, first come first served.
    private var waiters: [(id: Int, continuation: CheckedContinuation<Bool, Never>)] = []
    private var nextWaiter = 0

    public init(transport: any Transport, cache: ImageCache, limit: Int = standardLimit) {
        self.transport = transport
        self.cache = cache
        freeSlots = max(1, limit)
    }

    /// The cache key of the body image at `url`: the address itself. A
    /// thumbnail of the same address has its own key.
    public static func cacheKey(for url: URL) -> String {
        url.absoluteString
    }

    /// What a request for an image came to.
    public enum Outcome: Sendable, Equatable {
        /// The stored JPEG.
        case image(Data)
        /// There is no image to show: the address may not be requested,
        /// the fetch failed, the answer is too large or not an image the
        /// system decodes, or it declares too many pixels.
        case failed
        /// The calling task was cancelled before an answer was there:
        /// nothing is known about the image, and nothing was stored.
        case cancelled
    }

    /// The stored JPEG of the image at `url` when the cache holds it; no
    /// request is made.
    public func cachedImage(for url: URL) async -> Data? {
        await cache.data(for: Self.cacheKey(for: url))
    }

    /// The image at `url` as the stored JPEG, or `nil` when there is none
    /// or the calling task was cancelled.
    public func image(for url: URL) async -> Data? {
        if case .image(let data) = await load(url) {
            return data
        }
        return nil
    }

    /// Asks for the image at `url`: from the cache, else through the
    /// transport. A failure the transport reports is a failure even when
    /// the calling task was cancelled meanwhile (a cancelled exchange is the
    /// transport's `CancellationError`, not a failure): the image is then
    /// known to fail, and is not asked for again at once.
    public func load(_ url: URL) async -> Outcome {
        let key = Self.cacheKey(for: url)
        if let cached = await cache.data(for: key) {
            return .image(cached)
        }
        guard !Task.isCancelled else { return .cancelled }
        guard url.isCollectableAddress else { return .failed }
        guard await acquireSlot() else { return .cancelled }
        defer { releaseSlot() }
        guard !Task.isCancelled else { return .cancelled }
        // Another request for the same address may have stored it meanwhile.
        if let cached = await cache.data(for: key) {
            return .image(cached)
        }
        let response: TransportResponse
        do {
            response = try await transport.fetch(TransportRequest(url: url))
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed
        }
        guard (200..<300).contains(response.status), response.body.count <= Self.maximumReceivedBytes else { return .failed }
        // A cancelled request is not decoded, and stores nothing.
        guard !Task.isCancelled else { return .cancelled }
        guard let image = await Self.reduce(response.body) else { return .failed }
        guard !Task.isCancelled else { return .cancelled }
        await cache.store(image, for: key)
        return .image(image)
    }

    // MARK: - Reduction and decoding

    /// Off the actor: decoding and encoding take a moment.
    @concurrent
    private static func reduce(_ data: Data) async -> Data? {
        ThumbnailLoader.reduced(data, longerSide: storedLongerSide)
    }

    /// The longer side, in pixels, at which an image of `width` × `height`
    /// pixels is stored: its own when the image is within
    /// `maximumPixelCount` pixels and `maximumSide` on each side, else the
    /// longest at which it is, its shape kept. Never more than its own.
    public static func storedLongerSide(width: Int, height: Int) -> Int {
        let longer = max(width, height)
        let shorter = min(width, height)
        guard shorter > 0 else { return 0 }
        var side = min(longer, maximumSide)
        if Double(width) * Double(height) > Double(maximumPixelCount) {
            // side × (side × shorter / longer) is the count at most.
            side = min(side, Int((Double(maximumPixelCount) * Double(longer) / Double(shorter)).squareRoot().rounded(.down)))
        }
        // The shorter side comes out rounded: within the count whichever
        // way it is rounded.
        while side > 1, Double(side) * (Double(shorter) * Double(side) / Double(longer)).rounded(.up) > Double(maximumPixelCount) {
            side -= 1
        }
        return max(side, 1)
    }

    /// The width and height of the image in `data`, in pixels, read from its
    /// header.
    public static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0
        else { return nil }
        return (width, height)
    }

    /// The image in `data` decoded for drawing at no more than
    /// `maximumPixelSize` pixels on its longer side, and never larger than
    /// it is. Decoded now, not when first drawn, so that the caller chooses
    /// the thread.
    public static func decoded(_ data: Data, maximumPixelSize: Int) -> CGImage? {
        guard maximumPixelSize > 0,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - Slots

    /// Takes a slot, waiting for one when none is free. Returns false when
    /// the request was cancelled first; a cancelled waiter leaves the queue.
    private func acquireSlot() async -> Bool {
        if freeSlots > 0 {
            freeSlots -= 1
            return true
        }
        nextWaiter += 1
        let id = nextWaiter
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Hands the slot to the first waiter, or frees it.
    private func releaseSlot() {
        if waiters.isEmpty {
            freeSlots += 1
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    /// Takes a cancelled request out of the queue. A request already handed
    /// a slot is not in it: it sees its cancellation and frees the slot.
    private func cancelWaiter(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}
