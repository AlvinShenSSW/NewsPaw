import Foundation
import Testing

/// Synthetic test material bundled with the test target under `Fixtures/`.
enum Fixture {
    static func url(_ name: String, _ fileExtension: String) throws -> URL {
        try #require(
            Bundle.module.url(forResource: name, withExtension: fileExtension, subdirectory: "Fixtures"),
            "Missing fixture \(name).\(fileExtension)"
        )
    }

    static func data(_ name: String, _ fileExtension: String) throws -> Data {
        try Data(contentsOf: url(name, fileExtension))
    }

    static func text(_ name: String, _ fileExtension: String) throws -> String {
        try String(contentsOf: url(name, fileExtension), encoding: .utf8)
    }
}

/// A directory under the system temporary directory that the caller removes when done.
func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "NewsPawKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
