import Foundation

/// One linear pass over the bytes of a decoded HTML document, as tokens:
/// text, start tags, the content of raw-text elements and end tags (RD05
/// decision 5; RD11 decision 1). Feed discovery reads a page's `<link>`,
/// `<base>`, `<title>` and `<meta>` with it; the body converter reads an
/// article's HTML with it. It never backs up and builds no tree: every byte
/// is visited a bounded number of times, since a tag, a comment or a
/// raw-text element that does not end consumes what it looked at.
///
/// - A tag ends at the first `>` outside a quoted attribute value; a tag
///   with no end within `maximumTagLength` bytes is skipped, and the scan
///   goes on after those bytes.
/// - A tag name ends at white space, `/` or `>` and is compared ignoring
///   case.
/// - Comments are passed over. An unclosed comment ends the scan.
/// - The content of a raw-text element is one token, not scanned for tags.
/// - A `<` that starts no tag is text.
/// Accepted approximations: a `<!…>` that is not a comment ends at the first
/// `>`; `<!-->` is a complete comment.
enum TagScanner {
    /// A tag or attribute name: its bytes in lower case with their count,
    /// packed, so that names compare and hash as one number. Names longer
    /// than 15 bytes are all `other`: no name the scans look for is that
    /// long.
    struct Name: Hashable, ExpressibleByStringLiteral, Sendable {
        /// The bytes, the first lowest, and the count in the highest byte.
        let packed: UInt128

        static let other = Name(packed: 0)

        private init(packed: UInt128) {
            self.packed = packed
        }

        init(stringLiteral value: StaticString) {
            self = value.withUTF8Buffer { Name($0, from: 0, to: $0.count) }
        }

        init(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) {
            let count = end - start
            guard count > 0, count <= 15 else {
                self = .other
                return
            }
            var packed: UInt128 = 0
            var index = end
            while index > start {
                index -= 1
                packed = (packed << 8) | UInt128(TagScanner.lowercased(bytes[index]))
            }
            self.packed = packed | (UInt128(count) << 120)
        }

        /// The name's bytes.
        var bytes: [UInt8] {
            let count = Int(packed >> 120)
            return (0..<count).map { UInt8(truncatingIfNeeded: packed >> UInt128($0 * 8)) }
        }
    }

    struct Token {
        enum Kind {
            /// Text between markup, as written: references are not decoded.
            case text
            case startTag
            /// The content of the raw-text element whose start tag came
            /// just before, as written.
            case rawText
            case endTag
        }

        var kind: Kind
        /// The bytes of the text, or of the whole tag.
        var range: Range<Int>
        /// The tag's name; for raw text, its element's.
        var name: Name = .other
        /// A start tag's attributes, names in lower case, the first of a
        /// repeated name kept; empty unless the scan keeps this tag's.
        var attributes: [String: String] = [:]
        /// Whether a start tag ends in `/>`.
        var isSelfClosing = false
    }

    struct Options {
        /// The longest tag read, in bytes.
        var maximumTagLength: Int
        /// The elements whose content is one token of raw text.
        var rawTextElements: Set<Name>
        /// The start tags whose attributes are read.
        var tagsWithAttributes: Set<Name>
        /// The attributes read on those tags; `nil` for all of them.
        var attributes: Set<Name>?
        /// Whether a raw-text element written as `<name/>` has no content.
        /// A browser does not read it so; XML serialisers write it so.
        var selfClosingHasNoContent = false
    }

    private static let lessThan = UInt8(ascii: "<")
    private static let greaterThan = UInt8(ascii: ">")
    private static let slash = UInt8(ascii: "/")
    private static let equals = UInt8(ascii: "=")
    private static let bang = UInt8(ascii: "!")
    private static let question = UInt8(ascii: "?")
    private static let quote = UInt8(ascii: "\"")
    private static let apostrophe = UInt8(ascii: "'")
    private static let dash = UInt8(ascii: "-")

    /// Scans `bytes` and hands each token to `handle`, in document order,
    /// until the end or until `handle` returns false.
    static func scan(_ bytes: [UInt8], options: Options, _ handle: (Token) -> Bool) {
        bytes.withUnsafeBufferPointer { buffer in
            scan(buffer, options: options, handle)
        }
    }

    static func scan(_ bytes: UnsafeBufferPointer<UInt8>, options: Options, _ handle: (Token) -> Bool) {
        let count = bytes.count
        /// Where the text not yet handed over starts.
        var textStart = 0
        var index = 0

        /// Hands over the text before `end`; false when the scan is to stop.
        func flushText(to end: Int) -> Bool {
            guard end > textStart else { return true }
            return handle(Token(kind: .text, range: textStart..<end))
        }

        while index < count {
            guard let open = find(lessThan, in: bytes, from: index, to: count) else { break }
            let next = open + 1
            guard next < count else { break }
            switch bytes[next] {
            case bang:
                guard flushText(to: open) else { return }
                if next + 2 < count, bytes[next + 1] == dash, bytes[next + 2] == dash {
                    // `<!-->` is a complete comment, so the end is looked
                    // for from the first `-`.
                    guard let end = findCommentEnd(in: bytes, from: next + 1) else { return }
                    index = end + 3
                } else {
                    index = (find(greaterThan, in: bytes, from: next, to: count) ?? count - 1) + 1
                }
                textStart = index
                continue
            case question:
                guard flushText(to: open) else { return }
                index = (find(greaterThan, in: bytes, from: next, to: count) ?? count - 1) + 1
                textStart = index
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
            guard flushText(to: open) else { return }
            let limit = open + min(count - open, options.maximumTagLength)
            var nameEnd = nameStart
            while nameEnd < limit, !isSpace(bytes[nameEnd]), bytes[nameEnd] != slash, bytes[nameEnd] != greaterThan {
                nameEnd += 1
            }
            let name = Name(bytes, from: nameStart, to: nameEnd)
            let keep = !isEndTag && options.tagsWithAttributes.contains(name)
            var attributes: [String: String] = [:]
            guard let end = readAttributes(
                bytes, from: nameEnd, limit: limit, keep: keep, into: &attributes, only: options.attributes
            ) else {
                // No end within the limit: the tag is skipped with what was
                // looked at.
                index = limit
                textStart = index
                continue
            }
            index = end
            textStart = index
            if isEndTag {
                guard handle(Token(kind: .endTag, range: open..<end, name: name)) else { return }
                continue
            }
            let isSelfClosing = end >= 2 && bytes[end - 2] == slash
            guard handle(Token(kind: .startTag, range: open..<end, name: name, attributes: attributes, isSelfClosing: isSelfClosing))
            else { return }
            if options.rawTextElements.contains(name), !(isSelfClosing && options.selfClosingHasNoContent) {
                let close = findEndTag(bytes, name: name.bytes, from: index)
                guard handle(Token(kind: .rawText, range: index..<(close?.start ?? count), name: name)) else { return }
                index = close?.end ?? count
                textStart = index
                if let close {
                    guard handle(Token(kind: .endTag, range: close.start..<close.end, name: name)) else { return }
                }
            }
        }
        _ = flushText(to: count)
    }

    /// Reads attributes from `start` to the tag's end, quote-aware. Returns
    /// the index after the `>`, or `nil` when the tag does not end before
    /// `limit`. When `keep` is set, the attributes named in `only` (all,
    /// when it is `nil`) are written to `attributes`.
    private static func readAttributes(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int, limit: Int,
        keep: Bool, into attributes: inout [String: String], only: Set<Name>?
    ) -> Int? {
        var index = start
        while true {
            while index < limit, isSpace(bytes[index]) || bytes[index] == slash {
                index += 1
            }
            guard index < limit else { return nil }
            if bytes[index] == greaterThan {
                return index + 1
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
                    guard let valueEnd = find(mark, in: bytes, from: valueStart, to: limit) else { return nil }
                    value = valueStart..<valueEnd
                    index = valueEnd + 1
                } else {
                    let valueStart = index
                    while index < limit, !isSpace(bytes[index]), bytes[index] != greaterThan {
                        index += 1
                    }
                    value = valueStart..<index
                }
            }
            if keep {
                if let only, !only.contains(Name(bytes, from: nameStart, to: nameEnd)) {
                    continue
                }
                var key = [UInt8](repeating: 0, count: nameEnd - nameStart)
                for offset in 0..<key.count {
                    key[offset] = lowercased(bytes[nameStart + offset])
                }
                let name = String(decoding: key, as: UTF8.self)
                if attributes[name] == nil {
                    attributes[name] = String(decoding: UnsafeBufferPointer(rebasing: bytes[value]), as: UTF8.self)
                }
            }
        }
    }

    /// The next end tag `</name` (case ignored, followed by white space,
    /// `/`, `>` or the end), as the range from its `<` to after its `>`.
    private static func findEndTag(
        _ bytes: UnsafeBufferPointer<UInt8>, name: [UInt8], from start: Int
    ) -> (start: Int, end: Int)? {
        let count = bytes.count
        var index = start
        while index < count {
            guard let open = find(lessThan, in: bytes, from: index, to: count) else { return nil }
            let nameStart = open + 2
            if open + 1 < count, bytes[open + 1] == slash, nameStart + name.count <= count {
                var matches = true
                for offset in 0..<name.count where lowercased(bytes[nameStart + offset]) != name[offset] {
                    matches = false
                    break
                }
                if matches {
                    let after = nameStart + name.count
                    if after == count || isSpace(bytes[after]) || bytes[after] == slash || bytes[after] == greaterThan {
                        let end = (find(greaterThan, in: bytes, from: after, to: count) ?? count - 1) + 1
                        return (open, end)
                    }
                }
            }
            index = open + 1
        }
        return nil
    }

    /// The index of the `-->` at or after `start`.
    private static func findCommentEnd(in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        let count = bytes.count
        var index = start
        while index + 3 <= count {
            guard let first = find(dash, in: bytes, from: index, to: count) else { return nil }
            if first + 3 <= count, bytes[first + 1] == dash, bytes[first + 2] == greaterThan {
                return first
            }
            index = first + 1
        }
        return nil
    }

    /// The first index of `byte` in `bytes[start..<end]`.
    private static func find(_ byte: UInt8, in bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) -> Int? {
        guard start < end, let base = bytes.baseAddress else { return nil }
        guard let found = memchr(base + start, Int32(byte), end - start) else { return nil }
        return base.distance(to: found.assumingMemoryBound(to: UInt8.self))
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
