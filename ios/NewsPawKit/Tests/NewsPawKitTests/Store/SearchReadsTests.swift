import Foundation
@testable import NewsPawKit
import Testing

/// RD25 criterion 5's queue line: superseded search reads are dropped
/// before they touch the database and before they apply a page.
///
/// The queue is a stand-in built like the reading model's `enqueue`: each
/// operation waits for the one queued before it, on the main actor. A first
/// operation holds it until the test releases a continuation, so that the
/// interleaving is held rather than slept for.
@MainActor
@Suite("Search reads")
struct SearchReadsTests {
    /// A serial queue, a held head, the bookkeeping and what the reads did.
    @MainActor
    final class Harness {
        var reads = SearchReads()
        private var last: Task<Void, Never>?
        private var hold: CheckedContinuation<Void, Never>?
        private var holding: Task<Void, Never>?
        /// The queries whose database read ran, in order.
        private(set) var databaseReads: [SearchQuery] = []
        /// The reads whose page was applied.
        private(set) var applied: [SearchReads.Read] = []
        /// Run once by the next read at its await, after its `mayRead`.
        var duringRead: (@MainActor () async -> Void)?
        /// The continuation that ends a read held by `holdInsideNextRead`.
        private var insideRead: CheckedContinuation<Void, Never>?

        /// Queues an operation that waits for `release()`.
        func holdQueue() async {
            await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
                holding = enqueue {
                    await withCheckedContinuation { continuation in
                        self.hold = continuation
                        started.resume()
                    }
                }
            }
        }

        /// Queues `read` and returns once it is inside its read, held there
        /// until `releaseRead()`.
        func queueHeldInsideItsRead(_ read: SearchReads.Read) async -> Task<Void, Never> {
            var task: Task<Void, Never>?
            await withCheckedContinuation { (reached: CheckedContinuation<Void, Never>) in
                duringRead = {
                    await withCheckedContinuation { continuation in
                        self.insideRead = continuation
                        reached.resume()
                    }
                }
                task = queue(read)
            }
            return task!
        }

        func releaseRead() {
            insideRead?.resume()
            insideRead = nil
        }

        func release() {
            hold?.resume()
            hold = nil
        }

        /// Queues `read` as the reading model does: `mayRead` before the
        /// database is touched, `mayApply` after the read, then `didApply`.
        @discardableResult
        func queue(_ read: SearchReads.Read) -> Task<Void, Never> {
            enqueue {
                guard self.reads.mayRead(read) else { return }
                self.databaseReads.append(read.query)
                // The read's await: the main actor is free meanwhile.
                if let hook = self.duringRead {
                    self.duringRead = nil
                    await hook()
                } else {
                    await Task.yield()
                }
                guard self.reads.mayApply(read) else { return }
                self.applied.append(read)
                self.reads.didApply(read)
            }
        }

        /// Waits for everything queued so far.
        func drain() async {
            await enqueue {}.value
        }

        private func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
            let previous = last
            let task = Task { @MainActor in
                _ = await previous?.value
                await operation()
            }
            last = task
            return task
        }
    }

    private let position = ArticlePosition(shownAt: "2026-11-17 10:00:00.000", firstSeenAt: "2026-11-17 10:00:00.000", rowID: 42)

    @Test("reads for three successive queries queued behind a held queue: on release exactly one database read runs, for the last query, and its page is applied once")
    func supersededReadsDoNotRead() async throws {
        let harness = Harness()
        await harness.holdQueue()
        for text in ["苹", "苹果", "苹果 芯片"] {
            harness.queue(harness.reads.firstPage(of: SearchQuery(text)!))
        }
        #expect(harness.databaseReads.isEmpty)

        harness.release()
        await harness.drain()

        #expect(harness.databaseReads == [SearchQuery("苹果 芯片")!])
        #expect(harness.applied.count == 1)
        #expect(harness.applied.first?.cursor == nil)
    }

    @Test("a read that completes after a newer query was asked for is not applied")
    func supersededAfterTheRead() async throws {
        let harness = Harness()
        let first = harness.reads.firstPage(of: SearchQuery("kestrel")!)
        let running = await harness.queueHeldInsideItsRead(first)
        // The read is past `mayRead` and held at its await: a newer query
        // is asked for before it applies.
        let second = harness.reads.firstPage(of: SearchQuery("kestrels")!)
        harness.releaseRead()
        await running.value
        harness.queue(second)
        await harness.drain()

        #expect(harness.databaseReads == [SearchQuery("kestrel")!, SearchQuery("kestrels")!])
        #expect(harness.applied.map(\.query) == [SearchQuery("kestrels")!])
    }

    @Test("a next-page read of an older generation does not read; a cleared query reads nothing")
    func olderGenerationNextPage() async throws {
        let harness = Harness()
        let first = harness.reads.firstPage(of: SearchQuery("kestrel")!)
        harness.queue(first)
        await harness.drain()
        let next = try #require(harness.reads.page(after: position))
        await harness.holdQueue()
        harness.queue(next)
        _ = harness.reads.firstPage(of: SearchQuery("osprey")!)
        harness.release()
        await harness.drain()
        #expect(harness.databaseReads == [SearchQuery("kestrel")!])

        // No query: nothing asked for before the clearing reads.
        let osprey = harness.reads.firstPage(of: SearchQuery("osprey")!)
        await harness.holdQueue()
        harness.queue(osprey)
        harness.reads.clear()
        harness.release()
        await harness.drain()
        #expect(harness.databaseReads == [SearchQuery("kestrel")!])
        #expect(harness.reads.page(after: position) == nil)
    }

    @Test("a second first-page read of the same query (a run's end) is a new generation and reads; a page already applied is not applied twice")
    func sameQueryAgainAndDuplicatePages() async throws {
        let harness = Harness()
        let query = SearchQuery("kestrel")!
        harness.queue(harness.reads.firstPage(of: query))
        await harness.drain()
        harness.queue(harness.reads.firstPage(of: query))
        await harness.drain()
        #expect(harness.databaseReads == [query, query])
        #expect(harness.applied.map(\.generation) == [1, 2])

        // The same next page asked for twice: read and applied once.
        let next = try #require(harness.reads.page(after: position))
        harness.queue(next)
        harness.queue(next)
        await harness.drain()
        #expect(harness.databaseReads == [query, query, query])
        #expect(harness.applied.map(\.cursor) == [nil, nil, position])
        // The first page of this generation is not applied again either.
        let again = SearchReads.Read(query: query, generation: harness.reads.generation, cursor: nil)
        #expect(!harness.reads.mayRead(again))
    }

    @Test("no next page is asked for while a newer first page is queued or in flight: the rows shown are the previous query's (review R2)")
    func noNextPageBeforeTheFirstPageApplies() async throws {
        let harness = Harness()
        // Query A's first page is shown.
        harness.queue(harness.reads.firstPage(of: SearchQuery("kestrel")!))
        await harness.drain()
        #expect(harness.reads.page(after: position) != nil)
        // B's first page is asked for and held inside its read; the rows
        // shown, and their last position, are still A's.
        let first = harness.reads.firstPage(of: SearchQuery("osprey")!)
        #expect(harness.reads.page(after: position) == nil)
        let running = await harness.queueHeldInsideItsRead(first)
        #expect(harness.reads.page(after: position) == nil)
        harness.releaseRead()
        await running.value
        // B's first page is applied: its own rows give the next cursor.
        #expect(harness.applied.last?.query == SearchQuery("osprey")!)
        let next = try #require(harness.reads.page(after: position))
        #expect(next.query == SearchQuery("osprey")! && next.generation == first.generation)
        // A clearing, then a new query: again none until it applies.
        harness.reads.clear()
        #expect(harness.reads.page(after: position) == nil)
    }
}
