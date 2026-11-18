import Foundation
import NewsPawKit

/// One shown article list: a snapshot of its rows read in pages (RD09
/// decision 3). A row whose state changes is updated where it stands and
/// keeps its place until the list is read again. It lives in the reading
/// model, not in a view, so a container switch keeps it.
@MainActor @Observable
final class ArticleListModel {
    enum LoadState {
        /// Nothing read yet.
        case notLoaded
        /// The first read is in flight.
        case loading
        /// A snapshot is shown.
        case loaded
        /// The first read failed and nothing is shown.
        case failed
    }

    let kind: ArticleListKind
    /// The filter the snapshot was read with.
    private(set) var filter: ArticleFilter
    private(set) var rows: [ArticleRow] = []
    private(set) var state = LoadState.notLoaded
    /// Whether the last page read was full, so that another may follow.
    private(set) var hasMore = false
    /// Which read failed while rows were shown: the list then ends with
    /// "Could not load" and "Try Again" (failure table).
    enum FailedRead {
        case firstPage
        case nextPage
    }

    private(set) var failedRead: FailedRead?

    var readFailed: Bool {
        failedRead != nil
    }

    /// How far the list is scrolled from its top, in points: its content
    /// offset relative to its top inset, as the list's view reports it.
    @ObservationIgnored private var offsetFromTop = 0.0
    /// The height of the first row, as its view reports it; a usual row's
    /// until then.
    @ObservationIgnored private var firstRowHeight = 60.0
    /// Refreshes started from this list that have not ended.
    @ObservationIgnored var ownRefreshes = 0
    /// Whether a next page is being read.
    @ObservationIgnored var isReadingPage = false

    // MARK: Search (RD25 decision 11)

    /// What the search field shows. Search's list only; never stored.
    var text = ""
    /// What the rows were read for, or are being read for; `nil` with no
    /// query. Search's list only.
    var query: SearchQuery?
    /// The text as typed, trimmed, of the query whose rows are shown: the
    /// no-results sentence names it.
    private(set) var queryText = ""
    /// The same, of the query being read.
    @ObservationIgnored private var wantedText = ""
    /// The reads of `query`: superseded ones neither read nor apply.
    @ObservationIgnored var reads = SearchReads()
    /// The last of the navigation's focus requests the Search screen has
    /// acted on: a request is acted on once, also when the screen is built
    /// after it.
    @ObservationIgnored var handledFocusRequest = 0
    /// Whether the first page of the current query has been applied, so
    /// that an empty list means no match rather than not read yet.
    private(set) var hasResults = false

    init(kind: ArticleListKind, filter: ArticleFilter) {
        self.kind = kind
        self.filter = filter
    }

    /// Whether the list's first row is on screen (ux S3): the list is
    /// scrolled from its top by less than that row's height. Taken from the
    /// scroll position, not from the row's appear and disappear events,
    /// which SwiftUI sends at distances that differ between devices (RD11
    /// decision 15). An empty list is at its top.
    var isAtTop: Bool {
        rows.isEmpty || offsetFromTop < firstRowHeight
    }

    /// The list's view scrolled: its content offset relative to its top
    /// inset.
    func scrolled(toOffsetFromTop offset: Double) {
        offsetFromTop = offset
    }

    func firstRowMeasured(height: Double) {
        if height > 0 {
            firstRowHeight = height
        }
    }

    func index(of id: UUID) -> Int? {
        rows.firstIndex { $0.id == id }
    }

    // MARK: - Changes made by the reading model

    func setFilter(_ filter: ArticleFilter) {
        self.filter = filter
    }

    /// A query is wanted (RD25): the rows stay until its first page
    /// replaces them.
    func setQuery(_ query: SearchQuery, text: String) {
        self.query = query
        wantedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// No query: no rows, no read wanted; the prompt is shown.
    func clearQuery() {
        query = nil
        queryText = ""
        wantedText = ""
        reads.clear()
        rows = []
        hasMore = false
        hasResults = false
        failedRead = nil
        state = .loaded
    }

    /// The first page of the current query replaced the rows.
    func searchResultsApplied() {
        hasResults = true
        queryText = wantedText
    }

    func beginLoading() {
        if state == .notLoaded || state == .failed {
            state = .loading
        }
    }

    /// A first page read afresh replaces the snapshot.
    func replace(with page: [ArticleRow], pageSize: Int) {
        rows = page
        hasMore = page.count == pageSize
        state = .loaded
        failedRead = nil
    }

    /// A later page continues it; a row already listed is not repeated.
    func append(_ page: [ArticleRow], pageSize: Int) {
        let listed = Set(rows.map(\.id))
        rows += page.filter { !listed.contains($0.id) }
        hasMore = page.count == pageSize
        failedRead = nil
    }

    /// A read failed: the rows already shown stay.
    func readDidFail(_ read: FailedRead) {
        if rows.isEmpty, state != .loaded {
            state = .failed
        } else {
            failedRead = read
        }
    }

    /// "Try Again" was chosen: the failure is cleared before the read.
    func clearFailure() {
        failedRead = nil
    }

    /// Applies a stored or optimistic state to the row of `id`, where it
    /// stands.
    func update(_ id: UUID, read: Bool? = nil, starred: Bool? = nil) {
        guard let index = index(of: id) else { return }
        if let read {
            rows[index].isRead = read
        }
        if let starred {
            rows[index].isStarred = starred
        }
    }

    /// Applies a stored translation to the row of `id`, where it stands
    /// (RD14 decision 11).
    func update(_ id: UUID, translation: StoredTranslation?) {
        guard let index = index(of: id), rows[index].translation != translation else { return }
        rows[index].translation = translation
    }

    /// The library's failed translations were deleted: those rows wait
    /// again.
    func clearFailedTranslations() {
        for index in rows.indices where rows[index].translation?.state == .failed {
            rows[index].translation = nil
        }
    }

    /// The article no longer exists: its row leaves the list.
    func remove(_ id: UUID) {
        rows.removeAll { $0.id == id }
    }
}
