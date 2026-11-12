import Foundation
import NewsPawKit

/// A screen pushed inside the Add source sheet.
enum AddSourceRoute: Hashable {
    case confirm
    case suggested
    case categoryPicker
    case newCategory
}

/// The Add source sheet's state (spec N03, ux S6): the address, the
/// detection in flight and its result, the choice, the name, the category
/// and the save. The detection belongs to this model, so a container switch
/// cannot cancel it; Cancel and dismissal do.
@MainActor @Observable
final class AddSourceModel {
    /// What can be saved.
    enum Choice: Hashable {
        /// A declared or typed feed, by address.
        case feed(String)
        /// The page itself, as a web-page source.
        case webPage
    }

    /// What Save hands to the source model.
    struct Saving: Sendable {
        enum Kind: Sendable {
            case feed(FeedCandidate)
            case webPage(String)
        }

        let kind: Kind
        let name: String
        let categoryID: UUID

        var address: String {
            switch kind {
            case .feed(let candidate): candidate.address
            case .webPage(let address): address
            }
        }
    }

    enum SaveResult {
        case saved
        case duplicate(ExistingSource)
        case failed
    }

    var path: [AddSourceRoute] = []
    var addressText = ""
    /// The result of the last detection.
    private(set) var detection: Detection?
    /// The text the last detection ran on.
    private(set) var detectedText: String?
    private(set) var isDetecting = false
    /// Whether the owner chose to save the address as a web page from the
    /// address step (no feed found, or a site that answered but refused the
    /// app's fetch).
    private(set) var savingAsWebPage = false
    private(set) var choice: Choice?
    var name = "" {
        didSet {
            if name != suggestedName {
                nameEdited = true
            }
        }
    }
    var categoryID: UUID?
    private(set) var isSaving = false
    /// A duplicate found at Save, shown on the sheet.
    var duplicateAtSave: ExistingSource?
    // The inline "New Category…" draft.
    var newCategoryName = ""
    var newCategoryIcon = CategoryIcon.folder
    private(set) var isCreatingCategory = false

    private var task: Task<Void, Never>?
    private var nameEdited = false
    private var suggestedName = ""
    private let sources: SourceModel
    private let categories: CategoryModel

    init(sources: SourceModel, categories: CategoryModel, preferredCategory: UUID?) {
        self.sources = sources
        self.categories = categories
        categoryID = preferredCategory
    }

    // MARK: - Detection

    /// Runs a detection on the address field's text, replacing any earlier
    /// result, and returns to the address step.
    func detect() {
        task?.cancel()
        let text = addressText
        detection = nil
        detectedText = nil
        savingAsWebPage = false
        choice = nil
        nameEdited = false
        path = []
        isDetecting = true
        let detector = SourceDetector(transport: sources.transport, candidateLimit: sources.candidateLimit)
        let library = sources.library
        task = Task {
            let result: Detection
            do {
                result = try await detector.detect(text, in: library)
            } catch {
                // Cancelled, or a lookup failed: nothing is shown and
                // nothing was stored.
                if !Task.isCancelled {
                    isDetecting = false
                    task = nil
                }
                return
            }
            guard !Task.isCancelled else { return }
            isDetecting = false
            task = nil
            detection = result
            detectedText = text
            apply(result)
        }
    }

    /// "Continue": shows the confirm step again when the text has not
    /// changed since a detection that found something to save; otherwise
    /// detects.
    func continueTapped() {
        if detectedText == addressText, canConfirm {
            path = [.confirm]
        } else {
            detect()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isDetecting = false
    }

    /// "Try Another Address": clears the field and the result.
    func tryAnotherAddress() {
        cancel()
        addressText = ""
        detection = nil
        detectedText = nil
        savingAsWebPage = false
        choice = nil
    }

    /// "Save as a Web Page" from the address step.
    func saveAsWebPage() {
        savingAsWebPage = true
        choose(.webPage)
        path = [.confirm]
    }

    /// Picks a suggested source: its address runs an ordinary detection.
    func chooseSuggested(_ suggestion: SuggestedSource) {
        addressText = suggestion.address
        detect()
    }

    private func apply(_ result: Detection) {
        switch result {
        case .feed(let candidate):
            choose(.feed(candidate.address))
            path = [.confirm]
        case .page(let page) where !page.candidates.isEmpty:
            let firstUsable = page.candidates.first { candidate in
                if case .usable = candidate.state { true } else { false }
            }
            if let firstUsable {
                choose(.feed(firstUsable.address))
            }
            path = [.confirm]
        case .page, .invalidAddress, .duplicate, .failed:
            break
        }
    }

    // MARK: - Confirm

    /// Whether there is anything to save: a feed, a page with declared feeds,
    /// or a web page the owner asked for.
    var canConfirm: Bool {
        switch detection {
        case .feed: true
        case .page(let page): !page.candidates.isEmpty || savingAsWebPage
        case .failed(let failure): failure.offersWebPage && savingAsWebPage
        case .invalidAddress, .duplicate, nil: false
        }
    }

    /// The page's address, when the owner may save it as a web page.
    var webPageAddress: String? {
        switch detection {
        case .page(let page): page.address
        case .failed(let failure) where failure.offersWebPage: failure.address
        case .feed, .failed, .invalidAddress, .duplicate, nil: nil
        }
    }

    /// The page's declared feeds, when the choice list shows them.
    var declaredCandidates: [DeclaredCandidate] {
        guard !savingAsWebPage, case .page(let page) = detection else { return [] }
        return page.candidates
    }

    /// The feed candidate chosen, if the choice is a usable feed.
    var chosenFeed: FeedCandidate? {
        guard case .feed(let address) = choice else { return nil }
        switch detection {
        case .feed(let candidate) where candidate.address == address:
            return candidate
        case .page(let page):
            for candidate in page.candidates where candidate.address == address {
                if case .usable(let feed) = candidate.state {
                    return feed
                }
            }
            return nil
        default:
            return nil
        }
    }

    /// Chooses a row of the confirm step. A declared feed that could not be
    /// checked in time runs an ordinary detection on its address instead.
    func choose(_ newChoice: Choice) {
        if case .feed(let address) = newChoice,
           declaredCandidates.contains(where: { $0.address == address && $0.state == .notChecked }) {
            addressText = address
            detect()
            return
        }
        choice = newChoice
        suggestedName = defaultName(for: newChoice)
        if !nameEdited {
            name = suggestedName
            nameEdited = false
        }
    }

    private func defaultName(for choice: Choice) -> String {
        let title: String?
        let address: String?
        switch choice {
        case .feed:
            title = chosenFeed?.title
            address = chosenFeed?.address
        case .webPage:
            if case .page(let page) = detection {
                title = page.title
            } else {
                title = nil
            }
            address = webPageAddress
        }
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Library.maximumSourceNameLength))
        }
        return address.flatMap { URL(string: $0)?.host() } ?? ""
    }

    var nameProblem: CategoryNameProblem? {
        Library.sourceNameProblem(name)
    }

    /// The chosen category, if it still exists.
    var chosenCategory: LibraryCategory? {
        categoryID.flatMap { categories.summary($0)?.category }
    }

    var canSave: Bool {
        guard !isSaving, nameProblem == nil, chosenCategory != nil else { return false }
        switch choice {
        case .feed: return chosenFeed != nil
        case .webPage: return webPageAddress != nil
        case nil: return false
        }
    }

    func save() async {
        guard canSave, let categoryID = chosenCategory?.id, let choice else { return }
        let kind: Saving.Kind
        switch choice {
        case .feed:
            guard let feed = chosenFeed else { return }
            kind = .feed(feed)
        case .webPage:
            guard let address = webPageAddress else { return }
            kind = .webPage(address)
        }
        isSaving = true
        defer { isSaving = false }
        let result = await sources.save(Saving(kind: kind, name: name, categoryID: categoryID))
        if case .duplicate(let existing) = result {
            duplicateAtSave = existing
        }
    }

    // MARK: - New category

    func beginNewCategory() {
        newCategoryName = ""
        newCategoryIcon = .folder
        path.append(.newCategory)
    }

    /// Creates the category at once and selects it.
    func createCategory() async {
        guard Library.categoryNameProblem(newCategoryName) == nil, !isCreatingCategory else { return }
        isCreatingCategory = true
        defer { isCreatingCategory = false }
        if let category = await categories.createCategory(name: newCategoryName, icon: newCategoryIcon) {
            categoryID = category.id
            path.removeAll { $0 == .newCategory || $0 == .categoryPicker }
        }
    }
}
