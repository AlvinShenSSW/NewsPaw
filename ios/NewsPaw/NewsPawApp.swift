import NewsPawKit
import SwiftUI

@main
struct NewsPawApp: App {
    /// Where opening the normal library stands.
    enum LibraryStatus {
        case loading
        case ready(Library)
        case failed(LibraryFailure)
    }

    private let store = LibraryStore(directory: LibraryStore.defaultDirectory())
    @State private var status = LibraryStatus.loading

    var body: some Scene {
        WindowGroup {
            PlaceholderView(failure: failure)
                .task { await openLibrary() }
        }
    }

    private var failure: LibraryFailure? {
        if case .failed(let failure) = status { failure } else { nil }
    }

    /// Opens the normal library, creating it on first launch. A failure is
    /// shown and left as it is: the file is never deleted, reset or replaced.
    private func openLibrary() async {
        do {
            status = .ready(try await store.openNormal())
        } catch is CancellationError {
            return
        } catch {
            status = .failed(LibraryFailure(error))
        }
    }
}
