import Foundation
import GRDB
@testable import NewsPawKit
import Synchronization
import Testing

/// A feed transport for the background tests: every address answers a feed
/// of English stories named after it (fresh ones at each fetch), and an
/// address the test holds waits until released or cancelled — a cancelled
/// fetch throws `CancellationError`, as a cancelled request does.
final class HeldFeedTransport: Transport {
    private struct State {
        var received: [String] = []
        var held: Set<String> = []
        var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
        var fetches: [String: Int] = [:]
    }

    private let state = Mutex(State())
    /// How many stories each feed holds.
    let stories: Int

    init(stories: Int = 2) {
        self.stories = stories
    }

    var received: [String] {
        state.withLock { $0.received }
    }

    func hold(_ address: String) {
        state.withLock { _ = $0.held.insert(address) }
    }

    func release(_ address: String) {
        let waiting = state.withLock { state in
            state.held.remove(address)
            return state.waiting.removeValue(forKey: address) ?? []
        }
        for waiter in waiting {
            waiter.resume()
        }
    }

    func fetch(_ request: TransportRequest) async throws -> TransportResponse {
        let address = request.url.absoluteString
        let fetch = state.withLock { state in
            state.received.append(address)
            state.fetches[address, default: 0] += 1
            return state.fetches[address] ?? 1
        }
        if state.withLock({ $0.held.contains(address) }) {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let now = state.withLock { state in
                        guard state.held.contains(address) else { return true }
                        state.waiting[address, default: []].append(continuation)
                        return false
                    }
                    if now {
                        continuation.resume()
                    }
                }
            } onCancel: {
                self.release(address)
            }
            try Task.checkCancellation()
        }
        // The host's first label: the source's name and its own suffix.
        let slug = (request.url.host() ?? "feed").split(separator: ".").first.map(String.init) ?? "feed"
        let items: String = (1...stories).map { (number: Int) -> String in
            let name: String = "\(slug)-\(fetch)-\(number)"
            return "<item><title>Story \(name) about the harbour</title><guid>\(name)</guid><link>https://example.invalid/\(name)</link></item>"
        }.joined()
        return TransportResponse(finalURL: request.url, status: 200, headers: [:], body: Data(rssDocument(items).utf8))
    }
}

/// A sleep the tests end by hand that ends at once, by throwing, when its
/// task is cancelled: what the pass's cut waits with.
final class HandSleep: Sendable {
    private struct State {
        var asked: [Duration] = []
        var waiting: [UUID: CheckedContinuation<Void, any Error>] = [:]
        var woken = false
    }

    private let state = Mutex(State())

    var asked: [Duration] {
        state.withLock { $0.asked }
    }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let now = state.withLock { state in
                    state.asked.append(duration)
                    guard !state.woken else { return true }
                    state.waiting[id] = continuation
                    return false
                }
                if now {
                    continuation.resume()
                }
            }
        } onCancel: {
            let waiting = state.withLock { $0.waiting.removeValue(forKey: id) }
            waiting?.resume(throwing: CancellationError())
        }
    }

    /// Ends every sleep, now and later.
    func wake() {
        let all = state.withLock { state in
            state.woken = true
            defer { state.waiting = [:] }
            return Array(state.waiting.values)
        }
        for waiting in all {
            waiting.resume()
        }
    }
}

/// A flag a task sets and the test reads.
final class Flag: Sendable {
    private let value = Mutex(false)

    var isSet: Bool {
        value.withLock { $0 }
    }

    func set() {
        value.withLock { $0 = true }
    }
}

/// A scheduler that records what it was asked; it can refuse submissions.
@MainActor
final class RecordingScheduler: BackgroundScheduler {
    struct Refused: Error {}

    private(set) var pending: Date?
    private(set) var submissions: [Date] = []
    private(set) var cancellations = 0
    var refuses = false

    func submit(earliest: Date) throws {
        submissions.append(earliest)
        if refuses {
            throw Refused()
        }
        pending = earliest
    }

    func cancel() {
        cancellations += 1
        pending = nil
    }
}

/// The normal library with its translator (`TranslatorFixture`), a
/// refresher over a `HeldFeedTransport`, and helpers for a pass.
@MainActor
final class PassFixture {
    let base: TranslatorFixture
    let transport: HeldFeedTransport
    let refresher: Refresher
    let sleep = HandSleep()

    var library: Library { base.library }
    var translator: TitleTranslator { base.translator }
    var service: TranslationService { base.service }
    var clock: TestClock { base.clock }

    init(base: TranslatorFixture, stories: Int) {
        self.base = base
        transport = HeldFeedTransport(stories: stories)
        refresher = Refresher(library: base.library, transport: transport)
    }

    static func make(service: TranslationService = TranslationService(), stories: Int = 2) async throws -> PassFixture {
        PassFixture(base: try await TranslatorFixture.make(service: service), stories: stories)
    }

    func remove() {
        base.remove()
    }

    /// Adds a feed source; returns its id and address.
    func source(_ name: String) async throws -> (id: UUID, address: String) {
        let id = try await base.source(name)
        let source = try #require(try await library.pool.read { db in try Source.fetchOne(db, key: id.databaseKey) })
        return (id, source.url)
    }

    /// Starts the translator, and waits until it has nothing to do.
    func startTranslator() async {
        await base.start()
    }

    func pass(_ control: BackgroundPassControl, interval: RefreshInterval = .thirtyMinutes,
              afterCollection: @escaping @MainActor () async -> Void = {}) -> BackgroundPass {
        let sleep = sleep
        return BackgroundPass(
            library: library, refresher: refresher, translator: translator, interval: interval, control: control,
            sleep: { try await sleep.sleep($0) }, afterCollection: afterCollection
        )
    }

    /// Everything a collection may touch for one source: its row, its
    /// articles and its seen rows, as text.
    func state(of id: UUID) async throws -> [String] {
        try await library.pool.read { db in
            let key = id.databaseKey
            var lines: [String] = []
            for (table, column) in [("source", "id"), ("article", "source_id"), ("seen", "source_id")] {
                for row in try Row.fetchAll(db, sql: "SELECT * FROM \(table) WHERE \(column) = ? ORDER BY 1, 2", arguments: [key]) {
                    lines.append("\(table): " + row.databaseValues.map { $0.description }.joined(separator: "|"))
                }
            }
            return lines
        }
    }

    func articles(of source: UUID) async throws -> [UUID] {
        try await library.pool.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM article WHERE source_id = ?", arguments: [source.databaseKey])
                .compactMap(UUID.init(uuidString:))
        }
    }

    /// Waits, `TranslatorFixture.eventualBound` at most, until `condition`
    /// holds.
    func eventually(_ condition: @MainActor () async throws -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async rethrows {
        let deadline = ContinuousClock.now + TranslatorFixture.eventualBound
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("the condition did not hold within \(TranslatorFixture.eventualBound)", sourceLocation: sourceLocation)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
