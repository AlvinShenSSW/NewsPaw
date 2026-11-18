import Foundation

/// What ends a background pass early (RD24 approach 4), and what the app's
/// entry waits for. Made for one run over the normal library's refresher.
///
/// - `cancel()` is the system's time running out: the refresher is
///   cancelled synchronously, and the translator wait ends.
/// - `release()` is the app coming to the front: the cut is disarmed and
///   the wait ends; nothing is cancelled, and a collection under way goes
///   on as the ordinary refresh.
///
/// Whichever comes first holds; the other then does nothing.
@MainActor
public final class BackgroundPassControl {
    public private(set) var isCancelled = false
    public private(set) var isReleased = false
    /// Whether the pass's collection is under way.
    public private(set) var isCollecting = false

    private let refresher: Refresher
    /// Ends the pass's translator wait.
    private var endWait: (@MainActor () -> Void)?
    private var collectionWaiters: [CheckedContinuation<Void, Never>] = []

    public init(refresher: Refresher) {
        self.refresher = refresher
    }

    /// Whether the run was cancelled or released.
    public var hasEnded: Bool {
        isCancelled || isReleased
    }

    public func cancel() {
        guard !hasEnded else { return }
        isCancelled = true
        refresher.cancelAll()
        endTheWait()
    }

    public func release() {
        guard !hasEnded else { return }
        isReleased = true
        endTheWait()
    }

    /// Returns when the pass's collection has ended, the recorded refresh
    /// time with it; at once when none is under way.
    public func untilCollectionEnds() async {
        guard isCollecting else { return }
        await withCheckedContinuation { collectionWaiters.append($0) }
    }

    // MARK: - For the pass

    func collectionStarted() {
        isCollecting = true
    }

    func collectionEnded() {
        isCollecting = false
        let waiters = collectionWaiters
        collectionWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Sets what ends the wait; called at once when the run has ended.
    func setWaitEnder(_ end: @escaping @MainActor () -> Void) {
        if hasEnded {
            end()
        } else {
            endWait = end
        }
    }

    private func endTheWait() {
        let end = endWait
        endWait = nil
        end?()
    }
}

/// One background run (RD24 approach 4): the work runs in a task of its
/// own, and `run()` returns when the work ends, when the calling task is
/// cancelled (the system's time ran out), or when the app comes to the
/// front. On the second, `control.cancel()` is called on the main actor
/// before `run()` returns; on the third, `control.release()`, and the work
/// goes on by itself. The first of the three decides; the others then do
/// nothing.
@MainActor
public final class BackgroundRun {
    /// How the run ended.
    public enum Ending: Sendable, Hashable {
        case ended(BackgroundPassResult)
        case expired
        case cameToFront
    }

    private let control: BackgroundPassControl
    private let work: @MainActor () async -> BackgroundPassResult
    private var ending: Ending?
    private var waiting: CheckedContinuation<Ending, Never>?
    private var started = false

    public init(control: BackgroundPassControl, work: @escaping @MainActor () async -> BackgroundPassResult) {
        self.control = control
        self.work = work
    }

    /// Runs the work once.
    public func run() async -> Ending {
        precondition(!started, "a background run runs once")
        started = true
        let work = work
        Task { @MainActor [weak self] in
            let result = await work()
            self?.finish(.ended(result))
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Ending, Never>) in
                if let ending {
                    continuation.resume(returning: ending)
                } else {
                    waiting = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.expired() }
        }
    }

    /// The app came to the front: the work goes on as the ordinary
    /// refresh, and `run()` returns now.
    public func cameToFront() {
        guard ending == nil else { return }
        control.release()
        finish(.cameToFront)
    }

    /// The calling task was cancelled: the refresher is cancelled, on the
    /// main actor, before `run()` returns.
    private func expired() {
        guard ending == nil else { return }
        control.cancel()
        finish(.expired)
    }

    private func finish(_ value: Ending) {
        guard ending == nil else { return }
        ending = value
        let waiting = waiting
        self.waiting = nil
        waiting?.resume(returning: value)
    }
}
