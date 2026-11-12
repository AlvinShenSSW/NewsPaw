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

    // Source settings draft.
    var draftName = ""
    var draftCategoryID: UUID?
    var draftPaused = false
    var draftAutoTranslate = AutoTranslate.inherit
    var draftBodyMode = BodyMode.auto
    var draftTranslatePage = false
    /// The source whose deletion is being confirmed.
    var pendingDeletion: SourceSummary?
    var isShowingSaveError = false

    let library: Library
    let transport: any Transport
    let candidateLimit: Duration
    private let navigation: NavigationModel
    private let categories: CategoryModel
    private let refresh: RefreshModel
    /// The last queued operation; each waits for the one before it.
    private var lastOperation: Task<Bool, Never>?
    private var queuedOperations = 0

    #if DEBUG
    /// Set by the UI tests: the next source save fails before reaching
    /// storage.
    var failNextSave = false
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
    /// feed that is not paused.
    func hasRefreshTarget(in category: UUID) -> Bool {
        sources(in: category).contains { $0.kind == .feed && !$0.paused }
    }

    /// Reads the sources from storage. A settings sheet open on a source
    /// that no longer exists closes.
    func reload() async {
        do {
            summaries = try await library.sourceSummaries()
            loadFailed = false
        } catch is CancellationError {
            // Not a failure to read: what is shown stays.
            return
        } catch {
            summaries = []
            loadFailed = true
            return
        }
        if case .sourceSettings(let id) = navigation.sheet, summary(id) == nil {
            navigation.sheet = nil
        }
    }

    func toggleExpanded(_ category: UUID) {
        if expanded.contains(category) {
            expanded.remove(category)
        } else {
            expanded.insert(category)
        }
    }

    // MARK: - Add source

    /// Opens Add source. The category open in Library is chosen, else the
    /// last one used this session.
    func beginAddSource() {
        addSource?.cancel()
        addSource = AddSourceModel(
            sources: self, categories: categories,
            preferredCategory: navigation.openCategory ?? lastUsedCategory
        )
        navigation.sheet = .addSource
    }

    /// Add source closed, by Cancel, a dismissal or a save: the detection in
    /// flight is cancelled and the parsed candidates are released.
    func addSourceClosed() {
        addSource?.cancel()
        addSource = nil
        if navigation.sheet == .addSource {
            navigation.sheet = nil
        }
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
