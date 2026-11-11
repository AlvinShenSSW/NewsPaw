import Foundation
import Network
@testable import NewsPawKit
import Synchronization
import Testing

// MARK: - Fixtures

/// The synthetic feeds under `Fixtures/feeds/`.
enum FeedFixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/feeds"),
            "Missing feed fixture \(name)"
        )
        return try Data(contentsOf: url)
    }
}

/// The final address the parser tests pretend their documents came from.
let fixtureBase = URL(string: "https://example.invalid/feed.xml")!

func parse(_ data: Data, charset: String? = nil, base: URL = fixtureBase) -> ParsedFeed? {
    FeedParser.parse(data, charset: charset, baseURL: base)
}

func parse(_ text: String, charset: String? = nil, base: URL = fixtureBase) -> ParsedFeed? {
    parse(Data(text.utf8), charset: charset, base: base)
}

/// A minimal RSS 2.0 document around `items`.
func rssDocument(_ items: String, channel: String = "<title>Test channel</title>") -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:media="http://search.yahoo.com/mrss/">
    <channel>\(channel)
    \(items)
    </channel>
    </rss>
    """
}

/// A date from an ISO 8601 text, for expectations.
func date(_ text: String) -> Date {
    FeedDate.parse(text)!
}

// MARK: - Fake transport

/// A transport that answers from a closure and records what it was asked.
final class FakeTransport: Transport {
    typealias Handler = @Sendable (TransportRequest) async throws -> TransportResponse

    private let handler: Handler
    private let requests = Mutex<[TransportRequest]>([])

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    var received: [TransportRequest] {
        requests.withLock { $0 }
    }

    func fetch(_ request: TransportRequest) async throws -> TransportResponse {
        requests.withLock { $0.append(request) }
        return try await handler(request)
    }

    /// Always gives the same answer.
    static func answering(
        status: Int = 200, body: Data = Data(), headers: [String: String] = [:], finalURL: URL = fixtureBase
    ) -> FakeTransport {
        FakeTransport { _ in TransportResponse(finalURL: finalURL, status: status, headers: headers, body: body) }
    }

    /// Always fails with `failure`.
    static func failing(_ failure: TransportFailure) -> FakeTransport {
        FakeTransport { _ in throw failure }
    }
}

/// A value one closure stores and the test reads later.
final class Holder<Value: Sendable>: Sendable {
    private let stored = Mutex<Value?>(nil)

    var value: Value? {
        stored.withLock { $0 }
    }

    func set(_ value: Value) {
        stored.withLock { $0 = value }
    }
}

/// A one-shot signal one task fires and others wait for.
final class Signal: Sendable {
    private struct State {
        var fired = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func fire() {
        let waiters = state.withLock { state in
            state.fired = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let fired = state.withLock { state in
                if !state.fired {
                    state.waiters.append(continuation)
                }
                return state.fired
            }
            if fired {
                continuation.resume()
            }
        }
    }
}

// MARK: - Libraries

/// A library in a fresh temporary directory, with one category holding one
/// feed source at `url`.
struct CollectionFixture {
    let directory: URL
    let clock: TestClock
    let library: Library
    let categoryID: UUID
    let source: Source

    static func make(url: String = "https://example.invalid/feed.xml") async throws -> CollectionFixture {
        let directory = try makeTemporaryDirectory()
        let clock = TestClock()
        let library = try await LibraryStore(directory: directory, now: clock.now).openNormal()
        let category = try await library.createCategory(name: "News", icon: .newspaper)
        let source = Sample.source(in: category.id, url: url, at: clock.now())
        try await library.insert(source)
        return CollectionFixture(directory: directory, clock: clock, library: library, categoryID: category.id, source: source)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    func storedSource(_ id: UUID? = nil) async throws -> Source {
        let key = (id ?? source.id).databaseKey
        return try #require(try await library.pool.read { db in try Source.fetchOne(db, key: key) })
    }

    func articles(of sourceID: UUID? = nil) async throws -> [Article] {
        let key = (sourceID ?? source.id).databaseKey
        return try await library.pool.read { db in
            try Article.filter(sql: "source_id = ?", arguments: [key]).order(sql: "rowid").fetchAll(db)
        }
    }

    func addSource(url: String, category: UUID? = nil) async throws -> Source {
        let source = Sample.source(in: category ?? categoryID, url: url, name: url, at: clock.now())
        try await library.insert(source)
        return source
    }
}

// MARK: - URL-loading stub

/// An in-process stand-in for the network, on the system's URL-loading
/// stubs. Each test registers its own host under `.invalid`, which no
/// resolver answers, so nothing can leave the process even by mistake.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    typealias Route = @Sendable (StubProtocol) -> Void

    private static let routes = Mutex<[String: Route]>([:])
    private static let seen = Mutex<[String: [URLRequest]]>([:])
    private static let counter = Atomic<Int>(0)

    /// Registers `route` under a new host and returns the host's base
    /// address.
    static func register(_ route: @escaping Route) -> String {
        let host = "t\(counter.add(1, ordering: .relaxed).newValue).stub.invalid"
        routes.withLock { $0[host] = route }
        return "http://\(host)"
    }

    /// The requests the stub received for `host`'s base address.
    static func requests(for base: String) -> [URLRequest] {
        let host = URL(string: base)?.host ?? ""
        return seen.withLock { $0[host] ?? [] }
    }

    private let stopped = Mutex(false)

    var isStopped: Bool {
        stopped.withLock { $0 }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return routes.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let host = request.url?.host ?? ""
        Self.seen.withLock { $0[host, default: []].append(request) }
        guard let route = Self.routes.withLock({ $0[host] }) else { return }
        route(self)
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
    }

    // Helpers for routes.

    var path: String {
        request.url?.path ?? ""
    }

    func respond(status: Int, headers: [String: String] = [:], body: Data = Data(), finish: Bool = true) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty {
            client?.urlProtocol(self, didLoad: body)
        }
        if finish {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    func redirect(to target: String, status: Int = 302) {
        let url = URL(string: target, relativeTo: request.url)!.absoluteURL
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": url.absoluteString]
        )!
        client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: url), redirectResponse: response)
    }

    /// Sends a 200 head, then `chunk` repeatedly from another thread until
    /// `total` bytes are sent or loading stops.
    func stream(chunk: Data, total: Int, headers: [String: String] = [:]) {
        respond(status: 200, headers: headers, finish: false)
        let client = client
        DispatchQueue.global().async { [self] in
            var sent = 0
            while sent < total, !isStopped {
                let piece = chunk.prefix(total - sent)
                client?.urlProtocol(self, didLoad: piece)
                sent += piece.count
            }
            if !isStopped {
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }
}

/// A transport whose loading goes through `StubProtocol` only.
func stubTransport(_ limits: TransportLimits = .standard) -> URLSessionTransport {
    URLSessionTransport(limits: limits, protocolClasses: [StubProtocol.self])
}

// MARK: - Loopback listener

/// An HTTP/1.1 listener on 127.0.0.1 inside the test process, for what the
/// stub cannot show: cookies, decompression, a real authentication
/// challenge, the headers actually sent, embedded credentials. Every answer
/// closes its connection.
///
/// Unchecked: the listener is used only through its own thread-safe
/// methods, the log is behind a mutex, and everything else is immutable.
final class LoopbackServer: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        /// Header fields with lowercased names; repeated fields joined.
        var headers: [String: String]
        var head: String
    }

    struct Reply: Sendable {
        var status: String
        var headers: [String]
        var body: Data

        init(_ status: String = "200 OK", headers: [String] = [], body: Data = Data()) {
            self.status = status
            self.headers = headers
            self.body = body
        }
    }

    typealias Handler = @Sendable (Request, _ base: String) -> Reply

    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackServer")
    private let log = Mutex<[Request]>([])
    private let handler: Handler

    init(_ handler: @escaping Handler) throws {
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            connection.start(queue: self.queue)
            self.receive(on: connection, buffer: Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, listener.port != nil else {
            listener.cancel()
            throw LoopbackError.notReady
        }
    }

    enum LoopbackError: Error {
        case notReady
    }

    deinit {
        listener.cancel()
    }

    var base: String {
        "http://127.0.0.1:\(listener.port!.rawValue)"
    }

    var requests: [Request] {
        log.withLock { $0 }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                self.answer(head, on: connection)
            } else if isComplete || error != nil || buffer.count > 65_536 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func answer(_ head: String, on connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ").map(String.init) ?? []
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        let request = Request(
            method: requestLine.first ?? "", path: requestLine.count > 1 ? requestLine[1] : "/", headers: headers, head: head
        )
        log.withLock { $0.append(request) }
        let reply = handler(request, base)
        var text = "HTTP/1.1 \(reply.status)\r\n"
        for header in reply.headers {
            text += header + "\r\n"
        }
        if !reply.headers.contains(where: { $0.lowercased().hasPrefix("content-length:") }) {
            text += "Content-Length: \(reply.body.count)\r\n"
        }
        text += "Connection: close\r\n\r\n"
        connection.send(content: Data(text.utf8) + reply.body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// A transport on the system's own loading, for the loopback tests.
func loopbackTransport(_ limits: TransportLimits = TransportLimits(deadline: .seconds(10), maximumBytes: 10 * 1024 * 1024, maximumRedirects: 5)) -> URLSessionTransport {
    URLSessionTransport(limits: limits)
}

// MARK: - gzip

/// `data` in the gzip format: the system's raw DEFLATE inside gzip's header
/// and trailer.
func gzip(_ data: Data) throws -> Data {
    let deflated = try (data as NSData).compressed(using: .zlib) as Data
    var output = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03])
    output.append(deflated)
    var crc = crc32(data).littleEndian
    var size = UInt32(truncatingIfNeeded: data.count).littleEndian
    withUnsafeBytes(of: &crc) { output.append(contentsOf: $0) }
    withUnsafeBytes(of: &size) { output.append(contentsOf: $0) }
    return output
}

private func crc32(_ data: Data) -> UInt32 {
    var table = [UInt32](repeating: 0, count: 256)
    for index in 0..<256 {
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        table[index] = value
    }
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
        crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }
    return crc ^ 0xFFFF_FFFF
}
