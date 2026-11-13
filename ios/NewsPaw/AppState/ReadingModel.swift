import Foundation
import NewsPawKit

/// "Mark All as Read" waiting for its answer (RD09 decision 7): the scope,
/// the moment it was asked and the number of unread articles first seen up
/// to it.
struct MarkAllRequest: Identifiable {
    let scope: ArticleScope
    let moment: Date
    let count: Int
    let id = UUID()
}

/// What the reading screen shows for an article.
enum OpenArticle {
    case loaded(ArticleRow)
    /// Its source was deleted, or clean-up removed it.
    case missing
}

/// The article lists, read state and stars for the app (spec N05; RD09):
/// the model of each shown list, the filter chosen for each list, the
/// articles opened, the one thumbnail loader, and the serial queue through
/// which every list read and state change goes. At app level beside the
/// category, source and refresh models.
@MainActor @Observable
final class ReadingModel {
    /// The articles the reading screen shows, by identifier.
    private(set) var articles: [UUID: OpenArticle] = [:]
    /// "Mark All as Read" waiting for its answer.
    var pendingMarkAll: MarkAllRequest?

    /// The thumbnails of list rows: the app's transport and this library's
    /// cache.
    let loader: ThumbnailLoader
    let library: Library

    /// The model of each list shown: the Library side's current list and
    /// Starred. Created when a view asks for it, so not observed.
    @ObservationIgnored private var lists: [ArticleListKind: ArticleListModel] = [:]
    /// The filter chosen for each category and source list, until the app
    /// is closed.
    @ObservationIgnored private var filters: [ArticleListKind: ArticleFilter] = [:]
    /// The last queued list read or state change; each waits for the one
    /// before it, so a read begun before a change cannot land after it.
    @ObservationIgnored private var lastOperation: Task<Void, Never>?
    /// How many saves of each article's read state or star are queued or
    /// running: an earlier save does not show its state over a later one's.
    @ObservationIgnored private var queuedSaves: [SavedField: Int] = [:]

    private struct SavedField: Hashable {
        var article: UUID
        var isStar: Bool
    }

    @ObservationIgnored private let navigation: NavigationModel
    @ObservationIgnored private let sources: SourceModel
    @ObservationIgnored private let refresh: RefreshModel

    init(library: Library, transport: any Transport, navigation: NavigationModel, sources: SourceModel, refresh: RefreshModel) {
        self.library = library
        self.navigation = navigation
        self.sources = sources
        self.refresh = refresh
        loader = ThumbnailLoader(transport: transport, cache: library.imageCache)
    }

    // MARK: - Lists

    /// The model of `kind`, made when first asked for.
    func list(_ kind: ArticleListKind) -> ArticleListModel {
        if let model = lists[kind] {
            return model
        }
        let model = ArticleListModel(kind: kind, filter: filter(of: kind))
        lists[kind] = model
        return model
    }

    /// The filter of `kind`: the one chosen this session, else Unread for a
    /// list with the control.
    func filter(of kind: ArticleListKind) -> ArticleFilter {
        kind.hasFilter ? filters[kind] ?? .unread : kind.fixedFilter
    }

    /// The list's view appeared: a list never read is read now. Returning
    /// to it, or a container switch, reads nothing.
    func appeared(_ kind: ArticleListKind) {
        let model = list(kind)
        if model.state == .notLoaded {
            reload(model)
        }
    }

    /// A list was entered (decision 3): it is read again. Another Library
    /// list's snapshot is let go; Starred's is kept.
    func entered(_ kind: ArticleListKind) {
        if kind != .starred {
            for other in lists.keys where other != kind && other != .starred {
                lists[other] = nil
            }
        }
        reload(list(kind))
    }

    /// A different filter: remembered for the list and read at once.
    func setFilter(_ filter: ArticleFilter, of kind: ArticleListKind) {
        guard kind.hasFilter else { return }
        filters[kind] = filter
        let model = list(kind)
        guard model.filter != filter else { return }
        model.setFilter(filter)
        reload(model)
    }

    /// A refresh run ended. A list whose first row is on screen is read
    /// again, unless it started the run itself (it reads itself after).
    func runEnded() {
        for model in lists.values where model.isAtTop && model.ownRefreshes == 0 && model.state != .notLoaded {
            // In the tab structure a list with its article pushed on it is
            // not on screen, whatever its rows' appearance said.
            if navigation.layout?.structure == .tabs, navigation.openArticle(on: model.kind) != nil {
                continue
            }
            reload(model)
        }
    }

    /// A pull, the toolbar's Refresh or `R`: collects the list's scope,
    /// then reads the list again. Returns when both have ended.
    func refresh(_ kind: ArticleListKind) async {
        let model = list(kind)
        model.ownRefreshes += 1
        await refresh.refresh(kind.refreshScope)
        model.ownRefreshes -= 1
        await reload(model).value
    }

    /// Reads the list's first page afresh, in the queue.
    @discardableResult
    func reload(_ model: ArticleListModel) -> Task<Void, Never> {
        model.beginLoading()
        let library = library
        return enqueue {
            let scope = model.kind.scope
            let filter = model.filter
            do {
                let page = try await library.articleRows(scope, filter: filter)
                model.replace(with: page, pageSize: Library.articlePageSize)
            } catch {
                model.readDidFail(.firstPage)
            }
        }
    }

    /// Reads the page after the last row, in the queue.
    @discardableResult
    func loadNextPage(_ model: ArticleListModel) -> Task<Void, Never> {
        guard model.hasMore, !model.isReadingPage, !model.readFailed else {
            return Task {}
        }
        model.isReadingPage = true
        let library = library
        return enqueue {
            defer { model.isReadingPage = false }
            guard model.hasMore, let last = model.rows.last else { return }
            do {
                let page = try await library.articleRows(model.kind.scope, filter: model.filter, after: last.position)
                model.append(page, pageSize: Library.articlePageSize)
            } catch {
                model.readDidFail(.nextPage)
            }
        }
    }

    /// "Try Again" after a failed read: the read that failed again.
    func retry(_ model: ArticleListModel) {
        let failed = model.failedRead
        model.clearFailure()
        if model.rows.isEmpty || failed == .firstPage {
            reload(model)
        } else {
            loadNextPage(model)
        }
    }

    // MARK: - Opening

    /// Opens the row's article on `kind` and marks it read (decision 4).
    func open(_ row: ArticleRow, on kind: ArticleListKind) {
        articles[row.id] = .loaded(row)
        navigation.openArticle(row.id, on: kind)
        if !row.isRead {
            setRead(row.id, true)
        } else {
            // Nothing is saved for a row already read, so nothing else would
            // find that its article is gone since the list was read
            // (retention, a deleted source).
            let id = row.id
            let library = library
            enqueue {
                do {
                    _ = try await library.article(id)
                } catch LibraryError.unknownArticle {
                    self.articleVanished(id)
                } catch {
                    // Shown from its row: it may be readable at the next look.
                }
            }
        }
    }

    /// Reads the article for the reading screen when it was not opened from
    /// a row of this session.
    func loadArticle(_ id: UUID) {
        guard articles[id] == nil else { return }
        let library = library
        enqueue {
            do {
                self.articles[id] = .loaded(try await library.article(id))
            } catch LibraryError.unknownArticle {
                self.articles[id] = .missing
            } catch {
                // Not shown as missing: it may load at the next look.
            }
        }
    }

    // MARK: - Read state and stars

    func setRead(_ id: UUID, _ read: Bool) {
        change(id, read: read) { library in try await library.setRead(id, read) }
    }

    func setStarred(_ id: UUID, _ starred: Bool) {
        change(id, starred: starred) { library in try await library.setStarred(id, starred) }
    }

    /// Shows the change at once in every list and the reading screen, then
    /// saves it in the queue and reads the counts again. When it cannot be
    /// saved the rows return to the stored state and the alert is shown; an
    /// article that no longer exists leaves the lists without an alert.
    private func change(
        _ id: UUID, read: Bool? = nil, starred: Bool? = nil, _ operation: @escaping @Sendable (Library) async throws -> Void
    ) {
        apply(id, read: read, starred: starred)
        let field = SavedField(article: id, isStar: starred != nil)
        queuedSaves[field, default: 0] += 1
        let library = library
        enqueue {
            do {
                try await operation(library)
                // A list read queued before the change may have landed after
                // the optimistic update with the old state, so the saved
                // state is shown again; not over a later change of the same
                // state, which is shown already and whose own save follows.
                if self.saveEnded(field) {
                    self.apply(id, read: read, starred: starred)
                }
            } catch LibraryError.unknownArticle {
                self.saveEnded(field)
                self.articleVanished(id)
            } catch {
                self.saveEnded(field)
                if let stored = try? await library.article(id) {
                    self.apply(id, read: stored.isRead, starred: stored.isStarred)
                } else {
                    self.apply(id, read: read.map(!), starred: starred.map(!))
                }
                self.sources.isShowingSaveError = true
            }
            await self.sources.reload()
        }
    }

    /// Counts one save of `field` as ended; whether none is queued after it.
    @discardableResult
    private func saveEnded(_ field: SavedField) -> Bool {
        let left = queuedSaves[field, default: 1] - 1
        queuedSaves[field] = left > 0 ? left : nil
        return left <= 0
    }

    private func apply(_ id: UUID, read: Bool?, starred: Bool?) {
        for model in lists.values {
            model.update(id, read: read, starred: starred)
        }
        if case .loaded(var row) = articles[id] {
            if let read {
                row.isRead = read
            }
            if let starred {
                row.isStarred = starred
            }
            articles[id] = .loaded(row)
        }
    }

    private func articleVanished(_ id: UUID) {
        for model in lists.values {
            model.remove(id)
        }
        articles[id] = .missing
    }

    // MARK: - Mark all as read

    /// Asks before marking: reads how many unread articles the scope holds
    /// up to this moment, and asks when there is at least one.
    func askMarkAllRead(_ scope: ArticleScope) {
        let moment = refresh.now()
        let library = library
        enqueue {
            do {
                let count = try await library.unreadCount(in: scope, firstSeenThrough: moment)
                if count > 0 {
                    self.pendingMarkAll = MarkAllRequest(scope: scope, moment: moment, count: count)
                }
            } catch {
                self.sources.isShowingSaveError = true
            }
        }
    }

    /// Marks what the question counted, in one transaction, then shows the
    /// rows of the scope read where they stand.
    func confirmMarkAllRead(_ request: MarkAllRequest) {
        pendingMarkAll = nil
        let library = library
        enqueue {
            do {
                try await library.markAllRead(in: request.scope, firstSeenThrough: request.moment)
                for model in self.lists.values {
                    for row in model.rows where !row.isRead && row.firstSeenAt <= request.moment && self.contains(request.scope, row) {
                        model.update(row.id, read: true)
                    }
                }
                for (id, article) in self.articles {
                    if case .loaded(let row) = article, !row.isRead, row.firstSeenAt <= request.moment, self.contains(request.scope, row) {
                        self.apply(id, read: true, starred: nil)
                    }
                }
            } catch {
                self.sources.isShowingSaveError = true
            }
            await self.sources.reload()
        }
    }

    private func contains(_ scope: ArticleScope, _ row: ArticleRow) -> Bool {
        switch scope {
        case .library: true
        case .starred: row.isStarred
        case .source(let id): row.sourceID == id
        case .category(let id): sources.summary(row.sourceID)?.categoryID == id
        }
    }

    // MARK: - Keyboard (decision 15)

    /// Whether a shortcut key of `list` may act now: only while the tab
    /// that holds the list is selected (Starred for Starred, Library for the
    /// others), and not while a sheet, the slide-over or the "Mark All as
    /// Read" question is open.
    func keysMayAct(on list: ArticleListKind) -> Bool {
        let tab: AppTab = list == .starred ? .starred : .library
        return navigation.currentTab == tab && navigation.sheet == nil && pendingMarkAll == nil && !navigation.isSlideOverOpen
    }

    /// `J`: the next article of the list. With nothing open, or the open
    /// article no longer in the snapshot, the first row; at the last loaded
    /// row, the first row of the next page.
    func openNext(on kind: ArticleListKind) async {
        let model = list(kind)
        guard let open = navigation.openArticle(on: kind), let index = model.index(of: open) else {
            if let first = model.rows.first {
                self.open(first, on: kind)
            }
            return
        }
        if index + 1 < model.rows.count {
            self.open(model.rows[index + 1], on: kind)
        } else if model.hasMore {
            await loadNextPage(model).value
            if index + 1 < model.rows.count {
                self.open(model.rows[index + 1], on: kind)
            }
        }
    }

    /// `K`: the previous article; nothing at the first row.
    func openPrevious(on kind: ArticleListKind) {
        let model = list(kind)
        guard let open = navigation.openArticle(on: kind), let index = model.index(of: open), index > 0 else { return }
        self.open(model.rows[index - 1], on: kind)
    }

    /// `S`: stars or unstars the open article; nothing when none is open.
    func toggleStarOfOpenArticle(on kind: ArticleListKind) {
        guard let id = navigation.openArticle(on: kind), let row = row(id) else { return }
        setStarred(id, !row.isStarred)
    }

    /// `U`: marks the open article read or unread; nothing when none is
    /// open.
    func toggleReadOfOpenArticle(on kind: ArticleListKind) {
        guard let id = navigation.openArticle(on: kind), let row = row(id) else { return }
        setRead(id, !row.isRead)
    }

    /// The article as last known: opened, or a row of a list.
    func row(_ id: UUID) -> ArticleRow? {
        if case .loaded(let row) = articles[id] {
            return row
        }
        for model in lists.values {
            if let index = model.index(of: id) {
                return model.rows[index]
            }
        }
        return nil
    }

    // MARK: - Queue

    /// Runs `operation` after every operation queued before it.
    @discardableResult
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = lastOperation
        let task = Task { @MainActor in
            _ = await previous?.value
            await operation()
        }
        lastOperation = task
        return task
    }
}
