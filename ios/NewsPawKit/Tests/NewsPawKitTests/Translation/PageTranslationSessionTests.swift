import Foundation
@testable import NewsPawKit
import Testing

/// A page stand-in for the session: it answers each `collect` from a rule,
/// records every call, and can hold a call until the test releases it.
@MainActor
final class StubPage: PageScripting {
    enum Call: Equatable {
        case collect
        case apply(PageApplyRequest)
        case end(Bool)
    }

    private(set) var calls: [Call] = []
    /// The answer to the next `collect`.
    var collection: () -> Result<PageCollection, PageCallFailure> = { .success(.runs([], loaded: true)) }
    var applyAnswer: ((PageApplyRequest) -> Result<PageApplied, PageCallFailure>)?
    var endAnswer: Result<PageEnded, PageCallFailure> = .success(PageEnded(had: true, restored: 0))
    /// Collects wait while this is set, until `releaseCollects()`.
    var holdsCollects = false
    private var heldCollects: [CheckedContinuation<Void, Never>] = []
    /// Called after each `apply` (the "navigating" stub of criterion 12).
    var afterApply: (() -> Void)?

    var collects: Int {
        calls.filter { $0 == .collect }.count
    }

    var applies: [PageApplyRequest] {
        calls.compactMap { if case .apply(let request) = $0 { request } else { nil } }
    }

    var written: [PageWrite] {
        applies.flatMap(\.writes)
    }

    var ends: [Bool] {
        calls.compactMap { if case .end(let restore) = $0 { restore } else { nil } }
    }

    /// The runs written into or settled in the page, which it does not
    /// return again, as the script does not; `end` forgets them.
    private var writtenIDs = Set<Int>()
    private var settledIDs = Set<Int>()

    func collect() async -> Result<PageCollection, PageCallFailure> {
        calls.append(.collect)
        var answer = collection()
        if case .success(.runs(let runs, let loaded, let written)) = answer {
            let left = runs.filter { !writtenIDs.contains($0.id) && !settledIDs.contains($0.id) }
            answer = .success(.runs(left, loaded: loaded, written: written || !writtenIDs.isEmpty))
        }
        if holdsCollects {
            await withCheckedContinuation { heldCollects.append($0) }
        }
        return answer
    }

    /// The page made a new document: nothing of the script's is in it.
    func newDocument() {
        writtenIDs = []
        settledIDs = []
    }

    func releaseCollects() {
        holdsCollects = false
        let held = heldCollects
        heldCollects = []
        held.forEach { $0.resume() }
    }

    func apply(_ request: PageApplyRequest) async -> Result<PageApplied, PageCallFailure> {
        calls.append(.apply(request))
        defer { afterApply?() }
        let result = applyAnswer?(request) ?? .success(PageApplied(written: request.writes.map(\.id), skipped: [], holding: request.check))
        if case .success(let applied) = result {
            writtenIDs.formUnion(applied.written)
            settledIDs.formUnion(request.settle)
        }
        return result
    }

    func end(restore: Bool) async -> Result<PageEnded, PageCallFailure> {
        calls.append(.end(restore))
        writtenIDs = []
        settledIDs = []
        return endAnswer
    }
}

/// RD16 decisions 4 and 8–12 with a stub page and stubbed HTTP: the
/// states of the line, periods and the ceiling, generations, the poll's
/// conditions, failures and their actions, and the partition rule.
/// Criteria 2, 3, 7, 8, 9, 11, 12, 14 and 15 (the session's half).
@Suite("Page translation session", .serialized)
@MainActor
struct PageTranslationSessionTests {
    static let address = URL(string: "https://pages.example.invalid/ja-list")!

    /// A session over a stub page and the fixture's translator, with a
    /// fast poll; seen unless `seen` says otherwise.
    @MainActor
    final class Harness {
        let page = StubPage()
        let fixture: TranslatorFixture
        let translator: PageTranslator?
        var seen = true
        var locale = ReadingLocale.simplifiedChinese
        private(set) var session: PageTranslationSession!

        init(fixture: TranslatorFixture, translator: Bool = true, ceiling: Int = PageTranslator.standardCeiling, decideAfter: Duration = .seconds(600)) {
            self.fixture = fixture
            self.translator = translator ? PageTranslator(models: fixture.models, ceiling: ceiling) : nil
            var timing = PageTranslationSession.Timing()
            timing.poll = .milliseconds(10)
            timing.afterScroll = .milliseconds(1)
            timing.decideAfter = decideAfter
            timing.briefMessage = .milliseconds(50)
            session = PageTranslationSession(
                scripting: page, translator: self.translator, readingLocale: { [weak self] in self?.locale ?? .simplifiedChinese },
                isSeen: { [weak self] in self?.seen ?? false }, timing: timing
            )
        }

        isolated deinit {
            session.close()
        }

        /// Turns translation on and waits until it is.
        func turnOn() async {
            session.turnOn()
            await eventually { self.session.isOn }
        }

        func eventuallyReads(_ condition: () async throws -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            let deadline = ContinuousClock.now + .seconds(120)
            while try await !condition() {
                guard ContinuousClock.now < deadline else {
                    Issue.record("the condition did not hold within 120 s", sourceLocation: sourceLocation)
                    return
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        func eventually(_ condition: @escaping () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
            let deadline = ContinuousClock.now + .seconds(120)
            while !condition() {
                guard ContinuousClock.now < deadline else {
                    Issue.record("the condition did not hold within 120 s", sourceLocation: sourceLocation)
                    return
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    static func runs(_ texts: [String], from id: Int = 1, block: Int? = nil, whole: Bool = true) -> [PageRun] {
        texts.enumerated().map { index, text in
            PageRun(id: id + index, block: block ?? (id + index), text: text, whole: whole, inView: true)
        }
    }

    static let japanese = ["新しい製品が発表された", "今日の天気は晴れです", "株価が上がりました"]

    // MARK: - States (criteria 1, 3 and 15)

    @Test("a tap turns translation on: Translating…, then Translated to the reading language, with the page's runs written")
    func translates() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.page.collection = { .success(.runs(Self.runs(Self.japanese), loaded: true)) }
        #expect(harness.session.line == nil && !harness.session.isOn)
        await harness.turnOn()
        await harness.eventually { harness.session.line == .translated(.simplifiedChinese) }
        #expect(Set(harness.page.written.map(\.id)) == [1, 2, 3])
        #expect(harness.page.written.allSatisfy { $0.text.hasPrefix("T:") })
        #expect(fixture.service.requests.count == 1)
    }

    @Test("criterion 15: a page in the reading language on a tap: Nothing to translate, briefly, and translation turns off")
    func nothingOnTap() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.page.collection = { .success(.runs(Self.runs(["国务院发布新的数据安全管理条例"]), loaded: true)) }
        harness.session.turnOn()
        await harness.eventually { harness.session.line == .nothingToTranslate(brief: true) }
        #expect(!harness.session.isOn)
        #expect(harness.page.written.isEmpty)
        await harness.eventually { harness.session.line == nil }
        #expect(fixture.service.requests.isEmpty)
    }

    @Test("criterion 15: on a page reached while on, nothing to translate keeps translation on; the next page is translated")
    func nothingOnFollowedPage() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.page.collection = { .success(.runs(Self.runs(Self.japanese), loaded: true)) }
        await harness.turnOn()
        await harness.eventually { harness.session.line == .translated(.simplifiedChinese) }
        harness.page.collection = { .success(.runs(Self.runs(["国务院发布新的数据安全管理条例"], from: 100), loaded: true)) }
        harness.page.newDocument()
        harness.session.documentCommitted(URL(string: "https://pages.example.invalid/zh-hans"))
        await harness.eventually { harness.session.line == .nothingToTranslate(brief: false) }
        #expect(harness.session.isOn)
        harness.page.collection = { .success(.runs(Self.runs(["別のページの本文です"], from: 200), loaded: true)) }
        harness.session.documentCommitted(URL(string: "https://pages.example.invalid/ja-item-2"))
        await harness.eventually { harness.session.line == .translated(.simplifiedChinese) }
        #expect(harness.page.written.contains { $0.id == 200 })
    }

    @Test("criterion 3: a page shown again from the back-forward cache, translated already, reads Translated, not Nothing to translate")
    func cachedPage() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.page.collection = { .success(.runs(Self.runs(Self.japanese), loaded: true)) }
        await harness.turnOn()
        await harness.eventually { harness.session.line == .translated(.simplifiedChinese) }
        harness.page.collection = { .success(.unchanged(loaded: true, written: true)) }
        harness.session.documentCommitted(Self.address)
        try await Task.sleep(for: .milliseconds(200))
        await harness.eventually { harness.session.line == .translated(.simplifiedChinese) }
        #expect(fixture.service.requests.count == 1)
    }

    @Test("criterion 15: a page whose load never ends is decided after the decision time; a held collection never decides")
    func decisions() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture, decideAfter: .milliseconds(200))
        harness.session.documentCommitted(Self.address)
        // A field has focus: held, again and again, past the decision time.
        harness.page.collection = { .success(.held(loaded: true)) }
        await harness.turnOn()
        await harness.eventually { harness.page.collects > 30 }
        #expect(harness.session.isOn && harness.session.line == .translating)
        // The focus leaves; the page has not finished loading and shows
        // nothing to translate: decided after the decision time.
        harness.page.collection = { .success(.runs([], loaded: false)) }
        await harness.eventually { harness.session.line == .nothingToTranslate(brief: true) }
        #expect(!harness.session.isOn)
    }

    @Test("criterion 15: a foreign page whose field has focus stays at Translating… and is translated once the focus leaves")
    func focusThenTranslate() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture, decideAfter: .milliseconds(1))
        harness.session.documentCommitted(Self.address)
        harness.page.collection = { .success(.held(loaded: true)) }
        await harness.turnOn()
        await harness.eventually { harness.page.collects > 10 }
        #expect(harness.session.line == .translating && fixture.service.requests.isEmpty)
        harness.page.collection = { .success(.runs(Self.runs(Self.japanese), loaded: true)) }
        await harness.eventually { harness.session.line == .translated(.simplifiedChinese) }
    }

    // MARK: - Criteria 8 and 9: no model

    @Test("criterion 8: without a translator (the adult workspace) Translate says Set up a model with no link, collects nothing and sends nothing")
    func noTranslator() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture, translator: false)
        harness.session.documentCommitted(Self.address)
        harness.session.toggle()
        #expect(harness.session.line == .noModel(opensSettings: false))
        try await Task.sleep(for: .milliseconds(100))
        #expect(!harness.session.isOn)
        #expect(harness.page.calls.isEmpty)
        #expect(fixture.service.requests.isEmpty)
    }

    @Test("criterion 9: with no primary model, or its key missing, Translate says Set up a model with Open Settings and collects nothing")
    func noPrimary() async throws {
        let fixture = try await TranslatorFixture.make(primary: false)
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.session.toggle()
        await harness.eventually { harness.session.line == .noModel(opensSettings: true) }
        try await fixture.saveSlot(.primary, key: nil)
        harness.session.toggle()
        await harness.eventually { harness.session.line == .noModel(opensSettings: true) }
        #expect(!harness.session.isOn)
        #expect(harness.page.calls.isEmpty)
        #expect(fixture.service.requests.isEmpty)
    }

    // MARK: - Criteria 2 and 3: off, on again, pages shown again

    @Test("criterion 2: Show Original cancels the request in flight (nothing written or stored) and restores the page; on again comes from memory without a request")
    func offAndOnAgain() async throws {
        let service = TranslationService()
        service.hold(request: 1)
        let fixture = try await TranslatorFixture.make(service: service)
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.page.collection = { .success(.runs(Self.runs(Self.japanese, whole: false), loaded: true)) }
        await harness.turnOn()
        await harness.eventually { service.requests.count == 1 }
        harness.session.showOriginal()
        #expect(!harness.session.isOn && harness.session.line == nil)
        await harness.eventually { harness.page.ends == [true] }
        try await harness.eventuallyReads { try await fixture.usage().map(\.outcome) == [.cancelled] }
        #expect(harness.page.written.isEmpty)
        #expect(try await fixture.library.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM page_text") } == 0)

        // On again: sent (nothing was kept), then off and on once more:
        // from memory, no request.
        await harness.turnOn()
        await harness.eventually { harness.session.line == .translated(.simplifiedChinese) }
        #expect(service.requests.count == 2)
        harness.session.toggle()
        await harness.eventually { harness.page.ends.count == 2 }
        let before = harness.page.written.count
        await harness.turnOn()
        await harness.eventually { harness.page.written.count == before + 3 }
        await harness.eventually { harness.session.line == .translated(.simplifiedChinese) }
        #expect(service.requests.count == 2, "turning translation on again on that page makes no request")
    }

    @Test("criterion 3: with translation off, a commit restores a page only when the session has translated before")
    func restoreAtCommitWhileOff() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.session.documentCommitted(URL(string: "https://pages.example.invalid/ja-item-1"))
        #expect(harness.page.calls.isEmpty, "never translated: no call at a commit")
        harness.page.collection = { .success(.runs(Self.runs(Self.japanese), loaded: true)) }
        await harness.turnOn()
        await harness.eventually { harness.session.line == .translated(.simplifiedChinese) }
        harness.session.showOriginal()
        await harness.eventually { harness.page.ends.count == 1 }
        let collects = harness.page.collects
        harness.session.documentCommitted(Self.address)
        await harness.eventually { harness.page.ends.count == 2 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.page.collects == collects, "no other call while off")
        #expect(harness.page.ends == [true, true])
    }

    // MARK: - Criterion 12: the ceiling, the deadline, being seen

    @Test("criterion 12: the 51st request of a period is not sent — also when the page makes a new document after every answer; Continue, Retry and on again each allow 50 more")
    func ceiling() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        var page = 0
        harness.page.collection = {
            page += 1
            return .success(.runs(Self.runs(["新しい文書 \(page) の本文です"], from: page * 10), loaded: true))
        }
        // The page makes a new document after every answer it is given.
        harness.page.afterApply = { [unowned harness] in
            page += 1
            harness.session.documentCommitted(URL(string: "https://pages.example.invalid/endless?\(page)"))
        }
        harness.session.documentCommitted(Self.address)
        await harness.turnOn()
        // At most 50 requests a period: an attempt counts when it is made,
        // also one that a new document cancels before it reaches the
        // service.
        var sent = try await pausedCount(harness, fixture: fixture, before: 0)
        harness.session.continueTranslating()
        sent = try await pausedCount(harness, fixture: fixture, before: sent)
        harness.session.retry()
        sent = try await pausedCount(harness, fixture: fixture, before: sent)
        harness.session.toggle()
        await harness.turnOn()
        _ = try await pausedCount(harness, fixture: fixture, before: sent)
    }

    /// Waits for the paused line, checks that no request is sent while it
    /// is shown and that the period sent at most 50, and returns the count.
    private func pausedCount(_ harness: Harness, fixture: TranslatorFixture, before: Int) async throws -> Int {
        await harness.eventually { harness.session.line == .paused && fixture.service.requests.count > before }
        let count = fixture.service.requests.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.service.requests.count == count, "nothing is sent while paused")
        #expect(count - before <= 50 && count - before >= 45, "\(count - before) requests in the period")
        #expect(try await fixture.usage().count == count)
        return count
    }

    @Test("criterion 12: a session that is not seen makes no call into its page and sends nothing; requests in flight finish and are written once it is seen")
    func notSeen() async throws {
        let service = TranslationService()
        service.hold(request: 1)
        let fixture = try await TranslatorFixture.make(service: service)
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.page.collection = { .success(.runs(Self.runs(Self.japanese), loaded: true)) }
        await harness.turnOn()
        await harness.eventually { service.requests.count == 1 }
        harness.seen = false
        let calls = harness.page.calls.count
        service.release(request: 1)
        await harness.eventually { harness.session.unitsInFlight == 0 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.page.calls.count == calls, "no call while not seen")
        #expect(service.requests.count == 1)
        harness.seen = true
        harness.session.becameSeen()
        await harness.eventually { Set(harness.page.written.map(\.id)) == [1, 2, 3] }
    }

    @Test("criterion 12: a page that never answers is said to be unresponsive; an expiry of an earlier document shows nothing")
    func unresponsive() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.page.collection = { .failure(.timedOut) }
        await harness.turnOn()
        await harness.eventually { harness.session.line == .didNotRespond }
        let collects = harness.page.collects
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.page.collects == collects, "the poll ended for this document")
        // Retry polls again.
        harness.page.collection = { .success(.runs(Self.runs(Self.japanese), loaded: true)) }
        harness.session.retry()
        await harness.eventually { harness.session.line == .translated(.simplifiedChinese) }

        // A collect left hanging by a navigation: its expiry belongs to the
        // old document and shows nothing; the new document's poll goes on.
        let before = harness.page.collects
        harness.page.holdsCollects = true
        harness.page.collection = { .failure(.timedOut) }
        harness.session.documentCommitted(URL(string: "https://pages.example.invalid/next"))
        await harness.eventually { harness.page.collects > before }
        harness.page.holdsCollects = false
        harness.session.documentCommitted(URL(string: "https://pages.example.invalid/third"))
        let afterCommit = harness.page.collects
        harness.page.collection = { .success(.runs(Self.runs(["三つ目の本文です"], from: 300), loaded: true)) }
        await harness.eventually { harness.page.collects > afterCommit }
        harness.page.releaseCollects()
        await harness.eventually { harness.page.written.contains { $0.id == 300 } }
        await harness.eventually { harness.session.line == .translated(.simplifiedChinese) }
    }

    // MARK: - Criterion 14: generations

    @Test("criterion 14: a result of an earlier document generation is neither written nor stored")
    func generations() async throws {
        let service = TranslationService()
        service.hold(request: 1)
        let fixture = try await TranslatorFixture.make(service: service)
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.page.collection = { .success(.runs(Self.runs(Self.japanese), loaded: true)) }
        await harness.turnOn()
        await harness.eventually { service.requests.count == 1 }
        harness.page.collection = { .success(.runs([], loaded: false)) }
        harness.session.documentCommitted(URL(string: "https://pages.example.invalid/ja-item-1"))
        service.release(request: 1)
        try await harness.eventuallyReads { try await fixture.usage().count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.page.written.isEmpty)
        #expect(try await fixture.library.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM page_text") } == 0)
    }

    // MARK: - Criterion 11: in flight

    @Test("criterion 11: at most two requests are in flight per session")
    func twoInFlight() async throws {
        let service = TranslationService()
        for number in 1...6 {
            service.hold(request: number)
        }
        let fixture = try await TranslatorFixture.make(service: service)
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        // 200 groups: five requests of 40.
        let texts = (1...200).map { "項目 \($0) のタイトルです" }
        harness.page.collection = { .success(.runs(Self.runs(texts), loaded: true)) }
        await harness.turnOn()
        await harness.eventually { service.requests.count == 2 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(service.requests.count == 2)
        #expect(harness.session.unitsInFlight == 2)
        for number in 1...6 {
            service.release(request: number)
        }
        await harness.eventually { harness.session.line == .translated(.simplifiedChinese) }
        #expect(service.requests.count == 5, "\(service.requests.map(\.texts.count))")
        #expect(harness.session.line == .translated(.simplifiedChinese), "\(String(describing: harness.session.line)) written \(Set(harness.page.written.map(\.id)).count)")
        #expect(service.mostInFlight == 2)
        #expect(service.requests.allSatisfy { $0.texts.count <= 40 })
    }

    // MARK: - Criterion 7: failures and their actions

    @Test("criterion 7: a refused block stays original and the rest is translated; the line offers Retry and Retry with the Backup Model, which sends exactly one request to the backup")
    func refusal() async throws {
        let service = TranslationService { host, texts, _ in
            host == TranslatorFixture.primaryHost && texts.contains { $0.contains("fixture:refuse") } ? .refusal : .texts(TranslationService.marked)
        }
        let fixture = try await TranslatorFixture.make(service: service, backup: true)
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        // Two blocks in one request: retried as two halves, one block each.
        let runs = Self.runs(["最初の項目です", "拒否される項目 fixture:refuse"])
        harness.page.collection = { .success(.runs(runs, loaded: true)) }
        await harness.turnOn()
        await harness.eventually { harness.session.line == .failed(.content(.refused), offersBackup: true) }
        #expect(service.requests.map(\.texts.count) == [2, 1, 1])
        await harness.eventually { harness.page.written.map(\.id).contains(1) && harness.page.applies.contains { $0.settle.contains(2) } }
        #expect(!harness.page.written.contains { $0.id == 2 })
        #expect(service.requests(to: TranslatorFixture.backupHost).isEmpty)
        let primary = service.requests.count
        harness.session.retryWithBackup()
        await harness.eventually { harness.page.written.contains { $0.id == 2 } }
        #expect(service.requests(to: TranslatorFixture.backupHost).count == 1)
        #expect(service.requests.count == primary + 1)
        await harness.eventually { harness.session.line == .translated(.simplifiedChinese) }
    }

    @Test("criterion 7: a 429 without a backup: the runs stay original, the line gives the reason, and nothing more is sent until Retry, which re-sends only the failed runs")
    func limited() async throws {
        let service = TranslationService { _, _, _ in .status(429) }
        let fixture = try await TranslatorFixture.make(service: service)
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        var runs = Self.runs(Self.japanese)
        harness.page.collection = { .success(.runs(runs, loaded: true)) }
        await harness.turnOn()
        await harness.eventually { harness.session.line == .failed(.service(.limited), offersBackup: false) }
        #expect(service.requests.count == 1)
        // New text appears: nothing more is sent for this document.
        runs += Self.runs(["新しく現れた本文です"], from: 50)
        try await Task.sleep(for: .milliseconds(200))
        #expect(service.requests.count == 1)
        #expect(harness.page.written.isEmpty)
        // Retry: the failed runs that still hold their originals, then the
        // new one through the poll.
        service.answer { _, _, _ in .texts(TranslationService.marked) }
        harness.page.applyAnswer = { request in
            .success(PageApplied(written: request.writes.map(\.id), skipped: [], holding: request.check.filter { $0 != 3 }))
        }
        runs = runs.filter { $0.id != 3 && $0.id != 1 && $0.id != 2 } // the failed runs are settled in the page
        harness.session.retry()
        await harness.eventually { harness.session.line == .translated(.simplifiedChinese) }
        #expect(Array(service.requests[1].texts.prefix(2)) == ["新しい製品が発表された", "今日の天気は晴れです"])
        #expect(!service.requests.dropFirst().contains { $0.texts.contains("株価が上がりました") }, "only the failed runs still holding their originals")
        #expect(Set(harness.page.written.map(\.id)) == [1, 2, 50])
    }

    // MARK: - Criterion 8: partitions

    @Test("criterion 8: the session's text goes only through its translator's library: usage and cache rows land there and nowhere else")
    func partition() async throws {
        let normal = try await TranslatorFixture.make()
        defer { normal.remove() }
        let other = try await TranslatorFixture.make()
        defer { other.remove() }
        let harness = Harness(fixture: normal)
        harness.session.documentCommitted(Self.address)
        harness.page.collection = { .success(.runs(Self.runs(Self.japanese), loaded: true)) }
        await harness.turnOn()
        await harness.eventually { harness.session.line == .translated(.simplifiedChinese) }
        #expect(normal.service.requests.count == 1 && other.service.requests.isEmpty)
        #expect(try await normal.usage().count == 1)
        #expect(try await other.usage().isEmpty)
        #expect(try await other.library.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM page_text") } == 0)
        #expect(try await normal.library.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM page_text") } == 3)
    }

    // MARK: - Hosts

    @Test("a document without an http or https host uses neither the memory nor page_text")
    func noHost() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(URL(string: "about:blank"))
        harness.page.collection = { .success(.runs(Self.runs(Self.japanese), loaded: true)) }
        await harness.turnOn()
        await harness.eventually { harness.session.line == .translated(.simplifiedChinese) }
        #expect(try await fixture.library.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM page_text") } == 0)
    }
}
