import Foundation
@testable import NewsPawKit
import Testing

/// The fetcher's outcomes, without any library (criteria 4, 5, 14).
@Suite("Feed fetcher")
struct FeedFetcherTests {
    private let address = "https://example.invalid/feed.xml"

    @Test("a 200 feed comes back parsed, with its validators and final address")
    func feed() async throws {
        let finalURL = URL(string: "https://mirror.example.invalid/moved/feed.xml")!
        let transport = FakeTransport.answering(
            body: try FeedFixture.data("rss2.xml"),
            headers: ["ETag": #"W/"abc""#, "Last-Modified": "Tue, 10 Nov 2026 08:00:00 GMT", "Content-Type": "application/rss+xml"],
            finalURL: finalURL
        )
        let result = try await FeedFetcher(transport: transport).fetch(address, etag: #"W/"old""#, lastModified: "Mon, 09 Nov 2026 08:00:00 GMT")
        guard case .feed(let fetched) = result else {
            Issue.record("expected a feed, got \(result)")
            return
        }
        #expect(fetched.feed.items.count == 3)
        #expect(fetched.validators == Validators(etag: #"W/"abc""#, lastModified: "Tue, 10 Nov 2026 08:00:00 GMT"))
        #expect(fetched.finalURL == finalURL)
        // Relative links resolve against the final address.
        #expect(fetched.feed.items[1].url == "https://mirror.example.invalid/articles/ferry")
        #expect(transport.received == [TransportRequest(url: URL(string: address)!, etag: #"W/"old""#, lastModified: "Mon, 09 Nov 2026 08:00:00 GMT")])
    }

    @Test("an incomplete document is a feed whose validators are not kept")
    func incomplete() async throws {
        let body = Data(#"<rss version="2.0"><channel><title>t</title><item><guid>1</guid></item><item><guid>2</guid><title>A & B"#.utf8)
        let transport = FakeTransport.answering(body: body, headers: ["ETag": "\"e\"", "Last-Modified": "x"])
        let result = try await FeedFetcher(transport: transport).fetch(address)
        guard case .feed(let fetched) = result else {
            Issue.record("expected a feed, got \(result)")
            return
        }
        #expect(fetched.feed.isComplete == false)
        #expect(fetched.feed.items.map(\.externalID) == ["1"])
        #expect(fetched.validators == Validators(etag: nil, lastModified: nil))
    }

    @Test("a 304 is not modified and nothing is parsed")
    func notModified() async throws {
        let transport = FakeTransport.answering(status: 304, body: Data("not a feed at all".utf8))
        #expect(try await FeedFetcher(transport: transport).fetch(address, etag: "\"e\"") == .notModified)
    }

    @Test(
        "statuses other than 200 and 304 are failures with their codes",
        arguments: [(404, "gone"), (410, "gone"), (500, "http:500"), (503, "http:503"), (302, "http:302"), (204, "http:204"), (401, "http:401"), (403, "http:403")]
    )
    func statuses(_ status: Int, _ code: String) async throws {
        let result = try await FeedFetcher(transport: FakeTransport.answering(status: status, body: try FeedFixture.data("rss2.xml"))).fetch(address)
        #expect(result.failure?.code == code)
    }

    @Test(
        "each transport failure is a failure with its code",
        arguments: [
            (TransportFailure.unreachable, "unreachable"), (.timedOut, "timed_out"), (.tooLarge, "too_large"),
            (.tooManyRedirects, "too_many_redirects"), (.unsupportedAddress, "unsupported_address"),
            (.declinedAuthentication(status: 401), "http:401"), (.declinedAuthentication(status: 407), "http:407"),
        ]
    )
    func transportFailures(_ failure: TransportFailure, _ code: String) async throws {
        let result = try await FeedFetcher(transport: FakeTransport.failing(failure)).fetch(address)
        #expect(result.failure?.code == code)
    }

    @Test("an error the transport does not name counts as unreachable")
    func otherErrors() async throws {
        let transport = FakeTransport { _ in throw URLError(.cannotFindHost) }
        #expect(try await FeedFetcher(transport: transport).fetch(address) == .failed(.unreachable))
    }

    @Test("a document that is not a feed comes back with its bytes, media type, charset and final address")
    func notAFeed() async throws {
        let page = Data("<html><head><title>ページ</title></head></html>".utf8)
        let finalURL = URL(string: "https://example.invalid/home")!
        let transport = FakeTransport.answering(body: page, headers: ["Content-Type": #"text/html; charset="Shift_JIS""#], finalURL: finalURL)
        let result = try await FeedFetcher(transport: transport).fetch(address)
        #expect(result == .notAFeed(NonFeedDocument(body: page, mediaType: "text/html", charset: "Shift_JIS", finalURL: finalURL)))
        #expect(result.failure?.code == "not_a_feed")
    }

    @Test("the response's charset reaches the parser")
    func headerCharset() async throws {
        let transport = FakeTransport.answering(
            body: try FeedFixture.data("ja-shift_jis-undeclared.xml"),
            headers: ["Content-Type": "application/rss+xml; charset=Shift_JIS"]
        )
        guard case .feed(let fetched) = try await FeedFetcher(transport: transport).fetch(address) else {
            Issue.record("expected a feed")
            return
        }
        #expect(fetched.feed.title == "架空ニュース 表示テスト")
    }

    @Test("an address that is not http or https, or carries credentials, fails without a request", arguments: ["ftp://example.invalid/feed", "not an address", "", "https://u:p@example.invalid/feed", "javascript:alert(1)"])
    func unsupportedAddress(_ address: String) async throws {
        let transport = FakeTransport.answering(body: Data())
        #expect(try await FeedFetcher(transport: transport).fetch(address) == .failed(.unsupportedAddress))
        #expect(transport.received.isEmpty)
    }

    @Test("cancellation is rethrown, not turned into a failure")
    func cancellation() async throws {
        let transport = FakeTransport { _ in
            try await Task.sleep(for: .seconds(30))
            throw TransportFailure.unreachable
        }
        let task = Task { try await FeedFetcher(transport: transport).fetch(address) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
    }

    @Test("the content type header is read into a media type and a charset")
    func contentType() {
        #expect(ContentType("application/rss+xml; charset=UTF-8").mediaType == "application/rss+xml")
        #expect(ContentType("application/rss+xml; charset=UTF-8").charset == "UTF-8")
        #expect(ContentType("Text/XML ;Charset=\"euc-jp\" ; q=1").charset == "euc-jp")
        #expect(ContentType("Text/XML").mediaType == "text/xml")
        #expect(ContentType("text/xml").charset == nil)
        #expect(ContentType(nil).mediaType == nil)
    }
}
