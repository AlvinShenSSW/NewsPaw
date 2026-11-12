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
/// of the input on crafted markup. The scan tokenises every tag, aware of
/// quoted attribute values, and keeps `<link>`, `<base>`, `<title>` and
/// `<meta>`:
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
        let label = charset ?? TagScanner.scan(Array(examined.prefix(charsetBytes))).charset
        let text = decode(examined, label: label)
        let scan = TagScanner.scan(Array(text.utf8))

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

    static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D
    }

    static func lowercased(_ byte: UInt8) -> UInt8 {
        byte >= 65 && byte <= 90 ? byte + 32 : byte
    }

    static func isLetter(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
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

    /// One linear pass over the bytes of a decoded document (or of the raw
    /// first bytes, for the `<meta>` charset). Every byte is visited a
    /// bounded number of times: a tag, a comment or a raw-text element that
    /// does not end consumes what it looked at.
    enum TagScanner {
        private static let lessThan = UInt8(ascii: "<")
        private static let greaterThan = UInt8(ascii: ">")
        private static let slash = UInt8(ascii: "/")
        private static let equals = UInt8(ascii: "=")
        private static let bang = UInt8(ascii: "!")
        private static let question = UInt8(ascii: "?")
        private static let quote = UInt8(ascii: "\"")
        private static let apostrophe = UInt8(ascii: "'")

        private static let kept: Set<[UInt8]> = [Array("link".utf8), Array("base".utf8), Array("meta".utf8)]
        private static let rawText: Set<[UInt8]> = [
            Array("script".utf8), Array("style".utf8), Array("textarea".utf8), Array("title".utf8),
        ]

        static func scan(_ bytes: [UInt8]) -> ScanResult {
            var result = ScanResult()
            let count = bytes.count
            var index = 0
            while index < count {
                guard let open = bytes[index...].firstIndex(of: lessThan) else { break }
                let next = open + 1
                guard next < count else { break }
                switch bytes[next] {
                case bang:
                    if hasPrefix(bytes, at: next + 1, Array("--".utf8)) {
                        // `<!-->` is a complete comment, so the end is looked
                        // for from the first `-`.
                        guard let end = find(bytes, Array("-->".utf8), from: next + 1) else { return result }
                        index = end + 3
                    } else {
                        index = (bytes[next...].firstIndex(of: greaterThan) ?? count - 1) + 1
                    }
                    continue
                case question:
                    index = (bytes[next...].firstIndex(of: greaterThan) ?? count - 1) + 1
                    continue
                default:
                    break
                }
                let isEndTag = bytes[next] == slash
                let nameStart = isEndTag ? next + 1 : next
                guard nameStart < count, isLetter(bytes[nameStart]) else {
                    // A `<` that starts no tag is text.
                    index = next
                    continue
                }
                let limit = min(count, open + maximumTagLength)
                var nameEnd = nameStart
                while nameEnd < limit, !isSpace(bytes[nameEnd]), bytes[nameEnd] != slash, bytes[nameEnd] != greaterThan {
                    nameEnd += 1
                }
                let name = bytes[nameStart..<nameEnd].map(lowercased)
                let keep = !isEndTag && kept.contains(name)
                guard let (end, attributes) = readAttributes(bytes, from: nameEnd, limit: limit, keep: keep) else {
                    // No end within the limit: the tag is skipped with what
                    // was looked at.
                    index = limit
                    continue
                }
                index = end
                guard !isEndTag else { continue }

                switch name {
                case Array("link".utf8):
                    result.links.append(attributes)
                case Array("base".utf8):
                    if let href = attributes["href"] {
                        result.baseHrefs.append(href)
                    }
                case Array("meta".utf8):
                    if result.charset == nil {
                        result.charset = charset(in: attributes)
                    }
                default:
                    if rawText.contains(name) {
                        let close = findEndTag(bytes, name: name, from: index)
                        if name == Array("title".utf8), result.title == nil {
                            result.title = String(decoding: bytes[index..<(close?.start ?? count)], as: UTF8.self)
                        }
                        index = close?.end ?? count
                    }
                }
            }
            return result
        }

        /// Reads attributes from `start` to the tag's end, quote-aware.
        /// Returns the index after the `>` and, when `keep` is set, the
        /// attributes; `nil` when the tag does not end before `limit`.
        private static func readAttributes(
            _ bytes: [UInt8], from start: Int, limit: Int, keep: Bool
        ) -> (Int, [String: String])? {
            var attributes: [String: String] = [:]
            var index = start
            while true {
                while index < limit, isSpace(bytes[index]) || bytes[index] == slash {
                    index += 1
                }
                guard index < limit else { return nil }
                if bytes[index] == greaterThan {
                    return (index + 1, attributes)
                }
                let nameStart = index
                index += 1
                while index < limit, !isSpace(bytes[index]), bytes[index] != slash, bytes[index] != greaterThan,
                      bytes[index] != equals {
                    index += 1
                }
                let nameEnd = index
                while index < limit, isSpace(bytes[index]) {
                    index += 1
                }
                var value = index..<index
                if index < limit, bytes[index] == equals {
                    index += 1
                    while index < limit, isSpace(bytes[index]) {
                        index += 1
                    }
                    if index < limit, bytes[index] == quote || bytes[index] == apostrophe {
                        let mark = bytes[index]
                        let valueStart = index + 1
                        index = valueStart
                        while index < limit, bytes[index] != mark {
                            index += 1
                        }
                        guard index < limit else { return nil }
                        value = valueStart..<index
                        index += 1
                    } else {
                        let valueStart = index
                        while index < limit, !isSpace(bytes[index]), bytes[index] != greaterThan {
                            index += 1
                        }
                        value = valueStart..<index
                    }
                }
                if keep {
                    let key = String(decoding: bytes[nameStart..<nameEnd].map(lowercased), as: UTF8.self)
                    if attributes[key] == nil {
                        attributes[key] = String(decoding: bytes[value], as: UTF8.self)
                    }
                }
            }
        }

        /// The next end tag `</name` (case ignored, followed by white space,
        /// `/`, `>` or the end), as the range from its `<` to after its `>`.
        private static func findEndTag(_ bytes: [UInt8], name: [UInt8], from start: Int) -> (start: Int, end: Int)? {
            let count = bytes.count
            var index = start
            while index < count {
                guard let open = bytes[index...].firstIndex(of: lessThan) else { return nil }
                let nameStart = open + 2
                if open + 1 < count, bytes[open + 1] == slash, nameStart + name.count <= count,
                   bytes[nameStart..<(nameStart + name.count)].map(lowercased) == name {
                    let after = nameStart + name.count
                    if after == count || isSpace(bytes[after]) || bytes[after] == slash || bytes[after] == greaterThan {
                        let end = (bytes[after...].firstIndex(of: greaterThan) ?? count - 1) + 1
                        return (open, end)
                    }
                }
                index = open + 1
            }
            return nil
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

        private static func hasPrefix(_ bytes: [UInt8], at index: Int, _ prefix: [UInt8]) -> Bool {
            index + prefix.count <= bytes.count && bytes[index..<(index + prefix.count)].elementsEqual(prefix)
        }

        private static func find(_ bytes: [UInt8], _ needle: [UInt8], from start: Int) -> Int? {
            var index = start
            while index + needle.count <= bytes.count {
                guard let first = bytes[index...].firstIndex(of: needle[0]) else { return nil }
                if hasPrefix(bytes, at: first, needle) {
                    return first
                }
                index = first + 1
            }
            return nil
        }
    }
}
