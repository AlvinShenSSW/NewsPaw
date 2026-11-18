import Foundation
import NewsPawKit
import UIKit

/// Refresh for the app (spec N04; RD06): the library's one engine, the
/// entry that cleans up and refreshes when due, the refresh settings, the
/// recorded refresh time for Today's status line, and the background time
/// asked for while a run is in flight. At app level beside the category and
/// source models.
@MainActor @Observable
final class RefreshModel {
    /// Every collection of the library goes through it.
    let engine: Refresher
    /// The two settings, shared with every workspace (RD18 decision 3) and
    /// read at each use.
    var interval: RefreshInterval {
        get { settings.interval }
        set { settings.interval = newValue }
    }
    var retention: Retention {
        get { settings.retention }
        set { settings.retention = newValue }
    }
    var backgroundRefresh: Bool {
        get { settings.backgroundRefresh }
        set { settings.backgroundRefresh = newValue }
    }

    /// The background runs of the last seven days by the library's clock,
    /// oldest first (RD24 decision 6), read from the preferences store.
    func recentBackgroundRuns() -> [Date] {
        settings.backgroundRuns(before: now())
    }
    /// The end of the last counted whole-library refresh.
    private(set) var lastRefreshAt: Date?
    /// The clock the library uses, so that "Updated …" agrees with it.
    let now: @Sendable () -> Date
    /// Where the device's local day starts, for the overviews' clean-up.
    @ObservationIgnored private let calendar = Calendar.autoupdatingCurrent

    /// Reads the lists again; set by the app model.
    @ObservationIgnored var onListsChanged: (@MainActor () async -> Void)?
    /// Shows the "could not be saved" alert; set by the app model.
    @ObservationIgnored var onStorageError: (@MainActor () -> Void)?
    /// Told when a run has ended and the lists have been read again, so
    /// that an article list at its top reads itself again (RD09 decision 3).
    @ObservationIgnored var onRunEnded: (@MainActor () -> Void)?
    /// Called at the end of every entry (`entered()`), after its run if one
    /// was due, never by a background run.
    @ObservationIgnored var onEntered: (@MainActor () -> Void)?

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let settings: RefreshSettings
    @ObservationIgnored private var runs = 0
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    @ObservationIgnored private var reloading = false
    @ObservationIgnored private var reloadAgain = false
    /// Whether the workspace of this model was dropped (RD18 decision 4):
    /// from then on it starts no run.
    @ObservationIgnored private var isStopped = false

    init(library: Library, transport: any Transport, settings: RefreshSettings, now: @escaping @Sendable () -> Date) {
        self.library = library
        self.settings = settings
        self.now = now
        engine = Refresher(library: library, transport: transport)
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
    /// the next entry. The overviews older than the 7-day window go first,
    /// whatever the retention (RD23 decision 15).
    ///
    /// An entry that a lock overtakes ends at its next step: a dropped
    /// workspace starts no run.
    ///
    /// Every entry ends with exactly one overview due check (RD23 with
    /// RD24's handoff; batch 4 gate run 2): the run's own, through
    /// `onRunEnded`, when the entry's refresh ran to its end; otherwise
    /// `onEntered` — the refresh was not due, its read failed, or the
    /// workspace's run did not reach its end — so that the articles a
    /// background run collected get their overview without a pull, and a
    /// job the run's check ended is not sent again by a second check.
    func entered() async {
        let reported = await cleanUpAndRefreshIfDue()
        guard !isStopped, !reported else { return }
        onEntered?()
    }

    /// The entry's clean-up and its refresh when due; returns whether a run
    /// reached `onRunEnded`.
    private func cleanUpAndRefreshIfDue() async -> Bool {
        guard !isStopped else { return false }
        _ = try? await library.cleanUpOverviews(before: OverviewDay.oldestKept(now(), calendar: calendar))
        guard !isStopped else { return false }
        let deleted = (try? await library.cleanUp(keeping: retention)) ?? 0
        guard !isStopped else { return false }
        if deleted > 0 {
            await reloadLists()
            guard !isStopped else { return false }
        }
        guard (try? await library.refreshIsDue(every: interval)) == true else { return false }
        return await run(.library, ownerStarted: false)
    }

    /// A refresh the owner asked for: a pull, a menu's Refresh, or Update Now.
    /// It runs in a task of its own, so that a caller that is cancelled
    /// (SwiftUI cancels a pull's task) neither cancels the reads that follow
    /// the run nor makes them fail; the caller still waits for the end.
    func refresh(_ scope: RefreshScope) async {
        _ = await Task { await run(scope, ownerStarted: true) }.value
    }

    /// One run; returns whether it reached `onRunEnded`.
    @discardableResult
    private func run(_ scope: RefreshScope, ownerStarted: Bool) async -> Bool {
        guard !isStopped else { return false }
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
        if storageFailed, ownerStarted, !isStopped {
            onStorageError?()
        }
        await load()
        await reloadLists()
        onRunEnded?()
        return true
    }

    /// The workspace is dropped (RD18 decision 4): the run in flight is
    /// cancelled, and none is started afterwards — not by an entry that is
    /// still on its way, and not by Update Now or a pull of a view that
    /// something keeps. What a run has stored stays in the library.
    func stop() {
        isStopped = true
        engine.cancelAll()
    }

    // MARK: - Background time (decision 6)

    /// Also taken for a background run's collection handed to the front
    /// (RD24 review G3), and ended by `endBackgroundTimeIfIdle()` when it
    /// ends.
    func beginBackgroundTime() {
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

    func endBackgroundTimeIfIdle() {
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
