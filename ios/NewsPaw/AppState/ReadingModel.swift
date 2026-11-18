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

/// The body of an open article, as the reading screen shows it (RD11
/// decision 7; RD12 decision 4).
enum ReadingBody {
    /// Being read and converted.
    case loading
    /// The article's page is being fetched and extracted: "Loading the
    /// full text…" under the header, and below it the feed's content, or
    /// nothing under "Always fetch the page".
    case fetching(ReadingContent?)
    case loaded(ReadingContent)
    /// It could not be read from the library.
    case failed
}

/// The article lists, read state and stars for the app (spec N05; RD09):
/// the model of each shown list, the filter chosen for each list, the
/// articles opened and their bodies, the thumbnail loader and the body image
/// loader, and the serial queue through which every list read and state
/// change goes. At app level beside the category, source and refresh models.
@MainActor @Observable
final class ReadingModel {
    /// The articles the reading screen shows, by identifier.
    private(set) var articles: [UUID: OpenArticle] = [:]
    /// The bodies of the open articles, one per stack at most (RD11
    /// decision 7). Derived each time an article is opened, never stored.
    private(set) var bodies: [UUID: ReadingBody] = [:]
    /// "Mark All as Read" waiting for its answer.
    var pendingMarkAll: MarkAllRequest?
    /// Whether the rows of the lists show thumbnails: the library's "Show
    /// Thumbnails in Lists" (RD19 decision 6), read at the workspace's
    /// load and changed only after it was stored. Off, a row asks for no
    /// thumbnail and draws none.
    private(set) var showsThumbnails = true

    /// The thumbnails of list rows: the app's transport and this library's
    /// cache.
    let loader: ThumbnailLoader
    /// The images of article bodies: the same transport and the same cache.
    let bodyImages: BodyImageLoader
    let library: Library
    /// The rows a list page holds: the library's page size. The UI tests
    /// lower it in a debug build, so that the next page is a few rows away.
    @ObservationIgnored var pageSize = Library.articlePageSize
    /// The reading language whose stored translations the rows carry (RD14
    /// decision 11), read at each list or article read; `nil` for a
    /// workspace without translation, whose rows show originals. Set by
    /// the workspace.
    @ObservationIgnored var translationLocale: @MainActor () -> ReadingLocale? = { nil }
    /// Told when an open article's body is settled (never the interim body
    /// shown while its page is fetched) and when it is let go: the body's
    /// translation plans and drops it (RD15 decision 15). Set by the
    /// workspace.
    @ObservationIgnored var onBodySettled: @MainActor (UUID, ReadingContent) -> Void = { _, _ in }
    @ObservationIgnored var onBodyDropped: @MainActor (UUID) -> Void = { _ in }

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
    /// The task reading and converting each open article's body.
    @ObservationIgnored private var bodyTasks: [UUID: Task<Void, Never>] = [:]
    /// Where the reader stands in each open article (RD11, review round
    /// 1): the block at the top of its screen, kept in memory beside the
    /// body and let go with it, never stored.
    @ObservationIgnored private var positions: [UUID: Int] = [:]
    /// How many times the body of each open article was replaced by its
    /// page's (RD12): the reading screen then starts at the top.
    private(set) var replacements: [UUID: Int] = [:]
    /// Whether the workspace of this model was dropped (RD18 decision 4).
    @ObservationIgnored private(set) var isStopped = false
    /// The pause after typing before Search reads (RD25 decision 11).
    static let searchDelay = Duration.milliseconds(300)
    /// The pending read of what was typed into Search.
    @ObservationIgnored private var searchDebounce: Task<Void, Never>?
    #if DEBUG
    /// Set by the UI tests: the next search read fails before reaching
    /// storage (RD25: the failure state).
    @ObservationIgnored var failNextSearch = false
    #endif
    /// Fetches, extracts and keeps bodies from the articles' pages, and
    /// remembers the failures (RD12 decisions 5 and 6): this workspace's
    /// own, on its library, its transport and its extractor.
    @ObservationIgnored let pages: BodyLoader

    private struct SavedField: Hashable {
        var article: UUID
        var isStar: Bool
    }

    @ObservationIgnored private let navigation: NavigationModel
    @ObservationIgnored private let sources: SourceModel
    @ObservationIgnored private let refresh: RefreshModel

    /// - Parameters:
    ///   - extractor: the workspace's extractor, which reader mode in its
    ///     browser shares: one extraction at a time per workspace.
    ///   - isInFront: whether the app is in front, so that a failure while
    ///     it is not is not remembered.
    init(
        library: Library, transport: any Transport, extractor: any PageExtracting, now: @escaping @Sendable () -> Date,
        isInFront: @escaping @MainActor () -> Bool, navigation: NavigationModel, sources: SourceModel, refresh: RefreshModel
    ) {
        self.library = library
        self.navigation = navigation
        self.sources = sources
        self.refresh = refresh
        loader = ThumbnailLoader(transport: transport, cache: library.imageCache)
        bodyImages = BodyImageLoader(transport: transport, cache: library.imageCache)
        pages = BodyLoader(library: library, transport: transport, extractor: extractor, now: now, isInFront: isInFront)
        // After the lists are read again an open article may be gone: its
        // source deleted, or removed by the retention clean-up (RD11
        // decision 15).
        sources.onReloaded = { [weak self] in self?.revalidateOpenArticles() }
    }

    // MARK: - Thumbnails (RD19 decision 6)

    /// Reads the library's "Show Thumbnails in Lists". A value that cannot
    /// be read counts as off in the adult partition, whose owner may have
    /// turned them off (review round 1), and leaves the one shown in the
    /// normal partition.
    func loadSettings() async {
        if let shows = try? await library.listThumbnails() {
            showsThumbnails = shows
        } else if library.partition == .adult {
            showsThumbnails = false
        }
    }

    /// Stores "Show Thumbnails in Lists" and then shows it.
    ///
    /// - Returns: whether it was stored; the switch then keeps the stored
    ///   value.
    func setShowsThumbnails(_ shows: Bool) async -> Bool {
        do {
            try await library.setListThumbnails(shows)
        } catch {
            return false
        }
        showsThumbnails = shows
        return true
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

    /// Reads every living list's first page again, and returns when all
    /// have been read: after a category was moved out of this library its
    /// articles leave the lists before the image cache is cleared (RD19
    /// decision 11).
    func reloadAllLists() async {
        let reads = lists.values.filter { $0.state != .notLoaded }.map { reload($0) }
        for read in reads {
            await read.value
        }
    }

    /// The source of the article `id`, as last known: opened, or a row of a
    /// list.
    func source(ofArticle id: UUID) -> UUID? {
        row(id)?.sourceID
    }

    /// Reads the list's first page afresh, in the queue.
    @discardableResult
    func reload(_ model: ArticleListModel) -> Task<Void, Never> {
        if model.kind == .search {
            return reloadSearch(model)
        }
        model.beginLoading()
        let library = library
        return enqueue {
            let scope = model.kind.scope
            let filter = model.filter
            do {
                let page = try await library.articleRows(
                    scope, filter: filter, limit: self.pageSize, translationsIn: self.translationLocale()
                )
                model.replace(with: page, pageSize: self.pageSize)
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
        if model.kind == .search {
            return loadNextSearchPage(model)
        }
        model.isReadingPage = true
        let library = library
        return enqueue {
            defer { model.isReadingPage = false }
            guard model.hasMore, let last = model.rows.last else { return }
            do {
                let page = try await library.articleRows(
                    model.kind.scope, filter: model.filter, after: last.position, limit: self.pageSize,
                    translationsIn: self.translationLocale()
                )
                model.append(page, pageSize: self.pageSize)
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

    // MARK: - Search (RD25 decision 11)

    /// Search is opened anew: its list is dropped, so that it starts empty.
    func dropSearch() {
        searchDebounce?.cancel()
        searchDebounce = nil
        lists[.search] = nil
    }

    /// The search field's text changed. An unchanged query (a trailing
    /// space) reads nothing; no query clears the rows at once; another
    /// query is read after a pause, unless the text changes again first.
    /// Typing never waits for the database.
    func setSearchText(_ text: String) {
        let model = list(.search)
        model.text = text
        let query = SearchQuery(text)
        guard query != model.query else {
            searchDebounce?.cancel()
            searchDebounce = nil
            return
        }
        searchDebounce?.cancel()
        guard let query else {
            searchDebounce = nil
            model.clearQuery()
            return
        }
        searchDebounce = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDelay)
            guard let self, !Task.isCancelled else { return }
            self.search(query, in: model)
        }
    }

    /// Return in the search field: the text is read at once.
    func submitSearch() {
        let model = list(.search)
        searchDebounce?.cancel()
        searchDebounce = nil
        guard let query = SearchQuery(model.text) else {
            model.clearQuery()
            return
        }
        search(query, in: model)
    }

    /// Reads `query` for `model`, if it is still wanted: the workspace is
    /// not dropped, the model is still the Search list, and its text still
    /// gives the same query.
    private func search(_ query: SearchQuery, in model: ArticleListModel) {
        guard !isStopped, lists[.search] === model, SearchQuery(model.text) == query else { return }
        model.setQuery(query, text: model.text)
        reloadSearch(model)
    }

    /// Search's first page: none without a query (the prompt); otherwise a
    /// new generation of reads, which a later one supersedes before it
    /// touches the database and before it applies its page.
    @discardableResult
    private func reloadSearch(_ model: ArticleListModel) -> Task<Void, Never> {
        guard let query = model.query else {
            model.clearQuery()
            return Task {}
        }
        model.beginLoading()
        let read = model.reads.firstPage(of: query)
        let library = library
        return enqueue {
            guard model.reads.mayRead(read) else { return }
            do {
                #if DEBUG
                if self.failNextSearch {
                    self.failNextSearch = false
                    throw LibraryError.storage("The UI tests' failing search read")
                }
                #endif
                let page = try await library.articleRows(
                    .library, filter: .all, limit: self.pageSize, translationsIn: self.translationLocale(), matching: read.query
                )
                guard model.reads.mayApply(read), self.lists[.search] === model else { return }
                model.replace(with: page, pageSize: self.pageSize)
                model.searchResultsApplied()
                model.reads.didApply(read)
            } catch {
                guard model.reads.mayApply(read), self.lists[.search] === model else { return }
                model.readDidFail(.firstPage)
            }
        }
    }

    /// Search's next page, in the generation of the rows shown.
    private func loadNextSearchPage(_ model: ArticleListModel) -> Task<Void, Never> {
        guard let last = model.rows.last, let read = model.reads.page(after: last.position) else {
            return Task {}
        }
        model.isReadingPage = true
        let library = library
        return enqueue {
            defer { model.isReadingPage = false }
            guard model.reads.mayRead(read) else { return }
            do {
                let page = try await library.articleRows(
                    .library, filter: .all, after: read.cursor, limit: self.pageSize, translationsIn: self.translationLocale(),
                    matching: read.query
                )
                guard model.reads.mayApply(read), self.lists[.search] === model else { return }
                model.append(page, pageSize: self.pageSize)
                model.reads.didApply(read)
            } catch {
                guard model.reads.mayApply(read), self.lists[.search] === model else { return }
                model.readDidFail(.nextPage)
            }
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

    /// Opens the article `id` on `kind` as a tapped row does, after reading
    /// its row (an overview's highlight, RD23 decision 12): it is marked
    /// read; an article that no longer exists leaves the lists as a
    /// vanished row's does.
    func open(articleID id: UUID, on kind: ArticleListKind) {
        guard !isStopped else { return }
        let library = library
        enqueue {
            do {
                let row = try await library.article(id, translationsIn: self.translationLocale())
                guard !self.isStopped else { return }
                self.open(row, on: kind)
            } catch LibraryError.unknownArticle {
                self.articleVanished(id)
            } catch {
                // Not opened: the next tap tries again.
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
                self.articles[id] = .loaded(try await library.article(id, translationsIn: self.translationLocale()))
            } catch LibraryError.unknownArticle {
                self.articles[id] = .missing
            } catch {
                // Not shown as missing: it may load at the next look.
            }
        }
    }

    // MARK: - Bodies (RD11 decision 7)

    /// Reads and converts the body of the open article `row`, unless it is
    /// there already. A task of its own, outside the queue of list reads
    /// and state changes: the HTML is read cut to the converter's limit and
    /// converted off the main actor, outside any database read or write. A
    /// result whose article is no longer open is dropped, and so are the
    /// bodies of articles that are no longer open.
    func loadBody(of row: ArticleRow) {
        guard !isStopped else { return }
        let open = navigation.openArticles
        for id in bodies.keys where !open.contains(id) && id != row.id {
            dropBody(id)
        }
        guard bodies[row.id] == nil else { return }
        readBody(of: row)
    }

    /// "Try Again" after a body that could not be read.
    func retryBody(of row: ArticleRow) {
        guard !isStopped else { return }
        readBody(of: row)
    }

    /// The reading screen of `id` went away: its body is let go unless the
    /// article is still open (a container switch shows it again).
    func readingScreenClosed(_ id: UUID) {
        if !navigation.openArticles.contains(id) {
            dropBody(id)
        }
    }

    // MARK: - The reader's place in an open article

    /// The block that was at the top of the screen when the reading screen
    /// of the open article `id` was last on screen; `nil` when the screen
    /// reported none, and for an article whose body is not held. A reading
    /// screen built again for an article that stayed open starts there: in
    /// the reading pane after its page in the browser was closed, and
    /// after a switch between the tab and the pane structure. A position
    /// is not remembered from one opening to the next.
    func position(of id: UUID) -> Int? {
        positions[id]
    }

    /// The reading screen of `id` scrolled: `block` is now at its top, or
    /// the screen reports none.
    func readerMoved(to block: Int?, in id: UUID) {
        guard bodies[id] != nil else { return }
        positions[id] = block
        #if DEBUG
        lastReportedPosition = block
        #endif
    }

    #if DEBUG
    /// The block the reading screen last reported at its top, for the UI
    /// tests' report (RD15 criterion 7).
    @ObservationIgnored private(set) var lastReportedPosition: Int?
    #endif

    /// Reads and converts the feed's body, then follows the body plan
    /// (RD12 decision 4): the feed's content; or a usable stored
    /// extraction; or, unless a failure of the page is remembered, the
    /// page fetched and extracted while the loading line stands, and then
    /// the extraction or, on failure, the feed's content as RD11 shows it.
    private func readBody(of row: ArticleRow) {
        guard !isStopped else { return }
        let id = row.id
        bodyTasks[id]?.cancel()
        bodies[id] = .loading
        let library = library
        let images = bodyImages
        let baseURL = row.linkURL
        let excerpt = row.excerpt
        let summary = sources.summary(row.sourceID)
        bodyTasks[id] = Task {
            let mayLoad: @MainActor () -> Bool = { [weak self] in self.map { !$0.isStopped } ?? false }
            let converted: ReadingContent.Converted
            do {
                // One character more than the converter reads, so that it
                // knows whether the input was cut.
                let html = try await library.contentHTML(ofArticle: id, limit: ArticleBlocks.maximumInputCharacters + 1)
                converted = await ReadingContent.convert(html: html, excerpt: excerpt, baseURL: baseURL)
            } catch {
                self.settle(id, .failed)
                return
            }
            let feed = ReadingContent(converted, images: images, mayLoad: mayLoad)
            // A source not known here is shown as its feed gives it.
            let plan = BodyPlan.make(
                kind: summary?.kind ?? .feed, mode: summary?.bodyMode ?? .feed, feedIsFullText: converted.isFullText, link: baseURL
            )
            guard case .fetch(let showsFeedMeanwhile) = plan, let link = baseURL else {
                self.settle(id, .loaded(feed))
                return
            }
            if let stored = await self.pages.storedBody(ofArticle: id, feed: converted.blocks) {
                self.settle(id, .loaded(ReadingContent(extracted: stored, images: images, mayLoad: mayLoad)))
                return
            }
            guard !Task.isCancelled else { return }
            if self.pages.remembersFailure(ofArticle: id) {
                self.settle(id, .loaded(feed))
                return
            }
            guard self.show(id, .fetching(showsFeedMeanwhile ? feed : nil)) else { return }
            let outcome: BodyLoader.Outcome
            do {
                outcome = try await self.pages.load(article: id, link: link, feed: converted.blocks)
            } catch {
                // Cancelled: the article was left, or the workspace dropped.
                return
            }
            switch outcome {
            case .extracted(let body, _):
                guard self.settle(id, .loaded(ReadingContent(extracted: body, images: images, mayLoad: mayLoad))) else { return }
                self.positions[id] = nil
                self.replacements[id, default: 0] += 1
            case .failed, .articleGone:
                self.settle(id, .loaded(feed))
            }
        }
    }

    /// Shows `body` for the open article `id` while its task goes on;
    /// false, with nothing kept, when the task was cancelled or the article
    /// is no longer open.
    private func show(_ id: UUID, _ body: ReadingBody) -> Bool {
        // A cancelled task was replaced or dropped: what stands for the
        // article now is not its to change.
        guard !Task.isCancelled else { return false }
        guard navigation.openArticles.contains(id) else {
            // Not open at this moment: nothing is kept, so that opening
            // it again reads it again instead of waiting for a task that
            // has ended.
            bodyTasks[id]?.cancel()
            bodies[id] = nil
            bodyTasks[id] = nil
            positions[id] = nil
            onBodyDropped(id)
            return false
        }
        bodies[id] = body
        return true
    }

    /// Shows `body` for the open article `id` as its task's last word.
    @discardableResult
    private func settle(_ id: UUID, _ body: ReadingBody) -> Bool {
        guard show(id, body) else { return false }
        bodyTasks[id] = nil
        if case .loaded(let content) = body {
            onBodySettled(id, content)
        }
        return true
    }

    private func dropBody(_ id: UUID) {
        bodyTasks[id]?.cancel()
        bodyTasks[id] = nil
        bodies[id] = nil
        positions[id] = nil
        replacements[id] = nil
        onBodyDropped(id)
    }

    /// The app is leaving the front: a page load under way remembers no
    /// failure (RD12, post-implementation record).
    func appLeftFront() {
        pages.appLeftFront()
    }

    /// A source's settings were saved: the failures of pages are forgotten
    /// (RD12 decision 6), so that the next opening fetches again.
    func sourceSettingsSaved() {
        pages.forgetFailures()
    }

    /// Looks each open article up again; one that no longer exists becomes
    /// "This article is no longer available." (decision 15).
    private func revalidateOpenArticles() {
        guard !isStopped else { return }
        let library = library
        for id in navigation.openArticles {
            guard case .loaded = articles[id] else { continue }
            enqueue {
                do {
                    _ = try await library.article(id)
                } catch LibraryError.unknownArticle {
                    self.articleVanished(id)
                } catch {
                    // Shown as it is: it may be readable at the next look.
                }
            }
        }
    }

    /// The workspace is dropped (RD18 decision 4, as amended): the body
    /// reads, page fetches and extractions in flight are cancelled and their results
    /// dropped, and from here on no body is read, no body image is asked
    /// for or read from the cache, the image viewer does not open, and an
    /// article found gone closes nothing. List reads and state changes that
    /// are queued run into the closed library and fail, shown nowhere, as
    /// the source and category models' saves do.
    func stop() {
        isStopped = true
        // A search typed in this workspace reads nothing more (RD25).
        searchDebounce?.cancel()
        searchDebounce = nil
        // No page fetch, extraction or stored extraction starts from here
        // on (RD12 decision 8).
        pages.stop()
        for task in bodyTasks.values {
            task.cancel()
        }
        bodyTasks = [:]
        pendingMarkAll = nil
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

    /// The article no longer exists: it leaves the lists, the reading pane
    /// says so, and a reading screen pushed on a list (tab structure) is
    /// popped (RD11 decision 15).
    private func articleVanished(_ id: UUID) {
        for model in lists.values {
            model.remove(id)
        }
        articles[id] = .missing
        dropBody(id)
        if navigation.layout?.structure == .tabs, !isStopped {
            navigation.closeArticle(id)
        }
    }

    // MARK: - Translations (RD14 decision 11)

    /// The translator stored rows for `ids`: they are read in the reading
    /// language and applied where the rows stand, in every living list and
    /// to the open articles, through the queue, so that a list read begun
    /// before the store cannot land after it and undo it.
    func applyTranslations(of ids: Set<UUID>) {
        guard !isStopped, !ids.isEmpty else { return }
        let library = library
        enqueue {
            guard let locale = self.translationLocale(),
                  let stored = try? await library.translations(of: ids, locale: locale)
            else { return }
            for id in ids {
                self.applyTranslation(stored[id], to: id)
            }
        }
    }

    /// The reading language changed: the translations of the new one are
    /// read for the rows of every living list and every open article, and
    /// applied where the rows stand (none where there is none), so that no
    /// translation of the old one is shown. The lists are not read again:
    /// their rows past the first page and the reader's place stay. Through
    /// the queue, with the rows as they stand when it is this work's turn.
    func translationLocaleChanged() {
        guard !isStopped else { return }
        let library = library
        enqueue {
            var ids = Set<UUID>()
            for model in self.lists.values {
                ids.formUnion(model.rows.map(\.id))
            }
            for (id, article) in self.articles {
                if case .loaded = article {
                    ids.insert(id)
                }
            }
            guard !ids.isEmpty, let locale = self.translationLocale() else { return }
            // A failed read shows the originals rather than the old language.
            let stored = (try? await library.translations(of: ids, locale: locale)) ?? [:]
            for id in ids {
                self.applyTranslation(stored[id], to: id)
            }
        }
    }

    /// A slot changed and the library's failed rows were deleted with it:
    /// the rows that show a failure wait again.
    func failedTranslationsCleared() {
        enqueue {
            for model in self.lists.values {
                model.clearFailedTranslations()
            }
            for (id, article) in self.articles {
                if case .loaded(let row) = article, row.translation?.state == .failed {
                    self.applyTranslation(nil, to: id)
                }
            }
        }
    }

    private func applyTranslation(_ translation: StoredTranslation?, to id: UUID) {
        for model in lists.values {
            model.update(id, translation: translation)
        }
        if case .loaded(var row) = articles[id], row.translation != translation {
            row.translation = translation
            articles[id] = .loaded(row)
        }
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

    /// Whether `openNext` would open an article: there is a row after the
    /// open one, or a further page to read; when the open article is not in
    /// the snapshot, the first row.
    func hasNext(on kind: ArticleListKind) -> Bool {
        let model = list(kind)
        guard let open = navigation.openArticle(on: kind), let index = model.index(of: open) else {
            return !model.rows.isEmpty
        }
        return index + 1 < model.rows.count || model.hasMore
    }

    /// Whether `openPrevious` would open an article.
    func hasPrevious(on kind: ArticleListKind) -> Bool {
        let model = list(kind)
        guard let open = navigation.openArticle(on: kind), let index = model.index(of: open) else { return false }
        return index > 0
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
