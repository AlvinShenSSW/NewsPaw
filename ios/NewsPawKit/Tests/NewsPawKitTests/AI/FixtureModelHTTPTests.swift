import Foundation
@testable import NewsPawKit
import Testing

/// The UI tests' model fixture gives each Test line it is meant to give.
@Suite("Model fixture")
struct FixtureModelHTTPTests {
    @Test("each fixture host gives its Test line", arguments: [
        (FixtureModelHTTP.Address.passed, TestOutcome.passed),
        (FixtureModelHTTP.Address.rejected, .keyRejected),
        (FixtureModelHTTP.Address.noModel, .modelNotFound),
        (FixtureModelHTTP.Address.limited, .limited),
        (FixtureModelHTTP.Address.down, .couldNotConnect),
        (FixtureModelHTTP.Address.redirect, .couldNotConnect),
        ("https://other.example.invalid/v1", .couldNotConnect),
    ])
    func lines(address: String, line: TestOutcome) async throws {
        let fixture = try await ModelsFixture.make(http: FixtureModelHTTP())
        defer { fixture.remove() }
        let draft = ModelSlotDraft(role: .primary, preset: .custom, address: address, model: "m", newKey: key("sk-fixture-0123456789"))
        #expect(try await fixture.models.test(draft) == line)
    }

    @Test("the passed host lists three models and echoes the texts it was sent")
    func passed() async throws {
        let fixture = try await ModelsFixture.make(http: FixtureModelHTTP())
        defer { fixture.remove() }
        try await fixture.save(address: FixtureModelHTTP.Address.passed)
        let draft = ModelSlotDraft(role: .primary, preset: .custom, address: FixtureModelHTTP.Address.passed, model: "m", newKey: nil)
        #expect(try await fixture.models.listModels(draft) == FixtureModelHTTP.listedModels.sorted())
        let reply = try await fixture.models.send(texts: ["One", "Two"], instructions: "i", purpose: .titles, role: .primary)
        #expect(reply == ModelReply(texts: ["One", "Two"], isCutOff: false, inputTokens: 12, outputTokens: 5, model: "test-model"))
    }

    @Test("RD14: the translator marks each text with the language asked for and obeys its words; the backup ignores the 429 word")
    func translator() async throws {
        let fixture = try await ModelsFixture.make(http: FixtureModelHTTP())
        defer { fixture.remove() }
        try await fixture.save(address: FixtureModelHTTP.Address.translate)
        try await fixture.save(.backup, address: FixtureModelHTTP.Address.translateBackup)
        let before = FixtureModelHTTP.translationRequests
        let reply = try await fixture.models.send(
            texts: ["One", "<b>Two</b>"], instructions: TranslationPrompt.titles(into: .japanese), purpose: .titles, role: .primary
        )
        #expect(reply.texts == ["译[ja]：One", "译[ja]：<b>Two</b>"])
        let chinese = try await fixture.models.send(
            texts: ["One"], instructions: TranslationPrompt.titles(into: .simplifiedChinese), purpose: .titles, role: .primary
        )
        #expect(chinese.texts == ["译[zh-Hans]：One"])
        let instructions = TranslationPrompt.titles(into: .english)
        await #expect(throws: ModelFailure.refused) {
            try await fixture.models.send(texts: ["a fixture:refuse b"], instructions: instructions, purpose: .titles, role: .primary)
        }
        await #expect(throws: ModelFailure.limited) {
            try await fixture.models.send(texts: ["a fixture:limit b"], instructions: instructions, purpose: .titles, role: .primary)
        }
        let backup = try await fixture.models.send(texts: ["a fixture:limit b"], instructions: instructions, purpose: .titles, role: .backup)
        #expect(backup.texts == ["译[en]：a fixture:limit b"])
        let start = ContinuousClock.now
        _ = try await fixture.models.send(texts: ["fixture:slow"], instructions: instructions, purpose: .titles, role: .primary)
        #expect(ContinuousClock.now - start >= .seconds(2))
        #expect(FixtureModelHTTP.translationRequests - before >= 6)
    }

    @Test("RD15: stall-once stalls its first request until cancelled and answers later ones; fail-once answers 503 once; refuse-primary refuses on the primary only")
    func bodyWords() async throws {
        let fixture = try await ModelsFixture.make(http: FixtureModelHTTP())
        defer { fixture.remove() }
        try await fixture.save(address: FixtureModelHTTP.Address.translate)
        try await fixture.save(.backup, address: FixtureModelHTTP.Address.translateBackup)
        let instructions = TranslationPrompt.body(into: .simplifiedChinese)
        let models = fixture.models
        let before = FixtureModelHTTP.translationRequests
        let stalled = Task {
            try await models.send(texts: ["a fixture:stall-once b"], instructions: instructions, purpose: .body, role: .primary)
        }
        let deadline = ContinuousClock.now + .seconds(60)
        while FixtureModelHTTP.translationRequests == before, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        stalled.cancel()
        await #expect(throws: CancellationError.self) { try await stalled.value }
        let start = ContinuousClock.now
        let again = try await models.send(texts: ["a fixture:stall-once b"], instructions: instructions, purpose: .body, role: .primary)
        #expect(again.texts == ["译[zh-Hans]：a fixture:stall-once b"])
        #expect(ContinuousClock.now - start < .seconds(30))

        await #expect(throws: ModelFailure.serverError) {
            try await models.send(texts: ["a fixture:fail-once b"], instructions: instructions, purpose: .body, role: .primary)
        }
        let later = try await models.send(texts: ["a fixture:fail-once b"], instructions: instructions, purpose: .body, role: .primary)
        #expect(later.texts == ["译[zh-Hans]：a fixture:fail-once b"])

        await #expect(throws: ModelFailure.refused) {
            try await models.send(texts: ["a fixture:refuse-primary b"], instructions: instructions, purpose: .body, role: .primary)
        }
        let backup = try await models.send(texts: ["a fixture:refuse-primary b"], instructions: instructions, purpose: .body, role: .backup)
        #expect(backup.texts == ["译[zh-Hans]：a fixture:refuse-primary b"])
    }
}
