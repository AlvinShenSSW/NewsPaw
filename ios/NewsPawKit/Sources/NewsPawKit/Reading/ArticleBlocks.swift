import Foundation

/// An article's body as blocks (spec N05, N12; RD11 decisions 1 to 6).
///
/// `make` reads the HTML once from start to end with the package's tag
/// scanner and emits flat blocks as it goes. It builds no document tree and
/// hands nothing to an HTML parser: a tree builder's time and memory grow
/// out of proportion on markup a feed can carry (measured for RD11: seconds,
/// or hundreds of megabytes, for bodies of 16 to 240 KB). The work here is in
/// proportion to the input: a block's start ends the block before it, and
/// inline styles end with their block.
///
/// It is a pure function of the HTML and the base address: no request, no
/// clock, no storage. What it returns are values, never HTML; no script,
/// style or event attribute exists after it, and every link and image
/// address it returns is `http` or `https`.
public struct ArticleBlocks: Sendable, Hashable {
    public var blocks: [ArticleBlock]
    /// The marker at the end of the list: the input or the number of blocks
    /// was past its limit, or the input ended inside an element that is
    /// dropped with its content (a raw-text element or a comment among
    /// them), so the list does not hold the whole body.
    public var isCut: Bool

    public init(blocks: [ArticleBlock], isCut: Bool) {
        self.blocks = blocks
        self.isCut = isCut
    }

    /// Names the converter's output. A change to what `make` gives for the
    /// same HTML raises it; RD15 records it with a translation.
    public static let version = 2

    /// The part of the HTML that is read, in characters (Unicode scalars,
    /// as SQLite's `substr` counts them).
    public static let maximumInputCharacters = 2_000_000
    public static let maximumBlocks = 3_000
    public static let maximumImages = 300
    /// A paragraph's, heading's or code block's text beyond this continues
    /// in a further block: so many characters as a reader counts them, and
    /// so many bytes of UTF-8, since one such character can be of any size
    /// (a letter under any number of combining marks).
    public static let maximumBlockCharacters = 20_000
    public static let maximumBlockBytes = 80_000
    /// The deepest quote and list nesting a block shows.
    public static let maximumDepth = 3
    /// The most list, quote and table contexts kept open; deeper ones are
    /// counted and add no depth.
    static let maximumContexts = 32
    /// The longest alternative text kept, in characters and in bytes of
    /// UTF-8.
    static let maximumAlternativeTextLength = 500
    static let maximumAlternativeTextBytes = 2_000

    /// The plain text a body needs to count as full text, and the lower
    /// figure for text that is mostly Chinese, Japanese or Korean.
    public static let fullTextCharacters = 1_000
    public static let fullTextCharactersCJK = 400

    /// The blocks of `html`. Relative links and image addresses are
    /// resolved against `baseURL`, the article's own address, and dropped
    /// when there is none.
    public static func make(html: String, baseURL: URL?) -> ArticleBlocks {
        var bytes = Array(html.utf8)
        var inputWasCut = false
        if let end = offset(ofCharacter: maximumInputCharacters, in: bytes) {
            bytes.removeSubrange(end...)
            inputWasCut = true
        }
        return bytes.withUnsafeBufferPointer { source in
            var converter = Converter(bytes: bytes, source: source, base: baseURL)
            let end = TagScanner.scan(source, options: Converter.scanOptions) { token in
                converter.handle(token)
            }
            converter.finish(insideUnclosedElement: end == .unclosedRawText || end == .unclosedComment)
            return ArticleBlocks(blocks: converter.blocks, isCut: inputWasCut || converter.isCut)
        }
    }

    /// Whether `blocks` hold a full text rather than an excerpt (decision
    /// 5): the plain text of the text blocks, white space collapsed, has at
    /// least 1,000 characters, or at least 400 when more than half of its
    /// letters are Han, Hiragana, Katakana or Hangul.
    public static func isFullText(_ blocks: [ArticleBlock]) -> Bool {
        var characters = 0
        var letters = 0
        var cjkLetters = 0
        var pendingSpace = false
        for block in blocks {
            guard let text = block.plainText else { continue }
            for character in text {
                if character.isWhitespace {
                    pendingSpace = true
                    continue
                }
                if pendingSpace, characters > 0 {
                    characters += 1
                }
                pendingSpace = false
                characters += 1
                if character.isLetter {
                    letters += 1
                    if isCJK(character) {
                        cjkLetters += 1
                    }
                }
                if characters >= fullTextCharacters {
                    return true
                }
            }
            // A block's end separates words.
            pendingSpace = true
        }
        return characters >= fullTextCharactersCJK && cjkLetters * 2 > letters
    }

    /// Whether more than half of the letters of `text` are Han, Hiragana,
    /// Katakana or Hangul: what decides a block's line height (decision 8).
    public static func isMostlyCJK(_ text: some StringProtocol) -> Bool {
        var letters = 0
        var cjkLetters = 0
        for character in text where character.isLetter {
            letters += 1
            if isCJK(character) {
                cjkLetters += 1
            }
        }
        return cjkLetters * 2 > letters
    }

    /// Whether `text` holds Hiragana or Katakana: a block that does is
    /// drawn in the Japanese forms of its characters (decision 8).
    public static func containsKana(_ text: some StringProtocol) -> Bool {
        text.unicodeScalars.contains { isKana($0.value) }
    }

    // MARK: - Scripts

    private static func isCJK(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        return isHan(value) || isKana(value) || isHangul(value)
    }

    private static func isHan(_ value: UInt32) -> Bool {
        switch value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x3005...0x3007, 0x20000...0x2EBEF, 0x2F800...0x2FA1F,
             0x30000...0x323AF:
            true
        default:
            false
        }
    }

    private static func isKana(_ value: UInt32) -> Bool {
        switch value {
        case 0x3041...0x3096, 0x309D...0x309F, 0x30A1...0x30FA, 0x30FC...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F:
            true
        default:
            false
        }
    }

    private static func isHangul(_ value: UInt32) -> Bool {
        switch value {
        case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xD7B0...0xD7FF:
            true
        default:
            false
        }
    }

    // MARK: - The input limit

    /// The byte offset at which the character numbered `limit` (from zero)
    /// starts, or `nil` when `bytes` hold no more than `limit` characters.
    private static func offset(ofCharacter limit: Int, in bytes: [UInt8]) -> Int? {
        // A character is at least one byte.
        guard bytes.count > limit else { return nil }
        return bytes.withUnsafeBufferPointer { buffer -> Int? in
            var characters = 0
            var index = 0
            let count = buffer.count
            while index < count {
                if buffer[index] & 0xC0 != 0x80 {
                    if characters == limit {
                        return index
                    }
                    characters += 1
                }
                index += 1
            }
            return nil
        }
    }
}

// MARK: - The converter

/// The state of one conversion: the blocks so far, the text block being
/// built, and what is open around it.
private struct Converter {
    typealias Name = TagScanner.Name

    static let scanOptions = TagScanner.Options(
        // A tag is read to its end: with a shorter limit the rest of a long
        // attribute (an image written into its own `src`) would be read as
        // the article's text. The input is cut already, and a tag that never
        // ends consumes the rest of it.
        maximumTagLength: .max,
        rawTextElements: ["script", "style", "textarea", "title", "iframe", "noscript"],
        tagsWithAttributes: ["a", "img", "ol"],
        attributes: ["href", "src", "data-src", "srcset", "alt", "width", "height", "start", "class"],
        selfClosingHasNoContent: true
    )

    /// What a tag does. Any tag not listed contributes only its text.
    enum Tag {
        /// Starts and ends a block. `endsHeading`: a heading does not go on
        /// into it.
        case block(endsHeading: Bool)
        case heading(Int)
        case figure
        case figcaption
        case listItem
        case list(ordered: Bool)
        case quote
        case pre
        case rule
        case table
        case tableRow
        case tableCell
        case image
        case lineBreak
        case bold
        case italic
        case code
        case anchor
        /// Dropped with everything inside.
        case dropped
    }

    static let tags: [Name: Tag] = {
        var tags: [Name: Tag] = [
            "p": .block(endsHeading: true), "div": .block(endsHeading: false), "section": .block(endsHeading: false),
            "article": .block(endsHeading: false), "header": .block(endsHeading: false),
            "footer": .block(endsHeading: false), "main": .block(endsHeading: false), "aside": .block(endsHeading: false),
            "center": .block(endsHeading: false), "address": .block(endsHeading: false),
            "dt": .block(endsHeading: true), "dd": .block(endsHeading: true), "summary": .block(endsHeading: true),
            "details": .block(endsHeading: true),
            "h1": .heading(1), "h2": .heading(2), "h3": .heading(3), "h4": .heading(4), "h5": .heading(5), "h6": .heading(6),
            "figure": .figure, "figcaption": .figcaption, "li": .listItem, "ul": .list(ordered: false),
            "ol": .list(ordered: true), "blockquote": .quote, "pre": .pre, "hr": .rule, "table": .table, "tr": .tableRow,
            "td": .tableCell, "th": .tableCell, "img": .image, "br": .lineBreak,
            "b": .bold, "strong": .bold, "i": .italic, "em": .italic, "cite": .italic,
            "code": .code, "kbd": .code, "samp": .code, "tt": .code, "a": .anchor,
        ]
        // `script`, `style`, `noscript`, `iframe`, `textarea` and `title` are
        // raw text to the scanner, whose token is never read; `embed` has
        // no content.
        let dropped: [Name] = ["template", "object", "video", "audio", "canvas", "svg", "math", "form", "select", "button", "head"]
        for name in dropped {
            tags[name] = .dropped
        }
        return tags
    }()

    struct Style: Equatable {
        var isBold = false
        var isItalic = false
        var isCode = false
        var link: URL?
    }

    enum Context {
        /// `next`: the number of the next item of an ordered list.
        /// `pending`: the marker of the item whose first block is still to
        /// come.
        case list(ordered: Bool, next: Int, pending: ArticleBlock.ListMarker?)
        case quote
        /// `isContainer`: a block element stood in one of its cells, so its
        /// rows are no longer lines of text.
        case table(isContainer: Bool)
    }

    enum ContextKind {
        case list
        case quote
        case table
    }

    let bytes: [UInt8]
    /// The same bytes, for reading without a bounds check on each.
    let source: UnsafeBufferPointer<UInt8>
    let base: URL?

    private(set) var blocks: [ArticleBlock] = []
    /// The block limit was reached with a block still to come, or the input
    /// ended inside a dropped element.
    private(set) var isCut = false
    private var imageCount = 0

    // The text block being built.
    private var runs: [InlineRun] = []
    private var runBytes: [UInt8] = []
    private var runStyle = Style()
    private var hasContent = false
    /// A space is owed before the next word, in the style it was seen in.
    private var pendingSpace: Style?
    /// `br`s seen since the last word.
    private var pendingBreaks = 0
    /// " · " is owed before the next word: a new cell of a table row.
    private var pendingSeparator = false
    /// The last thing written is a line break.
    private var atLineStart = false

    // What is open.
    private var bold = 0
    private var italic = 0
    private var code = 0
    private var link: URL?
    /// The `href` of the open link, until text in it asks for its address:
    /// a link with no text is never resolved.
    private var pendingAddress: String?
    private var style = Style()
    private var headingLevel: Int?
    private var isCaption = false
    private var contexts: [Context] = []
    /// Contexts opened beyond `maximumContexts`.
    private var overflow = 0
    private var listCount = 0
    private var quoteCount = 0
    private var tableCount = 0
    /// Inside `pre`: how many are open, and its text so far.
    private var preDepth = 0
    private var preBytes: [UInt8] = []
    /// Inside a dropped element: its name and how many of it are open.
    private var droppedName = Name.other
    private var droppedDepth = 0

    /// A text token with its references decoded; reused.
    private var decoded: [UInt8] = []

    init(bytes: [UInt8], source: UnsafeBufferPointer<UInt8>, base: URL?) {
        self.bytes = bytes
        self.source = source
        self.base = base
    }

    // MARK: - Tokens

    /// Takes one token; false when the block limit is reached.
    mutating func handle(_ token: TagScanner.Token) -> Bool {
        switch token.kind {
        case .rawText:
            // The content of `script`, `style` and the like is never text.
            break
        case .text:
            guard droppedDepth == 0 else { break }
            let range = token.range
            if let start = source.baseAddress, memchr(start + range.lowerBound, 0x26, range.count) == nil {
                // No reference to decode.
                let text = UnsafeBufferPointer(rebasing: source[range])
                if preDepth > 0 {
                    preBytes.append(contentsOf: text)
                } else {
                    appendText(text)
                }
            } else {
                decode(range)
                if preDepth > 0 {
                    preBytes.append(contentsOf: decoded)
                } else {
                    let text = decoded
                    text.withUnsafeBufferPointer { appendText($0) }
                }
            }
        case .startTag:
            if droppedDepth > 0 {
                if token.name == droppedName, !token.isSelfClosing {
                    droppedDepth += 1
                }
            } else if preDepth > 0 {
                // Tags inside `pre` are dropped and their text kept.
                if token.name == "pre" {
                    preDepth += 1
                } else if token.name == "br" {
                    preBytes.append(UInt8(ascii: "\n"))
                }
            } else if let tag = Self.tags[token.name] {
                start(tag, token)
            }
        case .endTag:
            if droppedDepth > 0 {
                if token.name == droppedName {
                    droppedDepth -= 1
                }
            } else if preDepth > 0 {
                if token.name == "pre" {
                    preDepth -= 1
                    if preDepth == 0 {
                        emitCode()
                    }
                }
            } else if let tag = Self.tags[token.name] {
                end(tag)
            }
        }
        return !isCut
    }

    /// The end of the input: what is still open is emitted. Inside a
    /// dropped element that never ended — one the converter drops, or a
    /// raw-text element or a comment that ran to the end of the input in
    /// the scanner (`insideUnclosedElement`) — what was dropped may be the
    /// rest of the article, so the list is marked as cut.
    mutating func finish(insideUnclosedElement: Bool) {
        if preDepth > 0 {
            emitCode()
        }
        finishBlock(resetStyles: true)
        if droppedDepth > 0 || insideUnclosedElement {
            isCut = true
        }
    }

    private mutating func start(_ tag: Tag, _ token: TagScanner.Token) {
        switch tag {
        case .block(let endsHeading):
            beginBlockElement()
            if endsHeading {
                headingLevel = nil
            }
        case .heading(let level):
            beginBlockElement()
            headingLevel = level
        case .figure:
            beginBlockElement()
            isCaption = false
        case .figcaption:
            beginBlockElement()
            isCaption = true
        case .listItem:
            beginBlockElement()
            headingLevel = nil
            setPendingMarker(forNewItem: true)
        case .list(let ordered):
            beginBlockElement()
            headingLevel = nil
            if contexts.count < ArticleBlocks.maximumContexts {
                // The list stands where the enclosing item's first block
                // would.
                setPendingMarker(forNewItem: false)
            }
            let first = ordered ? Self.listStart(token.attributes["start"]) : 1
            push(.list(ordered: ordered, next: first, pending: nil))
        case .quote:
            beginBlockElement()
            headingLevel = nil
            push(.quote)
        case .pre:
            beginBlockElement()
            headingLevel = nil
            preDepth = 1
            preBytes.removeAll(keepingCapacity: true)
        case .rule:
            beginBlockElement()
            headingLevel = nil
            emit(.rule)
        case .table:
            beginBlockElement()
            headingLevel = nil
            push(.table(isContainer: false))
        case .tableRow:
            finishBlock(resetStyles: true)
        case .tableCell:
            if case .table(isContainer: false)? = contexts.last, overflow == 0 {
                // A further cell of a row of plain cells.
                pendingSeparator = hasContent
                resetStyles()
            } else {
                finishBlock(resetStyles: true)
            }
        case .image:
            if Self.isEmoji(token.attributes["class"]) {
                // An emoji written as an image (WordPress does so) is its
                // alternative text in the line: no block, and no request.
                if let text = Self.alternativeText(token.attributes["alt"]) {
                    let bytes = Array(text.utf8)
                    bytes.withUnsafeBufferPointer { appendText($0) }
                }
                break
            }
            markTableAsContainer()
            // An image splits its paragraph; the styles around it go on.
            finishBlock(resetStyles: false)
            if imageCount < ArticleBlocks.maximumImages, let image = image(from: token.attributes) {
                imageCount += 1
                emit(.image(image))
            }
        case .lineBreak:
            pendingBreaks += 1
        case .bold:
            bold += 1
            updateStyle()
        case .italic:
            italic += 1
            updateStyle()
        case .code:
            code += 1
            updateStyle()
        case .anchor:
            link = nil
            pendingAddress = token.attributes["href"]
            updateStyle()
        case .dropped:
            if !token.isSelfClosing {
                droppedName = token.name
                droppedDepth = 1
            }
        }
    }

    private mutating func end(_ tag: Tag) {
        switch tag {
        case .block, .listItem, .tableRow, .pre, .rule:
            finishBlock(resetStyles: true)
            if case .listItem = tag {
                // An item that held no block shows no marker.
                setPendingMarker(forNewItem: false)
            }
        case .heading:
            finishBlock(resetStyles: true)
            headingLevel = nil
        case .figure, .figcaption:
            finishBlock(resetStyles: true)
            isCaption = false
        case .list:
            finishBlock(resetStyles: true)
            pop(.list)
        case .quote:
            finishBlock(resetStyles: true)
            pop(.quote)
        case .table:
            finishBlock(resetStyles: true)
            pop(.table)
        case .tableCell:
            if case .table(isContainer: false)? = contexts.last, overflow == 0 {
                resetStyles()
            } else {
                finishBlock(resetStyles: true)
            }
        case .bold:
            bold = max(0, bold - 1)
            updateStyle()
        case .italic:
            italic = max(0, italic - 1)
            updateStyle()
        case .code:
            code = max(0, code - 1)
            updateStyle()
        case .anchor:
            link = nil
            pendingAddress = nil
            updateStyle()
        case .image, .lineBreak, .dropped:
            break
        }
    }

    // MARK: - Contexts

    private mutating func push(_ context: Context) {
        guard contexts.count < ArticleBlocks.maximumContexts else {
            overflow += 1
            return
        }
        contexts.append(context)
        count(context, by: 1)
    }

    /// Closes the nearest context of `kind` and everything opened inside
    /// it. A context beyond the limit is only counted down, so that its end
    /// tag does not close a kept one.
    private mutating func pop(_ kind: ContextKind) {
        if overflow > 0 {
            overflow -= 1
            return
        }
        let open: Int
        switch kind {
        case .list: open = listCount
        case .quote: open = quoteCount
        case .table: open = tableCount
        }
        guard open > 0 else { return }
        while let last = contexts.popLast() {
            count(last, by: -1)
            if Self.kind(of: last) == kind {
                break
            }
        }
    }

    private mutating func count(_ context: Context, by change: Int) {
        switch context {
        case .list: listCount += change
        case .quote: quoteCount += change
        case .table: tableCount += change
        }
    }

    private static func kind(of context: Context) -> ContextKind {
        switch context {
        case .list: .list
        case .quote: .quote
        case .table: .table
        }
    }

    /// The index of the innermost list.
    private var innermostList: Int? {
        contexts.lastIndex { if case .list = $0 { true } else { false } }
    }

    /// For a new item: the innermost list owes its next marker. Otherwise
    /// it owes none. Inside a list beyond the limit nothing changes: its
    /// items are not the kept list's.
    private mutating func setPendingMarker(forNewItem: Bool) {
        guard overflow == 0, let index = innermostList, case .list(let ordered, let next, _) = contexts[index] else { return }
        if !forNewItem {
            contexts[index] = .list(ordered: ordered, next: next, pending: nil)
        } else if ordered {
            contexts[index] = .list(ordered: true, next: next + 1, pending: .number(next))
        } else {
            contexts[index] = .list(ordered: false, next: next, pending: .bullet)
        }
    }

    /// The marker owed by the innermost list, which then owes none.
    private mutating func takeMarker() -> ArticleBlock.ListMarker? {
        guard let index = innermostList, case .list(let ordered, let next, let pending?) = contexts[index] else { return nil }
        contexts[index] = .list(ordered: ordered, next: next, pending: nil)
        return pending
    }

    /// A block element inside a cell: its table's rows are no longer lines
    /// of text.
    private mutating func markTableAsContainer() {
        if case .table(isContainer: false)? = contexts.last {
            contexts[contexts.count - 1] = .table(isContainer: true)
        }
    }

    /// `start` of an `ol`, kept between 1 and 9,999.
    private static func listStart(_ attribute: String?) -> Int {
        guard let attribute, let value = Int(attribute.trimmingCharacters(in: .whitespaces)) else { return 1 }
        return min(max(value, 1), 9_999)
    }

    // MARK: - Text

    /// Writes the text of `range` to `decoded` with its references decoded.
    private mutating func decode(_ range: Range<Int>) {
        decoded.removeAll(keepingCapacity: true)
        guard let start = source.baseAddress else { return }
        var index = range.lowerBound
        while index < range.upperBound {
            guard let found = memchr(start + index, 0x26, range.upperBound - index) else {
                decoded.append(contentsOf: UnsafeBufferPointer(rebasing: source[index..<range.upperBound]))
                return
            }
            let ampersand = start.distance(to: found.assumingMemoryBound(to: UInt8.self))
            decoded.append(contentsOf: UnsafeBufferPointer(rebasing: source[index..<ampersand]))
            index = HTMLText.decodeReference(bytes, from: ampersand, output: &decoded)
        }
    }

    /// Adds `text` to the text block being built, white space collapsed.
    private mutating func appendText(_ text: UnsafeBufferPointer<UInt8>) {
        let count = text.count
        var index = 0
        while index < count {
            let byte = text[index]
            // Most bytes are neither a space nor the start of one.
            if byte <= 0x20 || (byte >= 0xC2 && byte <= 0xE3) {
                let width = Self.whiteSpaceWidth(text, at: index)
                if width > 0 {
                    if hasContent, !atLineStart, pendingSpace == nil {
                        pendingSpace = style
                    }
                    index += width
                    continue
                }
            }
            var end = index + 1
            while end < count {
                let next = text[end]
                if next <= 0x20 || (next >= 0xC2 && next <= 0xE3), Self.whiteSpaceWidth(text, at: end) > 0 {
                    break
                }
                end += 1
            }
            appendWord(UnsafeBufferPointer(rebasing: text[index..<end]))
            index = end
        }
    }

    /// Adds `word`, with what is owed before it.
    private mutating func appendWord(_ word: UnsafeBufferPointer<UInt8>) {
        if !hasContent, Self.isInvisible(word) {
            // A block of zero-width characters alone has no text.
            return
        }
        if let raw = pendingAddress {
            link = address(raw)
            pendingAddress = nil
            updateStyle()
        }
        if pendingBreaks >= 2 {
            // Two or more line breaks in a row end the block.
            finishBlock(resetStyles: false)
        } else if pendingBreaks == 1, hasContent {
            write([UInt8(ascii: "\n")], in: style)
            atLineStart = true
            pendingSpace = nil
        }
        pendingBreaks = 0
        if pendingSeparator {
            if hasContent {
                write(Array(" · ".utf8), in: Style())
                pendingSpace = nil
            }
            pendingSeparator = false
        }
        if let space = pendingSpace {
            if hasContent, !atLineStart {
                write([UInt8(ascii: " ")], in: space)
            }
            pendingSpace = nil
        }
        if style != runStyle {
            flushRun()
            runStyle = style
        }
        runBytes.append(contentsOf: word)
        hasContent = true
        atLineStart = false
    }

    private mutating func write(_ text: [UInt8], in style: Style) {
        if style != runStyle {
            flushRun()
            runStyle = style
        }
        runBytes.append(contentsOf: text)
    }

    private mutating func flushRun() {
        guard !runBytes.isEmpty else { return }
        runs.append(InlineRun(
            String(decoding: runBytes, as: UTF8.self), isBold: runStyle.isBold, isItalic: runStyle.isItalic,
            isCode: runStyle.isCode, link: runStyle.link
        ))
        runBytes.removeAll(keepingCapacity: true)
    }

    private mutating func updateStyle() {
        style = Style(isBold: bold > 0, isItalic: italic > 0, isCode: code > 0, link: link)
    }

    private mutating func resetStyles() {
        bold = 0
        italic = 0
        code = 0
        link = nil
        pendingAddress = nil
        style = Style()
    }

    /// How many bytes of white space start at `index`: 0 for none. White
    /// space is what Unicode calls so, the no-break and ideographic spaces
    /// included, so that a block of `&nbsp;` alone is empty.
    private static func whiteSpaceWidth(_ text: UnsafeBufferPointer<UInt8>, at index: Int) -> Int {
        let byte = text[index]
        if byte <= 0x20 {
            return byte == 0x20 || (byte >= 0x09 && byte <= 0x0D) ? 1 : 0
        }
        if byte < 0xC2 || byte > 0xE3 {
            return 0
        }
        let second = index + 1 < text.count ? text[index + 1] : 0
        let third = index + 2 < text.count ? text[index + 2] : 0
        switch byte {
        case 0xC2:
            return second == 0xA0 || second == 0x85 ? 2 : 0
        case 0xE1:
            return second == 0x9A && third == 0x80 ? 3 : 0
        case 0xE2:
            if second == 0x80 {
                return (third >= 0x80 && third <= 0x8A) || third == 0xA8 || third == 0xA9 || third == 0xAF ? 3 : 0
            }
            return second == 0x81 && third == 0x9F ? 3 : 0
        case 0xE3:
            return second == 0x80 && third == 0x80 ? 3 : 0
        default:
            return 0
        }
    }

    /// Whether the word is made of zero-width characters only (U+200B to
    /// U+200D, U+2060, U+FEFF).
    private static func isInvisible(_ word: UnsafeBufferPointer<UInt8>) -> Bool {
        let count = word.count
        guard count % 3 == 0, word[0] == 0xE2 || word[0] == 0xEF else { return false }
        var index = 0
        while index < count {
            let first = word[index]
            let second = word[index + 1]
            let third = word[index + 2]
            let zeroWidth = (first == 0xE2 && second == 0x80 && third >= 0x8B && third <= 0x8D)
                || (first == 0xE2 && second == 0x81 && third == 0xA0)
                || (first == 0xEF && second == 0xBB && third == 0xBF)
            guard zeroWidth else { return false }
            index += 3
        }
        return true
    }

    // MARK: - Blocks

    /// A block element starts: it ends the block before it and the inline
    /// styles with it, and a table whose cell holds it is a container.
    private mutating func beginBlockElement() {
        markTableAsContainer()
        finishBlock(resetStyles: true)
    }

    /// Ends the text block being built; it is emitted when it has text.
    private mutating func finishBlock(resetStyles: Bool) {
        guard hasContent || pendingBreaks > 0 || pendingSeparator else {
            // Nothing is being built: only the styles can be open.
            if resetStyles {
                self.resetStyles()
            }
            return
        }
        flushRun()
        if hasContent {
            emitText(runs)
        }
        runs.removeAll(keepingCapacity: true)
        hasContent = false
        pendingSpace = nil
        pendingBreaks = 0
        pendingSeparator = false
        atLineStart = false
        if resetStyles {
            self.resetStyles()
        }
    }

    private mutating func emit(_ kind: ArticleBlock.Kind) {
        guard !isCut else { return }
        guard blocks.count < ArticleBlocks.maximumBlocks else {
            isCut = true
            return
        }
        blocks.append(ArticleBlock(
            kind, quoteDepth: min(quoteCount, ArticleBlocks.maximumDepth), listDepth: min(listCount, ArticleBlocks.maximumDepth),
            marker: takeMarker(), isCaption: isCaption
        ))
    }

    private func textKind(_ runs: [InlineRun]) -> ArticleBlock.Kind {
        headingLevel.map { .heading(level: $0, runs) } ?? .paragraph(runs)
    }

    /// Emits `runs` as one block, or as several when they hold more than
    /// `maximumBlockCharacters` characters or `maximumBlockBytes` bytes.
    private mutating func emitText(_ runs: [InlineRun]) {
        let limit = ArticleBlocks.maximumBlockCharacters
        let byteLimit = ArticleBlocks.maximumBlockBytes
        // A character is at least one byte.
        if runs.reduce(0, { $0 + $1.text.utf8.count }) <= limit {
            emit(textKind(runs))
            return
        }
        var piece: [InlineRun] = []
        var room = limit
        var byteRoom = byteLimit
        for run in runs {
            var rest = Substring(run.text)
            while !rest.isEmpty, !isCut {
                var part = run
                if let cut = Self.pieceEnd(of: rest, characters: room, bytes: byteRoom) {
                    if cut > rest.startIndex {
                        part.text = String(rest[..<cut])
                        piece.append(part)
                    }
                    if !piece.isEmpty {
                        emit(textKind(piece))
                    }
                    piece.removeAll()
                    room = limit
                    byteRoom = byteLimit
                    rest = rest[cut...]
                } else {
                    part.text = String(rest)
                    piece.append(part)
                    room -= rest.count
                    byteRoom -= rest.utf8.count
                    rest = Substring()
                    if room == 0 || byteRoom == 0 {
                        emit(textKind(piece))
                        piece.removeAll()
                        room = limit
                        byteRoom = byteLimit
                    }
                }
            }
        }
        if !piece.isEmpty {
            emit(textKind(piece))
        }
    }

    /// Where a piece of `text` ends that may hold `characters` characters
    /// and `bytes` bytes of UTF-8, whichever is reached first; `nil` when
    /// all of `text` fits. The character bound ends the piece between two
    /// characters. The byte bound ends it where a scalar ends, which can be
    /// inside a character: a character has no largest size. The index is
    /// the start of `text` only when not even its first scalar fits (the
    /// piece so far is full).
    private static func pieceEnd(of text: Substring, characters: Int, bytes: Int) -> String.Index? {
        let size = text.utf8.count
        if size <= bytes {
            // A character is at least one byte.
            guard size > characters,
                  let cut = text.index(text.startIndex, offsetBy: characters, limitedBy: text.endIndex), cut != text.endIndex
            else { return nil }
            return cut
        }
        var byteCut = text.utf8.index(text.utf8.startIndex, offsetBy: bytes)
        while byteCut > text.startIndex, text.utf8[byteCut] & 0xC0 == 0x80 {
            byteCut = text.utf8.index(before: byteCut)
        }
        let head = text[..<byteCut]
        if let cut = head.index(head.startIndex, offsetBy: characters, limitedBy: head.endIndex), cut != head.endIndex {
            return cut
        }
        return byteCut
    }

    /// Emits the text of the `pre` that just ended: as written, without the
    /// line break after its start tag and the white space at its end; in
    /// several blocks when it is longer than `maximumBlockCharacters` or
    /// `maximumBlockBytes`, cut at a line's end where there is one.
    private mutating func emitCode() {
        preDepth = 0
        var text = String(decoding: preBytes, as: UTF8.self)
        preBytes.removeAll(keepingCapacity: true)
        if text.utf8.contains(UInt8(ascii: "\r")) {
            text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
        var rest = Substring(text)
        if rest.first == "\n" {
            rest.removeFirst()
        }
        while let last = rest.last, last.isWhitespace {
            rest.removeLast()
        }
        guard rest.contains(where: { !$0.isWhitespace }) else { return }
        let limit = ArticleBlocks.maximumBlockCharacters
        let byteLimit = ArticleBlocks.maximumBlockBytes
        while !isCut, let cut = Self.pieceEnd(of: rest, characters: limit, bytes: byteLimit) {
            if let lineEnd = rest[..<cut].lastIndex(of: "\n"), lineEnd > rest.startIndex {
                emit(.code(String(rest[..<lineEnd])))
                rest = rest[rest.index(after: lineEnd)...]
            } else {
                emit(.code(String(rest[..<cut])))
                rest = rest[cut...]
            }
        }
        if !rest.isEmpty {
            emit(.code(String(rest)))
        }
    }

    // MARK: - Addresses and images

    /// `raw`, an attribute's value, as an `http` or `https` address,
    /// resolved against the base; `nil` for anything else.
    private func address(_ raw: String?) -> URL? {
        guard var reference = raw else { return nil }
        if reference.utf8.contains(0x26) {
            reference = FeedDiscovery.decodeReferences(reference)
        }
        if let first = reference.utf8.first, let last = reference.utf8.last, first <= 0x20 || last <= 0x20 {
            reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !reference.isEmpty else { return nil }
        let resolved = base.map { URL(string: reference, relativeTo: $0)?.absoluteURL } ?? URL(string: reference)
        guard let url = resolved, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false), !host.isEmpty
        else { return nil }
        return url
    }

    /// The image of an `img` tag: its `src`, or when that is not an `http`
    /// or `https` address, its `data-src`, then the first address of its
    /// `srcset`. `nil` when none is, and for an image that declares a width
    /// or height of 0 or 1 (a tracking pixel).
    private func image(from attributes: [String: String]) -> ArticleImage? {
        let width = Self.pixels(attributes["width"])
        let height = Self.pixels(attributes["height"])
        if let width, width <= 1 {
            return nil
        }
        if let height, height <= 1 {
            return nil
        }
        guard let url = address(attributes["src"]) ?? address(attributes["data-src"])
            ?? address(Self.firstAddress(ofSourceSet: attributes["srcset"]))
        else { return nil }
        let alternativeText = Self.alternativeText(attributes["alt"])
        var declaredSize: ArticleImage.DeclaredSize?
        if let width, let height {
            declaredSize = ArticleImage.DeclaredSize(width: width, height: height)
        }
        return ArticleImage(url: url, alternativeText: alternativeText, declaredSize: declaredSize)
    }

    /// An `alt` attribute as text: references decoded, white space
    /// collapsed, cut to the alternative text's bounds; `nil` when empty.
    private static func alternativeText(_ attribute: String?) -> String? {
        guard let attribute else { return nil }
        let text = HTMLText.collapseWhitespace(FeedDiscovery.decodeReferences(attribute))
        guard !text.isEmpty else { return nil }
        let whole = Substring(text)
        let end = pieceEnd(
            of: whole, characters: ArticleBlocks.maximumAlternativeTextLength, bytes: ArticleBlocks.maximumAlternativeTextBytes
        )
        return end.map { String(whole[..<$0]) } ?? text
    }

    /// Whether an `img`'s `class` names it an emoji: the token `wp-smiley`
    /// or `emoji`, as WordPress and its emoji script write them.
    private static func isEmoji(_ classAttribute: String?) -> Bool {
        guard let classAttribute, !classAttribute.isEmpty else { return false }
        return classAttribute.utf8.split(whereSeparator: { $0 <= 0x20 }).contains { token in
            token.elementsEqual("wp-smiley".utf8) || token.elementsEqual("emoji".utf8)
        }
    }

    /// A `width` or `height` attribute as pixels: digits, optionally
    /// followed by `px`; at most 100,000. Anything else (a percentage) is
    /// no size.
    private static func pixels(_ attribute: String?) -> Int? {
        guard var text = attribute?.trimmingCharacters(in: .whitespaces).lowercased(), text.utf8.count <= 10 else { return nil }
        if text.hasSuffix("px") {
            text.removeLast(2)
        }
        guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let value = Int(text), value <= 100_000 else {
            return nil
        }
        return value
    }

    /// The first address of a `srcset`: up to the first white space, without
    /// a comma at its end.
    private static func firstAddress(ofSourceSet attribute: String?) -> String? {
        guard let attribute else { return nil }
        let trimmed = attribute.drop { $0.isWhitespace || $0 == "," }
        var first = trimmed.prefix { !$0.isWhitespace }
        while first.last == "," {
            first.removeLast()
        }
        return first.isEmpty ? nil : String(first)
    }
}
