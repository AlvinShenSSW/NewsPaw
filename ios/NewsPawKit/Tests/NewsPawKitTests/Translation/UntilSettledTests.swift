import Foundation
@testable import NewsPawKit
import Testing

/// RD24 approach 6: `TitleTranslator.untilSettled()`, the polling form of
/// `settled()` a background run waits with.
@Suite("Until settled", .serialized, .timeLimit(.minutes(5)))
struct UntilSettledTests {
    /// A translator whose first request is held in flight.
    private func busy() async throws -> TranslatorFixture {
        let fixture = try await TranslatorFixture.make()
        let source = try await fixture.source()
        try await fixture.article("Story 01 about the harbour", in: source)
        fixture.service.hold(request: 1)
        await fixture.translator.configure(TranslationConfiguration(locale: .simplifiedChinese, automatic: true))
        await fixture.eventually { fixture.service.requests.count == 1 }
        return fixture
    }

    @Test("returns at once when the translator is idle, and when it was never configured")
    func idle() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        await fixture.translator.untilSettled()
        await fixture.start()
        await fixture.translator.untilSettled()
    }

    @Test("waits for a held request, and returns once it is released and stored")
    func afterRelease() async throws {
        let fixture = try await busy()
        defer { fixture.remove() }
        let ended = Flag()
        let wait = Task {
            await fixture.translator.untilSettled()
            ended.set()
        }
        try await Task.sleep(for: .milliseconds(400))
        #expect(!ended.isSet)
        fixture.service.release(request: 1)
        await wait.value
        #expect(try await fixture.translationCount() == 1)
    }

    @Test("returns when the translator is stopped")
    func whenStopped() async throws {
        let fixture = try await busy()
        defer { fixture.remove() }
        let wait = Task { await fixture.translator.untilSettled() }
        await fixture.translator.stop()
        await wait.value
        #expect(try await fixture.translationCount() == 0)
    }

    @Test("returns when its task is cancelled, with the translator still working")
    func whenCancelled() async throws {
        let fixture = try await busy()
        defer { fixture.remove() }
        let wait = Task { await fixture.translator.untilSettled() }
        wait.cancel()
        await wait.value
        // Still working: the request is in flight, nothing stored.
        #expect(try await fixture.translationCount() == 0)
        #expect(fixture.service.requests.count == 1)
        fixture.service.release(request: 1)
        await fixture.translator.settled()
        #expect(try await fixture.translationCount() == 1)
    }
}
