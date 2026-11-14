#if DEBUG
import Foundation

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
        default:
            throw ModelHTTPFailure.unreachable
        }
    }

    /// A completion whose content is `{"texts": [...]}` with the texts of the
    /// request's user message.
    private static func completion(echoing body: Data?) -> String {
        var texts: [String] = []
        if let body, let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
           let messages = object["messages"] as? [[String: Any]], let user = messages.last?["content"] as? String,
           let parsed = ChatWire.texts(in: user) {
            texts = parsed
        }
        let content = #"{"texts":\#(ChatWire.jsonArray(texts))}"#
        let message: [String: Any] = ["role": "assistant", "content": content]
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
