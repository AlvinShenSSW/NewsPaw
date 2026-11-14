import Foundation
import NewsPawKit
import SwiftUI
import WebKit

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
        case ready(CategoryModel, SourceModel, RefreshModel, ReadingModel, BrowserModel)
        case failed(LibraryFailure)
    }

    private(set) var status = Status.loading
    let navigation = NavigationModel()
    /// The app's one store; it gives out one library per partition.
    private var store: LibraryStore?
    /// Whether the scene has been in the background since it was last
    /// active: the next `active` is an entry.
    private var wasInBackground = false

    /// Opens the normal library, creating it on first launch. A failure is
    /// shown and left as it is: the file is never deleted, reset or replaced.
    func start() async {
        guard case .loading = status else { return }
        // The one transport the app makes requests through. Under a UI-test
        // library directory it is the fixture transport, never the real one.
        // The one clock of the library and of Today's status line.
        #if DEBUG
        let options = DebugLaunchOptions(environment: ProcessInfo.processInfo.environment)
        let directory = options.libraryDirectory ?? LibraryStore.defaultDirectory()
        let transport: any Transport = options.libraryDirectory != nil ? FixtureTransport() : URLSessionTransport()
        let candidateLimit = options.libraryDirectory != nil ? FixtureTransport.candidateLimit : .seconds(20)
        // Under a UI-test library directory: the cache inside it, and a
        // preferences suite named after it, never the standard one.
        let cacheRoot = options.libraryDirectory.map { $0.appending(path: "Images", directoryHint: .isDirectory) }
            ?? LibraryStore.defaultCacheRoot()
        let defaults = options.libraryDirectory.flatMap { UserDefaults(suiteName: $0.lastPathComponent) } ?? .standard
        // The clock offset, like the fixture transport, applies only under a
        // UI-test library directory.
        let offset = options.libraryDirectory != nil ? options.clockOffset : 0
        let now: @Sendable () -> Date = { Date().addingTimeInterval(offset) }
        #else
        let directory = LibraryStore.defaultDirectory()
        let transport: any Transport = URLSessionTransport()
        let candidateLimit = Duration.seconds(20)
        let cacheRoot = LibraryStore.defaultCacheRoot()
        let defaults = UserDefaults.standard
        let now: @Sendable () -> Date = { Date() }
        #endif
        do {
            let store = LibraryStore(directory: directory, cacheRoot: cacheRoot, now: now)
            self.store = store
            let library = try await store.openNormal()
            let categories = CategoryModel(library: library, navigation: navigation)
            let refresh = RefreshModel(library: library, transport: transport, preferences: Preferences(defaults), now: now)
            let sources = SourceModel(
                library: library, transport: transport, candidateLimit: candidateLimit,
                navigation: navigation, categories: categories, refresh: refresh
            )
            let reading = ReadingModel(
                library: library, transport: transport, navigation: navigation, sources: sources, refresh: refresh
            )
            // The embedded browser: the system's default website data store
            // for the normal library; under a UI-test library directory a
            // non-persistent one and the fixture pages.
            #if DEBUG
            let browser = if options.libraryDirectory != nil {
                BrowserModel(
                    dataStore: .nonPersistent(), navigation: navigation, sources: sources,
                    addressMap: BrowserFixtures.map, schemeHandlers: [BrowserFixtures.scheme: BrowserFixtures()]
                )
            } else {
                BrowserModel(dataStore: .default(), navigation: navigation, sources: sources)
            }
            #else
            let browser = BrowserModel(dataStore: .default(), navigation: navigation, sources: sources)
            #endif
            categories.onReload = { [weak sources] in await sources?.reload() }
            categories.sourcesOf = { [weak sources] id in Set(sources?.sources(in: id).map(\.id) ?? []) }
            refresh.onListsChanged = { [weak sources] in await sources?.reload() }
            refresh.onStorageError = { [weak sources] in sources?.isShowingSaveError = true }
            refresh.onRunEnded = { [weak reading] in reading?.runEnded() }
            navigation.onListEntered = { [weak reading] list in reading?.entered(list) }
            navigation.isWebPageSource = { [weak sources] id in sources?.summary(id)?.kind == .webpage }
            navigation.onStacksChanged = { [weak browser] in browser?.stacksChanged() }
            #if DEBUG
            if let count = options.syntheticSources {
                try await library.insertSyntheticSourcesForUITests(count: count)
            }
            categories.failNextSave = options.failNextSave
            categories.slowNextSave = options.slowNextSave
            sources.failNextSave = options.failNextSourceSave
            #endif
            await categories.reload()
            await refresh.load()
            status = .ready(categories, sources, refresh, reading, browser)
            // The launch is the first entry (RD06 decision 3).
            Task { await refresh.entered() }
        } catch is CancellationError {
            return
        } catch {
            status = .failed(LibraryFailure(error))
        }
    }

    /// Every return from the background to `active` is an entry; a return
    /// from `inactive` alone (Control Centre, a system alert) is not. The
    /// launch's own first `active` arrives while the library is still
    /// opening and is not one either: `start()` makes the launch entry.
    func scenePhaseChanged(to phase: ScenePhase) {
        switch phase {
        case .background:
            wasInBackground = true
        case .active where wasInBackground:
            wasInBackground = false
            if case .ready(_, _, let refresh, _, _) = status {
                Task { await refresh.entered() }
            }
        default:
            break
        }
    }
}
