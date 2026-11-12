import Foundation
import NewsPawKit
import UIKit

/// Refresh for the app (spec N04; RD06): the library's one engine, the
/// entry that cleans up and refreshes when due, the two settings, the
/// recorded refresh time for Today's status line, and the background time
/// asked for while a run is in flight. At app level beside the category and
/// source models.
@MainActor @Observable
final class RefreshModel {
    /// Every collection of the library goes through it.
    let engine: Refresher
    var interval: RefreshInterval {
        didSet { preferences.refreshInterval = interval }
    }
    var retention: Retention {
        didSet { preferences.retention = retention }
    }
    /// The end of the last counted whole-library refresh.
    private(set) var lastRefreshAt: Date?
    /// The clock the library uses, so that "Updated …" agrees with it.
    let now: @Sendable () -> Date

    /// Reads the lists again; set by the app model.
    @ObservationIgnored var onListsChanged: (@MainActor () async -> Void)?
    /// Shows the "could not be saved" alert; set by the app model.
    @ObservationIgnored var onStorageError: (@MainActor () -> Void)?

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var runs = 0
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    @ObservationIgnored private var reloading = false
    @ObservationIgnored private var reloadAgain = false

    init(library: Library, transport: any Transport, preferences: Preferences, now: @escaping @Sendable () -> Date) {
        self.library = library
        self.preferences = preferences
        self.now = now
        engine = Refresher(library: library, transport: transport)
        interval = preferences.refreshInterval
        retention = preferences.retention
        engine.onCollectionEnded = { [weak self] _ in
            Task { await self?.reloadLists() }
        }
    }

    /// Reads the recorded refresh time. A failed read keeps the time shown.
    func load() async {
        do {
            lastRefreshAt = try await library.lastRefreshAt()
        } catch {}
    }

    /// Entering the app (decision 3): clean up, then refresh the whole
    /// library when a refresh is due. Silent: a failure is tried again at
    /// the next entry.
    func entered() async {
        let deleted = (try? await library.cleanUp(keeping: retention)) ?? 0
        if deleted > 0 {
            await reloadLists()
        }
        guard (try? await library.refreshIsDue(every: interval)) == true else { return }
        await run(.library, ownerStarted: false)
    }

    /// A refresh the owner asked for: a pull, a menu's Refresh, or Update Now.
    /// It runs in a task of its own, so that a caller that is cancelled
    /// (SwiftUI cancels a pull's task) neither cancels the reads that follow
    /// the run nor makes them fail; the caller still waits for the end.
    func refresh(_ scope: RefreshScope) async {
        await Task { await run(scope, ownerStarted: true) }.value
    }

    private func run(_ scope: RefreshScope, ownerStarted: Bool) async {
        beginBackgroundTime()
        defer { endBackgroundTimeIfIdle() }
        var storageFailed = false
        do {
            let results = try await engine.refresh(scope)
            storageFailed = results.values.contains { result in
                if case .storageError = result { true } else { false }
            }
        } catch {
            storageFailed = true
        }
        if storageFailed, ownerStarted {
            onStorageError?()
        }
        await load()
        await reloadLists()
    }

    // MARK: - Background time (decision 6)

    private func beginBackgroundTime() {
        runs += 1
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Refresh") { [weak self] in
            // Called on the main thread when the time runs out.
            MainActor.assumeIsolated { self?.backgroundTimeExpired() }
        }
    }

    /// Cancels the engine synchronously, then ends the assertion; the end of
    /// the runs does not end it a second time.
    private func backgroundTimeExpired() {
        engine.cancelAll()
        endBackgroundTime()
    }

    private func endBackgroundTimeIfIdle() {
        runs -= 1
        if runs == 0 {
            endBackgroundTime()
        }
    }

    private func endBackgroundTime() {
        let task = backgroundTask
        backgroundTask = .invalid
        if task != .invalid {
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    // MARK: - Lists

    /// Reads the lists again, one read at a time, so that an older read
    /// never lands after a newer one.
    private func reloadLists() async {
        if reloading {
            reloadAgain = true
            return
        }
        reloading = true
        repeat {
            reloadAgain = false
            await onListsChanged?()
        } while reloadAgain
        reloading = false
    }
}
