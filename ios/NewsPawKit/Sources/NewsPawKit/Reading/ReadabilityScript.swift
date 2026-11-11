import Foundation

/// Mozilla's Readability script, bundled with this package (see `Resources/README.md`).
public enum ReadabilityScript {
    public enum LoadError: Error {
        case missingResource
    }

    /// The script's source text, read from the package's resource bundle.
    public static func source() throws -> String {
        guard let url = Bundle.module.url(forResource: "Readability", withExtension: "js") else {
            throw LoadError.missingResource
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
