import Foundation
@testable import NewsPawKit
import Testing

/// The real transport driven through an in-process URL-loading stub
/// (criteria 5 and 6). Every stub host is under `.invalid`.
@Suite("Transport with a URL-loading stub")
struct TransportStubTests {
    private static func elapsed(_ body: () async throws -> Void) async rethrows -> Duration {
        let start = ContinuousClock.now
        try await body()
        return ContinuousClock.now - start
    }

    private static func failure(_ body: () async throws -> TransportResponse) async -> (any Error)? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Criterion 5: validators

    @Test("a 200 answer carries status, headers, body and final address; stored validators are sent exactly as stored")
    func successWithValidators() async throws {
        let base = StubProtocol.register { stub in
            stub.respond(status: 200, headers: ["ETag": #"W/"v2""#, "Last-Modified": "Wed, 11 Nov 2026 08:00:00 GMT", "Content-Type": "application/rss+xml"], body: Data("feed".utf8))
        }
        let request = TransportRequest(url: URL(string: base + "/feed")!, etag: #"W/"v1""#, lastModified: "Tue, 10 Nov 2026 08:00:00 GMT")
        let response = try await stubTransport().fetch(request)
        #expect(response.status == 200)
        #expect(response.body == Data("feed".utf8))
        #expect(response.finalURL.absoluteString == base + "/feed")
        #expect(response.header("etag") == #"W/"v2""#)
        #expect(response.header("Last-Modified") == "Wed, 11 Nov 2026 08:00:00 GMT")
        let sent = try #require(StubProtocol.requests(for: base).first)
        #expect(sent.value(forHTTPHeaderField: "If-None-Match") == #"W/"v1""#)
        #expect(sent.value(forHTTPHeaderField: "If-Modified-Since") == "Tue, 10 Nov 2026 08:00:00 GMT")
    }

    @Test("without stored validators no conditional header is sent")
    func noValidators() async throws {
        let base = StubProtocol.register { stub in stub.respond(status: 200, body: Data("x".utf8)) }
        _ = try await stubTransport().fetch(TransportRequest(url: URL(string: base + "/feed")!))
        let sent = try #require(StubProtocol.requests(for: base).first)
        #expect(sent.value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(sent.value(forHTTPHeaderField: "If-Modified-Since") == nil)
    }

    @Test("a 304 answer is returned as it is, with no body")
    func notModified() async throws {
        let base = StubProtocol.register { stub in
            if stub.request.value(forHTTPHeaderField: "If-None-Match") == #"W/"v1""# {
                stub.respond(status: 304, headers: ["ETag": #"W/"v1""#])
            } else {
                stub.respond(status: 200, body: Data("full".utf8))
            }
        }
        let response = try await stubTransport().fetch(TransportRequest(url: URL(string: base + "/feed")!, etag: #"W/"v1""#))
        #expect(response.status == 304)
        #expect(response.body.isEmpty)
    }

    @Test("an answer that is not 2xx is returned without reading its body")
    func otherStatuses() async throws {
        for status in [404, 410, 500, 401, 302] {
            let base = StubProtocol.register { stub in
                stub.respond(status: status, body: Data(repeating: 0x61, count: 64 * 1024))
            }
            let response = try await stubTransport().fetch(TransportRequest(url: URL(string: base + "/feed")!))
            #expect(response.status == status)
            #expect(response.body.isEmpty)
        }
    }

    // MARK: - Criterion 6: the deadline

    @Test("the deadline ends an exchange that never answers")
    func deadlineWithoutAnswer() async throws {
        let loader = Holder<StubProtocol>()
        let base = StubProtocol.register { stub in loader.set(stub) }
        let limits = TransportLimits(deadline: .milliseconds(300), maximumBytes: 1024, maximumRedirects: 5)
        let time = await Self.elapsed {
            let error = await Self.failure { try await stubTransport(limits).fetch(TransportRequest(url: URL(string: base + "/never")!)) }
            #expect(error as? TransportFailure == .timedOut)
        }
        #expect(time >= .milliseconds(300))
        #expect(time < .seconds(3))
        try await Task.sleep(for: .milliseconds(100))
        #expect(loader.value?.isStopped == true)
    }

    @Test("the deadline covers the body: an answer that stalls after its head times out")
    func deadlineDuringBody() async throws {
        let base = StubProtocol.register { stub in
            stub.respond(status: 200, body: Data("first part".utf8), finish: false)
        }
        let limits = TransportLimits(deadline: .milliseconds(300), maximumBytes: 1024, maximumRedirects: 5)
        let error = await Self.failure { try await stubTransport(limits).fetch(TransportRequest(url: URL(string: base + "/stall")!)) }
        #expect(error as? TransportFailure == .timedOut)
    }

    @Test("the deadline covers the whole exchange, redirects included")
    func deadlineAcrossRedirects() async throws {
        let base = StubProtocol.register { stub in
            if stub.path == "/start" {
                stub.redirect(to: "/hop")
            }
            // "/hop" never answers.
        }
        let limits = TransportLimits(deadline: .milliseconds(300), maximumBytes: 1024, maximumRedirects: 5)
        let error = await Self.failure { try await stubTransport(limits).fetch(TransportRequest(url: URL(string: base + "/start")!)) }
        #expect(error as? TransportFailure == .timedOut)
    }

    // MARK: - Criterion 6: the size limit

    @Test("a body announced larger than 10 MB is refused at once")
    func announcedTooLarge() async throws {
        let base = StubProtocol.register { stub in
            // With a media type the loader hands the head over at once; without
            // one it first waits for enough bytes to sniff a type.
            stub.respond(
                status: 200, headers: ["Content-Type": "application/rss+xml", "Content-Length": "\(10 * 1024 * 1024 + 1)"],
                body: Data("x".utf8), finish: false
            )
        }
        let limits = TransportLimits(deadline: .seconds(5), maximumBytes: 10 * 1024 * 1024, maximumRedirects: 5)
        let time = await Self.elapsed {
            let error = await Self.failure { try await stubTransport(limits).fetch(TransportRequest(url: URL(string: base + "/big")!)) }
            #expect(error as? TransportFailure == .tooLarge)
        }
        #expect(time < .seconds(2))
    }

    @Test("a streamed body that passes 10 MB is abandoned")
    func streamedTooLarge() async throws {
        let loader = Holder<StubProtocol>()
        let base = StubProtocol.register { stub in
            loader.set(stub)
            stub.stream(chunk: Data(repeating: 0x61, count: 256 * 1024), total: 12 * 1024 * 1024)
        }
        let limits = TransportLimits(deadline: .seconds(10), maximumBytes: 10 * 1024 * 1024, maximumRedirects: 5)
        let error = await Self.failure { try await stubTransport(limits).fetch(TransportRequest(url: URL(string: base + "/stream")!)) }
        #expect(error as? TransportFailure == .tooLarge)
        try await Task.sleep(for: .milliseconds(100))
        #expect(loader.value?.isStopped == true)
    }

    @Test("a body of exactly the limit is accepted; one byte more is not")
    func exactLimit() async throws {
        let limit = 64 * 1024
        let limits = TransportLimits(deadline: .seconds(5), maximumBytes: limit, maximumRedirects: 5)
        let exact = StubProtocol.register { stub in
            stub.stream(chunk: Data(repeating: 0x62, count: 1000), total: limit)
        }
        let response = try await stubTransport(limits).fetch(TransportRequest(url: URL(string: exact + "/exact")!))
        #expect(response.body.count == limit)
        let over = StubProtocol.register { stub in
            stub.stream(chunk: Data(repeating: 0x62, count: 1000), total: limit + 1)
        }
        let error = await Self.failure { try await stubTransport(limits).fetch(TransportRequest(url: URL(string: over + "/over")!)) }
        #expect(error as? TransportFailure == .tooLarge)
    }

    // MARK: - Criterion 6: redirects

    private static func redirectChain() -> String {
        StubProtocol.register { stub in
            let remaining = Int(stub.path.dropFirst("/hops/".count)) ?? 0
            if remaining > 0 {
                stub.redirect(to: "/hops/\(remaining - 1)")
            } else {
                stub.respond(status: 200, body: Data("landed".utf8))
            }
        }
    }

    @Test("exactly 5 redirects succeed")
    func fiveRedirects() async throws {
        let base = Self.redirectChain()
        let response = try await stubTransport().fetch(TransportRequest(url: URL(string: base + "/hops/5")!))
        #expect(response.status == 200)
        #expect(response.body == Data("landed".utf8))
        #expect(response.finalURL.absoluteString == base + "/hops/0")
        #expect(StubProtocol.requests(for: base).count == 6)
    }

    @Test("a 6th redirect fails at once, not after the deadline")
    func sixRedirects() async throws {
        let base = Self.redirectChain()
        let limits = TransportLimits(deadline: .seconds(10), maximumBytes: 1024, maximumRedirects: 5)
        let time = await Self.elapsed {
            let error = await Self.failure { try await stubTransport(limits).fetch(TransportRequest(url: URL(string: base + "/hops/6")!)) }
            #expect(error as? TransportFailure == .tooManyRedirects)
        }
        #expect(time < .seconds(2))
        // The refused target is never requested.
        #expect(StubProtocol.requests(for: base).count == 6)
    }

    @Test("a redirect to a scheme other than http or https is refused at once", arguments: ["ftp://example.invalid/x", "file:///etc/hosts", "data:text/plain,hi", "newspaw-test://x/y"])
    func redirectToOtherScheme(_ target: String) async throws {
        let base = StubProtocol.register { stub in stub.redirect(to: target) }
        let limits = TransportLimits(deadline: .seconds(10), maximumBytes: 1024, maximumRedirects: 5)
        let time = await Self.elapsed {
            let error = await Self.failure { try await stubTransport(limits).fetch(TransportRequest(url: URL(string: base + "/away")!)) }
            #expect(error as? TransportFailure == .unsupportedAddress, "\(target)")
        }
        #expect(time < .seconds(2))
    }

    @Test("a redirect to an address with a user name or password is refused before it is requested")
    func redirectWithCredentials() async throws {
        let target = StubProtocol.register { stub in stub.respond(status: 200, body: Data("should not load".utf8)) }
        let targetHost = URL(string: target)!.host!
        let base = StubProtocol.register { stub in stub.redirect(to: "http://user:secret@\(targetHost)/private") }
        let error = await Self.failure { try await stubTransport().fetch(TransportRequest(url: URL(string: base + "/start")!)) }
        #expect(error as? TransportFailure == .unsupportedAddress)
        #expect(StubProtocol.requests(for: target).isEmpty)
    }

    @Test(
        "a source address that is not http or https, or that carries a user name or password, is refused without a request",
        arguments: ["ftp://t.stub.invalid/feed", "file:///etc/hosts", "feed://t.stub.invalid/feed", "http://user:pass@t.stub.invalid/feed", "https://user@t.stub.invalid/feed", "http:///nohost"]
    )
    func unsupportedSourceAddress(_ address: String) async throws {
        let url = try #require(URL(string: address))
        let error = await Self.failure { try await stubTransport().fetch(TransportRequest(url: url)) }
        #expect(error as? TransportFailure == .unsupportedAddress, "\(address)")
    }

    // MARK: - Cancellation

    @Test("cancelling the calling task ends the exchange with a cancellation error")
    func cancellation() async throws {
        let base = StubProtocol.register { _ in }
        let transport = stubTransport(TransportLimits(deadline: .seconds(30), maximumBytes: 1024, maximumRedirects: 5))
        let task = Task { try await transport.fetch(TransportRequest(url: URL(string: base + "/never")!)) }
        try await Task.sleep(for: .milliseconds(100))
        let time = await Self.elapsed {
            task.cancel()
            let result = await task.result
            #expect(throws: CancellationError.self) { try result.get() }
        }
        #expect(time < .seconds(2))
    }
}
