import Foundation
@testable import NewsPawKit
import Testing

/// RD16 review round 3: the owner's actions are serialised (N3), and the
/// cells of the session's sweep that sent twice or showed a state that is
/// not true. Each test holds its interleaving with held checks, collects or
/// requests; the short sleeps only give a wrong implementation the chance
/// to do what it must not.
@Suite("Page translation session, review round 3", .serialized)
@MainActor
struct PageTranslationSessionRound3Tests {
    typealias Harness = PageTranslationSessionTests.Harness
    typealias Review = PageTranslationSessionReviewTests
    static let address = URL(string: "https://pages.example.invalid/ja-list")!

    // MARK: - N3: the owner's actions are serialised

    @Test("N3: Retry tapped again while its check is outstanding sends the failed runs once")
    func retryTwice() async throws {
        let service = TranslationService(Review.refusing)
        let fixture = try await TranslatorFixture.make(service: service)
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.page.collection = { .success(.runs(Review.refusedRuns(3), loaded: true)) }
        await harness.turnOn()
        await Review.waitForFailedLine(harness)
        service.answer { _, _, _ in .texts(TranslationService.marked) }
        let before = service.requests.count
        harness.page.holdsChecks = true
        harness.session.retry()
        await harness.eventually { harness.page.heldCheckCount == 1 }
        harness.session.retry()
        try await Task.sleep(for: .milliseconds(100))
        harness.page.releaseChecks()
        await harness.eventually { Set(harness.page.written.map(\.id)) == [1, 2, 3] }
        try await Task.sleep(for: .milliseconds(200))
        #expect(service.requests.count == before + 1, "\(service.requests.count - before) requests for one Retry")
        #expect(harness.page.written.count == 3)
    }

    @Test("N3: Retry with the Backup Model tapped while Retry's check is outstanding sends nothing to the backup")
    func retryThenBackup() async throws {
        let service = TranslationService { host, texts, _ in
            host == TranslatorFixture.primaryHost && texts.contains { $0.contains("fixture:refuse") } ? .refusal : .texts(TranslationService.marked)
        }
        let fixture = try await TranslatorFixture.make(service: service, backup: true)
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.page.collection = { .success(.runs(Review.refusedRuns(3), loaded: true)) }
        await harness.turnOn()
        await Review.waitForFailedLine(harness)
        service.answer { _, _, _ in .texts(TranslationService.marked) }
        let before = service.requests.count
        harness.page.holdsChecks = true
        harness.session.retry()
        await harness.eventually { harness.page.heldCheckCount == 1 }
        harness.session.retryWithBackup()
        try await Task.sleep(for: .milliseconds(100))
        harness.page.releaseChecks()
        await harness.eventually { Set(harness.page.written.map(\.id)) == [1, 2, 3] }
        try await Task.sleep(for: .milliseconds(200))
        #expect(service.requests(to: TranslatorFixture.backupHost).isEmpty)
        #expect(service.requests.count == before + 1)
    }

    @Test("N3: while Retry's check is outstanding the session is acting and every other action is refused; afterwards they work")
    func actionsRefusedWhileActing() async throws {
        let service = TranslationService(Review.refusing)
        let fixture = try await TranslatorFixture.make(service: service, backup: true)
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.page.collection = { .success(.runs(Review.refusedRuns(3), loaded: true)) }
        #expect(!harness.session.isActing)
        await harness.turnOn()
        await harness.eventually { !harness.session.isActing }
        await Review.waitForFailedLine(harness)
        harness.page.holdsChecks = true
        harness.session.retry()
        await harness.eventually { harness.page.heldCheckCount == 1 }
        #expect(harness.session.isActing)
        let ends = harness.page.ends.count
        harness.session.showOriginal()
        harness.session.toggle()
        harness.session.continueTranslating()
        harness.session.retryWithBackup()
        harness.session.retry()
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.session.isOn, "Show Original and the Translate button were refused")
        #expect(harness.page.ends.count == ends)
        #expect(harness.page.heldCheckCount == 1, "no second check")
        harness.page.releaseChecks()
        await harness.eventually { !harness.session.isActing }
        harness.session.showOriginal()
        await harness.eventually { !harness.session.isOn && harness.page.ends.count == ends + 1 }
        await harness.eventually { !harness.session.isActing }
        harness.session.turnOn()
        #expect(harness.session.isActing)
        harness.session.toggle()
        await harness.eventually { harness.session.isOn && !harness.session.isActing }
        #expect(harness.page.ends.count == ends + 1, "the second tap while turning on was refused")
    }

    // MARK: - The sweep

    @Test("sweep: a collect that fails across a time in the background does not say the page did not respond; the next step asks again")
    func callAcrossBackground() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.page.collection = { .failure(.timedOut) }
        harness.page.holdsCollects = true
        await harness.turnOn()
        await harness.eventually { harness.page.heldCollectCount == 1 }
        // The app goes to the background and comes back while the collect
        // is outstanding; then it expires.
        harness.seen = false
        try await Task.sleep(for: .milliseconds(50))
        harness.seen = true
        harness.session.becameSeen()
        // The held collect answers with the failure it was given; the next
        // ones find the page's runs.
        harness.page.collection = { .success(.runs(PageTranslationSessionTests.runs(PageTranslationSessionTests.japanese), loaded: true)) }
        harness.page.releaseCollects()
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.session.line != .didNotRespond)
        await harness.eventually { harness.page.confirmed == [1, 2, 3] }
        await harness.eventually { harness.session.line == .translated(.simplifiedChinese) }
    }

    @Test("sweep: a collect that fails while the session was seen throughout still says the page did not respond")
    func callFailsWhileSeen() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.page.collection = { .failure(.timedOut) }
        await harness.turnOn()
        await harness.eventually { harness.session.line == .didNotRespond }
    }

    @Test("sweep: Retry with the Backup Model once the backup slot is gone sends nothing, and the line stops offering it")
    func backupGone() async throws {
        let service = TranslationService { host, texts, _ in
            host == TranslatorFixture.primaryHost && texts.contains { $0.contains("fixture:refuse") } ? .refusal : .texts(TranslationService.marked)
        }
        let fixture = try await TranslatorFixture.make(service: service, backup: true)
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.page.collection = { .success(.runs(Review.refusedRuns(1), loaded: true)) }
        await harness.turnOn()
        await harness.eventually { harness.session.line == .failed(.content(.refused), offersBackup: true) && harness.session.unitsInFlight == 0 }
        try await fixture.models.removeSlot(.backup)
        let before = service.requests.count
        harness.session.retryWithBackup()
        await harness.eventually { harness.session.line == .failed(.content(.refused), offersBackup: false) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(service.requests.count == before)
        #expect(harness.session.line == .failed(.content(.refused), offersBackup: false))
    }

    @Test("sweep: a refusal that ends after another unit stopped the document does not offer the backup: nothing is sent until Retry")
    func refusedWhileStopped() async throws {
        let service = TranslationService { _, texts, _ in
            if texts.contains(where: { $0.contains("fixture:limit") }) { return .status(429) }
            if texts.contains(where: { $0.contains("fixture:refuse") }) { return .refusal }
            return .texts(TranslationService.marked)
        }
        // The large group's first piece is refused at once; its retry is
        // held.
        service.hold(request: 2)
        let fixture = try await TranslatorFixture.make(service: service, backup: true)
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        let long = PageRun(
            id: 1, block: 1, text: "fixture:refuse " + String(repeating: "これは長い段落の一文です。", count: 900), whole: true, inView: true
        )
        let limited = PageRun(id: 2, block: 2, text: "制限される文 fixture:limit", whole: true, inView: true)
        harness.page.collection = { .success(.runs([long], loaded: true)) }
        await harness.turnOn()
        await harness.eventually { service.requests.count == 2 }
        // Another unit: the primary and the backup both answer 429, and the
        // document stops.
        harness.page.collection = { .success(.runs([long, limited], loaded: true)) }
        await harness.eventually { harness.session.line == .failed(.service(.limited), offersBackup: false) }
        service.release(request: 2)
        await harness.eventually { harness.session.unitsInFlight == 0 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.session.line == .failed(.content(.refused), offersBackup: false))
    }

    // MARK: - N1, N2 at the session's side

    @Test("N1, N2: each collect names the document generation and its reading language; a language change is a new generation in the new language")
    func collectNamesPeriodAndLocale() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.page.collection = { .success(.runs(PageTranslationSessionTests.runs(PageTranslationSessionTests.japanese), loaded: true)) }
        await harness.turnOn()
        await harness.eventually { harness.session.line == .translated(.simplifiedChinese) }
        let first = try #require(harness.page.collectedFor.last)
        #expect(first.locale == .simplifiedChinese && first.period == String(harness.session.currentGeneration))
        harness.session.documentCommitted(Self.address)
        harness.page.newDocument()
        await harness.eventually { harness.page.collectedFor.last.map { $0.period != first.period } ?? false }
        let second = try #require(harness.page.collectedFor.last)
        #expect(second.period == String(harness.session.currentGeneration))
        harness.locale = .english
        await harness.eventually { harness.page.collectedFor.last?.locale == .english }
        let third = try #require(harness.page.collectedFor.last)
        #expect(third.period != second.period)
        await harness.eventually { harness.session.line == .translated(.english) }
    }
}
