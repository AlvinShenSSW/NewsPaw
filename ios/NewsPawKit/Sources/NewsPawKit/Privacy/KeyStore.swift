import Foundation
import Synchronization

/// Where one partition's model keys are kept (spec N08, section 6; RD13
/// decision 2): the replaceable interface between the package and the
/// device keychain. A store is made for one partition and reaches only that
/// partition's items; `LibraryModels` refuses a store of another partition.
public protocol KeyStore: Sendable {
    /// The partition whose keys this store holds.
    var partition: Partition { get }

    /// Stores `key` under a new reference and returns the reference.
    ///
    /// - Throws: `KeyStoreError.refused` when the store does not take it.
    func add(_ key: SecretKey) throws -> String

    /// The key stored under `reference`, or `nil` when there is no such
    /// item.
    ///
    /// - Throws: `KeyStoreError.refused` when the store cannot be read.
    func read(_ reference: String) throws -> SecretKey?

    /// Removes the item of `reference`. "No such item" counts as removed.
    ///
    /// - Throws: `KeyStoreError.refused` for any other failure.
    func remove(_ reference: String) throws
}

/// Why a key store failed. It carries the store's status code only.
public enum KeyStoreError: Error, Sendable, Hashable {
    case refused(status: Int32)
}

/// A key store in memory, for the package tests (spec N13: the keychain is
/// one of the stand-in points). It can be told to refuse adds or removals
/// and to lose an item, as a restore onto another device would.
final class InMemoryKeyStore: KeyStore {
    private struct State {
        var items: [String: SecretKey] = [:]
        var refuseAdds = false
        var refuseRemovals = false
        var refuseReads = false
    }

    let partition: Partition
    private let state = Mutex(State())

    init(partition: Partition = .normal) {
        self.partition = partition
    }

    func add(_ key: SecretKey) throws -> String {
        try state.withLock { state in
            if state.refuseAdds {
                throw KeyStoreError.refused(status: -1)
            }
            let reference = UUID().uuidString
            state.items[reference] = key
            return reference
        }
    }

    func read(_ reference: String) throws -> SecretKey? {
        try state.withLock { state in
            if state.refuseReads {
                throw KeyStoreError.refused(status: -2)
            }
            return state.items[reference]
        }
    }

    func remove(_ reference: String) throws {
        try state.withLock { state in
            if state.refuseRemovals {
                throw KeyStoreError.refused(status: -3)
            }
            state.items[reference] = nil
        }
    }

    // MARK: - For tests

    var references: Set<String> {
        state.withLock { Set($0.items.keys) }
    }

    var refuseAdds: Bool {
        get { state.withLock { $0.refuseAdds } }
        set { state.withLock { $0.refuseAdds = newValue } }
    }

    var refuseRemovals: Bool {
        get { state.withLock { $0.refuseRemovals } }
        set { state.withLock { $0.refuseRemovals = newValue } }
    }

    var refuseReads: Bool {
        get { state.withLock { $0.refuseReads } }
        set { state.withLock { $0.refuseReads = newValue } }
    }

    /// Loses the item of `reference` without any row knowing.
    func lose(_ reference: String) {
        state.withLock { _ = $0.items.removeValue(forKey: reference) }
    }
}
