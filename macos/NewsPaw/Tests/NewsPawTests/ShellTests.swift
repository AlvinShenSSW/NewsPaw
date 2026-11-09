import Foundation
import Testing

@testable import NewsPaw

@MainActor
private func client(replying reply: String, sent: (@Sendable (Data, Int?) -> Void)? = nil) -> BackendClient {
    BackendClient { body, timeout in
        sent?(body, timeout)
        return Data(reply.utf8)
    }
}

@Test @MainActor func structuredFailuresKeepCodeDomainFieldAndRetryability() async throws {
    let reply = #"{"ok":false,"error":"invalid_request","error_detail":{"code":"invalid_request","domain":"models","retryable":false,"field":"capability"}}"#
    await #expect(throws: BackendError(code: "invalid_request", domain: "models", field: "capability", retryable: false)) {
        _ = try await client(replying: reply).call(.configGet)
    }
    let older = #"{"ok":false,"error":"rate_limited"}"#
    await #expect(throws: BackendError(code: "rate_limited")) {
        _ = try await client(replying: older).call(.configGet)
    }
    await #expect(throws: BackendFailure.invalidReply) {
        _ = try await client(replying: #"{"ok":1,"result":{}}"#).call(.configGet)
    }
    await #expect(throws: BackendFailure.invalidReply) {
        _ = try await client(replying: #"{"ok":tru"#).call(.configGet)
    }
}

@Test @MainActor func operationTimeoutsAreSetInOnePlace() async throws {
    let seen = Box<[Int?]>([])
    let probe = client(replying: #"{"ok":true,"result":{}}"#) { _, timeout in seen.value.append(timeout) }
    _ = try await probe.send("models.probe", [:])
    _ = try await probe.call(.configGet)
    _ = try await probe.send("x.video.inspect", [:])
    // Long operations answer within ~2 s (R05), so they use the socket default.
    #expect(seen.value == [35_000, nil, nil])
}

@Test @MainActor func aPendingLongOperationIsFollowedToItsResult() async throws {
    let sent = Box<[[String: Any]]>([])
    let replies = Box<[String]>([
        #"{"ok":true,"result":{"pending":true,"request":"req_1"}}"#,
        #"{"ok":true,"result":{"pending":true,"request":"req_1"}}"#,
        #"{"ok":true,"result":{"attempt":{"status":"fresh"}}}"#,
    ])
    var backend = BackendClient { body, _ in
        sent.value.append(try JSONSerialization.jsonObject(with: body) as! [String: Any])
        return Data(replies.value.removeFirst().utf8)
    }
    backend.pollInterval = .milliseconds(1)
    let result = try JSONSerialization.jsonObject(with: await backend.send("sources.preview", ["source_id": "s"])) as? [String: Any]
    #expect((result?["attempt"] as? [String: Any])?["status"] as? String == "fresh")
    #expect(sent.value.map { $0["op"] as? String } == ["sources.preview", "requests.status", "requests.status"])
    #expect(sent.value.last?["request"] as? String == "req_1")
}

@Test @MainActor func aPendingLongOperationThatFailsThrowsItsOwnError() async throws {
    let replies = Box<[String]>([
        #"{"ok":true,"result":{"pending":true,"request":"req_2"}}"#,
        #"{"ok":false,"error":"timeout","error_detail":{"code":"timeout","domain":"bots","retryable":true}}"#,
    ])
    var backend = BackendClient { _, _ in Data(replies.value.removeFirst().utf8) }
    backend.pollInterval = .milliseconds(1)
    await #expect(throws: BackendError(code: "timeout", domain: "bots", retryable: true)) {
        _ = try await backend.send("bots.verify", ["bot_id": "b"])
    }
}

@Test @MainActor func aResultThatLooksPendingIsNotFollowedForOrdinaryOperations() async throws {
    let calls = Box<Int>(0)
    let backend = BackendClient { _, _ in
        calls.value += 1
        return Data(#"{"ok":true,"result":{"pending":true,"request":"x"}}"#.utf8)
    }
    _ = try await backend.call(.configGet)
    #expect(calls.value == 1)
}

@Test @MainActor func statusAndReadinessDecodeFromTheBackendShape() async throws {
    let status = try await client(replying: #"{"ok":true,"result":{"protocol_version":1,"state":"running","operations":["setup.readiness"]}}"#).status()
    #expect(status.operations == ["setup.readiness"])
    let older = try await client(replying: #"{"ok":true,"result":{"protocol_version":1,"state":"running"}}"#).status()
    #expect(older.operations == nil)
    let readiness = try await client(replying: #"""
        {"ok":true,"result":{"complete":false,"next":"model","scheduling_enabled":true,"steps":[
         {"step":"bot","state":"done","blocker_code":null,"entity_id":"bot1","fix_op":null},
         {"step":"model","state":"pending","blocker_code":"model_unverified","entity_id":"normal_primary","fix_op":"models.probe"}]}}
        """#).readiness()
    #expect(readiness.next == "model" && readiness.schedulingEnabled)
    #expect(readiness.steps.map(\.done) == [true, false])
    #expect(readiness.steps[1].blockerCode == "model_unverified")
}

@Test @MainActor func editorMergesOneBackgroundRevisionChange() async {
    var revision = 4
    var stored: [String: Any] = ["max_items": 5, "name": "World"]
    var loads = 0
    let editor = EditorState(
        load: {
            loads += 1
            return (revision, stored)
        },
        store: { document, expected in
            if loads == 1 {
                // A Telegram command renamed the digest between our read and our write.
                revision = 5
                stored["name"] = "World (renamed)"
                throw BackendError(code: "config_conflict", domain: "config")
            }
            #expect(expected == 5)
            stored = document
        },
        clock: { Date(timeIntervalSince1970: 1) }
    )
    let saved = await editor.apply { var d = $0; d["max_items"] = 8; return d }
    #expect(saved && editor.failure == nil && loads == 2)
    #expect(stored["max_items"] as? Int == 8 && stored["name"] as? String == "World (renamed)")
    #expect(editor.savedAt == Date(timeIntervalSince1970: 1))
}

@Test @MainActor func editorReportsARepeatedConflictAndDoesNotRetryOtherFailures() async {
    var loads = 0
    let conflicted = EditorState(
        load: { loads += 1; return (1, [:]) },
        store: { _, _ in throw BackendError(code: "config_conflict") }
    )
    #expect(!(await conflicted.apply { $0 }))
    #expect(conflicted.failure?.code == "config_conflict" && loads == 2)

    loads = 0
    let rejected = EditorState(
        load: { loads += 1; return (1, [:]) },
        store: { _, _ in throw BackendError(code: "invalid_token", domain: "bots") }
    )
    #expect(!(await rejected.apply { $0 }))
    #expect(rejected.failure?.code == "invalid_token" && loads == 1)

    let offline = EditorState(load: { throw SocketFailure.disconnected }, store: { _, _ in })
    #expect(!(await offline.apply { $0 }))
    #expect(offline.failure?.code == "backend_unreachable")
}

@Test func everyWordHasAllThreeLanguages() {
    let groups = L10n.Shell.all + L10n.Page.all + L10n.Setup.all
        + FailureCopy.table.values.flatMap { [$0.message] + ($0.action.map { [$0] } ?? []) }
        + [FailureCopy.conflict.message, FailureCopy.fallback]
    for words in groups {
        for language in AppLanguage.allCases {
            #expect(!words(language).trimmingCharacters(in: .whitespaces).isEmpty)
        }
        #expect(words.zh != words.en)
    }
}

@Test func failureCopyNamesWhatHappenedAndWhatToDo() {
    let unknown = BackendError(code: "something_new", domain: "bots", retryable: true)
    #expect(FailureCopy.message(for: unknown, .en).contains("something_new"))
    #expect(FailureCopy.entry(for: unknown).action == L10n.Shell.retry)
    #expect(FailureCopy.entry(for: BackendError(code: "schedule_policy_changed")).message == FailureCopy.conflict.message)
    #expect(FailureCopy.message(for: BackendError(code: "invalid_token"), .zhHans).contains("@BotFather"))
    for language in AppLanguage.allCases {
        #expect(!language.text(.saveFailed).contains("语言"))
    }
}

@Test @MainActor func legacyViewsShowTheActualFailureInsteadOfAGenericSentence() async throws {
    let fixture = try FixtureSocket()
    let running = #"{"ok":true,"result":{"protocol_version":1,"state":"running"}}"# + "\n"
    let configuration = #"{"ok":true,"result":{"revision":1,"document":{"ui_locale":"en","news_output_locale":"en","categories":[],"subscriptions":[],"sources":[],"accounts":[],"model_profiles":[]}}}"# + "\n"
    let bots = #"{"ok":true,"result":[]}"# + "\n"
    let rejected = #"{"ok":false,"error":"invalid_token","error_detail":{"code":"invalid_token","domain":"bots","retryable":false}}"# + "\n"
    let conflict = #"{"ok":false,"error":"config_conflict","error_detail":{"code":"config_conflict","domain":"config","retryable":false}}"# + "\n"
    let replies = fixture.serve([running, configuration, bots, rejected, conflict])
    let name = "NewsPawTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let model = AppModel(socket: LocalSocket(path: fixture.path), defaults: defaults)
    await model.refresh()
    await #expect(throws: BackendError.self) { _ = try await model.request("bots.verify", fields: ["bot_id": "b"]) }
    #expect(model.text(.saveFailed) == FailureCopy.message(for: BackendError(code: "invalid_token"), .en))
    await #expect(throws: BackendFailure.conflict) { _ = try await model.request("config.save", fields: [:]) }
    #expect(try await replies.value.count == 5)
}

private final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

@Test @MainActor func aFailedPauseIsReportedWithItsCode() async throws {
    let fixture = try FixtureSocket()
    let running = #"{"ok":true,"result":{"protocol_version":1,"state":"running","operations":["setup.readiness"]}}"# + "\n"
    let ready = #"{"ok":true,"result":{"complete":false,"next":"bot","scheduling_enabled":true,"steps":[]}}"# + "\n"
    let configuration = #"{"ok":true,"result":{"revision":1,"document":{"ui_locale":"en","news_output_locale":"en","categories":[],"subscriptions":[],"sources":[],"accounts":[],"model_profiles":[]}}}"# + "\n"
    let bots = #"{"ok":true,"result":[]}"# + "\n"
    let policy = #"{"ok":true,"result":{"revision":3,"settings":{"enabled":true},"activated_at":null,"occurrences":[]}}"# + "\n"
    let refused = #"{"ok":false,"error":"invalid_schedule_policy","error_detail":{"code":"invalid_schedule_policy","domain":"schedule","retryable":false}}"# + "\n"
    let replies = fixture.serve([running, ready, configuration, bots, policy, refused, running, ready, configuration, bots])
    let name = "NewsPawTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let model = AppModel(socket: LocalSocket(path: fixture.path), defaults: defaults)
    await model.refresh()
    #expect(!model.schedulingPaused)
    await model.setPaused(true)
    #expect(model.error == .saveFailed && model.lastFailure?.code == "invalid_schedule_policy")
    #expect(model.text(.saveFailed).contains("invalid_schedule_policy"))
    #expect(try await replies.value.count == 10)
}

@Test @MainActor func recordsRejectNonIntegerRevisions() {
    #expect(throws: BackendFailure.invalidReply) {
        _ = try BackendClient.record(Data(#"{"revision":1.5,"document":{}}"#.utf8), field: "document")
    }
    #expect((try? BackendClient.record(Data(#"{"revision":2,"document":{}}"#.utf8), field: "document"))?.revision == 2)
}

@Test @MainActor func aLostBackendIsNamedInLegacyViewsAndAShellRetryIsOffered() async throws {
    let fixture = try FixtureSocket()
    let running = #"{"ok":true,"result":{"protocol_version":1,"state":"running","operations":["setup.readiness"]}}"# + "\n"
    let ready = #"{"ok":true,"result":{"complete":false,"next":"bot","scheduling_enabled":true,"steps":[]}}"# + "\n"
    let configuration = #"{"ok":true,"result":{"revision":1,"document":{"ui_locale":"en","news_output_locale":"en","categories":[],"subscriptions":[],"sources":[],"accounts":[],"model_profiles":[]}}}"# + "\n"
    let bots = #"{"ok":true,"result":[]}"# + "\n"
    let policy = #"{"ok":true,"result":{"revision":3,"settings":{"enabled":true},"activated_at":null,"occurrences":[]}}"# + "\n"
    let refused = #"{"ok":false,"error":"rate_limited","error_detail":{"code":"rate_limited","domain":"schedule","retryable":true}}"# + "\n"
    let replies = fixture.serve([running, ready, configuration, bots, policy, refused, running, ready, configuration, bots])
    let name = "NewsPawTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let model = AppModel(socket: LocalSocket(path: fixture.path), defaults: defaults)
    await model.refresh()
    await model.setPaused(true)
    #expect(model.retryLast != nil)
    #expect(FailureCopy.entry(for: try #require(model.lastFailure)).action != nil)
    #expect(try await replies.value.count == 10)
    // The fixture has stopped answering: a legacy request now names the lost backend.
    await #expect(throws: SocketFailure.self) { _ = try await model.request("sources.list", fields: [:]) }
    #expect(model.lastFailure?.code == "backend_unreachable")
    #expect(model.text(.saveFailed) == FailureCopy.message(for: BackendError(code: "backend_unreachable"), .en))
}

@Test @MainActor func aSuccessfulLegacyRequestKeepsTheShellFailureAndItsRetry() async throws {
    let fixture = try FixtureSocket()
    let running = #"{"ok":true,"result":{"protocol_version":1,"state":"running","operations":["setup.readiness"]}}"# + "\n"
    let ready = #"{"ok":true,"result":{"complete":false,"next":"bot","scheduling_enabled":true,"steps":[]}}"# + "\n"
    let configuration = #"{"ok":true,"result":{"revision":1,"document":{"ui_locale":"en","news_output_locale":"en","categories":[],"subscriptions":[],"sources":[],"accounts":[],"model_profiles":[]}}}"# + "\n"
    let bots = #"{"ok":true,"result":[]}"# + "\n"
    let policy = #"{"ok":true,"result":{"revision":3,"settings":{"enabled":true},"activated_at":null,"occurrences":[]}}"# + "\n"
    let refused = #"{"ok":false,"error":"rate_limited","error_detail":{"code":"rate_limited","domain":"schedule","retryable":true}}"# + "\n"
    let replies = fixture.serve([running, ready, configuration, bots, policy, refused, running, ready, configuration, bots, bots])
    let name = "NewsPawTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let model = AppModel(socket: LocalSocket(path: fixture.path), defaults: defaults)
    await model.refresh()
    await model.setPaused(true)
    _ = try await model.request("bots.list", fields: [:])
    #expect(model.error == .saveFailed && model.lastFailure?.code == "rate_limited" && model.retryLast != nil)
    #expect(model.text(.saveFailed) == FailureCopy.message(for: BackendError(code: "rate_limited", domain: "schedule"), .en))
    #expect(try await replies.value.count == 11)
}

@Test @MainActor func aViewFailureAfterASuccessfulRequestNamesItselfNotTheShellFailure() async throws {
    struct LocalCheck: Error {}
    let fixture = try FixtureSocket()
    let running = #"{"ok":true,"result":{"protocol_version":1,"state":"running","operations":["setup.readiness"]}}"# + "\n"
    let ready = #"{"ok":true,"result":{"complete":false,"next":"bot","scheduling_enabled":true,"steps":[]}}"# + "\n"
    let configuration = #"{"ok":true,"result":{"revision":1,"document":{"ui_locale":"en","news_output_locale":"en","categories":[],"subscriptions":[],"sources":[],"accounts":[],"model_profiles":[]}}}"# + "\n"
    let bots = #"{"ok":true,"result":[]}"# + "\n"
    let policy = #"{"ok":true,"result":{"revision":3,"settings":{"enabled":true},"activated_at":null,"occurrences":[]}}"# + "\n"
    let refused = #"{"ok":false,"error":"rate_limited","error_detail":{"code":"rate_limited","domain":"schedule","retryable":true}}"# + "\n"
    let malformed = #"{"ok":true,"result":{"unexpected":true}}"# + "\n"
    let replies = fixture.serve([running, ready, configuration, bots, policy, refused, running, ready, configuration, bots, malformed])
    let name = "NewsPawTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let model = AppModel(socket: LocalSocket(path: fixture.path), defaults: defaults)
    await model.refresh()
    await model.setPaused(true)
    #expect(model.retryLast != nil)
    // A result the view cannot decode (the bots.status path in BotWorkspace).
    let reply = try await model.request("bots.status", fields: ["bot_id": "b"])
    #expect(throws: BackendFailure.invalidReply) { let _: BotStatus = try model.decodeReply(reply) }
    #expect(model.lastFailure?.code == "invalid_reply" && model.retryLast == nil)
    #expect(model.viewFailed(BackendFailure.invalidReply) == .saveFailed)
    #expect(model.text(.saveFailed) == FailureCopy.message(for: BackendError(code: "invalid_reply"), .en))
    // A view's own check (no backend code) gets the generic sentence, not an older failure.
    _ = model.viewFailed(LocalCheck())
    #expect(model.lastFailure == nil && model.text(.saveFailed) == AppLanguage.en.text(.saveFailed))
    _ = model.viewFailed(BackendError(code: "invalid_token", domain: "bots"))
    #expect(model.text(.saveFailed) == FailureCopy.message(for: BackendError(code: "invalid_token", domain: "bots"), .en))
    #expect(try await replies.value.count == 11)
}

@Test @MainActor func aLegacyRequestWhileDisconnectedDropsTheShellRetry() async throws {
    let fixture = try FixtureSocket()
    let running = #"{"ok":true,"result":{"protocol_version":1,"state":"running","operations":["setup.readiness"]}}"# + "\n"
    let ready = #"{"ok":true,"result":{"complete":false,"next":"bot","scheduling_enabled":true,"steps":[]}}"# + "\n"
    let configuration = #"{"ok":true,"result":{"revision":1,"document":{"ui_locale":"en","news_output_locale":"en","categories":[],"subscriptions":[],"sources":[],"accounts":[],"model_profiles":[]}}}"# + "\n"
    let bots = #"{"ok":true,"result":[]}"# + "\n"
    let policy = #"{"ok":true,"result":{"revision":3,"settings":{"enabled":true},"activated_at":null,"occurrences":[]}}"# + "\n"
    let refused = #"{"ok":false,"error":"rate_limited","error_detail":{"code":"rate_limited","domain":"schedule","retryable":true}}"# + "\n"
    let replies = fixture.serve([running, ready, configuration, bots, policy, refused, running, ready, configuration, bots])
    let name = "NewsPawTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let model = AppModel(socket: LocalSocket(path: fixture.path), defaults: defaults)
    await model.refresh()
    await model.setPaused(true)
    #expect(model.retryLast != nil)
    #expect(try await replies.value.count == 10)
    await model.refresh()
    #expect(model.connection != .connected)
    await #expect(throws: SocketFailure.self) { _ = try await model.request("subscriptions.save", fields: [:]) }
    #expect(model.retryLast == nil && model.lastFailure?.code == "backend_unreachable")
}

@Test @MainActor func aLaterViewFailureDropsTheShellRetryAndNamesABadReply() async throws {
    let fixture = try FixtureSocket()
    let running = #"{"ok":true,"result":{"protocol_version":1,"state":"running","operations":["setup.readiness"]}}"# + "\n"
    let ready = #"{"ok":true,"result":{"complete":false,"next":"bot","scheduling_enabled":true,"steps":[]}}"# + "\n"
    let configuration = #"{"ok":true,"result":{"revision":1,"document":{"ui_locale":"en","news_output_locale":"en","categories":[],"subscriptions":[],"sources":[],"accounts":[],"model_profiles":[]}}}"# + "\n"
    let bots = #"{"ok":true,"result":[]}"# + "\n"
    let policy = #"{"ok":true,"result":{"revision":3,"settings":{"enabled":true},"activated_at":null,"occurrences":[]}}"# + "\n"
    let refused = #"{"ok":false,"error":"rate_limited","error_detail":{"code":"rate_limited","domain":"schedule","retryable":true}}"# + "\n"
    let limited = #"{"ok":false,"error":"rate_limited","error_detail":{"code":"rate_limited","domain":"bots","retryable":true}}"# + "\n"
    let garbled = #"{"ok":"yes"}"# + "\n"
    let truncated = #"{"ok":tru"# + "\n"
    let replies = fixture.serve([running, ready, configuration, bots, policy, refused, running, ready, configuration, bots, limited, garbled, truncated])
    let name = "NewsPawTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let model = AppModel(socket: LocalSocket(path: fixture.path), defaults: defaults)
    await model.refresh()
    await model.setPaused(true)
    #expect(model.retryLast != nil)
    await #expect(throws: BackendError.self) { _ = try await model.request("bots.list", fields: [:]) }
    #expect(model.lastFailure?.domain == "bots" && model.retryLast == nil)
    await #expect(throws: BackendFailure.invalidReply) { _ = try await model.request("bots.list", fields: [:]) }
    #expect(model.lastFailure?.code == "invalid_reply")
    #expect(model.text(.saveFailed) == FailureCopy.message(for: BackendError(code: "invalid_reply"), .en))
    await #expect(throws: BackendFailure.invalidReply) { _ = try await model.request("bots.list", fields: [:]) }
    #expect(model.lastFailure?.code == "invalid_reply")
    #expect(try await replies.value.count == 13)
}


@Test @MainActor func configChangesDecodeFieldsAndItems() async throws {
    let reply = #"{"ok":true,"result":{"revision":7,"changes":[{"field":"ui_locale"},{"collection":"subscriptions","id":"sub_world","fields":["times"]},{"collection":"sources","id":"s1","added":true}]}}"#
    let changes = try await client(replying: reply).changes(since: 5)
    #expect(changes.revision == 7 && changes.changes.count == 3)
    #expect(changes.changes[1].fields == ["times"] && changes.changes[2].added == true)
}
