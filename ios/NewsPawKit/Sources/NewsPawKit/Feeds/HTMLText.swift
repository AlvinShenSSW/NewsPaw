import Foundation
import SwiftSoup

/// Plain text from feed HTML, and HTML from plain text, each in one linear
/// pass over the input.
///
/// No document tree is built: a tree builder's time can grow with the square
/// of the input on some markup (nested table cells), and a feed's description
/// can be megabytes long. The scanner removes tags, drops the content of
/// `script` and `style` elements and of comments, and decodes character
/// references. Named references are looked up one name at a time in
/// SwiftSoup's entity table (a dictionary and a binary search, bounded by the
/// name's length, so the pass stays linear).
enum HTMLText {
    /// The longest excerpt kept, in characters.
    static let excerptLength = 500

    /// The text of `html` with white space collapsed.
    static func reduce(_ html: String) -> String {
        collapseWhitespace(strip(Array(html.utf8)))
    }

    /// Up to `excerptLength` characters of text from `html`.
    static func excerpt(fromHTML html: String) -> String? {
        cut(reduce(html))
    }

    /// Up to `excerptLength` characters of plain `text`, white space collapsed.
    static func excerpt(fromText text: String) -> String? {
        cut(collapseWhitespace(text))
    }

    /// `text` with every run of white space turned into one space and the
    /// ends trimmed.
    static func collapseWhitespace(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                pendingSpace = true
                continue
            }
            if pendingSpace, !result.isEmpty {
                result.append(" ")
            }
            pendingSpace = false
            result.append(scalar)
        }
        return String(result)
    }

    /// `text` escaped so that, read as HTML, it shows as the same text.
    static func escape(_ text: String) -> String {
        var output: [UInt8] = []
        output.reserveCapacity(text.utf8.count)
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "&"): output.append(contentsOf: "&amp;".utf8)
            case UInt8(ascii: "<"): output.append(contentsOf: "&lt;".utf8)
            case UInt8(ascii: ">"): output.append(contentsOf: "&gt;".utf8)
            case UInt8(ascii: "\""): output.append(contentsOf: "&quot;".utf8)
            case UInt8(ascii: "'"): output.append(contentsOf: "&#39;".utf8)
            default: output.append(byte)
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func cut(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        var excerpt = String(text.prefix(excerptLength))
        while excerpt.last?.isWhitespace == true {
            excerpt.removeLast()
        }
        return excerpt
    }

    // MARK: - Scanner

    /// Elements whose start and end separate words.
    private static let blockElements: Set<[UInt8]> = Set([
        "address", "article", "aside", "blockquote", "br", "dd", "div", "dl", "dt", "figcaption", "figure",
        "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre",
        "section", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul",
    ].map { Array($0.utf8) })

    /// Elements whose content is not text.
    private static let rawTextElements: Set<[UInt8]> = [Array("script".utf8), Array("style".utf8)]

    /// Named references that HTML also recognises without their semicolon.
    private static let legacyNames: [[UInt8]: UInt32] = [
        Array("amp".utf8): 0x26, Array("lt".utf8): 0x3C, Array("gt".utf8): 0x3E, Array("quot".utf8): 0x22,
        Array("nbsp".utf8): 0xA0, Array("copy".utf8): 0xA9, Array("reg".utf8): 0xAE,
    ]

    /// What HTML reads numeric references 0x80–0x9F as (windows-1252).
    private static let windows1252: [UInt32: UInt32] = [
        0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021,
        0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160, 0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018,
        0x92: 0x2019, 0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02DC,
        0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153, 0x9E: 0x017E, 0x9F: 0x0178,
    ]

    private static let maximumNameLength = 32

    /// Removes markup and decodes references; block elements become spaces.
    /// White space is left for `collapseWhitespace`.
    static func strip(_ bytes: [UInt8]) -> String {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        let count = bytes.count
        var index = 0
        while index < count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "<") {
                index = skipMarkup(bytes, from: index, output: &output)
            } else if byte == UInt8(ascii: "&") {
                index = decodeReference(bytes, from: index, output: &output)
            } else {
                output.append(byte)
                index += 1
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Handles the markup starting at `start` (a `<`) and returns the index
    /// after it. A `<` that does not start markup is text.
    private static func skipMarkup(_ bytes: [UInt8], from start: Int, output: inout [UInt8]) -> Int {
        let count = bytes.count
        var index = start + 1
        guard index < count else {
            output.append(UInt8(ascii: "<"))
            return count
        }
        let next = bytes[index]
        if next == UInt8(ascii: "!") {
            if hasPrefix(bytes, at: index + 1, "--") {
                // A comment runs to `-->`, or to the end when unclosed.
                return find(bytes, "-->", from: index + 3).map { $0 + 3 } ?? count
            }
            return find(bytes, ">", from: index).map { $0 + 1 } ?? count
        }
        if next == UInt8(ascii: "?") {
            return find(bytes, ">", from: index).map { $0 + 1 } ?? count
        }
        let isEnd = next == UInt8(ascii: "/")
        if isEnd {
            index += 1
        }
        guard index < count, isLetter(bytes[index]) else {
            output.append(UInt8(ascii: "<"))
            return start + 1
        }
        var name: [UInt8] = []
        while index < count, isNameByte(bytes[index]), name.count <= maximumNameLength {
            name.append(lowercased(bytes[index]))
            index += 1
        }
        // Skip attributes up to the closing `>`, minding quoted values.
        var selfClosing = false
        while index < count {
            let byte = bytes[index]
            if byte == UInt8(ascii: ">") {
                selfClosing = index > start && bytes[index - 1] == UInt8(ascii: "/")
                index += 1
                break
            }
            if byte == UInt8(ascii: "=") {
                index += 1
                while index < count, isSpace(bytes[index]) { index += 1 }
                if index < count, bytes[index] == UInt8(ascii: "\"") || bytes[index] == UInt8(ascii: "'") {
                    let quote = bytes[index]
                    index += 1
                    while index < count, bytes[index] != quote { index += 1 }
                    index += 1
                }
                continue
            }
            index += 1
        }
        index = min(index, count)
        if blockElements.contains(name) {
            output.append(UInt8(ascii: " "))
        }
        if !isEnd, !selfClosing, rawTextElements.contains(name) {
            return skipRawText(bytes, from: index, name: name)
        }
        return index
    }

    /// Skips the content of a `script` or `style` element and its end tag.
    private static func skipRawText(_ bytes: [UInt8], from start: Int, name: [UInt8]) -> Int {
        let count = bytes.count
        var index = start
        while let open = find(bytes, "</", from: index) {
            var position = open + 2
            var matches = true
            for expected in name {
                guard position < count, lowercased(bytes[position]) == expected else {
                    matches = false
                    break
                }
                position += 1
            }
            if matches, position >= count || !isNameByte(bytes[position]) {
                return find(bytes, ">", from: position).map { $0 + 1 } ?? count
            }
            index = open + 2
        }
        return count
    }

    /// Decodes the character reference starting at `start` (a `&`) and
    /// returns the index after it. An `&` that starts no known reference is
    /// text.
    private static func decodeReference(_ bytes: [UInt8], from start: Int, output: inout [UInt8]) -> Int {
        let count = bytes.count
        var index = start + 1
        if index < count, bytes[index] == UInt8(ascii: "#") {
            index += 1
            let hex = index < count && (bytes[index] == UInt8(ascii: "x") || bytes[index] == UInt8(ascii: "X"))
            if hex {
                index += 1
            }
            var value: UInt32 = 0
            var digits = 0
            while index < count, let digit = digitValue(bytes[index], hex: hex) {
                if digits < 8 {
                    value = value * (hex ? 16 : 10) + digit
                }
                digits += 1
                index += 1
            }
            guard digits > 0 else {
                output.append(UInt8(ascii: "&"))
                return start + 1
            }
            if index < count, bytes[index] == UInt8(ascii: ";") {
                index += 1
            }
            appendScalar(numericScalar(value, digits: digits), to: &output)
            return index
        }

        var end = index
        while end < count, isAlphanumeric(bytes[end]), end - index < maximumNameLength {
            end += 1
        }
        guard end > index else {
            output.append(UInt8(ascii: "&"))
            return start + 1
        }
        let name = bytes[index..<end]
        if end < count, bytes[end] == UInt8(ascii: ";"), let scalars = Entities.codepointsForName(name) {
            for scalar in scalars {
                appendScalar(scalar, to: &output)
            }
            return end + 1
        }
        if let value = legacyNames[Array(name)], end >= count || (bytes[end] != UInt8(ascii: "=") && !isAlphanumeric(bytes[end])),
           let scalar = Unicode.Scalar(value) {
            appendScalar(scalar, to: &output)
            return end
        }
        output.append(UInt8(ascii: "&"))
        return start + 1
    }

    private static func numericScalar(_ value: UInt32, digits: Int) -> Unicode.Scalar {
        let replacement = Unicode.Scalar(0xFFFD)!
        guard digits <= 8, value != 0 else { return replacement }
        if let mapped = windows1252[value] {
            return Unicode.Scalar(mapped) ?? replacement
        }
        return Unicode.Scalar(value) ?? replacement
    }

    private static func appendScalar(_ scalar: Unicode.Scalar, to output: inout [UInt8]) {
        output.append(contentsOf: String(Character(scalar)).utf8)
    }

    // MARK: - Bytes

    private static func find(_ bytes: [UInt8], _ needle: StaticString, from start: Int) -> Int? {
        let pattern = needle.withUTF8Buffer { Array($0) }
        guard let first = pattern.first, start >= 0 else { return nil }
        var index = start
        let last = bytes.count - pattern.count
        while index <= last {
            if bytes[index] == first {
                var matches = true
                for offset in 1..<pattern.count where bytes[index + offset] != pattern[offset] {
                    matches = false
                    break
                }
                if matches {
                    return index
                }
            }
            index += 1
        }
        return nil
    }

    private static func hasPrefix(_ bytes: [UInt8], at index: Int, _ prefix: StaticString) -> Bool {
        let pattern = prefix.withUTF8Buffer { Array($0) }
        guard index + pattern.count <= bytes.count else { return false }
        for (offset, byte) in pattern.enumerated() where bytes[index + offset] != byte {
            return false
        }
        return true
    }

    private static func digitValue(_ byte: UInt8, hex: Bool) -> UInt32? {
        switch byte {
        case 48...57: UInt32(byte - 48)
        case 97...102 where hex: UInt32(byte - 87)
        case 65...70 where hex: UInt32(byte - 55)
        default: nil
        }
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        isLetter(byte) || (byte >= 48 && byte <= 57)
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        isAlphanumeric(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ":") || byte == UInt8(ascii: "_")
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        byte >= 65 && byte <= 90 ? byte + 32 : byte
    }
}
