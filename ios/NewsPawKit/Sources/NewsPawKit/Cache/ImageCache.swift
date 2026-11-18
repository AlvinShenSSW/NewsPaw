import CryptoKit
import Foundation

/// One library's image cache (spec N04; RD06 decision 10): files in one
/// directory, named by the SHA-256 of their address, kept under a size limit
/// with the least recently used removed first. A file's modification date is
/// its last use. Reached only through its library (`Library.imageCache`).
///
/// It stores bytes and nothing else: what is fetched, and what counts as an
/// image, is the caller's (RD09). I/O failures are not thrown: a read then
/// returns nothing, a store returns false, and the size counts what can be
/// listed.
///
/// The total size is kept as a running figure (RD09 criterion 13): listing
/// the directory on every store cost about 100 ms at 20,000 files. It is
/// taken from a listing at first use and again whenever an eviction is
/// needed, so files removed behind the cache's back are noticed then.
///
/// A cache whose library was closed stores nothing (RD18): the adult
/// library is closed at every lock and before its data is deleted, and a
/// thumbnail that was ending must not write its bytes, or create the
/// directory again, after that.
///
/// No store lands after a clear (RD19 decision 7): `clear()` raises the
/// cache's generation, and a store made with the generation its caller read
/// before fetching writes nothing once a clear has come in between. A
/// category's move clears the old partition's cache, and an image whose
/// fetch began before that must not put a moved article's picture back.
public actor ImageCache {
    /// 500 MB.
    public static let standardLimit = 500 * 1024 * 1024

    /// The cache's own directory; created by the first store.
    public nonisolated let directory: URL
    /// The largest total size kept, in bytes.
    public nonisolated let limit: Int
    /// The running total in bytes; `nil` until first use.
    private var total: Int?
    /// Whether the cache's library was closed: a store then writes nothing.
    private var isClosed = false
    /// Raised by every `clear()`.
    public private(set) var generation = 0

    #if DEBUG
    /// Package tests only: runs inside a store that is about to write, so
    /// that a test can hold a store in flight.
    private var storeWillWrite: (@Sendable () -> Void)?

    func setStoreWillWrite(_ hook: (@Sendable () -> Void)?) {
        storeWillWrite = hook
    }
    #endif

    init(directory: URL, limit: Int = standardLimit) {
        self.directory = directory
        self.limit = limit
    }

    /// The bytes stored for `address`, or `nil`. A read makes the item the
    /// most recently used.
    public func data(for address: String) -> Data? {
        let url = fileURL(for: address)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    /// Stores `data` for `address`, then removes the least recently used
    /// items until the total is within the limit. An item larger than the
    /// limit is not stored and removes nothing; a closed cache stores
    /// nothing and creates no directory.
    ///
    /// - Returns: whether the item was stored.
    @discardableResult
    public func store(_ data: Data, for address: String) -> Bool {
        store(data, for: address, generation: generation)
    }

    /// Stores `data` for `address` as `store(_:for:)` does, unless the
    /// cache was cleared since its caller read `generation` (before it
    /// began to fetch): then nothing is written.
    ///
    /// - Returns: whether the item was stored.
    @discardableResult
    public func store(_ data: Data, for address: String, generation: Int) -> Bool {
        guard !isClosed, generation == self.generation, data.count <= limit else { return false }
        #if DEBUG
        storeWillWrite?()
        #endif
        let url = fileURL(for: address)
        var total = currentTotal()
        let replaced = fileSize(at: url)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        } catch {
            // What is on disk is no longer known; the next use lists it.
            self.total = nil
            return false
        }
        total += data.count - replaced
        self.total = total
        if total > limit {
            evict(keeping: url)
        }
        return true
    }

    /// The sum of the stored files' sizes, in bytes: the running total,
    /// listed at first use and kept by stores, evictions and Clear; zero
    /// when the directory does not exist or cannot be listed.
    public func size() -> Int {
        currentTotal()
    }

    /// Removes every stored item it can; the total is then what is left.
    /// A store whose fetch began before this writes nothing.
    public func clear() {
        generation += 1
        var left = 0
        for item in entries() where (try? FileManager.default.removeItem(at: item.url)) == nil {
            left += item.size
        }
        total = left
    }

    /// The cache's library was closed (RD18: every lock of the adult
    /// partition, and before its data is deleted): from now on a store
    /// writes nothing. A store that is running ends first, because the
    /// actor runs one at a time; so once this returns, nothing of this
    /// cache writes any more and its directory can be removed. Reads and
    /// Clear are unchanged.
    func close() {
        isClosed = true
    }

    // MARK: - Total

    /// The running total, taken from a listing at first use.
    private func currentTotal() -> Int {
        if let total {
            return total
        }
        let listed = entries().reduce(0) { $0 + $1.size }
        total = listed
        return listed
    }

    /// Lists the directory, so that the total is exact again, then removes
    /// the least recently used items until it is within the limit. The item
    /// at `kept`, just stored, is never a candidate.
    private func evict(keeping kept: URL) {
        var items = entries()
        var total = items.reduce(0) { $0 + $1.size }
        // Oldest first.
        items.removeAll { $0.url.lastPathComponent == kept.lastPathComponent }
        items.sort { $0.used < $1.used }
        for item in items where total > limit {
            if (try? FileManager.default.removeItem(at: item.url)) != nil {
                total -= item.size
            }
        }
        self.total = total
    }

    /// The size of the file at `url`, or zero when there is none.
    private func fileSize(at url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    // MARK: - Files

    private struct Entry {
        var url: URL
        var size: Int
        var used: Date
    }

    private func entries() -> [Entry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else {
            return []
        }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return Entry(url: url, size: values.fileSize ?? 0, used: values.contentModificationDate ?? .distantPast)
        }
    }

    private func fileURL(for address: String) -> URL {
        directory.appending(path: sha256Hex(address), directoryHint: .notDirectory)
    }
}

/// The lowercase hexadecimal SHA-256 of `text`'s UTF-8 bytes: the cache's
/// file names and the identifiers kept in `seen`.
func sha256Hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}
