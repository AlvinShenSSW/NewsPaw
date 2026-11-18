import Foundation

/// An operation on the partitions that no other may overlap (RD19 review
/// round 4): one runs at a time in the whole app, whichever workspace is
/// shown, and across a lock and a new unlock.
///
/// To add an operation: add its case here, then answer it in every switch
/// of `PartitionOperations` — the compiler lists them — and in the table of
/// its documentation.
public enum PartitionOperation: Sendable, Equatable {
    /// Moving a category to the other partition, from the reading of its
    /// plan to the end of its run (RD19 decision 11).
    case categoryMove
    /// Clear Browsing Data: the adult browser's website data are removed.
    case clearBrowsingData
    /// Turn Off the Adult Partition, keeping its data or deleting them.
    case turnOff
    /// A configuration import's write (RD20 decision 5; batch 2): from the
    /// moment Merge or Replace is confirmed to the end of `AppModel`'s
    /// completion — one write per partition the import covers, then the
    /// reloads. Its preview, before, is not an operation.
    case configurationImport
}

/// Which partition operation runs, if any, and what it refuses meanwhile
/// (RD19 review round 4). It replaces one flag per operation: an operation
/// is begun by `begin(_:)`, which refuses while another runs and returns a
/// token, and ended only with that token, so that a refused or second
/// request cannot end a state it did not set.
///
/// What each operation refuses while it runs:
///
/// | While … runs | another partition operation | an unlock | an unlock carrying a move | an adult browser session | an edit of either library's categories or sources | a write of either library's model slots or keys |
/// | --- | --- | --- | --- | --- | --- | --- |
/// | a category move | refused | allowed | refused | allowed | refused | allowed |
/// | Clear Browsing Data | refused | refused | refused | refused | allowed | allowed |
/// | Turn Off / Delete | refused | refused | refused | refused | allowed | allowed |
/// | a configuration import's write | refused | allowed | refused | allowed | refused | refused |
///
/// A write of model slots or keys that runs when an import's write begins
/// ends first (`ModelWrites.settle`), as a queued category or source change
/// does.
///
/// A lock is always allowed (RD19 criterion 12): a move and an import's
/// write go on through it, and Turn Off locks first itself.
public struct PartitionOperations: Sendable, Equatable {
    /// The proof of having begun an operation; only it ends the operation.
    public struct Token: Sendable, Equatable {
        public let operation: PartitionOperation
        fileprivate let id: UUID
    }

    private var current: Token?

    public init() {}

    /// The operation that runs, if any.
    public var running: PartitionOperation? {
        current?.operation
    }

    /// Begins `operation`: `nil`, and nothing changed, while another runs.
    public mutating func begin(_ operation: PartitionOperation) -> Token? {
        guard current == nil else { return nil }
        let token = Token(operation: operation, id: UUID())
        current = token
        return token
    }

    /// Ends the operation that `token` began. Any other token changes
    /// nothing; returns whether it ended the running operation.
    @discardableResult
    public mutating func end(_ token: Token) -> Bool {
        guard current == token else { return false }
        current = nil
        return true
    }

    // MARK: - The table

    /// Whether an unlock is refused: not during a move or an import's
    /// write, which go on across a lock and a new unlock (decision 11; RD20
    /// criterion 13) — the new adult workspace's edits are refused by
    /// `refusesLibraryEdits` meanwhile — and while the adult browser's data
    /// are cleared or removed.
    public var refusesUnlock: Bool {
        switch running {
        case nil, .categoryMove, .configurationImport: false
        case .clearBrowsingData, .turnOff: true
        }
    }

    /// Whether an unlock that would carry a move across is refused: while
    /// any operation runs, since the move it carries could not begin.
    public var refusesUnlockCarryingMove: Bool {
        running != nil
    }

    /// Whether the adult browser makes no session: while its data are
    /// cleared or removed, so that no page keeps or writes back what is
    /// removed. A move and an import touch no browser data.
    public var refusesAdultSessions: Bool {
        switch running {
        case nil, .categoryMove, .configurationImport: false
        case .clearBrowsingData, .turnOff: true
        }
    }

    /// Whether the categories and sources of both libraries are kept from
    /// every change: the category editor, row moves and deletions, the
    /// source editor, Add source's save and the source rows' actions.
    /// During a move, because it copies and deletes them (a change made
    /// then would be lost with the deletion). During an import's write,
    /// because Merge adds to them and Replace updates and deletes them: a
    /// change made then would be overwritten, or would fail on a row Replace
    /// removed. Clear touches no library; Turn Off locks first, which drops
    /// the adult workspace, and leaves the normal library alone.
    public var refusesLibraryEdits: Bool {
        switch running {
        case .categoryMove, .configurationImport: true
        case nil, .clearBrowsingData, .turnOff: false
        }
    }

    /// Whether the model slots and keys of both libraries are kept from
    /// every write the owner starts — a slot saved or removed, a key added,
    /// replaced or removed, the primary's and the backup's (gate review of
    /// batch 2): during an import's write, because the import writes and
    /// removes slots and releases keychain items; a save that read a slot
    /// before the import's commit would write a reference back after it,
    /// naming an item the import removed. A move copies no slot; Clear and
    /// Turn Off touch no slot of a workspace that is shown.
    public var refusesModelEdits: Bool {
        switch running {
        case .configurationImport: true
        case nil, .categoryMove, .clearBrowsingData, .turnOff: false
        }
    }
}
