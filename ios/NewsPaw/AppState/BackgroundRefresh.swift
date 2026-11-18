import BackgroundTasks
import Foundation
import NewsPawKit
import Synchronization

// Background refresh (spec N04; RD24). This file builds the background
// work from the normal workspace, its library, the refresh settings and a
// run's control, and from nothing else: a package scan checks that it
// names no other partition and nothing that opens one.

/// The one background task of the app: an app refresh, declared in the
/// Info.plist's `BGTaskSchedulerPermittedIdentifiers`.
enum BackgroundRefreshTask {
    static let identifier = "io.newspaw.reader.refresh"
}

/// The schedule over the system's task scheduler (RD24 approach 3): one
/// app-refresh request, replaced by each submission.
@MainActor
final class SystemBackgroundScheduler: BackgroundScheduler {
    func submit(earliest: Date) throws {
        let request = BGAppRefreshTaskRequest(identifier: BackgroundRefreshTask.identifier)
        request.earliestBeginDate = earliest
        try BGTaskScheduler.shared.submit(request)
    }

    func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundRefreshTask.identifier)
    }
}

/// The work of one background run (RD24 approach 7): a `BackgroundPass`
/// over the normal workspace's own refresher and translator, with the
/// interval read now. When its collection has ended the workspace reads the
/// recorded refresh time again, so that Today's status line shows it, and
/// its lists at their top read themselves again, as after any refresh.
@MainActor
struct BackgroundRefreshWork {
    private let workspace: Workspace
    private let library: Library
    private let settings: RefreshSettings
    private let control: BackgroundPassControl

    /// - Parameters:
    ///   - workspace: the normal workspace; any other is a programming
    ///     error.
    ///   - library: its library.
    init(workspace: Workspace, library: Library, settings: RefreshSettings, control: BackgroundPassControl) {
        precondition(workspace.partition == .normal && library.partition == .normal, "background refresh is the normal library's")
        self.workspace = workspace
        self.library = library
        self.settings = settings
        self.control = control
    }

    func run() async -> BackgroundPassResult {
        let refresh = workspace.refresh
        let reading = workspace.reading
        let pass = BackgroundPass(
            library: library, refresher: refresh.engine, translator: workspace.translation.translator,
            interval: settings.interval, control: control,
            afterCollection: { [weak refresh, weak reading] in
                await refresh?.load()
                reading?.runEnded()
            }
        )
        return await pass.run()
    }
}

#if DEBUG
/// The UI tests' scheduler (RD24 decision 9): it records the pending
/// request in place of the system's scheduler, which the simulator does not
/// offer (assumption A2). Used only under a UI-test library directory.
@MainActor
final class RecordingBackgroundScheduler: BackgroundScheduler {
    private(set) var pending: Date?

    func submit(earliest: Date) throws {
        pending = earliest
    }

    func cancel() {
        pending = nil
    }
}

/// The UI tests' clock (RD24 decision 9): the launch's day offset, which
/// the debug delivery moves forward to a request's earliest start. Used
/// only under a UI-test library directory.
final class DebugClock: Sendable {
    private let offset: Mutex<TimeInterval>

    init(offset: TimeInterval) {
        self.offset = Mutex(offset)
    }

    func now() -> Date {
        Date().addingTimeInterval(offset.withLock { $0 })
    }

    /// Moves the clock forward to `date`; never back.
    func move(to date: Date) {
        offset.withLock { offset in
            offset += max(0, date.timeIntervalSince(Date().addingTimeInterval(offset)))
        }
    }
}
#endif
