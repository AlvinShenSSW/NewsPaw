import Foundation
import GRDB
@testable import NewsPawKit
import Synchronization
import Testing

/// A model service stand-in for translation requests: it reads each
/// request's texts and answers by a rule given per host, records every
/// request with its host and texts, and counts the requests in flight.
final class TranslationService: ModelHTTP {
    /// What a host answers for the texts of one request.
    enum Answer: Sendable {
        /// A completion whose texts are `transform` of each text.
        case texts(@Sendable ([String]) -> [String], finishReason: String = "stop")
        /// A completion with this content as it is.
        case content(String, finishReason: String = "stop")
        /// A completion with a refusal.
        case refusal
        case status(Int)
        case failure(ModelHTTPFailure)
    }

    struct Request: Sendable {
        let host: String
        let texts: [String]
        let system: String
        /// The request's body as sent.
        var body: Data? = nil
    }

    typealias Rule = @Sendable (_ host: String, _ texts: [String], _ number: Int) -> Answer

    private struct State {
        var requests: [Request] = []
        var inFlight = 0
        var mostInFlight = 0
    }

    private let state = Mutex(State())
    private let rule: Mutex<Rule>

    /// Requests held until released by number (the first is 1).
    private struct Holds {
        var held: Set<Int> = []
        var released: Set<Int> = []
        var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    }

    private let holds = Mutex(Holds())
    /// How long each request takes.
    let delay: Duration

    init(delay: Duration = .zero, _ rule: @escaping Rule = { _, texts, _ in .texts(TranslationService.marked) }) {
        self.delay = delay
        self.rule = Mutex(rule)
    }

    func answer(with rule: @escaping Rule) {
        self.rule.withLock { $0 = rule }
    }

    /// Request `number` waits, once it has arrived, until `release(_:)` or
    /// until its task is cancelled (it then throws `CancellationError`, as
    /// a cancelled request does). Tests that need a request in flight hold
    /// it instead of giving it a delay that a slow runner could outlast.
    func hold(request number: Int) {
        holds.withLock { _ = $0.held.insert(number) }
    }

    func release(request number: Int) {
        let waiting = holds.withLock { holds in
            holds.released.insert(number)
            return holds.waiting.removeValue(forKey: number)
        }
        waiting?.resume()
    }

    /// "T:" before each text.
    static let marked: @Sendable ([String]) -> [String] = { $0.map { "T:" + $0 } }

    var requests: [Request] {
        state.withLock { $0.requests }
    }

    var mostInFlight: Int {
        state.withLock { $0.mostInFlight }
    }

    func requests(to host: String) -> [Request] {
        requests.filter { $0.host == host }
    }

    func send(_ request: ModelHTTPRequest) async throws -> ModelHTTPResponse {
        let host = request.url.host() ?? ""
        var texts: [String] = []
        var system = ""
        if let body = request.body, let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
           let messages = object["messages"] as? [[String: Any]] {
            system = messages.first?["content"] as? String ?? ""
            if let user = messages.last?["content"] as? String {
                texts = ChatWire.texts(in: user) ?? []
            }
        }
        let number = state.withLock { state in
            state.requests.append(Request(host: host, texts: texts, system: system, body: request.body))
            state.inFlight += 1
            state.mostInFlight = max(state.mostInFlight, state.inFlight)
            return state.requests.count
        }
        defer { state.withLock { $0.inFlight -= 1 } }
        if holds.withLock({ $0.held.contains(number) }) {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let now = holds.withLock { holds in
                        guard !holds.released.contains(number) else { return true }
                        holds.waiting[number] = continuation
                        return false
                    }
                    if now {
                        continuation.resume()
                    }
                }
            } onCancel: {
                release(request: number)
            }
            try Task.checkCancellation()
        }
        if delay > .zero {
            try await Task.sleep(for: delay)
        } else {
            await Task.yield()
        }
        let answer = rule.withLock { $0 }(host, texts, number)
        switch answer {
        case .texts(let transform, let finishReason):
            return ModelHTTPResponse(status: 200, headers: [:], body: completionBody(ChatWire.jsonArray(transform(texts)), finishReason: finishReason))
        case .content(let content, let finishReason):
            return ModelHTTPResponse(status: 200, headers: [:], body: completionBody(content, finishReason: finishReason))
        case .refusal:
            return ModelHTTPResponse(status: 200, headers: [:], body: completionBody(nil, refusal: "I can't help with that."))
        case .status(let status):
            return ModelHTTPResponse(status: status, headers: [:], body: Data(#"{"error":{"message":"stub"}}"#.utf8))
        case .failure(let failure):
            throw failure
        }
    }
}

/// Holds the translator at one of its suspension points
/// (`TitleTranslator.SuspensionPoint`), the first time it gets there, until
/// the test releases it: the race tests hold an interleaving instead of
/// sleeping for it.
typealias SuspensionGate = HoldGate<TitleTranslator.SuspensionPoint>

/// Holds a worker at one of its suspension points, the first time it gets
/// there, until the test releases it (the translator's and, RD23, the
/// overview writer's).
final class HoldGate<Point: Hashable & Sendable>: Sendable {

    private struct State {
        var held: Set<Point> = []
        var reached: Set<Point> = []
        var released: Set<Point> = []
        var waiting: [Point: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = Mutex(State())

    func hold(_ point: Point) {
        state.withLock { _ = $0.held.insert(point) }
    }

    func reached(_ point: Point) -> Bool {
        state.withLock { $0.reached.contains(point) }
    }

    /// Whether a worker is held at `point` now (a later arrival than the
    /// first one `reached` reports).
    func isHolding(_ point: Point) -> Bool {
        state.withLock { $0.waiting[point] != nil }
    }

    func release(_ point: Point) {
        let waiting = state.withLock { state in
            state.released.insert(point)
            return state.waiting.removeValue(forKey: point)
        }
        waiting?.resume()
    }

    /// The worker's hook.
    func arrive(_ point: Point) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = state.withLock { state in
                state.reached.insert(point)
                guard state.held.contains(point), !state.released.contains(point) else { return true }
                state.waiting[point] = continuation
                return false
            }
            if now {
                continuation.resume()
            }
        }
    }
}

/// A sleep the tests end by hand: what the service pause waits with.
final class ManualSleeper: Sendable {
    private let waiting = Mutex<[(Duration, CheckedContinuation<Void, any Error>)]>([])
    private let asked = Mutex<[Duration]>([])

    func sleep(_ duration: Duration) async throws {
        asked.withLock { $0.append(duration) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            waiting.withLock { $0.append((duration, continuation)) }
        }
    }

    /// The durations asked for so far.
    var durations: [Duration] {
        asked.withLock { $0 }
    }

    var sleepers: Int {
        waiting.withLock { $0.count }
    }

    /// Ends every sleep waiting now.
    func wake() {
        let all = waiting.withLock { waiting in
            defer { waiting = [] }
            return waiting
        }
        for (_, continuation) in all {
            continuation.resume()
        }
    }
}

/// A library with sources and articles, its models over a
/// `TranslationService`, and a translator on an injected clock, calendar
/// and sleep, with the events it reported.
final class TranslatorFixture: @unchecked Sendable {
    static let primaryHost = "primary.example.invalid"
    static let backupHost = "backup.example.invalid"

    let directory: URL
    let clock: TestClock
    let library: Library
    let keys: InMemoryKeyStore
    let service: TranslationService
    let models: LibraryModels
    let sleeper = ManualSleeper()
    let translator: TitleTranslator
    let category: UUID
    private let events = Mutex<[TranslatorEvent]>([])
    private var sequence = 0

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private init(directory: URL, clock: TestClock, library: Library, keys: InMemoryKeyStore, service: TranslationService, category: UUID) {
        self.directory = directory
        self.clock = clock
        self.library = library
        self.keys = keys
        self.service = service
        self.category = category
        models = LibraryModels(library: library, keys: keys, http: service)
        let sleeper = sleeper
        translator = TitleTranslator(models: models, now: clock.now, calendar: Self.calendar, sleep: { try await sleeper.sleep($0) })
    }

    /// - Parameters:
    ///   - primary: whether a primary model is set up.
    ///   - backup: whether a backup model is set up.
    static func make(
        service: TranslationService = TranslationService(), primary: Bool = true, backup: Bool = false
    ) async throws -> TranslatorFixture {
        let directory = try makeTemporaryDirectory()
        let clock = TestClock()
        let library = try await LibraryStore(directory: directory, cacheRoot: directory.appending(path: "Images"), now: clock.now)
            .openNormal()
        let category = try await library.createCategory(name: "News", icon: .newspaper)
        let fixture = TranslatorFixture(
            directory: directory, clock: clock, library: library, keys: InMemoryKeyStore(), service: service, category: category.id
        )
        if primary {
            try await fixture.saveSlot(.primary)
        }
        if backup {
            try await fixture.saveSlot(.backup)
        }
        await fixture.translator.setObserver { [weak fixture] event in
            fixture?.events.withLock { $0.append(event) }
        }
        return fixture
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    func saveSlot(_ role: ModelRole, host: String? = nil, key text: String? = "sk-translate-0123456789") async throws {
        let host = host ?? (role == .primary ? Self.primaryHost : Self.backupHost)
        try await models.save(
            ModelSlotDraft(role: role, preset: .custom, address: "https://\(host)/v1", model: "\(role.rawValue)-model", newKey: text.map(key)),
            testedOutcome: nil
        )
    }

    var reported: [TranslatorEvent] {
        events.withLock { $0 }
    }

    /// The last blocked map reported.
    var blocked: [UUID: TranslationBlock] {
        for event in reported.reversed() {
            if case .blocked(let map) = event {
                return map
            }
        }
        return [:]
    }

    /// Every article reported stored.
    var stored: Set<UUID> {
        reported.reduce(into: Set<UUID>()) { result, event in
            if case .stored(let ids) = event {
                result.formUnion(ids)
            }
        }
    }

    // MARK: - Content

    func source(_ name: String = "Source", autoTranslate: AutoTranslate = .inherit, category: UUID? = nil) async throws -> UUID {
        var source = Sample.source(
            in: category ?? self.category, url: "https://\(name.lowercased())-\(UUID().uuidString.prefix(6)).example.invalid/feed",
            name: name, at: clock.now()
        )
        source.autoTranslate = autoTranslate
        try await library.insert(source)
        return source.id
    }

    /// Inserts an article; later ones are newer, so the newest is the last
    /// inserted.
    @discardableResult
    func article(_ title: String?, excerpt: String? = nil, in source: UUID) async throws -> UUID {
        sequence += 1
        let at = clock.now().addingTimeInterval(TimeInterval(sequence))
        let article = Article(
            id: UUID(), sourceID: source, externalID: "item-\(sequence)-\(UUID().uuidString)", url: nil, title: title, excerpt: excerpt,
            author: nil, imageURL: nil, publishedAt: at, firstSeenAt: at, language: nil, readAt: nil, starredAt: nil
        )
        try await library.insert(article)
        return article.id
    }

    /// `count` English articles named "Story NN", oldest first.
    func englishArticles(_ count: Int, in source: UUID, excerpt: (Int) -> String? = { "Summary of story \($0)." }) async throws -> [UUID] {
        var ids: [UUID] = []
        for number in 1...count {
            ids.append(try await article(String(format: "Story %02d about the harbour", number), excerpt: excerpt(number), in: source))
        }
        return ids
    }

    // MARK: - Reading back

    func translation(_ id: UUID, _ locale: ReadingLocale = .simplifiedChinese) async throws -> StoredTranslation? {
        try await library.translations(of: [id], locale: locale)[id]
    }

    /// The stored columns of a row, as text.
    struct RawTranslation: Sendable {
        let state: String?
        let error: String?
        let model: String?
    }

    func rawTranslation(_ id: UUID, _ locale: ReadingLocale = .simplifiedChinese) async throws -> RawTranslation? {
        try await library.pool.read { db in
            try Row.fetchOne(
                db, sql: "SELECT state, error, model FROM translation WHERE article_id = ? AND locale = ?",
                arguments: [id.databaseKey, locale.rawValue]
            ).map { RawTranslation(state: $0["state"], error: $0["error"], model: $0["model"]) }
        }
    }

    func translationCount() async throws -> Int {
        try await library.pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM translation") ?? 0 }
    }

    func usage() async throws -> [UsageRecord] {
        try await library.usageRecords()
    }

    /// Configures the translator and waits until it has nothing left to do.
    func start(_ locale: ReadingLocale = .simplifiedChinese, automatic: Bool = true) async {
        await translator.configure(TranslationConfiguration(locale: locale, automatic: automatic))
        await translator.settled()
    }

    func resume(_ trigger: TranslationTrigger) async {
        await translator.resume(after: trigger)
        await translator.settled()
    }

    func ask(_ ids: [UUID]) async {
        await translator.ask(ids)
        await translator.settled()
    }

    /// How long `eventually` waits at most: a bound a stalled runner does
    /// not reach (CI saw a first request take over five seconds); a passing
    /// test returns as soon as its condition holds.
    static let eventualBound = Duration.seconds(120)

    /// Waits, `eventualBound` at most, until `condition` holds: for what the
    /// translator does from a task of its own (a pause's timer, a request
    /// that is being cancelled, the first request after `configure`).
    func eventually(_ condition: @escaping () async throws -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async rethrows {
        let deadline = ContinuousClock.now + Self.eventualBound
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("the condition did not hold within \(Self.eventualBound)", sourceLocation: sourceLocation)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The articles of each request, by the texts of `ids`' titles it holds.
    func titles(of request: TranslationService.Request) -> [String] {
        request.texts.filter { $0.hasPrefix("Story ") }
    }
}
