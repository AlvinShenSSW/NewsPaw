import Foundation

/// A Hugging Face account — a user or an organisation — recognised in a
/// typed address, or named by the Hub (RD26 decisions 1 and 2). Pure: it
/// makes no request.
public struct HuggingFaceAccount: Sendable, Hashable {
    /// The account's name: as typed, or in the Hub's spelling once an
    /// overview has given it.
    public let name: String

    private static let hosts: Set<String> = ["huggingface.co", "www.huggingface.co", "hf.co"]

    /// The account of `normalForm` (a `SourceAddress` normal form), or `nil`
    /// when it is not an account's own page: the scheme is http or https;
    /// the host is `huggingface.co`, `www.huggingface.co` or `hf.co`,
    /// without a port; the path is exactly one segment, with or without a
    /// trailing slash, that is a name (`isName`). The query is ignored.
    public init?(normalForm: String) {
        guard let components = URLComponents(string: normalForm),
              let scheme = components.scheme, scheme == "http" || scheme == "https",
              let host = components.host, Self.hosts.contains(host),
              components.port == nil
        else { return nil }
        var path = Substring(components.percentEncodedPath)
        guard path.hasPrefix("/") else { return nil }
        path = path.dropFirst()
        if path.hasSuffix("/") {
            path = path.dropLast()
        }
        let name = String(path)
        guard Self.isName(name) else { return nil }
        self.name = name
    }

    /// The account called `name`, or `nil` when it is not a name.
    init?(name: String) {
        guard Self.isName(name) else { return nil }
        self.name = name
    }

    /// `https://huggingface.co/<name>`: the account's page, which a source
    /// stores as its address and its site.
    public var pageAddress: String {
        "https://huggingface.co/\(name)"
    }

    /// The organisation overview: `https://huggingface.co/api/organizations/<name>/overview`.
    var organizationOverviewAddress: String {
        "https://huggingface.co/api/organizations/\(name)/overview"
    }

    /// The user overview: `https://huggingface.co/api/users/<name>/overview`.
    var userOverviewAddress: String {
        "https://huggingface.co/api/users/\(name)/overview"
    }

    /// The newest models, by creation time: the list a source collects.
    /// Thirty is three times a GitHub feed's ten.
    var modelsAddress: String {
        "https://huggingface.co/api/models?author=\(name)&sort=createdAt&direction=-1&limit=30&expand=createdAt"
    }

    /// Whether `text` is a name: 1–96 ASCII letters, digits, `-`, `_` or
    /// `.`, and not `.` or `..`. A percent-escape is not a name.
    static func isName(_ text: some StringProtocol) -> Bool {
        guard (1...96).contains(text.utf8.count), text != ".", text != ".." else { return false }
        return text.utf8.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ".")
        }
    }

    /// The account's name as an overview spells it: the string `member` of
    /// a JSON object (`name` for an organisation, `user` for a user) when it
    /// is a name equal to `self.name` ignoring ASCII case; else `nil`. The
    /// document is refused before parsing when it is past the JSON limits.
    /// Nothing else in it is read.
    func spelling(inOverview data: Data, member: String) -> String? {
        guard !JSONFeedReader.exceedsLimits(data),
              let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let spelled = object[member] as? String, Self.isName(spelled),
              spelled.lowercased() == name.lowercased()
        else { return nil }
        return spelled
    }
}

/// What detection found for an account address (RD26 decision 3).
public struct HuggingFaceDetection: Sendable, Hashable {
    /// The account, in the Hub's spelling.
    public let account: HuggingFaceAccount
    /// Its newest models, fetched and read: what Save stores, of kind
    /// `huggingface`, at the account's page.
    public let candidate: FeedCandidate
}
