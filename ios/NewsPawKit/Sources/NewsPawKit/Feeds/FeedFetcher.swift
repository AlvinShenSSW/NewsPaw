import Foundation

/// Fetches one feed address and parses the answer, without any library
/// (spec N03, N04). The collector uses it to collect; source detection and
/// preview (RD05) and GitHub's feeds (RD07) use it directly.
public struct FeedFetcher: Sendable {
    private let transport: any Transport

    public init(transport: any Transport) {
        self.transport = transport
    }

    /// Fetches `address`, sending the stored validators.
    ///
    /// - Throws: only `CancellationError`. Every other failure is a result.
    public func fetch(_ address: String, etag: String? = nil, lastModified: String? = nil) async throws -> FetchResult {
        guard let url = URL(string: address), url.isCollectableAddress else {
            return .failed(.unsupportedAddress)
        }
        let response: TransportResponse
        do {
            response = try await transport.fetch(TransportRequest(url: url, etag: etag, lastModified: lastModified))
        } catch let failure as TransportFailure {
            try Task.checkCancellation()
            return .failed(Self.reason(for: failure))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return .failed(.unreachable)
        }
        try Task.checkCancellation()

        switch response.status {
        case 304:
            return .notModified
        case 200:
            break
        case 404, 410:
            return .failed(.gone)
        default:
            return .failed(.httpStatus(response.status))
        }

        let contentType = ContentType(response.header("Content-Type"))
        guard let feed = FeedParser.parse(response.body, charset: contentType.charset, baseURL: response.finalURL) else {
            return .notAFeed(NonFeedDocument(
                body: response.body, mediaType: contentType.mediaType, charset: contentType.charset, finalURL: response.finalURL
            ))
        }
        let validators = feed.isComplete
            ? Validators(etag: response.header("ETag"), lastModified: response.header("Last-Modified"))
            : Validators(etag: nil, lastModified: nil)
        return .feed(FetchedFeed(feed: feed, validators: validators, finalURL: response.finalURL))
    }

    private static func reason(for failure: TransportFailure) -> CollectionFailure {
        switch failure {
        case .unreachable: .unreachable
        case .timedOut: .timedOut
        case .tooLarge: .tooLarge
        case .tooManyRedirects: .tooManyRedirects
        case .unsupportedAddress: .unsupportedAddress
        case .declinedAuthentication(let status): .httpStatus(status)
        }
    }
}

/// What fetching a feed address produced.
public enum FetchResult: Sendable, Hashable {
    /// `304 Not Modified`: nothing was parsed.
    case notModified
    /// A feed.
    case feed(FetchedFeed)
    /// The answer was a document that is not a feed. It is handed back so
    /// that feed discovery need not fetch the page a second time.
    case notAFeed(NonFeedDocument)
    /// No usable answer.
    case failed(CollectionFailure)

    /// The failure reason, `notAFeed` included; `nil` for a success.
    public var failure: CollectionFailure? {
        switch self {
        case .notModified, .feed: nil
        case .notAFeed: .notAFeed
        case .failed(let reason): reason
        }
    }
}

/// A feed and what to store from its answer.
public struct FetchedFeed: Sendable, Hashable {
    public var feed: ParsedFeed
    /// The validators to store: the answer's own after a complete document,
    /// none after an incomplete one, so that the next request fetches the
    /// whole document again.
    public var validators: Validators
    /// The address that answered, after redirects. The stored address is not
    /// rewritten from it.
    public var finalURL: URL
}

/// HTTP validators, kept exactly as the server sent them.
public struct Validators: Sendable, Hashable {
    public var etag: String?
    public var lastModified: String?
}

/// An answer that is not a feed, with what discovery needs to read it.
public struct NonFeedDocument: Sendable, Hashable {
    public var body: Data
    public var mediaType: String?
    public var charset: String?
    public var finalURL: URL
}

/// The media type and charset of a `Content-Type` header.
struct ContentType {
    var mediaType: String?
    var charset: String?

    init(_ header: String?) {
        guard let header else { return }
        let parts = header.split(separator: ";", omittingEmptySubsequences: false)
        let type = parts.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        mediaType = type.isEmpty ? nil : type
        for parameter in parts.dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "charset" else { continue }
            var value = pair[1].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            charset = value.isEmpty ? nil : value
            break
        }
    }
}
