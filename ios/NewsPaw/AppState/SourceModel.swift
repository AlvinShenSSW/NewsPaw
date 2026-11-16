import Foundation
import NewsPawKit

/// The sources of the library, their rows' expansion, Source settings and
/// every source operation (spec N03), at app level beside the category
/// model. What is typed in a sheet lives here, so a container switch cannot
/// lose it.
@MainActor @Observable
final class SourceModel {
    /// Every source, ordered by name.
    private(set) var summaries: [SourceSummary] = []
    private(set) var loadFailed = false
    /// The categories whose sources are shown. Kept in memory only:
    /// collapsed at launch.
    var expanded: Set<UUID> = []
    /// The Add source sheet's state while it is open.
    private(set) var addSource: AddSourceModel?
    /// The category chosen in the last successful Add source of this
    /// session.
    private(set) var lastUsedCategory: UUID?
    /// The OPML import in progress, from its file choice to its summary
    /// (RD08). One at a time.
    private(set) var opmlImport: OPMLImportModel?

    // Source settings draft.
    var draftName = ""
    var draftCategoryID: UUID?
    var draftPaused = false
    var draftAutoTranslate = AutoTranslate.inherit
    var draftBodyMode = BodyMode.auto
    var draftTranslatePage = false
    /// The source whose deletion is being confirmed.
    var pendingDeletion: SourceSummary?
    /// Whether "The change could not be saved." is shown. A stopped model
    /// never raises it, whoever asks: its own saves, the refresh model or
    /// the reading model of the same dropped workspace (RD18).
    var isShowingSaveError = false {
        didSet {
            if isStopped, isShowingSaveError {
                isShowingSaveError = false
            }
        }
    }

    /// Whether the workspace of this model was dropped.
    private(set) var isStopped = false

    let library: Library
    let transport: any Transport
    let candidateLimit: Duration
    private let navigation: NavigationModel
    private let categories: CategoryModel
    private let refresh: RefreshModel
    /// The last queued operation; each waits for the one before it.
    private var lastOperation: Task<Bool, Never>?
    private var queuedOperations = 0
    /// Raised by every read of the sources, so that a read that ends after
    /// a newer one has started is dropped (RD09).
    private var reloadToken = 0
    /// Called after the sources were read again: an article open on the
    /// reading screen may be gone with its source, or with the retention
    /// clean-up (RD11 decision 15). Set by the reading model.
    @ObservationIgnored var onReloaded: (@MainActor () -> Void)?

    #if DEBUG
    /// Set by the UI tests: the next source save fails before reaching
    /// storage.
    var failNextSave = false
    /// Set by the UI tests: "Import OPML" reads this fixture instead of
    /// presenting the file picker (RD08 decision 8).
    var opmlFixture: OPMLFixture?
    #endif

    init(
        library: Library, transport: any Transport, candidateLimit: Duration, navigation: NavigationModel,
        categories: CategoryModel, refresh: RefreshModel
    ) {
        self.library = library
        self.transport = transport
        self.candidateLimit = candidateLimit
        self.navigation = navigation
        self.categories = categories
        self.refresh = refresh
    }

    /// Sources being collected: a view of the refresh engine.
    var updating: Set<UUID> {
        refresh.engine.collecting
    }

    /// Whether a source save is queued or running.
    var isBusy: Bool {
        queuedOperations > 0
    }

    func summary(_ id: UUID) -> SourceSummary? {
        summaries.first { $0.id == id }
    }

    func sources(in category: UUID) -> [SourceSummary] {
        summaries.filter { $0.categoryID == category }
    }

    /// Unread articles in a category; a web page has none.
    func unreadCount(in category: UUID) -> Int {
        sources(in: category).filter(\.isFeedLike).reduce(0) { $0 + $1.unreadCount }
    }

    var totalUnread: Int {
        summaries.filter(\.isFeedLike).reduce(0) { $0 + $1.unreadCount }
    }

    /// Unread articles in a list's scope; Starred counts none.
    func unreadCount(of list: ArticleListKind) -> Int {
        switch list {
        case .allUnread: totalUnread
        case .category(let id): unreadCount(in: id)
        case .source(let id): summary(id)?.unreadCount ?? 0
        case .starred: 0
        }
    }

    /// Every article stored in a list's scope, read or not; `nil` for
    /// Starred, whose count the summaries do not hold.
    func articleCount(of list: ArticleListKind) -> Int? {
        switch list {
        case .allUnread: summaries.reduce(0) { $0 + $1.articleCount }
        case .category(let id): sources(in: id).reduce(0) { $0 + $1.articleCount }
        case .source(let id): summary(id)?.articleCount ?? 0
        case .starred: nil
        }
    }

    /// The categories that hold unread articles, in the owner's order, with
    /// their counts: Today's rows (RD09 decision 10).
    func categoriesWithUnread(_ categories: [CategorySummary]) -> [(category: LibraryCategory, unread: Int)] {
        categories.compactMap { summary in
            let unread = unreadCount(in: summary.id)
            return unread > 0 ? (summary.category, unread) : nil
        }
    }

    /// Whether the library has a feed-like source: Today's status line is
    /// shown only then.
    var hasFeedLikeSource: Bool {
        summaries.contains(where: \.isFeedLike)
    }

    /// The feed-like sources that are not paused and whose stored status is
    /// failing.
    var failingSources: [SourceSummary] {
        summaries.filter { summary in
            guard summary.isFeedLike, !summary.paused, case .failing = summary.status else { return false }
            return true
        }
    }

    /// Whether a refresh of `category` would collect anything: it has a
    /// source collected as a feed (a feed, a GitHub repository) that is not
    /// paused.
    func hasRefreshTarget(in category: UUID) -> Bool {
        sources(in: category).contains { $0.kind.isCollectedAsFeed && !$0.paused }
    }

    /// Whether a list's Refresh would collect anything: its category's or
    /// its source's targets, or the library's for All Unread and Starred.
    func hasRefreshTarget(for list: ArticleListKind) -> Bool {
        switch list {
        case .allUnread, .starred: summaries.contains { $0.kind.isCollectedAsFeed && !$0.paused }
        case .category(let id): hasRefreshTarget(in: id)
        case .source(let id): summary(id).map { $0.kind.isCollectedAsFeed && !$0.paused } ?? false
        }
    }

    /// Reads the sources from storage, with their counts. A read that ends
    /// after a newer one has started is dropped. A settings sheet open on a
    /// source that no longer exists closes, and so does that source's list
    /// (RD09 decision 19).
    func reload() async {
        reloadToken += 1
        let token = reloadToken
        do {
            let read = try await library.sourceSummaries()
            guard token == reloadToken else { return }
            summaries = read
            loadFailed = false
        } catch is CancellationError {
            // Not a failure to read: what is shown stays.
            return
        } catch {
            guard token == reloadToken else { return }
            summaries = []
            loadFailed = true
            return
        }
        if case .sourceSettings(let id) = navigation.sheet, summary(id) == nil {
            navigation.sheet = nil
        }
        navigation.sourcesChanged(existing: Set(summaries.map(\.id)))
        onReloaded?()
    }

    func toggleExpanded(_ category: UUID) {
        if expanded.contains(category) {
            expanded.remove(category)
        } else {
            expanded.insert(category)
        }
    }

    // MARK: - Add source

    /// Opens Add source, with `address` in its field when given (the
    /// browser's "Save This Page as a Source"). The category open in Library
    /// is chosen, else the last one used this session.
    func beginAddSource(address: String? = nil) {
        addSource?.cancel()
        let model = AddSourceModel(
            sources: self, categories: categories,
            preferredCategory: navigation.openCategory ?? lastUsedCategory
        )
        if let address {
            model.addressText = address
        }
        addSource = model
        navigation.sheet = .addSource
    }

    /// Add source closed, by Cancel, a dismissal or a save: the detection in
    /// flight is cancelled and the parsed candidates are released.
    func addSourceClosed() {
        addSource?.cancel()
        addSource = nil
        if opmlImport?.origin == .addSource {
            opmlImport?.cancel()
            opmlImport = nil
        }
        if navigation.sheet == .addSource {
            navigation.sheet = nil
        }
    }

    /// The workspace is dropped (RD18 decision 4): the detection in flight
    /// is cancelled and Add source's state, which holds this model, let
    /// go; from here on nothing this model does is shown.
    func stop() {
        isStopped = true
        isShowingSaveError = false
        pendingDeletion = nil
        addSource?.cancel()
        addSource = nil
        opmlImport?.cancel()
        opmlImport = nil
    }

    /// Saves what Add source chose. On success the sheet closes, the lists
    /// are read again and the category is expanded; on failure the sheet
    /// stays with its values and the alert is shown on it.
    func save(_ choice: AddSourceModel.Saving) async -> AddSourceModel.SaveResult {
        let created = LockedValue<Bool>(false)
        let duplicate = LockedValue<ExistingSource?>(nil)
        let ok = await perform { library in
            do {
                switch choice.kind {
                case .feed(let candidate):
                    try await library.addFeedSource(candidate, name: choice.name, categoryID: choice.categoryID)
                case .webPage(let address):
                    try await library.addWebPageSource(address: address, name: choice.name, categoryID: choice.categoryID)
                }
                created.value = true
            } catch LibraryError.duplicateAddress {
                duplicate.value = try await library.existingSource(atAddress: choice.address)
                throw LibraryError.duplicateAddress
            }
        } showingError: { error in
            error as? LibraryError != .duplicateAddress
        }
        if ok, created.value {
            lastUsedCategory = choice.categoryID
            expanded.insert(choice.categoryID)
            addSourceClosed()
            return .saved
        }
        if let existing = duplicate.value {
            return .duplicate(existing)
        }
        return .failed
    }

    /// "Show in Library": closes the sheet and shows the category expanded
    /// where the category list is.
    func showInLibrary(_ existing: ExistingSource) {
        expanded.insert(existing.categoryID)
        addSource?.cancel()
        addSource = nil
        navigation.closeSheetAndShowCategoryList()
    }

    /// "N sources failed": shows the category list with the failing
    /// sources' categories expanded.
    func showFailingSources() {
        expanded.formUnion(failingSources.map(\.categoryID))
        navigation.showCategoryList()
    }

    // MARK: - OPML import (RD08)

    /// "Import OPML" on `origin`: presents the file picker there. In a
    /// debug build under the UI tests a fixture is read instead.
    func beginOPMLImport(from origin: OPMLImportOrigin) {
        guard !isStopped else { return }
        opmlImport?.cancel()
        let model = OPMLImportModel(origin: origin, sources: self)
        opmlImport = model
        #if DEBUG
        if let opmlFixture, let url = try? opmlFixture.writeToTemporaryFile() {
            model.fileChosen(url)
            return
        }
        #endif
        model.isPickingFile = true
    }

    /// Whether `model` is still the import this workspace holds: a result
    /// for any other is dropped.
    func isCurrent(_ model: OPMLImportModel) -> Bool {
        !isStopped && opmlImport === model
    }

    /// The import ended: the picker was cancelled, the alert answered, or
    /// the preview or the summary closed. Leaving the summary starts the
    /// refresh the Today pull starts; from Add source it closes Add source
    /// too.
    func opmlImportEnded(_ model: OPMLImportModel) {
        guard opmlImport === model else { return }
        model.cancel()
        opmlImport = nil
        guard case .done = model.stage else { return }
        let refresh = refresh
        Task { await refresh.refresh(.library) }
        if model.origin == .addSource {
            addSourceClosed()
        }
    }

    /// Writes an import in the save queue. The lists are read again as soon
    /// as the write succeeds; a failure is the preview's to show, not the
    /// save alert's.
    func importOPML(_ document: OPMLDocument, outsideFeeds target: OPMLOutsideFeeds?)
        async -> Result<OPMLImportSummary, OPMLImportModel.Failure> {
        let summary = LockedValue<OPMLImportSummary?>(nil)
        let failure = LockedValue<OPMLImportModel.Failure>(.storage)
        let ok = await perform { library in
            do {
                summary.value = try await library.importOPML(document, outsideFeeds: target)
            } catch LibraryError.unknownCategory {
                failure.value = .categoryGone
                throw LibraryError.unknownCategory
            }
        } showingError: { _ in false }
        if ok, let summary = summary.value {
            return .success(summary)
        }
        return .failure(failure.value)
    }

    // MARK: - Source settings

    func beginSettings(_ id: UUID) {
        guard let summary = summary(id) else { return }
        draftName = summary.name
        draftCategoryID = summary.categoryID
        draftPaused = summary.paused
        draftAutoTranslate = summary.autoTranslate
        draftBodyMode = summary.bodyMode
        draftTranslatePage = summary.translatePage
        navigation.sheet = .sourceSettings(id)
    }

    var draftNameProblem: CategoryNameProblem? {
        Library.sourceNameProblem(draftName)
    }

    func cancelSettings() {
        if case .sourceSettings = navigation.sheet {
            navigation.sheet = nil
        }
    }

    /// Saves the settings draft: only the fields that changed. The sheet
    /// closes on success and stays with its values on failure.
    func saveSettings(_ id: UUID) async {
        guard let stored = summary(id), draftNameProblem == nil else { return }
        var changes = SourceChanges()
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name != stored.name {
            changes.name = name
        }
        if let category = draftCategoryID, category != stored.categoryID {
            changes.categoryID = category
        }
        if stored.isFeedLike {
            if draftPaused != stored.paused {
                changes.paused = draftPaused
            }
            if draftAutoTranslate != stored.autoTranslate {
                changes.autoTranslate = draftAutoTranslate
            }
            if draftBodyMode != stored.bodyMode {
                changes.bodyMode = draftBodyMode
            }
        } else if draftTranslatePage != stored.translatePage {
            changes.translatePage = draftTranslatePage
        }
        let finalChanges = changes
        let saved = await perform { library in
            if finalChanges != SourceChanges() {
                try await library.updateSource(id, finalChanges)
            }
        }
        if saved, navigation.sheet == .sourceSettings(id) {
            navigation.sheet = nil
        }
    }

    /// Pause or Resume from a row's menu.
    func setPaused(_ id: UUID, _ paused: Bool) {
        Task {
            _ = await perform { library in
                try await library.updateSource(id, SourceChanges(paused: paused))
            }
        }
    }

    func requestDeletion(_ id: UUID) {
        pendingDeletion = summary(id)
    }

    func delete(_ summary: SourceSummary) async {
        let id = summary.id
        let deleted = await perform { library in
            try await library.deleteSource(id)
        }
        if deleted, navigation.sheet == .sourceSettings(id) {
            navigation.sheet = nil
        }
    }

    /// "Update Now": collects the source once through the refresh engine,
    /// joining a run that already holds it; the status section then shows
    /// the stored result. A paused or web-page source is not collected (the
    /// engine's targets).
    func updateNow(_ id: UUID) async {
        // Not in the save queue: a fetch can take up to 20 seconds, and a
        // collection writes only the source's status columns, articles and
        // seen rows, never what an editor changes. A feed failure is stored
        // on the source; a storage failure shows the save alert.
        await refresh.refresh(.source(id))
    }

    // MARK: - Saving

    /// Runs `operation` after every operation queued before it, then reads
    /// both lists again. On failure the error is shown unless
    /// `showingError` says otherwise.
    private func perform(
        _ operation: @escaping @Sendable (Library) async throws -> Void,
        showingError: @escaping (any Error) -> Bool = { _ in true }
    ) async -> Bool {
        let previous = lastOperation
        let library = library
        queuedOperations += 1
        let task = Task { @MainActor in
            _ = await previous?.value
            defer { queuedOperations -= 1 }
            do {
                #if DEBUG
                if failNextSave {
                    failNextSave = false
                    throw LibraryError.storage("Simulated failure for a UI test")
                }
                #endif
                try await operation(library)
                await categories.reload()
                return true
            } catch {
                await categories.reload()
                if showingError(error) {
                    isShowingSaveError = true
                }
                return false
            }
        }
        lastOperation = task
        return await task.value
    }
}
