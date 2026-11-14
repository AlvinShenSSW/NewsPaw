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
/// at most `maximumPixelSize` pixels on its longer side (an image smaller
/// than that keeps its size), flattens it onto white and re-encodes it as
/// JPEG. Only that JPEG is stored, under the image's own address; no fetched
/// byte is written as received. An animated image is stored as its first
/// frame.
///
/// At most `limit` requests are in flight; a freed slot goes to the first
/// waiter, and a cancelled waiter leaves the queue (as in `ThumbnailLoader`,
/// whose queue this repeats). A cancelled request stores nothing. Unlike a
/// thumbnail, a failure is not remembered here: who shows the article
/// decides when to ask again, which is when the article is opened again.
public actor BodyImageLoader {
    /// The longest side of a stored body image, in pixels.
    public static let maximumPixelSize = 2_048
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

    /// The image at `url` as the stored JPEG, or `nil` when there is none:
    /// the fetch failed, the answer is too large or not an image the system
    /// decodes, it declares too many pixels, or the calling task was
    /// cancelled.
    public func image(for url: URL) async -> Data? {
        let key = Self.cacheKey(for: url)
        if let cached = await cache.data(for: key) {
            return cached
        }
        guard !Task.isCancelled, url.isCollectableAddress else { return nil }
        guard await acquireSlot() else { return nil }
        defer { releaseSlot() }
        guard !Task.isCancelled else { return nil }
        // Another request for the same address may have stored it meanwhile.
        if let cached = await cache.data(for: key) {
            return cached
        }
        guard let response = try? await transport.fetch(TransportRequest(url: url)), !Task.isCancelled,
              (200..<300).contains(response.status), response.body.count <= Self.maximumReceivedBytes,
              let image = await Self.reduce(response.body), !Task.isCancelled
        else { return nil }
        await cache.store(image, for: key)
        return image
    }

    // MARK: - Reduction and decoding

    /// Off the actor: decoding and encoding take a moment.
    @concurrent
    private static func reduce(_ data: Data) async -> Data? {
        ThumbnailLoader.reduced(data, maximumPixelSize: maximumPixelSize)
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
