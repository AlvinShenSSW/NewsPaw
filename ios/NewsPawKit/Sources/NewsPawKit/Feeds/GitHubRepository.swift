import Foundation

/// One of a repository's Atom feeds (spec N03), in the order the confirm
/// step lists them.
public enum GitHubFeed: String, Sendable, Hashable, CaseIterable {
    /// Every tag, with the release notes of a published release, else the
    /// tag's message. The default.
    case releases
    /// Every tag, without notes: Releases' identities and links.
    case tags
    /// The default branch's commits.
    case commits
}

/// A public GitHub repository recognised in a typed address (RD07 decisions
/// 1 and 2). Pure: it makes no request.
public struct GitHubRepository: Sendable, Hashable {
    /// The owner, as typed.
    public let owner: String
    /// The repository's name, as typed, without a trailing `.git`.
    public let name: String

    private static let hosts: Set<String> = ["github.com", "www.github.com"]

    /// The repository of `normalForm` (a `SourceAddress` normal form), or
    /// `nil` when it is not a repository address: the host is `github.com`
    /// or `www.github.com` without a port; the path has at least two
    /// segments, an owner (1–39 ASCII letters, digits or hyphens) and a name
    /// (after one trailing `.git` is removed, 1–100 ASCII letters, digits,
    /// `.`, `_` or `-`, not `.` or `..`); and its last segment does not end
    /// in `.atom`. The query is ignored.
    public init?(normalForm: String) {
        guard let components = URLComponents(string: normalForm),
              let scheme = components.scheme, scheme == "http" || scheme == "https",
              let host = components.host, Self.hosts.contains(host),
              components.port == nil
        else { return nil }
        let segments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
        guard segments.count >= 2, let last = segments.last, !last.hasSuffix(".atom") else { return nil }
        let owner = String(segments[0])
        var name = String(segments[1])
        if name.hasSuffix(".git") {
            name.removeLast(4)
        }
        guard Self.isOwner(owner), Self.isName(name) else { return nil }
        self.owner = owner
        self.name = name
    }

    /// `https://github.com/<owner>/<name>` in the typed case.
    public var pageAddress: String {
        "https://github.com/\(owner)/\(name)"
    }

    /// `<owner>/<name>` in the typed case: the source's suggested name.
    public var displayName: String {
        "\(owner)/\(name)"
    }

    /// The feed's address: https, on `github.com`, owner and name in lower
    /// case. GitHub answers every case alike, so one form is stored.
    public func feedAddress(_ feed: GitHubFeed) -> String {
        "https://github.com/\(owner.lowercased())/\(name.lowercased())/\(feed.rawValue).atom"
    }

    private static func isOwner(_ text: String) -> Bool {
        (1...39).contains(text.utf8.count) && text.utf8.allSatisfy { isLetterOrDigit($0) || $0 == UInt8(ascii: "-") }
    }

    private static func isName(_ text: String) -> Bool {
        guard (1...100).contains(text.utf8.count), text != ".", text != ".." else { return false }
        return text.utf8.allSatisfy { byte in
            isLetterOrDigit(byte) || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }
    }

    private static func isLetterOrDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }
}
