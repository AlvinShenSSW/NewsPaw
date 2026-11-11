import Foundation

/// One HTTP exchange for collection (spec N04, N13): the replaceable
/// interface between collection and the network. Tests supply their own.
public protocol Transport: Sendable {
    /// Fetches `request.url`, following redirects under the transport's
    /// rules.
    ///
    /// - Throws: a `TransportFailure`, or `CancellationError` when the
    ///   calling task is cancelled.
    func fetch(_ request: TransportRequest) async throws -> TransportResponse
}

/// What to fetch: an address and the validators stored from the last full
/// answer, sent exactly as stored.
public struct TransportRequest: Sendable, Hashable {
    public var url: URL
    public var etag: String?
    public var lastModified: String?

    public init(url: URL, etag: String? = nil, lastModified: String? = nil) {
        self.url = url
        self.etag = etag
        self.lastModified = lastModified
    }
}

/// The final answer of an exchange.
public struct TransportResponse: Sendable, Hashable {
    /// The address that answered, after redirects.
    public var finalURL: URL
    public var status: Int
    /// Header fields with lowercased names.
    public var headers: [String: String]
    /// The decoded body. Only a 2xx answer's body is read; others are empty.
    public var body: Data

    public init(finalURL: URL, status: Int, headers: [String: String], body: Data) {
        self.finalURL = finalURL
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        self.body = body
    }

    /// The value of the header field `name`, whatever its case.
    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

/// Why an exchange produced no answer to use.
public enum TransportFailure: Error, Sendable, Hashable {
    /// No answer: name lookup, connection or TLS failure, a connection lost
    /// mid-body, an undecodable body, a load the system blocks.
    case unreachable
    /// The deadline passed before the exchange ended.
    case timedOut
    /// More than the byte limit, announced or decoded.
    case tooLarge
    /// More redirects than allowed.
    case tooManyRedirects
    /// The address or a redirect target is not http or https, or carries a
    /// user name or password.
    case unsupportedAddress
    /// An authentication challenge was declined; `status` is the status of
    /// the answer that raised it (401, or 407 for a proxy).
    case declinedAuthentication(status: Int)
}

/// The fixed rules of collection (spec N04).
public struct TransportLimits: Sendable, Hashable {
    /// The whole exchange, redirects included, must end within this time.
    public var deadline: Duration
    /// The largest decoded body accepted, in bytes.
    public var maximumBytes: Int
    /// The most redirects followed.
    public var maximumRedirects: Int

    public init(deadline: Duration, maximumBytes: Int, maximumRedirects: Int) {
        self.deadline = deadline
        self.maximumBytes = maximumBytes
        self.maximumRedirects = maximumRedirects
    }

    /// 20 seconds, 10 MB (10 × 1024 × 1024 bytes), 5 redirects.
    public static let standard = TransportLimits(deadline: .seconds(20), maximumBytes: 10 * 1024 * 1024, maximumRedirects: 5)
}

extension URL {
    /// Whether collection may request this address: http or https, with a
    /// host, and without a user name or password (which the system would
    /// send before any delegate is asked).
    var isCollectableAddress: Bool {
        guard let scheme = scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = host(percentEncoded: false), !host.isEmpty
        else { return false }
        return user(percentEncoded: true) == nil && password(percentEncoded: true) == nil
    }
}
