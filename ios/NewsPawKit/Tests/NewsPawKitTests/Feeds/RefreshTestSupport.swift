import Foundation
import GRDB
@testable import NewsPawKit
import Synchronization
import Testing

/// A transport that answers each address from a closure, records every
/// request, and counts the requests in flight and the most at once.
final class CountingTransport: Transport {
    typealias Handler = @Sendable (URL) async throws -> TransportResponse

    private struct State {
        var received: [URL] = []
        var inFlight = 0
        var mostInFlight = 0
    }

    private let state = Mutex(State())
    private let handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    var received: [URL] {
        state.withLock { $0.received }
    }

    var mostInFlight: Int {
        state.withLock { $0.mostInFlight }
    }

    var inFlight: Int {
        state.withLock { $0.inFlight }
    }

    func requests(for address: String) -> Int {
        received.filter { $0.absoluteString == address }.count
    }

    func fetch(_ request: TransportRequest) async throws -> TransportResponse {
        state.withLock { state in
            state.received.append(request.url)
            state.inFlight += 1
            state.mostInFlight = max(state.mostInFlight, state.inFlight)
        }
        defer { state.withLock { $0.inFlight -= 1 } }
        return try await handler(request.url)
    }

    /// A feed of one item named after the address.
    static func feed(_ url: URL) -> TransportResponse {
        let slug = url.absoluteString.filter { $0.isLetter || $0.isNumber }
        let body = rssDocument("<item><guid>\(slug)</guid><link>https://example.invalid/item/\(slug)</link></item>")
        return TransportResponse(finalURL: url, status: 200, headers: [:], body: Data(body.utf8))
    }
}

/// A library with a clock and helpers to add sources of each kind.
struct RefreshFixture {
    let directory: URL
    let clock: TestClock
    let library: Library
    let categoryID: UUID

    static func make() async throws -> RefreshFixture {
        let directory = try makeTemporaryDirectory()
        let clock = TestClock()
        let library = try await LibraryStore(directory: directory, cacheRoot: directory.appending(path: "Images"), now: clock.now)
            .openNormal()
        let category = try await library.createCategory(name: "News", icon: .newspaper)
        return RefreshFixture(directory: directory, clock: clock, library: library, categoryID: category.id)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Adds a feed source at `https://<name>.example.invalid/feed`.
    @discardableResult
    func addFeed(_ name: String, category: UUID? = nil, paused: Bool = false, kind: SourceKind = .feed) async throws -> Source {
        var source = Sample.source(in: category ?? categoryID, url: Self.address(name), name: name, at: clock.now())
        source.paused = paused
        source.kind = kind
        try await library.insert(source)
        return source
    }

    static func address(_ name: String) -> String {
        "https://\(name).example.invalid/feed"
    }

    func source(_ id: UUID) async throws -> Source {
        try #require(try await library.pool.read { db in try Source.fetchOne(db, key: id.databaseKey) })
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
}
