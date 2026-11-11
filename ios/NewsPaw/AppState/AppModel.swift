import Foundation
import NewsPawKit

/// Why the library could not be opened, as the failure screen tells it.
enum LibraryFailure: Equatable {
    case newerSchema
    case damaged
    /// Anything else, with the underlying description shown as technical
    /// detail (SQLite's own English wording, not translated).
    case other(detail: String)

    init(_ error: any Error) {
        switch error {
        case LibraryError.newerSchema: self = .newerSchema
        case LibraryError.damaged: self = .damaged
        case LibraryError.storage(let description): self = .other(detail: description)
        default: self = .other(detail: String(describing: error))
        }
    }
}

/// The app's startup state and its one library: the normal one.
@MainActor @Observable
final class AppModel {
    enum Status {
        case loading
        case ready(CategoryModel)
        case failed(LibraryFailure)
    }

    private(set) var status = Status.loading
    let navigation = NavigationModel()
    /// The app's one store; it gives out one library per partition.
    private var store: LibraryStore?

    /// Opens the normal library, creating it on first launch. A failure is
    /// shown and left as it is: the file is never deleted, reset or replaced.
    func start() async {
        guard case .loading = status else { return }
        #if DEBUG
        let options = DebugLaunchOptions(environment: ProcessInfo.processInfo.environment)
        let directory = options.libraryDirectory ?? LibraryStore.defaultDirectory()
        #else
        let directory = LibraryStore.defaultDirectory()
        #endif
        do {
            let store = LibraryStore(directory: directory)
            self.store = store
            let library = try await store.openNormal()
            let categories = CategoryModel(library: library, navigation: navigation)
            #if DEBUG
            if let count = options.syntheticSources {
                try await library.insertSyntheticSourcesForUITests(count: count)
            }
            categories.failNextSave = options.failNextSave
            categories.slowNextSave = options.slowNextSave
            #endif
            await categories.reload()
            status = .ready(categories)
        } catch is CancellationError {
            return
        } catch {
            status = .failed(LibraryFailure(error))
        }
    }
}
