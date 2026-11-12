import Foundation

/// Why a typed address is refused before any request (spec N02, N03).
public enum SourceAddressProblem: Error, Sendable, Hashable {
    /// Nothing is left once surrounding white space is removed.
    case empty
    /// The scheme is not http or https.
    case unsupportedScheme
    /// The address carries a user name or a password.
    case hasCredentials
    /// The text is not an address with a host.
    case malformed
    /// Longer than `SourceAddress.maximumLength` characters.
    case tooLong
}

/// The normal form of a source's address: what `source.url` holds and what
/// "the same address" compares (RD05 decision 1).
///
/// Surrounding white space is removed; `https://` is put in front when the
/// text does not begin with a scheme followed by `://`; the scheme and the
/// host are lower case (an internationalised host in its ASCII form); a
/// default port is removed; an empty path is written `/`; the fragment is
/// removed. Nothing else changes: the path's case and trailing slash, the
/// query and its order, `www.`, percent-escapes and dot segments stay as
/// typed, and http and https are different addresses. Characters that
/// cannot stand in an address (a space, a non-ASCII letter in the path) are
/// percent-encoded, as the system's URL parser does.
public struct SourceAddress: Sendable, Hashable {
    /// The longest address accepted, in characters.
    public static let maximumLength = 2_048

    /// The normal form.
    public let normalForm: String
    /// Whether `https://` was put in front of what was typed.
    public let addedScheme: Bool

    /// The normal form of `text`, or why it is refused.
    public static func parse(_ text: String) -> Result<SourceAddress, SourceAddressProblem> {
        parse(text, addingScheme: true)
    }

    /// The normal form of `text`, or `nil` when it is refused.
    public static func normalForm(of text: String) -> String? {
        try? parse(text).get().normalForm
    }

    /// - Parameter addingScheme: whether `https://` may be put in front of a
    ///   text without a scheme. Discovery passes `false`: a resolved
    ///   address always has one.
    static func parse(_ text: String, addingScheme: Bool) -> Result<SourceAddress, SourceAddressProblem> {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        var added = false
        if !startsWithScheme(text) {
            guard addingScheme else { return .failure(.unsupportedScheme) }
            text = "https://" + text
            added = true
        }
        guard text.count <= maximumLength else { return .failure(.tooLong) }
        guard var components = URLComponents(string: text) else { return .failure(.malformed) }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .failure(.unsupportedScheme)
        }
        components.scheme = scheme
        if components.user != nil || components.password != nil {
            return .failure(.hasCredentials)
        }
        guard let host = components.host, !host.isEmpty else { return .failure(.malformed) }
        components.host = host.lowercased()
        if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        if components.percentEncodedPath.isEmpty {
            components.percentEncodedPath = "/"
        }
        components.fragment = nil
        guard let normal = components.string else { return .failure(.malformed) }
        guard normal.count <= maximumLength else { return .failure(.tooLong) }
        return .success(SourceAddress(normalForm: normal, addedScheme: added))
    }

    /// Whether `text` begins with a scheme and `://`: a letter, then
    /// letters, digits, `+`, `-` or `.`, then `://`. A `://` further in, as
    /// in a query, does not count.
    static func startsWithScheme(_ text: String) -> Bool {
        var sawLetter = false
        var index = text.unicodeScalars.startIndex
        let scalars = text.unicodeScalars
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if !sawLetter {
                guard scalar.isASCII, scalar.properties.isAlphabetic else { return false }
                sawLetter = true
            } else if scalar == ":" {
                return scalars[index...].starts(with: "://".unicodeScalars)
            } else if !(scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar)
                || scalar == "+" || scalar == "-" || scalar == ".")) {
                return false
            }
            index = scalars.index(after: index)
        }
        return false
    }

    /// The address to store after fetching `requested` (a normal form) and
    /// ending at `finalURL` (RD05 decision 3): the https twin when an http
    /// address ended at it — the final address's normal form equals the
    /// requested one with the scheme changed to `https` — else `nil`, and
    /// the requested address is stored.
    public static func upgrade(requested: String, finalURL: URL) -> String? {
        let prefix = "http://"
        guard requested.hasPrefix(prefix), let final = normalForm(of: finalURL.absoluteString) else { return nil }
        let twin = "https://" + requested.dropFirst(prefix.count)
        return final == twin ? twin : nil
    }
}
