import Foundation
import GRDB
@testable import NewsPawKit
import Testing

/// One row of `search_text`.
struct SearchTextRow: Hashable, CustomStringConvertible {
    var article: String
    var locale: String
    var text: String

    var description: String { "\(article.prefix(8))|\(locale)|\(text)" }
}

/// What `search_text` must hold (RD25 decision 5), derived in Swift from
/// `article` and `translation`: a row per article with a title, and a row
/// per `done` translation with a title, each folded by `SearchQuery.fold`.
func derivedSearchText(_ db: Database) throws -> Set<SearchTextRow> {
    var rows = Set<SearchTextRow>()
    for row in try Row.fetchAll(db, sql: "SELECT id, title FROM article WHERE title IS NOT NULL") {
        rows.insert(SearchTextRow(article: row["id"], locale: "", text: SearchQuery.fold(row["title"])))
    }
    for row in try Row.fetchAll(db, sql: "SELECT article_id, locale, title FROM translation WHERE state = 'done' AND title IS NOT NULL") {
        rows.insert(SearchTextRow(article: row["article_id"], locale: row["locale"], text: SearchQuery.fold(row["title"])))
    }
    return rows
}

/// What `search_text` holds.
func storedSearchText(_ db: Database) throws -> [SearchTextRow] {
    try Row.fetchAll(db, sql: "SELECT article_id, locale, text FROM search_text").map { row in
        SearchTextRow(article: row["article_id"], locale: row["locale"], text: row["text"])
    }
}

/// The index invariant of RD25 criterion 3: `search_text` equals its
/// derivation from `article` and `translation`, row for row. Returns the
/// number of rows, so that a caller can also see the index is not empty.
@discardableResult
func expectSearchTextMatchesDerivation(
    _ library: Library, _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation
) async throws -> Int {
    let (stored, derived) = try await library.pool.read { db in (try storedSearchText(db), try derivedSearchText(db)) }
    let storedSet = Set(stored)
    #expect(stored.count == storedSet.count, "repeated rows in search_text", sourceLocation: sourceLocation)
    let missing = derived.subtracting(storedSet).map(\.description).sorted()
    let extra = storedSet.subtracting(derived).map(\.description).sorted()
    let message = "\(comment.map { "\($0.rawValue): " } ?? "")missing \(missing), extra \(extra)"
    #expect(storedSet == derived, Comment(rawValue: message), sourceLocation: sourceLocation)
    return stored.count
}

/// A library with one category and one source, articles written through
/// the record (the tests' insert path) a minute apart, newest last, and
/// translations written through RD14's `storeTranslations`.
final class SearchFixture: @unchecked Sendable {
    let directory: URL
    let clock: TestClock
    let store: LibraryStore
    let library: Library
    let category: UUID
    let source: UUID
    private var count = 0

    private init(directory: URL, clock: TestClock, store: LibraryStore, library: Library, category: UUID, source: UUID) {
        self.directory = directory
        self.clock = clock
        self.store = store
        self.library = library
        self.category = category
        self.source = source
    }

    static func make() async throws -> SearchFixture {
        let directory = try makeTemporaryDirectory()
        let clock = TestClock()
        let store = LibraryStore(directory: directory, cacheRoot: directory.appending(path: "Images"), now: clock.now)
        let library = try await store.openNormal()
        let category = try await library.createCategory(name: "News", icon: .newspaper)
        let source = Sample.source(in: category.id, url: "https://search.example.invalid/feed", name: "Search", at: clock.now())
        try await library.insert(source)
        return SearchFixture(directory: directory, clock: clock, store: store, library: library, category: category.id, source: source.id)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes an article with `title` through the record, a minute after
    /// the one before, so that later articles come first in the list order.
    @discardableResult
    func article(_ title: String?, in library: Library? = nil, source: UUID? = nil) async throws -> UUID {
        count += 1
        let date = clock.now().addingTimeInterval(TimeInterval(count * 60))
        var article = Sample.article(in: source ?? self.source, externalID: "search-\(count)", title: title ?? "", at: date)
        article.title = title
        try await (library ?? self.library).insert(article)
        return article.id
    }

    /// Stores a translation row through RD14's write.
    func translate(
        _ id: UUID, _ locale: ReadingLocale, _ state: TranslationState, title: String?, in library: Library? = nil
    ) async throws {
        try await (library ?? self.library).storeTranslations([
            TranslationRecord(
                articleID: id, locale: locale, state: state, title: title, excerpt: nil,
                failure: state == .failed ? .malformed : nil, model: state == .none ? nil : "fixture-model"
            ),
        ])
    }

    /// The titles of the first page `text` finds, in the list order.
    func search(_ text: String, locale: ReadingLocale? = .simplifiedChinese, in library: Library? = nil) async throws -> [String?] {
        guard let query = SearchQuery(text) else { return [] }
        return try await (library ?? self.library)
            .articleRows(.library, filter: .all, translationsIn: locale, matching: query).map(\.title)
    }
}
