import Foundation
@testable import NewsPawKit
import Testing

/// Counts what the system parser delivers.
final class StartTagCounter: NSObject, XMLParserDelegate {
    var maximumAttributes = 0
    var startTags = 0

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        startTags += 1
        maximumAttributes = max(maximumAttributes, attributeDict.count)
    }
}

/// What the system parser delivers from the part of `data` the scan lets
/// through, configured as the reader configures it.
func deliveredByParser(_ data: Data) -> (cut: Int?, maximumAttributes: Int, startTags: Int, wellFormed: Bool) {
    let cut = StartTagScan.cutOffset(in: data)
    let counter = StartTagCounter()
    let parser = XMLParser(data: cut.map { data.prefix($0) } ?? data)
    parser.shouldProcessNamespaces = true
    parser.shouldReportNamespacePrefixes = true
    parser.shouldResolveExternalEntities = false
    parser.delegate = counter
    let wellFormed = parser.parse()
    return (cut, counter.maximumAttributes, counter.startTags, wellFormed)
}

// Nested in the serialized group: see `TimedAndHeavySuites`.
extension TimedAndHeavySuites {
/// Fix round 2: an encoding label or a declaration the scan reads
/// differently from the parser must not hide a start tag (D2, D3).
@Suite("Start-tag scan: encoding bypasses")
struct ScanBypassTests {
    private static let overLimit = "<x" + (0..<300).map { #" a\#($0)="""# }.joined() + "/>"

    /// The reviewer's document: a two-byte character whose second byte is
    /// `]`, followed by `]>`, inside CDATA; read byte by byte the section
    /// ends there and the comment after it hides the tag.
    private static func hidingDocument(declaration: String, prefix: [UInt8] = [], tag: String = overLimit) -> Data {
        var bytes = prefix + Array(declaration.utf8)
        bytes += Array(#"<rss version="2.0"><channel><title>T</title><item><guid>1</guid><title>One</title><description><![CDATA["#.utf8)
        bytes += [0x83, 0x5D] + Array("]><!--]]></description></item>".utf8)
        bytes += Array(tag.utf8) + Array("<!-- --></channel></rss>".utf8)
        return Data(bytes)
    }

    @Test(
        "a label the parser reads as a double-byte set never hides an over-limit tag",
        arguments: ["pck", "ibm-942", "ibm942", "x-IBM942", "IBM-942_P12A-1999", "ibm-1386", "cp1386", "ibm-5471", "ibm-1373", "ibm-1375", "Shift_JIS"]
    )
    func unrecognisedLabel(_ label: String) {
        let delivered = deliveredByParser(Self.hidingDocument(declaration: #"<?xml version="1.0" encoding="\#(label)"?>"#))
        #expect(delivered.maximumAttributes <= 256, "\(label): \(delivered)")
    }

    @Test("a declaration padded past any window never hides an over-limit tag")
    func paddedDeclaration() {
        let declaration = #"<?xml version="1.0""# + String(repeating: " ", count: 2_000) + #"encoding="Shift_JIS"?>"#
        let delivered = deliveredByParser(Self.hidingDocument(declaration: declaration))
        #expect(delivered.maximumAttributes <= 256, "\(delivered)")
    }

    @Test("a UTF-8 byte-order mark followed by a Shift_JIS declaration never hides an over-limit tag")
    func byteOrderMarkThenDeclaration() {
        let delivered = deliveredByParser(Self.hidingDocument(declaration: #"<?xml version="1.0" encoding="Shift_JIS"?>"#, prefix: [0xEF, 0xBB, 0xBF]))
        #expect(delivered.maximumAttributes <= 256, "\(delivered)")
    }

    @Test("the pck document with 150,000 attributes is refused quickly through the package's parser")
    func pckThroughThePackage() {
        let tag = "<x" + (0..<150_000).map { #" a\#($0)="""# }.joined() + "/>"
        let data = Self.hidingDocument(declaration: #"<?xml version="1.0" encoding="pck"?>"#, tag: tag)
        let start = ContinuousClock.now
        let feed = FeedParser.parse(data, charset: nil, baseURL: fixtureBase)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(feed == nil || feed?.isComplete == false)
    }
}
}
