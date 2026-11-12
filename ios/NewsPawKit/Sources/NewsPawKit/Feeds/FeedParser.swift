import CryptoKit
import Foundation

/// Turns a downloaded document into a feed (spec N03, N12). It has no
/// network and no store: bytes in, a `ParsedFeed` or "not a feed" out.
///
/// The format is recognised by the document itself: JSON with a JSON Feed
/// `version`, or XML whose root is RSS (with a channel), RDF (with an RSS 1.0
/// channel or item) or Atom (with an id, a title or an entry). Anything else
/// is not a feed, including documents a lenient parser would read as empty
/// feeds.
public enum FeedParser {
    /// Parses `data`.
    ///
    /// - Parameters:
    ///   - charset: the charset the HTTP response named, if any. The bytes are
    ///     parsed as sent first; only when that fails and `charset` is a plain
    ///     token is it written into the XML declaration for one more try.
    ///   - baseURL: the final address of the response, against which links and
    ///     image addresses are resolved.
    /// - Returns: the feed, or `nil` when the document is not a feed.
    public static func parse(_ data: Data, charset: String?, baseURL: URL) -> ParsedFeed? {
        let data = trimmingSpaceBeforeDeclaration(data)
        if firstSignificantByte(of: data) == UInt8(ascii: "{") {
            let json = data.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(data.dropFirst(3)) : data
            return JSONFeedReader.read(json, baseURL: baseURL)
        }
        let asSent = XMLFeedReader.read(data)
        var chosen = asSent
        if !asSent.wellFormed, !asSent.rootRefused,
           let charset, isPlainToken(charset), let declared = declaring(charset, in: data) {
            let retried = XMLFeedReader.read(declared)
            if isFeed(retried), retried.wellFormed || !isFeed(asSent) {
                chosen = retried
            }
        }
        guard isFeed(chosen), let format = chosen.format else { return nil }
        return ParsedFeed(
            format: format,
            title: chosen.title.map { chosen.titleKind == .text ? HTMLText.collapseWhitespace($0) : HTMLText.reduce($0) }
                .flatMap { $0.isEmpty ? nil : $0 },
            siteURL: RawItem.webAddress(chosen.siteLink, base: baseURL),
            items: chosen.items.compactMap { $0.resolved(against: baseURL) },
            isComplete: chosen.wellFormed
        )
    }

    /// A feed is a recognised root with what its format needs. A document
    /// that broke part-way is a feed only when at least one item was
    /// completed before the break.
    private static func isFeed(_ result: XMLFeedReader.Result) -> Bool {
        guard result.format != nil, result.hasFeedMarker else { return false }
        return result.wellFormed || !result.items.isEmpty
    }

    // MARK: - Charset

    /// Letters, digits, `.`, `_` and `-` only.
    static func isPlainToken(_ charset: String) -> Bool {
        !charset.isEmpty && charset.utf8.count <= 40 && charset.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }
    }

    /// `data` with `charset` written into its XML declaration: replacing an
    /// existing `encoding`, inserted after the version in a declaration
    /// without one, or in a new declaration when there is none. `nil` when
    /// the document starts with a byte-order mark or its declaration cannot
    /// be read.
    static func declaring(_ charset: String, in data: Data) -> Data? {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) || bytes.starts(with: [0xFE, 0xFF]) || bytes.starts(with: [0xFF, 0xFE]) {
            return nil
        }
        let value = Array(charset.utf8)
        let opening = Array("<?xml".utf8)
        guard bytes.starts(with: opening), bytes.count > opening.count, isXMLSpace(bytes[opening.count]) else {
            return Data(Array("<?xml version=\"1.0\" encoding=\"".utf8) + value + Array("\"?>\n".utf8) + bytes)
        }
        let window = bytes.prefix(1024)
        guard let end = firstIndex(of: Array("?>".utf8), in: window, from: 0) else { return nil }
        let declaration = Array(bytes[0..<end])
        if let range = quotedValue(named: "encoding", in: declaration) {
            return Data(Array(bytes[..<range.lowerBound]) + value + Array(bytes[range.upperBound...]))
        }
        let insertion = Array(" encoding=\"".utf8) + value + [UInt8(ascii: "\"")]
        let position = quotedValue(named: "version", in: declaration).map { $0.upperBound + 1 } ?? opening.count
        return Data(Array(bytes[..<position]) + insertion + Array(bytes[position...]))
    }

    /// The range of the value of pseudo-attribute `name` inside an XML
    /// declaration, quotes excluded.
    static func quotedValue(named name: String, in declaration: [UInt8]) -> Range<Int>? {
        guard var index = firstIndex(of: Array(name.utf8), in: declaration[...], from: 0) else { return nil }
        index += name.utf8.count
        while index < declaration.count, isXMLSpace(declaration[index]) { index += 1 }
        guard index < declaration.count, declaration[index] == UInt8(ascii: "=") else { return nil }
        index += 1
        while index < declaration.count, isXMLSpace(declaration[index]) { index += 1 }
        guard index < declaration.count, declaration[index] == UInt8(ascii: "\"") || declaration[index] == UInt8(ascii: "'") else {
            return nil
        }
        let quote = declaration[index]
        let start = index + 1
        guard let close = declaration[start...].firstIndex(of: quote) else { return nil }
        return start..<close
    }

    static func firstIndex(of needle: [UInt8], in haystack: ArraySlice<UInt8>, from start: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        var index = haystack.startIndex + start
        while index + needle.count <= haystack.endIndex {
            if haystack[index..<(index + needle.count)].elementsEqual(needle) {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func isXMLSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// `data` without the XML white space between an optional UTF-8
    /// byte-order mark and an XML declaration: the system parser refuses a
    /// declaration that is not at the very start, and some servers send a
    /// newline before it (RD05).
    static func trimmingSpaceBeforeDeclaration(_ data: Data) -> Data {
        let start = data.startIndex + (data.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0)
        var index = start
        while index < data.endIndex, isXMLSpace(data[index]) {
            index += 1
        }
        guard index > start, data[index...].starts(with: Array("<?xml".utf8)) else { return data }
        return Data(data[data.startIndex..<start] + data[index...])
    }

    /// The first byte after a UTF-8 byte-order mark and white space.
    private static func firstSignificantByte(of data: Data) -> UInt8? {
        var index = data.startIndex
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            index += 3
        }
        while index < data.endIndex {
            let byte = data[index]
            if !isXMLSpace(byte) {
                return byte
            }
            index += 1
        }
        return nil
    }
}

/// The last resort of identity (spec N04): a hash of the raw title and the
/// raw date, as the feed wrote them.
enum ItemIdentity {
    static func hash(title: String?, date: String?) -> String {
        // A separator that cannot occur in XML or JSON text keeps
        // ("ab", "c") and ("a", "bc") apart.
        let input = (title ?? "") + "\u{0}" + (date ?? "")
        let digest = SHA256.hash(data: Data(input.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
