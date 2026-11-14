/// A model service's key (spec N08; RD13 decision 4): a value that does not
/// print. Its description, debug description and mirror show a fixed
/// placeholder, and it is not `Codable`, so it cannot reach a log, an error,
/// a table or an exported file by being printed or encoded.
///
/// The string is read in two places only: the keychain store, which writes
/// and reads it, and the one line of `URLSessionModelHTTP` that writes the
/// `Authorization` header.
public struct SecretKey: Sendable, Equatable {
    /// The key's text. Package-internal and named so that every read of it
    /// can be found by searching for this name.
    let exposedValue: String

    /// The longest key accepted, in characters.
    public static let maximumLength = 4_096

    /// The rule a key must meet (decision 5): surrounding white space and
    /// line breaks are removed (pasted keys); what remains is 1 to
    /// `maximumLength` printable ASCII characters. A line break inside a key
    /// would write a second header, so anything else is refused.
    public static func validate(_ text: String) -> Result<SecretKey, KeyProblem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .failure(.empty)
        }
        guard trimmed.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) || $0 == " " }) else {
            return .failure(.invalidCharacter)
        }
        guard trimmed.unicodeScalars.count <= maximumLength else {
            return .failure(.tooLong)
        }
        return .success(SecretKey(exposedValue: trimmed))
    }

    private init(exposedValue: String) {
        self.exposedValue = exposedValue
    }

    /// The last four characters, for "•••• 1a2b" (ux S9), or `nil` when the
    /// key is shorter than 12 characters and only the dots are shown.
    public var lastFour: String? {
        exposedValue.count >= 12 ? String(exposedValue.suffix(4)) : nil
    }

    /// What every printing of a key shows.
    static let placeholder = "SecretKey(redacted)"
}

extension SecretKey: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { Self.placeholder }
    public var debugDescription: String { Self.placeholder }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// Why a typed key is refused.
public enum KeyProblem: Error, Sendable, Hashable {
    /// Nothing is left once surrounding white space is removed.
    case empty
    /// A character that is not printable ASCII: a line break inside the key,
    /// a control character or a non-ASCII character.
    case invalidCharacter
    /// Longer than `SecretKey.maximumLength`.
    case tooLong
}
