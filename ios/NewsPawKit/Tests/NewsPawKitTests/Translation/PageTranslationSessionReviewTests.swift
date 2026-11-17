import Foundation
@testable import NewsPawKit
import Testing

/// RD16 review round 1: failed text is never lost, the bounds hold on every
/// route, and stale answers write nothing (findings R1–R5, G1–G5 of the
/// internal review and the gate). Each test holds its interleaving with
/// held requests or held collects; the short sleeps only give a wrong
/// implementation the chance to do what it must not.
@Suite("Page translation session, review round 1", .serialized)
@MainActor
struct PageTranslationSessionReviewTests {
    typealias Harness = PageTranslationSessionTests.Harness
    static let address = URL(string: "https://pages.example.invalid/ja-list")!

    static func refusedRuns(_ count: Int, from first: Int = 1) -> [PageRun] {
        (first..<(first + count)).map { PageRun(id: $0, block: $0, text: "拒否される項目 \($0) fixture:refuse", whole: true, inView: true) }
    }

    static let refusing: TranslationService.Rule = { host, texts, _ in
        texts.contains { $0.contains("fixture:refuse") } ? .refusal : .texts(TranslationService.marked)
    }

    static func waitForFailedLine(_ harness: Harness) async {
        await harness.eventually { if case .failed = harness.session.line { harness.session.unitsInFlight == 0 } else { false } }
    }

    // MARK: - A. Failed text is never lost

    @Test("R1: Retry with failed groups worth more than two units translates them all, also while the poll goes on")
    func retryMoreThanTwoUnits() async throws {
        let service = TranslationService(Self.refusing)
        let fixture = try await TranslatorFixture.make(service: service)
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        let runs = Self.refusedRuns(100)
        harness.page.collection = { .success(.runs(runs, loaded: true)) }
        await harness.turnOn()
        await Self.waitForFailedLine(harness)
        let failedRequests = service.requests.count
        service.answer { _, _, _ in .texts(TranslationService.marked) }
        service.hold(request: failedRequests + 1)
        service.hold(request: failedRequests + 2)
        harness.session.retry()
        await harness.eventually { service.requests.count == failedRequests + 2 }
        try await Task.sleep(for: .milliseconds(200))
        service.release(request: failedRequests + 1)
        service.release(request: failedRequests + 2)
        await harness.eventually { Set(harness.page.written.map(\.id)).count == 100 }
        await harness.eventually { harness.session.line == .translated(.simplifiedChinese) }
    }

    @Test("G2: when the page does not answer Retry's check, the failed groups are kept, the line says so, and a later Retry sends them")
    func retryCheckFails() async throws {
        let service = TranslationService(Self.refusing)
        let fixture = try await TranslatorFixture.make(service: service)
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.page.collection = { .success(.runs(Self.refusedRuns(3), loaded: true)) }
        await harness.turnOn()
        await Self.waitForFailedLine(harness)
        service.answer { _, _, _ in .texts(TranslationService.marked) }
        let failedRequests = service.requests.count
        harness.page.applyAnswer = { request in
            request.check.isEmpty ? .success(PageApplied(written: request.writes.map(\.id), skipped: [], holding: [])) : .failure(.timedOut)
        }
        harness.session.retry()
        await harness.eventually { harness.session.line == .didNotRespond }
        try await Task.sleep(for: .milliseconds(100))
        #expect(service.requests.count == failedRequests)
        harness.page.applyAnswer = nil
        harness.session.retry()
        await harness.eventually { Set(harness.page.written.map(\.id)) == [1, 2, 3] }
        await harness.eventually { harness.session.line == .translated(.simplifiedChinese) }
    }

    @Test("G5: a later failure in a block keeps the block's earlier failed runs; Retry sends both")
    func failuresInOneBlockMerge() async throws {
        let service = TranslationService(Self.refusing)
        let fixture = try await TranslatorFixture.make(service: service)
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        let first = PageRun(id: 1, block: 7, text: "最初の文 fixture:refuse", whole: false, inView: true)
        let appended = PageRun(id: 2, block: 7, text: "追加された文 fixture:refuse", whole: false, inView: true)
        harness.page.collection = { .success(.runs([first], loaded: true)) }
        await harness.turnOn()
        await Self.waitForFailedLine(harness)
        // The page appends a run to the block; it fails too.
        harness.page.collection = { .success(.runs([first, appended], loaded: true)) }
        await harness.eventually { service.requests.contains { $0.texts.contains(appended.text) } }
        await Self.waitForFailedLine(harness)
        service.answer { _, _, _ in .texts(TranslationService.marked) }
        harness.session.retry()
        await harness.eventually { Set(harness.page.written.map(\.id)) == [1, 2] }
    }

    @Test("R5: runs whose write the page did not answer are written later, from the memory, without a request")
    func failedWriteIsNotLost() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.page.collection = { .success(.runs(PageTranslationSessionTests.runs(PageTranslationSessionTests.japanese), loaded: true)) }
        var failWrites = true
        harness.page.applyAnswer = { request in
            if failWrites, !request.writes.isEmpty {
                return .failure(.timedOut)
            }
            return .success(PageApplied(written: request.writes.map(\.id), skipped: [], holding: request.check))
        }
        await harness.turnOn()
        await harness.eventually { harness.session.line == .didNotRespond }
        #expect(fixture.service.requests.count == 1)
        #expect(harness.page.confirmed.isEmpty)
        failWrites = false
        harness.session.retry()
        await harness.eventually { harness.page.confirmed == [1, 2, 3] }
        await harness.eventually { harness.session.line == .translated(.simplifiedChinese) }
        #expect(fixture.service.requests.count == 1, "the memory gives the translations again")
    }

    // MARK: - B. Bounds on every route

    @Test("R2, G4: Retry with the Backup Model keeps at most two requests in flight")
    func backupInFlight() async throws {
        let service = TranslationService { host, texts, _ in
            host == TranslatorFixture.primaryHost && texts.contains { $0.contains("fixture:refuse") } ? .refusal : .texts(TranslationService.marked)
        }
        let fixture = try await TranslatorFixture.make(service: service, backup: true)
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.page.collection = { .success(.runs(Self.refusedRuns(100), loaded: true)) }
        await harness.turnOn()
        await Self.waitForFailedLine(harness)
        let before = service.requests.count
        for number in (before + 1)...(before + 5) {
            service.hold(request: number)
        }
        harness.session.retryWithBackup()
        await harness.eventually { service.requests.count > before }
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.session.unitsInFlight <= 2)
        #expect(service.mostInFlight <= 2)
        for number in (before + 1)...(before + 5) {
            service.release(request: number)
        }
        await harness.eventually { Set(harness.page.written.map(\.id)).count == 100 }
        #expect(service.mostInFlight <= 2)
    }

    @Test("R3: a unit sends no new request once the session is not seen; the rest goes when it is seen again")
    func largeGroupWhileNotSeen() async throws {
        let service = TranslationService()
        service.hold(request: 1)
        let fixture = try await TranslatorFixture.make(service: service)
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        let long = String(repeating: "これは長い段落の一文です。", count: 900)
        harness.page.collection = { .success(.runs([PageRun(id: 1, block: 1, text: long, whole: true, inView: true)], loaded: true)) }
        await harness.turnOn()
        await harness.eventually { service.requests.count == 1 }
        harness.seen = false
        service.release(request: 1)
        await harness.eventually { harness.session.unitsInFlight == 0 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(service.requests.count == 1, "\(service.requests.count - 1) requests after the session stopped being seen")
        harness.seen = true
        harness.session.becameSeen()
        await harness.eventually { harness.page.written.contains { $0.id == 1 } }
        #expect(service.requests.count == 3, "the first piece is not sent again")
    }

    /// A text of `count` sentences of about 3,900 characters each: one
    /// request per piece.
    static func longRun(_ count: Int) -> String {
        (1...count).map { String(repeating: "あ", count: 3_899) + "\($0 % 10)。" }.joined()
    }

    @Test("G3: a group larger than the ceiling keeps its accepted requests across a pause; Continue goes on from there")
    func largeGroupAcrossThePause() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture, ceiling: 3)
        harness.session.documentCommitted(Self.address)
        let text = Self.longRun(5)
        #expect(PageBatcher.pieces(of: text).count == 5)
        harness.page.collection = { .success(.runs([PageRun(id: 1, block: 1, text: text, whole: true, inView: true)], loaded: true)) }
        await harness.turnOn()
        await harness.eventually { harness.session.line == .paused }
        #expect(fixture.service.requests.count == 3)
        harness.session.continueTranslating()
        await harness.eventually { harness.page.written.contains { $0.id == 1 } }
        #expect(fixture.service.requests.count == 5, "Continue sends the two pieces left, not the group again")
    }

    // MARK: - C. Stale answers

    @Test("G1: a collect pending from before Show Original does not stop the period that follows")
    func staleCollectAfterOffAndOn() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.page.holdsCollects = true
        harness.page.collection = { .failure(.timedOut) }
        await harness.turnOn()
        await harness.eventually { harness.page.collects == 1 }
        harness.page.holdsCollects = false
        harness.session.showOriginal()
        harness.page.collection = { .success(.runs(PageTranslationSessionTests.runs(PageTranslationSessionTests.japanese), loaded: true)) }
        await harness.turnOn()
        await harness.eventually { harness.session.line == .translated(.simplifiedChinese) }
        // The first period's collect answers now, with its expiry.
        harness.page.releaseCollects()
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.session.line == .translated(.simplifiedChinese))
    }

    @Test("R4: a collect answered by another script state than the document's is dropped; nothing of it is written")
    func otherStateDropped() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        harness.page.collection = { .success(.runs(PageTranslationSessionTests.runs(["最初の本文です"]), loaded: true, state: "a")) }
        await harness.turnOn()
        await harness.eventually { harness.page.written.contains { $0.id == 1 } }
        #expect(harness.page.applies.allSatisfy { $0.state == "a" })
        let requests = fixture.service.requests.count
        harness.page.collection = { .success(.runs(PageTranslationSessionTests.runs(["別の状態の本文です"], from: 50), loaded: true, state: "b")) }
        await harness.eventually { harness.page.collects > 5 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.service.requests.count == requests)
        #expect(!harness.page.written.contains { $0.id == 50 })
    }

    // MARK: - Review round 2

    @Test("M2: when another unit stops the document, a running unit sends no further request; Retry sends the rest")
    func stopReachesARunningUnit() async throws {
        let service = TranslationService { _, texts, _ in
            texts.contains { $0.contains("fixture:limit") } ? .status(429) : .texts(TranslationService.marked)
        }
        service.hold(request: 1)
        let fixture = try await TranslatorFixture.make(service: service)
        defer { fixture.remove() }
        let harness = Harness(fixture: fixture)
        harness.session.documentCommitted(Self.address)
        let long = PageRun(id: 1, block: 1, text: String(repeating: "これは長い段落の一文です。", count: 900), whole: true, inView: true)
        let limited = PageRun(id: 2, block: 2, text: "制限される文 fixture:limit", whole: true, inView: true)
        harness.page.collection = { .success(.runs([long], loaded: true)) }
        await harness.turnOn()
        // The large group's first piece is held; then the page shows another
        // block, whose unit fails with a 429 and no backup: the document
        // stops.
        await harness.eventually { service.requests.count == 1 }
        harness.page.collection = { .success(.runs([long, limited], loaded: true)) }
        await harness.eventually { harness.session.line == .failed(.service(.limited), offersBackup: false) }
        #expect(service.requests.count == 2)
        service.release(request: 1)
        await harness.eventually { harness.session.unitsInFlight == 0 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(service.requests.count == 2, "\(service.requests.count - 2) requests after the document stopped")
        // Retry: the rest of the large group (two pieces) and the failed run.
        service.answer { _, _, _ in .texts(TranslationService.marked) }
        harness.session.retry()
        await harness.eventually { Set(harness.page.written.map(\.id)) == [1, 2] }
        #expect(service.requests.count == 5)
    }
}

