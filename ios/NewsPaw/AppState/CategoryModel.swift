import Foundation
import NewsPawKit
import Synchronization

/// A category sheet presented from the root.
enum CategorySheet: Hashable, Identifiable {
    case newCategory
    case settings(UUID)

    var id: Self { self }
}

/// Where an alert or dialog about categories or sources is attached: the root, the
/// slide-over sidebar's content, or the open sheet's content. Only the
/// frontmost host presents, so a dialog never closes a sheet or waits behind
/// the slide-over.
enum CategoryDialogHost {
    case root
    case slideOver
    case sheet
}

/// What moving a category to the other partition needs (RD19 decision 11),
/// given by the app model to the adult workspace's category model only: it
/// holds the normal library and the adult one.
struct CategoryMover {
    /// Reads what moving the category out of the library of `from` would
    /// do; `nil` when it cannot be read or the category is gone.
    let plan: @MainActor (_ category: UUID, _ from: Partition) async -> CategoryMove.Plan?
    /// Runs the move, lets the old workspace go of what it moved, clears
    /// the old image cache and reads both workspaces again.
    let run: @MainActor (CategoryMove.Plan) async -> CategoryMove.Outcome
}

/// What a move has to say (RD19 decision 11), as an alert with OK.
enum MoveMessage: Identifiable, Equatable {
    /// Every source of the category is in the destination already.
    case nothingToMove(name: String, to: Partition)
    /// Nothing was changed.
    case notMoved
    /// The copy was made and the old category could not be removed.
    case copiedNotRemoved(name: String, to: Partition)

    var id: String {
        switch self {
        case .nothingToMove(let name, let to): "nothing.\(to.rawValue).\(name)"
        case .notMoved: "notMoved"
        case .copiedNotRemoved(let name, let to): "copied.\(to.rawValue).\(name)"
        }
    }
}

/// The category list and every category operation (spec N02), at app level
/// so that one model writes categories. What is typed in a sheet lives here,
/// so a container switch cannot lose it.
@MainActor @Observable
final class CategoryModel {
    enum LoadState {
        case loading
        case loaded
        case failed
    }

    /// Every category in storage, a category awaiting deletion included.
    private(set) var summaries: [CategorySummary] = []
    /// The category whose row the list has taken away while its deletion is
    /// confirmed (edit mode or a swipe). It is still a category: titles and
    /// the empty state keep counting it until the deletion succeeds.
    private(set) var hiddenForDeletion: UUID?
    private(set) var loadState = LoadState.loading
    /// The category sheet: a view of the root's one sheet state.
    var sheet: CategorySheet? {
        get {
            switch navigation.sheet {
            case .newCategory: .newCategory
            case .categorySettings(let id): .settings(id)
            case .addSource, .sourceSettings, .configurationImport, nil: nil
            }
        }
        set {
            switch newValue {
            case .newCategory: navigation.sheet = .newCategory
            case .settings(let id): navigation.sheet = .categorySettings(id)
            case nil:
                if sheet != nil {
                    navigation.sheet = nil
                }
            }
        }
    }
    var draftName = ""
    var draftIcon = CategoryIcon.folder
    /// The category whose deletion is being confirmed.
    var pendingDeletion: CategorySummary?
    /// Whether "The change could not be saved." is shown. A stopped model
    /// never raises it: what a dropped workspace's task fails at, against
    /// its closed library, is shown nowhere (RD18).
    var isShowingSaveError = false {
        didSet {
            if isStopped, isShowingSaveError {
                isShowingSaveError = false
            }
        }
    }

    /// Whether the workspace of this model was dropped.
    private(set) var isStopped = false
    /// The move waiting for its confirmation (RD19 decision 11). Cleared
    /// by Cancel, by the alert's dismissal or by a lock, before its run has
    /// begun: the move's operation ends.
    var pendingMove: CategoryMove.Plan? {
        didSet {
            if pendingMove == nil, !isMoving {
                endMove()
            }
        }
    }
    /// What the last move has to say.
    var moveMessage: MoveMessage?
    /// Whether a move's plan is being read or the move runs.
    private(set) var isMoving = false
    /// Given by the app model to the adult workspace's model only: moves
    /// run inside the adult partition, in both directions.
    @ObservationIgnored var mover: CategoryMover?
    /// The app's partition operation state (review round 4), shared by
    /// both workspaces: a move begins its operation here, and every change
    /// of the library is refused while a move runs anywhere in the app.
    let operations: PartitionOperationState
    /// The move's operation, held from the reading of its plan to the end
    /// of its run, or until its confirmation is cancelled or dropped.
    @ObservationIgnored private var moveToken: PartitionOperations.Token?

    private let library: Library
    private let navigation: NavigationModel
    /// Run after every reload, so that the source list follows a change of
    /// categories (a deletion removes or moves sources).
    var onReload: (@MainActor () async -> Void)?
    /// The sources of a category, so that deleting it also closes a list of
    /// one of them (RD09 decision 19). Set by the app model.
    var sourcesOf: (@MainActor (UUID) -> Set<UUID>)?
    /// The last queued operation; each waits for the one before it, so
    /// changes are saved one after another in the order made.
    private var lastOperation: Task<Bool, Never>?
    private var queuedOperations = 0
    /// Categories whose deletion has been chosen and not yet finished.
    private var deletionsStarted: Set<UUID> = []
    /// Raised each time an editor opens. Two editors of the same kind compare
    /// equal as sheets, so a save closes its sheet only if no other editor has
    /// been opened since it started.
    private var editorSession = 0

    #if DEBUG
    /// Set by the UI tests: the next save fails before reaching storage.
    var failNextSave = false
    /// Set by the UI tests: the next save waits this long before it runs.
    var slowNextSave: Duration?
    #endif

    init(library: Library, navigation: NavigationModel, operations: PartitionOperationState) {
        self.library = library
        self.navigation = navigation
        self.operations = operations
    }

    /// The workspace is dropped (RD18 decision 4): from here on nothing
    /// this model does is shown.
    func stop() {
        isStopped = true
        isShowingSaveError = false
        pendingDeletion = nil
        pendingMove = nil
        moveMessage = nil
    }

    /// The library's partition.
    var partition: Partition {
        library.partition
    }

    /// Whether a category save is queued or running, or a move's plan is
    /// read or the move runs (review round 2). Meanwhile the open editor is
    /// locked and rows cannot be moved or deleted: an edit made then would
    /// be built on a list that is about to change (RD03 C2–C5), or saved in
    /// a library the category is leaving. A move that runs anywhere in the
    /// app counts too (reviews rounds 3 and 4).
    var isBusy: Bool {
        queuedOperations > 0 || isMoving || operations.refusesLibraryEdits
    }

    /// Waits for every change queued before now (review round 4: a move
    /// begins after them).
    func settle() async {
        _ = await lastOperation?.value
    }

    var activeDialogHost: CategoryDialogHost {
        if navigation.sheet != nil {
            .sheet
        } else if navigation.isSlideOverOpen {
            .slideOver
        } else {
            .root
        }
    }

    var draftNameProblem: CategoryNameProblem? {
        Library.categoryNameProblem(draftName)
    }

    func summary(_ id: UUID) -> CategorySummary? {
        summaries.first { $0.id == id }
    }

    /// The rows the category list shows: every category except the one the
    /// list has taken away while its deletion is confirmed.
    var listedSummaries: [CategorySummary] {
        summaries.filter { $0.id != hiddenForDeletion }
    }

    /// Reads the categories from storage.
    func reload() async {
        do {
            summaries = try await library.categorySummaries()
            loadState = .loaded
        } catch {
            summaries = []
            loadState = .failed
        }
        await onReload?()
    }

    // MARK: - Sheets

    func beginNewCategory() {
        draftName = ""
        draftIcon = .folder
        editorSession += 1
        sheet = .newCategory
    }

    func beginSettings(_ id: UUID) {
        guard let summary = summary(id) else { return }
        draftName = summary.category.name
        draftIcon = summary.category.icon
        editorSession += 1
        sheet = .settings(id)
    }

    func cancelSheet() {
        sheet = nil
    }

    /// Saves the open sheet. It closes on success and stays open with its
    /// text on failure. If the editor was cancelled and another opened while
    /// the save ran, the other editor stays open.
    func saveSheet() async {
        guard let current = sheet, draftNameProblem == nil else { return }
        let session = editorSession
        let name = draftName
        let icon = draftIcon
        let saved: Bool
        switch current {
        case .newCategory:
            saved = await perform { library in
                _ = try await library.createCategory(name: name, icon: icon)
            }
        case .settings(let id):
            let stored: LibraryCategory? = summary(id)?.category
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let rename = stored?.name != trimmed
            let changeIcon = stored?.iconName != icon.rawValue
            saved = await perform { library in
                if rename {
                    try await library.renameCategory(id, to: name)
                }
                if changeIcon {
                    try await library.setCategoryIcon(id, to: icon)
                }
            }
        }
        if saved, sheet == current, editorSession == session {
            sheet = nil
        }
    }

    /// Creates a category from inside Add source ("New Category…"). It is
    /// written at once and stays if Add source is cancelled (RD05 decision
    /// 24). Returns the new category, or `nil` when the save failed.
    func createCategory(name: String, icon: CategoryIcon) async -> LibraryCategory? {
        let created = LockedValue<LibraryCategory?>(nil)
        let saved = await perform { library in
            created.value = try await library.createCategory(name: name, icon: icon)
        }
        return saved ? created.value : nil
    }

    // MARK: - Order and deletion

    /// Shows the new order at once, then saves it. The offsets are those of
    /// `listedSummaries`.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var listed = listedSummaries
        listed.move(fromOffsets: source, toOffset: destination)
        // A row hidden for a deletion keeps its slot.
        var moved = listed.makeIterator()
        summaries = summaries.map { $0.id == hiddenForDeletion ? $0 : moved.next() ?? $0 }
        let order = summaries.map(\.id)
        Task {
            _ = await perform { library in
                try await library.reorderCategories(order)
            }
        }
    }

    /// A deletion asked for from the list (edit mode or a swipe), with
    /// offsets of `listedSummaries`. The list has already taken the row away
    /// when it calls this, so the row stays out of `listedSummaries` until
    /// the dialog closes; it comes back if the deletion is not confirmed.
    func requestDeletion(atOffsets offsets: IndexSet) {
        let listed = listedSummaries
        guard let index = offsets.first, listed.indices.contains(index) else { return }
        hiddenForDeletion = listed[index].id
        pendingDeletion = listed[index]
    }

    /// A deletion asked for from Category Settings.
    func requestDeletion(_ id: UUID) {
        pendingDeletion = summary(id)
    }

    /// The deletion dialog closed, by a choice or without one. A row taken
    /// out of the list for it comes back unless the deletion went ahead; the
    /// check waits for the dialog's own action to run.
    func deletionDialogDismissed() {
        pendingDeletion = nil
        guard let id = hiddenForDeletion else { return }
        Task {
            await Task.yield()
            if !deletionsStarted.contains(id), hiddenForDeletion == id {
                hiddenForDeletion = nil
            }
        }
    }

    /// The categories the sources of `summary` can move to.
    func moveTargets(for summary: CategorySummary) -> [CategorySummary] {
        summaries.filter { $0.id != summary.id }
    }

    func delete(_ summary: CategorySummary, sources: CategorySourcesDisposition) async {
        let id = summary.id
        let heldSources = sourcesOf?(id) ?? []
        deletionsStarted.insert(id)
        defer { deletionsStarted.remove(id) }
        let deleted = await perform { library in
            try await library.deleteCategory(id, sources: sources)
        }
        // On success the reload has removed the category; on failure it is
        // still stored and its row comes back.
        if hiddenForDeletion == id {
            hiddenForDeletion = nil
        }
        if deleted {
            navigation.categoryDeleted(id, sources: heldSources)
            if sheet == .settings(id) {
                sheet = nil
            }
        }
    }

    // MARK: - Moving to the other partition (RD19 decision 11)

    /// Whether the open category sheet differs from the stored category.
    func sheetHasChanges(_ id: UUID) -> Bool {
        guard let stored = summary(id)?.category else { return false }
        return draftName.trimmingCharacters(in: .whitespacesAndNewlines) != stored.name || draftIcon.rawValue != stored.iconName
    }

    /// Reads what moving the category `id` out of the library of `from`
    /// would do, then asks for the confirmation; a category whose every
    /// source stays says so at once. A plan that arrives after a lock
    /// stopped this model is not presented.
    func beginMove(_ id: UUID, from partition: Partition) {
        guard let mover, !isMoving, !isStopped else { return }
        // One partition operation at a time in the app (review round 4),
        // whichever workspace began the other one: refused, nothing moves.
        guard let token = operations.begin(.categoryMove) else {
            moveMessage = .notMoved
            return
        }
        moveToken = token
        isMoving = true
        let to: Partition = partition == .normal ? .adult : .normal
        Task {
            let plan = await mover.plan(id, partition)
            isMoving = false
            guard !isStopped else {
                endMove()
                return
            }
            guard let plan else {
                endMove()
                moveMessage = .notMoved
                return
            }
            if plan.movesNothing {
                endMove()
                moveMessage = .nothingToMove(name: plan.category.name, to: to)
            } else {
                pendingMove = plan
            }
        }
    }

    /// Ends the move's operation, if this model holds it.
    private func endMove() {
        if let moveToken {
            operations.end(moveToken)
            self.moveToken = nil
        }
    }

    /// "Move": runs the move. Success shows nothing.
    func confirmMove(_ plan: CategoryMove.Plan) {
        guard let mover, !isMoving, !isStopped, moveToken != nil else {
            pendingMove = nil
            return
        }
        // Set first: the confirmation's clearing keeps the operation.
        isMoving = true
        pendingMove = nil
        let previous = lastOperation
        Task {
            // A category save queued before the move ends first; none can
            // start meanwhile (`isBusy`).
            _ = await previous?.value
            let outcome = await mover.run(plan)
            isMoving = false
            endMove()
            guard !isStopped else { return }
            switch outcome {
            case .moved:
                break
            case .nothingToMove:
                moveMessage = .nothingToMove(name: plan.category.name, to: plan.to)
            case .notMoved:
                moveMessage = .notMoved
            case .copiedNotRemoved:
                moveMessage = .copiedNotRemoved(name: plan.category.name, to: plan.to)
            }
        }
    }

    /// Cancel: nothing is written.
    func cancelMove() {
        pendingMove = nil
    }

    // MARK: - Saving

    /// Runs `operation` after every operation queued before it. On failure
    /// the list is reloaded from storage and the error is shown; on success
    /// it is reloaded once nothing else is queued, so an optimistic order is
    /// not replaced by an intermediate one. A `nil` operation only reloads,
    /// in its turn.
    private func perform(_ operation: (@Sendable (Library) async throws -> Void)?) async -> Bool {
        // No change of the library is queued while a move runs anywhere in
        // the app (review round 4): refused, nothing written, nothing shown.
        // A reload still is.
        if operation != nil, operations.refusesLibraryEdits {
            return false
        }
        let previous = lastOperation
        let library = library
        queuedOperations += 1
        let task = Task { @MainActor in
            _ = await previous?.value
            defer { queuedOperations -= 1 }
            guard let operation else {
                await reload()
                return true
            }
            do {
                #if DEBUG
                if let delay = slowNextSave {
                    slowNextSave = nil
                    try? await Task.sleep(for: delay, tolerance: .zero)
                }
                if failNextSave {
                    failNextSave = false
                    throw LibraryError.storage("Simulated failure for a UI test")
                }
                #endif
                try await operation(library)
                if queuedOperations == 1 {
                    await reload()
                }
                return true
            } catch {
                await reload()
                isShowingSaveError = true
                return false
            }
        }
        lastOperation = task
        return await task.value
    }
}

/// A value one task writes and another reads.
final class LockedValue<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) {
        mutex = Mutex(value)
    }

    var value: Value {
        get { mutex.withLock { $0 } }
        set { mutex.withLock { $0 = newValue } }
    }
}
