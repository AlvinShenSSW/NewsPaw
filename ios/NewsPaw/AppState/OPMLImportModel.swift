import Foundation
import NewsPawKit
import UniformTypeIdentifiers

/// Where an OPML import was started: the screen whose modifier presents its
/// file picker, alert and preview.
enum OPMLImportOrigin: Hashable {
    /// The address step of Add source.
    case addSource
    /// Settings › Data.
    case settings
}

/// A screen pushed inside the import preview.
enum OPMLImportRoute: Hashable {
    case categoryPicker
    case newCategory
    case skipped
}

extension UTType {
    /// OPML, declared as an imported type in the app's Info.plist.
    static let opml = UTType(importedAs: "org.opml.opml", conformingTo: .xml)
}

/// One OPML import (spec N03, N10; RD08 decision 5): the file, its plan, the
/// category chosen for the feeds outside any folder, and the stage: reading,
/// then preview → importing → done. Owned by the workspace's source model,
/// as Add source's model is: a result that arrives after this model is no
/// longer the one its workspace holds — the import was closed, or the
/// workspace was dropped at a lock or a switch — is dropped, and nothing
/// is presented.
@MainActor @Observable
final class OPMLImportModel {
    enum Stage: Equatable {
        /// The file is being read and planned; nothing is presented.
        case reading
        case preview
        case importing
        case done(OPMLImportSummary)
    }

    /// What the alert of the screen that opened the picker says.
    enum Alert: Equatable {
        case refused(OPMLRefusal)
        /// The plan could not read the library.
        case storage
    }

    /// Why Import did not write; the preview stays.
    enum Failure: Error, Equatable {
        case storage
        /// The chosen category was deleted meanwhile.
        case categoryGone
    }

    /// The choice for the feeds outside any folder.
    enum Choice: Equatable {
        case existing(UUID)
        case named(String)
    }

    let origin: OPMLImportOrigin
    var isPickingFile = false
    var alert: Alert?
    var isShowingPreview = false
    var path: [OPMLImportRoute] = []
    private(set) var stage = Stage.reading
    private(set) var plan: OPMLImportSummary?
    var choice: Choice?
    /// The "New Category…" draft.
    var newCategoryName = ""
    private(set) var failure: Failure?

    private var document: OPMLDocument?
    private var task: Task<Void, Never>?
    private weak var sources: SourceModel?

    init(origin: OPMLImportOrigin, sources: SourceModel) {
        self.origin = origin
        self.sources = sources
    }

    /// Whether Import can be tapped: the plan writes something, the
    /// required category is chosen, and nothing is being written.
    var canImport: Bool {
        guard stage == .preview, let plan, plan.changesSomething else { return false }
        return !plan.needsOutsideCategory || choice != nil
    }

    /// Reads the chosen file off the main actor, under its security scope,
    /// and plans it against this workspace's library.
    func fileChosen(_ url: URL) {
        task?.cancel()
        stage = .reading
        task = Task {
            let read = await Task.detached {
                let scoped = url.startAccessingSecurityScopedResource()
                defer {
                    if scoped {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                return OPMLReader.read(contentsOf: url)
            }.value
            guard !Task.isCancelled, let sources, sources.isCurrent(self) else { return }
            let document: OPMLDocument
            switch read {
            case .success(let read): document = read
            case .failure(let refusal):
                alert = .refused(refusal)
                return
            }
            do {
                let plan = try await sources.library.opmlImportPlan(document)
                guard !Task.isCancelled, sources.isCurrent(self) else { return }
                self.document = document
                self.plan = plan
                stage = .preview
                isShowingPreview = true
            } catch {
                guard !Task.isCancelled, sources.isCurrent(self) else { return }
                alert = .storage
            }
        }
    }

    /// Import: one transaction. On success the summary is shown and the
    /// lists have been read again; on failure the preview stays with the
    /// reason and Import enabled again.
    func importTapped() {
        guard canImport, let document, let plan, let sources else { return }
        let target: OPMLOutsideFeeds? = switch choice {
        case _ where !plan.needsOutsideCategory: nil
        case .existing(let id): .existing(id)
        case .named(let name): .named(name)
        case nil: nil
        }
        stage = .importing
        failure = nil
        task = Task {
            let result = await sources.importOPML(document, outsideFeeds: target)
            guard sources.isCurrent(self) else { return }
            switch result {
            case .success(let summary):
                path = []
                stage = .done(summary)
            case .failure(let failure):
                self.failure = failure
                if failure == .categoryGone {
                    choice = nil
                }
                stage = .preview
            }
        }
    }

    /// The name shown for the chosen category, if any.
    func choiceName(in categories: [CategorySummary]) -> String? {
        switch choice {
        case .existing(let id): categories.first { $0.id == id }?.category.name
        case .named(let name): name
        case nil: nil
        }
    }

    /// "New Category…" confirmed: the typed name is the choice. Nothing is
    /// created until Import.
    func useNewCategoryName() {
        guard Library.categoryNameProblem(newCategoryName) == nil else { return }
        choice = .named(newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines))
        path = []
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
