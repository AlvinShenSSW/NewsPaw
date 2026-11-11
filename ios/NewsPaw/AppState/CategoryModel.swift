import Foundation
import NewsPawKit

/// A category sheet presented from the root.
enum CategorySheet: Hashable, Identifiable {
    case newCategory
    case settings(UUID)

    var id: Self { self }
}

/// Where an alert or dialog about categories is attached: the root, the
/// slide-over sidebar's content, or the open sheet's content. Only the
/// frontmost host presents, so a dialog never closes a sheet or waits behind
/// the slide-over.
enum CategoryDialogHost {
    case root
    case slideOver
    case sheet
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

    private(set) var summaries: [CategorySummary] = []
    private(set) var loadState = LoadState.loading
    var sheet: CategorySheet?
    var draftName = ""
    var draftIcon = CategoryIcon.folder
    /// The category whose deletion is being confirmed.
    var pendingDeletion: CategorySummary?
    var isShowingSaveError = false

    private let library: Library
    private let navigation: NavigationModel
    /// The last queued operation; each waits for the one before it, so
    /// changes are saved one after another in the order made.
    private var lastOperation: Task<Bool, Never>?
    private var queuedOperations = 0

    #if DEBUG
    /// Set by the UI tests: the next save fails before reaching storage.
    var failNextSave = false
    #endif

    init(library: Library, navigation: NavigationModel) {
        self.library = library
        self.navigation = navigation
    }

    var activeDialogHost: CategoryDialogHost {
        if sheet != nil {
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

    /// Reads the categories from storage.
    func reload() async {
        do {
            summaries = try await library.categorySummaries()
            loadState = .loaded
        } catch {
            summaries = []
            loadState = .failed
        }
    }

    // MARK: - Sheets

    func beginNewCategory() {
        draftName = ""
        draftIcon = .folder
        sheet = .newCategory
    }

    func beginSettings(_ id: UUID) {
        guard let summary = summary(id) else { return }
        draftName = summary.category.name
        draftIcon = summary.category.icon
        sheet = .settings(id)
    }

    func cancelSheet() {
        sheet = nil
    }

    /// Saves the open sheet. It closes on success and stays open with its
    /// text on failure.
    func saveSheet() async {
        guard let current = sheet, draftNameProblem == nil else { return }
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
        if saved, sheet == current {
            sheet = nil
        }
    }

    // MARK: - Order and deletion

    /// Shows the new order at once, then saves it.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        summaries.move(fromOffsets: source, toOffset: destination)
        let order = summaries.map(\.id)
        Task {
            _ = await perform { library in
                try await library.reorderCategories(order)
            }
        }
    }

    func requestDeletion(atOffsets offsets: IndexSet) {
        guard let index = offsets.first, summaries.indices.contains(index) else { return }
        pendingDeletion = summaries[index]
    }

    func requestDeletion(_ id: UUID) {
        pendingDeletion = summary(id)
    }

    /// The categories the sources of `summary` can move to.
    func moveTargets(for summary: CategorySummary) -> [CategorySummary] {
        summaries.filter { $0.id != summary.id }
    }

    func delete(_ summary: CategorySummary, sources: CategorySourcesDisposition) async {
        let id = summary.id
        let deleted = await perform { library in
            try await library.deleteCategory(id, sources: sources)
        }
        if deleted {
            navigation.categoryDeleted(id)
            if sheet == .settings(id) {
                sheet = nil
            }
        }
    }

    // MARK: - Saving

    /// Runs `operation` after every operation queued before it. On failure
    /// the list is reloaded from storage and the error is shown; on success
    /// it is reloaded once nothing else is queued, so an optimistic order is
    /// not replaced by an intermediate one.
    private func perform(_ operation: @escaping @Sendable (Library) async throws -> Void) async -> Bool {
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
