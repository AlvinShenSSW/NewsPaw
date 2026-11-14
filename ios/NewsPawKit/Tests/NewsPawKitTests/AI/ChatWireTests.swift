import Foundation
@testable import NewsPawKit
import Testing

/// RD13 decisions 7, 8 and 10: the request's exact shape, reading a reply,
/// and the classification table.
@Suite("Chat wire format")
struct ChatWireTests {
    // MARK: - Requests

    @Test("the chat body is the model, the two messages and stream false, and nothing else")
    func chatBodyExact() {
        let body = ChatWire.chatBody(model: "gpt-x", instructions: "Translate each text.", texts: ["One / two", "三"])
        let expected = #"{"messages":[{"content":"Translate each text.\n\nReply with only a JSON object of the form {\"texts\": [...]} whose \"texts\" member is an array of strings, and nothing else.","role":"system"},{"content":"[\"One / two\",\"三\"]","role":"user"}],"model":"gpt-x","stream":false}"#
        #expect(String(decoding: body, as: UTF8.self) == expected)
    }

    @Test("the chat request: POST to <address>/chat/completions with the key apart and JSON headers, 120 s")
    func chatRequest() throws {
        let secret = key("sk-request-0123456789")
        let request = try #require(ChatWire.chatRequest(
            address: "https://api.example.invalid/v1", model: "m", instructions: "i", texts: ["t"], key: secret
        ))
        #expect(request.method == .post)
        #expect(request.url.absoluteString == "https://api.example.invalid/v1/chat/completions")
        #expect(request.authorization == secret)
        #expect(request.headers == ["Accept": "application/json", "Content-Type": "application/json"])
        #expect(request.deadline == .seconds(120))
        #expect(request.body == ChatWire.chatBody(model: "m", instructions: "i", texts: ["t"]))
    }

    @Test("the list request: GET <address>/models, 30 s, no body")
    func listRequest() throws {
        let request = try #require(ChatWire.listRequest(address: "https://api.example.invalid", key: key("sk-list-0123456789")))
        #expect(request.method == .get)
        #expect(request.url.absoluteString == "https://api.example.invalid/models")
        #expect(request.headers == ["Accept": "application/json"])
        #expect(request.body == nil)
        #expect(request.deadline == .seconds(30))
    }

    // MARK: - Reading a reply (decision 8)

    private func read(_ content: String?, finishReason: String = "stop", refusal: String? = nil, usage: String? = #"{"prompt_tokens":11,"completion_tokens":7}"#) -> Result<ModelReply, ModelFailure> {
        guard let completion = ChatWire.decodeCompletion(completionBody(content, finishReason: finishReason, refusal: refusal, usage: usage)) else {
            return .failure(.unreachable)
        }
        return ChatWire.interpret(completion)
    }

    @Test("an object with texts is the reply, with the token counts")
    func object() {
        #expect(read(#"{"texts":["a","b"]}"#) == .success(ModelReply(texts: ["a", "b"], isCutOff: false, inputTokens: 11, outputTokens: 7)))
    }

    @Test("a bare array of strings is the reply")
    func bareArray() {
        #expect(read(#"["a"]"#) == .success(ModelReply(texts: ["a"], isCutOff: false, inputTokens: 11, outputTokens: 7)))
    }

    @Test("a reply inside a Markdown code fence is read", arguments: [
        "```json\n{\"texts\":[\"a\"]}\n```",
        "```\n[\"a\"]\n```",
        "  ```json\n{\"texts\": [\"a\"]}\n```  \n",
    ])
    func fenced(content: String) {
        #expect(read(content) == .success(ModelReply(texts: ["a"], isCutOff: false, inputTokens: 11, outputTokens: 7)))
    }

    @Test("a refusal, or a content filter, is refused")
    func refused() {
        #expect(read(nil, refusal: "I can't help with that.") == .failure(.refused))
        #expect(read(#"{"texts":["a"]}"#, refusal: "No.") == .failure(.refused))
        #expect(read(#"{"texts":["a"]}"#, finishReason: "content_filter") == .failure(.refused))
        #expect(read(#"{"texts":["a"]}"#, refusal: "") == .success(ModelReply(texts: ["a"], isCutOff: false, inputTokens: 11, outputTokens: 7)))
    }

    @Test("a cut-off reply with readable content is the reply with the flag; without, it is cut off")
    func cutOff() {
        #expect(read(#"{"texts":["a"]}"#, finishReason: "length") == .success(ModelReply(texts: ["a"], isCutOff: true, inputTokens: 11, outputTokens: 7)))
        #expect(read(#"{"texts":["a", "b"#, finishReason: "length") == .failure(.cutOff))
        #expect(read(nil, finishReason: "length") == .failure(.cutOff))
    }

    @Test("content that does not parse as the shape is malformed", arguments: [
        "Hallo", #"{"text":["a"]}"#, #"{"texts":"a"}"#, #"{"texts":["a",1]}"#, "[1,2]", "```json\n{\"texts\":[\"a\"]}", "",
    ])
    func malformed(content: String) {
        #expect(read(content) == .failure(.malformed))
    }

    @Test("nesting deep enough to end the process in the system parser is refused before it", arguments: ["[", "{\"a\":"])
    func deepNesting(opener: String) async {
        // About 480 levels overflow a concurrency thread's stack (RD04).
        let nested = String(repeating: opener, count: 2_000)
        let content = Data(nested.utf8)
        // Run where the app runs it: on a concurrency thread.
        await Task.detached {
            #expect(ChatWire.json(content) == nil)
            #expect(ChatWire.texts(in: nested) == nil)
            #expect(ChatWire.interpret(ChatWire.Completion(content: nested, finishReason: "stop")) == .failure(.malformed))
            let answer = ModelHTTPResponse(status: 200, headers: [:], body: content)
            #expect(ChatWire.classifyChat(answer) == .failure(.unreachable))
            #expect(ChatWire.classifyList(answer) == .failure(.unreachable))
            #expect(ChatWire.failure(status: 404, body: content) == .unreachable)
            // The limit leaves room for a real answer.
            #expect(ChatWire.texts(in: #"{"texts": ["a", "b"]}"#) == ["a", "b"])
        }.value
    }

    @Test("missing content is malformed")
    func missingContent() {
        #expect(read(nil) == .failure(.malformed))
    }

    @Test("token counts missing, negative, fractional or Boolean are left empty")
    func tokenCounts() {
        let expected = ModelReply(texts: ["a"], isCutOff: false, inputTokens: nil, outputTokens: nil)
        #expect(read(#"["a"]"#, usage: nil) == .success(expected))
        #expect(read(#"["a"]"#, usage: #"{"prompt_tokens":-1,"completion_tokens":1.5}"#) == .success(expected))
        #expect(read(#"["a"]"#, usage: #"{"prompt_tokens":true,"completion_tokens":"7"}"#) == .success(expected))
        #expect(read(#"["a"]"#, usage: #"{"prompt_tokens":0,"completion_tokens":3}"#)
            == .success(ModelReply(texts: ["a"], isCutOff: false, inputTokens: 0, outputTokens: 3)))
    }

    @Test("a 200 that is not a chat completion is not one", arguments: [
        "", "not json", "[]", #"{"choices":[]}"#, #"{"choices":[{"text":"a"}]}"#, #"{"data":[]}"#,
    ])
    func notACompletion(body: String) {
        #expect(ChatWire.decodeCompletion(Data(body.utf8)) == nil)
        #expect(ChatWire.classifyChat(ModelHTTPResponse(status: 200, headers: [:], body: Data(body.utf8))) == .failure(.unreachable))
    }

    // MARK: - Classification (decision 10)

    @Test("statuses map to the failures of decision 10", arguments: [
        (401, "", ModelFailure.keyRejected),
        (403, #"{"error":"moderation"}"#, .keyRejected),
        (404, #"{"error":{"message":"no such model"}}"#, .modelNotFound),
        (404, #"[{"error":{"code":404}}]"#, .modelNotFound),
        (404, #"{"message":"not found"}"#, .unreachable),
        (404, "<html>Not Found</html>", .unreachable),
        (404, "", .unreachable),
        (400, "", .badRequest),
        (413, "", .badRequest),
        (422, "", .badRequest),
        (402, "", .limited),
        (429, "", .limited),
        (500, "", .serverError),
        (503, "", .serverError),
        (599, "", .serverError),
        (201, "", .unreachable),
        (204, "", .unreachable),
        (302, "", .unreachable),
        (407, "", .unreachable),
        (418, "", .unreachable),
    ])
    func statuses(status: Int, body: String, failure: ModelFailure) {
        let response = ModelHTTPResponse(status: status, headers: [:], body: Data(body.utf8))
        #expect(ChatWire.classifyChat(response) == .failure(failure))
        #expect(ChatWire.classifyList(response) == .failure(failure))
    }

    @Test("an exchange without an answer maps to unreachable, a declined 401 challenge to key rejected")
    func transportFailures() {
        #expect(ChatWire.failure(.declinedAuthentication(status: 401)) == .keyRejected)
        #expect(ChatWire.failure(.declinedAuthentication(status: 407)) == .unreachable)
        for failure in [ModelHTTPFailure.unreachable, .timedOut, .redirected, .tooLarge] {
            #expect(ChatWire.failure(failure) == .unreachable)
        }
    }

    @Test("Test lines follow decision 10's Test column")
    func testLines() {
        #expect(TestOutcome(ModelFailure.keyRejected) == .keyRejected)
        #expect(TestOutcome(ModelFailure.modelNotFound) == .modelNotFound)
        #expect(TestOutcome(ModelFailure.badRequest) == .modelNotFound)
        #expect(TestOutcome(ModelFailure.limited) == .limited)
        #expect(TestOutcome(ModelFailure.serverError) == .couldNotConnect)
        #expect(TestOutcome(ModelFailure.unreachable) == .couldNotConnect)
    }

    // MARK: - Model list

    @Test("a model list is sorted, without repeats, at most 1,000")
    func modelList() {
        let body = #"{"object":"list","data":[{"id":"b"},{"id":"a"},{"id":"b"},{"name":"x"},{"id":7},{"id":"  "}]}"#
        #expect(ChatWire.decodeModelList(Data(body.utf8)) == ["a", "b"])
        let many = (0..<1_500).map { #"{"id":"m\#(String(format: "%04d", $0))"}"# }.joined(separator: ",")
        let list = ChatWire.decodeModelList(Data(#"{"data":[\#(many)]}"#.utf8))
        #expect(list?.count == 1_000)
        #expect(list?.first == "m0000")
        #expect(ChatWire.decodeModelList(Data("[]".utf8)) == nil)
        #expect(ChatWire.decodeModelList(Data(#"{"models":[]}"#.utf8)) == nil)
    }
}
