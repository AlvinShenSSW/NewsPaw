import Foundation
import Observation

/// Shared save path for every redesigned page (interaction-spec §2.2–§2.3).
///
/// A change is expressed as a function of the current stored record, not as a stale copy,
/// so a revision bumped in the background (the 3-second poll, a Telegram command, a probe
/// result) is merged: the record is fetched again and the same change is applied to it.
/// Only a second conflict in a row reaches the owner.
@MainActor @Observable
final class EditorState {
    typealias Load = @MainActor () async throws -> (revision: Int, document: [String: Any])
    typealias Store = @MainActor (_ document: [String: Any], _ revision: Int) async throws -> Void
    typealias Change = ([String: Any]) throws -> [String: Any]

    private(set) var busy = false
    private(set) var failure: BackendError?
    private(set) var savedAt: Date?

    @ObservationIgnored private let load: Load
    @ObservationIgnored private let store: Store
    @ObservationIgnored private let saved: @MainActor () async -> Void
    @ObservationIgnored private let clock: () -> Date

    init(
        load: @escaping Load,
        store: @escaping Store,
        saved: @escaping @MainActor () async -> Void = {},
        clock: @escaping () -> Date = Date.init
    ) {
        self.load = load
        self.store = store
        self.saved = saved
        self.clock = clock
    }

    /// Edits the configuration document through `client`.
    convenience init(client: BackendClient, saved: @escaping @MainActor () async -> Void = {}) {
        self.init(
            load: { try await client.configDocument() },
            store: { try await client.saveConfig($0, revision: $1) },
            saved: saved
        )
    }

    /// Applies `change` to the newest stored record. Returns whether it was saved.
    @discardableResult
    func apply(_ change: Change) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        failure = nil
        for attempt in 0..<2 {
            do {
                let current = try await load()
                try await store(try change(current.document), current.revision)
                savedAt = clock()
                await saved()
                return true
            } catch let error as BackendError where error.isConflict && attempt == 0 {
                continue
            } catch let error as BackendError {
                failure = error
                return false
            } catch {
                failure = BackendError(code: error is SocketFailure ? "backend_unreachable" : "invalid_reply")
                return false
            }
        }
        return false
    }

    func dismissFailure() { failure = nil }
}
