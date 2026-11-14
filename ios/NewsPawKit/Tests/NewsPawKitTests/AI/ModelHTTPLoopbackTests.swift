import Foundation
@testable import NewsPawKit
import Testing

// Nested in the serialized group: see `TimedAndHeavySuites`.
extension TimedAndHeavySuites {
/// The real model HTTP against a listener on 127.0.0.1 inside the test
/// process (RD13 decision 7; criteria 4, 6, 10): the headers on the wire,
/// no cookies, a redirect, a `Basic` challenge, a deadline, an oversized
/// reply.
@Suite("Model HTTP with a loopback listener")
struct ModelHTTPLoopbackTests {
    static let secret = "sk-loopback-key-0123456789"

    private static func chat(_ base: String, deadline: Duration = .seconds(10)) -> ModelHTTPRequest {
        var request = ChatWire.chatRequest(address: base + "/v1", model: "m", instructions: "i", texts: ["Hello"], key: key(secret))!
        request.deadline = deadline
        return request
    }

    private static func completion() -> LoopbackServer.Reply {
        LoopbackServer.Reply(headers: ["Content-Type: application/json"], body: completionBody(#"{"texts":["Hallo"]}"#))
    }

    @Test("criterion 10: the chat request on the wire has one Authorization header, the JSON headers, the body and no cookie")
    func headersOnTheWire() async throws {
        let server = try LoopbackServer { _, _ in Self.completion() }
        let response = try await URLSessionModelHTTP().send(Self.chat(server.base))
        #expect(response.status == 200)
        let request = try #require(server.requests.first)
        #expect(server.requests.count == 1)
        #expect(request.method == "POST")
        #expect(request.path == "/v1/chat/completions")
        let authorizationLines = request.head.components(separatedBy: "\r\n").filter { $0.lowercased().hasPrefix("authorization:") }
        #expect(authorizationLines.count == 1)
        #expect(request.headers["authorization"] == "Bearer \(Self.secret)")
        #expect(request.headers["accept"] == "application/json")
        #expect(request.headers["content-type"] == "application/json")
        #expect(request.headers["cookie"] == nil)
        #expect(request.body == ChatWire.chatBody(model: "m", instructions: "i", texts: ["Hello"]))
    }

    @Test("the list request on the wire: GET <address>/models with the key and Accept")
    func listOnTheWire() async throws {
        let server = try LoopbackServer { _, _ in LoopbackServer.Reply(body: Data(#"{"data":[{"id":"b"},{"id":"a"}]}"#.utf8)) }
        let fixture = try await ModelsFixture.make(http: URLSessionModelHTTP())
        defer { fixture.remove() }
        let models = try await fixture.models.listModels(ModelSlotDraft(
            role: .primary, preset: .custom, address: server.base + "/v1", model: "", newKey: key(Self.secret)
        ))
        #expect(models == ["a", "b"])
        let request = try #require(server.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/v1/models")
        #expect(request.headers["authorization"] == "Bearer \(Self.secret)")
        #expect(request.headers["accept"] == "application/json")
    }

    @Test("no cookie is stored or sent")
    func noCookies() async throws {
        let server = try LoopbackServer { _, _ in
            LoopbackServer.Reply(headers: ["Set-Cookie: sid=abc123; Path=/", "Content-Type: application/json"], body: completionBody(#"["a"]"#))
        }
        let http = URLSessionModelHTTP()
        _ = try await http.send(Self.chat(server.base))
        _ = try await http.send(Self.chat(server.base))
        #expect(server.requests.count == 2)
        #expect(server.requests.allSatisfy { $0.headers["cookie"] == nil })
    }

    @Test("criterion 4: a redirect is not followed — one request, none to its target, and the result is unreachable")
    func redirectNotFollowed() async throws {
        let server = try LoopbackServer { request, _ in
            request.path == "/elsewhere" ? Self.completion() : LoopbackServer.Reply("302 Found", headers: ["Location: /elsewhere"])
        }
        let error = await thrown { try await URLSessionModelHTTP().send(Self.chat(server.base)) }
        #expect(error as? ModelHTTPFailure == .redirected)
        #expect(server.requests.map(\.path) == ["/v1/chat/completions"])

        let fixture = try await ModelsFixture.make(http: URLSessionModelHTTP())
        defer { fixture.remove() }
        try await fixture.save(address: server.base + "/v1", key: Self.secret)
        let sendError = await thrown { try await fixture.models.send(texts: ["a"], instructions: "i", purpose: .titles, role: .primary) }
        #expect(sendError as? ModelFailure == .unreachable)
        let draft = ModelSlotDraft(role: .primary, preset: .custom, address: server.base + "/v1", model: "test-model", newKey: nil)
        #expect(try await fixture.models.test(draft) == .couldNotConnect)
        #expect(server.requests.map(\.path) == ["/v1/chat/completions", "/v1/chat/completions", "/v1/chat/completions"])
        #expect(try await fixture.usage().map(\.outcome) == [.unreachable, .unreachable])
    }

    @Test("a 307 and a 308 are not followed either")
    func otherRedirects() async throws {
        for status in ["307 Temporary Redirect", "308 Permanent Redirect", "301 Moved Permanently"] {
            let server = try LoopbackServer { request, _ in
                request.path == "/elsewhere" ? Self.completion() : LoopbackServer.Reply(status, headers: ["Location: /elsewhere"])
            }
            let error = await thrown { try await URLSessionModelHTTP().send(Self.chat(server.base)) }
            #expect(error as? ModelHTTPFailure == .redirected, "\(status)")
            #expect(server.requests.map(\.path) == ["/v1/chat/completions"], "\(status)")
        }
    }

    @Test("criterion 6: a 401 with a Basic challenge is key rejected after one request")
    func basicChallenge() async throws {
        let server = try LoopbackServer { _, _ in
            LoopbackServer.Reply("401 Unauthorized", headers: [#"WWW-Authenticate: Basic realm="api""#], body: Data(#"{"error":"echo sk-x"}"#.utf8))
        }
        let error = await thrown { try await URLSessionModelHTTP().send(Self.chat(server.base)) }
        #expect(error as? ModelHTTPFailure == .declinedAuthentication(status: 401))
        #expect(server.requests.count == 1)

        let fixture = try await ModelsFixture.make(http: URLSessionModelHTTP())
        defer { fixture.remove() }
        try await fixture.save(address: server.base + "/v1", key: Self.secret)
        let sendError = await thrown { try await fixture.models.send(texts: ["a"], instructions: "i", purpose: .titles, role: .primary) }
        #expect(sendError as? ModelFailure == .keyRejected)
        #expect(server.requests.count == 2)
        let draft = ModelSlotDraft(role: .primary, preset: .custom, address: server.base + "/v1", model: "test-model", newKey: nil)
        #expect(try await fixture.models.test(draft) == .keyRejected)
        #expect(server.requests.count == 3)
        #expect(try await fixture.usage().map(\.outcome) == [.keyRejected, .keyRejected])
    }

    @Test("a 401 without a challenge, and a 404 with the service's error body, classify on the real session")
    func statusesOnTheWire() async throws {
        let server = try LoopbackServer { request, _ in
            request.path.hasPrefix("/missing")
                ? LoopbackServer.Reply("404 Not Found", body: Data(#"{"error":{"message":"The model does not exist"}}"#.utf8))
                : LoopbackServer.Reply("401 Unauthorized", body: Data(#"{"error":{"message":"bad key"}}"#.utf8))
        }
        let fixture = try await ModelsFixture.make(http: URLSessionModelHTTP())
        defer { fixture.remove() }
        func test(_ path: String) async throws -> TestOutcome {
            try await fixture.models.test(ModelSlotDraft(
                role: .primary, preset: .custom, address: server.base + path, model: "m", newKey: key(Self.secret)
            ))
        }
        #expect(try await test("/v1") == .keyRejected)
        #expect(try await test("/missing") == .modelNotFound)
    }

    @Test("an exchange past its deadline is timed out")
    func deadline() async throws {
        let server = try LoopbackServer { _, _ in
            Thread.sleep(forTimeInterval: 3)
            return Self.completion()
        }
        let started = ContinuousClock.now
        let error = await thrown { try await URLSessionModelHTTP().send(Self.chat(server.base, deadline: .seconds(1))) }
        #expect(error as? ModelHTTPFailure == .timedOut)
        #expect(ContinuousClock.now - started < .seconds(2.5))
    }

    @Test("a reply over 4 MB is too large, announced or not; 4 MB itself is read")
    func oversized() async throws {
        let limit = URLSessionModelHTTP.maximumBytes
        for (size, announce, tooLarge) in [(limit + 1, true, true), (limit + 1, false, true), (limit, true, false)] {
            let server = try LoopbackServer { _, _ in
                LoopbackServer.Reply(body: Data(repeating: 0x20, count: size), announceLength: announce)
            }
            let result = await thrown { try await URLSessionModelHTTP().send(Self.chat(server.base)) }
            if tooLarge {
                #expect(result as? ModelHTTPFailure == .tooLarge, "\(size) \(announce)")
            } else {
                #expect(result == nil, "\(size) \(announce)")
            }
        }
    }

    @Test("an error body is read up to 64 KB and the answer kept")
    func errorBodyCut() async throws {
        let server = try LoopbackServer { _, _ in
            LoopbackServer.Reply("500 Internal Server Error", body: Data(repeating: 0x41, count: 200 * 1024), announceLength: false)
        }
        let response = try await URLSessionModelHTTP().send(Self.chat(server.base))
        #expect(response.status == 500)
        #expect(response.body.count == URLSessionModelHTTP.maximumErrorBytes)
    }

    @Test("a cancelled exchange throws a cancellation")
    func cancelled() async throws {
        let server = try LoopbackServer { _, _ in
            Thread.sleep(forTimeInterval: 2)
            return Self.completion()
        }
        let task = Task { try await URLSessionModelHTTP().send(Self.chat(server.base)) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        #expect(await thrown { try await task.value } is CancellationError)
    }
}
}
