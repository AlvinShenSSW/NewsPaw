import Foundation

/// An operation on the partitions that no other may overlap (RD19 review
/// round 4): one runs at a time in the whole app, whichever workspace is
/// shown, and across a lock and a new unlock.
///
/// To add an operation (RD20 adds the configuration file's import): add its
/// case here, then answer it in every switch of `PartitionOperations` —
/// the compiler lists them — and in the table of its documentation.
public enum PartitionOperation: Sendable, Equatable {
    /// Moving a category to the other partition, from the reading of its
    /// plan to the end of its run (RD19 decision 11).
    case categoryMove
    /// Clear Browsing Data: the adult browser's website data are removed.
    case clearBrowsingData
    /// Turn Off the Adult Partition, keeping its data or deleting them.
    case turnOff
}

/// Which partition operation runs, if any, and what it refuses meanwhile
/// (RD19 review round 4). It replaces one flag per operation: an operation
/// is begun by `begin(_:)`, which refuses while another runs and returns a
/// token, and ended only with that token, so that a refused or second
/// request cannot end a state it did not set.
///
/// What each operation refuses while it runs:
///
/// | While … runs | another partition operation | an unlock | an unlock carrying a move | an adult browser session | an edit of either library's categories or sources |
/// | --- | --- | --- | --- | --- | --- |
/// | a category move | refused | allowed | refused | allowed | refused |
/// | Clear Browsing Data | refused | refused | refused | refused | allowed |
/// | Turn Off / Delete | refused | refused | refused | refused | allowed |
///
/// A lock is always allowed (RD19 criterion 12): a move goes on through it,
/// and Turn Off locks first itself.
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

    /// Whether an unlock is refused: not during a move, whose run goes on
    /// across a lock and a new unlock (decision 11), and while the adult
    /// browser's data are cleared or removed.
    public var refusesUnlock: Bool {
        switch running {
        case nil, .categoryMove: false
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
    /// removed. A move touches no browser data.
    public var refusesAdultSessions: Bool {
        switch running {
        case nil, .categoryMove: false
        case .clearBrowsingData, .turnOff: true
        }
    }

    /// Whether the categories and sources of both libraries are kept from
    /// every change: the category editor, row moves and deletions, the
    /// source editor, Add source's save and the source rows' actions.
    /// During a move, because it copies and deletes them (a change made
    /// then would be lost with the deletion). Clear touches no library;
    /// Turn Off locks first, which drops the adult workspace, and leaves
    /// the normal library alone.
    public var refusesLibraryEdits: Bool {
        switch running {
        case .categoryMove: true
        case nil, .clearBrowsingData, .turnOff: false
        }
    }
}
