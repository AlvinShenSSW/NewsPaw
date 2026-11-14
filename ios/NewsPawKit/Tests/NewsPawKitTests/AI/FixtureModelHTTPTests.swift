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
        #expect(reply == ModelReply(texts: ["One", "Two"], isCutOff: false, inputTokens: 12, outputTokens: 5))
    }
}
