import Dispatch
import Foundation
@testable import NewsPawKit
import Testing

/// RD23 review round 4: the writer's two conditions — the app in front, and
/// for a job's first request its reading language still current — are
/// checked once more inside `LibraryModels.send`, after the slot and key
/// reads and with nothing awaited before the transport. The tests change
/// the state during the key read, through the fixture's hooked key store.
@Suite("Overview review round 4", .serialized)
struct OverviewReviewRoundFourTests {
    typealias Fixture = OverviewFixture

    private func automaticCount(_ fixture: Fixture) async throws -> Int {
        try await fixture.library.automaticRequestCount(since: OverviewDay.start(of: fixture.clock.now(), calendar: fixture.calendar))
    }

    @Test("the app leaves the front during the key read inside the send: no transport call, nothing counted or blocked, due again in front")
    func outOfFrontDuringTheKeyRead() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let (category, _, _) = try await fixture.filledCategory()
        let front = fixture.front
        fixture.keyReads.onNextRead { front.set(isInFront: false) }
        await fixture.runDue()
        #expect(fixture.service.requests.isEmpty, "no transport call")
        #expect(try await fixture.usage().isEmpty, "no usage row")
        #expect(try await automaticCount(fixture) == 0, "the daily limit is not charged")
        #expect(fixture.blocked.isEmpty)
        #expect(try await fixture.rows().isEmpty)

        front.set(isInFront: true)
        await fixture.runDue()
        #expect(try await fixture.rows(of: category).map(\.state) == ["done"])
        #expect(try await automaticCount(fixture) == 1)
    }

    @Test("a manual job whose app leaves the front during the key read answers cancelled; nothing sent or counted")
    func manualOutOfFrontDuringTheKeyRead() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let (category, _, _) = try await fixture.filledCategory(mode: .manual)
        let front = fixture.front
        fixture.keyReads.onNextRead { front.set(isInFront: false) }
        #expect(await fixture.write(category) == .cancelled)
        #expect(fixture.service.requests.isEmpty)
        #expect(try await fixture.usage().isEmpty)
        #expect(fixture.blocked.isEmpty)
    }

    @Test("the reading language changes during the key read of a job's first request: no transport call, nothing counted; the next run writes in the new language")
    func languageChangeDuringTheKeyRead() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let (category, _, _) = try await fixture.filledCategory()
        let writer = fixture.writer
        // The writer is suspended in the send, so `configure` runs on the
        // actor meanwhile; the read waits for it, as a slow key read would.
        fixture.keyReads.onNextRead {
            let done = DispatchSemaphore(value: 0)
            Task {
                await writer.configure(locale: .english)
                done.signal()
            }
            _ = done.wait(timeout: .now() + 60)
        }
        await fixture.runDue()
        #expect(fixture.service.requests.isEmpty, "no request in the old language")
        #expect(try await fixture.usage().isEmpty)
        #expect(try await automaticCount(fixture) == 0)
        #expect(try await fixture.rows().isEmpty)
        #expect(fixture.blocked.isEmpty)

        await fixture.runDue()
        #expect(try await fixture.rows(of: category).map(\.locale) == ["en"])
        #expect(fixture.overviewRequests.allSatisfy { $0.system.contains("English (en)") })
    }

    @Test("a request of another purpose is unchanged: the models' send without a condition sends as before")
    func otherPurposesUnchanged() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let front = fixture.front
        fixture.keyReads.onNextRead { front.set(isInFront: false) }
        _ = try await fixture.models.send(texts: ["Hello"], instructions: "Repeat.", purpose: .test, role: .primary)
        #expect(fixture.service.requests.count == 1)
    }
}
