import Foundation
import GRDB
@testable import NewsPawKit
import Testing

/// RD14 decisions 4, 6, 7, 8, 9 (what is stored), 10 and 12: the
/// translator on a stubbed service, an injected clock, calendar and sleep.
/// Criteria 1, 2, 3, 5, 6, 7, 8, 9, 10, 13 and 15.
@Suite("Title translator")
struct TitleTranslatorTests {
    static let primary = TranslatorFixture.primaryHost
    static let backup = TranslatorFixture.backupHost

    // MARK: - Criterion 1

    @Test("criterion 1: a refresh of 60 foreign items sends 20, 20 and 10 newest first; the other ten when their rows are asked for")
    @MainActor
    func refreshOfSixty() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let address = "https://sixty.example.invalid/feed"
        let items: String = (1...60).map { number -> String in
            let name = String(format: "%02d", number)
            // Item 1 is the newest.
            return """
                <item><guid>sixty-\(name)</guid><title>Story \(name) about the harbour</title>\
                <description>Summary of story \(name).</description>\
                <pubDate>\(Self.rfc822(fixture.clock.now().addingTimeInterval(TimeInterval(-3_600 * number))))</pubDate></item>
                """
        }.joined()
        let transport = CountingTransport { url in
            TransportResponse(finalURL: url, status: 200, headers: [:], body: Data(rssDocument(items).utf8))
        }
        var source = Sample.source(in: fixture.category, url: address, name: "Sixty", at: fixture.clock.now())
        source.autoTranslate = .inherit
        try await fixture.library.insert(source)
        await fixture.start()
        #expect(fixture.service.requests.isEmpty)

        try await Refresher(library: fixture.library, transport: transport).refresh(.library)
        await fixture.resume(.refreshEnded)

        let requests = fixture.service.requests
        #expect(requests.map { $0.texts.count / 2 } == [20, 20, 10])
        let sent = requests.flatMap { fixture.titles(of: $0) }
        #expect(sent == (1...50).map { String(format: "Story %02d about the harbour", $0) }, "newest first")
        #expect(requests.allSatisfy { $0.texts.count % 2 == 0 }, "an article's title and excerpt go together")
        #expect(try await fixture.translationCount() == 50)

        // The other ten when their rows are asked for.
        let rows = try await fixture.library.articleRows(.library, filter: .all, translationsIn: .simplifiedChinese)
        let waiting = rows.filter { $0.translation == nil }.map(\.id)
        #expect(waiting.count == 10)
        await fixture.ask(waiting)
        #expect(fixture.service.requests.count == 4)
        #expect(fixture.service.requests.last?.texts.count == 20)
        #expect(try await fixture.translationCount() == 60)
        #expect(try await fixture.usage().allSatisfy { $0.automatic && $0.purpose == .titles && $0.outcome == .ok })
    }

    @Test("criterion 1: with 500-character excerpts the 50 newest go in requests of at most 6,000 characters")
    func fullExcerpts() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let source = try await fixture.source()
        let excerpt = String(repeating: "The harbour lights come on along the quay at dusk. ", count: 12)
        _ = try await fixture.englishArticles(60, in: source) { _ in excerpt }
        await fixture.start()
        let requests = fixture.service.requests
        let sizes = requests.map { $0.texts.reduce(0) { $0 + $1.count } }
        #expect(sizes.allSatisfy { $0 <= TitleTranslator.batchCharacters }, "\(sizes)")
        #expect(requests.map { $0.texts.count / 2 }.reduce(0, +) == 50)
        #expect(requests.count == 5, "about ten articles a request: \(requests.map { $0.texts.count / 2 })")
        #expect(requests.allSatisfy { $0.texts.count % 2 == 0 }, "an article is never split")
        #expect(requests.flatMap(\.texts).filter { $0 != String(excerpt.prefix(500)) }.allSatisfy { $0.hasPrefix("Story ") })
    }

    // MARK: - Criterion 2

    /// The crafted replies of decision 5 and the content failures of the
    /// service, each with the reason stored.
    static let contentFailures: [(String, TranslationService.Answer, TranslationFailure)] = [
        ("count", .texts({ Array($0.dropLast()) }), .count),
        ("empty", .texts({ $0.enumerated().map { $0.offset == 0 ? " " : "T:" + $0.element } }), .empty),
        ("cut off", .texts(TranslationService.marked, finishReason: "length"), .cutOff),
        ("length", .texts({ $0.map { String(repeating: "长", count: 6 * $0.count + 41) } }), .length),
        ("refused", .refusal, .refused),
        ("malformed", .content("Here are the translations you asked for."), .malformed),
        ("bad request", .status(400), .badRequest),
    ]

    @Test("criterion 2: a rejected batch is retried once as two halves; a second rejection stores failed with its reason; a wholly failed batch pauses",
          arguments: contentFailures.indices)
    func contentFailure(_ index: Int) async throws {
        let (name, answer, reason) = Self.contentFailures[index]
        let fixture = try await TranslatorFixture.make(service: TranslationService { _, _, _ in answer }, backup: true)
        defer { fixture.remove() }
        let source = try await fixture.source()
        let ids = try await fixture.englishArticles(4, in: source)
        await fixture.start()
        let requests = fixture.service.requests
        #expect(requests.map { $0.texts.count / 2 } == [4, 2, 2], "\(name)")
        #expect(requests.allSatisfy { $0.host == Self.primary }, "\(name): never to the backup")
        for id in ids {
            #expect(try await fixture.translation(id) == StoredTranslation(state: .failed, title: nil, excerpt: nil, failure: reason), "\(name)")
            // A model was called: the failed row names it (decision 2).
            #expect(try await fixture.rawTranslation(id)?.model == "primary-model", "\(name)")
        }
        #expect(try await fixture.usage().count == 3, "\(name): one usage row per request")
        #expect(await fixture.translator.pausedBy == .failedBatch(reason), "\(name)")

        // During the pause a waiting article is judged and blocked, not sent.
        let later = try await fixture.article("Another story about the quay", in: source)
        await fixture.ask([later])
        #expect(fixture.service.requests.count == 3, "\(name): paused")
        #expect(fixture.blocked[later] == .failedBatch(reason))
    }

    @Test("criterion 2: one article is retried as itself; halves that pass are stored")
    func retryShapes() async throws {
        let service = TranslationService { _, texts, _ in
            // Rejects any request of more than two articles.
            texts.count > 4 ? .texts { Array($0.dropLast()) } : .texts(TranslationService.marked)
        }
        let fixture = try await TranslatorFixture.make(service: service)
        defer { fixture.remove() }
        let source = try await fixture.source()
        let ids = try await fixture.englishArticles(4, in: source)
        await fixture.start()
        #expect(fixture.service.requests.map { $0.texts.count / 2 } == [4, 2, 2])
        for id in ids {
            #expect(try await fixture.translation(id)?.state == .done)
        }
        #expect(await fixture.translator.pausedBy == nil)

        let single = try await TranslatorFixture.make(service: TranslationService { _, _, _ in .refusal })
        defer { single.remove() }
        let one = try await single.article("A single story", in: try await single.source())
        await single.start()
        #expect(single.service.requests.map(\.texts.count) == [1, 1])
        #expect(try await single.translation(one)?.failure == .refused)
    }

    // MARK: - Criterion 3

    @Test("criterion 3: a title kept with a name in its original script is stored; one returned unchanged is stored as null")
    func keptNamesAndUnchanged() async throws {
        let service = TranslationService { _, texts, _ in
            .texts { _ in texts.map { $0 == "Apple unveils iPhone 18" ? "Apple 发布 iPhone 18" : $0 } }
        }
        let fixture = try await TranslatorFixture.make(service: service)
        defer { fixture.remove() }
        let source = try await fixture.source()
        let named = try await fixture.article("Apple unveils iPhone 18", excerpt: "Shown in Cupertino.", in: source)
        await fixture.start()
        #expect(try await fixture.translation(named) == StoredTranslation(state: .done, title: "Apple 发布 iPhone 18", excerpt: nil, failure: nil))
        let raw = try #require(try await fixture.rawTranslation(named))
        #expect(raw.model == "primary-model")
    }

    // MARK: - Criterion 5

    @Test("criterion 5: 429, 503 and no answer from the primary send the batch once to the backup", arguments: [
        TranslationService.Answer.status(429), .status(503), .failure(.unreachable),
    ].indices)
    func serviceFailureGoesToBackup(_ index: Int) async throws {
        let failing: [TranslationService.Answer] = [.status(429), .status(503), .failure(.unreachable)]
        let failure = failing[index]
        let service = TranslationService { host, _, _ in host == Self.primary ? failure : .texts(TranslationService.marked) }
        let fixture = try await TranslatorFixture.make(service: service, backup: true)
        defer { fixture.remove() }
        let source = try await fixture.source()
        let ids = try await fixture.englishArticles(3, in: source)
        await fixture.start()
        #expect(fixture.service.requests.map(\.host) == [Self.primary, Self.backup])
        for id in ids {
            #expect(try await fixture.translation(id)?.title?.hasPrefix("T:Story") == true)
        }
        let raw = try #require(try await fixture.rawTranslation(ids[0]))
        #expect(raw.model == "backup-model")
        #expect(await fixture.translator.pausedBy == nil)
    }

    @Test("criterion 5: without a backup nothing is stored, the articles are blocked, the pause holds 10 minutes and then work resumes")
    func servicePause() async throws {
        let service = TranslationService { _, _, _ in .status(503) }
        let fixture = try await TranslatorFixture.make(service: service)
        defer { fixture.remove() }
        let source = try await fixture.source()
        let ids = try await fixture.englishArticles(3, in: source)
        await fixture.start()
        #expect(fixture.service.requests.count == 1)
        #expect(try await fixture.translationCount() == 0)
        #expect(Set(fixture.blocked.keys) == Set(ids))
        #expect(fixture.blocked.values.allSatisfy { $0 == .service(.serverError) })
        #expect(fixture.sleeper.durations == [.seconds(600)])

        // Asking, a new locale and the switch do not end it.
        await fixture.ask(ids)
        await fixture.resume(.localeChanged)
        #expect(fixture.service.requests.count == 1)

        // The 10 minutes pass: work resumes, and the service answers now.
        service.answer { _, _, _ in .texts(TranslationService.marked) }
        fixture.clock.advance(seconds: 600)
        fixture.sleeper.wake()
        await fixture.eventually { fixture.service.requests.count == 2 }
        await fixture.translator.settled()
        #expect(fixture.service.requests.count == 2)
        #expect(try await fixture.translationCount() == 3)
        #expect(fixture.blocked.isEmpty)
    }

    @Test("criterion 5: a service pause ends when the app comes to the front, when a refresh ends and when a manual retry succeeds")
    func servicePauseEnds() async throws {
        for trigger in [TranslationTrigger.cameToFront, .refreshEnded] {
            let service = TranslationService { _, _, number in number == 1 ? .status(429) : .texts(TranslationService.marked) }
            let fixture = try await TranslatorFixture.make(service: service)
            defer { fixture.remove() }
            let ids = try await fixture.englishArticles(2, in: try await fixture.source())
            await fixture.start()
            #expect(await fixture.translator.pausedBy == .service(.limited))
            await fixture.resume(trigger)
            #expect(fixture.service.requests.count == 2, "\(trigger)")
            #expect(try await fixture.translation(ids[0])?.state == .done)
        }
        let service = TranslationService { _, _, number in number == 1 ? .status(429) : .texts(TranslationService.marked) }
        let fixture = try await TranslatorFixture.make(service: service)
        defer { fixture.remove() }
        let ids = try await fixture.englishArticles(2, in: try await fixture.source())
        await fixture.start()
        #expect(await fixture.translator.retry(ids[0], backup: false) == .stored)
        await fixture.translator.settled()
        #expect(await fixture.translator.pausedBy == nil)
        #expect(try await fixture.translation(ids[1])?.state == .done, "the pause ended and work resumed")
    }

    @Test("criterion 5: a refusal is retried on the primary, never sent to the backup, and stored; Retry with the Backup Model sends one request")
    func refusalAndBackupRetry() async throws {
        let service = TranslationService { host, _, _ in host == Self.primary ? .refusal : .texts(TranslationService.marked) }
        let fixture = try await TranslatorFixture.make(service: service, backup: true)
        defer { fixture.remove() }
        let id = try await fixture.article("A story the model declines", in: try await fixture.source())
        await fixture.start()
        #expect(fixture.service.requests.map(\.host) == [Self.primary, Self.primary])
        #expect(try await fixture.translation(id)?.failure == .refused)

        #expect(await fixture.translator.retry(id, backup: true) == .stored)
        #expect(fixture.service.requests.map(\.host) == [Self.primary, Self.primary, Self.backup])
        #expect(try await fixture.translation(id)?.title == "T:A story the model declines")
        let usage = try await fixture.usage()
        #expect(usage.map(\.automatic).sorted { !$0 && $1 } == [false, true, true])
    }

    @Test("a backup's content failure is stored; a backup's service failure blocks with the primary's reason")
    func backupFailures() async throws {
        let refusing = TranslationService { host, _, _ in host == Self.primary ? .status(503) : .refusal }
        let fixture = try await TranslatorFixture.make(service: refusing, backup: true)
        defer { fixture.remove() }
        let id = try await fixture.article("Story", in: try await fixture.source())
        await fixture.start()
        #expect(fixture.service.requests.map(\.host) == [Self.primary, Self.backup], "no retry on the backup")
        #expect(try await fixture.translation(id)?.failure == .refused)
        #expect(try await fixture.rawTranslation(id)?.model == "backup-model", "the model that refused")

        let down = TranslationService { host, _, _ in host == Self.primary ? .status(429) : .status(503) }
        let second = try await TranslatorFixture.make(service: down, backup: true)
        defer { second.remove() }
        let other = try await second.article("Story", in: try await second.source())
        await second.start()
        #expect(second.service.requests.map(\.host) == [Self.primary, Self.backup])
        #expect(try await second.translation(other) == nil)
        #expect(second.blocked[other] == .service(.limited))
        #expect(await second.translator.pausedBy == .service(.limited))
    }

    // MARK: - Criterion 6

    static let setUpCases: [(String, TranslationService.Answer?, ModelFailure, Int)] = [
        ("key rejected", .status(401), .keyRejected, 1),
        ("model not found", .status(404), .modelNotFound, 1),
        ("key needed", nil, .keyNeeded, 0),
        ("no slot", nil, .noModelSetUp, 0),
    ]

    @Test("criterion 6: a set-up failure sends one request at most and stores nothing; front and refresh send nothing more; a changed slot ends it",
          arguments: setUpCases.indices)
    func setUpPause(_ index: Int) async throws {
        let (name, answer, failure, requests) = Self.setUpCases[index]
        let service = TranslationService { _, _, _ in answer ?? .texts(TranslationService.marked) }
        let fixture = try await TranslatorFixture.make(service: service, primary: failure != .noModelSetUp)
        defer { fixture.remove() }
        if failure == .keyNeeded {
            try await fixture.models.removeKey(.primary)
        }
        let source = try await fixture.source()
        let ids = try await fixture.englishArticles(25, in: source)
        let simplified = try await fixture.article("国务院发布新的数据安全管理条例", in: source)
        await fixture.start()
        #expect(fixture.service.requests.count == requests, "\(name)")
        #expect(try await fixture.translationCount() == 1, "\(name): only the row that needs no model")
        #expect(try await fixture.translation(simplified)?.state == TranslationState.none)
        #expect(await fixture.translator.pausedBy == .setUp(failure), "\(name)")
        #expect(Set(fixture.blocked.keys) == Set(ids), "\(name): every article that needs the model is blocked")

        await fixture.resume(.cameToFront)
        await fixture.resume(.refreshEnded)
        await fixture.ask(ids)
        #expect(fixture.service.requests.count == requests, "\(name): nothing more")

        service.answer { _, _, _ in .texts(TranslationService.marked) }
        try await fixture.saveSlot(.primary)
        await fixture.resume(.slotsChanged)
        #expect(await fixture.translator.pausedBy == nil, "\(name)")
        #expect(fixture.service.requests.count > requests, "\(name): sent again")
        #expect(try await fixture.translationCount() == 26)
    }

    @Test("criterion 6: a set-up pause ends at a trigger that reads the slots different")
    func setUpPauseSeesChangedSlots() async throws {
        let service = TranslationService { _, _, _ in .status(401) }
        let fixture = try await TranslatorFixture.make(service: service)
        defer { fixture.remove() }
        _ = try await fixture.englishArticles(2, in: try await fixture.source())
        await fixture.start()
        #expect(await fixture.translator.pausedBy == .setUp(.keyRejected))
        // Saved elsewhere (the other workspace's Settings), without telling
        // this translator.
        service.answer { _, _, _ in .texts(TranslationService.marked) }
        try await fixture.saveSlot(.primary, key: "sk-a-new-key-0123456789")
        await fixture.resume(.cameToFront)
        #expect(await fixture.translator.pausedBy == nil)
        #expect(try await fixture.translationCount() == 2)
    }

    @Test("criterion 6: saving a slot deletes failed rows and they are translated again")
    func failedTranslatedAgain() async throws {
        let service = TranslationService { _, _, _ in .refusal }
        let fixture = try await TranslatorFixture.make(service: service)
        defer { fixture.remove() }
        let ids = try await fixture.englishArticles(2, in: try await fixture.source())
        await fixture.start()
        #expect(try await fixture.translation(ids[0])?.state == .failed)
        service.answer { _, _, _ in .texts(TranslationService.marked) }
        try await fixture.saveSlot(.primary)
        await fixture.resume(.slotsChanged)
        for id in ids {
            #expect(try await fixture.translation(id)?.state == .done)
        }
    }

    /// The answer of the old primary, the request held until after the
    /// change, and whether a backup is set up.
    static let supersededCases: [(String, TranslationService.Answer, Int, Bool)] = [
        // The first request's 401 comes back after the change.
        ("key rejected", .status(401), 1, false),
        // The refusal's retry comes back after the change.
        ("refused", .refusal, 2, false),
        // Service failures: neither a pause nor the backup.
        ("503", .status(503), 1, false),
        ("503 with a backup", .status(503), 1, true),
        ("network", .failure(.unreachable), 1, false),
        ("network with a backup", .failure(.unreachable), 1, true),
    ]

    @Test("a set-up, content or service failure that comes back after a slot change stores, blocks and pauses nothing; the new slot translates",
          arguments: supersededCases.indices)
    func failureAfterSlotChange(_ index: Int) async throws {
        let (name, answer, held, backup) = Self.supersededCases[index]
        let repaired = "repaired.example.invalid"
        let service = TranslationService { host, _, _ in host == Self.primary ? answer : .texts(TranslationService.marked) }
        service.hold(request: held)
        let fixture = try await TranslatorFixture.make(service: service, backup: backup)
        defer { fixture.remove() }
        let id = try await fixture.article("Story one", in: try await fixture.source())
        await fixture.translator.configure(TranslationConfiguration(locale: .simplifiedChinese, automatic: true))
        await fixture.eventually { fixture.service.requests.count == held }
        // The owner saves a repaired slot while the request is in flight.
        try await fixture.saveSlot(.primary, host: repaired)
        await fixture.translator.resume(after: .slotsChanged)
        service.release(request: held)
        await fixture.translator.settled()

        #expect(await fixture.translator.pausedBy == nil, "\(name)")
        #expect(fixture.blocked[id] == nil, "\(name)")
        #expect(fixture.service.requests.map(\.host).last == repaired, "\(name)")
        #expect(fixture.service.requests(to: Self.backup).isEmpty, "\(name): the old slot's failure goes to no backup")
        // No pause on the repaired slot that the app's coming to the front
        // or a refresh's end would have to end (the gate's G2).
        await fixture.resume(.cameToFront)
        await fixture.resume(.refreshEnded)
        #expect(await fixture.translator.pausedBy == nil, "\(name)")
        let row = try await fixture.rawTranslation(id)
        #expect(row?.state == "done", "\(name): no failed row; translated on the new slot")
        #expect(try await fixture.translation(id)?.title == "T:Story one", "\(name)")
    }

    // MARK: - Stale writes across an await (fix round 3)

    @Test("a pass whose candidates come back after a newer pass began does not replace its queue: all 50 are translated in the new language")
    func stalePassDropped() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let ids = try await fixture.englishArticles(50, in: try await fixture.source())
        await fixture.start()
        for id in ids {
            #expect(try await fixture.translation(id)?.state == .done)
        }
        let gate = SuspensionGate()
        gate.hold(.passCandidates(.simplifiedChinese))
        await fixture.translator.setSuspensionHook { await gate.arrive($0) }
        // The first Japanese request stays in flight while the old pass ends.
        fixture.service.hold(request: 4)

        // A Chinese pass is held at its read; then the language changes and
        // the Japanese pass fills the queue and sends its first 20.
        await fixture.translator.resume(after: .refreshEnded)
        await fixture.eventually { gate.reached(.passCandidates(.simplifiedChinese)) }
        await fixture.translator.configure(TranslationConfiguration(locale: .japanese, automatic: true))
        await fixture.eventually { fixture.service.requests.count == 4 }
        // The Chinese pass comes back (nothing waits in Chinese) and ends.
        gate.release(.passCandidates(.simplifiedChinese))
        await fixture.eventually { await fixture.translator.sideWorkRunning == 0 }
        fixture.service.release(request: 4)
        await fixture.translator.settled()

        var japanese = 0
        for id in ids where try await fixture.translation(id, .japanese)?.state == .done {
            japanese += 1
        }
        #expect(japanese == 50)
        #expect(fixture.service.requests.count == 6)
    }

    @Test("a slot repaired while a set-up failure reads the slots for its pause: no pause, no block, the repaired slot translates")
    func setUpPauseAfterRepair() async throws {
        let repaired = "repaired.example.invalid"
        let service = TranslationService { host, _, _ in host == Self.primary ? .status(401) : .texts(TranslationService.marked) }
        let fixture = try await TranslatorFixture.make(service: service)
        defer { fixture.remove() }
        let gate = SuspensionGate()
        gate.hold(.setUpSlots)
        await fixture.translator.setSuspensionHook { await gate.arrive($0) }
        let id = try await fixture.article("Story one", in: try await fixture.source())
        await fixture.translator.configure(TranslationConfiguration(locale: .simplifiedChinese, automatic: true))
        await fixture.eventually { gate.reached(.setUpSlots) }
        try await fixture.saveSlot(.primary, host: repaired)
        await fixture.translator.resume(after: .slotsChanged)
        gate.release(.setUpSlots)
        await fixture.translator.settled()

        #expect(await fixture.translator.pausedBy == nil)
        #expect(fixture.blocked[id] == nil)
        #expect(fixture.service.requests.map(\.host) == [Self.primary, repaired])
        #expect(try await fixture.translation(id)?.title == "T:Story one")
    }

    @Test("a slot repaired while a service failure looks for a backup: no pause, no block, no backup; the repaired slot translates",
          arguments: [false, true])
    func backupCheckAfterRepair(_ backup: Bool) async throws {
        let repaired = "repaired.example.invalid"
        let service = TranslationService { host, _, _ in host == Self.primary ? .status(503) : .texts(TranslationService.marked) }
        let fixture = try await TranslatorFixture.make(service: service, backup: backup)
        defer { fixture.remove() }
        let gate = SuspensionGate()
        gate.hold(.backupCheck)
        await fixture.translator.setSuspensionHook { await gate.arrive($0) }
        let id = try await fixture.article("Story one", in: try await fixture.source())
        await fixture.translator.configure(TranslationConfiguration(locale: .simplifiedChinese, automatic: true))
        await fixture.eventually { gate.reached(.backupCheck) }
        try await fixture.saveSlot(.primary, host: repaired)
        await fixture.translator.resume(after: .slotsChanged)
        gate.release(.backupCheck)
        await fixture.translator.settled()

        #expect(await fixture.translator.pausedBy == nil, "backup: \(backup)")
        #expect(fixture.blocked[id] == nil, "backup: \(backup)")
        #expect(fixture.service.requests.map(\.host) == [Self.primary, repaired], "backup: \(backup)")
        #expect(try await fixture.translation(id)?.title == "T:Story one", "backup: \(backup)")
    }

    @Test("a slot repaired while a failed batch's rows are written: the batch does not pause the repaired slot")
    func failedBatchAfterRepair() async throws {
        let repaired = "repaired.example.invalid"
        // Every model refuses: the repaired one too.
        let service = TranslationService { _, _, _ in .refusal }
        let fixture = try await TranslatorFixture.make(service: service)
        defer { fixture.remove() }
        let gate = SuspensionGate()
        gate.hold(.failedRowsWrite)
        await fixture.translator.setSuspensionHook { await gate.arrive($0) }
        _ = try await fixture.englishArticles(2, in: try await fixture.source())
        // The batch of two is refused, then its first half: held before its
        // failed row is written.
        await fixture.translator.configure(TranslationConfiguration(locale: .simplifiedChinese, automatic: true))
        await fixture.eventually { gate.reached(.failedRowsWrite) }
        try await fixture.saveSlot(.primary, host: repaired)
        await fixture.translator.resume(after: .slotsChanged)
        gate.release(.failedRowsWrite)
        await fixture.translator.settled()

        // The second half went to the repaired slot; the old slot's refusals
        // pause nothing.
        #expect(fixture.service.requests.map(\.host) == [Self.primary, Self.primary, repaired])
        #expect(await fixture.translator.pausedBy == nil)
    }

    // MARK: - Criterion 7

    @Test("criterion 7: at the limit no automatic request is sent, not a backup attempt either; the reason is the daily limit")
    func limitBeforeBackup() async throws {
        let service = TranslationService { host, _, _ in host == Self.primary ? .status(429) : .texts(TranslationService.marked) }
        let fixture = try await TranslatorFixture.make(service: service, backup: true)
        defer { fixture.remove() }
        try await fixture.library.setDailyAutomaticLimit(1)
        let ids = try await fixture.englishArticles(2, in: try await fixture.source())
        await fixture.start()
        #expect(fixture.service.requests.map(\.host) == [Self.primary])
        #expect(fixture.blocked == Dictionary(uniqueKeysWithValues: ids.map { ($0, .dailyLimit) }))
        #expect(try await fixture.translationCount() == 0)
    }

    @Test("criterion 7: at the limit not a half either; the limit lifts when the day changes; a manual retry sends and is not counted")
    func limitBeforeHalvesAndManual() async throws {
        let service = TranslationService { _, _, number in number == 1 ? .refusal : .texts(TranslationService.marked) }
        let fixture = try await TranslatorFixture.make(service: service)
        defer { fixture.remove() }
        try await fixture.library.setDailyAutomaticLimit(1)
        let source = try await fixture.source()
        let ids = try await fixture.englishArticles(4, in: source)
        await fixture.start()
        #expect(fixture.service.requests.count == 1, "no half after the refusal")
        #expect(fixture.blocked.values.allSatisfy { $0 == .dailyLimit })
        #expect(fixture.blocked.count == 4)

        // A manual retry at the limit sends and stores, and is not counted.
        #expect(await fixture.translator.retry(ids[0], backup: false) == .stored)
        #expect(fixture.service.requests.count == 2)
        #expect(try await fixture.translation(ids[0])?.state == .done)
        // Usage rows of one moment are in no particular order.
        #expect(try await fixture.usage().map(\.automatic).sorted { !$0 && $1 } == [false, true])
        #expect(try await fixture.library.automaticRequestCount(since: .distantPast) == 1)

        // Still the same day: nothing automatic.
        await fixture.resume(.refreshEnded)
        #expect(fixture.service.requests.count == 2)

        // The next day the limit lifts.
        fixture.clock.advance(seconds: 86_400)
        await fixture.resume(.refreshEnded)
        #expect(fixture.service.requests.count == 3)
        for id in ids {
            #expect(try await fixture.translation(id)?.state == .done)
        }
    }

    // MARK: - Criterion 8

    @Test("criterion 8: never more than one request in flight; an article gets at most two primary and one backup request")
    func oneInFlight() async throws {
        let service = TranslationService(delay: .milliseconds(20)) { host, texts, _ in
            if host == Self.primary {
                return texts.contains { $0.contains("refuse") } ? .refusal : .status(503)
            }
            return texts.contains { $0.contains("refuse") } ? .refusal : .texts(TranslationService.marked)
        }
        let fixture = try await TranslatorFixture.make(service: service, backup: true)
        defer { fixture.remove() }
        let source = try await fixture.source()
        let plain = try await fixture.englishArticles(30, in: source)
        let refused = try await fixture.article("A story they refuse", in: source)
        await fixture.translator.configure(TranslationConfiguration(locale: .simplifiedChinese, automatic: true))
        async let asked: Void = fixture.translator.ask(Array(plain.reversed()))
        async let manual = fixture.translator.retry(plain[3], backup: false)
        async let resumed: Void = fixture.translator.resume(after: .refreshEnded)
        _ = await (asked, manual, resumed)
        await fixture.translator.settled()
        #expect(fixture.service.mostInFlight == 1)
        for id in plain + [refused] {
            let title = try await fixture.library.article(id).title ?? ""
            let primaryRequests = fixture.service.requests(to: Self.primary).filter { $0.texts.contains(title) }.count
            let backupRequests = fixture.service.requests(to: Self.backup).filter { $0.texts.contains(title) }.count
            // A manual retry is its own piece of work.
            let allowedPrimary = id == plain[3] ? 4 : 2
            let allowedBackup = id == plain[3] ? 2 : 1
            #expect(primaryRequests <= allowedPrimary, "\(title)")
            #expect(backupRequests <= allowedBackup, "\(title)")
        }
    }

    // MARK: - Criterion 9

    @Test("criterion 9: automatic off globally or for the source sends nothing; on for the source overrides the global switch")
    func automaticSwitches() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let following = try await fixture.source("Following", autoTranslate: .inherit)
        let on = try await fixture.source("On", autoTranslate: .on)
        let off = try await fixture.source("Off", autoTranslate: .off)
        let a = try await fixture.article("Following story", in: following)
        let b = try await fixture.article("Always story", in: on)
        let c = try await fixture.article("Never story", in: off)
        await fixture.start(automatic: false)
        await fixture.ask([a, c])
        #expect(fixture.service.requests.flatMap(\.texts) == ["Always story"])
        #expect(try await fixture.translation(a) == nil)
        #expect(try await fixture.translation(c) == nil)
        #expect(try await fixture.translation(b)?.title == "T:Always story")

        await fixture.translator.configure(TranslationConfiguration(locale: .simplifiedChinese, automatic: true))
        await fixture.translator.settled()
        #expect(try await fixture.translation(a)?.state == .done, "turning the switch on resumes")
        await fixture.ask([c])
        #expect(try await fixture.translation(c) == nil, "off for the source")
    }

    @Test("criterion 9: during any pause Simplified articles get none and Traditional ones are converted")
    func judgingDuringPause() async throws {
        let service = TranslationService { _, _, _ in .status(503) }
        let fixture = try await TranslatorFixture.make(service: service)
        defer { fixture.remove() }
        let source = try await fixture.source()
        _ = try await fixture.article("A foreign story", in: source)
        await fixture.start()
        #expect(await fixture.translator.pausedBy == .service(.serverError))
        let simplified = try await fixture.article("国务院发布新的数据安全管理条例", excerpt: "条例明确了数据处理者的责任。", in: source)
        let traditional = try await fixture.article("台灣半導體產業持續擴張", excerpt: "業者表示，新廠將於明年開始量產。", in: source)
        let foreign = try await fixture.article("Another foreign story", in: source)
        await fixture.ask([simplified, traditional, foreign])
        #expect(fixture.service.requests.count == 1)
        #expect(try await fixture.translation(simplified) == StoredTranslation(state: .none, title: nil, excerpt: nil, failure: nil))
        #expect(try await fixture.translation(traditional)
            == StoredTranslation(state: .done, title: "台湾半导体产业持续扩张", excerpt: "业者表示，新厂将于明年开始量产。", failure: nil))
        let raw = try #require(try await fixture.rawTranslation(traditional))
        #expect(raw.model == nil, "no model was called")
        #expect(fixture.blocked[foreign] == .service(.serverError))
    }

    // MARK: - Criterion 10

    @Test("criterion 10: a new reading locale keeps the old rows, shows none of them, and translates the rows on screen in the new one")
    func localeChange() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let source = try await fixture.source()
        let ids = try await fixture.englishArticles(3, in: source)
        await fixture.start()
        #expect(try await fixture.translationCount() == 3)
        #expect(fixture.service.requests.last?.system.contains("Simplified Chinese (zh-Hans)") == true)

        await fixture.translator.setRowsOnScreen([ids[0]])
        await fixture.translator.configure(TranslationConfiguration(locale: .japanese, automatic: true))
        await fixture.translator.settled()
        #expect(fixture.service.requests.last?.system.contains("Japanese (ja)") == true)
        #expect(try await fixture.translation(ids[0], .japanese)?.state == .done)
        #expect(try await fixture.translation(ids[0], .simplifiedChinese)?.state == .done, "the old row is kept")
        let rows = try await fixture.library.articleRows(.library, filter: .all, translationsIn: .japanese)
        #expect(rows.allSatisfy { $0.translation?.title?.hasPrefix("T:") ?? true })
        #expect(try await fixture.translationCount() == 6, "the pass translated the rest in the new locale")

        // English originals under `en` need nothing.
        await fixture.translator.configure(TranslationConfiguration(locale: .english, automatic: true))
        await fixture.translator.settled()
        #expect(try await fixture.translation(ids[0], .english) == StoredTranslation(state: .none, title: nil, excerpt: nil, failure: nil))
    }

    @Test("a reply that arrives after the locale changed is stored under the locale it was asked for")
    func localeChangeDuringRequest() async throws {
        let service = TranslationService()
        service.hold(request: 1)
        let fixture = try await TranslatorFixture.make(service: service)
        defer { fixture.remove() }
        let id = try await fixture.article("A story", in: try await fixture.source())
        await fixture.translator.configure(TranslationConfiguration(locale: .simplifiedChinese, automatic: true))
        await fixture.eventually { fixture.service.requests.count == 1 }
        await fixture.translator.configure(TranslationConfiguration(locale: .japanese, automatic: true))
        service.release(request: 1)
        await fixture.translator.settled()
        #expect(try await fixture.translation(id, .simplifiedChinese)?.state == .done)
        #expect(try await fixture.translation(id, .japanese)?.state == .done)
        #expect(fixture.service.requests.map { $0.system.contains("(ja)") } == [false, true])
    }

    // MARK: - Criterion 13

    @Test("criterion 13: a translator works on its models' library; a library without models of its own sends nothing and writes no usage row")
    @MainActor
    func partition() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        // A second library on the same store: the adult one.
        let store = LibraryStore(directory: fixture.directory.appending(path: "second"), now: fixture.clock.now)
        let adult = try await store.createAdultLibrary()
        let adultCategory = try await adult.createCategory(name: "Adult", icon: .folder)
        let adultSource = Sample.source(in: adultCategory.id, url: "https://adult.example.invalid/feed", name: "Adult", at: fixture.clock.now())
        try await adult.insert(adultSource)
        var adultIDs: [UUID] = []
        for number in 1...5 {
            let article = Sample.article(in: adultSource.id, externalID: "adult-\(number)", title: "Adult story \(number)", at: fixture.clock.now())
            try await adult.insert(article)
            adultIDs.append(article.id)
        }
        #expect(fixture.models.belong(to: fixture.library))
        #expect(!fixture.models.belong(to: adult))

        // The normal translator, asked for the adult articles by identifier,
        // finds nothing of them: it reads its own library.
        await fixture.start()
        await fixture.ask(adultIDs)
        await fixture.resume(.refreshEnded)
        #expect(fixture.service.requests.isEmpty)
        #expect(try await fixture.usage().isEmpty)
        let adultRows = try await adult.pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM translation") ?? -1 }
        let adultUsage = try await adult.pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage") ?? -1 }
        #expect(adultRows == 0)
        #expect(adultUsage == 0)
        // A refresh of the adult library sends no request either.
        let transport = CountingTransport { url in
            let item: String = "<item><guid>fresh</guid><title>Fresh adult story</title></item>"
            return TransportResponse(finalURL: url, status: 200, headers: [:], body: Data(rssDocument(item).utf8))
        }
        _ = try await Refresher(library: adult, transport: transport).refresh(.library)
        await fixture.resume(.refreshEnded)
        #expect(fixture.service.requests.isEmpty)
        #expect(try await fixture.usage().isEmpty)
    }

    // MARK: - Criterion 15 and the rest

    @Test("criterion 15: a title of 100,000 characters and a character of 100,000 scalars are cut before they are sent")
    func cutBeforeSending() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let source = try await fixture.source()
        let heavy = "e" + String(repeating: "\u{301}", count: 99_999)
        try await fixture.article(String(repeating: "word ", count: 20_000), excerpt: heavy, in: source)
        await fixture.start()
        let texts = try #require(fixture.service.requests.first?.texts)
        #expect(texts.count == 2)
        #expect(texts[0].count <= TextLanguage.titleCharacters)
        #expect(texts[1].unicodeScalars.count <= TextLanguage.maximumScalars)
    }

    @Test("an article deleted while its request is in flight loses only its own result")
    func deletedDuringRequest() async throws {
        let service = TranslationService()
        service.hold(request: 1)
        let fixture = try await TranslatorFixture.make(service: service)
        defer { fixture.remove() }
        let source = try await fixture.source()
        let ids = try await fixture.englishArticles(3, in: source)
        await fixture.translator.configure(TranslationConfiguration(locale: .simplifiedChinese, automatic: true))
        await fixture.eventually { fixture.service.requests.count == 1 }
        try await fixture.library.pool.write { db in
            try db.execute(sql: "DELETE FROM article WHERE id = ?", arguments: [ids[1].databaseKey])
        }
        service.release(request: 1)
        await fixture.translator.settled()
        #expect(try await fixture.translation(ids[0])?.state == .done)
        #expect(try await fixture.translation(ids[2])?.state == .done)
        #expect(try await fixture.translationCount() == 2)
        #expect(fixture.stored == [ids[0], ids[2]])
    }

    @Test("results that cannot be stored pause sending, and nothing is shown")
    func storageFailurePauses() async throws {
        let fixture = try await TranslatorFixture.make(backup: true)
        defer { fixture.remove() }
        let ids = try await fixture.englishArticles(2, in: try await fixture.source())
        try await fixture.library.pool.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_translation BEFORE INSERT ON translation BEGIN SELECT RAISE(FAIL, 'refused by the test'); END;")
        }
        await fixture.start()
        #expect(fixture.service.requests.count == 1, "not sent again, not to the backup")
        #expect(await fixture.translator.pausedBy == .storage)
        #expect(fixture.blocked == Dictionary(uniqueKeysWithValues: ids.map { ($0, .storage) }))
    }

    @Test("an automatic request whose usage row cannot be written pauses sending for storage: the daily limit is not passed by uncounted requests")
    func usageNotRecordedPauses() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        try await fixture.library.setDailyAutomaticLimit(1)
        // 25 articles: two requests (20 and 5) without the pause.
        let ids = try await fixture.englishArticles(25, in: try await fixture.source())
        try await fixture.library.pool.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_usage BEFORE INSERT ON usage BEGIN SELECT RAISE(FAIL, 'refused by the test'); END;")
        }
        await fixture.start()
        #expect(fixture.service.requests.count == 1, "at most one uncounted automatic request")
        #expect(try await fixture.usage().isEmpty)
        #expect(await fixture.translator.pausedBy == .storage)
        #expect(Set(fixture.blocked.keys) == Set(ids))
        #expect(fixture.blocked.values.allSatisfy { $0 == .storage })

        // A request the owner asks for goes on as before, uncounted.
        #expect(await fixture.translator.retry(ids[0], backup: false) == .stored)
        #expect(fixture.service.requests.count == 2)
    }

    @Test("an accepted backup reply that cannot be stored is not reported as stored, and the pause stays")
    func backupReplyNotStored() async throws {
        let service = TranslationService { host, _, _ in host == Self.primary ? .status(503) : .texts(TranslationService.marked) }
        let fixture = try await TranslatorFixture.make(service: service, backup: true)
        defer { fixture.remove() }
        let id = try await fixture.article("A story", in: try await fixture.source())
        try await fixture.library.pool.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_translation BEFORE INSERT ON translation BEGIN SELECT RAISE(FAIL, 'refused by the test'); END;")
        }
        await fixture.start()
        #expect(fixture.service.requests.map(\.host) == [Self.primary, Self.backup])
        #expect(await fixture.translator.pausedBy == .storage)

        // A manual retry: the primary fails, the backup answers, the store
        // fails: said as a storage failure, and the pause is not ended.
        #expect(await fixture.translator.retry(id, backup: false) == .notStored(.storage))
        #expect(fixture.service.requests.map(\.host) == [Self.primary, Self.backup, Self.primary, Self.backup])
        #expect(await fixture.translator.pausedBy == .storage)
        #expect(try await fixture.translation(id) == nil)
    }

    @Test("stopping cancels the request in flight and stores nothing; nothing starts afterwards")
    func stopping() async throws {
        // Held until the stop cancels it.
        let service = TranslationService()
        service.hold(request: 1)
        let fixture = try await TranslatorFixture.make(service: service)
        defer { fixture.remove() }
        let id = try await fixture.article("A story", in: try await fixture.source())
        await fixture.translator.configure(TranslationConfiguration(locale: .simplifiedChinese, automatic: true))
        await fixture.eventually { fixture.service.requests.count == 1 }
        await fixture.translator.stop()
        try await fixture.eventually { try await !fixture.usage().isEmpty }
        #expect(try await fixture.translationCount() == 0)
        #expect(try await fixture.usage().map(\.outcome) == [.cancelled])
        await fixture.ask([id])
        await fixture.resume(.slotsChanged)
        #expect(await fixture.translator.retry(id, backup: false) == .cancelled)
        #expect(fixture.service.requests.count == 1)
    }

    @Test("the events: the articles in a request while it is in flight, then the stored rows")
    func events() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        let ids = try await fixture.englishArticles(2, in: try await fixture.source())
        await fixture.start()
        #expect(fixture.reported == [.requesting(Set(ids)), .requesting([]), .stored(Set(ids))])
    }

    // MARK: - RD15 decision 10: translateIfWaiting

    @Test("RD15 criterion 11: translateIfWaiting sends one manual request for a waiting article, none when a row exists, and is not limited")
    func translateIfWaiting() async throws {
        let fixture = try await TranslatorFixture.make()
        defer { fixture.remove() }
        try await fixture.library.setDailyAutomaticLimit(0)
        // A source with automatic titles off.
        let source = try await fixture.source(autoTranslate: .off)
        let waiting = try await fixture.article("A waiting story about the harbour", in: source)
        await fixture.start()
        #expect(fixture.service.requests.isEmpty)
        #expect(await fixture.translator.translateIfWaiting(waiting) == .stored)
        #expect(fixture.service.requests.count == 1)
        #expect(try await fixture.translation(waiting)?.state == .done)
        #expect(try await fixture.usage().map(\.automatic) == [false])
        // A row exists now: nothing is sent.
        #expect(await fixture.translator.translateIfWaiting(waiting) == .notWaiting)
        #expect(fixture.service.requests.count == 1)
        // A failed row counts as a row: it waits for Retry.
        let refused = try await fixture.article("A refused story", in: source)
        try await fixture.library.storeTranslations([
            TranslationRecord(articleID: refused, locale: .simplifiedChinese, state: .failed, title: nil, excerpt: nil, failure: .refused, model: "m"),
        ])
        #expect(await fixture.translator.translateIfWaiting(refused) == .notWaiting)
        #expect(fixture.service.requests.count == 1)
    }

    @Test("RD15 criterion 11: translateIfWaiting while an automatic request holds the article sends nothing more")
    func translateIfWaitingAfterAutomatic() async throws {
        let service = TranslationService()
        service.hold(request: 1)
        let fixture = try await TranslatorFixture.make(service: service)
        defer { fixture.remove() }
        let source = try await fixture.source()
        let id = try await fixture.article("An automatic story about the harbour", in: source)
        await fixture.translator.configure(TranslationConfiguration(locale: .simplifiedChinese, automatic: true))
        await fixture.eventually { fixture.service.requests.count == 1 }
        let manual = Task { await fixture.translator.translateIfWaiting(id) }
        // The manual job is queued while the worker holds the article; only
        // then is the automatic request let go.
        await fixture.eventually { await fixture.translator.manualJobsQueued == 1 }
        #expect(fixture.service.requests.count == 1)
        service.release(request: 1)
        #expect(await manual.value == .notWaiting)
        await fixture.translator.settled()
        #expect(fixture.service.requests.count == 1)
        #expect(try await fixture.translation(id)?.state == .done)
    }

    private static func rfc822(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}
