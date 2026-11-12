import Foundation
@testable import NewsPawKit
import Testing

// Nested in the serialized group: see `TimedAndHeavySuites`.
extension TimedAndHeavySuites {
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
// One label at a time: run in parallel, these synchronous parses fill every
// thread of the shared pool and stall the timed transport tests beside them.
@Suite("Encoding labels proven against the parser", .serialized)
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

    struct Case {
        var prefix: [UInt8]
        var x: UInt8
    }

    /// Records the text of each `p` element.
    final class SectionCollector: NSObject, XMLParserDelegate {
        var texts: [String] = []

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
        ) {
            if elementName == "p" {
                texts.append("")
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if !texts.isEmpty {
                texts[texts.count - 1] += string
            }
        }
    }

    /// Probes each case — its prefix, X and `Z` inside a CDATA section of its
    /// own `p` element — in documents that declare `label`. Cases go into one
    /// document together; a document the parser refuses is split in halves
    /// until each refused case stands alone, so every case gets the outcome
    /// it gets on its own. (Each case starts after ASCII `[`, a character
    /// boundary in all these encodings, so its neighbours cannot change it.)
    static func probe(_ label: String, cases: [Case]) -> [Probe] {
        var results = [Probe](repeating: .refused, count: cases.count)
        func run(_ range: Range<Int>) {
            guard !range.isEmpty else { return }
            var bytes = head(label) + Array("<r>".utf8)
            for index in range {
                bytes += Array("<p><![CDATA[".utf8) + cases[index].prefix + [cases[index].x] + Array("Z]]></p>".utf8)
            }
            bytes += Array("</r>".utf8)
            let collector = SectionCollector()
            let parser = XMLParser(data: Data(bytes))
            parser.shouldProcessNamespaces = true
            parser.shouldReportNamespacePrefixes = true
            parser.shouldResolveExternalEntities = false
            parser.delegate = collector
            if parser.parse(), collector.texts.count == range.count {
                for (offset, index) in range.enumerated() {
                    results[index] = classify(collector.texts[offset], x: cases[index].x)
                }
            } else if range.count > 1 {
                let middle = range.lowerBound + range.count / 2
                run(range.lowerBound..<middle)
                run(middle..<range.upperBound)
            }
        }
        run(0..<cases.count)
        return results
    }

    static func classify(_ text: String, x: UInt8) -> Probe {
        guard !text.isEmpty else { return .textDropped }
        let scalars = Array(text.unicodeScalars)
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
        var cases: [Case] = []
        for lead in UInt8(0x80)...UInt8(0xFF) {
            for prefix in [[lead], [lead, 0xA1]] {
                for x in Self.neverSecondBytes + Self.steppedBytes {
                    cases.append(Case(prefix: prefix, x: x))
                }
            }
        }
        var failures: [String] = []
        for (testCase, outcome) in zip(cases, Self.probe(label, cases: cases)) {
            let prefix = testCase.prefix
            let x = testCase.x
            let consumed: Bool
            switch outcome {
            case .refused:
                continue
            case .decoded(let xConsumed):
                consumed = xConsumed
            case .textDropped:
                // Only in an ASCII-compatible mode can one ASCII byte stand
                // for all: a decoder that leaves `]` alone after the prefix
                // treats every ASCII byte alike.
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
        print("label proof | \(label) | \(mode) | \(failures.isEmpty ? "proven" : "FAILED \(failures.count): \(failures.prefix(8))")")
        #expect(failures.isEmpty, "\(label) (\(mode)): \(failures.prefix(16))")
    }
}
}
