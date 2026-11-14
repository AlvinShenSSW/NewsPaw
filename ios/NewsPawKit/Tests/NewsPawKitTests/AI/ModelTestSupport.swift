import Foundation
import GRDB
@testable import NewsPawKit
import Synchronization
import Testing

/// A model HTTP that answers from a closure and records what it was asked,
/// key included, so that a test can see which address received which key.
final class StubModelHTTP: ModelHTTP {
    typealias Handler = @Sendable (ModelHTTPRequest) async throws -> ModelHTTPResponse

    private let handler: Handler
    private let requests = Mutex<[ModelHTTPRequest]>([])

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    var received: [ModelHTTPRequest] {
        requests.withLock { $0 }
    }

    func send(_ request: ModelHTTPRequest) async throws -> ModelHTTPResponse {
        requests.withLock { $0.append(request) }
        return try await handler(request)
    }

    /// Always gives the same answer.
    static func answering(_ status: Int, _ body: String = "", headers: [String: String] = [:]) -> StubModelHTTP {
        StubModelHTTP { _ in ModelHTTPResponse(status: status, headers: headers, body: Data(body.utf8)) }
    }

    /// Always fails with `failure`.
    static func failing(_ failure: ModelHTTPFailure) -> StubModelHTTP {
        StubModelHTTP { _ in throw failure }
    }

    /// A chat completion with `content` and token counts, and a list of two
    /// models for `GET …/models`.
    static func completing(_ content: String = #"{"texts":["Hallo"]}"#, finishReason: String = "stop") -> StubModelHTTP {
        StubModelHTTP { request in
            if request.method == .get {
                return ModelHTTPResponse(status: 200, headers: [:], body: Data(#"{"data":[{"id":"m-2"},{"id":"m-1"}]}"#.utf8))
            }
            return ModelHTTPResponse(status: 200, headers: [:], body: completionBody(content, finishReason: finishReason))
        }
    }
}

/// A chat completion's JSON.
func completionBody(_ content: String?, finishReason: String = "stop", refusal: String? = nil, usage: String? = #"{"prompt_tokens":11,"completion_tokens":7}"#) -> Data {
    var message: [String: Any] = ["role": "assistant", "content": content as Any? ?? NSNull()]
    if let refusal {
        message["refusal"] = refusal
    }
    var object: [String: Any] = ["choices": [["index": 0, "message": message, "finish_reason": finishReason]]]
    if let usage {
        object["usage"] = try! JSONSerialization.jsonObject(with: Data(usage.utf8))
    }
    return try! JSONSerialization.data(withJSONObject: object)
}

func key(_ text: String) -> SecretKey {
    guard case .success(let key) = SecretKey.validate(text) else {
        preconditionFailure("not a valid test key")
    }
    return key
}

/// A library in a fresh directory with its own image-cache directory, an
/// in-memory key store and `LibraryModels` over a given HTTP.
struct ModelsFixture {
    let directory: URL
    let clock: TestClock
    let library: Library
    let keys: InMemoryKeyStore
    let models: LibraryModels

    static func make(http: any ModelHTTP) async throws -> ModelsFixture {
        let directory = try makeTemporaryDirectory()
        let clock = TestClock()
        let store = LibraryStore(directory: directory, cacheRoot: directory.appending(path: "Images"), now: clock.now)
        let library = try await store.openNormal()
        let keys = InMemoryKeyStore()
        return ModelsFixture(
            directory: directory, clock: clock, library: library, keys: keys,
            models: LibraryModels(library: library, keys: keys, http: http)
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Saves a slot of `role` at `address` with `key`.
    @discardableResult
    func save(
        _ role: ModelRole = .primary, address: String = "https://api.example.invalid/v1", model: String = "test-model",
        key text: String? = "sk-test-key-0123456789", preset: ModelPreset = .custom, tested: TestOutcome? = nil
    ) async throws -> ModelSlotStatus {
        try await models.save(
            ModelSlotDraft(role: role, preset: preset, address: address, model: model, newKey: text.map(key)),
            testedOutcome: tested
        )
    }

    func slot(_ role: ModelRole = .primary) async throws -> ModelSlot? {
        try await library.modelSlot(role)
    }

    func usage() async throws -> [UsageRecord] {
        try await library.usageRecords()
    }

    /// Makes every write to `model_slot` fail.
    func failSlotWrites() async throws {
        try await library.pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_slot_insert BEFORE INSERT ON model_slot BEGIN SELECT RAISE(FAIL, 'refused by the test'); END;
                CREATE TRIGGER fail_slot_update BEFORE UPDATE ON model_slot BEGIN SELECT RAISE(FAIL, 'refused by the test'); END;
                CREATE TRIGGER fail_slot_delete BEFORE DELETE ON model_slot BEGIN SELECT RAISE(FAIL, 'refused by the test'); END;
                """)
        }
    }

    func allowSlotWrites() async throws {
        try await library.pool.write { db in
            try db.execute(sql: "DROP TRIGGER fail_slot_insert; DROP TRIGGER fail_slot_update; DROP TRIGGER fail_slot_delete;")
        }
    }
}

/// Runs `body` and returns what it threw, or `nil`.
func thrown(_ body: () async throws -> some Any) async -> (any Error)? {
    do {
        _ = try await body()
        return nil
    } catch {
        return error
    }
}

/// `ios/NewsPawKit/Sources/NewsPawKit` in the repository.
var packageSourcesDirectory: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // AI
        .deletingLastPathComponent() // NewsPawKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // NewsPawKit
        .appending(path: "Sources/NewsPawKit")
}

func swiftSources(in directory: URL) -> [URL] {
    let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
    return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
}
