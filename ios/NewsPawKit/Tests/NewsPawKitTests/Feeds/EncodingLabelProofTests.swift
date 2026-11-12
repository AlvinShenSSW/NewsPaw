import Foundation
@testable import NewsPawKit
import Testing

/// Proves each label the start-tag scan accepts against the system parser
/// (fix round 2, D2): the parser either refuses the label, or it groups
/// bytes into characters the way the label's byte mode assumes.
///
/// For every byte 0x80–0xFF, alone or followed by 0xA1, and then a probe
/// byte X, the test asks the parser whether X ended up inside a multibyte
/// character, and compares that with the scan's own walk (`advance`):
/// - X that the scan finds with memchr or only at a character's start — `<`,
///   `>`, quotes, `-`, `?`, `=`, `/`, `!` and white space — must never be
///   consumed;
/// - X that the scan steps over character by character — `[` and `]` — must
///   be consumed exactly when the scan's walk makes it a second byte.
/// A sequence the parser refuses to decode ends its reading there, so it
/// cannot hide anything and passes.
@Suite("Encoding labels proven against the parser")
struct EncodingLabelProofTests {
    enum Probe {
        case refused
        case decoded(xConsumed: Bool)
        /// The parser read the bytes but delivered no text for them (it
        /// accepts an overlong UTF-8 sequence, then cannot turn the section
        /// into a string).
        case textDropped
    }

    final class TextCollector: NSObject, XMLParserDelegate {
        var text = ""

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }
    }

    static let neverSecondBytes: [UInt8] = Array("<>\"'-?=/! \t\n\r".utf8)
    static let steppedBytes: [UInt8] = Array("[]".utf8)

    /// Parses `prefix`, X, `Z` inside a CDATA section of a document that
    /// declares `label`.
    static func probe(_ label: String, prefix: [UInt8], x: UInt8) -> Probe {
        var bytes = head(label) + Array("<r><![CDATA[".utf8)
        bytes += prefix + [x] + Array("Z]]></r>".utf8)
        let collector = TextCollector()
        let parser = XMLParser(data: Data(bytes))
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = collector
        guard parser.parse() else { return .refused }
        guard !collector.text.isEmpty else { return .textDropped }
        let scalars = Array(collector.text.unicodeScalars)
        // A carriage return may arrive as itself or as a line feed.
        let accepted: [Unicode.Scalar] = x == 0x0D ? ["\r", "\n"] : [Unicode.Scalar(x)]
        let separate = scalars.count >= 2 && scalars.last == "Z" && accepted.contains(scalars[scalars.count - 2])
        return .decoded(xConsumed: !separate)
    }

    /// Whether the scan's walk from the start of `prefix` makes the byte
    /// after it a second byte.
    static func scanConsumes(after prefix: [UInt8], mode: StartTagScan.ByteMode) -> Bool {
        var index = 0
        while index < prefix.count {
            index += width(of: prefix[index], mode: mode)
        }
        return index > prefix.count
    }

    /// The scan's character widths (`StartTagScan.Scanner.advance`).
    static func width(of byte: UInt8, mode: StartTagScan.ByteMode) -> Int {
        switch mode {
        case .asciiCompatible: 1
        case .shiftJIS: (0x81...0x9F).contains(byte) || (0xE0...0xFC).contains(byte) ? 2 : 1
        case .doubleByte: (0x81...0xFE).contains(byte) ? 2 : 1
        }
    }

    final class ElementCollector: NSObject, XMLParserDelegate {
        var names: [String] = []

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
        ) {
            names.append(elementName)
        }
    }

    /// Whether the byte after `prefix`, inside a CDATA section, starts a
    /// character for the parser: `prefix` then `]]><b/>` must end the
    /// section and deliver the element `b`. (Only CDATA accepts the
    /// overlong sequences whose text is dropped; text, attribute values and
    /// comments refuse them.)
    static func characterStarts(after prefix: [UInt8], label: String) -> Bool {
        var bytes = head(label) + Array("<r><![CDATA[".utf8)
        bytes += prefix + Array("]]><b/></r>".utf8)
        let collector = ElementCollector()
        let parser = XMLParser(data: Data(bytes))
        parser.delegate = collector
        _ = parser.parse()
        return collector.names.contains("b")
    }

    static func acceptsLabel(_ label: String) -> Bool {
        let parser = XMLParser(data: Data(head(label) + Array("<r>A</r>".utf8)))
        return parser.parse()
    }

    /// The pseudo-labels for the two ways a document declares no encoding,
    /// which the scan reads as UTF-8.
    static let noDeclaration = "(no declaration)"
    static let byteOrderMark = "(byte-order mark, no declaration)"

    static func head(_ label: String) -> [UInt8] {
        switch label {
        case noDeclaration: []
        case byteOrderMark: [0xEF, 0xBB, 0xBF]
        default: Array(#"<?xml version="1.0" encoding="\#(label)"?>"#.utf8)
        }
    }

    @Test(
        "every accepted label, and no declaration at all, is refused by the parser or read as its byte mode assumes",
        arguments: StartTagScan.labels.keys.sorted() + [noDeclaration, byteOrderMark]
    )
    func label(_ label: String) {
        let mode = StartTagScan.labels[label] ?? .asciiCompatible
        guard Self.acceptsLabel(label) else {
            print("label proof | \(label) | \(mode) | refused by the parser")
            return
        }
        var failures: [String] = []
        for lead in UInt8(0x80)...UInt8(0xFF) {
            for prefix in [[lead], [lead, 0xA1]] {
                for x in Self.neverSecondBytes + Self.steppedBytes {
                    let consumed: Bool
                    switch Self.probe(label, prefix: prefix, x: x) {
                    case .refused:
                        continue
                    case .decoded(let xConsumed):
                        consumed = xConsumed
                    case .textDropped:
                        // Only in an ASCII-compatible mode can one ASCII byte
                        // stand for all: a decoder that leaves `<` alone
                        // after the prefix treats every ASCII byte alike.
                        guard mode == .asciiCompatible else {
                            failures.append(prefix.map { String(format: "%02X", $0) }.joined() + " text dropped")
                            continue
                        }
                        consumed = !Self.characterStarts(after: prefix, label: label)
                    }
                    let allowed = Self.steppedBytes.contains(x) ? Self.scanConsumes(after: prefix, mode: mode) : false
                    if consumed != allowed {
                        failures.append(prefix.map { String(format: "%02X", $0) }.joined() + "+" + String(format: "%02X", x) + (consumed ? " consumed" : " separate"))
                    }
                }
            }
        }
        print("label proof | \(label) | \(mode) | \(failures.isEmpty ? "proven" : "FAILED \(failures.count): \(failures.prefix(8))")")
        #expect(failures.isEmpty, "\(label) (\(mode)): \(failures.prefix(16))")
    }
}
