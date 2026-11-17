import Foundation

/// How a background pass ended. Without a payload: what the pass did is in
/// the library and the run record, not here.
public enum BackgroundPassResult: Sendable, Hashable, CaseIterable {
    /// No refresh was due (also for "Manual Only"); nothing was collected.
    case notDue
    /// The library was collected: each source's own outcome is its status,
    /// as in any refresh.
    case collected
    /// The collection was cut or cancelled, or the run ended before it
    /// started: what was collected stays, and nothing was recorded.
    case cancelled
    /// Whether a refresh was due, or what to collect, could not be read.
    case failed
}

/// What a background run does with the normal library (spec N04; RD24
/// approach 5): when a refresh is due, one ordinary whole-library refresh
/// through the library's own refresher, cut `cut` after the pass starts;
/// then the automatic title translation of the library's own translator,
/// counted and limited as always (N11). On every branch it then waits for
/// that translator to settle, until the run is cancelled or released.
///
/// It never cleans up, reads a body or an image, or stops the translator:
/// the translator is the interface's.
@MainActor
public struct BackgroundPass {
    /// How long the pass collects at most.
    public static let standardCut = Duration.seconds(15)

    private let library: Library
    private let refresher: Refresher
    private let translator: TitleTranslator
    private let interval: RefreshInterval
    private let control: BackgroundPassControl
    private let cut: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let afterCollection: @MainActor () async -> Void

    /// - Parameters:
    ///   - library: the normal library; any other is a programming error.
    ///   - refresher: the library's one refresher.
    ///   - translator: the library's one translator.
    ///   - interval: the refresh interval, read at the run's start.
    ///   - control: the run's control.
    ///   - cut: how long after the pass starts the collection is cut.
    ///   - sleep: how the cut waits (tests release it by hand).
    ///   - afterCollection: what the app does when the collection ended and
    ///     was not cancelled, before the translator resumes (it reads the
    ///     recorded time again for the status line).
    public init(
        library: Library, refresher: Refresher, translator: TitleTranslator, interval: RefreshInterval,
        control: BackgroundPassControl, cut: Duration = BackgroundPass.standardCut,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        afterCollection: @escaping @MainActor () async -> Void = {}
    ) {
        precondition(library.partition == .normal, "a background pass runs on the normal library only")
        self.library = library
        self.refresher = refresher
        self.translator = translator
        self.interval = interval
        self.control = control
        self.cut = cut
        self.sleep = sleep
        self.afterCollection = afterCollection
    }

    public func run() async -> BackgroundPassResult {
        let cutting = Cut()
        let control = control
        let refresher = refresher
        let sleep = sleep
        let cut = cut
        let timer = Task { @MainActor in
            do {
                try await sleep(cut)
            } catch {
                return
            }
            guard !Task.isCancelled, !control.hasEnded else { return }
            cutting.happened = true
            if control.isCollecting {
                refresher.cancelAll()
            }
        }
        let result = await collectIfDue(cutting)
        timer.cancel()
        // The time ran out: no further request, and no wait.
        guard !control.hasEnded else { return result }
        let wait = Task { await translator.untilSettled() }
        control.setWaitEnder { wait.cancel() }
        await wait.value
        return result
    }

    /// Whether the cut came.
    @MainActor
    private final class Cut {
        var happened = false
    }

    private func collectIfDue(_ cutting: Cut) async -> BackgroundPassResult {
        guard !control.hasEnded else { return .cancelled }
        let due: Bool
        do {
            due = try await library.refreshIsDue(every: interval)
        } catch {
            return .failed
        }
        guard due else { return .notDue }
        // Rechecked after the read: a run that expired, came to the front
        // or was cut meanwhile starts no collection (the entry's own due
        // check collects then).
        guard !control.hasEnded, !cutting.happened else { return .cancelled }
        control.collectionStarted()
        let results: [UUID: Refresher.SourceResult]
        do {
            results = try await refresher.refresh(.library)
        } catch {
            control.collectionEnded()
            return .failed
        }
        control.collectionEnded()
        if control.isCancelled {
            return .cancelled
        }
        let result: BackgroundPassResult = results.values.contains(.cancelled) ? .cancelled : .collected
        await afterCollection()
        // Rechecked after the app's step: no request after the time ran
        // out. Released, the translator resumes as after any refresh.
        guard !control.isCancelled else { return result }
        await translator.resume(after: .refreshEnded)
        return result
    }
}
