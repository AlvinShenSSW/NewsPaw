import Synchronization

/// Whether the app is in front (RD23 review round 3): one value for the
/// app, set by the app on the main actor when the scene's phase changes and
/// first from the scene's real state at start, never assumed. The overview
/// writer reads it where it decides to start work and immediately before
/// every request, so no event has to reach it in time: a writer made while
/// the app is in the background, or a background whose cancellation is
/// still on its way, sends nothing.
public final class AppFront: Sendable {
    private let state: Mutex<Bool>

    public init(isInFront: Bool) {
        state = Mutex(isInFront)
    }

    public var isInFront: Bool {
        state.withLock { $0 }
    }

    public func set(isInFront: Bool) {
        state.withLock { $0 = isInFront }
    }
}
