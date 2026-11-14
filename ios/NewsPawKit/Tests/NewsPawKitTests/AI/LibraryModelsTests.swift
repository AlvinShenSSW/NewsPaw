import Foundation
@testable import NewsPawKit
import Testing

/// RD13 decisions 8–12: send, Test and Load List on a stubbed HTTP, with
/// the usage rows each leaves. Criteria 6, 7, 8, 9, 11, 12 and 13.
@Suite("Library models")
struct LibraryModelsTests {
    static let address = "https://api.example.invalid/v1"

    private func draft(
        _ role: ModelRole = .primary, address: String = LibraryModelsTests.address, model: String = "test-model", key text: String? = nil
    ) -> ModelSlotDraft {
        ModelSlotDraft(role: role, preset: .custom, address: address, model: model, newKey: text.map(key))
    }

    // MARK: - Send

    @Test("send: one request to <address>/chat/completions with the slot's key; the reply's texts and a usage row")
    func sendSucceeds() async throws {
        let http = StubModelHTTP.completing(#"{"texts":["Hallo","Welt"]}"#)
        let fixture = try await ModelsFixture.make(http: http)
        defer { fixture.remove() }
        try await fixture.save(key: "sk-send-key-0123456789")
        let reply = try await fixture.models.send(texts: ["Hello", "World"], instructions: "Translate.", purpose: .titles, role: .primary)
        #expect(reply == ModelReply(texts: ["Hallo", "Welt"], isCutOff: false, inputTokens: 11, outputTokens: 7))
        let request = try #require(http.received.first)
        #expect(http.received.count == 1)
        #expect(request.url.absoluteString == "https://api.example.invalid/v1/chat/completions")
        #expect(request.authorization == key("sk-send-key-0123456789"))
        #expect(request.body == ChatWire.chatBody(model: "test-model", instructions: "Translate.", texts: ["Hello", "World"]))
        let usage = try await fixture.usage()
        #expect(usage.count == 1)
        let row = try #require(usage.first)
        #expect(row.model == "test-model")
        #expect(row.purpose == .titles)
        #expect(row.inputTokens == 11)
        #expect(row.outputTokens == 7)
        #expect(row.outcome == .ok)
        #expect(row.at == fixture.clock.now())
    }

    @Test("send: the backup role uses the backup slot")
    func sendBackup() async throws {
        let http = StubModelHTTP.completing()
        let fixture = try await ModelsFixture.make(http: http)
        defer { fixture.remove() }
        try await fixture.save(.primary, address: "https://primary.example.invalid/v1", key: "sk-primary-0123456789")
        try await fixture.save(.backup, address: "https://backup.example.invalid/v1", model: "backup-model", key: "sk-backup-0123456789")
        _ = try await fixture.models.send(texts: ["a"], instructions: "i", purpose: .body, role: .backup)
        #expect(http.received.map(\.url.host) == ["backup.example.invalid"])
        #expect(http.received.first?.authorization == key("sk-backup-0123456789"))
        #expect(try await fixture.usage().map(\.model) == ["backup-model"])
    }

    /// Decision 10's table, for `send`: each answer, its failure and its
    /// usage outcome.
    static let sendTable: [(String, StubModelHTTP, ModelFailure, UsageOutcome)] = [
        ("401", .answering(401, #"{"error":{"message":"bad key"}}"#), .keyRejected, .keyRejected),
        ("403", .answering(403), .keyRejected, .keyRejected),
        ("401 challenge", .failing(.declinedAuthentication(status: 401)), .keyRejected, .keyRejected),
        ("404 error body", .answering(404, #"{"error":{"message":"model not found"}}"#), .modelNotFound, .modelNotFound),
        ("400", .answering(400, #"{"error":{"message":"too long"}}"#), .badRequest, .badRequest),
        ("413", .answering(413), .badRequest, .badRequest),
        ("422", .answering(422), .badRequest, .badRequest),
        ("402", .answering(402), .limited, .limited),
        ("429", .answering(429), .limited, .limited),
        ("500", .answering(500), .serverError, .serverError),
        ("503", .answering(503), .serverError, .serverError),
        ("no answer", .failing(.unreachable), .unreachable, .unreachable),
        ("deadline", .failing(.timedOut), .unreachable, .unreachable),
        ("redirect", .failing(.redirected), .unreachable, .unreachable),
        ("407 challenge", .failing(.declinedAuthentication(status: 407)), .unreachable, .unreachable),
        ("404 page", .answering(404, "<html>Not Found</html>"), .unreachable, .unreachable),
        ("418", .answering(418), .unreachable, .unreachable),
        ("200 not a completion", .answering(200, #"{"data":[]}"#), .unreachable, .unreachable),
        ("too large", .failing(.tooLarge), .unreachable, .unreachable),
        ("refusal", .completing("ignored"), .refused, .refused),
        ("cut off", .completing(#"{"texts":["a"#, finishReason: "length"), .cutOff, .cutOff),
        ("malformed", .completing("Hallo"), .malformed, .malformed),
    ]

    @Test("criterion 6: each answer of decision 10 gives its send failure and usage outcome", arguments: 0..<22)
    func sendFailures(index: Int) async throws {
        let (name, http, failure, outcome) = Self.sendTable[index]
        let fixture = try await ModelsFixture.make(http: name == "refusal" ? StubModelHTTP { _ in
            ModelHTTPResponse(status: 200, headers: [:], body: completionBody(nil, refusal: "I won't."))
        } : http)
        defer { fixture.remove() }
        try await fixture.save()
        let error = await thrown { try await fixture.models.send(texts: ["a"], instructions: "i", purpose: .overview, role: .primary) }
        #expect(error as? ModelFailure == failure, "\(name)")
        #expect(try await fixture.usage().map(\.outcome) == [outcome], "\(name)")
        #expect(try await fixture.usage().map(\.purpose) == [.overview], "\(name)")
    }

    @Test("a cut-off reply that parses is returned with the flag, and its row is ok")
    func cutOffReply() async throws {
        let fixture = try await ModelsFixture.make(http: StubModelHTTP.completing(#"{"texts":["a"]}"#, finishReason: "length"))
        defer { fixture.remove() }
        try await fixture.save()
        let reply = try await fixture.models.send(texts: ["a"], instructions: "i", purpose: .body, role: .primary)
        #expect(reply.isCutOff)
        #expect(try await fixture.usage().map(\.outcome) == [.ok])
    }

    @Test("criterion 7: a library with no slot answers no model set up for both roles, without a request or a row")
    func noModelSetUp() async throws {
        let http = StubModelHTTP.completing()
        let empty = try await ModelsFixture.make(http: http)
        let other = try await ModelsFixture.make(http: http)
        defer {
            empty.remove()
            other.remove()
        }
        // A second library with a slot does not change that.
        try await other.save(.primary)
        try await other.save(.backup)
        for role in ModelRole.allCases {
            let error = await thrown { try await empty.models.send(texts: ["a"], instructions: "i", purpose: .titles, role: role) }
            #expect(error as? ModelFailure == .noModelSetUp)
        }
        #expect(http.received.isEmpty)
        #expect(try await empty.usage().isEmpty)
        #expect(try await empty.models.statuses().isEmpty)
        #expect(try await other.models.statuses().count == 2)
    }

    @Test("criterion 12: a slot without a reference, or whose item is missing, fails with key needed without a request")
    func keyNeeded() async throws {
        let http = StubModelHTTP.completing()
        let fixture = try await ModelsFixture.make(http: http)
        defer { fixture.remove() }
        try await fixture.save(key: nil)
        #expect(await thrown { try await fixture.models.send(texts: ["a"], instructions: "i", purpose: .titles, role: .primary) } as? ModelFailure == .keyNeeded)
        try await fixture.save(key: "sk-lost-key-0123456789")
        fixture.keys.lose(try #require(try await fixture.slot()?.keyRef))
        #expect(await thrown { try await fixture.models.send(texts: ["a"], instructions: "i", purpose: .titles, role: .primary) } as? ModelFailure == .keyNeeded)
        #expect(await thrown { try await fixture.models.test(draft()) } as? ModelFailure == .keyNeeded)
        #expect(await thrown { try await fixture.models.listModels(draft()) } as? ModelFailure == .keyNeeded)
        #expect(http.received.isEmpty)
        #expect(try await fixture.usage().isEmpty)
        try await fixture.models.removeSlot(.primary)
        #expect(try await fixture.slot() == nil)
    }

    @Test("a stored address this build refuses is never requested")
    func storedAddressRechecked() async throws {
        let http = StubModelHTTP.completing()
        let fixture = try await ModelsFixture.make(http: http)
        defer { fixture.remove() }
        try await fixture.save()
        try await fixture.library.pool.write { db in
            try db.execute(sql: "UPDATE model_slot SET base_url = 'http://api.example.invalid/v1'")
        }
        #expect(await thrown { try await fixture.models.send(texts: ["a"], instructions: "i", purpose: .titles, role: .primary) } as? ModelFailure == .unreachable)
        #expect(http.received.isEmpty)
        #expect(try await fixture.usage().isEmpty)
    }

    // MARK: - Cancellation (criterion 8)

    @Test("a cancelled request writes its cancelled row and throws a cancellation")
    func cancelledSend() async throws {
        let started = Signal()
        let http = StubModelHTTP { _ in
            started.fire()
            try await Task.sleep(for: .seconds(30))
            return ModelHTTPResponse(status: 200, headers: [:], body: completionBody(#"["a"]"#))
        }
        let fixture = try await ModelsFixture.make(http: http)
        defer { fixture.remove() }
        try await fixture.save()
        let models = fixture.models
        let task = Task { try await models.send(texts: ["a"], instructions: "i", purpose: .page, role: .primary) }
        await started.wait()
        task.cancel()
        let error = await thrown { try await task.value }
        #expect(error is CancellationError)
        let usage = try await fixture.usage()
        #expect(usage.map(\.outcome) == [.cancelled])
        #expect(usage.map(\.purpose) == [.page])
        #expect(usage.first?.inputTokens == nil)
    }

    @Test("a cancelled Test writes its row and keeps no result")
    func cancelledTest() async throws {
        let started = Signal()
        let http = StubModelHTTP { _ in
            started.fire()
            try await Task.sleep(for: .seconds(30))
            return ModelHTTPResponse(status: 200, headers: [:], body: completionBody(#"["a"]"#))
        }
        let fixture = try await ModelsFixture.make(http: http)
        defer { fixture.remove() }
        try await fixture.save()
        let models = fixture.models
        let draft = draft()
        let task = Task { try await models.test(draft) }
        await started.wait()
        task.cancel()
        #expect(await thrown { try await task.value } is CancellationError)
        #expect(try await fixture.usage().map(\.outcome) == [.cancelled])
        #expect(try await fixture.usage().map(\.purpose) == [.test])
        #expect(try await fixture.slot()?.testOutcome == nil)
    }

    @Test("a usage row that cannot be written does not fail the request")
    func usageWriteFails() async throws {
        let fixture = try await ModelsFixture.make(http: StubModelHTTP.completing())
        defer { fixture.remove() }
        try await fixture.save()
        try await fixture.library.pool.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_usage BEFORE INSERT ON usage BEGIN SELECT RAISE(FAIL, 'refused'); END")
        }
        let reply = try await fixture.models.send(texts: ["a"], instructions: "i", purpose: .titles, role: .primary)
        #expect(reply.texts == ["Hallo"])
        #expect(try await fixture.usage().isEmpty)
    }

    // MARK: - Test (decisions 9 and 10)

    /// Decision 10's Test column.
    static let testTable: [(String, StubModelHTTP, TestOutcome, UsageOutcome)] = [
        ("200 completion", .completing(), .passed, .ok),
        ("200 completion, content not judged", .completing("Hello"), .passed, .malformed),
        ("401", .answering(401), .keyRejected, .keyRejected),
        ("401 challenge", .failing(.declinedAuthentication(status: 401)), .keyRejected, .keyRejected),
        ("403", .answering(403), .keyRejected, .keyRejected),
        ("404 error body", .answering(404, #"{"error":{}}"#), .modelNotFound, .modelNotFound),
        ("400", .answering(400), .modelNotFound, .badRequest),
        ("422", .answering(422), .modelNotFound, .badRequest),
        ("402", .answering(402), .limited, .limited),
        ("429", .answering(429), .limited, .limited),
        ("503", .answering(503), .couldNotConnect, .serverError),
        ("redirect", .failing(.redirected), .couldNotConnect, .unreachable),
        ("404 page", .answering(404, "Not Found"), .couldNotConnect, .unreachable),
        ("no answer", .failing(.unreachable), .couldNotConnect, .unreachable),
        ("200 not a completion", .answering(200, "{}"), .couldNotConnect, .unreachable),
    ]

    @Test("criterion 6: each answer gives its Test line, and every Test writes a test row", arguments: 0..<15)
    func testLines(index: Int) async throws {
        let (name, http, line, outcome) = Self.testTable[index]
        let fixture = try await ModelsFixture.make(http: http)
        defer { fixture.remove() }
        #expect(try await fixture.models.test(draft(key: "sk-typed-key-0123456789")) == line, "\(name)")
        let usage = try await fixture.usage()
        #expect(usage.map(\.outcome) == [outcome], "\(name)")
        #expect(usage.map(\.purpose) == [.test], "\(name)")
        #expect(usage.map(\.model) == ["test-model"], "\(name)")
    }

    @Test("Test sends Hello with Repeat the text. to the form's address with the typed key, and saves nothing")
    func testRequest() async throws {
        let http = StubModelHTTP.completing()
        let fixture = try await ModelsFixture.make(http: http)
        defer { fixture.remove() }
        #expect(try await fixture.models.test(draft(address: "https://typed.example.invalid/v1/", key: "sk-typed-0123456789")) == .passed)
        let request = try #require(http.received.first)
        #expect(request.url.absoluteString == "https://typed.example.invalid/v1/chat/completions")
        #expect(request.authorization == key("sk-typed-0123456789"))
        #expect(request.body == ChatWire.chatBody(model: "test-model", instructions: "Repeat the text.", texts: ["Hello"]))
        #expect(try await fixture.slot() == nil)
        #expect(fixture.keys.references.isEmpty)
    }

    @Test("criterion 11: a Test of the saved values is kept at once; of other values it is not")
    func testOutcomeStored() async throws {
        let fixture = try await ModelsFixture.make(http: StubModelHTTP.answering(429))
        defer { fixture.remove() }
        try await fixture.save(model: "saved-model")
        // Another model in the form: not the saved values.
        #expect(try await fixture.models.test(draft(model: "other-model")) == .limited)
        #expect(try await fixture.slot()?.testOutcome == nil)
        // A typed key: not the saved key.
        #expect(try await fixture.models.test(draft(model: "saved-model", key: "sk-typed-0123456789")) == .limited)
        #expect(try await fixture.slot()?.testOutcome == nil)
        // The saved values.
        #expect(try await fixture.models.test(draft(model: "saved-model")) == .limited)
        #expect(try await fixture.slot()?.testOutcome == .limited)
        #expect(try await fixture.usage().count == 3)
    }

    // MARK: - Load List (criterion 9)

    @Test("Load List returns the identifiers sorted, and writes no usage row")
    func loadList() async throws {
        let http = StubModelHTTP.completing()
        let fixture = try await ModelsFixture.make(http: http)
        defer { fixture.remove() }
        #expect(try await fixture.models.listModels(draft(key: "sk-list-0123456789")) == ["m-1", "m-2"])
        let request = try #require(http.received.first)
        #expect(request.method == .get)
        #expect(request.url.absoluteString == "https://api.example.invalid/v1/models")
        #expect(try await fixture.usage().isEmpty)
    }

    @Test("a Load List failure is thrown with its line, and writes no usage row")
    func loadListFails() async throws {
        for (http, failure) in [(StubModelHTTP.answering(401), ModelFailure.keyRejected), (.answering(429), .limited), (.failing(.redirected), .unreachable), (.answering(200, "[]"), .unreachable)] {
            let fixture = try await ModelsFixture.make(http: http)
            defer { fixture.remove() }
            let error = await thrown { try await fixture.models.listModels(draft(key: "sk-list-0123456789")) }
            #expect(error as? ModelFailure == failure)
            #expect(try await fixture.usage().isEmpty)
        }
    }

    // MARK: - Criterion 13: a stored key never goes to another origin

    @Test("after the host changes, Test and Load List carry no stored key; the stored key goes only to its origin")
    func storedKeyStaysWithItsOrigin() async throws {
        let http = StubModelHTTP.completing()
        let fixture = try await ModelsFixture.make(http: http)
        defer { fixture.remove() }
        try await fixture.save(address: "https://api.openai.com/v1", key: "sk-openai-0123456789")
        for address in [ModelPreset.deepSeek.address, "https://api.openai.com:8443/v1", "https://openai.com/v1", "https://api.openai.com.evil.invalid/v1"] {
            #expect(await thrown { try await fixture.models.test(draft(address: address)) } as? ModelFailure == .keyNeeded, "\(address)")
            #expect(await thrown { try await fixture.models.listModels(draft(address: address)) } as? ModelFailure == .keyNeeded, "\(address)")
        }
        #expect(http.received.isEmpty)
        // A path change keeps the origin, and so the key.
        _ = try await fixture.models.listModels(draft(address: "https://api.openai.com/v2"))
        _ = try await fixture.models.test(draft(address: "https://API.OPENAI.COM/v1"))
        // A key typed for the new address goes there.
        _ = try await fixture.models.test(draft(address: ModelPreset.deepSeek.address, key: "sk-deepseek-0123456789"))
        let sent = http.received.map { (($0.url.host ?? "").lowercased(), $0.authorization) }
        #expect(sent.count == 3)
        #expect(sent[0] == ("api.openai.com", key("sk-openai-0123456789")))
        #expect(sent[1] == ("api.openai.com", key("sk-openai-0123456789")))
        #expect(sent[2] == ("api.deepseek.com", key("sk-deepseek-0123456789")))
    }

    // MARK: - Partitions (decision 12)

    @Test("a key store of another partition is refused")
    func otherPartitionRefused() async throws {
        // `precondition` cannot be caught in-process; the exit test runs it
        // in a child process.
        await #expect(processExitsWith: .failure) {
            let directory = try makeTemporaryDirectory()
            let library = try await LibraryStore(directory: directory, cacheRoot: directory).openNormal()
            _ = LibraryModels(library: library, keys: InMemoryKeyStore(partition: .adult), http: StubModelHTTP.answering(500))
        }
    }

    @Test("two libraries keep their own slots, keys and usage rows")
    func twoLibraries() async throws {
        let http = StubModelHTTP.completing()
        let first = try await ModelsFixture.make(http: http)
        let second = try await ModelsFixture.make(http: http)
        defer {
            first.remove()
            second.remove()
        }
        try await first.save(address: "https://first.example.invalid/v1", key: "sk-first-0123456789")
        try await second.save(address: "https://second.example.invalid/v1", key: "sk-second-0123456789")
        _ = try await second.models.send(texts: ["a"], instructions: "i", purpose: .titles, role: .primary)
        #expect(http.received.map(\.url.host) == ["second.example.invalid"])
        #expect(http.received.first?.authorization == key("sk-second-0123456789"))
        #expect(try await first.usage().isEmpty)
        #expect(try await second.usage().count == 1)
        #expect(first.keys.references.count == 1)
        #expect(second.keys.references.count == 1)
    }
}
