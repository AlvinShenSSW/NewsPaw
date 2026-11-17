import CryptoKit
import Foundation

/// One run of text the page script collected (RD16 decision 3): one text
/// node, with its normalised text, its block's number in its document,
/// whether it is the whole text of its block, and whether it lies in the
/// viewport.
public struct PageRun: Sendable, Hashable {
    /// The script's number for the node, in its document.
    public let id: Int
    public let block: Int
    public let text: String
    public let whole: Bool
    public let inView: Bool

    public init(id: Int, block: Int, text: String, whole: Bool, inView: Bool) {
        self.id = id
        self.block = block
        self.text = text
        self.whole = whole
        self.inView = inView
    }
}

/// The runs of one block, in document order (decision 5): judged together
/// and sent next to each other.
struct PageGroup: Sendable, Hashable {
    let block: Int
    let runs: [PageRun]

    var texts: [String] {
        runs.map(\.text)
    }

    /// Whether the group's one run is the whole text of its block and is
    /// sent uncut: only such a run is stored in `page_text`.
    var isCacheable: Bool {
        runs.count == 1 && runs[0].whole && PageBatcher.pieces(of: runs[0].text).count == 1
    }
}

/// One entry of a request: a piece of a run.
struct PageEntry: Sendable, Hashable {
    let run: Int
    let text: String
}

/// What one unit of work sends (decision 5): whole groups in one request,
/// or one group too large for a request, sent as consecutive requests cut
/// at entry boundaries.
struct PageUnit: Sendable, Hashable {
    let groups: [PageGroup]
    /// The entries of each request, in order.
    let requests: [[PageEntry]]

    var runIDs: [Int] {
        groups.flatMap { $0.runs.map(\.id) }
    }
}

/// A translated text to write into the page: the run's number and its text.
public struct PageWrite: Sendable, Hashable {
    public let id: Int
    public let text: String

    public init(id: Int, text: String) {
        self.id = id
        self.text = text
    }
}

/// The pure steps of page translation (RD16 decision 5): groups, pieces,
/// packing, joins and the cache key.
enum PageBatcher {
    /// The most entries one request carries (spec N06).
    static let maximumEntries = 40
    /// The most characters (Swift `Character`s, as RD14 counts) one request
    /// carries.
    static let maximumCharacters = 4_000
    /// A run longer than this, in UTF-16 code units, is never sent (the
    /// script does not return one).
    static let maximumRunUnits = 20_000

    // MARK: - Groups

    /// The runs grouped by block, in collection order: a group is placed
    /// where its block's first run comes, and its runs keep their order.
    static func groups(_ runs: [PageRun]) -> [PageGroup] {
        var order: [Int] = []
        var byBlock: [Int: [PageRun]] = [:]
        for run in runs {
            if byBlock[run.block] == nil {
                order.append(run.block)
            }
            byBlock[run.block, default: []].append(run)
        }
        return order.map { PageGroup(block: $0, runs: byBlock[$0] ?? []) }
    }

    // MARK: - Pieces

    /// Sentence ends after which a long run may be cut: an ideographic end
    /// cuts after itself; a Latin one only when white space follows.
    private static let ideographicEnds: Set<Character> = ["。", "！", "？"]
    private static let latinEnds: Set<Character> = [".", "!", "?"]

    /// `text` cut into consecutive pieces of at most `limit` characters
    /// (decision 5): each ends at the last sentence end within the limit,
    /// else at the last white space before it, else at the limit. White
    /// space at a cut is dropped. A text within the limit is one piece.
    static func pieces(of text: String, limit: Int = maximumCharacters) -> [String] {
        guard text.count > limit else { return [text] }
        var pieces: [String] = []
        var rest = Substring(text)
        while rest.count > limit {
            let window = rest.prefix(limit)
            var cut: Substring.Index?
            // The last sentence end in the window. The window is a prefix
            // of `rest`, so the character after it is `rest`'s.
            var index = window.endIndex
            while index > window.startIndex {
                let previous = window.index(before: index)
                let character = window[previous]
                if ideographicEnds.contains(character) {
                    cut = index
                    break
                }
                if latinEnds.contains(character) {
                    let next: Character? = index < rest.endIndex ? rest[index] : nil
                    if next?.isWhitespace ?? true {
                        cut = index
                        break
                    }
                }
                index = previous
            }
            // Else the last white space before the limit.
            if cut == nil, let space = window.lastIndex(where: \.isWhitespace), space > window.startIndex {
                cut = space
            }
            let end = cut ?? window.endIndex
            let piece = rest[..<end].trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty {
                pieces.append(piece)
            }
            rest = rest[end...].drop(while: \.isWhitespace)
        }
        if !rest.isEmpty {
            pieces.append(String(rest))
        }
        return pieces
    }

    /// A group's entries: each run's pieces, in order.
    static func entries(of group: PageGroup) -> [PageEntry] {
        group.runs.flatMap { run in
            pieces(of: run.text).map { PageEntry(run: run.id, text: $0) }
        }
    }

    /// The translations of a run's pieces joined (decision 5): no separator
    /// for Chinese and Japanese, one space for English.
    static func join(_ translations: [String], into locale: ReadingLocale) -> String {
        translations.joined(separator: locale == .english ? " " : "")
    }

    // MARK: - Packing

    static func characters(_ entries: [PageEntry]) -> Int {
        entries.reduce(0) { $0 + $1.text.count }
    }

    /// The next unit from `groups`, in order, and the groups left: whole
    /// groups while the request stays within the bounds; a first group that
    /// alone exceeds a bound is a unit of its own, cut at entry boundaries
    /// into consecutive requests. `nil` when `groups` is empty.
    static func nextUnit(
        from groups: [PageGroup], maximumEntries: Int = maximumEntries, maximumCharacters: Int = maximumCharacters
    ) -> (unit: PageUnit, rest: [PageGroup])? {
        guard let first = groups.first else { return nil }
        let firstEntries = entries(of: first)
        if firstEntries.count > maximumEntries || characters(firstEntries) > maximumCharacters {
            var requests: [[PageEntry]] = []
            var current: [PageEntry] = []
            var count = 0
            for entry in firstEntries {
                if !current.isEmpty, current.count + 1 > maximumEntries || count + entry.text.count > maximumCharacters {
                    requests.append(current)
                    current = []
                    count = 0
                }
                current.append(entry)
                count += entry.text.count
            }
            if !current.isEmpty {
                requests.append(current)
            }
            return (PageUnit(groups: [first], requests: requests), Array(groups.dropFirst()))
        }
        var taken: [PageGroup] = [first]
        var request = firstEntries
        var count = characters(firstEntries)
        for group in groups.dropFirst() {
            let more = entries(of: group)
            let moreCount = characters(more)
            guard request.count + more.count <= maximumEntries, count + moreCount <= maximumCharacters else { break }
            taken.append(group)
            request += more
            count += moreCount
        }
        return (PageUnit(groups: taken, requests: [request]), Array(groups.dropFirst(taken.count)))
    }

    /// Every unit of `groups`, in order.
    static func units(_ groups: [PageGroup]) -> [PageUnit] {
        var units: [PageUnit] = []
        var rest = groups
        while let (unit, left) = nextUnit(from: rest) {
            units.append(unit)
            rest = left
        }
        return units
    }

    // MARK: - The cache key (decision 7)

    /// The lower-case hex SHA-256 of the UTF-8 of the lower-cased host, a
    /// NUL and the normalised text; `nil` without a host.
    static func cacheKey(host: String?, text: String) -> String? {
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data((host + "\u{0}" + text).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
