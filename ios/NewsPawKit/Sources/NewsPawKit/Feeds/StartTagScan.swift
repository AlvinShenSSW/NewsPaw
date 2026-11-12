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
/// It works on bytes, in the byte mode of the encoding the document
/// declares. That is sound only for encodings whose mode is known, so the
/// scan accepts a declared encoding only when its label is in `labels` —
/// the labels of the WHATWG Encoding Standard for UTF-8, the legacy
/// single-byte sets, EUC-JP, EUC-KR, GBK, gb18030, Big5 and Shift_JIS. Each
/// was checked against the system parser (`EncodingLabelProofTests`):
/// - in an ASCII-compatible encoding no byte below 0x80 is ever part of a
///   multibyte character;
/// - in Shift_JIS and the double-byte sets a second byte can be 0x40–0x7E,
///   but never `<`, `>`, `"`, `'`, `=`, `/`, `-`, `?`, `!` or white space; of
///   the bytes the scan looks for only `[` and `]` can be second bytes, so the
///   scan steps character by character, with the lead bytes the parser uses,
///   where it looks for those: inside CDATA sections and the document type.
/// Any other declared label — whether or not the parser knows it — and any
/// document whose declaration cannot be read exactly, or that is in UTF-16,
/// UTF-32 or EBCDIC, is cut at its first byte, so it is not a feed: its tags
/// cannot be found reliably byte by byte.
///
/// A document type whose internal subset holds an attribute-list declaration
/// is cut at the first byte too, so the parser never sees it: an enumerated
/// type of some twenty thousand values overflows the parser's stack (R13),
/// and many default attributes make every later element slow, even after an
/// error (R11).
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

    /// The labels the scan accepts, each with its byte mode, matched exactly
    /// and without regard to case. From the WHATWG Encoding Standard's label
    /// table; UTF-16, ISO-2022-JP, "replacement" and x-user-defined are left
    /// out. A label the system parser does not know cannot hide anything:
    /// the parser refuses the document.
    static let labels: [String: ByteMode] = {
        var table: [String: ByteMode] = [:]
        let asciiCompatible = [
            // UTF-8
            "unicode-1-1-utf-8", "unicode11utf8", "unicode20utf8", "utf-8", "utf8", "x-unicode20utf8",
            // IBM866
            "866", "cp866", "csibm866", "ibm866",
            // ISO-8859-2 to -16
            "csisolatin2", "iso-8859-2", "iso-ir-101", "iso8859-2", "iso88592", "iso_8859-2", "iso_8859-2:1987", "l2", "latin2",
            "csisolatin3", "iso-8859-3", "iso-ir-109", "iso8859-3", "iso88593", "iso_8859-3", "iso_8859-3:1988", "l3", "latin3",
            "csisolatin4", "iso-8859-4", "iso-ir-110", "iso8859-4", "iso88594", "iso_8859-4", "iso_8859-4:1988", "l4", "latin4",
            "csisolatincyrillic", "cyrillic", "iso-8859-5", "iso-ir-144", "iso8859-5", "iso88595", "iso_8859-5", "iso_8859-5:1988",
            "arabic", "asmo-708", "csiso88596e", "csiso88596i", "csisolatinarabic", "ecma-114", "iso-8859-6", "iso-8859-6-e",
            "iso-8859-6-i", "iso-ir-127", "iso8859-6", "iso88596", "iso_8859-6", "iso_8859-6:1987",
            "csisolatingreek", "ecma-118", "elot_928", "greek", "greek8", "iso-8859-7", "iso-ir-126", "iso8859-7", "iso88597",
            "iso_8859-7", "iso_8859-7:1987", "sun_eu_greek",
            "csiso88598e", "csisolatinhebrew", "hebrew", "iso-8859-8", "iso-8859-8-e", "iso-ir-138", "iso8859-8", "iso88598",
            "iso_8859-8", "iso_8859-8:1988", "visual",
            "csiso88598i", "iso-8859-8-i", "logical",
            "csisolatin6", "iso-8859-10", "iso-ir-157", "iso8859-10", "iso885910", "l6", "latin6",
            "iso-8859-13", "iso8859-13", "iso885913",
            "iso-8859-14", "iso8859-14", "iso885914",
            "csisolatin9", "iso-8859-15", "iso8859-15", "iso885915", "iso_8859-15", "l9",
            "iso-8859-16",
            // KOI8-R, KOI8-U, macintosh, x-mac-cyrillic
            "cskoi8r", "koi", "koi8", "koi8-r", "koi8_r", "koi8-ru", "koi8-u",
            "csmacintosh", "mac", "macintosh", "x-mac-roman", "x-mac-cyrillic", "x-mac-ukrainian",
            // windows-874 and windows-1250 to -1258
            "dos-874", "iso-8859-11", "iso8859-11", "iso885911", "tis-620", "windows-874",
            "cp1250", "windows-1250", "x-cp1250",
            "cp1251", "windows-1251", "x-cp1251",
            "ansi_x3.4-1968", "ascii", "cp1252", "cp819", "csisolatin1", "ibm819", "iso-8859-1", "iso-ir-100", "iso8859-1",
            "iso88591", "iso_8859-1", "iso_8859-1:1987", "l1", "latin1", "us-ascii", "windows-1252", "x-cp1252",
            "cp1253", "windows-1253", "x-cp1253",
            "cp1254", "csisolatin5", "iso-8859-9", "iso-ir-148", "iso8859-9", "iso88599", "iso_8859-9", "iso_8859-9:1989", "l5",
            "latin5", "windows-1254", "x-cp1254",
            "cp1255", "windows-1255", "x-cp1255",
            "cp1256", "windows-1256", "x-cp1256",
            "cp1257", "windows-1257", "x-cp1257",
            "cp1258", "windows-1258", "x-cp1258",
            // EUC-JP: every byte of a multibyte character is 0x8E, 0x8F or
            // 0xA1 and above.
            "cseucpkdfmtjapanese", "euc-jp", "x-euc-jp",
            // Aliases seen in feeds, outside the WHATWG list, each proven
            // like the rest.
            "utf_8", "iso8859_1", "latin-1", "euc_jp", "eucjp", "koi8r",
            // The parser reads cp949 as strict EUC-KR, like euc-kr below
            // (proven: 0x81 is a single byte).
            "cp949",
            // The system parser reads these as strict EUC-KR and EUC-CN,
            // whose characters use only bytes 0xA1 and above, and 0x81–0xA0
            // as single bytes (measured), unlike the web.
            "cseuckr", "euc-kr", "csgb2312", "gb2312", "gb_2312",
        ]
        let shiftJIS = ["csshiftjis", "ms932", "ms_kanji", "shift-jis", "shift_jis", "sjis", "windows-31j", "x-sjis", "cp932", "shiftjis"]
        let doubleByte = [
            // GBK and gb18030
            "chinese", "csiso58gb231280", "gb_2312-80", "gbk", "iso-ir-58", "x-gbk", "gb18030",
            // Big5
            "big5", "big5-hkscs", "cn-big5", "csbig5", "x-x-big5",
            // The web's EUC-KR labels, read as windows-949
            "csksc56011987", "iso-ir-149", "korean", "ks_c_5601-1987", "ks_c_5601-1989", "ksc5601",
            "ksc_5601", "windows-949",
            // Aliases seen in feeds, proven like the rest.
            "cp936", "cp950",
        ]
        for label in asciiCompatible { table[label] = .asciiCompatible }
        for label in shiftJIS { table[label] = .shiftJIS }
        for label in doubleByte { table[label] = .doubleByte }
        return table
    }()

    /// The longest label looked up, in UTF-8 bytes. The longest in `labels`
    /// is 19.
    static let maximumLabelBytes = 64

    /// The byte mode for a declared encoding label; `nil` for a label not in
    /// `labels`. A label longer than `maximumLabelBytes` is refused before it
    /// is lowercased or hashed: Swift does both in time growing with the
    /// square of a long run of combining marks (V1).
    static func mode(forLabel label: String) -> ByteMode? {
        guard label.utf8.count <= maximumLabelBytes else { return nil }
        return labels[label.lowercased()]
    }

    /// What the document's XML declaration says, read exactly as XML writes
    /// it: `<?xml`, white space, `version`, then optionally `encoding` and
    /// `standalone` in that order, each `name S? = S? quoted value` after
    /// white space, then `S? ?>`.
    enum Declaration: Equatable {
        /// The document does not start with `<?xml` and white space.
        case absent
        /// The declaration, with its encoding label if it names one.
        case read(encoding: String?)
        /// It starts like a declaration but is not one the scan can read.
        case unreadable
    }

    static func declaration(in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Declaration {
        let count = bytes.count
        func has(_ text: String, at index: Int) -> Bool {
            let pattern = Array(text.utf8)
            guard index + pattern.count <= count else { return false }
            return pattern.indices.allSatisfy { bytes[index + $0] == pattern[$0] }
        }
        func skipSpace(from index: Int) -> Int {
            var index = index
            while index < count, isSpace(bytes[index]) { index += 1 }
            return index
        }
        /// `name S? = S? quoted` at `index`; the value and the index after it.
        func pseudoAttribute(_ name: String, at index: Int) -> (value: String, end: Int)? {
            guard has(name, at: index) else { return nil }
            var position = skipSpace(from: index + name.utf8.count)
            guard position < count, bytes[position] == UInt8(ascii: "=") else { return nil }
            position = skipSpace(from: position + 1)
            guard position < count, bytes[position] == UInt8(ascii: "\"") || bytes[position] == UInt8(ascii: "'") else { return nil }
            let quote = bytes[position]
            var close = position + 1
            while close < count, bytes[close] != quote { close += 1 }
            guard close < count else { return nil }
            return (String(decoding: bytes[(position + 1)..<close], as: UTF8.self), close + 1)
        }

        guard has("<?xml", at: start), start + 5 < count, isSpace(bytes[start + 5]) else { return .absent }
        var index = skipSpace(from: start + 5)
        guard let version = pseudoAttribute("version", at: index) else { return .unreadable }
        index = version.end
        var encoding: String?
        var spaced = skipSpace(from: index)
        if spaced > index, let found = pseudoAttribute("encoding", at: spaced) {
            encoding = found.value
            index = found.end
            spaced = skipSpace(from: index)
        }
        if spaced > index, let found = pseudoAttribute("standalone", at: spaced) {
            index = found.end
            spaced = skipSpace(from: index)
        }
        guard has("?>", at: spaced) else { return .unreadable }
        return .read(encoding: encoding)
    }

    /// The byte mode the document is read in, and where scanning starts;
    /// `nil` when the scan cannot read the document's encoding reliably.
    static func byteMode(of bytes: UnsafeBufferPointer<UInt8>) -> (ByteMode, Int)? {
        let head = Array(bytes.prefix(4))
        if head.starts(with: [0xFE, 0xFF]) || head.starts(with: [0xFF, 0xFE]) || head.contains(0x00)
            || head == [0x4C, 0x6F, 0xA7, 0x94] {
            // UTF-16 or UTF-32 (a byte-order mark, or the zero bytes of
            // `<?` in two or four bytes), or EBCDIC's `<?xm`.
            return nil
        }
        // After a UTF-8 byte-order mark the parser still honours the
        // declaration's encoding (measured: Shift_JIS), so it is read too.
        let start = head.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        switch declaration(in: bytes, from: start) {
        case .absent, .read(encoding: nil):
            // No declared encoding: the parser reads UTF-8 and stops at the
            // first byte that is not.
            return (.asciiCompatible, start)
        case .read(encoding: let label?):
            return mode(forLabel: label).map { ($0, start) }
        case .unreadable:
            return nil
        }
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

        private enum DocumentType {
            case ended(at: Int)
            case notWellFormed
            /// It holds an attribute-list declaration.
            case refused
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
                        switch skipDocumentType(from: open + 9) {
                        case .ended(let end): index = end
                        case .notWellFormed: return nil
                        case .refused: return 0
                        }
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
        /// hold `]` and `>`. Ends after the closing `>`; refused at an
        /// attribute-list declaration.
        private func skipDocumentType(from start: Int) -> DocumentType {
            let count = bytes.count
            var index = start
            while index < count {
                let byte = bytes[index]
                if byte == Self.quote || byte == Self.apostrophe {
                    guard let close = find(byte, from: index + 1) else { return .notWellFormed }
                    index = close + 1
                } else if byte == Self.greaterThan {
                    return .ended(at: index + 1)
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
                    guard let close = find(byte, from: index + 1) else { return .notWellFormed }
                    index = close + 1
                case Self.lessThan where has("<!ATTLIST", at: index):
                    return .refused
                case Self.lessThan where has("<!--", at: index):
                    guard let end = find("-->", from: index + 4) else { return .notWellFormed }
                    index = end + 3
                case Self.lessThan where has("<?", at: index):
                    guard let end = find("?>", from: index + 2) else { return .notWellFormed }
                    index = end + 2
                case Self.closeBracket:
                    index = skipSpace(from: index + 1)
                    guard index < count, bytes[index] == Self.greaterThan else { return .notWellFormed }
                    return .ended(at: index + 1)
                default:
                    index = advance(index)
                }
            }
            return .notWellFormed
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
