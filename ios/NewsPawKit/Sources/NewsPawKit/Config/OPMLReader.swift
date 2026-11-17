import Foundation

/// A feed an OPML file lists, as the file states it: nothing is checked or
/// fetched (RD08 decision 1).
public struct OPMLFeed: Sendable, Hashable {
    /// The `xmlUrl` text, trimmed of surrounding white space. When the value
    /// is longer than `OPMLReader.maximumAddressBytes`, its first bytes up
    /// to that limit, and `addressIsTooLong` is set.
    public let address: String
    /// The cleaned `title`, else `text`; empty when the file gives none.
    public let name: String
    /// The `htmlUrl` text, trimmed; `nil` when absent, empty or longer than
    /// `OPMLReader.maximumAddressBytes`.
    public let siteAddress: String?
    /// Whether the `xmlUrl` value was longer than the byte limit: the entry
    /// is skipped as an invalid address.
    public let addressIsTooLong: Bool

    public init(address: String, name: String, siteAddress: String?, addressIsTooLong: Bool = false) {
        self.address = address
        self.name = name
        self.siteAddress = siteAddress
        self.addressIsTooLong = addressIsTooLong
    }
}

/// A top-level entry of an OPML file's body.
public enum OPMLEntry: Sendable, Hashable {
    /// A feed outside any folder.
    case feed(OPMLFeed)
    /// A top-level folder with every feed under it at any depth, in file
    /// order; empty for a folder written as an empty element.
    case folder(name: String, feeds: [OPMLFeed])
}

/// What an OPML file lists: its top-level entries in file order.
public struct OPMLDocument: Sendable, Hashable {
    public let entries: [OPMLEntry]

    public init(entries: [OPMLEntry]) {
        self.entries = entries
    }

    /// Every feed of the file, inside folders or not.
    public var feedCount: Int {
        entries.reduce(0) { count, entry in
            switch entry {
            case .feed: count + 1
            case .folder(_, let feeds): count + feeds.count
            }
        }
    }
}

/// Why an OPML file is refused (RD08 criterion 2). A refusal never carries
/// part of a document.
public enum OPMLRefusal: Error, Sendable, Hashable {
    /// Larger than `OPMLReader.maximumBytes`.
    case tooLarge
    /// The file could not be read, or its bytes cannot be scanned reliably:
    /// an encoding the start-tag scan does not accept, an attribute-list
    /// declaration, or a start tag with too many attributes.
    case unreadable
    /// The file has a document type.
    case hasDocumentType
    /// The XML is not well-formed; the parser's line.
    case notWellFormed(line: Int)
    /// The root is not `opml`, or it has no `body`.
    case notOPML
    /// More than `OPMLReader.maximumFeeds` feeds.
    case tooManyFeeds
    /// More than `OPMLReader.maximumFolders` top-level outlines without an
    /// address.
    case tooManyFolders
    /// Neither a feed nor a folder.
    case empty
}

/// Reads an OPML file chosen by the owner (spec N03, N10; RD08 decisions 1
/// to 3). The file is untrusted (N12): it is read only up to its size
/// limit, refused when it has any document type — found in its bytes before
/// the parser runs, so that no external identifier is ever looked at — and
/// parsed with external entities off. Names and addresses are bounded in
/// bytes before any operation on characters, comparison or hash. Nothing
/// the file says is followed; addresses are not checked here.
///
/// Known limit: these guards do not claim to bound the system parser on
/// every input of 5 MB (spec section 10 accepts the same for feeds).
public enum OPMLReader {
    /// The largest file read: 5 MB, in the unit of the feed limit.
    public static let maximumBytes = 5 * 1024 * 1024
    /// The most feeds a file may list.
    public static let maximumFeeds = 2_000
    /// The most top-level outlines without an address a file may hold.
    public static let maximumFolders = 500
    /// The longest `title` or `text` value used, in UTF-8 bytes; a longer
    /// one is cut at a scalar boundary before anything else is done to it.
    public static let maximumValueBytes = 1_024
    /// The longest `xmlUrl` or `htmlUrl` value accepted, in UTF-8 bytes.
    public static let maximumAddressBytes = 8_192
    /// The longest element or attribute name compared, in UTF-8 bytes. The
    /// names looked for are at most 7 bytes long.
    static let maximumComparedNameBytes = 16

    /// Reads the file at `url`: its size from the file's resource values,
    /// refused above the limit without reading; then at most the limit
    /// plus one byte, refused when that byte is there.
    public static func read(contentsOf url: URL) -> Result<OPMLDocument, OPMLRefusal> {
        switch BoundedFileRead.read(contentsOf: url, maximumBytes: maximumBytes) {
        case .success(let data): read(data)
        case .failure(.tooLarge): .failure(.tooLarge)
        case .failure(.unreadable): .failure(.unreadable)
        }
    }

    /// Reads from `handle` until its end or until one byte past the limit
    /// (`BoundedFileRead`, shared with the configuration reader).
    static func boundedRead(_ handle: FileHandle) throws -> Data {
        try BoundedFileRead.read(handle, maximumBytes: maximumBytes)
    }

    /// Reads `data`, with the guards of decision 2 in their order.
    public static func read(_ data: Data) -> Result<OPMLDocument, OPMLRefusal> {
        guard data.count <= maximumBytes else { return .failure(.tooLarge) }
        // An attribute-list declaration, too many attributes on one tag, or
        // bytes the scan cannot read reliably.
        if StartTagScan.cutOffset(in: data) != nil {
            return .failure(.unreadable)
        }
        if prologHasDocumentType(data) {
            return .failure(.hasDocumentType)
        }
        return parse(data)
    }

    /// The system parser with the reader's settings: external entities not
    /// resolved, namespaces not processed.
    static func makeParser(_ data: Data) -> XMLParser {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        return parser
    }

    /// Step 4 alone: the parse, with the declaration callbacks as a second
    /// guard against a document type.
    static func parse(_ data: Data) -> Result<OPMLDocument, OPMLRefusal> {
        let parser = makeParser(data)
        let reader = Delegate()
        parser.delegate = reader
        let finished = parser.parse()
        if let refusal = reader.refusal {
            return .failure(refusal)
        }
        guard finished else {
            return .failure(.notWellFormed(line: parser.lineNumber))
        }
        guard reader.rootIsOPML, reader.bodyFound else {
            return .failure(.notOPML)
        }
        guard !reader.entries.isEmpty else {
            return .failure(.empty)
        }
        return .success(OPMLDocument(entries: reader.entries))
    }

    // MARK: - The prolog walk (decision 2, step 3)

    /// Whether `<!DOCTYPE` comes before the first start tag. It skips a
    /// byte-order mark, white space, comments and processing instructions
    /// (the XML declaration among them), and stops at anything else. Run
    /// after `StartTagScan` accepted the bytes, so `<`, `!`, `?`, `-` and
    /// `>` are never the second byte of a character here.
    static func prologHasDocumentType(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            func matches(_ text: StaticString, at offset: Int, foldingCase: Bool = false) -> Bool {
                let length = text.utf8CodeUnitCount
                guard offset + length <= count else { return false }
                for index in 0..<length {
                    var byte = bytes[offset + index]
                    if foldingCase, byte >= 0x61, byte <= 0x7A {
                        byte -= 0x20
                    }
                    if byte != text.utf8Start[index] {
                        return false
                    }
                }
                return true
            }
            func find(_ text: StaticString, from offset: Int) -> Int? {
                var index = offset
                while index < count {
                    if matches(text, at: index) {
                        return index
                    }
                    index += 1
                }
                return nil
            }
            var index = 0
            if matches("\u{FEFF}", at: 0) {
                index = 3
            }
            while index < count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D:
                    index += 1
                case UInt8(ascii: "<"):
                    if matches("<?", at: index) {
                        guard let end = find("?>", from: index + 2) else { return false }
                        index = end + 2
                    } else if matches("<!--", at: index) {
                        guard let end = find("-->", from: index + 4) else { return false }
                        index = end + 3
                    } else {
                        return matches("<!DOCTYPE", at: index, foldingCase: true)
                    }
                default:
                    return false
                }
            }
            return false
        }
    }

    // MARK: - Values (decision 2, step 5)

    /// `text`'s first bytes, at most `maximumBytes`, cut at a scalar
    /// boundary.
    static func prefix(ofUTF8 text: String, maximumBytes: Int) -> String {
        let utf8 = text.utf8
        guard utf8.count > maximumBytes else { return text }
        var end = utf8.index(utf8.startIndex, offsetBy: maximumBytes)
        // Back to the first byte of the character the limit falls in.
        while end > utf8.startIndex, utf8[end] & 0xC0 == 0x80 {
            end = utf8.index(before: end)
        }
        return String(decoding: utf8[..<end], as: UTF8.self)
    }

    /// A name: cut in bytes first, then control characters removed, runs of
    /// white space made one space, trimmed, and cut to `maximumCharacters`.
    static func cleanName(_ value: String?, maximumCharacters: Int) -> String {
        guard let value else { return "" }
        let bounded = prefix(ofUTF8: value, maximumBytes: maximumValueBytes)
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in bounded.unicodeScalars {
            if scalar.properties.isWhitespace {
                pendingSpace = !scalars.isEmpty
            } else if scalar.properties.generalCategory == .control {
                continue
            } else {
                if pendingSpace {
                    scalars.append(" ")
                    pendingSpace = false
                }
                scalars.append(scalar)
            }
        }
        return String(String(scalars).prefix(maximumCharacters))
    }

    /// An address value: `nil` when absent or empty once trimmed; else the
    /// trimmed text and whether it was over the byte limit (then its first
    /// bytes, untrimmed).
    static func address(_ value: String?) -> (text: String, tooLong: Bool)? {
        guard let value else { return nil }
        if value.utf8.count > maximumAddressBytes {
            return (prefix(ofUTF8: value, maximumBytes: maximumAddressBytes), true)
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : (trimmed, false)
    }

    /// Whether `name` is `lowercase` with ASCII letters folded, compared as
    /// bytes and only when it is short.
    static func nameMatches(_ name: String, _ lowercase: StaticString) -> Bool {
        let utf8 = name.utf8
        guard utf8.count <= maximumComparedNameBytes, utf8.count == lowercase.utf8CodeUnitCount else { return false }
        var index = 0
        for var byte in utf8 {
            if byte >= 0x41, byte <= 0x5A {
                byte += 0x20
            }
            if byte != lowercase.utf8Start[index] {
                return false
            }
            index += 1
        }
        return true
    }

    // MARK: - The parse (decision 2, step 4)

    /// The attributes of an outline the reader uses.
    struct OutlineAttributes {
        var xmlURL: String?
        var htmlURL: String?
        var title: String?
        var text: String?

        /// The value of each wanted attribute, from the parser's dictionary
        /// as it is: a key is made a Swift `String` only when it is at most
        /// `maximumComparedNameBytes` UTF-16 units long, so no long name is
        /// ever converted or hashed. When a name is present in more than one
        /// spelling, the conventional one wins, else the smallest in byte
        /// order, so the result does not depend on the dictionary's order.
        init(_ attributes: NSDictionary) {
            var chosen: [Int: (key: String, value: String)] = [:]
            let names: [(StaticString, String)] = [("xmlurl", "xmlUrl"), ("htmlurl", "htmlUrl"), ("title", "title"), ("text", "text")]
            for (rawKey, rawValue) in attributes {
                guard let nsKey = rawKey as? NSString, nsKey.length <= OPMLReader.maximumComparedNameBytes,
                      let value = rawValue as? String
                else { continue }
                let key = nsKey as String
                for (slot, (lowercase, conventional)) in names.enumerated() where Self.prefers(key, over: chosen[slot]?.key, lowercase, conventional) {
                    chosen[slot] = (key, value)
                }
            }
            xmlURL = chosen[0]?.value
            htmlURL = chosen[1]?.value
            title = chosen[2]?.value
            text = chosen[3]?.value
        }

        private static func prefers(_ key: String, over current: String?, _ lowercase: StaticString, _ conventional: String) -> Bool {
            guard nameMatches(key, lowercase) else { return false }
            guard let current else { return true }
            if current == conventional { return false }
            if key == conventional { return true }
            return key.utf8.lexicographicallyPrecedes(current.utf8)
        }
    }

    /// The top-level outline without an address being read.
    private struct TopOutline {
        let depth: Int
        /// Empty for an outline that is no folder: its feeds are outside.
        let name: String
        var feeds: [OPMLFeed] = []
        var hasChildElement = false
    }

    /// The conformance to `XMLParserDelegate`, and nothing else. The reader
    /// inherits it, so that it can implement the start-element callback
    /// with an `NSDictionary` (see `Delegate.startElement`); declared on the
    /// reader itself, that method would be a compiler warning or error.
    private class DelegateBase: NSObject, XMLParserDelegate {}

    /// The reader's callbacks, each exposed to Objective-C by its selector:
    /// the parser asks whether its delegate responds to each one.
    private final class Delegate: DelegateBase {
        var entries: [OPMLEntry] = []
        var refusal: OPMLRefusal?
        var rootIsOPML = false
        var bodyFound = false

        private var depth = 0
        /// The depth of the body being read, while inside it.
        private var bodyDepth: Int?
        /// Elements deeper than this are ignored.
        private var ignoredBelow: Int?
        private var top: TopOutline?
        private var feeds = 0
        private var folders = 0

        private func refuse(_ reason: OPMLRefusal, _ parser: XMLParser) {
            guard refusal == nil else { return }
            refusal = reason
            parser.abortParsing()
        }

        /// The start-element callback, under its Objective-C selector and
        /// with the attributes as the parser's `NSDictionary`. Declared with
        /// `[String: String]`, as the protocol spells it, the bridge would
        /// convert every attribute name to a Swift `String` and hash it at
        /// every start tag, before any bound here (RD08 review R1: 100 names
        /// of 49 kB of combining marks took 14.5 s; 0.06 s this way). The
        /// class inherits its conformance from `DelegateBase`, so the
        /// compiler does not take this method for a mistyped protocol
        /// requirement; the parser finds it by its selector.
        @objc(parser:didStartElement:namespaceURI:qualifiedName:attributes:)
        func startElement(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                          qualifiedName qName: String?, attributes attributeDict: NSDictionary) {
            guard refusal == nil else { return }
            depth += 1
            if depth == 1 {
                rootIsOPML = OPMLReader.nameMatches(elementName, "opml")
                if !rootIsOPML {
                    refuse(.notOPML, parser)
                }
                return
            }
            if let ignoredBelow, depth > ignoredBelow {
                return
            }
            if depth == 2 {
                if !bodyFound, OPMLReader.nameMatches(elementName, "body") {
                    bodyFound = true
                    bodyDepth = depth
                } else {
                    ignoredBelow = depth
                }
                return
            }
            guard let bodyDepth, depth > bodyDepth else { return }
            if let top, depth == top.depth + 1 {
                self.top?.hasChildElement = true
            }
            guard OPMLReader.nameMatches(elementName, "outline") else {
                ignoredBelow = depth
                return
            }
            let attributes = OutlineAttributes(attributeDict)
            if let address = OPMLReader.address(attributes.xmlURL) {
                feeds += 1
                guard feeds <= OPMLReader.maximumFeeds else {
                    refuse(.tooManyFeeds, parser)
                    return
                }
                let name = OPMLReader.cleanName(attributes.title, maximumCharacters: Library.maximumSourceNameLength)
                let feed = OPMLFeed(
                    address: address.text,
                    name: name.isEmpty ? OPMLReader.cleanName(attributes.text, maximumCharacters: Library.maximumSourceNameLength) : name,
                    siteAddress: OPMLReader.address(attributes.htmlURL).flatMap { $0.tooLong ? nil : $0.text },
                    addressIsTooLong: address.tooLong
                )
                if let top, !top.name.isEmpty {
                    self.top?.feeds.append(feed)
                } else {
                    entries.append(.feed(feed))
                }
                // The children of a feed are ignored.
                ignoredBelow = depth
                return
            }
            guard depth == bodyDepth + 1 else {
                // A nested folder: flattened into the top-level one.
                return
            }
            folders += 1
            guard folders <= OPMLReader.maximumFolders else {
                refuse(.tooManyFolders, parser)
                return
            }
            var name = OPMLReader.cleanName(attributes.title, maximumCharacters: Library.maximumCategoryNameLength)
            if name.isEmpty {
                name = OPMLReader.cleanName(attributes.text, maximumCharacters: Library.maximumCategoryNameLength)
            }
            top = TopOutline(depth: depth, name: name)
        }

        @objc func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard refusal == nil else { return }
            defer { depth -= 1 }
            if ignoredBelow == depth {
                ignoredBelow = nil
            }
            if let top, top.depth == depth {
                // A folder when it has a name and either a feed under it or
                // no child element at all (the writer's empty category).
                if !top.name.isEmpty, !top.feeds.isEmpty || !top.hasChildElement {
                    entries.append(.folder(name: top.name, feeds: top.feeds))
                }
                self.top = nil
            }
            if bodyDepth == depth {
                bodyDepth = nil
            }
        }

        // A document type the prolog walk did not see: the second guard.

        @objc func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            refuse(.hasDocumentType, parser)
        }

        @objc func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
            refuse(.hasDocumentType, parser)
        }

        @objc func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?,
                    systemID: String?, notationName: String?) {
            refuse(.hasDocumentType, parser)
        }

        @objc func parser(_ parser: XMLParser, foundNotationDeclarationWithName name: String, publicID: String?, systemID: String?) {
            refuse(.hasDocumentType, parser)
        }

        @objc func parser(_ parser: XMLParser, foundElementDeclarationWithName elementName: String, model: String) {
            refuse(.hasDocumentType, parser)
        }

        @objc func parser(_ parser: XMLParser, foundAttributeDeclarationWithName attributeName: String, forElement elementName: String,
                    type: String?, defaultValue: String?) {
            refuse(.hasDocumentType, parser)
        }
    }
}
