import CoreFoundation
import Foundation

/// Why a model request failed (RD13 decisions 8 and 10). A closed set: no
/// text from the service is carried, because a service may echo the key in
/// its error message.
public enum ModelFailure: Error, Sendable, Hashable {
    /// The slot has no usable key; no request was made.
    case keyNeeded
    /// The library has no slot for the role; no request was made.
    case noModelSetUp
    /// 401 or 403.
    case keyRejected
    /// 404 with the service's own error body.
    case modelNotFound
    /// 400, 413 or 422: the service objects to the request.
    case badRequest
    /// 402 or 429.
    case limited
    /// 5xx.
    case serverError
    /// No answer, the deadline, a TLS failure, a redirect, a 407 challenge,
    /// a 404 without the service's error body, any other status, a 200 that
    /// is not a chat completion or a model list, a reply over the size
    /// limit.
    case unreachable
    /// The model declined: a refusal, or `finish_reason` = `content_filter`.
    case refused
    /// The reply was cut off (`finish_reason` = `length`) before it could be
    /// read.
    case cutOff
    /// The reply's content is not the requested shape.
    case malformed

    /// The `usage.outcome` of a sent request that failed this way, or `nil`
    /// for the failures that make no request.
    var usageOutcome: UsageOutcome? {
        switch self {
        case .keyNeeded, .noModelSetUp: nil
        case .keyRejected: .keyRejected
        case .modelNotFound: .modelNotFound
        case .badRequest: .badRequest
        case .limited: .limited
        case .serverError: .serverError
        case .unreachable: .unreachable
        case .refused: .refused
        case .cutOff: .cutOff
        case .malformed: .malformed
        }
    }
}

extension TestOutcome {
    /// The Test line of a failed exchange (decision 10's Test column). Load
    /// List shows the same line for its failures.
    public init(_ failure: ModelFailure) {
        switch failure {
        case .keyRejected: self = .keyRejected
        // Test's request is fixed by the app, so what a service objects to
        // is in practice the model's name.
        case .modelNotFound, .badRequest: self = .modelNotFound
        case .limited: self = .limited
        case .serverError, .unreachable, .refused, .cutOff, .malformed, .keyNeeded, .noModelSetUp: self = .couldNotConnect
        }
    }
}

/// What `send` returns (decision 8).
public struct ModelReply: Sendable, Hashable {
    /// The reply's texts, as the model returned them. Their number and
    /// order are for the caller to check.
    public let texts: [String]
    /// Whether the service cut the reply off (`finish_reason` = `length`)
    /// although its content could be read.
    public let isCutOff: Bool
    /// The token counts, when the service returned them as non-negative
    /// integers.
    public let inputTokens: Int?
    public let outputTokens: Int?
}

/// The OpenAI-compatible chat wire format (spec N08; RD13 decisions 7, 8
/// and 10): pure functions that build requests, read replies and classify
/// answers.
enum ChatWire {
    /// The deadline of a chat request.
    static let chatDeadline = Duration.seconds(120)
    /// The deadline of a model list request.
    static let listDeadline = Duration.seconds(30)

    /// The sentence that ends every system message. It fixes only the
    /// reply's shape; how many strings, and in what order, is for the
    /// caller's instructions to say.
    static let shapeSentence = #"Reply with only a JSON object of the form {"texts": [...]} whose "texts" member is an array of strings, and nothing else."#

    // MARK: - Requests

    /// `POST <address>/chat/completions` with the model, the system and
    /// user messages and `"stream": false`, and nothing else.
    static func chatRequest(address: String, model: String, instructions: String, texts: [String], key: SecretKey) -> ModelHTTPRequest? {
        guard let url = URL(string: address + "/chat/completions") else { return nil }
        return ModelHTTPRequest(
            method: .post, url: url, authorization: key,
            headers: ["Accept": "application/json", "Content-Type": "application/json"],
            body: chatBody(model: model, instructions: instructions, texts: texts),
            deadline: chatDeadline
        )
    }

    /// `GET <address>/models`.
    static func listRequest(address: String, key: SecretKey) -> ModelHTTPRequest? {
        guard let url = URL(string: address + "/models") else { return nil }
        return ModelHTTPRequest(
            method: .get, url: url, authorization: key, headers: ["Accept": "application/json"], body: nil, deadline: listDeadline
        )
    }

    /// The chat body, with sorted keys so that it is the same bytes every
    /// time. The system message is the instructions followed by the shape
    /// sentence; the user message is the JSON array of the texts.
    static func chatBody(model: String, instructions: String, texts: [String]) -> Data {
        let system = instructions.isEmpty ? shapeSentence : instructions + "\n\n" + shapeSentence
        let object: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": jsonArray(texts)],
            ],
            "stream": false,
        ]
        // Strings, arrays, dictionaries and a Boolean always serialise.
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    static func jsonArray(_ texts: [String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: texts, options: [.withoutEscapingSlashes])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Answers

    /// A chat completion's parts that the client reads.
    struct Completion: Sendable, Hashable {
        var content: String?
        var refusal: String?
        var finishReason: String?
        var promptTokens: Int?
        var completionTokens: Int?
    }

    /// Classifies a chat answer (decision 10): a completion, or the failure.
    static func classifyChat(_ response: ModelHTTPResponse) -> Result<Completion, ModelFailure> {
        if response.status == 200 {
            guard let completion = decodeCompletion(response.body) else { return .failure(.unreachable) }
            return .success(completion)
        }
        return .failure(failure(status: response.status, body: response.body))
    }

    /// Classifies a model-list answer: the identifiers, sorted, without
    /// repeats, at most `maximumListLength`; or the failure.
    static func classifyList(_ response: ModelHTTPResponse) -> Result<[String], ModelFailure> {
        if response.status == 200 {
            guard let models = decodeModelList(response.body) else { return .failure(.unreachable) }
            return .success(models)
        }
        return .failure(failure(status: response.status, body: response.body))
    }

    /// The most model identifiers a list shows.
    static let maximumListLength = 1_000

    /// The failure of a status other than 200.
    static func failure(status: Int, body: Data) -> ModelFailure {
        switch status {
        case 401, 403: .keyRejected
        case 404: hasErrorMember(body) ? .modelNotFound : .unreachable
        case 400, 413, 422: .badRequest
        case 402, 429: .limited
        case 500..<600: .serverError
        default: .unreachable
        }
    }

    /// The failure of an exchange that produced no answer.
    static func failure(_ failure: ModelHTTPFailure) -> ModelFailure {
        switch failure {
        case .declinedAuthentication(let status) where status == 401 || status == 403: .keyRejected
        case .declinedAuthentication, .unreachable, .timedOut, .redirected, .tooLarge: .unreachable
        }
    }

    /// Whether a body is a JSON object with an `error` member, or an array
    /// whose first element is one: the service's own error, as opposed to a
    /// web server's page for an address that does not exist.
    static func hasErrorMember(_ body: Data) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: body) else { return false }
        if let object = value as? [String: Any] {
            return object["error"] != nil
        }
        if let array = value as? [Any], let first = array.first as? [String: Any] {
            return first["error"] != nil
        }
        return false
    }

    /// A chat completion with a message, or `nil` when the body is not one.
    static func decodeCompletion(_ body: Data) -> Completion? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let choices = object["choices"] as? [Any],
              let choice = choices.first as? [String: Any],
              let message = choice["message"] as? [String: Any]
        else { return nil }
        let usage = object["usage"] as? [String: Any]
        return Completion(
            content: message["content"] as? String,
            refusal: message["refusal"] as? String,
            finishReason: choice["finish_reason"] as? String,
            promptTokens: count(usage?["prompt_tokens"]),
            completionTokens: count(usage?["completion_tokens"])
        )
    }

    /// A token count: a non-negative integer, not a Boolean or a fraction.
    static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double >= 0, double.rounded() == double, let integer = Int(exactly: double) else { return nil }
        return integer
    }

    /// Reads a completion (decision 8), in this order: a refusal or a
    /// content filter is "refused"; content that parses — after removing a
    /// surrounding Markdown code fence — as `{"texts": [...]}` or as a bare
    /// array of strings is the reply, cut off when `finish_reason` =
    /// `length`; content that does not parse is "cut off" when
    /// `finish_reason` = `length` and "malformed" otherwise.
    static func interpret(_ completion: Completion) -> Result<ModelReply, ModelFailure> {
        if let refusal = completion.refusal, !refusal.isEmpty {
            return .failure(.refused)
        }
        if completion.finishReason == "content_filter" {
            return .failure(.refused)
        }
        let cutOff = completion.finishReason == "length"
        guard let content = completion.content, let texts = texts(in: content) else {
            return .failure(cutOff ? .cutOff : .malformed)
        }
        return .success(ModelReply(
            texts: texts, isCutOff: cutOff, inputTokens: completion.promptTokens, outputTokens: completion.completionTokens
        ))
    }

    /// The strings of `{"texts": [...]}` or of a bare array of strings,
    /// inside an optional Markdown code fence.
    static func texts(in content: String) -> [String]? {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            guard let lineEnd = text.firstIndex(of: "\n") else { return nil }
            text = String(text[text.index(after: lineEnd)...])
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasSuffix("```") else { return nil }
            text = String(trimmed.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return nil }
        if let object = value as? [String: Any] {
            return strings(object["texts"])
        }
        return strings(value)
    }

    private static func strings(_ value: Any?) -> [String]? {
        guard let array = value as? [Any] else { return nil }
        var result: [String] = []
        for element in array {
            guard let string = element as? String else { return nil }
            result.append(string)
        }
        return result
    }

    /// The identifiers of an OpenAI-style model list (`{"data": [{"id":
    /// …}]}`), sorted, without repeats, at most `maximumListLength`; `nil`
    /// when the body is not such a list.
    static func decodeModelList(_ body: Data) -> [String]? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let data = object["data"] as? [Any]
        else { return nil }
        var identifiers = Set<String>()
        for element in data {
            if let entry = element as? [String: Any], let id = entry["id"] as? String,
               case .success(let name) = ModelName.validate(id) {
                identifiers.insert(name)
            }
        }
        return Array(identifiers.sorted().prefix(maximumListLength))
    }
}
