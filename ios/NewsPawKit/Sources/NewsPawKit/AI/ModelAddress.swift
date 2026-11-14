import Foundation

/// Why a model service address is refused.
public enum ModelAddressProblem: Error, Sendable, Hashable {
    /// Nothing is left once surrounding white space is removed.
    case empty
    /// Longer than `ModelAddress.maximumLength`.
    case tooLong
    /// Not an address.
    case invalid
    /// Not https (and not the loopback http a debug build accepts).
    case notHTTPS
    /// No host.
    case noHost
    /// A user name or password in the address.
    case credentials
    /// A query or a fragment in the address.
    case queryOrFragment
}

/// The rule for model service addresses (spec N08, N12; RD13 decision 5),
/// applied when saving and again before every request.
public enum ModelAddress {
    /// Whether this build accepts `http` to the device's own loopback
    /// address. The only `true` is inside `#if DEBUG`: TestFlight and
    /// release builds refuse every http address.
    #if DEBUG
    public static let allowsLoopbackHTTPInThisBuild = true
    #else
    public static let allowsLoopbackHTTPInThisBuild = false
    #endif

    /// The longest address accepted, in characters.
    public static let maximumLength = 2_048

    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    /// The address in normal form, or why it is refused: `https`, a host, no
    /// user name or password, no query and no fragment, at most
    /// `maximumLength` characters; surrounding white space and trailing
    /// slashes are removed and the scheme is lowercased. With
    /// `allowsLoopbackHTTP`, `http` is also accepted when the host is
    /// `localhost`, `127.0.0.1` or `::1`.
    public static func normalise(_ text: String, allowsLoopbackHTTP: Bool) -> Result<String, ModelAddressProblem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .failure(.empty)
        }
        if trimmed.count > maximumLength {
            return .failure(.tooLong)
        }
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased() else {
            return .failure(.invalid)
        }
        guard let host = Self.host(of: components), !host.isEmpty else {
            return scheme == "https" || scheme == "http" ? .failure(.noHost) : .failure(.notHTTPS)
        }
        switch scheme {
        case "https":
            break
        case "http" where allowsLoopbackHTTP && loopbackHosts.contains(host.lowercased()):
            break
        default:
            return .failure(.notHTTPS)
        }
        if components.user != nil || components.password != nil {
            return .failure(.credentials)
        }
        if components.query != nil || components.fragment != nil || trimmed.contains("?") || trimmed.contains("#") {
            return .failure(.queryOrFragment)
        }
        var normal = scheme + trimmed.dropFirst(scheme.count)
        while normal.hasSuffix("/") {
            normal.removeLast()
        }
        // What is left must still be an address with the same host.
        guard let check = URLComponents(string: normal), Self.host(of: check)?.lowercased() == host.lowercased() else {
            return .failure(.invalid)
        }
        return .success(normal)
    }

    /// Whether two addresses have the same origin — scheme, host and port
    /// (decision 3). A stored key is usable only while the address keeps
    /// its origin. An address that cannot be read has no origin and matches
    /// nothing.
    public static func sameOrigin(_ first: String, _ second: String) -> Bool {
        guard let first = Origin(first), let second = Origin(second) else { return false }
        return first == second
    }

    /// The host of an address, without the brackets of an IPv6 literal.
    private static func host(of components: URLComponents) -> String? {
        guard var host = components.host else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        return host
    }

    private struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int

        init?(_ address: String) {
            guard let components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let scheme = components.scheme?.lowercased(),
                  let host = ModelAddress.host(of: components)?.lowercased(), !host.isEmpty
            else { return nil }
            self.scheme = scheme
            self.host = host
            if let port = components.port {
                self.port = port
            } else {
                switch scheme {
                case "https": port = 443
                case "http": port = 80
                default: return nil
                }
            }
        }
    }
}

/// Why a model name is refused.
public enum ModelNameProblem: Error, Sendable, Hashable {
    case empty
    case tooLong
    case controlCharacter
}

/// The rule for model names (RD13 decision 5).
public enum ModelName {
    /// The longest model name accepted, in characters.
    public static let maximumLength = 200

    /// The name trimmed of surrounding white space, or why it is refused:
    /// not empty, at most `maximumLength` characters, no control character.
    public static func validate(_ text: String) -> Result<String, ModelNameProblem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .failure(.empty)
        }
        if trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return .failure(.controlCharacter)
        }
        if trimmed.count > maximumLength {
            return .failure(.tooLong)
        }
        return .success(trimmed)
    }
}
