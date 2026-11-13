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

    /// The rows on screen, from their appearing and disappearing.
    @ObservationIgnored private var visible: Set<UUID> = []
    /// Refreshes started from this list that have not ended.
    @ObservationIgnored var ownRefreshes = 0
    /// Whether a next page is being read.
    @ObservationIgnored var isReadingPage = false

    init(kind: ArticleListKind, filter: ArticleFilter) {
        self.kind = kind
        self.filter = filter
    }

    /// Whether the list's first row is on screen; an empty list counts as
    /// at its top.
    var isAtTop: Bool {
        guard let first = rows.first else { return true }
        return visible.contains(first.id)
    }

    func rowAppeared(_ id: UUID) {
        visible.insert(id)
    }

    func rowDisappeared(_ id: UUID) {
        visible.remove(id)
    }

    func index(of id: UUID) -> Int? {
        rows.firstIndex { $0.id == id }
    }

    // MARK: - Changes made by the reading model

    func setFilter(_ filter: ArticleFilter) {
        self.filter = filter
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

    /// The article no longer exists: its row leaves the list.
    func remove(_ id: UUID) {
        rows.removeAll { $0.id == id }
        visible.remove(id)
    }
}
