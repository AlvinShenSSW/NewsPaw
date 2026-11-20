import Foundation
@testable import NewsPawKit
import Testing

/// Issue #188: three recovery defects of page translation (RD16) that #183
/// recorded as known limits. Each test holds its interleaving with held
/// collects or checks, or by calling the session's step itself; none waits
/// for a time to pass.
@Suite("Page translation session, recovery (#188)", .serialized)
@MainActor
struct PageTranslationRecoveryTests {
    typealias Harness = PageTranslationSessionTests.Harness
    typealias Review = PageTranslationSessionReviewTests
    static let address = URL(string: "https://pages.example.invalid/ja-list")!

    /// A collection rule that answers as the script does on a page that
    /// does not change: the runs at the first collect of each period (the
    /// walk clears the dirty flag), `unchanged` at every later collect of
    /// that period.
    static func walkOncePerPeriod(_ harness: Harness, _ runs: [PageRun]) -> () -> Result<PageCollection, PageCallFailure> {
        var walked = Set<String>()
        return { [unowned harness] in
            let period = harness.page.collectedFor.last?.period ?? ""
            return walked.insert(period).inserted ? .success(.runs(runs, loaded: true)) : .success(.unchanged(loaded: true))
        }
    }

    /// Applies that write fail before the script runs when `failing()`,
    /// asked once for each of them, says so; Retry's checks and the other
    /// applies are answered.
    static func failingWrites(_ failing: @escaping () -> Bool) -> (PageApplyRequest) -> Result<PageApplied, PageCallFailure> {
        { request in
            if !request.writes.isEmpty, failing() {
                return .failure(.timedOut)
            }
            return .success(PageApplied(written: request.writes.map(\.id), skipped: [], holding: request.check))
        }
    }

    var applyingWrites: (StubPage) -> Int {
        { page in page.applies.filter { !$0.writes.isEmpty }.count }
    }

    // MARK: - 1. A write that fails before its script ran

    @Test("#188 (1): after a write that failed on an unchanged page, Retry walks again and writes the translations from the memory; Translated only once the page has them")
    func failedWriteOnAnUnchangedPage() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.page.collection = Self.walkOncePerPeriod(harness, PageTranslationSessionTests.runs(PageTranslationSessionTests.japanese))
        var failing = true
        harness.page.applyAnswer = Self.failingWrites { failing }
        await harness.turnOn()
        await harness.eventually { harness.session.line == .didNotRespond }
        #expect(fixture.service.requests.count == 1)
        #expect(harness.page.confirmed.isEmpty)
        failing = false
        // Retry; its collect is held: until the walk's runs have come, the
        // session does not know the page shows the translations.
        harness.page.holdsCollects = true
        let collects = harness.page.collects
        harness.session.retry()
        await harness.eventually { harness.page.heldCollectCount == 1 }
        #expect(harness.session.line == .translating, "the line read \(String(describing: harness.session.line)) before the page had the translations")
        #expect(harness.page.collectedFor[collects].period != harness.page.collectedFor[collects - 1].period, "the collect after the failed write names a new period")
        harness.page.releaseCollects()
        await harness.eventually { harness.page.confirmed == [1, 2, 3] }
        await harness.eventually { harness.session.line == .translated(.simplifiedChinese) }
        #expect(fixture.service.requests.count == 1, "the translations came from the memory, without a request")
    }

    @Test("#188 (1): a write that keeps failing keeps saying the page did not respond; each Retry owes one walk and one write, no loop, no request")
    func writeThatKeepsFailing() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.page.collection = Self.walkOncePerPeriod(harness, PageTranslationSessionTests.runs(PageTranslationSessionTests.japanese))
        harness.page.applyAnswer = Self.failingWrites { true }
        await harness.turnOn()
        await harness.eventually { harness.session.line == .didNotRespond }
        await harness.eventually { !harness.session.isActing }
        for round in 1...3 {
            harness.session.retry()
            await harness.eventually { applyingWrites(harness.page) == round + 1 && harness.session.line == .didNotRespond }
            // The poll has ended for the document: steps ask nothing more.
            let calls = harness.page.calls.count
            for _ in 0..<3 {
                await harness.session.tick()
            }
            #expect(harness.page.calls.count == calls, "a step called into the page after the write failed again")
            #expect(applyingWrites(harness.page) == round + 1)
            await harness.eventually { !harness.session.isActing }
        }
        #expect(fixture.service.requests.count == 1, "no translation was asked for again")
        #expect(harness.page.confirmed.isEmpty)
    }

    @Test("#188 (1): a write that failed while the session was not seen is written once it is seen again, from the memory")
    func failedWriteWhileNotSeen() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.page.collection = Self.walkOncePerPeriod(harness, PageTranslationSessionTests.runs(PageTranslationSessionTests.japanese))
        // The first write fails; the later ones are made.
        var failures = 1
        harness.page.applyAnswer = Self.failingWrites {
            failures -= 1
            return failures >= 0
        }
        harness.page.holdsWrites = true
        await harness.turnOn()
        await harness.eventually { harness.page.heldWriteCount == 1 }
        // The write fails across a time the page was not seen (the app went
        // to the background and came back): it does not say the page did
        // not respond, and its runs are not lost.
        harness.seen = false
        harness.session.becameSeen()
        harness.seen = true
        harness.page.releaseWrites()
        await harness.eventually { harness.page.confirmed == [1, 2, 3] }
        #expect(harness.session.line != .didNotRespond)
        await harness.eventually { harness.session.line == .translated(.simplifiedChinese) }
        #expect(fixture.service.requests.count == 1)
    }

    // MARK: - 2. The backup model's offer

    static let refusingPrimary: TranslationService.Rule = { host, texts, _ in
        host == TranslatorFixture.primaryHost && texts.contains { $0.contains("fixture:refuse") } ? .refusal : .texts(TranslationService.marked)
    }

    @Test("#188 (2): a backup slot added after a refusal is offered when the session is seen again, without a request and without turning Translate off and on")
    func backupAddedThenSeenAgain() async throws {
        let service = TranslationService(Self.refusingPrimary)
        let fixture = try await TranslatorFixture.make(service: service)
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.page.collection = { .success(.runs(Review.refusedRuns(1), loaded: true)) }
        await harness.turnOn()
        await harness.eventually { harness.session.line == .failed(.content(.refused), offersBackup: false) && harness.session.unitsInFlight == 0 }
        try await fixture.saveSlot(.backup)
        let requests = service.requests.count
        harness.session.becameSeen()
        await harness.eventually { harness.session.line == .failed(.content(.refused), offersBackup: true) }
        #expect(service.requests.count == requests)
        #expect(harness.session.isOn)
        // The offer works: one request to the backup.
        await harness.eventually { !harness.session.isActing }
        harness.session.retryWithBackup()
        await harness.eventually { harness.page.confirmed == [1] }
        #expect(service.requests(to: TranslatorFixture.backupHost).count == 1)
    }

    @Test("#188 (2): a backup slot added after a refusal is offered at the next Retry")
    func backupAddedThenRetry() async throws {
        let service = TranslationService(Self.refusingPrimary)
        let fixture = try await TranslatorFixture.make(service: service)
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.page.collection = { .success(.runs(Review.refusedRuns(1), loaded: true)) }
        await harness.turnOn()
        await harness.eventually { harness.session.line == .failed(.content(.refused), offersBackup: false) && harness.session.unitsInFlight == 0 }
        try await fixture.saveSlot(.backup)
        await harness.eventually { !harness.session.isActing }
        let requests = service.requests(to: TranslatorFixture.primaryHost).count
        harness.session.retry()
        // The primary refuses again (its request and its retry).
        await harness.eventually { service.requests(to: TranslatorFixture.primaryHost).count == requests + 2 }
        await harness.eventually { harness.session.line == .failed(.content(.refused), offersBackup: true) }
        #expect(service.requests(to: TranslatorFixture.backupHost).isEmpty, "never sent to the backup automatically")
    }

    @Test("#188 (2): readiness is read from the session's own models only: a backup of another library is not offered")
    func backupOfAnotherLibrary() async throws {
        let service = TranslationService(Self.refusingPrimary)
        let fixture = try await TranslatorFixture.make(service: service)
        defer { fixture.remove() }
        let other = try await TranslatorFixture.make(service: service)
        defer { other.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.page.collection = { .success(.runs(Review.refusedRuns(1), loaded: true)) }
        await harness.turnOn()
        await harness.eventually { harness.session.line == .failed(.content(.refused), offersBackup: false) && harness.session.unitsInFlight == 0 }
        // Another library (the other partition's) gets a backup; this
        // session is seen again and retried.
        try await other.saveSlot(.backup)
        await harness.eventually { !harness.session.isActing }
        harness.session.becameSeen()
        let requests = service.requests(to: TranslatorFixture.primaryHost).count
        harness.session.retry()
        await harness.eventually { service.requests(to: TranslatorFixture.primaryHost).count == requests + 2 }
        await harness.eventually { !harness.session.isActing && harness.session.unitsInFlight == 0 }
        #expect(harness.session.line == .failed(.content(.refused), offersBackup: false))
        // Its own library gets one: offered.
        try await fixture.saveSlot(.backup)
        harness.session.becameSeen()
        await harness.eventually { harness.session.line == .failed(.content(.refused), offersBackup: true) }
    }

    @Test("#188 (2): after a refusal and then a malformed reply in one period, the backup is still offered while refused text remains")
    func refusalThenMalformed() async throws {
        let service = TranslationService { host, texts, _ in
            if host == TranslatorFixture.primaryHost, texts.contains(where: { $0.contains("fixture:refuse") }) { return .refusal }
            if texts.contains(where: { $0.contains("fixture:malformed") }) { return .content("this is not a JSON array") }
            return .texts(TranslationService.marked)
        }
        let fixture = try await TranslatorFixture.make(service: service, backup: true)
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        let refused = PageRun(id: 1, block: 1, text: "拒否される項目 fixture:refuse", whole: true, inView: true)
        let malformed = PageRun(id: 2, block: 2, text: "壊れた返事の項目 fixture:malformed", whole: true, inView: true)
        harness.page.collection = { .success(.runs([refused], loaded: true)) }
        await harness.turnOn()
        await harness.eventually { harness.session.line == .failed(.content(.refused), offersBackup: true) && harness.session.unitsInFlight == 0 }
        harness.page.collection = { .success(.runs([refused, malformed], loaded: true)) }
        await harness.eventually {
            if case .failed(let reason, _) = harness.session.line { reason != .content(.refused) && harness.session.unitsInFlight == 0 } else { false }
        }
        guard case .failed(let reason, let offersBackup) = harness.session.line else { return }
        #expect(reason != .content(.refused))
        #expect(offersBackup, "refused text remains and a backup is set up")
        // Retry with the Backup Model sends the refused run only.
        await harness.eventually { !harness.session.isActing }
        harness.session.retryWithBackup()
        await harness.eventually { harness.page.confirmed.contains(1) }
        #expect(service.requests(to: TranslatorFixture.backupHost).map(\.texts) == [[refused.text]])
        // No refused text remains: the backup is no longer offered.
        await harness.eventually { if case .failed(_, false) = harness.session.line { true } else { false } }
    }

    // MARK: - 3. A page the session does not see (the failure view)

    @Test("#188 (3): while the session is not seen, Retry asks the page nothing and keeps its failures; seen again, Retry sends them")
    func retryWhileNotSeen() async throws {
        let service = TranslationService(Review.refusing)
        let fixture = try await TranslatorFixture.make(service: service)
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.page.collection = { .success(.runs(Review.refusedRuns(2), loaded: true)) }
        await harness.turnOn()
        await Review.waitForFailedLine(harness)
        await harness.eventually { !harness.session.isActing }
        service.answer { _, _, _ in .texts(TranslationService.marked) }
        let requests = service.requests.count
        harness.seen = false
        let calls = harness.page.calls.count
        harness.session.retry()
        await harness.eventually { !harness.session.isActing }
        #expect(harness.page.calls.count == calls, "Retry called into a page that is not seen: \(harness.page.calls.suffix(from: calls))")
        #expect(service.requests.count == requests)
        #expect(harness.session.line == .failed(.content(.refused), offersBackup: false), "the failures stay, with Retry")
        harness.seen = true
        harness.session.becameSeen()
        harness.session.retry()
        await harness.eventually { harness.page.confirmed == [1, 2] }
        await harness.eventually { harness.session.line == .translated(.simplifiedChinese) }
    }

    @Test("#188 (3): Translate tapped while the page is not seen collects nothing; seen again, the page is translated")
    func translateWhileNotSeen() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.page.collection = { .success(.runs(PageTranslationSessionTests.runs(PageTranslationSessionTests.japanese), loaded: true)) }
        harness.seen = false
        await harness.turnOn()
        await harness.eventually { !harness.session.isActing }
        harness.session.scrolled()
        harness.session.becameSeen()
        for _ in 0..<3 {
            await harness.session.tick()
        }
        #expect(harness.page.calls.isEmpty, "a call into a page that is not seen: \(harness.page.calls)")
        #expect(fixture.service.requests.isEmpty)
        harness.seen = true
        harness.session.becameSeen()
        await harness.eventually { harness.page.confirmed == [1, 2, 3] }
        await harness.eventually { harness.session.line == .translated(.simplifiedChinese) }
    }

    @Test("#188 (3): Translate tapped over the failure state, then Try Again: the page shown again while the new one loads answers the tap; the new page is reached while on")
    func translateWhileNotSeenThenTryAgain() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.page.collection = { .success(.runs(PageTranslationSessionTests.runs(PageTranslationSessionTests.japanese), loaded: true)) }
        harness.seen = false
        await harness.turnOn()
        await harness.eventually { !harness.session.isActing }
        #expect(harness.page.calls.isEmpty)
        // Try Again, in the app's order: `load()` clears the failure (the
        // session is seen again) before the new page commits, and the page
        // shown before is on screen meanwhile.
        harness.seen = true
        harness.session.becameSeen()
        await harness.eventually { harness.page.confirmed == [1, 2, 3] }
        // The new page commits; in the reading language it is a page
        // reached while on: translation stays on.
        harness.page.collection = { .success(.runs(PageTranslationSessionTests.runs(["国务院发布新的数据安全管理条例"], from: 100), loaded: true)) }
        harness.page.newDocument()
        harness.session.documentCommitted(URL(string: "https://pages.example.invalid/zh-hans"))
        await harness.eventually { harness.session.line == .nothingToTranslate(brief: false) }
        #expect(harness.session.isOn)
        #expect(fixture.service.requests.count == 1)
    }

    // MARK: - Fix round 1

    @Test("#188 r1 (R1): a step whose write spans the page ceasing to be seen does not go on to collect from it")
    func noCollectAfterAWriteWhileNotSeen() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        fixture.service.hold(request: 1)
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        var unseenCollects = 0
        let walk = Self.walkOncePerPeriod(harness, PageTranslationSessionTests.runs(PageTranslationSessionTests.japanese))
        harness.page.collection = { [unowned harness] in
            if !harness.seen { unseenCollects += 1 }
            return walk()
        }
        await harness.turnOn()
        await harness.eventually { fixture.service.requests.count == 1 }
        // The answer comes while the page is not seen: its writes wait.
        harness.seen = false
        fixture.service.release(request: 1)
        await harness.eventually { harness.session.unitsInFlight == 0 }
        #expect(harness.page.confirmed.isEmpty)
        // Seen again: a step takes the waiting writes, and the write is
        // held in the page.
        harness.page.holdsWrites = true
        harness.seen = true
        harness.session.becameSeen()
        await harness.eventually { harness.page.heldWriteCount == 1 }
        // The failure state comes while the write is in the page.
        harness.seen = false
        harness.page.releaseWrites()
        // The step's write ends with the line; a collect would follow it
        // in the same step, before anything else runs.
        await harness.eventually { harness.page.confirmed == [1, 2, 3] && harness.session.line == .translated(.simplifiedChinese) }
        #expect(unseenCollects == 0, "\(unseenCollects) collect(s) made while the page was not seen")
    }

    @Test("#188 r1 (R2): outside the failure state nothing changes: a page that did not respond, then a link to a page in the reading language keeps translation on")
    func unansweredPageThenAReadingLanguagePage() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.page.collection = { .failure(.timedOut) }
        await harness.turnOn()
        await harness.eventually { harness.session.line == .didNotRespond }
        // A link to a page in the reading language.
        harness.page.collection = { .success(.runs(PageTranslationSessionTests.runs(["国务院发布新的数据安全管理条例"], from: 100), loaded: true)) }
        harness.session.documentCommitted(URL(string: "https://pages.example.invalid/zh-hans"))
        await harness.eventually { harness.session.line == .nothingToTranslate(brief: false) || harness.session.line == .nothingToTranslate(brief: true) }
        #expect(harness.session.line == .nothingToTranslate(brief: false), "as on main: a page reached while on says so and translation stays on")
        #expect(harness.session.isOn)
    }
}
