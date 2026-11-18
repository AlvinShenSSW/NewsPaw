import Foundation

/// One preparation that several callers wait for (RD24 approach 7): the
/// opening of the library, which the scene's start and a background run
/// share. It runs once at a time; a failed one is forgotten, so that the
/// next wait starts it again; a successful one is not run again.
///
/// A caller that asks to stop on cancellation (the background action,
/// review G1) returns `.abandoned` as soon as its task is cancelled, and
/// the preparation goes on for the other callers and for a scene that may
/// connect later.
@MainActor
public final class SharedPreparation {
    public enum Outcome: Sendable {
        /// The preparation ended: `nil` when it succeeded, else its error.
        case finished((any Error)?)
        /// The caller's task was cancelled first; the preparation goes on.
        case abandoned
    }

    private var running: Task<Void, Never>?
    private var succeeded = false
    private var waiters: [UUID: CheckedContinuation<Outcome, Never>] = [:]

    public init() {}

    /// Whether a preparation is under way.
    public var isRunning: Bool {
        running != nil
    }

    /// Waits for the preparation, starting `work` when none is under way.
    ///
    /// - Parameter stopsOnCancellation: whether the wait ends when the
    ///   calling task is cancelled.
    public func wait(stopsOnCancellation: Bool, starting work: @escaping @MainActor () async -> (any Error)?) async -> Outcome {
        if succeeded {
            return .finished(nil)
        }
        if stopsOnCancellation, Task.isCancelled {
            return .abandoned
        }
        if running == nil {
            running = Task { [weak self] in
                let error = await work()
                self?.finish(error)
            }
        }
        let id = UUID()
        guard stopsOnCancellation else {
            return await withCheckedContinuation { waiters[id] = $0 }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiters[id] = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.abandon(id) }
        }
    }

    private func abandon(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: .abandoned)
    }

    private func finish(_ error: (any Error)?) {
        running = nil
        succeeded = error == nil
        let all = waiters
        waiters = [:]
        for waiter in all.values {
            waiter.resume(returning: .finished(error))
        }
    }
}
