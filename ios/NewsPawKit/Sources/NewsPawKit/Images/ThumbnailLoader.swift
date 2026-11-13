import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The thumbnails of list rows (spec N05, N12; RD09 decision 13).
///
/// Made with the app's one transport and one library's image cache; it never
/// chooses between caches. For an image address it answers from the cache,
/// or fetches the address through the transport under its rules, refuses an
/// image that declares more than `maximumDeclaredPixels` before decoding it,
/// decodes it with the system's image decoder, reduces it to at most
/// `maximumPixelSize` pixels on its longer side, flattens it onto white and
/// re-encodes it as JPEG. Only that JPEG is stored, under a key of its own
/// (`cacheKey(for:)`); no fetched byte is written as received.
///
/// At most `limit` requests are in flight; a freed slot goes to the first
/// waiter, and a cancelled waiter leaves the queue. A cancelled request
/// stores nothing. An address that failed is not asked again for the life
/// of the loader.
public actor ThumbnailLoader {
    /// The longest side of a thumbnail, in pixels.
    public static let maximumPixelSize = 288
    /// The most pixels an image may declare.
    public static let maximumDeclaredPixels = 40_000_000
    /// At most this many requests are in flight.
    public static let standardLimit = 4

    private let transport: any Transport
    private let cache: ImageCache
    /// Addresses whose fetch, decoding or reduction failed.
    private var failed: Set<String> = []
    private var freeSlots: Int
    /// Requests waiting for a slot, first come first served.
    private var waiters: [(id: Int, continuation: CheckedContinuation<Bool, Never>)] = []
    private var nextWaiter = 0

    public init(transport: any Transport, cache: ImageCache, limit: Int = standardLimit) {
        self.transport = transport
        self.cache = cache
        freeSlots = max(1, limit)
    }

    /// The cache key of the thumbnail of the image at `address`: not the
    /// address itself, so that the full image cached at the same address
    /// (RD11) is never mistaken for it.
    public static func cacheKey(for address: String) -> String {
        "thumbnail:" + address
    }

    /// The thumbnail of the image at `address` as JPEG data, or `nil` when
    /// there is none: the fetch failed, the answer is not an image the
    /// system decodes, it declares too many pixels, or the calling task was
    /// cancelled.
    public func thumbnail(for address: String) async -> Data? {
        let key = Self.cacheKey(for: address)
        if let cached = await cache.data(for: key) {
            return cached
        }
        guard !failed.contains(address), !Task.isCancelled else { return nil }
        guard let url = URL(string: address), url.isCollectableAddress else {
            failed.insert(address)
            return nil
        }
        guard await acquireSlot() else { return nil }
        defer { releaseSlot() }
        guard !Task.isCancelled else { return nil }
        // Another request for the same address may have stored it meanwhile,
        // or failed: a failed address is not asked again by those that
        // waited for a slot behind it.
        if let cached = await cache.data(for: key) {
            return cached
        }
        guard !failed.contains(address) else { return nil }
        let response: TransportResponse
        do {
            response = try await transport.fetch(TransportRequest(url: url))
        } catch {
            if !Task.isCancelled, !(error is CancellationError) {
                failed.insert(address)
            }
            return nil
        }
        guard !Task.isCancelled else { return nil }
        guard (200..<300).contains(response.status), let thumbnail = await Self.reduce(response.body) else {
            failed.insert(address)
            return nil
        }
        guard !Task.isCancelled else { return nil }
        await cache.store(thumbnail, for: key)
        return thumbnail
    }

    // MARK: - Reduction

    /// Off the actor: decoding and encoding take a moment.
    @concurrent
    static func reduce(_ data: Data) async -> Data? {
        reduced(data)
    }

    /// `data` decoded by ImageIO, reduced to at most `maximumPixelSize`
    /// pixels on its longer side, drawn onto white and encoded as JPEG; `nil`
    /// when ImageIO does not take it as an image or it declares more than
    /// `maximumDeclaredPixels` pixels (read from its header, before any
    /// decoding).
    static func reduced(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0
        else { return nil }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= maximumDeclaredPixels else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        guard let flat = context.makeImage() else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, flat, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
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
