import Foundation
import Observation

/// The one refresh engine of one library (spec N04; RD06 decisions 1, 5, 6
/// and 13). Every collection of the library goes through it, whatever
/// started it, and at most `limit` of them are in flight at once. A source a
/// run already holds is joined, never requested a second time.
///
/// It lives on the main actor so that `cancelAll()` can be called
/// synchronously from the system's background-time expiry handler; fetching
/// and storing run off the main actor inside `FeedCollector`.
@MainActor @Observable
public final class Refresher {
    /// How one source's collection in a run ended.
    public enum SourceResult: Sendable, Equatable {
        /// The collector's outcome.
        case outcome(CollectionOutcome)
        /// Storing failed.
        case storageError(LibraryError)
        /// The engine was cancelled before the collection ended; nothing was
        /// recorded for the source.
        case cancelled
    }

    /// At most this many collections are in flight (decision 1).
    public static let standardLimit = 4

    /// The sources a run holds, from the start of that run until their own
    /// collection has ended: what a row shows as "Updating" and what makes
    /// the status line say "Updating…".
    public var collecting: Set<UUID> {
        Set(held.keys)
    }

    /// Called on the main actor each time a source's collection ends, so
    /// that the lists can be read again without waiting for the whole run.
    @ObservationIgnored public var onCollectionEnded: (@MainActor (UUID) -> Void)?

    /// The collection held for each source, with a token that tells it apart
    /// from a later one for the same source.
    private var held: [UUID: (token: Int, task: Task<SourceResult, Never>)] = [:]
    @ObservationIgnored private var nextToken = 0
    /// Raised by every `cancelAll()`; a run that sees it change was cancelled.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var freeSlots: Int
    /// Collections waiting for a slot, first come first served. A freed slot
    /// is handed to the first of them directly, so a newcomer can never take
    /// it in between (measured in the RD06 debate: free-then-wake exceeds the
    /// limit).
    @ObservationIgnored private var waiters: [CheckedContinuation<Bool, Never>] = []

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let collector: FeedCollector

    public init(library: Library, transport: any Transport, limit: Int = standardLimit) {
        self.library = library
        collector = FeedCollector(transport: transport)
        freeSlots = max(1, limit)
    }

    /// Collects the targets of `scope` (`Library.refreshTargets`), joining
    /// any collection already held for one of them, and returns when every
    /// one has ended. A whole-library run then records its end time unless
    /// it was cancelled, or attempted at least one source and every attempt
    /// failed (decision 5); a run with no source to attempt counts. A
    /// category or source run records nothing.
    ///
    /// - Returns: each target's result.
    /// - Throws: a `LibraryError` when the targets cannot be read, and
    ///   `CancellationError` when the calling task is cancelled before they
    ///   are read; nothing is collected or recorded then. A caller cancelled
    ///   after the targets were read still waits for and gets the results
    ///   (the collections are not the caller's tasks), but the recorded time
    ///   may then go unwritten, because the write is made in the cancelled
    ///   task and is abandoned; the next entry refreshes again.
    @discardableResult
    public func refresh(_ scope: RefreshScope) async throws -> [UUID: SourceResult] {
        let generation = generation
        let targets = try await library.refreshTargets(scope)
        guard generation == self.generation else {
            return Dictionary(targets.map { ($0, .cancelled) }, uniquingKeysWith: { first, _ in first })
        }
        let tasks = targets.map { id in (id, held[id]?.task ?? start(id)) }
        var results: [UUID: SourceResult] = [:]
        for (id, task) in tasks {
            results[id] = await task.value
        }
        if scope == .library, generation == self.generation, Self.counts(results.values) {
            // A time that cannot be written leaves the run unrecorded, so
            // the next entry refreshes again.
            try? await library.setLastRefreshAt(library.now())
        }
        return results
    }

    /// Cancels every collection held and wakes every one waiting for a slot,
    /// which then ends without a request. Synchronous. A collection that
    /// had not ended records nothing (RD04). A refresh started afterwards
    /// collects normally.
    public func cancelAll() {
        generation += 1
        for entry in held.values {
            entry.task.cancel()
        }
        held.removeAll()
        let woken = waiters
        waiters.removeAll()
        for waiter in woken {
            waiter.resume(returning: false)
        }
    }

    // MARK: - Collections

    private func start(_ id: UUID) -> Task<SourceResult, Never> {
        nextToken += 1
        let token = nextToken
        let library = library
        let collector = collector
        let task = Task { @MainActor [weak self] () -> SourceResult in
            guard let self else { return .cancelled }
            let result = await self.collect(id, library: library, collector: collector)
            if self.held[id]?.token == token {
                self.held[id] = nil
            }
            self.onCollectionEnded?(id)
            return result
        }
        held[id] = (token, task)
        return task
    }

    private func collect(_ id: UUID, library: Library, collector: FeedCollector) async -> SourceResult {
        guard await acquireSlot() else { return .cancelled }
        defer { releaseSlot() }
        guard !Task.isCancelled else { return .cancelled }
        do {
            return .outcome(try await collector.collect(id, in: library))
        } catch is CancellationError {
            return .cancelled
        } catch let error as LibraryError {
            return .storageError(error)
        } catch {
            return .storageError(.storage(String(describing: error)))
        }
    }

    /// Takes a slot, waiting for one when none is free. Returns false when
    /// the collection was cancelled first.
    private func acquireSlot() async -> Bool {
        guard !Task.isCancelled else { return false }
        if freeSlots > 0 {
            freeSlots -= 1
            return true
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the slot to the first waiter, or frees it.
    private func releaseSlot() {
        if waiters.isEmpty {
            freeSlots += 1
        } else {
            waiters.removeFirst().resume(returning: true)
        }
    }

    /// Whether a whole-library run with these results counts as a refresh.
    private static func counts(_ results: some Collection<SourceResult>) -> Bool {
        var failed = false
        var succeeded = false
        for result in results {
            switch result {
            case .cancelled:
                return false
            case .outcome(.notModified), .outcome(.collected):
                succeeded = true
            case .outcome(.failed), .storageError:
                failed = true
            case .outcome(.nothingDone):
                break
            }
        }
        return succeeded || !failed
    }
}
