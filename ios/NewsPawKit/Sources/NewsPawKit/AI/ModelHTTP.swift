import Foundation

/// One HTTP exchange with a model service (spec N08, N13; RD13 decision 7):
/// the replaceable interface between the model client and the network.
/// Tests supply their own; under the UI tests the app uses the fixture.
public protocol ModelHTTP: Sendable {
    /// Sends `request` once. A redirect is never followed and an
    /// authentication challenge is never answered.
    ///
    /// - Throws: a `ModelHTTPFailure`, or `CancellationError` when the
    ///   calling task is cancelled.
    func send(_ request: ModelHTTPRequest) async throws -> ModelHTTPResponse
}

/// What to send. The key travels apart from the other headers, as a value
/// that does not print, and only the implementation turns it into the
/// `Authorization` header.
public struct ModelHTTPRequest: Sendable {
    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
    }

    public var method: Method
    public var url: URL
    /// Sent as `Authorization: Bearer <key>`.
    public var authorization: SecretKey?
    /// Every other header field.
    public var headers: [String: String]
    public var body: Data?
    /// The whole exchange must end within this time.
    public var deadline: Duration

    public init(method: Method, url: URL, authorization: SecretKey?, headers: [String: String], body: Data?, deadline: Duration) {
        self.method = method
        self.url = url
        self.authorization = authorization
        self.headers = headers
        self.body = body
        self.deadline = deadline
    }
}

/// The answer: any status, with its header fields (lowercased names) and
/// body. A 2xx body is at most `URLSessionModelHTTP.maximumBytes`; another
/// status's body is cut at `URLSessionModelHTTP.maximumErrorBytes`.
public struct ModelHTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        self.body = body
    }
}

/// Why an exchange produced no answer to use. A closed set: no text from the
/// service is carried.
public enum ModelHTTPFailure: Error, Sendable, Hashable {
    /// No answer: name lookup, connection or TLS failure, a connection lost.
    case unreachable
    /// The deadline passed.
    case timedOut
    /// The service answered with a redirect, which is not followed.
    case redirected
    /// A 2xx body over the size limit, announced or read.
    case tooLarge
    /// An authentication challenge was cancelled; `status` is the status of
    /// the answer that raised it (401, or 407 for a proxy).
    case declinedAuthentication(status: Int)
}
