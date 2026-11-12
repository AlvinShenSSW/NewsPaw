import Foundation

/// Reads an RSS 2.0, RSS 1.0 (RDF) or Atom document in one streaming pass
/// with the system's XML parser, building the feed and its items directly
/// from the parse events.
///
/// Elements are matched by namespace, not by the prefix a document happens
/// to use. External entities and document types are never resolved. Every
/// field is text that is either there or absent: a field whose element holds
/// markup where text is expected is absent, and nothing else about its item
/// changes. When the document stops being well-formed, the items completed
/// before that point are kept.
///
/// Some documents make the system parser take time growing faster than
/// their size, or more. Reading stops where such a document goes past one of
/// the limits below, as if it stopped being well-formed there: the items
/// completed before are kept and the document is incomplete; with no item
/// completed it is not a feed. Declarations come before the root, so a
/// document refused for one is never a feed.
/// - A start tag with more than `StartTagScan.maximumAttributes` attributes,
///   found by a pass over the bytes before parsing, since the parser's time
///   goes into the tag before any callback.
/// - More than `maximumMappingsInScope` namespace declarations in scope: each
///   element's start costs time in proportion to them.
/// - More than `maximumDistinctNames` distinct names (element and attribute
///   names, namespace prefixes and addresses, processing-instruction
///   targets, declared names): past about a hundred thousand the parser's
///   name table grows faster than the document (measured: one million
///   distinct element names in 9.9 MB, 3 s, against 0.1 s for a quarter of
///   that).
/// - In the document type: an internal entity whose value is longer than
///   `maximumEntityValueBytes` or contains `&` (a reference to another
///   entity), any attribute-list declaration (the parser applies their
///   defaults to every element, at a cost growing with the square of their
///   number), and more than `maximumDeclarations` declarations. A parameter
///   entity's declaration is counted and its value checked like any other;
///   the parser refuses every reference to one in the internal subset
///   (measured: no element is delivered, in time proportional to the
///   document), so references need no limit of their own.
final class XMLFeedReader: NSObject, XMLParserDelegate {
    /// Namespace declarations in scope at once. A feed declares a dozen or
    /// two on its root; at 256 a 10 MB document of elements in their scope
    /// parses in about 0.8 s on the system parser (measured on this Mac).
    static let maximumMappingsInScope = 256

    /// Distinct names in one document. A feed with XHTML content uses a few
    /// hundred.
    static let maximumDistinctNames = 4096

    /// Declarations in the internal subset. A document that declares HTML's
    /// named characters as entities needs about 250.
    static let maximumDeclarations = 1024

    /// The longest internal entity value accepted, in bytes as the parser
    /// delivers it (character references already decoded). Values up to
    /// this length without `&` are read in time proportional to the number
    /// of references (measured: 2 million references, linear).
    static let maximumEntityValueBytes = 256

    enum Namespace {
        static let atom = "http://www.w3.org/2005/Atom"
        static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
        static let rss1 = "http://purl.org/rss/1.0/"
        static let rss09 = "http://my.netscape.com/rdf/simple/0.9/"
        static let content = "http://purl.org/rss/1.0/modules/content/"
        static let dublinCore = "http://purl.org/dc/elements/1.1/"
        static let media = "http://search.yahoo.com/mrss/"
        static let xhtml = "http://www.w3.org/1999/xhtml"
    }

    /// What one pass produced.
    struct Result {
        /// The format, when the root element is a feed's.
        var format: ParsedFeed.Format?
        /// Whether the document has what its format needs to be a feed: a
        /// channel for RSS; a channel or an item for RDF; an id, a title or
        /// an entry for Atom.
        var hasFeedMarker = false
        var title: String?
        var titleKind: RawItem.TextKind = .html
        var siteLink: String?
        var items: [RawItem] = []
        /// Whether the parser read the document to its end without an error.
        var wellFormed = false
        /// Whether reading stopped because the root element is not a feed's.
        var rootRefused = false
    }

    /// Reads `data` in one pass, up to the first start tag with too many
    /// attributes.
    static func read(_ data: Data) -> Result {
        let cut = StartTagScan.cutOffset(in: data)
        let reader = XMLFeedReader()
        let parser = XMLParser(data: cut.map { data.prefix($0) } ?? data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        let finished = parser.parse()
        // A cut document is incomplete even when the part before the cut
        // happens to be well-formed (the tag came after the root's end).
        reader.result.wellFormed = finished && !reader.refusedRoot && cut == nil
        reader.result.rootRefused = reader.refusedRoot
        if reader.refusedRoot {
            reader.result.format = nil
        }
        return reader.result
    }

    private struct Element {
        var namespace: String
        var name: String
    }

    /// Where captured text goes.
    private enum Field {
        case feedTitle, feedLink
        case title, link, identifier, summary, content, author, creator, date, fallbackDate
    }

    // The two captures are classes so that appending to their text always
    // happens in place: a copy of a struct holding the text would make each
    // append copy everything collected so far.

    /// Text being collected for one element.
    private final class TextCapture {
        let depth: Int
        let field: Field
        var text = ""
        /// Set when the element turns out to hold markup.
        var invalid = false

        init(depth: Int, field: Field) {
            self.depth = depth
            self.field = field
        }
    }

    /// Atom XHTML being rebuilt as markup.
    private final class MarkupCapture {
        let depth: Int
        let field: Field
        var markup = ""
        /// The depth of the wrapping `div`, which is not part of the content.
        var wrapperDepth: Int?
        /// Depths of void elements written at their start.
        var voidDepths: Set<Int> = []

        init(depth: Int, field: Field) {
            self.depth = depth
            self.field = field
        }
    }

    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
    ]

    private var result = Result()
    private var refusedRoot = false
    private var stack: [Element] = []
    /// The namespace of RSS 2.0's own elements: the root's, normally none.
    private var rssNamespace = ""
    private var item: RawItem?
    private var itemDepth = 0
    private var capture: TextCapture?
    private var markup: MarkupCapture?
    private var prefixes: [String: [String]] = [:]

    /// Set once reading has been stopped at a limit; later events are
    /// ignored.
    private var stopped = false
    private var mappingsInScope = 0
    private var names = Set<String>()
    private var declarations = 0

    // MARK: - Limits

    private func stop(_ parser: XMLParser) {
        stopped = true
        parser.abortParsing()
    }

    /// Records `name` among the document's distinct names; stops reading
    /// and returns false when that makes too many.
    private func note(_ name: String, _ parser: XMLParser) -> Bool {
        if names.insert(name).inserted, names.count > Self.maximumDistinctNames {
            stop(parser)
            return false
        }
        return true
    }

    /// Counts one declaration of the internal subset; stops reading and
    /// returns false past the limit.
    private func noteDeclaration(_ name: String, _ parser: XMLParser) -> Bool {
        declarations += 1
        if declarations > Self.maximumDeclarations {
            stop(parser)
            return false
        }
        return note(name, parser)
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        guard !stopped, noteDeclaration(name, parser) else { return }
        guard let value, value.utf8.count <= Self.maximumEntityValueBytes, !value.utf8.contains(UInt8(ascii: "&")) else {
            stop(parser)
            return
        }
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        guard !stopped else { return }
        _ = noteDeclaration(name, parser)
    }

    func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?, systemID: String?, notationName: String?) {
        guard !stopped else { return }
        _ = noteDeclaration(name, parser)
    }

    func parser(_ parser: XMLParser, foundNotationDeclarationWithName name: String, publicID: String?, systemID: String?) {
        guard !stopped else { return }
        _ = noteDeclaration(name, parser)
    }

    func parser(_ parser: XMLParser, foundElementDeclarationWithName elementName: String, model: String) {
        guard !stopped else { return }
        _ = noteDeclaration(elementName, parser)
    }

    func parser(
        _ parser: XMLParser, foundAttributeDeclarationWithName attributeName: String, forElement elementName: String,
        type: String?, defaultValue: String?
    ) {
        guard !stopped else { return }
        stop(parser)
    }

    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
        guard !stopped else { return }
        _ = note(target, parser)
    }

    // MARK: - Parser events

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        guard !stopped else { return }
        mappingsInScope += 1
        guard mappingsInScope <= Self.maximumMappingsInScope else {
            stop(parser)
            return
        }
        guard note(prefix, parser), note(namespaceURI, parser) else { return }
        prefixes[prefix, default: []].append(namespaceURI)
    }

    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
        guard !stopped else { return }
        mappingsInScope -= 1
        _ = prefixes[prefix]?.popLast()
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        guard !stopped, note(qName ?? elementName, parser) else { return }
        for name in attributeDict.keys {
            guard note(name, parser) else { return }
        }
        let element = Element(namespace: namespaceURI ?? "", name: elementName)
        stack.append(element)
        let depth = stack.count

        if markup != nil {
            startMarkupElement(element, attributes: attributeDict, depth: depth)
            return
        }
        if let capture {
            capture.invalid = true
            return
        }
        if depth == 1 {
            startRoot(element, parser: parser)
            return
        }
        guard let format = result.format else { return }
        if item != nil {
            startItemDescendant(element, attributes: attributeDict, depth: depth, format: format)
            return
        }
        let parent = stack[depth - 2]
        switch format {
        case .rss:
            if depth == 2, element.namespace == rssNamespace, element.name == "channel" {
                result.hasFeedMarker = true
            } else if depth == 3, parent.name == "channel", parent.namespace == rssNamespace, element.namespace == rssNamespace {
                switch element.name {
                case "title": startCapture(.feedTitle, depth: depth)
                case "link": startCapture(.feedLink, depth: depth)
                case "item": startItem(depth: depth)
                default: break
                }
            }
        case .rdf:
            guard isRSS1(element.namespace) else { return }
            if depth == 2, element.name == "channel" {
                result.hasFeedMarker = true
            } else if depth == 2, element.name == "item" {
                result.hasFeedMarker = true
                startItem(depth: depth)
                item?.identifier = rdfAbout(attributeDict)
            } else if depth == 3, parent.name == "channel", isRSS1(parent.namespace) {
                switch element.name {
                case "title": startCapture(.feedTitle, depth: depth)
                case "link": startCapture(.feedLink, depth: depth)
                default: break
                }
            }
        case .atom:
            guard depth == 2, element.namespace == Namespace.atom else { return }
            switch element.name {
            case "title":
                result.hasFeedMarker = true
                // A repeated title keeps the first one and its type.
                guard result.title == nil else { break }
                let kind = atomKind(attributeDict)
                result.titleKind = kind == .text ? .text : .html
                if kind == .xhtml {
                    markup = MarkupCapture(depth: depth, field: .feedTitle)
                } else if kind != .unsupported {
                    startCapture(.feedTitle, depth: depth)
                }
            case "id":
                result.hasFeedMarker = true
            case "link":
                if result.siteLink == nil, isAlternate(attributeDict) {
                    result.siteLink = attributeDict["href"]
                }
            case "entry":
                result.hasFeedMarker = true
                startItem(depth: depth)
            default:
                break
            }
        case .json:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard !stopped, !stack.isEmpty else { return }
        let depth = stack.count
        defer { stack.removeLast() }

        if let current = markup {
            if depth == current.depth {
                markup = nil
                deliver(current.markup, to: current.field)
            } else if depth == current.wrapperDepth {
                current.wrapperDepth = nil
            } else if current.voidDepths.remove(depth) == nil {
                current.markup += "</\(elementName)>"
            }
            return
        }
        if let current = capture, depth == current.depth {
            capture = nil
            if !current.invalid {
                deliver(current.text, to: current.field)
            }
        }
        if let finished = item, depth == itemDepth {
            item = nil
            result.items.append(finished)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stopped else { return }
        if let markup {
            markup.markup += Self.escapeMarkup(string, attribute: false)
        } else if let capture, !capture.invalid {
            capture.text += string
        }
    }

    // MARK: - Root

    private func startRoot(_ element: Element, parser: XMLParser) {
        switch (element.namespace, element.name) {
        case (_, "rss"):
            result.format = .rss
            rssNamespace = element.namespace
        case (Namespace.rdf, "RDF"):
            result.format = .rdf
        case (Namespace.atom, "feed"):
            result.format = .atom
        default:
            // Not a feed: stop reading at once.
            refusedRoot = true
            parser.abortParsing()
        }
    }

    // MARK: - Items

    private func startItem(depth: Int) {
        item = RawItem()
        itemDepth = depth
        // RSS and RDF titles do not say whether they are HTML; they are
        // treated as HTML.
        item?.titleKind = .html
    }

    private func startItemDescendant(_ element: Element, attributes: [String: String], depth: Int, format: ParsedFeed.Format) {
        let relative = depth - itemDepth
        let parent = stack[depth - 2]
        if element.namespace == Namespace.media, relative == 1 || (relative == 2 && parent.namespace == Namespace.media && parent.name == "group") {
            readMedia(element.name, attributes: attributes)
            return
        }
        if relative == 2, format == .atom, parent.namespace == Namespace.atom, parent.name == "author",
           element.namespace == Namespace.atom, element.name == "name" {
            startCapture(.author, depth: depth)
            return
        }
        guard relative == 1 else { return }

        switch element.namespace {
        case Namespace.content where element.name == "encoded":
            item?.contentKind = .html
            startCapture(.content, depth: depth)
        case Namespace.dublinCore where element.name == "creator":
            startCapture(.creator, depth: depth)
        case Namespace.dublinCore where element.name == "date":
            startCapture(.fallbackDate, depth: depth)
        default:
            switch format {
            case .rss where element.namespace == rssNamespace:
                startRSSChild(element.name, attributes: attributes, depth: depth)
            case .rdf where isRSS1(element.namespace):
                startRDFChild(element.name, depth: depth)
            case .atom where element.namespace == Namespace.atom:
                startAtomChild(element.name, attributes: attributes, depth: depth)
            default:
                break
            }
        }
    }

    private func startRSSChild(_ name: String, attributes: [String: String], depth: Int) {
        switch name {
        case "title": startCapture(.title, depth: depth)
        case "link": startCapture(.link, depth: depth)
        case "guid":
            item?.identifierIsPermalink = attributes["isPermaLink"]?.trimmingCharacters(in: .whitespaces).lowercased() != "false"
            startCapture(.identifier, depth: depth)
        case "description":
            item?.summaryKind = .html
            startCapture(.summary, depth: depth)
        case "author": startCapture(.author, depth: depth)
        case "pubDate": startCapture(.date, depth: depth)
        case "enclosure":
            if item?.enclosureImage == nil, isImage(type: attributes["type"]) {
                item?.enclosureImage = attributes["url"]
            }
        default: break
        }
    }

    private func startRDFChild(_ name: String, depth: Int) {
        switch name {
        case "title": startCapture(.title, depth: depth)
        case "link": startCapture(.link, depth: depth)
        case "description":
            item?.summaryKind = .html
            startCapture(.summary, depth: depth)
        default: break
        }
    }

    private func startAtomChild(_ name: String, attributes: [String: String], depth: Int) {
        switch name {
        case "id": startCapture(.identifier, depth: depth)
        case "title":
            startTextConstruct(.title, attributes: attributes, depth: depth) { item, kind in item.titleKind = kind }
        case "summary":
            startTextConstruct(.summary, attributes: attributes, depth: depth) { item, kind in item.summaryKind = kind }
        case "content":
            guard attributes["src"] == nil else { return }
            startTextConstruct(.content, attributes: attributes, depth: depth) { item, kind in item.contentKind = kind }
        case "published": startCapture(.date, depth: depth)
        case "updated": startCapture(.fallbackDate, depth: depth)
        case "link":
            let rel = attributes["rel"]?.trimmingCharacters(in: .whitespaces).lowercased() ?? "alternate"
            if rel == "alternate", item?.link == nil {
                item?.link = attributes["href"]
            } else if rel == "enclosure", item?.enclosureImage == nil, isImage(type: attributes["type"]) {
                item?.enclosureImage = attributes["href"]
            }
        default: break
        }
    }

    /// An Atom text construct: plain text, escaped HTML, or XHTML rebuilt
    /// as markup. A field that already has a value keeps it.
    private func startTextConstruct(
        _ field: Field, attributes: [String: String], depth: Int, setKind: (inout RawItem, RawItem.TextKind) -> Void
    ) {
        guard var current = item, value(of: field, in: current) == nil else { return }
        switch atomKind(attributes) {
        case .text:
            setKind(&current, .text)
            item = current
            startCapture(field, depth: depth)
        case .html:
            setKind(&current, .html)
            item = current
            startCapture(field, depth: depth)
        case .xhtml:
            setKind(&current, .html)
            item = current
            markup = MarkupCapture(depth: depth, field: field)
        case .unsupported:
            break
        }
    }

    private func readMedia(_ name: String, attributes: [String: String]) {
        switch name {
        case "thumbnail":
            if item?.thumbnail == nil {
                item?.thumbnail = attributes["url"]
            }
        case "content":
            let medium = attributes["medium"]?.lowercased()
            if item?.mediaImage == nil, medium == "image" || isImage(type: attributes["type"]) {
                item?.mediaImage = attributes["url"]
            }
        default:
            break
        }
    }

    // MARK: - Text

    private func startCapture(_ field: Field, depth: Int) {
        capture = TextCapture(depth: depth, field: field)
    }

    /// Stores captured text; the first value of a field is kept.
    private func deliver(_ text: String, to field: Field) {
        switch field {
        case .feedTitle:
            if result.title == nil { result.title = text }
        case .feedLink:
            if result.siteLink == nil { result.siteLink = text }
        default:
            guard var current = item, value(of: field, in: current) == nil else { return }
            switch field {
            case .title: current.title = text
            case .link: current.link = text
            case .identifier: current.identifier = text
            case .summary: current.summary = text
            case .content: current.content = text
            case .author: current.author = text
            case .creator: current.creator = text
            case .date: current.date = text
            case .fallbackDate: current.fallbackDate = text
            case .feedTitle, .feedLink: break
            }
            item = current
        }
    }

    private func value(of field: Field, in item: RawItem) -> String? {
        switch field {
        case .title: item.title
        case .link: item.link
        case .identifier: item.identifier
        case .summary: item.summary
        case .content: item.content
        case .author: item.author
        case .creator: item.creator
        case .date: item.date
        case .fallbackDate: item.fallbackDate
        case .feedTitle, .feedLink: nil
        }
    }

    // MARK: - XHTML

    private func startMarkupElement(_ element: Element, attributes: [String: String], depth: Int) {
        guard let current = markup else { return }
        if depth == current.depth + 1, current.wrapperDepth == nil, element.namespace == Namespace.xhtml, element.name == "div",
           current.markup.isEmpty {
            current.wrapperDepth = depth
            return
        }
        var tag = "<" + element.name
        for (name, value) in attributes.sorted(by: { $0.key < $1.key }) {
            tag += " \(name)=\"\(Self.escapeMarkup(value, attribute: true))\""
        }
        tag += ">"
        current.markup += tag
        if Self.voidElements.contains(element.name) {
            current.voidDepths.insert(depth)
        }
    }

    /// Text and attribute values arrive decoded; they are escaped again.
    private static func escapeMarkup(_ text: String, attribute: Bool) -> String {
        var output = ""
        output.reserveCapacity(text.utf8.count)
        for character in text.unicodeScalars {
            switch character {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            case "\"" where attribute: output += "&quot;"
            default: output.unicodeScalars.append(character)
            }
        }
        return output
    }

    // MARK: - Helpers

    private enum AtomKind {
        case text, html, xhtml, unsupported
    }

    private func atomKind(_ attributes: [String: String]) -> AtomKind {
        let type = attributes["type"]?.trimmingCharacters(in: .whitespaces).lowercased() ?? "text"
        switch type {
        case "text", "", "text/plain": return .text
        case "html", "text/html": return .html
        case "xhtml", "application/xhtml+xml": return .xhtml
        default: return type.hasPrefix("text/") ? .text : .unsupported
        }
    }

    private func isAlternate(_ attributes: [String: String]) -> Bool {
        (attributes["rel"]?.trimmingCharacters(in: .whitespaces).lowercased() ?? "alternate") == "alternate"
    }

    private func isImage(type: String?) -> Bool {
        type?.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("image/") == true
    }

    private func isRSS1(_ namespace: String) -> Bool {
        namespace == Namespace.rss1 || namespace == Namespace.rss09
    }

    /// The item's `rdf:about`, found through the prefix the document bound
    /// to the RDF namespace: attributes keep their written prefix.
    private func rdfAbout(_ attributes: [String: String]) -> String? {
        for (name, value) in attributes {
            let parts = name.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[1] == "about", prefixes[String(parts[0])]?.last == Namespace.rdf {
                return value
            }
        }
        return nil
    }
}
