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
public actor ImageCache {
    /// 500 MB.
    public static let standardLimit = 500 * 1024 * 1024

    /// The cache's own directory; created by the first store.
    public nonisolated let directory: URL
    /// The largest total size kept, in bytes.
    public nonisolated let limit: Int

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
    /// limit is not stored and removes nothing.
    ///
    /// - Returns: whether the item was stored.
    @discardableResult
    public func store(_ data: Data, for address: String) -> Bool {
        guard data.count <= limit else { return false }
        let url = fileURL(for: address)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        } catch {
            return false
        }
        var items = entries()
        var total = items.reduce(0) { $0 + $1.size }
        // Oldest first; the item just stored is never a candidate.
        items.removeAll { $0.url.lastPathComponent == url.lastPathComponent }
        items.sort { $0.used < $1.used }
        for item in items where total > limit {
            if (try? FileManager.default.removeItem(at: item.url)) != nil {
                total -= item.size
            }
        }
        return true
    }

    /// The sum of the stored files' sizes, in bytes; zero when the directory
    /// does not exist or cannot be listed.
    public func size() -> Int {
        entries().reduce(0) { $0 + $1.size }
    }

    /// Removes every stored item it can.
    public func clear() {
        for item in entries() {
            try? FileManager.default.removeItem(at: item.url)
        }
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
