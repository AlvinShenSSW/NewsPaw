import Foundation
import Synchronization

/// The one way the app reaches an `OverviewWriter` (RD23 decision 12;
/// review round 1, G1): every call goes after the calls sent before it, so
/// that a change of the reading language and a due check reach the writer
/// in the order made, and a manual job is queued only after them. A manual
/// job's own work does not hold the calls sent after it.
public final class OverviewChain: Sendable {
    public let writer: OverviewWriter
    private let last = Mutex<Task<Void, Never>?>(nil)

    public init(writer: OverviewWriter) {
        self.writer = writer
    }

    /// Sends `call` after every call sent before it.
    @discardableResult
    public func send(_ call: @escaping @Sendable (OverviewWriter) async -> Void) -> Task<Void, Never> {
        let writer = writer
        return last.withLock { last in
            let previous = last
            let task = Task {
                await previous?.value
                await call(writer)
            }
            last = task
            return task
        }
    }

    /// A manual job (Write Overview, Rewrite, Retry), and how it ended. It
    /// is queued in the writer after every call sent before it — a change
    /// of the reading language held behind a due check included —, and
    /// calls sent after it do not wait for its work.
    public func write(category: UUID) async -> OverviewWriteOutcome {
        await withCheckedContinuation { continuation in
            send { writer in
                await writer.enqueueWrite(category: category) { continuation.resume(returning: $0) }
            }
        }
    }

    /// The app entered the background: the writer's job in flight is
    /// cancelled at once, **not** after the calls sent before it — a due
    /// check held at its read cannot delay it (review round 3). Whether
    /// anything is sent meanwhile is decided by `AppFront`, which the app
    /// has already set.
    @discardableResult
    public func enteredBackground() -> Task<Void, Never> {
        let writer = writer
        return Task { await writer.enteredBackground() }
    }
}
