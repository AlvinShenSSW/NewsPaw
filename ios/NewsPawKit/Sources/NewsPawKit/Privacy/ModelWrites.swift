import Foundation

/// The writes of model slots and keys the owner started, in every workspace
/// of the app, a dropped one included (gate review of batch 2): a write
/// begins only while no partition operation refuses it, and an import's
/// write waits for every one under way before it reads a library.
@MainActor
public final class ModelWrites {
    private var running: [UUID: Task<Void, Never>] = [:]

    public init() {}

    /// Whether a write is under way.
    public var isRunning: Bool {
        !running.isEmpty
    }

    /// Starts `work` unless `refused`; returns whether it started. Nothing
    /// awaits between the check and the start.
    @discardableResult
    public func start(refused: Bool, _ work: @escaping @MainActor () async -> Void) -> Bool {
        guard !refused else { return false }
        let id = UUID()
        running[id] = Task { @MainActor [weak self] in
            await work()
            self?.running[id] = nil
        }
        return true
    }

    /// Returns once every write started before the call has ended.
    public func settle() async {
        for task in Array(running.values) {
            await task.value
        }
    }
}
