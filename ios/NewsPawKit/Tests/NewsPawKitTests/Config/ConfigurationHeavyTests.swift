import Foundation
@testable import NewsPawKit
import Testing

// Nested in the serialized group: see `TimedAndHeavySuites`.
extension TimedAndHeavySuites {
/// RD20 criterion 3 and assumption A1: the size limit before reading, the
/// decoder's depth limit, and bulk input, each refused or read within a
/// wide time bound.
@Suite("Configuration file size and depth", .serialized)
struct ConfigurationHeavyTests {
    typealias J = ConfigurationJSON

    /// The base file followed by white space up to `size` bytes.
    static func padded(to size: Int) -> Data {
        var data = J.data(J.base())
        data.append(Data(repeating: 0x20, count: size - data.count))
        return data
    }

    @Test("criterion 3: exactly 5 MB is accepted; one byte more is refused")
    func exactSize() throws {
        let limit = ConfigurationFile.maximumBytes
        #expect(limit == 5 * 1024 * 1024)
        #expect(try readDocument(Self.padded(to: limit)).normal.categories.count == 2)
        #expect(ConfigurationFileTests.refusal(Self.padded(to: limit + 1)) == .tooLarge)
    }

    @Test("criterion 3: a file larger than 5 MB is refused from its size, without being read")
    func sizeBeforeReading() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "large.newspaw")
        try Self.padded(to: ConfigurationFile.maximumBytes + 100_000).write(to: url)
        #expect(ConfigurationFile.read(contentsOf: url) == .failure(.tooLarge))
        // Unreadable: the size alone refuses it, so it is never opened.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        #expect(ConfigurationFile.read(contentsOf: url) == .failure(.tooLarge))
    }

    @Test("criterion 3: the bounded read stops at the limit plus one byte")
    func boundedRead() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "large.newspaw")
        try Data(repeating: 0x20, count: ConfigurationFile.maximumBytes + 100_000).write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let read = try BoundedFileRead.read(handle, maximumBytes: ConfigurationFile.maximumBytes)
        #expect(read.count == ConfigurationFile.maximumBytes + 1)
        #expect(try handle.offset() == UInt64(ConfigurationFile.maximumBytes + 1))
    }

    @Test("a chosen file within the limit is read; a missing one is unreadable")
    func fileRead() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "NewsPaw Configuration.newspaw")
        try J.data(J.base()).write(to: url)
        #expect(try ConfigurationFile.read(contentsOf: url).get().normal.categories.count == 2)
        #expect(ConfigurationFile.read(contentsOf: directory.appending(path: "missing.newspaw")) == .failure(.unreadable))
    }

    /// The base file with `depth` nested arrays in a member the reader does
    /// not read.
    static func nested(_ depth: Int) -> Data {
        var object = J.base()
        object["deep"] = 777_004
        let text = J.text(object).replacingOccurrences(
            of: "777004", with: String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        )
        return Data(text.utf8)
    }

    @Test("A1, criterion 3: 511 nested arrays inside the object are read; 512, and a million, are not a configuration file")
    func depth() throws {
        #expect(try readDocument(Self.nested(511)).normal.categories.count == 2)
        #expect(ConfigurationFileTests.refusal(Self.nested(512)) == .notAConfiguration)
        let start = ContinuousClock.now
        let refusal = ConfigurationFileTests.refusal(Self.nested(1_000_000))
        let elapsed = ContinuousClock.now - start
        print("RD20 A1 | a million nested arrays refused | \(elapsed)")
        #expect(refusal == .notAConfiguration)
        #expect(elapsed < .seconds(20))
    }

    @Test("A1: a million nested objects are not a configuration file")
    func nestedObjects() {
        var object = J.base()
        object["deep"] = 777_005
        let depth = 400_000
        let text = J.text(object).replacingOccurrences(
            of: "777005", with: String(repeating: #"{"a":"#, count: depth) + "1" + String(repeating: "}", count: depth)
        )
        #expect(ConfigurationFileTests.refusal(Data(text.utf8)) == .notAConfiguration)
    }

    @Test("1.2 million empty objects: in a member the reader reads, too many categories; in another, ignored — each within a bound")
    func bulk() throws {
        let objects = Array(repeating: "{}", count: 1_200_000).joined(separator: ",")
        var object = J.base()
        object["categories"] = 777_006
        let read = Data(J.text(object).replacingOccurrences(of: "777006", with: "[\(objects)]").utf8)
        #expect(read.count <= ConfigurationFile.maximumBytes)
        var start = ContinuousClock.now
        #expect(ConfigurationFileTests.refusal(read) == .tooManyCategories)
        let readElapsed = ContinuousClock.now - start
        object = J.base()
        object["unread"] = 777_006
        let ignored = Data(J.text(object).replacingOccurrences(of: "777006", with: "[\(objects)]").utf8)
        start = ContinuousClock.now
        #expect(try readDocument(ignored).normal.categories.count == 2)
        let ignoredElapsed = ContinuousClock.now - start
        print("RD20 criterion 3 | 1.2 million empty objects | read member \(readElapsed) | ignored member \(ignoredElapsed)")
        #expect(readElapsed < .seconds(30))
        #expect(ignoredElapsed < .seconds(30))
    }
}
}
