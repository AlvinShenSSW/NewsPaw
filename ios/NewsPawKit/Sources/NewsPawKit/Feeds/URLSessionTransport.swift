import Foundation
import Synchronization

/// The real transport, on the system's URL loading (spec N04, N12).
///
/// - An ephemeral session with no cookie storage, no credential storage and
///   no cache: nothing identifying is stored or sent.
/// - Fixed `User-Agent`, `Accept-Language` and `Accept`, on every request and
///   every redirect. The user agent is generic: the app's own name would be
///   unique to its one user and would link requests across feeds and
///   partitions.
/// - Redirects past the limit, to a scheme other than http or https, or to
///   an address with a user name or password are refused: the reason is
///   recorded and the task cancelled, and that reason is reported before any
///   status or error.
/// - HTTP and proxy authentication challenges are declined and reported with
///   the status that raised them; server-trust and client-certificate
///   challenges get default handling (the app holds no identity, so nothing
///   is sent).
/// - The body is read as a stream and abandoned once its decoded size passes
///   the limit; a larger announced length is refused at once.
/// - The whole exchange, redirects included, is raced against the deadline.
public final class URLSessionTransport: Transport {
    public static let userAgent = "Mozilla/5.0 (compatible; feed reader)"
    public static let acceptLanguage = "*"
    public static let accept =
        "application/rss+xml, application/atom+xml, application/feed+json, application/rdf+xml, "
        + "application/xml;q=0.9, text/xml;q=0.9, application/json;q=0.8, */*;q=0.5"

    private let session: URLSession
    private let limits: TransportLimits

    public convenience init(limits: TransportLimits = .standard) {
        self.init(limits: limits, protocolClasses: nil)
    }

    /// - Parameter protocolClasses: URL-loading stubs for tests; `nil` uses
    ///   the system's own loading.
    init(limits: TransportLimits, protocolClasses: [AnyClass]?) {
        self.limits = limits
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = Self.fixedHeaders
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    static let fixedHeaders: [String: String] = [
        "User-Agent": userAgent,
        "Accept-Language": acceptLanguage,
        "Accept": accept,
    ]

    public func fetch(_ request: TransportRequest) async throws -> TransportResponse {
        guard request.url.isCollectableAddress else {
            throw TransportFailure.unsupportedAddress
        }
        try Task.checkCancellation()

        var urlRequest = URLRequest(url: request.url)
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.httpShouldHandleCookies = false
        Self.applyFixedHeaders(to: &urlRequest)
        if let etag = request.etag {
            urlRequest.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = request.lastModified {
            urlRequest.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        let exchange = Exchange(limits: limits)
        let task = session.dataTask(with: urlRequest)
        task.delegate = exchange
        let deadline = limits.deadline
        let timer = Task {
            try? await Task.sleep(for: deadline)
            if !Task.isCancelled {
                exchange.refuse(.timedOut, task: task)
            }
        }
        defer { timer.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                exchange.start(task, continuation: continuation)
            }
        } onCancel: {
            exchange.cancelByCaller(task)
        }
    }

    static func applyFixedHeaders(to request: inout URLRequest) {
        for (field, value) in fixedHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
    }
}

/// The state of one exchange and its task's delegate. Internal so that tests
/// can drive the order of its events.
final class Exchange: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var redirects = 0
        /// Why the transport ended the exchange, recorded before the task is
        /// cancelled; it wins over whatever status or error follows.
        var refusal: TransportFailure?
        var callerCancelled = false
        var response: HTTPURLResponse?
        var body = Data()
        /// Set when a non-2xx answer arrived: its body is not read.
        var stoppedAfterHead = false
        var continuation: CheckedContinuation<TransportResponse, any Error>?
        var finished = false
        /// The result of an exchange that ended before `start` handed over
        /// its continuation.
        var outcome: Result<TransportResponse, any Error>?
    }

    private let state = Mutex(State())
    private let limits: TransportLimits

    init(limits: TransportLimits) {
        self.limits = limits
    }

    /// Starts the task, or ends at once with the exchange's result when it
    /// has already ended: cancelled by the caller, refused (the deadline
    /// passed, say), or finished, before `start` was called.
    func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<TransportResponse, any Error>) {
        let ended: Result<TransportResponse, any Error>? = state.withLock { state in
            if state.callerCancelled {
                state.finished = true
                return .failure(CancellationError())
            }
            if let outcome = state.outcome {
                return outcome
            }
            if let refusal = state.refusal {
                state.finished = true
                return .failure(refusal)
            }
            state.continuation = continuation
            return nil
        }
        if let ended {
            task.cancel()
            continuation.resume(with: ended)
        } else {
            task.resume()
        }
    }

    func refuse(_ reason: TransportFailure, task: URLSessionTask) {
        state.withLock { state in
            if state.refusal == nil, !state.finished {
                state.refusal = reason
            }
        }
        task.cancel()
    }

    func cancelByCaller(_ task: URLSessionTask) {
        state.withLock { $0.callerCancelled = true }
        task.cancel()
    }

    private func finish(_ result: Result<TransportResponse, any Error>) {
        let continuation: CheckedContinuation<TransportResponse, any Error>? = state.withLock { state in
            guard !state.finished else { return nil }
            state.finished = true
            guard let continuation = state.continuation else {
                // Ended before `start`: kept for it.
                state.outcome = result
                return nil
            }
            state.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }

    // MARK: - Delegate

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let maximum = limits.maximumRedirects
        let refusal: TransportFailure? = state.withLock { state in
            state.redirects += 1
            let reason: TransportFailure?
            if request.url?.isCollectableAddress != true {
                reason = .unsupportedAddress
            } else if state.redirects > maximum {
                reason = .tooManyRedirects
            } else {
                reason = nil
            }
            if let reason, state.refusal == nil {
                state.refusal = reason
            }
            return reason
        }
        if refusal != nil {
            task.cancel()
            completionHandler(nil)
            return
        }
        var next = request
        next.httpShouldHandleCookies = false
        URLSessionTransport.applyFixedHeaders(to: &next)
        completionHandler(next)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodServerTrust || method == NSURLAuthenticationMethodClientCertificate {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let status = (challenge.failureResponse as? HTTPURLResponse)?.statusCode
            ?? (challenge.protectionSpace.isProxy() ? 407 : 401)
        state.withLock { state in
            if state.refusal == nil {
                state.refusal = .declinedAuthentication(status: status)
            }
        }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let maximum = limits.maximumBytes
        let disposition: URLSession.ResponseDisposition = state.withLock { state in
            guard let http = response as? HTTPURLResponse else {
                if state.refusal == nil {
                    state.refusal = .unreachable
                }
                return .cancel
            }
            state.response = http
            if !(200..<300).contains(http.statusCode) {
                state.stoppedAfterHead = true
                return .cancel
            }
            let announced = max(
                http.expectedContentLength,
                http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } ?? -1
            )
            // With a content encoding the announced length is the encoded
            // one; the decoded body is at least as large.
            if announced > Int64(maximum) {
                if state.refusal == nil {
                    state.refusal = .tooLarge
                }
                return .cancel
            }
            return .allow
        }
        completionHandler(disposition)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let maximum = limits.maximumBytes
        let overLimit = state.withLock { state in
            guard state.refusal == nil, !state.finished else { return false }
            state.body.append(data)
            if state.body.count > maximum {
                state.refusal = .tooLarge
                state.body = Data()
                return true
            }
            return false
        }
        if overLimit {
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let result: Result<TransportResponse, any Error> = state.withLock { state in
            if state.callerCancelled {
                return .failure(CancellationError())
            }
            if let refusal = state.refusal {
                return .failure(refusal)
            }
            if let response = state.response, error == nil || state.stoppedAfterHead {
                let fallback = task.currentRequest?.url ?? task.originalRequest?.url
                return .success(Self.makeResponse(response, body: state.stoppedAfterHead ? Data() : state.body, fallbackURL: fallback))
            }
            return .failure(Self.failure(for: error))
        }
        finish(result)
    }

    private static func makeResponse(_ response: HTTPURLResponse, body: Data, fallbackURL: URL?) -> TransportResponse {
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            headers[String(describing: name).lowercased()] = String(describing: value)
        }
        return TransportResponse(
            finalURL: response.url ?? fallbackURL ?? URL(fileURLWithPath: "/"),
            status: response.statusCode,
            headers: headers,
            body: body
        )
    }

    private static func failure(for error: (any Error)?) -> TransportFailure {
        guard let error = error as? URLError else { return .unreachable }
        switch error.code {
        case .timedOut: return .timedOut
        // The loader refuses a redirect to a `file:` address itself, before
        // the delegate is asked, with one of the file errors. The source
        // address is always http or https, so a file error can only come
        // from such a redirect.
        case .unsupportedURL, .noPermissionsToReadFile, .fileDoesNotExist, .fileIsDirectory: return .unsupportedAddress
        case .httpTooManyRedirects: return .tooManyRedirects
        case .dataLengthExceedsMaximum: return .tooLarge
        default: return .unreachable
        }
    }
}
