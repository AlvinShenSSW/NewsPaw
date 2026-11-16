import Foundation
import GRDB
@testable import NewsPawKit
import Synchronization
import Testing

/// A library and its models over a `TranslationService` (RD14's fixture),
/// a body translator made from those models, and the events it reported.
final class BodyFixture: @unchecked Sendable {
    let base: TranslatorFixture
    let translator: BodyTranslator
    private let events = Mutex<[BodyTranslatorEvent]>([])

    private init(base: TranslatorFixture) {
        self.base = base
        translator = BodyTranslator(models: base.models)
    }

    static func make(service: TranslationService = TranslationService(), primary: Bool = true, backup: Bool = false) async throws -> BodyFixture {
        let fixture = BodyFixture(base: try await TranslatorFixture.make(service: service, primary: primary, backup: backup))
        await fixture.translator.setObserver { [weak fixture] event in
            fixture?.events.withLock { $0.append(event) }
        }
        return fixture
    }

    var service: TranslationService { base.service }
    var library: Library { base.library }

    func remove() {
        base.remove()
    }

    /// Paragraphs of about 700 characters: two to a chunk. `words` puts a
    /// word at the end of paragraph `n` (1-based).
    static func blocks(_ count: Int, story: String = "Story", words: [Int: String] = [:]) -> [ArticleBlock] {
        (1...count).map { BodySegmentsTests.paragraph(FixtureTransport.bodyParagraph($0, of: story, word: words[$0])) }
    }

    func article(_ title: String = "An article") async throws -> UUID {
        try await base.article(title, in: try await base.source())
    }

    /// The stored rows of `article` in `locale`.
    func stored(_ article: UUID, _ locale: ReadingLocale = .simplifiedChinese) async throws -> [String: StoredBodyText] {
        try await translator.storedTexts(ofArticle: article, locale: locale)
    }

    /// What an opening sends (decision 5): the sent texts without a row.
    func waiting(_ plan: BodyTranslationPlan, _ article: UUID) async throws -> Set<String> {
        let stored = try await stored(article, plan.locale)
        return plan.sentHashes.filter { stored[$0] == nil }
    }

    func job(_ plan: BodyTranslationPlan, article: UUID?, sending hashes: Set<String>? = nil, route: BodyTranslationJob.Route = .primary)
        -> BodyTranslationJob {
        BodyTranslationJob(article: article, locale: plan.locale, chunks: plan.chunks(sending: hashes ?? plan.sentHashes), route: route)
    }

    /// Runs `job` to its end.
    @discardableResult
    func run(_ job: BodyTranslationJob) async -> BodyTranslationEnd? {
        await translator.start(job)
        await translator.settled()
        return end(of: job.id)
    }

    var reported: [BodyTranslatorEvent] {
        events.withLock { $0 }
    }

    func end(of job: UUID) -> BodyTranslationEnd? {
        for event in reported {
            if case .ended(job, let end) = event {
                return end
            }
        }
        return nil
    }

    /// Every translation reported, by hash.
    var translated: [String: String] {
        reported.reduce(into: [:]) { result, event in
            if case .translated(_, let texts, _) = event {
                result.merge(texts) { _, new in new }
            }
        }
    }

    func usage() async throws -> [UsageRecord] {
        try await base.usage()
    }

    func eventually(_ condition: @escaping () async throws -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async rethrows {
        try await base.eventually(condition, sourceLocation: sourceLocation)
    }

    /// The paragraphs a request carries, by their number in the story.
    static func paragraphs(of request: TranslationService.Request) -> [Int] {
        request.texts.compactMap { text in
            guard let match = text.firstMatch(of: /paragraph (\d+)\./) else { return nil }
            return Int(match.1)
        }
    }
}

/// RD15 decisions 5–8 and 10: the body translator on a stubbed service.
/// Criteria 3, 4, 5, 6, 13 (the translator), 14 (no row), 15 and 17.
@Suite("Body translator")
struct BodyTranslatorTests {
    static let primary = TranslatorFixture.primaryHost
    static let backup = TranslatorFixture.backupHost

    // MARK: - Criterion 3

    @Test("criterion 3: eight chunks in reading order, one in flight; cancelled during chunk 4, chunks 1–3 are kept and nothing of 4; the next opening sends 4–8; a third sends nothing")
    func leavingAndResuming() async throws {
        let service = TranslationService()
        service.hold(request: 4)
        let fixture = try await BodyFixture.make(service: service)
        defer { fixture.remove() }
        let article = try await fixture.article()
        let plan = BodySegments.plan(BodyFixture.blocks(16), locale: .simplifiedChinese)
        #expect(plan.chunks.count == 8)

        let first = fixture.job(plan, article: article, sending: try await fixture.waiting(plan, article))
        await fixture.translator.start(first)
        await fixture.eventually { fixture.service.requests.count == 4 }
        // "Translating 3 of 8" while chunk 4 is in flight.
        await fixture.eventually { plan.finishedChunks(done: fixture.translated) == 3 }
        await fixture.translator.cancel()
        await fixture.translator.settled()
        #expect(fixture.end(of: first.id) == .cancelled)
        #expect(fixture.service.requests.map(BodyFixture.paragraphs) == [[1, 2], [3, 4], [5, 6], [7, 8]])
        #expect(fixture.service.mostInFlight == 1)
        let stored = try await fixture.stored(article)
        #expect(Set(stored.keys) == Set(plan.chunks[0..<3].flatMap { $0.map(\.hash) }), "chunks 1–3, nothing of 4")
        #expect(stored.values.allSatisfy { $0.state == .done && $0.model == "primary-model" })
        #expect(try await fixture.usage().map(\.outcome.rawValue).sorted() == ["cancelled", "ok", "ok", "ok"], "rows of one moment: order by name")

        // The next opening sends chunks 4–8 only.
        let second = fixture.job(plan, article: article, sending: try await fixture.waiting(plan, article))
        #expect(await fixture.run(second) == .finished)
        #expect(fixture.service.requests.dropFirst(4).map(BodyFixture.paragraphs) == [[7, 8], [9, 10], [11, 12], [13, 14], [15, 16]])
        #expect(plan.finishedChunks(done: try await fixture.stored(article).compactMapValues(\.text)) == 8)
        #expect(try await fixture.usage().count == 9)

        // A third opening has nothing to send.
        #expect(try await fixture.waiting(plan, article).isEmpty)
        #expect(fixture.job(plan, article: article, sending: []).chunks.isEmpty)
    }

    @Test("criterion 3: each chunk is reported as it is accepted, before the next is sent")
    func reportedChunkByChunk() async throws {
        let service = TranslationService()
        service.hold(request: 2)
        let fixture = try await BodyFixture.make(service: service)
        defer { fixture.remove() }
        let plan = BodySegments.plan(BodyFixture.blocks(4), locale: .simplifiedChinese)
        let job = fixture.job(plan, article: try await fixture.article())
        await fixture.translator.start(job)
        await fixture.eventually { fixture.service.requests.count == 2 }
        await fixture.eventually { fixture.translated.count == 2 }
        #expect(Set(fixture.translated.keys) == Set(plan.chunks[0].map(\.hash)))
        #expect(fixture.translated[plan.chunks[0][0].hash] == "T:" + plan.chunks[0][0].text)
        service.release(request: 2)
        await fixture.translator.settled()
        #expect(fixture.end(of: job.id) == .finished)
        #expect(fixture.translated.count == 4)
    }

    // MARK: - Criterion 4: decision 7's table

    @Test("criterion 4: a content failure is retried once as two halves; what fails again is stored failed with its reason; the work goes on; never to the backup",
          arguments: TitleTranslatorTests.contentFailures.indices)
    func contentFailure(_ index: Int) async throws {
        let (name, answer, reason) = TitleTranslatorTests.contentFailures[index]
        // Only chunk 1 (paragraphs 1 and 2) is answered badly.
        let service = TranslationService { _, texts, _ in
            texts.contains { $0.contains("paragraph 1.") || $0.contains("paragraph 2.") } ? answer : .texts(TranslationService.marked)
        }
        let fixture = try await BodyFixture.make(service: service, backup: true)
        defer { fixture.remove() }
        let article = try await fixture.article()
        let plan = BodySegments.plan(BodyFixture.blocks(4), locale: .simplifiedChinese)
        #expect(await fixture.run(fixture.job(plan, article: article)) == .finished, "\(name)")
        #expect(fixture.service.requests.map(BodyFixture.paragraphs) == [[1, 2], [1], [2], [3, 4]], "\(name)")
        #expect(fixture.service.requests.allSatisfy { $0.host == Self.primary }, "\(name)")
        let stored = try await fixture.stored(article)
        for segment in plan.chunks[0] {
            #expect(stored[segment.hash]?.state == .failed && stored[segment.hash]?.failure == reason, "\(name)")
        }
        for segment in plan.chunks[1] {
            #expect(stored[segment.hash]?.state == .done, "\(name)")
        }
        #expect(try await fixture.usage().count == 4, "\(name)")
    }

    @Test("criterion 4: one text is retried as itself; halves that pass are stored; a model that refuses everything costs three requests a chunk")
    func retryShapesAndRefusingModel() async throws {
        let single = try await BodyFixture.make(service: TranslationService { _, _, _ in .refusal })
        defer { single.remove() }
        let one = BodySegments.plan(BodyFixture.blocks(1), locale: .simplifiedChinese)
        #expect(await single.run(single.job(one, article: try await single.article())) == .finished)
        #expect(single.service.requests.map(\.texts.count) == [1, 1])

        let halves = try await BodyFixture.make(service: TranslationService { _, texts, _ in
            texts.count > 1 ? .texts { Array($0.dropLast()) } : .texts(TranslationService.marked)
        })
        defer { halves.remove() }
        let article = try await halves.article()
        let plan = BodySegments.plan(BodyFixture.blocks(4), locale: .simplifiedChinese)
        #expect(await halves.run(halves.job(plan, article: article)) == .finished)
        #expect(halves.service.requests.map(BodyFixture.paragraphs) == [[1, 2], [1], [2], [3, 4], [3], [4]])
        #expect(try await halves.stored(article).values.allSatisfy { $0.state == .done })

        let refusing = try await BodyFixture.make(service: TranslationService { _, _, _ in .refusal }, backup: true)
        defer { refusing.remove() }
        let refused = try await refusing.article()
        let six = BodySegments.plan(BodyFixture.blocks(6), locale: .simplifiedChinese)
        #expect(await refusing.run(refusing.job(six, article: refused)) == .finished)
        #expect(refusing.service.requests.count == 9, "three requests a chunk")
        #expect(refusing.service.requests(to: Self.backup).isEmpty)
        #expect(try await refusing.stored(refused).values.allSatisfy { $0.state == .failed && $0.failure == .refused })
        // Once: an opening sends no stored failure.
        #expect(try await refusing.waiting(six, refused).isEmpty)
    }

    @Test("criterion 4: 429, 503 and no answer send the chunk once to a usable backup, whose reply is stored with its model", arguments: [
        TranslationService.Answer.status(429), .status(503), .failure(.unreachable),
    ])
    func serviceFailureGoesToBackup(_ answer: TranslationService.Answer) async throws {
        let service = TranslationService { host, _, _ in host == TranslatorFixture.primaryHost ? answer : .texts(TranslationService.marked) }
        let fixture = try await BodyFixture.make(service: service, backup: true)
        defer { fixture.remove() }
        let article = try await fixture.article()
        let plan = BodySegments.plan(BodyFixture.blocks(4), locale: .simplifiedChinese)
        #expect(await fixture.run(fixture.job(plan, article: article)) == .finished)
        #expect(fixture.service.requests.map(\.host) == [Self.primary, Self.backup, Self.primary, Self.backup])
        #expect(try await fixture.stored(article).values.allSatisfy { $0.state == .done && $0.model == "backup-model" })
    }

    @Test("criterion 4: a service failure without a usable backup stops the work with its reason and stores nothing", arguments: [false, true])
    func serviceFailureWithoutBackup(_ backupWithoutKey: Bool) async throws {
        let fixture = try await BodyFixture.make(service: TranslationService { _, _, number in
            number == 2 ? .status(503) : .texts(TranslationService.marked)
        })
        defer { fixture.remove() }
        if backupWithoutKey {
            try await fixture.base.saveSlot(.backup, key: nil)
        }
        let article = try await fixture.article()
        let plan = BodySegments.plan(BodyFixture.blocks(6), locale: .simplifiedChinese)
        #expect(await fixture.run(fixture.job(plan, article: article)) == .stopped(.service(.serverError)))
        #expect(fixture.service.requests.count == 2)
        #expect(Set(try await fixture.stored(article).keys) == Set(plan.chunks[0].map(\.hash)))
    }

    @Test("criterion 4: a backup's content failure is stored; a backup's service or set-up failure stops with the primary's reason")
    func backupFailures() async throws {
        let refusing = try await BodyFixture.make(service: TranslationService { host, _, _ in
            host == TranslatorFixture.primaryHost ? .status(429) : .refusal
        }, backup: true)
        defer { refusing.remove() }
        let article = try await refusing.article()
        let plan = BodySegments.plan(BodyFixture.blocks(2), locale: .simplifiedChinese)
        #expect(await refusing.run(refusing.job(plan, article: article)) == .finished)
        #expect(refusing.service.requests.map(\.host) == [Self.primary, Self.backup])
        #expect(try await refusing.stored(article).values.allSatisfy { $0.state == .failed && $0.failure == .refused })

        for backupAnswer in [TranslationService.Answer.status(503), .status(401)] {
            let down = try await BodyFixture.make(service: TranslationService { host, _, _ in
                host == TranslatorFixture.primaryHost ? .status(429) : backupAnswer
            }, backup: true)
            defer { down.remove() }
            let other = try await down.article()
            #expect(await down.run(down.job(plan, article: other)) == .stopped(.service(.limited)))
            #expect(down.service.requests.count == 2)
            #expect(try await down.stored(other).isEmpty)
        }
    }

    @Test("criterion 4: a set-up failure stops the work and stores nothing; no model and no key send nothing", arguments: [
        "noModel", "keyNeeded", "keyRejected", "modelNotFound",
    ])
    func setUpFailures(_ kind: String) async throws {
        let answer: TranslationService.Answer = kind == "modelNotFound" ? .status(404) : .status(401)
        let fixture = try await BodyFixture.make(service: TranslationService { _, _, _ in answer }, primary: kind != "noModel")
        defer { fixture.remove() }
        if kind == "keyNeeded" {
            try await fixture.base.models.removeKey(.primary)
        }
        let article = try await fixture.article()
        let plan = BodySegments.plan(BodyFixture.blocks(4), locale: .simplifiedChinese)
        let expected: ModelFailure = switch kind {
        case "noModel": .noModelSetUp
        case "keyNeeded": .keyNeeded
        case "keyRejected": .keyRejected
        default: .modelNotFound
        }
        #expect(await fixture.run(fixture.job(plan, article: article)) == .stopped(.setUp(expected)))
        #expect(fixture.service.requests.count == (kind == "noModel" || kind == "keyNeeded" ? 0 : 1))
        #expect(try await fixture.stored(article).isEmpty)
    }

    @Test("criterion 4: results that cannot be written are reported for this opening, and the work stops for storage")
    func writeFailure() async throws {
        let fixture = try await BodyFixture.make()
        defer { fixture.remove() }
        let article = try await fixture.article()
        try await fixture.library.pool.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_body BEFORE INSERT ON body_translation BEGIN SELECT RAISE(FAIL, 'refused by the test'); END;")
        }
        let plan = BodySegments.plan(BodyFixture.blocks(4), locale: .simplifiedChinese)
        #expect(await fixture.run(fixture.job(plan, article: article)) == .stopped(.storage))
        #expect(fixture.service.requests.count == 1)
        #expect(Set(fixture.translated.keys) == Set(plan.chunks[0].map(\.hash)))
        #expect(try await fixture.stored(article).isEmpty)
    }

    @Test("criterion 4: the article deleted during a request: its result is dropped and the work ends")
    func articleDeletedDuringRequest() async throws {
        let service = TranslationService()
        service.hold(request: 1)
        let fixture = try await BodyFixture.make(service: service)
        defer { fixture.remove() }
        let article = try await fixture.article()
        let plan = BodySegments.plan(BodyFixture.blocks(4), locale: .simplifiedChinese)
        let job = fixture.job(plan, article: article)
        await fixture.translator.start(job)
        await fixture.eventually { fixture.service.requests.count == 1 }
        try await fixture.library.pool.write { db in
            try db.execute(sql: "DELETE FROM article WHERE id = ?", arguments: [article.databaseKey])
        }
        service.release(request: 1)
        await fixture.translator.settled()
        #expect(fixture.end(of: job.id) == .gone)
        #expect(fixture.service.requests.count == 1)
        #expect(fixture.translated.isEmpty)
        #expect(try await BodyTranslationStoreTests.rowCount(fixture.library) == 0)
    }

    @Test("criterion 4: never more than one request in flight, also when new work replaces running work; a text is in at most two primary requests and one backup request")
    func oneInFlightAndPerTextBound() async throws {
        // Chunk 1 is rejected, its halves get 429, the backup refuses.
        let service = TranslationService { host, texts, _ in
            if host == TranslatorFixture.backupHost { return .refusal }
            return texts.count > 1 ? .texts { Array($0.dropLast()) } : .status(429)
        }
        let fixture = try await BodyFixture.make(service: service, backup: true)
        defer { fixture.remove() }
        let article = try await fixture.article()
        let plan = BodySegments.plan(BodyFixture.blocks(4), locale: .simplifiedChinese)
        #expect(await fixture.run(fixture.job(plan, article: article)) == .finished)
        for segment in plan.sentHashes {
            let text = plan.chunks.flatMap { $0 }.first { $0.hash == segment }!.text
            let containing = fixture.service.requests.filter { $0.texts.contains(text) }
            #expect(containing.filter { $0.host == Self.primary }.count == 2)
            #expect(containing.filter { $0.host == Self.backup }.count == 1)
        }

        // New work replacing work whose request is in flight waits for it.
        let held = TranslationService()
        held.hold(request: 1)
        let replacing = try await BodyFixture.make(service: held)
        defer { replacing.remove() }
        let other = try await replacing.article()
        let first = replacing.job(plan, article: other)
        await replacing.translator.start(first)
        await replacing.eventually { replacing.service.requests.count == 1 }
        let second = replacing.job(BodySegments.plan(BodyFixture.blocks(2, story: "Other"), locale: .japanese), article: other)
        await replacing.translator.start(second)
        await replacing.translator.settled()
        #expect(replacing.end(of: first.id) == .cancelled)
        #expect(replacing.end(of: second.id) == .finished)
        #expect(replacing.service.mostInFlight == 1)
        #expect(try await replacing.usage().map(\.outcome.rawValue).sorted() == ["cancelled", "ok"])
    }

    // MARK: - Criterion 5

    @Test("criterion 5: a stored failure holds back only its own texts; Retry sends exactly them; the backup retry once; a slot save makes them wait again")
    func storedFailureHoldsBackOnlyItsTexts() async throws {
        let refuseWord = "fixture:refuse"
        let service = TranslationService { host, texts, _ in
            host == TranslatorFixture.primaryHost && texts.contains { $0.contains(refuseWord) } ? .refusal : .texts(TranslationService.marked)
        }
        service.hold(request: 6)
        let fixture = try await BodyFixture.make(service: service, backup: true)
        defer { fixture.remove() }
        let article = try await fixture.article()
        // Paragraph 3 (chunk 2) is refused.
        let plan = BodySegments.plan(BodyFixture.blocks(16, words: [3: refuseWord]), locale: .simplifiedChinese)
        let first = fixture.job(plan, article: article)
        await fixture.translator.start(first)
        // Chunk 1, chunk 2 and its two halves, chunk 3, then chunk 4 held.
        await fixture.eventually { fixture.service.requests.count == 6 }
        await fixture.translator.cancel()
        await fixture.translator.settled()
        #expect(fixture.service.requests.map(BodyFixture.paragraphs) == [[1, 2], [3, 4], [3], [4], [5, 6], [7, 8]])
        let failedHash = plan.chunks[1][0].hash
        #expect(try await fixture.stored(article)[failedHash]?.failure == .refused)

        // The next opening: chunks 4–8, not chunk 2's failed text.
        let waiting = try await fixture.waiting(plan, article)
        #expect(!waiting.contains(failedHash))
        #expect(await fixture.run(fixture.job(plan, article: article, sending: waiting)) == .finished)
        #expect(fixture.service.requests.dropFirst(6).map(BodyFixture.paragraphs) == [[7, 8], [9, 10], [11, 12], [13, 14], [15, 16]])

        // Retry: every sent text not done, which is the failed one.
        let stored = try await fixture.stored(article)
        let notDone = plan.sentHashes.filter { stored[$0]?.state != .done }
        #expect(notDone == [failedHash])
        #expect(await fixture.run(fixture.job(plan, article: article, sending: notDone)) == .finished)
        #expect(fixture.service.requests.dropFirst(11).map(BodyFixture.paragraphs) == [[3], [3]])
        #expect(fixture.service.requests.dropFirst(11).allSatisfy { $0.host == Self.primary })

        // Retry with the Backup Model: once, to the backup.
        #expect(await fixture.run(fixture.job(plan, article: article, sending: notDone, route: .backupOnly)) == .finished)
        #expect(fixture.service.requests.dropFirst(13).map(\.host) == [Self.backup])
        #expect(fixture.service.requests.dropFirst(13).map(BodyFixture.paragraphs) == [[3]])
        #expect(try await fixture.stored(article)[failedHash]?.model == "backup-model")
    }

    @Test("criterion 5: saving a slot deletes the failed body rows and the next opening sends them")
    func slotSaveSendsFailedAgain() async throws {
        let refusing = Mutex(true)
        let service = TranslationService { _, _, _ in refusing.withLock { $0 } ? .refusal : .texts(TranslationService.marked) }
        let fixture = try await BodyFixture.make(service: service)
        defer { fixture.remove() }
        let article = try await fixture.article()
        let plan = BodySegments.plan(BodyFixture.blocks(2), locale: .simplifiedChinese)
        await fixture.run(fixture.job(plan, article: article))
        #expect(try await fixture.waiting(plan, article).isEmpty)
        refusing.withLock { $0 = false }
        try await fixture.base.saveSlot(.primary, host: "repaired.example.invalid")
        let waiting = try await fixture.waiting(plan, article)
        #expect(waiting == plan.sentHashes)
        #expect(await fixture.run(fixture.job(plan, article: article, sending: waiting)) == .finished)
        #expect(try await fixture.stored(article).values.allSatisfy { $0.state == .done })
    }

    // MARK: - Criterion 6

    @Test("criterion 6: body requests are purpose body, not automatic, sent at a daily limit of 0 and not counted by it; cancelled ones are rows too")
    func notLimitedNotCounted() async throws {
        let service = TranslationService()
        service.hold(request: 3)
        let fixture = try await BodyFixture.make(service: service)
        defer { fixture.remove() }
        try await fixture.library.setDailyAutomaticLimit(0)
        let article = try await fixture.article()
        let plan = BodySegments.plan(BodyFixture.blocks(8), locale: .simplifiedChinese)
        let job = fixture.job(plan, article: article)
        await fixture.translator.start(job)
        await fixture.eventually { fixture.service.requests.count == 3 }
        await fixture.translator.cancel()
        await fixture.translator.settled()
        let usage = try await fixture.usage()
        #expect(usage.count == 3)
        #expect(usage.allSatisfy { $0.purpose == .body && !$0.automatic })
        #expect(usage.map(\.outcome.rawValue).sorted() == ["cancelled", "ok", "ok"])
        #expect(try await fixture.library.automaticRequestCount(since: .distantPast) == 0)
        #expect(try await fixture.library.usageCount(purpose: .body) == 3)
    }

    // MARK: - Criterion 13

    @Test("criterion 13: a job naming an article of another library sends nothing and writes no row in either library")
    func otherLibrary() async throws {
        let fixture = try await BodyFixture.make()
        defer { fixture.remove() }
        let store = LibraryStore(directory: fixture.base.directory.appending(path: "second"), now: fixture.base.clock.now)
        let adult = try await store.createAdultLibrary()
        let category = try await adult.createCategory(name: "Adult", icon: .folder)
        let source = Sample.source(in: category.id, url: "https://adult.example.invalid/feed", name: "Adult", at: fixture.base.clock.now())
        try await adult.insert(source)
        let adultArticle = Sample.article(in: source.id, externalID: "adult-1", title: "Adult story", at: fixture.base.clock.now())
        try await adult.insert(adultArticle)
        let plan = BodySegments.plan(BodyFixture.blocks(4), locale: .simplifiedChinese)
        #expect(await fixture.run(fixture.job(plan, article: adultArticle.id)) == .gone)
        #expect(fixture.service.requests.isEmpty)
        #expect(try await fixture.usage().isEmpty)
        #expect(try await BodyTranslationStoreTests.rowCount(fixture.library) == 0)
        #expect(try await BodyTranslationStoreTests.rowCount(adult) == 0)
        #expect(try await adult.pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage") } == 0)
        // Its rows are read from the translator's own library: none.
        #expect(try await fixture.stored(adultArticle.id).isEmpty)
    }

    // MARK: - Criterion 14

    @Test("criterion 14: a job without an article (reader mode) writes nothing to body_translation; its requests are usage rows; the title is its first text")
    func readerMode() async throws {
        let fixture = try await BodyFixture.make()
        defer { fixture.remove() }
        _ = try await fixture.article()
        let plan = BodySegments.plan(BodyFixture.blocks(3), title: "The ferry at dawn", locale: .simplifiedChinese)
        #expect(await fixture.run(fixture.job(plan, article: nil)) == .finished)
        #expect(fixture.service.requests.first?.texts.first == "The ferry at dawn")
        #expect(fixture.translated.count == 4)
        #expect(plan.text(of: BodySegments.titleBlock, done: fixture.translated) == "T:The ferry at dawn")
        #expect(try await BodyTranslationStoreTests.rowCount(fixture.library) == 0)
        #expect(try await fixture.usage().count == 2)
        // Opened again: everything is sent again.
        #expect(await fixture.run(fixture.job(plan, article: nil)) == .finished)
        #expect(try await fixture.usage().count == 4)
        #expect(try await BodyTranslationStoreTests.rowCount(fixture.library) == 0)
    }

    // MARK: - Criterion 15

    @Test("criterion 15: a changed body reuses the rows of its unchanged texts; only changed ones are sent")
    func changedBody() async throws {
        let fixture = try await BodyFixture.make()
        defer { fixture.remove() }
        let article = try await fixture.article()
        let feed = BodySegments.plan(BodyFixture.blocks(4), locale: .simplifiedChinese)
        await fixture.run(fixture.job(feed, article: article))
        // The extraction: the same four paragraphs, one changed, two more.
        var blocks = BodyFixture.blocks(6)
        blocks[1] = BodySegmentsTests.paragraph("A changed second paragraph, as the page has it.")
        let extracted = BodySegments.plan(blocks, locale: .simplifiedChinese)
        let waiting = try await fixture.waiting(extracted, article)
        let sentTexts = extracted.chunks.flatMap { $0 }.filter { waiting.contains($0.hash) }.map(\.text)
        #expect(sentTexts.count == 3)
        #expect(sentTexts[0] == "A changed second paragraph, as the page has it.")
        let before = fixture.service.requests.count
        await fixture.run(fixture.job(extracted, article: article, sending: waiting))
        #expect(fixture.service.requests.dropFirst(before).flatMap(\.texts) == sentTexts)
        let stored = try await fixture.stored(article).compactMapValues(\.text)
        #expect((0..<6).allSatisfy { extracted.text(of: $0, done: stored) != nil })
    }

    // MARK: - Criterion 17

    @Test("criterion 17: a new reading language cancels the work, keeps the old rows, shows none of them and translates in the new one")
    func localeChange() async throws {
        let service = TranslationService()
        service.hold(request: 2)
        let fixture = try await BodyFixture.make(service: service)
        defer { fixture.remove() }
        let article = try await fixture.article()
        let chinese = BodySegments.plan(BodyFixture.blocks(4), locale: .simplifiedChinese)
        let first = fixture.job(chinese, article: article)
        await fixture.translator.start(first)
        await fixture.eventually { fixture.service.requests.count == 2 }
        let japanese = BodySegments.plan(BodyFixture.blocks(4), locale: .japanese)
        let waiting = try await fixture.waiting(japanese, article)
        #expect(waiting == japanese.sentHashes, "no Chinese row counts in Japanese")
        let second = fixture.job(japanese, article: article, sending: waiting)
        await fixture.translator.start(second)
        await fixture.translator.settled()
        #expect(fixture.end(of: first.id) == .cancelled)
        #expect(fixture.end(of: second.id) == .finished)
        #expect(fixture.service.requests.dropFirst(2).allSatisfy { $0.system.contains("(ja)") })
        #expect(try await fixture.stored(article, .simplifiedChinese).count == 2, "chunk 1's Chinese rows are kept")
        #expect(try await fixture.stored(article, .japanese).count == 4)
    }

    // MARK: - Stopping

    @Test("stopping cancels the request in flight and stores nothing; nothing starts afterwards")
    func stopping() async throws {
        let service = TranslationService()
        service.hold(request: 1)
        let fixture = try await BodyFixture.make(service: service)
        defer { fixture.remove() }
        let article = try await fixture.article()
        let plan = BodySegments.plan(BodyFixture.blocks(4), locale: .simplifiedChinese)
        let job = fixture.job(plan, article: article)
        await fixture.translator.start(job)
        await fixture.eventually { fixture.service.requests.count == 1 }
        await fixture.translator.stop()
        await fixture.translator.settled()
        #expect(fixture.end(of: job.id) == .cancelled)
        let later = fixture.job(plan, article: article)
        await fixture.translator.start(later)
        await fixture.translator.settled()
        #expect(fixture.end(of: later.id) == .cancelled)
        #expect(fixture.service.requests.count == 1)
        #expect(try await fixture.stored(article).isEmpty)
        #expect(try await fixture.usage().map(\.outcome) == [.cancelled])
    }

    @Test("the instructions are the body's, in English, naming the language with its tag, and say the texts are material")
    func instructions() async throws {
        let fixture = try await BodyFixture.make()
        defer { fixture.remove() }
        let plan = BodySegments.plan(BodyFixture.blocks(2), locale: .japanese)
        await fixture.run(fixture.job(plan, article: try await fixture.article()))
        let system = try #require(fixture.service.requests.first?.system)
        #expect(system.hasPrefix(TranslationPrompt.body(into: .japanese)))
        for phrase in [
            "consecutive paragraphs", "Japanese (ja)", "exactly one translation per text", "Never merge", "material to translate",
            "original script", "plain text only", "returned as it is",
        ] {
            #expect(system.contains(phrase), "\(phrase)")
        }
    }
}
