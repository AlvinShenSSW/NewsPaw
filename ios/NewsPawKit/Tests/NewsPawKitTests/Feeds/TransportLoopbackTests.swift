import Foundation
@testable import NewsPawKit
import Testing

/// The real transport against a listener on 127.0.0.1 inside the test
/// process, for what a URL-loading stub cannot show (criteria 6, 7, 15):
/// cookies, decompression, a real authentication challenge, the headers on
/// the wire, embedded credentials, a redirect the loader itself refuses.
@Suite("Transport with a loopback listener")
struct TransportLoopbackTests {
    private static func failure(_ body: () async throws -> TransportResponse) async -> (any Error)? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error
        }
    }

    /// Answers `/headers` with 200, redirects `/hop` there, and 404 otherwise.
    private static func headerServer() throws -> LoopbackServer {
        try LoopbackServer { request, _ in
            switch request.path {
            case "/headers": LoopbackServer.Reply(headers: ["Content-Type: text/plain"], body: Data("ok".utf8))
            case "/hop": LoopbackServer.Reply("302 Found", headers: ["Location: /headers"])
            default: LoopbackServer.Reply("404 Not Found")
            }
        }
    }

    // MARK: - Criterion 7: nothing identifying is sent

    @Test("the User-Agent, Accept-Language and Accept on the wire are the fixed values, also after a redirect")
    func fixedHeadersOnTheWire() async throws {
        let server = try Self.headerServer()
        _ = try await loopbackTransport().fetch(TransportRequest(url: URL(string: server.base + "/hop")!))
        let requests = server.requests
        #expect(requests.map(\.path) == ["/hop", "/headers"])
        for request in requests {
            #expect(request.headers["user-agent"] == "Mozilla/5.0 (compatible; feed reader)")
            #expect(request.headers["accept-language"] == "*")
            #expect(request.headers["accept"] == URLSessionTransport.accept)
            #expect(request.headers["cookie"] == nil)
            #expect(request.headers["authorization"] == nil)
        }
    }

    @Test("no cookie is stored or sent")
    func noCookies() async throws {
        let server = try LoopbackServer { request, _ in
            switch request.path {
            case "/set": LoopbackServer.Reply(headers: ["Set-Cookie: sid=abc123; Path=/", "Set-Cookie: other=1; Path=/; Max-Age=3600"], body: Data("set".utf8))
            default: LoopbackServer.Reply(body: Data("second".utf8))
            }
        }
        let transport = loopbackTransport()
        _ = try await transport.fetch(TransportRequest(url: URL(string: server.base + "/set")!))
        _ = try await transport.fetch(TransportRequest(url: URL(string: server.base + "/check")!))
        let requests = server.requests
        #expect(requests.map(\.path) == ["/set", "/check"])
        #expect(requests.allSatisfy { $0.headers["cookie"] == nil })
    }

    @Test("an authentication challenge is declined and recorded as the 401 it was")
    func authenticationChallenge() async throws {
        let server = try LoopbackServer { _, _ in
            LoopbackServer.Reply("401 Unauthorized", headers: [#"WWW-Authenticate: Basic realm="private""#], body: Data("denied".utf8))
        }
        let error = await Self.failure { try await loopbackTransport().fetch(TransportRequest(url: URL(string: server.base + "/private")!)) }
        #expect(error as? TransportFailure == .declinedAuthentication(status: 401))
        #expect(server.requests.count == 1)
        #expect(server.requests.allSatisfy { $0.headers["authorization"] == nil })

        let result = try await FeedFetcher(transport: loopbackTransport()).fetch(server.base + "/private")
        #expect(result == .failed(.httpStatus(401)))
        #expect(result.failure?.code == "http:401")
    }

    @Test("credentials embedded in the source address are never sent: the address is refused")
    func credentialsInAddress() async throws {
        let server = try Self.headerServer()
        let port = URL(string: server.base)!.port!
        let error = await Self.failure {
            try await loopbackTransport().fetch(TransportRequest(url: URL(string: "http://user:secret@127.0.0.1:\(port)/headers")!))
        }
        #expect(error as? TransportFailure == .unsupportedAddress)
        let fetched = try await FeedFetcher(transport: loopbackTransport()).fetch("http://user:secret@127.0.0.1:\(port)/headers")
        #expect(fetched == .failed(.unsupportedAddress))
        #expect(server.requests.isEmpty)
    }

    @Test("credentials supplied by a redirect are never sent: the redirect is refused")
    func credentialsInRedirect() async throws {
        let server = try LoopbackServer { request, base in
            switch request.path {
            case "/start":
                let port = URL(string: base)!.port!
                return LoopbackServer.Reply("302 Found", headers: ["Location: http://router:admin@127.0.0.1:\(port)/private"])
            default:
                return LoopbackServer.Reply("401 Unauthorized", headers: [#"WWW-Authenticate: Basic realm="r""#])
            }
        }
        let error = await Self.failure { try await loopbackTransport().fetch(TransportRequest(url: URL(string: server.base + "/start")!)) }
        #expect(error as? TransportFailure == .unsupportedAddress)
        #expect(server.requests.map(\.path) == ["/start"])
        #expect(server.requests.allSatisfy { $0.headers["authorization"] == nil })
    }

    // MARK: - Criterion 6: redirects the loader refuses, decompressed size

    @Test("a redirect to a file address is refused as an unsupported address")
    func redirectToFile() async throws {
        let server = try LoopbackServer { request, _ in
            request.path == "/start" ? LoopbackServer.Reply("302 Found", headers: ["Location: file:///etc/hosts"]) : LoopbackServer.Reply("404 Not Found")
        }
        let error = await Self.failure { try await loopbackTransport().fetch(TransportRequest(url: URL(string: server.base + "/start")!)) }
        #expect(error as? TransportFailure == .unsupportedAddress)
    }

    @Test("exactly 5 redirects succeed and a 6th fails at once on the real loader")
    func redirectLimit() async throws {
        let server = try LoopbackServer { request, _ in
            let remaining = Int(request.path.dropFirst("/hops/".count)) ?? 0
            return remaining > 0
                ? LoopbackServer.Reply("302 Found", headers: ["Location: /hops/\(remaining - 1)"])
                : LoopbackServer.Reply(headers: ["Content-Type: text/plain"], body: Data("landed".utf8))
        }
        let response = try await loopbackTransport().fetch(TransportRequest(url: URL(string: server.base + "/hops/5")!))
        #expect(response.body == Data("landed".utf8))
        let start = ContinuousClock.now
        let error = await Self.failure { try await loopbackTransport().fetch(TransportRequest(url: URL(string: server.base + "/hops/6")!)) }
        #expect(error as? TransportFailure == .tooManyRedirects)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test("a gzip body is decoded, and the 10 MB limit applies to the decoded bytes")
    func decompressedSize() async throws {
        let feed = try FeedFixture.data("rss2.xml")
        let small = try gzip(feed)
        let bomb = try gzip(Data(repeating: 0x20, count: 10 * 1024 * 1024 + 4096))
        #expect(bomb.count < 100 * 1024)
        let server = try LoopbackServer { request, _ in
            let body = request.path == "/small" ? small : bomb
            return LoopbackServer.Reply(headers: ["Content-Type: application/rss+xml", "Content-Encoding: gzip"], body: body)
        }
        let transport = loopbackTransport()
        let response = try await transport.fetch(TransportRequest(url: URL(string: server.base + "/small")!))
        #expect(response.body == feed)
        let error = await Self.failure { try await transport.fetch(TransportRequest(url: URL(string: server.base + "/bomb")!)) }
        #expect(error as? TransportFailure == .tooLarge)
    }

    @Test("a body that passes 10 MB on the real loader is abandoned")
    func streamedTooLargeOnTheWire() async throws {
        let big = Data(repeating: 0x61, count: 10 * 1024 * 1024 + 1)
        let server = try LoopbackServer { _, _ in
            LoopbackServer.Reply(headers: ["Content-Type: text/plain", "Content-Length: \(big.count)"], body: big)
        }
        let error = await Self.failure { try await loopbackTransport().fetch(TransportRequest(url: URL(string: server.base + "/big")!)) }
        #expect(error as? TransportFailure == .tooLarge)
    }

    // MARK: - Criterion 15: nothing a feed mentions is requested

    @Test("external entities, document types and parameter entities in a feed cause no request")
    func externalEntitiesCauseNoRequest() async throws {
        let server = try Self.headerServer()
        let documents = [
            #"<?xml version="1.0"?><!DOCTYPE rss [<!ENTITY x SYSTEM "\#(server.base)/headers">]><rss version="2.0"><channel><title>t</title><item><guid>1</guid><title>a &x; b</title></item><item><guid>2</guid></item></channel></rss>"#,
            #"<?xml version="1.0"?><!DOCTYPE rss SYSTEM "\#(server.base)/headers"><rss version="2.0"><channel><title>t</title><item><guid>1</guid><title>a</title></item></channel></rss>"#,
            #"<?xml version="1.0"?><!DOCTYPE rss [<!ENTITY % p SYSTEM "\#(server.base)/headers"> %p;]><rss version="2.0"><channel><title>t</title><item><guid>1</guid><title>a</title></item></channel></rss>"#,
            #"<?xml version="1.0"?><!DOCTYPE rss PUBLIC "-//X//Y" "\#(server.base)/headers"><rss version="2.0"><channel><title>t</title><item><guid>1</guid><link>\#(server.base)/headers</link><enclosure url="\#(server.base)/headers" type="image/png"/></item></channel></rss>"#,
        ]
        for document in documents {
            _ = parse(document)
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.requests.isEmpty)
    }
}
