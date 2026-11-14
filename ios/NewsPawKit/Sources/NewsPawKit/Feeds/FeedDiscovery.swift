import Foundation

/// A feed a page declares.
public struct DeclaredFeed: Sendable, Hashable {
    /// The feed's address in normal form.
    public let address: String
    /// The `title` attribute of its `<link>`, as text.
    public let title: String?
}

/// What feed discovery read from a document that is not a feed.
public struct DiscoveredPage: Sendable, Hashable {
    /// Whether the document is HTML; only HTML is scanned.
    public let isHTML: Bool
    /// The text of the page's first `<title>`.
    public let title: String?
    /// The declared feeds, in document order, at most
    /// `FeedDiscovery.maximumFeeds`.
    public let feeds: [DeclaredFeed]
    /// How many distinct feeds the page declares, before the cap.
    public let declaredCount: Int
}

/// Finds the feeds an HTML page declares (spec N03, N12; RD05 decisions 4
/// and 5). It has no network and no store: bytes in, the page's title and
/// its declared feeds out. It never throws: a page that cannot be read has
/// no feeds and no title.
///
/// Only the first `examinedBytes` are read, decoded lossily, in one linear
/// scan that never backs up and builds no tree: the document is never handed
/// to an HTML parser, whose tree builder takes time growing with the square
/// of the input on crafted markup. The scan (`TagScanner`) tokenises every
/// tag, aware of quoted attribute values, and discovery keeps `<link>`,
/// `<base>`, `<title>` and `<meta>`:
/// - A tag ends at the first `>` outside a quoted attribute value; a tag
///   with no end within `maximumTagLength` bytes is skipped, and the scan
///   goes on after those bytes.
/// - A tag name ends at white space, `/` or `>` and is compared ignoring
///   case.
/// - Comments, and the contents of `script`, `style`, `textarea` and
///   `title`, are passed over as text.
/// - Raw `href`s are collected during the scan and resolved after it, by
///   hand, against the first `<base>` with a usable `href`, wherever it
///   stands, else the final address.
/// Accepted approximations: a `<!…>` that is not a comment ends at the first
/// `>`; `<!-->` is a complete comment; the contents of `textarea` are text.
enum FeedDiscovery {
    /// The part of a document examined: 1 MB.
    static let examinedBytes = 1_048_576
    /// The part examined for a `<meta>` charset.
    static let charsetBytes = 1_024
    /// The longest tag read, in bytes of the decoded text.
    static let maximumTagLength = 8_192
    /// The most declared feeds kept.
    static let maximumFeeds = 5
    /// The longest title read before its references are decoded, in
    /// characters.
    static let maximumTitleLength = 1_000

    /// The media types of a feed declaration. `application/json` is not one:
    /// on most sites it is the WordPress API link.
    static let feedTypes: Set<String> = [
        "application/rss+xml", "application/atom+xml", "application/rdf+xml", "application/feed+json",
    ]

    /// Reads `document`, fetched from the normal form `requested`.
    static func read(_ document: NonFeedDocument, requested: String) -> DiscoveredPage {
        read(body: document.body, mediaType: document.mediaType, charset: document.charset,
             requested: requested, finalURL: document.finalURL)
    }

    static func read(body: Data, mediaType: String?, charset: String?, requested: String, finalURL: URL) -> DiscoveredPage {
        let examined = [UInt8](body.prefix(examinedBytes))
        guard isHTML(examined, mediaType: mediaType) else {
            return DiscoveredPage(isHTML: false, title: nil, feeds: [], declaredCount: 0)
        }
        let label = charset ?? Self.scan(Array(examined.prefix(charsetBytes))).charset
        let text = decode(examined, label: label)
        let scan = Self.scan(Array(text.utf8))

        let title = scan.title.flatMap { raw -> String? in
            let reduced = HTMLText.collapseWhitespace(decodeReferences(String(raw.prefix(maximumTitleLength))))
            return reduced.isEmpty ? nil : reduced
        }

        let finalForm = SourceAddress.normalForm(of: finalURL.absoluteString)
        guard let fallbackBase = finalForm ?? SourceAddress.normalForm(of: requested) else {
            return DiscoveredPage(isHTML: true, title: title, feeds: [], declaredCount: 0)
        }
        let base = scan.baseHrefs.lazy.compactMap { href in usableAddress(href, base: fallbackBase) }.first ?? fallbackBase

        var seen: Set<String> = [requested]
        if let finalForm {
            seen.insert(finalForm)
        }
        var feeds: [DeclaredFeed] = []
        for link in scan.links where isFeedDeclaration(link) {
            guard let href = link["href"], let address = usableAddress(href, base: base),
                  seen.insert(address).inserted
            else { continue }
            let declaredTitle = link["title"].map { HTMLText.collapseWhitespace(decodeReferences($0)) }
            feeds.append(DeclaredFeed(address: address, title: declaredTitle?.isEmpty == false ? declaredTitle : nil))
        }
        return DiscoveredPage(
            isHTML: true, title: title, feeds: Array(feeds.prefix(maximumFeeds)), declaredCount: feeds.count
        )
    }

    // MARK: - Recognising HTML

    /// HTML by its media type, or by `<html` or `<!doctype html` in any
    /// letter case within the first 1,024 bytes.
    static func isHTML(_ bytes: [UInt8], mediaType: String?) -> Bool {
        if let mediaType, mediaType == "text/html" || mediaType == "application/xhtml+xml" {
            return true
        }
        let head = bytes.prefix(charsetBytes).map(lowercased)
        return contains(head, Array("<html".utf8)) || contains(head, Array("<!doctype html".utf8))
    }

    private static func contains(_ bytes: [UInt8], _ needle: [UInt8]) -> Bool {
        guard bytes.count >= needle.count else { return false }
        for start in 0...(bytes.count - needle.count) where bytes[start..<(start + needle.count)].elementsEqual(needle) {
            return true
        }
        return false
    }

    // MARK: - Decoding

    /// The text of `bytes` in the encoding `label` names, else UTF-8. Lossy:
    /// a bad byte or a character cut at the 1 MB edge never loses the rest.
    static func decode(_ bytes: [UInt8], label: String?) -> String {
        let utf8 = String(decoding: bytes, as: UTF8.self)
        guard let label = label?.trimmingCharacters(in: .whitespaces), !label.isEmpty else { return utf8 }
        let encoding = CFStringConvertIANACharSetNameToEncoding(label as CFString)
        guard encoding != kCFStringEncodingInvalidId, encoding != CFStringBuiltInEncodings.UTF8.rawValue else {
            return utf8
        }
        let suggested = CFStringConvertEncodingToNSStringEncoding(encoding)
        var converted: NSString?
        var lossy: ObjCBool = false
        let found = NSString.stringEncoding(
            for: Data(bytes),
            encodingOptions: [
                .suggestedEncodingsKey: [suggested],
                .useOnlySuggestedEncodingsKey: true,
                .allowLossyKey: true,
            ],
            convertedString: &converted,
            usedLossyConversion: &lossy
        )
        guard found != 0, let converted else { return utf8 }
        return converted as String
    }

    /// `text` with its character references decoded and nothing else
    /// changed.
    static func decodeReferences(_ text: String) -> String {
        // `strip` decodes references and removes markup; with every `<`
        // written as a reference there is no markup left to remove.
        HTMLText.strip(Array(text.replacingOccurrences(of: "<", with: "&lt;").utf8))
    }

    // MARK: - Declarations

    /// `rel` includes `alternate` and not `stylesheet`; `type`, parameters
    /// dropped and case ignored, is a feed's.
    static func isFeedDeclaration(_ link: [String: String]) -> Bool {
        let rel = Set((link["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
        guard rel.contains("alternate"), !rel.contains("stylesheet") else { return false }
        let type = (link["type"] ?? "").split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        return feedTypes.contains(type)
    }

    /// `href`, its references decoded and white space trimmed, resolved
    /// against `base` (a normal form), when the result is an http or https
    /// address the normal form accepts.
    static func usableAddress(_ href: String, base: String) -> String? {
        let reference = decodeReferences(href).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty, let resolved = resolve(reference, against: base),
              case .success(let address) = SourceAddress.parse(resolved, addingScheme: false)
        else { return nil }
        return address.normalForm
    }

    // MARK: - Resolution (RFC 3986, section 5.2, written out)

    /// `reference` resolved against `base`, a normal form
    /// (`scheme://authority/path?query`).
    static func resolve(_ reference: String, against base: String) -> String? {
        if hasScheme(reference) {
            return reference
        }
        guard let schemeEnd = base.range(of: "://") else { return nil }
        let scheme = base[..<schemeEnd.lowerBound]
        let afterScheme = base[schemeEnd.upperBound...]
        let authorityEnd = afterScheme.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? afterScheme.endIndex
        let authority = afterScheme[..<authorityEnd]
        let rest = afterScheme[authorityEnd...]
        let pathEnd = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? rest.endIndex
        let basePath = rest[..<pathEnd].isEmpty ? "/" : String(rest[..<pathEnd])
        let afterPath = rest[pathEnd...]
        let baseQuery = afterPath.hasPrefix("?") ? String(afterPath.prefix(while: { $0 != "#" })) : ""
        let origin = "\(scheme)://\(authority)"

        if reference.hasPrefix("//") {
            return "\(scheme):\(reference)"
        }
        if reference.hasPrefix("?") {
            return origin + basePath + reference
        }
        if reference.hasPrefix("#") {
            return origin + basePath + baseQuery + reference
        }
        let suffixStart = reference.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? reference.endIndex
        let referencePath = reference[..<suffixStart]
        let suffix = reference[suffixStart...]
        let merged: String
        if referencePath.hasPrefix("/") {
            merged = String(referencePath)
        } else {
            let directory = basePath[...(basePath.lastIndex(of: "/") ?? basePath.startIndex)]
            merged = String(directory) + referencePath
        }
        return origin + removeDotSegments(merged) + suffix
    }

    /// Whether `text` begins with a scheme: a letter, then letters, digits,
    /// `+`, `-` or `.`, then `:`.
    static func hasScheme(_ text: String) -> Bool {
        var first = true
        for scalar in text.unicodeScalars {
            if first {
                guard scalar.isASCII, scalar.properties.isAlphabetic else { return false }
                first = false
            } else if scalar == ":" {
                return true
            } else if !(scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar)
                || scalar == "+" || scalar == "-" || scalar == ".")) {
                return false
            }
        }
        return false
    }

    /// RFC 3986's removal of `.` and `..` segments from an absolute path.
    static func removeDotSegments(_ path: String) -> String {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        var output: [Substring] = []
        for (index, segment) in segments.enumerated() {
            let isLast = index == segments.count - 1
            if segment == "." || segment == ".." {
                if segment == "..", output.count > 1 {
                    output.removeLast()
                }
                if isLast {
                    output.append("")
                }
                continue
            }
            output.append(segment)
        }
        let joined = output.joined(separator: "/")
        return joined.hasPrefix("/") ? joined : "/" + joined
    }

    // MARK: - Bytes

    static func lowercased(_ byte: UInt8) -> UInt8 {
        TagScanner.lowercased(byte)
    }
}

// MARK: - The scan

extension FeedDiscovery {
    /// What one scan of a document found.
    struct ScanResult {
        /// The attributes of every `<link>`, names lower case, the first of
        /// a repeated name kept.
        var links: [[String: String]] = []
        /// The raw `href` of every `<base>` that has one, in document order.
        var baseHrefs: [String] = []
        /// The raw text of the first `<title>`.
        var title: String?
        /// The first charset a `<meta>` declares.
        var charset: String?
    }

    private static let scanOptions = TagScanner.Options(
        maximumTagLength: maximumTagLength,
        rawTextElements: ["script", "style", "textarea", "title"],
        tagsWithAttributes: ["link", "base", "meta"],
        attributes: nil
    )

    /// One pass of the tag scanner over the bytes of a decoded document (or
    /// of the raw first bytes, for the `<meta>` charset): its `<link>`s, its
    /// `<base>`s, its first `<title>` and its first declared charset. The
    /// contents of `script`, `style`, `textarea` and `title` are passed over
    /// as text.
    static func scan(_ bytes: [UInt8]) -> ScanResult {
        var result = ScanResult()
        TagScanner.scan(bytes, options: scanOptions) { token in
            switch token.kind {
            case .startTag:
                switch token.name {
                case "link":
                    result.links.append(token.attributes)
                case "base":
                    if let href = token.attributes["href"] {
                        result.baseHrefs.append(href)
                    }
                case "meta":
                    if result.charset == nil {
                        result.charset = charset(in: token.attributes)
                    }
                default:
                    break
                }
            case .rawText:
                if token.name == "title", result.title == nil {
                    result.title = String(decoding: bytes[token.range], as: UTF8.self)
                }
            case .text, .endTag:
                break
            }
            return true
        }
        return result
    }

    /// The charset of `<meta charset>` or of `<meta http-equiv=
    /// "Content-Type" content="…; charset=…">`.
    private static func charset(in attributes: [String: String]) -> String? {
        if let charset = attributes["charset"]?.trimmingCharacters(in: .whitespacesAndNewlines), !charset.isEmpty {
            return charset
        }
        guard attributes["http-equiv"]?.trimmingCharacters(in: .whitespaces).lowercased() == "content-type",
              let content = attributes["content"],
              let range = content.range(of: "charset=", options: .caseInsensitive)
        else { return nil }
        let value = content[range.upperBound...]
            .prefix(while: { $0 != ";" && !$0.isWhitespace })
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return value.isEmpty ? nil : value
    }
}
