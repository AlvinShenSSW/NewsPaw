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

/// The app's startup state and the workspace on screen (RD18 decision 3):
/// the normal library's, kept for the life of the app.
@MainActor @Observable
final class AppModel {
    enum Status {
        case loading
        /// The normal library is open and `shown` is set.
        case ready
        case failed(LibraryFailure)
    }

    private(set) var status = Status.loading
    /// The normal library's workspace; set before `status` is ready.
    private(set) var normal: Workspace?
    /// The app's one store; it gives out one library per partition.
    private var store: LibraryStore?
    /// Whether the scene has been in the background since it was last
    /// active: the next `active` is an entry.
    private var wasInBackground = false

    /// The workspace on screen.
    var shown: Workspace? {
        normal
    }

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
        // Under a UI-test library directory: keys under a keychain service
        // named after the directory, never the owner's, and the model
        // fixture, which reaches no real service.
        let keyStore = options.libraryDirectory.map { KeychainKeyStore(partition: .normal, uiTestSuffix: $0.lastPathComponent) }
            ?? KeychainKeyStore(partition: .normal)
        let modelHTTP: any ModelHTTP = options.libraryDirectory != nil ? FixtureModelHTTP() : URLSessionModelHTTP()
        #else
        let directory = LibraryStore.defaultDirectory()
        let transport: any Transport = URLSessionTransport()
        let candidateLimit = Duration.seconds(20)
        let cacheRoot = LibraryStore.defaultCacheRoot()
        let defaults = UserDefaults.standard
        let now: @Sendable () -> Date = { Date() }
        let keyStore = KeychainKeyStore(partition: .normal)
        let modelHTTP: any ModelHTTP = URLSessionModelHTTP()
        #endif
        do {
            let store = LibraryStore(directory: directory, cacheRoot: cacheRoot, now: now)
            self.store = store
            let library = try await store.openNormal()
            let parts = WorkspaceParts(
                transport: transport, candidateLimit: candidateLimit, now: now,
                refreshSettings: RefreshSettings(Preferences(defaults)),
                models: LibraryModels(library: library, keys: keyStore, http: modelHTTP)
            )
            // The embedded browser: the system's default website data store
            // for the normal library; under a UI-test library directory a
            // non-persistent one and the fixture pages.
            #if DEBUG
            let browser = if options.libraryDirectory != nil {
                BrowserSetup(
                    dataStore: .nonPersistent(), addressMap: BrowserFixtures.map,
                    schemeHandlers: [BrowserFixtures.scheme: BrowserFixtures()]
                )
            } else {
                BrowserSetup(dataStore: .default())
            }
            #else
            let browser = BrowserSetup(dataStore: .default())
            #endif
            let workspace = Workspace(library: library, parts: parts, browser: browser)
            #if DEBUG
            if let count = options.syntheticSources {
                try await library.insertSyntheticSourcesForUITests(count: count)
            }
            workspace.categories.failNextSave = options.failNextSave
            workspace.categories.slowNextSave = options.slowNextSave
            workspace.sources.failNextSave = options.failNextSourceSave
            #endif
            await workspace.load()
            normal = workspace
            status = .ready
            // The launch is the first entry (RD06 decision 3).
            Task { await workspace.refresh.entered() }
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
            if let refresh = shown?.refresh {
                Task { await refresh.entered() }
            }
        default:
            break
        }
    }
}
