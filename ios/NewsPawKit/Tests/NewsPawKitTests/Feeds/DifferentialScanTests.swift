import Foundation
@testable import NewsPawKit
import Testing

/// Tests the start-tag scan's soundness claim against the real parser rather
/// than against hand-picked cases (fix round 2): no start tag the parser
/// delivers has more than 256 attributes unless the scan cut before it; a
/// document that is well-formed with every tag within the limit is never
/// cut; and when the generator placed a real over-limit tag in an otherwise
/// well-formed document, the cut is exactly at the first one.
///
/// A seeded generator composes documents from what the scan models:
/// comments, CDATA sections, processing instructions, a document type with
/// an internal subset (entity declarations with tricky literals, comments,
/// processing instructions, names whose second byte is `[` or `]`), quoted
/// values holding `>`, `]`, `]]>`, `-->` and the other quote, text with
/// markup escaped, multibyte characters of the declared encoding — those
/// whose second byte is `]` or `[` placed before `]>` and `]]>` — over-limit
/// tags written inside CDATA, comments, processing instructions and entity
/// literals (where they are not tags), real over-limit tags, and now and
/// then a construct that is not well-formed.
@Suite("Start-tag scan against the parser")
struct DifferentialScanTests {
    struct Encoding: Sendable, CustomStringConvertible {
        var label: String
        var mode: StartTagScan.ByteMode
        /// Characters valid in this encoding.
        var characters: [[UInt8]]
        /// Characters whose last byte is `]` or `[`.
        var bracketCharacters: [[UInt8]]
        /// A character that may start a name.
        var nameCharacter: [UInt8]

        var description: String { label }
    }

    static let encodings: [Encoding] = [
        Encoding(label: "UTF-8", mode: .asciiCompatible, characters: [[0xE3, 0x82, 0xBE], [0xC3, 0xA9], [0xF0, 0x9F, 0x98, 0x80]], bracketCharacters: [], nameCharacter: [0xE3, 0x82, 0xBE]),
        Encoding(label: "windows-1252", mode: .asciiCompatible, characters: [[0xE9], [0x80], [0xFF]], bracketCharacters: [], nameCharacter: [0xE9]),
        Encoding(label: "EUC-JP", mode: .asciiCompatible, characters: [[0xA5, 0xBE], [0x8E, 0xB1], [0xB0, 0xA1]], bracketCharacters: [], nameCharacter: [0xA5, 0xBE]),
        Encoding(label: "Shift_JIS", mode: .shiftJIS, characters: [[0x82, 0xA0], [0xB1], [0x95, 0x5C], [0x83, 0x5D]], bracketCharacters: [[0x83, 0x5D], [0x83, 0x5B]], nameCharacter: [0x83, 0x5B]),
        Encoding(label: "GBK", mode: .doubleByte, characters: [[0xB0, 0xA1], [0x81, 0x40]], bracketCharacters: [[0x81, 0x5D], [0x81, 0x5B]], nameCharacter: [0x81, 0x5B]),
        Encoding(label: "gb18030", mode: .doubleByte, characters: [[0xB0, 0xA1], [0x81, 0x30, 0x81, 0x30]], bracketCharacters: [[0x81, 0x5D], [0x81, 0x5B]], nameCharacter: [0x81, 0x5B]),
        Encoding(label: "Big5", mode: .doubleByte, characters: [[0xA4, 0x40], [0xA4, 0xA1]], bracketCharacters: [[0xA4, 0x5D], [0xA4, 0x5B]], nameCharacter: [0xA4, 0x40]),
        Encoding(label: "windows-949", mode: .doubleByte, characters: [[0xB0, 0xA1], [0x81, 0x41]], bracketCharacters: [], nameCharacter: [0xB0, 0xA1]),
    ]

    static let documentsPerEncoding = 1_000

    @Test("the scan never lets an over-limit tag through, and cuts nothing else", arguments: encodings)
    func differential(_ encoding: Encoding) throws {
        #expect(StartTagScan.mode(forLabel: encoding.label) == encoding.mode)
        var generator = SeededGenerator(seed: 0xD1FF_0000 + UInt64(encoding.label.utf8.reduce(0) { $0 &* 31 &+ Int($1) } & 0xFFFF))
        var counts = (documents: 0, cut: 0, wellFormedWithinLimit: 0, malformed: 0, refusedByParser: 0)
        let start = ContinuousClock.now
        for index in 0..<Self.documentsPerEncoding {
            var builder = DocumentBuilder(encoding: encoding, generator: generator)
            let document = builder.build()
            generator = builder.generator
            let data = Data(document.bytes)
            let delivered = deliveredByParser(data)
            counts.documents += 1
            if delivered.cut != nil { counts.cut += 1 }
            if !document.wellFormed { counts.malformed += 1 }

            #expect(
                delivered.maximumAttributes <= StartTagScan.maximumAttributes,
                "\(encoding.label) document \(index): an over-limit tag got through\n\(document.preview)"
            )
            if document.wellFormed {
                let fullParse = deliveredWithoutScan(data)
                #expect(fullParse.wellFormed, "\(encoding.label) document \(index): generator bug, the parser refuses it\n\(document.preview)")
                if !fullParse.wellFormed { counts.refusedByParser += 1 }
                if document.overLimitOffsets.isEmpty {
                    counts.wellFormedWithinLimit += 1
                    #expect(delivered.cut == nil, "\(encoding.label) document \(index): cut a document within the limit\n\(document.preview)")
                } else {
                    #expect(delivered.cut == document.overLimitOffsets.first, "\(encoding.label) document \(index): cut \(String(describing: delivered.cut)), first tag at \(document.overLimitOffsets[0])\n\(document.preview)")
                }
            }
        }
        print("differential | \(encoding.label) | \(encoding.mode) | documents \(counts.documents) | cut \(counts.cut) | well-formed within the limit \(counts.wellFormedWithinLimit) | not well-formed \(counts.malformed) | \(ContinuousClock.now - start)")
    }

    /// What the parser delivers from the whole document, without the scan.
    func deliveredWithoutScan(_ data: Data) -> (maximumAttributes: Int, wellFormed: Bool) {
        let counter = StartTagCounter()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = counter
        let wellFormed = parser.parse()
        return (counter.maximumAttributes, wellFormed)
    }
}

/// Builds one document.
struct DocumentBuilder {
    struct Document {
        var bytes: [UInt8]
        /// Offsets of the `<` of each real over-limit start tag.
        var overLimitOffsets: [Int]
        /// False when the builder wrote something that is not well-formed.
        var wellFormed: Bool

        var preview: String {
            String(decoding: bytes.prefix(600).map { $0 < 0x80 ? $0 : UInt8(ascii: "#") }, as: UTF8.self)
        }
    }

    let encoding: DifferentialScanTests.Encoding
    var generator: SeededGenerator
    private var bytes: [UInt8] = []
    private var overLimitOffsets: [Int] = []
    private var wellFormed = true

    init(encoding: DifferentialScanTests.Encoding, generator: SeededGenerator) {
        self.encoding = encoding
        self.generator = generator
    }

    static let overLimitTag = "<x" + (0...StartTagScan.maximumAttributes).map { #" a\#($0)="""# }.joined() + "/>"

    private mutating func chance(_ percent: Int) -> Bool {
        Int.random(in: 0..<100, using: &generator) < percent
    }

    private mutating func pick<T>(_ items: [T]) -> T {
        items[Int.random(in: 0..<items.count, using: &generator)]
    }

    private mutating func append(_ text: String) {
        bytes += Array(text.utf8)
    }

    private mutating func character() -> [UInt8] {
        if !encoding.bracketCharacters.isEmpty, chance(50) {
            return pick(encoding.bracketCharacters)
        }
        return pick(encoding.characters)
    }

    /// A token: its bytes, and how it reads as characters with each
    /// multibyte character written `M`.
    struct Token {
        var bytes: [UInt8]
        var reading: String
    }

    /// Appends tokens, skipping any that would make one of `forbidden`
    /// appear in the run's reading as characters, so the run stays
    /// well-formed in the parser's eyes.
    private mutating func appendRun(_ tokens: [Token], forbidden: [String]) {
        var reading = ""
        for token in tokens {
            let candidate = reading + token.reading
            if forbidden.contains(where: { candidate.contains($0) }) {
                continue
            }
            reading = candidate
            bytes += token.bytes
        }
    }

    private mutating func tokens(_ choices: [String], count: Int) -> [Token] {
        (0..<count).map { _ in
            if chance(30) {
                let character = character()
                var suffix = ""
                // The critical shape: a character whose second byte is `]`
                // followed by `]>` or `]]>`, where reading byte by byte
                // finds an end that is not there.
                if encoding.bracketCharacters.contains(character), chance(60) {
                    suffix = pick(["]>", "]]>", "]", "]]", "]]]>"])
                }
                return Token(bytes: character + Array(suffix.utf8), reading: "M" + suffix)
            }
            let text = pick(choices)
            return Token(bytes: Array(text.utf8), reading: text)
        }
    }

    mutating func build() -> Document {
        append(#"<?xml version="1.0" encoding="\#(encoding.label)"?>"#)
        if chance(50) {
            documentType()
        }
        for _ in 0..<Int.random(in: 0...2, using: &generator) {
            chance(50) ? comment() : processingInstruction()
        }
        append("<root>")
        content(depth: 0)
        append("</root>")
        return Document(bytes: bytes, overLimitOffsets: overLimitOffsets, wellFormed: wellFormed)
    }

    private mutating func documentType() {
        append("<!DOCTYPE ")
        if chance(50) {
            bytes += encoding.nameCharacter
        }
        append("root")
        if chance(30) {
            append(pick([#" SYSTEM "x]>.dtd""#, #" PUBLIC "-//X//EN" 'y[]>'"#]))
        }
        append(" [")
        for index in 0..<Int.random(in: 0...4, using: &generator) {
            switch Int.random(in: 0..<5, using: &generator) {
            case 0:
                append(" <!ENTITY e\(index) \"")
                appendRun(tokens(["]>", "]", "'", ">", "<!--", "-->", "?>", " ", "<x a='1'>"], count: 6), forbidden: ["\"", "&", "%"])
                append("\">")
            case 1:
                append(" <!ENTITY f\(index) '")
                appendRun(tokens(["]>", "\"", ">", "<x a=\"]>\">", " ", Self.overLimitTag], count: 5), forbidden: ["'", "&", "%"])
                append("'>")
            case 2:
                append(" <!-- ")
                appendRun(tokens(["]>", "]", ">", "'", "\"", " ", Self.overLimitTag], count: 5), forbidden: ["--"])
                append(" -->")
            case 3:
                // A quote inside a processing instruction of the internal
                // subset makes the system parser refuse the document unless
                // another quote follows (its look-ahead for the subset's end
                // counts quotes there); such a document is not counted as
                // one the parser reads.
                append(" <?p ")
                let start = bytes.count
                appendRun(tokens(["]>", "]", ">", "'", "\"", " ", Self.overLimitTag], count: 5), forbidden: ["?>"])
                if bytes[start...].contains(UInt8(ascii: "'")) || bytes[start...].contains(UInt8(ascii: "\"")) {
                    wellFormed = false
                }
                append("?>")
            default:
                if encoding.bracketCharacters.isEmpty {
                    append(" <!ELEMENT root ANY>")
                } else {
                    // A name whose second byte is `]` or `[`.
                    append(" <!ENTITY ")
                    bytes += pick(encoding.bracketCharacters)
                    append("\(index) \"v\">")
                }
            }
        }
        append(" ]>")
    }

    private mutating func comment() {
        append("<!--")
        appendRun(tokens(["x", " ", "]]>", "]>", ">", "<!", "<x>", "- ", Self.overLimitTag, "'", "\""], count: 6), forbidden: ["--"])
        append(" -->")
    }

    private mutating func processingInstruction() {
        append("<?pi ")
        appendRun(tokens(["x", " ", ">", "]]>", "<!--", "-->", "? ", Self.overLimitTag], count: 6), forbidden: ["?>"])
        append("?>")
    }

    private mutating func cdata() {
        append("<![CDATA[")
        appendRun(tokens(["x", "]", "]>", "<!--", "-->", "<?", "<!", " ", Self.overLimitTag, "&", "<"], count: 7), forbidden: ["]]>"])
        append("]]>")
    }

    private mutating func text() {
        // A letter first, so that adjacent runs cannot join into `]]>`.
        append("t")
        appendRun(tokens(["a", " ", "&lt;x a0=\"\" a1=\"\"&gt;", "&lt;", "&gt;", "&amp;", ">", "]", "&#93;", "\n"], count: 5), forbidden: ["]]>"])
    }

    private mutating func element(depth: Int) {
        append("<e")
        for index in 0..<Int.random(in: 0...4, using: &generator) {
            let quote = chance(50) ? "\"" : "'"
            let other = quote == "\"" ? "'" : "\""
            append(" b\(index)=\(quote)")
            appendRun(tokens(["v", ">", "]", "]]>", "-->", other, " ", "&lt;", "&amp;"], count: 4), forbidden: [quote, "<"])
            append(quote)
        }
        if chance(40) {
            append("/>")
        } else {
            append(">")
            content(depth: depth + 1)
            append("</e>")
        }
    }

    private mutating func notWellFormed() {
        wellFormed = false
        switch Int.random(in: 0..<6, using: &generator) {
        case 0: append("< y")
        case 1: append("a & b")
        case 2: append("]]>")
        case 3: append("<!-- never closed")
        case 4: append("<e b=unquoted>")
        default: append(#"<e b="<!--">"#)
        }
    }

    private mutating func content(depth: Int) {
        for _ in 0..<Int.random(in: 1...8, using: &generator) {
            switch Int.random(in: 0..<100, using: &generator) {
            case 0..<20: text()
            case 20..<35: cdata()
            case 35..<47: comment()
            case 47..<55: processingInstruction()
            case 55..<85: depth < 3 ? element(depth: depth) : text()
            case 85..<97:
                overLimitOffsets.append(bytes.count)
                append(Self.overLimitTag)
            default:
                notWellFormed()
            }
        }
    }
}
