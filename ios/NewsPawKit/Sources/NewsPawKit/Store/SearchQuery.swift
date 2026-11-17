import Foundation
import GRDB

/// What the owner typed into the search field, as terms to look for in
/// article titles (spec N05; RD25 decisions 2 and 3). It has no syntax:
/// quotes, `*`, `%`, `_`, `\`, `NEAR`, `AND` and the like are characters
/// like any other, and the terms reach the database only as bound values.
public struct SearchQuery: Sendable, Hashable {
    /// The most characters of the trimmed text a query uses.
    public static let maximumCharacters = 100

    /// The folded terms, in typed order, without repeats. Never empty.
    public let terms: [String]

    /// The query of `text`: trimmed of white space and newlines (U+3000
    /// included), cut to its first `maximumCharacters` characters, split on
    /// white space, each part folded, empty and repeated parts dropped.
    /// `nil` when no term is left: white space only is no query.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let kept = String(trimmed.prefix(Self.maximumCharacters))
        var terms: [String] = []
        var seen = Set<String>()
        for part in kept.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            let term = Self.fold(String(part))
            guard !term.isEmpty, seen.insert(term).inserted else { continue }
            terms.append(term)
        }
        guard !terms.isEmpty else { return nil }
        self.terms = terms
    }

    /// The one folding of titles and terms (decision 3): case and width are
    /// folded (`APPLE`, `ａｐｐｌｅ` and `apple` are one; half-width katakana
    /// becomes full-width), then canonical composition. Diacritics are kept,
    /// so that `が` and `か` stay apart, and no script is converted. It does
    /// not depend on the device's locale.
    ///
    /// A change of these rules ships a migration that rebuilds
    /// `search_text`.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil).precomposedStringWithCanonicalMapping
    }

    // MARK: - The SQL function

    /// The name under which `fold` is registered on every connection of a
    /// library. The triggers of the search migration call it, so it is part
    /// of the schema: it never changes.
    static let foldFunctionName = "newspaw_search_fold"

    /// `fold` as the SQL function `newspaw_search_fold(text)`: one argument,
    /// pure; `NULL` in, `NULL` out. A value that is not text is folded as
    /// its text form, as SQLite would cast it.
    static func makeFoldFunction() -> DatabaseFunction {
        DatabaseFunction(foldFunctionName, argumentCount: 1, pure: true) { values in
            let value = values[0]
            guard !value.isNull else { return nil }
            if let text = String.fromDatabaseValue(value) {
                return fold(text)
            }
            return fold(value.description)
        }
    }
}

/// The bookkeeping of the search list's reads (RD25 decision 11), kept by
/// the search list's model: the reads of a query go through the reading
/// model's serial queue, which also carries other lists' reads and saves,
/// so a read that is no longer wanted must neither touch the database nor
/// apply its page.
///
/// Each first-page read asked for starts a new generation with its query.
/// A read carries its query, its generation and its cursor (`nil` for the
/// first page). A queued read asks `mayRead` before it touches the
/// database and `mayApply` after its read, and records its page with
/// `didApply`.
public struct SearchReads: Sendable {
    /// One read asked for.
    public struct Read: Sendable, Hashable {
        public let query: SearchQuery
        public let generation: Int
        /// The position after which the page starts; `nil` for the first
        /// page.
        public let cursor: ArticlePosition?
    }

    /// The generation of the latest first-page read asked for, or of the
    /// latest clearing.
    public private(set) var generation = 0
    /// The query of the current generation; `nil` after a clearing.
    public private(set) var query: SearchQuery?
    /// The cursors whose page has been applied in this generation.
    private var applied: Set<ArticlePosition?> = []

    public init() {}

    /// A first-page read of `query`: a new generation.
    public mutating func firstPage(of query: SearchQuery) -> Read {
        generation += 1
        self.query = query
        applied = []
        return Read(query: query, generation: generation, cursor: nil)
    }

    /// The read of the page after `cursor` in the current generation;
    /// `nil` when there is no query.
    public func page(after cursor: ArticlePosition) -> Read? {
        query.map { Read(query: $0, generation: generation, cursor: cursor) }
    }

    /// No query any more: every read asked for so far is superseded.
    public mutating func clear() {
        generation += 1
        query = nil
        applied = []
    }

    /// Whether `read` is still wanted: its generation and query are the
    /// current ones, and no page for its cursor has been applied in this
    /// generation.
    public func mayRead(_ read: Read) -> Bool {
        read.generation == generation && read.query == query && !applied.contains(read.cursor)
    }

    /// Whether the page `read` brought may be applied: the same question,
    /// asked again after the read.
    public func mayApply(_ read: Read) -> Bool {
        mayRead(read)
    }

    /// Records that the page of `read` was applied.
    public mutating func didApply(_ read: Read) {
        guard read.generation == generation else { return }
        applied.insert(read.cursor)
    }
}
