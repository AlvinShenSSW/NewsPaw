import Foundation

/// The bounded read of a file the owner chose (RD08 decision 2; RD20
/// decision 3), shared by the OPML reader and the configuration reader:
/// the size from the file's resource values, refused above the limit
/// without reading; then at most the limit plus one byte, refused when
/// that byte is there.
enum BoundedFileRead {
    enum Failure: Error, Sendable, Hashable {
        /// Larger than the limit.
        case tooLarge
        /// The file could not be opened or read.
        case unreadable
    }

    /// The bytes of the file at `url`, at most `maximumBytes` of them.
    static func read(contentsOf url: URL, maximumBytes: Int) -> Result<Data, Failure> {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maximumBytes {
            return .failure(.tooLarge)
        }
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try read(handle, maximumBytes: maximumBytes)
        } catch {
            return .failure(.unreadable)
        }
        guard data.count <= maximumBytes else { return .failure(.tooLarge) }
        return .success(data)
    }

    /// Reads from `handle` until its end or until one byte past the limit.
    static func read(_ handle: FileHandle, maximumBytes: Int) throws -> Data {
        let limit = maximumBytes + 1
        var data = Data()
        while data.count < limit {
            guard let chunk = try handle.read(upToCount: min(limit - data.count, 1 << 20)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return data
    }
}
