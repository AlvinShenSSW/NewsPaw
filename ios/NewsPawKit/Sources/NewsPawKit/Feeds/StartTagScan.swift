import Foundation

/// A pass over an XML document's bytes, before the system parser sees them,
/// that finds the first start tag with more attributes than
/// `maximumAttributes`.
///
/// The system parser takes time that grows with the square of the number of
/// attributes on one start tag (measured: 400,000 attributes in 4.3 MB,
/// 41 seconds), and it spends that time inside the tag, before any delegate
/// callback could stop it. So the document is cut at that tag's `<` and
/// only the part before it is parsed: the result is what the parser would
/// give if it stopped there — the items completed before are kept and the
/// document is incomplete, or, with no completed item, not a feed.
///
/// The scan follows XML's tokenisation closely enough to see every start tag
/// the parser sees in any prefix it accepts as well-formed: comments, CDATA
/// sections, processing instructions and the document type with its internal
/// subset are skipped as such, and quoted attribute values may hold `>`. So
/// no tag can hide from it, and escaped HTML in text is text. Where the scan
/// meets something that is not well-formed it stops looking: the parser
/// stops at or before that point too, so nothing after it is ever parsed.
///
/// It works on bytes. That is sound for the encodings the design supports,
/// which keep ASCII bytes for ASCII characters:
/// - UTF-8, the ISO 8859 and Windows single-byte sets, EUC-JP, EUC-KR and
///   EUC-CN never use a byte below 0x80 inside a multibyte character;
/// - Shift_JIS (and the double-byte Chinese and Korean sets) can use 0x40–0x7E
///   as a second byte, but never `<`, `>`, `"`, `'`, `=`, `/`, `-`, `?` or
///   white space; of the bytes the scan looks for only `]` (0x5D) can be a
///   second byte, so the scan steps character by character, in the encoding
///   the document declares, where it looks for `]`: inside CDATA sections and
///   the internal subset.
/// A document in an encoding that is not ASCII-compatible — UTF-16, UTF-32,
/// ISO-2022, UTF-7, EBCDIC; all non-goals of the design — is cut at its first
/// byte, so it is not a feed.
enum StartTagScan {
    /// The most attributes, namespace declarations included, accepted on one
    /// start tag. Real feeds use a few dozen at most (the root's namespace
    /// declarations); at 256 per tag a 10 MB document of such tags parses in
    /// about 0.35 s on the system parser (measured on this Mac).
    static let maximumAttributes = 256

    /// How bytes form characters in the declared encoding.
    enum ByteMode: Equatable {
        /// Bytes below 0x80 are always ASCII characters.
        case asciiCompatible
        /// Shift_JIS and its variants: 0x81–0x9F and 0xE0–0xFC start a
        /// two-byte character.
        case shiftJIS
        /// Big5, GBK, GB18030, UHC and similar: 0x81–0xFE start a two-byte
        /// character (GB18030's four-byte ones are two such pairs).
        case doubleByte
    }

    /// The offset at which the document must be cut: the `<` of the first
    /// start tag with too many attributes, or 0 for an encoding that is not
    /// ASCII-compatible; `nil` when nothing needs cutting.
    static func cutOffset(in data: Data) -> Int? {
        data.withUnsafeBytes { raw -> Int? in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard let (mode, start) = byteMode(of: bytes) else { return 0 }
            return Scanner(bytes: bytes, mode: mode).run(from: start)
        }
    }

    // MARK: - Encoding

    /// The byte mode of the encoding the parser will read the document in,
    /// and where scanning starts; `nil` when it is not ASCII-compatible.
    static func byteMode(of bytes: UnsafeBufferPointer<UInt8>) -> (ByteMode, Int)? {
        let head = Array(bytes.prefix(4))
        if head.starts(with: [0xFE, 0xFF]) || head.starts(with: [0xFF, 0xFE]) || head.contains(0x00)
            || head == [0x4C, 0x6F, 0xA7, 0x94] {
            // UTF-16 or UTF-32 (a byte-order mark, or the zero bytes of
            // `<?` in two or four bytes), or EBCDIC's `<?xm`.
            return nil
        }
        let start = head.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        if start == 3 {
            // With a UTF-8 byte-order mark the parser reads UTF-8.
            return (.asciiCompatible, start)
        }
        let window = Array(bytes.prefix(1024))
        guard window.starts(with: Array("<?xml".utf8)), window.count > 5, isSpace(window[5]),
              let end = FeedParser.firstIndex(of: Array("?>".utf8), in: window[...], from: 0),
              let range = FeedParser.quotedValue(named: "encoding", in: Array(window[0..<end]))
        else { return (.asciiCompatible, start) }
        let label = String(decoding: window[range], as: UTF8.self)
        return mode(forLabel: label).map { ($0, start) }
    }

    /// The byte mode for an encoding label; `nil` when the encoding is not
    /// ASCII-compatible. A label not recognised here is read as
    /// ASCII-compatible, which is what every other encoding the parser
    /// knows is.
    static func mode(forLabel label: String) -> ByteMode? {
        let name = label.lowercased()
        let notASCIICompatible = [
            "utf-16", "utf16", "ucs-2", "ucs2", "utf-32", "utf32", "ucs-4", "ucs4", "2022", "utf-7", "utf7", "hz-gb",
            "ebcdic", "cp037", "ibm037", "ibm-037", "cp500", "ibm500", "ibm-500", "cp1047", "ibm1047", "ibm-1047", "cp875",
        ]
        if notASCIICompatible.contains(where: name.contains) || name == "unicode" || name.hasPrefix("unicodef") {
            return nil
        }
        if name.contains("euc") {
            return .asciiCompatible
        }
        if ["shift", "sjis", "kanji", "31j", "932", "943", "japanese"].contains(where: name.contains) {
            return .shiftJIS
        }
        if ["big5", "950", "gbk", "gb2312", "gb18030", "936", "949", "uhc", "5601", "johab", "chinese", "korean"]
            .contains(where: name.contains) {
            return .doubleByte
        }
        return .asciiCompatible
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    // MARK: - Scanner

    private struct Scanner {
        let bytes: UnsafeBufferPointer<UInt8>
        let mode: ByteMode

        private enum Tag {
            case ended(at: Int)
            case tooManyAttributes
            case notWellFormed
        }

        private static let lessThan = UInt8(ascii: "<")
        private static let greaterThan = UInt8(ascii: ">")
        private static let slash = UInt8(ascii: "/")
        private static let equals = UInt8(ascii: "=")
        private static let quote = UInt8(ascii: "\"")
        private static let apostrophe = UInt8(ascii: "'")
        private static let openBracket = UInt8(ascii: "[")
        private static let closeBracket = UInt8(ascii: "]")

        func run(from start: Int) -> Int? {
            let count = bytes.count
            var index = start
            while let open = find(Self.lessThan, from: index) {
                guard open + 1 < count else { return nil }
                let next = bytes[open + 1]
                if next == UInt8(ascii: "!") {
                    if has("<!--", at: open) {
                        guard let end = find("-->", from: open + 4) else { return nil }
                        index = end + 3
                    } else if has("<![CDATA[", at: open) {
                        guard let end = findCDATAEnd(from: open + 9) else { return nil }
                        index = end + 3
                    } else if has("<!DOCTYPE", at: open) {
                        guard let end = skipDocumentType(from: open + 9) else { return nil }
                        index = end
                    } else {
                        return nil
                    }
                } else if next == UInt8(ascii: "?") {
                    guard let end = find("?>", from: open + 2) else { return nil }
                    index = end + 2
                } else if next == Self.slash {
                    guard let end = find(Self.greaterThan, from: open + 2) else { return nil }
                    index = end + 1
                } else if isNameStart(next) {
                    switch startTag(from: open + 1) {
                    case .ended(let end): index = end
                    case .tooManyAttributes: return open
                    case .notWellFormed: return nil
                    }
                } else {
                    return nil
                }
            }
            return nil
        }

        /// Reads a start tag after its `<`, counting attributes.
        private func startTag(from start: Int) -> Tag {
            let count = bytes.count
            var index = skipName(from: start)
            var attributes = 0
            while true {
                index = skipSpace(from: index)
                guard index < count else { return .notWellFormed }
                let byte = bytes[index]
                if byte == Self.greaterThan {
                    return .ended(at: index + 1)
                }
                if byte == Self.slash {
                    return index + 1 < count && bytes[index + 1] == Self.greaterThan ? .ended(at: index + 2) : .notWellFormed
                }
                guard isNameStart(byte) else { return .notWellFormed }
                index = skipSpace(from: skipName(from: index))
                guard index < count, bytes[index] == Self.equals else { return .notWellFormed }
                index = skipSpace(from: index + 1)
                guard index < count, bytes[index] == Self.quote || bytes[index] == Self.apostrophe,
                      let close = find(bytes[index], from: index + 1)
                else { return .notWellFormed }
                attributes += 1
                if attributes > StartTagScan.maximumAttributes {
                    return .tooManyAttributes
                }
                index = close + 1
            }
        }

        /// Skips the rest of `<!DOCTYPE`: an external identifier whose
        /// literals may hold anything, then an internal subset whose
        /// declarations' literals, comments and processing instructions may
        /// hold `]` and `>`. Returns the index after the closing `>`.
        private func skipDocumentType(from start: Int) -> Int? {
            let count = bytes.count
            var index = start
            while index < count {
                let byte = bytes[index]
                if byte == Self.quote || byte == Self.apostrophe {
                    guard let close = find(byte, from: index + 1) else { return nil }
                    index = close + 1
                } else if byte == Self.greaterThan {
                    return index + 1
                } else if byte == Self.openBracket {
                    index += 1
                    break
                } else {
                    index = advance(index)
                }
            }
            while index < count {
                let byte = bytes[index]
                switch byte {
                case Self.quote, Self.apostrophe:
                    guard let close = find(byte, from: index + 1) else { return nil }
                    index = close + 1
                case Self.lessThan where has("<!--", at: index):
                    guard let end = find("-->", from: index + 4) else { return nil }
                    index = end + 3
                case Self.lessThan where has("<?", at: index):
                    guard let end = find("?>", from: index + 2) else { return nil }
                    index = end + 2
                case Self.closeBracket:
                    index = skipSpace(from: index + 1)
                    guard index < count, bytes[index] == Self.greaterThan else { return nil }
                    return index + 1
                default:
                    index = advance(index)
                }
            }
            return nil
        }

        /// The index of the `]]>` that ends a CDATA section, found character
        /// by character because `]` can be the second byte of a character.
        private func findCDATAEnd(from start: Int) -> Int? {
            let count = bytes.count
            var index = start
            if mode == .asciiCompatible {
                return find("]]>", from: start)
            }
            while index + 2 < count {
                if bytes[index] == Self.closeBracket, bytes[index + 1] == Self.closeBracket, bytes[index + 2] == Self.greaterThan {
                    return index
                }
                index = advance(index)
            }
            return nil
        }

        // MARK: Bytes

        /// The index after the character at `index`.
        private func advance(_ index: Int) -> Int {
            let byte = bytes[index]
            switch mode {
            case .asciiCompatible:
                return index + 1
            case .shiftJIS:
                return (0x81...0x9F).contains(byte) || (0xE0...0xFC).contains(byte) ? index + 2 : index + 1
            case .doubleByte:
                return (0x81...0xFE).contains(byte) ? index + 2 : index + 1
            }
        }

        /// The first `byte` at or after `start`. Only for bytes that are
        /// never the second byte of a character, so any match starts one.
        private func find(_ byte: UInt8, from start: Int) -> Int? {
            guard start < bytes.count, let base = bytes.baseAddress else { return nil }
            guard let found = memchr(base + start, Int32(byte), bytes.count - start) else { return nil }
            return base.distance(to: found.assumingMemoryBound(to: UInt8.self))
        }

        /// The first `pattern` at or after `start`, for patterns whose first
        /// byte is never the second byte of a character.
        private func find(_ pattern: StaticString, from start: Int) -> Int? {
            let length = pattern.utf8CodeUnitCount
            let first = pattern.utf8Start.pointee
            var index = start
            while let candidate = find(first, from: index) {
                if candidate + length > bytes.count {
                    return nil
                }
                if has(pattern, at: candidate) {
                    return candidate
                }
                index = candidate + 1
            }
            return nil
        }

        private func has(_ pattern: StaticString, at index: Int) -> Bool {
            let length = pattern.utf8CodeUnitCount
            guard index >= 0, index + length <= bytes.count else { return false }
            let start = pattern.utf8Start
            for offset in 0..<length where bytes[index + offset] != start[offset] {
                return false
            }
            return true
        }

        private func skipSpace(from start: Int) -> Int {
            var index = start
            while index < bytes.count, StartTagScan.isSpace(bytes[index]) {
                index += 1
            }
            return index
        }

        /// Skips a name: everything up to white space or a byte that ends
        /// one. None of those bytes is ever the second byte of a character.
        private func skipName(from start: Int) -> Int {
            var index = start
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D, Self.slash, Self.greaterThan, Self.equals, Self.quote, Self.apostrophe, Self.lessThan:
                    return index
                default:
                    index += 1
                }
            }
            return index
        }

        private func isNameStart(_ byte: UInt8) -> Bool {
            (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == UInt8(ascii: "_")
                || byte == UInt8(ascii: ":") || byte >= 0x80
        }
    }
}
