#if DEBUG
import Foundation
import Synchronization

/// The model HTTP of a debug build running under the UI tests (RD13): it
/// answers by host under `models.example.invalid` and reports every other
/// host as no answer, so no UI test reaches a real service. Compiled into
/// debug builds only; release builds do not contain it.
public final class FixtureModelHTTP: ModelHTTP {
    /// The addresses of the table.
    public enum Address {
        /// A chat completion that returns its input texts, with token
        /// counts; a list of three models.
        public static let passed = "https://passed.models.example.invalid/v1"
        /// 401.
        public static let rejected = "https://rejected.models.example.invalid/v1"
        /// 404 with the service's error body.
        public static let noModel = "https://nomodel.models.example.invalid/v1"
        /// 429.
        public static let limited = "https://limited.models.example.invalid/v1"
        /// 503.
        public static let down = "https://down.models.example.invalid/v1"
        /// 302 to another address.
        public static let redirect = "https://redirect.models.example.invalid/v1"
        /// A translator (RD14 decision 13): it answers each text with
        /// "译[<language asked for>]：" before it, and obeys the words of
        /// `Word` in the texts it is sent.
        public static let translate = "https://translate.models.example.invalid/v1"
        /// The same without the 429, as a backup.
        public static let translateBackup = "https://translate-backup.models.example.invalid/v1"
    }

    /// The words the translator obeys, anywhere in a request's texts.
    public enum Word {
        /// The model declines the whole request.
        public static let refuse = "fixture:refuse"
        /// 429 from `translate`; the backup ignores it.
        public static let limit = "fixture:limit"
        /// The answer comes after `slowAnswer`.
        public static let slow = "fixture:slow"
        /// The first request carrying it in this process answers after
        /// `stallingAnswer` unless it is cancelled; later ones at once
        /// (RD15 decision 16).
        public static let stallOnce = "fixture:stall-once"
        /// The first request carrying it in this process answers 503; later
        /// ones translate.
        public static let failOnce = "fixture:fail-once"
        /// `translate` refuses; the backup translates.
        public static let refusePrimary = "fixture:refuse-primary"
    }

    /// How long the translator takes for a request with `Word.slow`.
    static let slowAnswer = Duration.seconds(2)
    /// How long the first request with `Word.stallOnce` takes.
    static let stallingAnswer = Duration.seconds(60)

    /// Whether a request with `Word.stallOnce`, and one with
    /// `Word.failOnce`, has arrived in this process.
    private static let onceWords = Mutex<Set<String>>([])

    /// Whether the stalling request has begun its wait (for the package
    /// test, which other tests' requests would confuse with the count).
    private static let stallStarted = Mutex(false)

    static var hasStalled: Bool {
        stallStarted.withLock { $0 }
    }

    /// Whether this is the first request of the process carrying `word`.
    private static func firstTime(_ word: String) -> Bool {
        onceWords.withLock { $0.insert(word).inserted }
    }

    /// The chat requests this process has sent to the translator hosts, for
    /// the UI tests' report.
    private static let translationRequestCount = Mutex(0)

    public static var translationRequests: Int {
        translationRequestCount.withLock { $0 }
    }

    /// The three models `passed` lists, in the order it lists them.
    public static let listedModels = ["fixture-model-b", "fixture-model-a", "fixture-model-c"]

    public init() {}

    public func send(_ request: ModelHTTPRequest) async throws -> ModelHTTPResponse {
        try Task.checkCancellation()
        let host = request.url.host(percentEncoded: false)?.lowercased() ?? ""
        let json = ["Content-Type": "application/json"]
        func answer(_ status: Int, _ body: String = "") -> ModelHTTPResponse {
            ModelHTTPResponse(status: status, headers: json, body: Data(body.utf8))
        }
        switch host {
        case "passed.models.example.invalid":
            if request.url.path.hasSuffix("/models") {
                let entries = Self.listedModels.map { #"{"id":"\#($0)","object":"model"}"# }.joined(separator: ",")
                return answer(200, #"{"object":"list","data":[\#(entries)]}"#)
            }
            return answer(200, Self.completion(echoing: request.body))
        case "rejected.models.example.invalid":
            return answer(401, #"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error"}}"#)
        case "nomodel.models.example.invalid":
            return answer(404, #"{"error":{"message":"The model does not exist","type":"invalid_request_error"}}"#)
        case "limited.models.example.invalid":
            return answer(429, #"{"error":{"message":"Rate limit reached","type":"requests"}}"#)
        case "down.models.example.invalid":
            return answer(503, "Service Unavailable")
        case "redirect.models.example.invalid":
            throw ModelHTTPFailure.redirected
        case "translate.models.example.invalid", "translate-backup.models.example.invalid":
            if request.url.path.hasSuffix("/models") {
                return answer(200, #"{"object":"list","data":[{"id":"fixture-translator","object":"model"}]}"#)
            }
            Self.translationRequestCount.withLock { $0 += 1 }
            let (system, texts) = Self.messages(of: request.body)
            if texts.contains(where: { $0.contains(Word.slow) }) {
                try await Task.sleep(for: Self.slowAnswer)
            }
            if texts.contains(where: { $0.contains(Word.stallOnce) }), Self.firstTime(Word.stallOnce) {
                Self.stallStarted.withLock { $0 = true }
                try await Task.sleep(for: Self.stallingAnswer)
            }
            if texts.contains(where: { $0.contains(Word.failOnce) }), Self.firstTime(Word.failOnce) {
                return answer(503, "Service Unavailable")
            }
            if host == "translate.models.example.invalid", texts.contains(where: { $0.contains(Word.refusePrimary) }) {
                return answer(200, Self.completion(content: nil, refusal: "I can't translate this."))
            }
            if texts.contains(where: { $0.contains(Word.refuse) && !$0.contains(Word.refusePrimary) }) {
                return answer(200, Self.completion(content: nil, refusal: "I can't translate this."))
            }
            if host == "translate.models.example.invalid", texts.contains(where: { $0.contains(Word.limit) }) {
                return answer(429, #"{"error":{"message":"Rate limit reached","type":"requests"}}"#)
            }
            let mark = "译[" + Self.languageTag(in: system) + "]："
            let translated = ChatWire.jsonArray(texts.map { mark + $0 })
            return answer(200, Self.completion(content: #"{"texts":\#(translated)}"#))
        default:
            throw ModelHTTPFailure.unreachable
        }
    }

    /// A completion whose content is `{"texts": [...]}` with the texts of the
    /// request's user message.
    private static func completion(echoing body: Data?) -> String {
        completion(content: #"{"texts":\#(ChatWire.jsonArray(messages(of: body).texts))}"#)
    }

    /// The system message and the texts of a request's user message.
    private static func messages(of body: Data?) -> (system: String, texts: [String]) {
        guard let body, let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let messages = object["messages"] as? [[String: Any]]
        else { return ("", []) }
        let system = messages.first?["content"] as? String ?? ""
        let texts = (messages.last?["content"] as? String).flatMap(ChatWire.texts(in:)) ?? []
        return (system, texts)
    }

    /// The first bracketed language tag of the instructions: the language
    /// asked for (`TranslationPrompt` names it so).
    private static func languageTag(in system: String) -> String {
        guard let match = system.firstMatch(of: /\(([A-Za-z]{2,3}(?:-[A-Za-z]{2,4})?)\)/) else { return "?" }
        return String(match.1)
    }

    /// A chat completion with `content`, or with a refusal.
    private static func completion(content: String?, refusal: String? = nil) -> String {
        var message: [String: Any] = ["role": "assistant", "content": content as Any? ?? NSNull()]
        if let refusal {
            message["refusal"] = refusal
        }
        let reply: [String: Any] = [
            "id": "fixture",
            "object": "chat.completion",
            "choices": [["index": 0, "message": message, "finish_reason": "stop"]],
            "usage": ["prompt_tokens": 12, "completion_tokens": 5, "total_tokens": 17],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
