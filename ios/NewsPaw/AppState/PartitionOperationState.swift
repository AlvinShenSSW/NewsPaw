import NewsPawKit
import Observation

/// The app's one partition operation state (RD19 review round 4): which of
/// a category move, Clear Browsing Data and Turn Off / Delete runs, and
/// what is refused meanwhile (`PartitionOperations`, whose documentation
/// holds the table). One object for the app, given to both workspaces
/// through their parts, so that a workspace made by a new unlock, or the
/// normal one shown after a lock, sees an operation an earlier workspace
/// began.
@MainActor @Observable
final class PartitionOperationState {
    private(set) var operations = PartitionOperations()

    /// The operation that runs, if any.
    var running: PartitionOperation? {
        operations.running
    }

    /// Begins `operation`: `nil` while another runs. Nothing awaits
    /// between the check and the setting.
    func begin(_ operation: PartitionOperation) -> PartitionOperations.Token? {
        operations.begin(operation)
    }

    /// Ends the operation `token` began; any other token changes nothing.
    func end(_ token: PartitionOperations.Token) {
        operations.end(token)
    }

    var refusesUnlock: Bool { operations.refusesUnlock }
    var refusesUnlockCarryingMove: Bool { operations.refusesUnlockCarryingMove }
    var refusesAdultSessions: Bool { operations.refusesAdultSessions }
    var refusesLibraryEdits: Bool { operations.refusesLibraryEdits }
    var refusesModelEdits: Bool { operations.refusesModelEdits }

    /// The model-slot and key writes under way in any workspace (gate
    /// review of batch 2): an import's write waits for them.
    let modelWrites = ModelWrites()

    /// Starts a write of model slots or keys unless an operation refuses
    /// it; returns whether it started.
    func startModelWrite(_ work: @escaping @MainActor () async -> Void) -> Bool {
        modelWrites.start(refused: refusesModelEdits, work)
    }
}
