import Foundation
import Synchronization

/// The real model HTTP, on the system's URL loading (spec N08, N12; RD13
/// decision 7).
///
/// - Its own ephemeral session, separate from collection's: no cookies, no
///   credential storage, no cache, and TLS 1.2 at least (the app allows
///   arbitrary loads for http feeds, which also lifts the system's floor).
/// - No redirect is followed: the delegate refuses every one, so the 3xx
///   answer ends the exchange as `redirected` after one request.
/// - An HTTP authentication challenge is cancelled, after recording the
///   status that raised it: answering it any other way would send the
///   request a second time.
/// - A 2xx body over `maximumBytes` is a failure; another status's body is
///   read up to `maximumErrorBytes`, to classify the failure, and the rest
///   is dropped.
/// - The whole exchange is raced against the request's deadline.
///
/// No request is printed or logged: a `URLRequest`'s dump shows its header
/// values.
public final class URLSessionModelHTTP: ModelHTTP {
    /// 4 MB.
    public static let maximumBytes = 4 * 1024 * 1024
    /// 64 KB.
    public static let maximumErrorBytes = 64 * 1024

    private let session: URLSession
    private let maximumBytes: Int
    private let maximumErrorBytes: Int

    public convenience init() {
        self.init(maximumBytes: Self.maximumBytes, maximumErrorBytes: Self.maximumErrorBytes)
    }

    /// Tests pass smaller limits.
    init(maximumBytes: Int, maximumErrorBytes: Int) {
        self.maximumBytes = maximumBytes
        self.maximumErrorBytes = maximumErrorBytes
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func send(_ request: ModelHTTPRequest) async throws -> ModelHTTPResponse {
        try Task.checkCancellation()
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.httpShouldHandleCookies = false
        // The idle timeout must not end a slow model's answer before the
        // deadline does.
        urlRequest.timeoutInterval = TimeInterval(request.deadline.components.seconds) + 5
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        if let key = request.authorization {
            urlRequest.setValue("Bearer " + key.exposedValue, forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = request.body

        let exchange = ModelExchange(maximumBytes: maximumBytes, maximumErrorBytes: maximumErrorBytes)
        let task = session.dataTask(with: urlRequest)
        task.delegate = exchange
        let deadline = request.deadline
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
}

/// The state of one model exchange and its task's delegate.
final class ModelExchange: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        /// Why the exchange was ended by this side, recorded before the task
        /// is cancelled; it wins over whatever status or error follows.
        var refusal: ModelHTTPFailure?
        var callerCancelled = false
        var response: HTTPURLResponse?
        var body = Data()
        /// A non-2xx body reached its limit and the rest was dropped: the
        /// cancellation that follows still ends with the answer.
        var errorBodyCut = false
        var continuation: CheckedContinuation<ModelHTTPResponse, any Error>?
        var finished = false
        var outcome: Result<ModelHTTPResponse, any Error>?
    }

    private let state = Mutex(State())
    private let maximumBytes: Int
    private let maximumErrorBytes: Int

    init(maximumBytes: Int, maximumErrorBytes: Int) {
        self.maximumBytes = maximumBytes
        self.maximumErrorBytes = maximumErrorBytes
    }

    func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<ModelHTTPResponse, any Error>) {
        let ended: Result<ModelHTTPResponse, any Error>? = state.withLock { state in
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

    func refuse(_ reason: ModelHTTPFailure, task: URLSessionTask) {
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

    private func finish(_ result: Result<ModelHTTPResponse, any Error>) {
        let continuation: CheckedContinuation<ModelHTTPResponse, any Error>? = state.withLock { state in
            guard !state.finished else { return nil }
            state.finished = true
            guard let continuation = state.continuation else {
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
        state.withLock { state in
            if state.refusal == nil {
                state.refusal = .redirected
            }
        }
        // No new request: the 3xx answer ends the task (measured on iOS,
        // RD13 assumption A2).
        completionHandler(nil)
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
        let maximum = maximumBytes
        let disposition: URLSession.ResponseDisposition = state.withLock { state in
            guard let http = response as? HTTPURLResponse else {
                if state.refusal == nil {
                    state.refusal = .unreachable
                }
                return .cancel
            }
            if state.refusal != nil {
                return .cancel
            }
            state.response = http
            if (200..<300).contains(http.statusCode) {
                let announced = max(
                    http.expectedContentLength,
                    http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } ?? -1
                )
                if announced > Int64(maximum) {
                    state.refusal = .tooLarge
                    return .cancel
                }
            }
            return .allow
        }
        completionHandler(disposition)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let maximum = maximumBytes
        let maximumError = maximumErrorBytes
        let stop = state.withLock { state in
            guard state.refusal == nil, !state.finished, !state.errorBodyCut, let response = state.response else { return false }
            state.body.append(data)
            if (200..<300).contains(response.statusCode) {
                if state.body.count > maximum {
                    state.refusal = .tooLarge
                    state.body = Data()
                    return true
                }
            } else if state.body.count >= maximumError {
                state.body = state.body.prefix(maximumError)
                state.errorBodyCut = true
                return true
            }
            return false
        }
        if stop {
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let result: Result<ModelHTTPResponse, any Error> = state.withLock { state in
            if state.callerCancelled {
                return .failure(CancellationError())
            }
            if let refusal = state.refusal {
                return .failure(refusal)
            }
            if let response = state.response, error == nil || state.errorBodyCut {
                return .success(Self.makeResponse(response, body: state.body))
            }
            return .failure(Self.failure(for: error))
        }
        finish(result)
    }

    private static func makeResponse(_ response: HTTPURLResponse, body: Data) -> ModelHTTPResponse {
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            headers[String(describing: name).lowercased()] = String(describing: value)
        }
        return ModelHTTPResponse(status: response.statusCode, headers: headers, body: body)
    }

    private static func failure(for error: (any Error)?) -> ModelHTTPFailure {
        guard let error = error as? URLError else { return .unreachable }
        switch error.code {
        case .timedOut: return .timedOut
        case .dataLengthExceedsMaximum: return .tooLarge
        case .httpTooManyRedirects: return .redirected
        default: return .unreachable
        }
    }
}
