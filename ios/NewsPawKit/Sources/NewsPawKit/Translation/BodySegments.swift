import CryptoKit
import Foundation

/// One text of a body as it is judged and sent (RD15 decision 3): a line of
/// a text block, or a piece of a line longer than
/// `BodySegments.maximumCharacters`.
public struct BodySegment: Sendable, Hashable {
    /// What happens to the segment (decision 4).
    public enum Role: Sendable, Hashable {
        /// It goes to the model.
        case sent
        /// It is shown as it is: in the reading language already, or
        /// without a letter.
        case kept
        /// Written in Traditional Chinese under `zh-Hans`: converted on the
        /// device, never sent.
        case converted(String)
    }

    /// The index of its block; `BodySegments.titleBlock` for a title.
    public let block: Int
    /// The text as sent: trimmed.
    public let text: String
    /// The SHA-256 of `text`'s UTF-8, lower-case hex: the key of its stored
    /// row.
    public let hash: String
    public let role: Role
}

/// What an opening of a body sends, shows and counts in one reading
/// language (RD15 decisions 3 and 4): every text block's lines cut into
/// segments, each judged, and the segments to send grouped into chunks in
/// reading order. It depends only on the blocks, the title given and the
/// locale.
public struct BodyTranslationPlan: Sendable, Hashable {
    public let locale: ReadingLocale
    /// The text blocks by index (and the title at `BodySegments.titleBlock`):
    /// their lines in order, each its pieces in order.
    public let lines: [Int: [[BodySegment]]]
    /// The segments to send, each text once, grouped in reading order.
    public let chunks: [[BodySegment]]
    /// The first language the recognizer gives for each text block's whole
    /// text (and the title's), for VoiceOver to read an original in.
    public let originalLanguages: [Int: String]

    /// The hashes of every segment to send.
    public var sentHashes: Set<String> {
        Set(chunks.flatMap { $0.map(\.hash) })
    }

    /// Whether anything is sent or converted: without it the screen shows
    /// no translation control.
    public var hasWork: Bool {
        !chunks.isEmpty || lines.values.contains { $0.contains { $0.contains { if case .converted = $0.role { true } else { false } } } }
    }

    /// Whether a segment is converted on the device.
    public var hasConversion: Bool {
        lines.values.contains { $0.contains { $0.contains { if case .converted = $0.role { true } else { false } } } }
    }

    /// The text a block shows in Translation mode, or `nil` while it shows
    /// its original: a block is translated when it has a segment sent or
    /// converted and every segment sent of it is in `done` (hash → text).
    /// Its lines are joined by `"\n"`, the pieces of one line with nothing
    /// for `zh-Hans` and `ja` and one space for `en`.
    public func text(of block: Int, done: [String: String]) -> String? {
        guard let blockLines = lines[block] else { return nil }
        var hasWork = false
        for line in blockLines {
            for piece in line {
                switch piece.role {
                case .sent:
                    guard done[piece.hash] != nil else { return nil }
                    hasWork = true
                case .converted:
                    hasWork = true
                case .kept:
                    break
                }
            }
        }
        guard hasWork else { return nil }
        let joiner = locale == .english ? " " : ""
        return blockLines.map { line in
            line.map { piece in
                switch piece.role {
                case .sent: done[piece.hash] ?? piece.text
                case .converted(let converted): converted
                case .kept: piece.text
                }
            }.joined(separator: joiner)
        }.joined(separator: "\n")
    }

    /// How many chunks have every segment in `done`: the first number of
    /// "Translating k of n".
    public func finishedChunks(done: [String: String]) -> Int {
        chunks.filter { $0.allSatisfy { done[$0.hash] != nil } }.count
    }

    /// The plan's chunks, each holding only its segments in `hashes`, in
    /// order; empty ones left out. The grouping stays the plan's.
    public func chunks(sending hashes: Set<String>) -> [[BodySegment]] {
        chunks.map { $0.filter { hashes.contains($0.hash) } }.filter { !$0.isEmpty }
    }
}

/// How a body is cut into segments and chunks (RD15 decision 3), and the
/// text Copy Translation puts on the pasteboard (decision 12). Pure.
public enum BodySegments {
    /// The longest segment, and the most characters of a chunk.
    public static let maximumCharacters = 1_500
    /// The most segments of a chunk.
    public static let chunkTexts = 20
    /// The block index a title is planned under (reader mode, decision 14).
    public static let titleBlock = -1

    /// The plan of `blocks`, with `title` as its first segment when given.
    public static func plan(_ blocks: [ArticleBlock], title: String? = nil, locale: ReadingLocale) -> BodyTranslationPlan {
        var texts: [(Int, String)] = []
        if let title {
            texts.append((titleBlock, title))
        }
        for (index, block) in blocks.enumerated() {
            switch block.kind {
            case .paragraph(let runs), .heading(_, let runs):
                texts.append((index, runs.map(\.text).joined()))
            case .image, .code, .rule:
                continue
            }
        }
        var roles: [String: BodySegment.Role] = [:]
        var sent: [BodySegment] = []
        var lines: [Int: [[BodySegment]]] = [:]
        var languages: [Int: String] = [:]
        for (index, text) in texts {
            var blockLines: [[BodySegment]] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard TextLanguage.Units(trimmed).hasLetter else {
                    // Shown as it is, and never judged.
                    blockLines.append([BodySegment(block: index, text: trimmed, hash: hash(trimmed), role: .kept)])
                    continue
                }
                blockLines.append(pieces(of: trimmed).map { piece in
                    let key = hash(piece)
                    let role: BodySegment.Role
                    if let known = roles[key] {
                        // A repeated text shows the first one's result and
                        // is not sent again.
                        role = known
                    } else {
                        role = switch TextLanguage.judge(segment: piece, reading: locale) {
                        case .send: .sent
                        case .keep: .kept
                        case .converted(let converted): .converted(converted)
                        }
                        roles[key] = role
                        if role == .sent {
                            sent.append(BodySegment(block: index, text: piece, hash: key, role: .sent))
                        }
                    }
                    return BodySegment(block: index, text: piece, hash: key, role: role)
                })
            }
            lines[index] = blockLines
            if let language = language(of: text) {
                languages[index] = language
            }
        }
        return BodyTranslationPlan(locale: locale, lines: lines, chunks: chunks(sent), originalLanguages: languages)
    }

    /// `line` (trimmed, with a letter) cut into pieces of at most
    /// `maximumCharacters`: after the last sentence end inside the bound
    /// (`。！？` anywhere; `.!?` followed by white space), else at the last
    /// white space, else at the bound. Each piece is trimmed.
    static func pieces(of line: String) -> [String] {
        var result: [String] = []
        var rest = Substring(line)
        while rest.count > maximumCharacters {
            let window = rest.prefix(maximumCharacters)
            var cut: String.Index?
            var index = window.endIndex
            while index > window.startIndex {
                let previous = window.index(before: index)
                let character = window[previous]
                if "。！？".contains(character) || (".!?".contains(character) && index < rest.endIndex && rest[index].isWhitespace) {
                    cut = index
                    break
                }
                index = previous
            }
            if cut == nil, let space = window.lastIndex(where: \.isWhitespace), space > window.startIndex {
                cut = space
            }
            let end = cut ?? window.endIndex
            let piece = rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty {
                result.append(piece)
            }
            rest = rest[end...].drop(while: \.isWhitespace)
        }
        let last = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty {
            result.append(last)
        }
        return result
    }

    /// `segments` grouped in order: a segment joins the current chunk while
    /// it keeps at most `chunkTexts` segments and `maximumCharacters`
    /// characters, else starts the next. A segment is never split.
    static func chunks(_ segments: [BodySegment]) -> [[BodySegment]] {
        var chunks: [[BodySegment]] = []
        var current: [BodySegment] = []
        var characters = 0
        for segment in segments {
            if !current.isEmpty, current.count >= chunkTexts || characters + segment.text.count > maximumCharacters {
                chunks.append(current)
                current = []
                characters = 0
            }
            current.append(segment)
            characters += segment.text.count
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    /// The SHA-256 of `text`'s UTF-8, lower-case hex.
    public static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The recognizer's first language for `text`, as a BCP 47 tag; `nil`
    /// when it has none.
    public static func language(of text: String) -> String? {
        guard TextLanguage.Units(text).hasLetter else { return nil }
        return TextLanguage.firstLanguage(of: TextLanguage.cut(text, characters: Int.max))?.rawValue
    }

    /// What Copy Translation puts on the pasteboard (decision 12), as plain
    /// text: `title`, then every text block as Translation mode shows it and
    /// every code block as it is, each after a blank line. Images and rules
    /// are left out.
    public static func copyText(title: String, blocks: [ArticleBlock], plan: BodyTranslationPlan?, done: [String: String]) -> String {
        var parts = [title]
        for (index, block) in blocks.enumerated() {
            switch block.kind {
            case .paragraph, .heading:
                let text = plan?.text(of: index, done: done) ?? block.plainText ?? ""
                if !text.isEmpty {
                    parts.append(text)
                }
            case .code(let code):
                parts.append(code)
            case .image, .rule:
                continue
            }
        }
        return parts.joined(separator: "\n\n")
    }
}
