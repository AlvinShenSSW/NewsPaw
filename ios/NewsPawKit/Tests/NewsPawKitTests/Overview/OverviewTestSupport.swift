import Foundation
import GRDB
@testable import NewsPawKit
import Synchronization
import Testing

typealias OverviewGate = HoldGate<OverviewWriter.SuspensionPoint>

/// A library with categories, sources and articles, its models over a
/// `TranslationService`, and an overview writer on an injected clock and
/// calendar, with the events it reported.
final class OverviewFixture: @unchecked Sendable {
    static let primaryHost = "primary.example.invalid"
    static let backupHost = "backup.example.invalid"

    let directory: URL
    let clock: TestClock
    let calendar: Calendar
    let library: Library
    let keys: InMemoryKeyStore
    /// The key store the models read: the keys above, with a hook on a read.
    let keyReads: HookedKeyStore
    let service: TranslationService
    let models: LibraryModels
    let writer: OverviewWriter
    let gate = OverviewGate()
    /// The app's state the writer reads: in front unless a test sets it.
    let front: AppFront
    private let events = Mutex<[OverviewEvent]>([])
    private let counter = Mutex(0)

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private init(
        directory: URL, clock: TestClock, calendar: Calendar, library: Library, keys: InMemoryKeyStore, hooked: HookedKeyStore,
        service: TranslationService, models: LibraryModels, inFront: Bool
    ) {
        front = AppFront(isInFront: inFront)
        self.directory = directory
        self.clock = clock
        self.calendar = calendar
        self.library = library
        self.keys = keys
        keyReads = hooked
        self.service = service
        self.models = models
        writer = OverviewWriter(models: models, front: front, now: clock.now, calendar: calendar)
    }

    /// - Parameters:
    ///   - primary: whether a primary model is set up.
    ///   - backup: whether a backup model is set up.
    ///   - adult: whether the library is an adult one (its own store).
    static func make(
        service: TranslationService = TranslationService(OverviewFixture.goodRule), primary: Bool = true, backup: Bool = false,
        calendar: Calendar = OverviewFixture.utc, locale: ReadingLocale? = .simplifiedChinese, inFront: Bool = true
    ) async throws -> OverviewFixture {
        let directory = try makeTemporaryDirectory()
        let clock = TestClock()
        let library = try await LibraryStore(directory: directory, cacheRoot: directory.appending(path: "Images"), now: clock.now)
            .openNormal()
        let keys = InMemoryKeyStore()
        let hooked = HookedKeyStore(keys)
        let fixture = OverviewFixture(
            directory: directory, clock: clock, calendar: calendar, library: library, keys: keys, hooked: hooked, service: service,
            models: LibraryModels(library: library, keys: hooked, http: service), inFront: inFront
        )
        if primary {
            try await fixture.saveSlot(.primary)
        }
        if backup {
            try await fixture.saveSlot(.backup)
        }
        await fixture.writer.setObserver { [weak fixture] event in
            fixture?.events.withLock { $0.append(event) }
        }
        let gate = fixture.gate
        await fixture.writer.setSuspensionHook { point in await gate.arrive(point) }
        if let locale {
            await fixture.writer.configure(locale: locale)
        }
        return fixture
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    func saveSlot(_ role: ModelRole, host: String? = nil, model: String? = nil, key text: String? = "sk-overview-0123456789") async throws {
        let host = host ?? (role == .primary ? Self.primaryHost : Self.backupHost)
        try await models.save(
            ModelSlotDraft(
                role: role, preset: .custom, address: "https://\(host)/v1", model: model ?? "\(role.rawValue)-model", newKey: text.map(key)
            ),
            testedOutcome: nil
        )
    }

    // MARK: - Replies

    /// A summary and highlights for articles 1 and 2.
    static let goodRule: TranslationService.Rule = { _, _, _ in .content(reply(["Summary of the day.", "[1] First matters.", "[2] Second matters."])) }

    /// The JSON content of a reply with `texts`.
    static func reply(_ texts: [String]) -> String {
        #"{"texts":\#(ChatWire.jsonArray(texts))}"#
    }

    // MARK: - Content

    func category(_ name: String = "News", mode: OverviewMode = .auto) async throws -> UUID {
        let category = try await library.createCategory(name: name, icon: .newspaper)
        if mode != .auto {
            try await library.setCategoryOverview(category.id, to: mode)
        }
        return category.id
    }

    func source(in category: UUID, name: String = "Source") async throws -> UUID {
        let source = Sample.source(
            in: category, url: "https://\(name.lowercased())-\(UUID().uuidString.prefix(8)).example.invalid/feed", name: name, at: clock.now()
        )
        try await library.insert(source)
        return source.id
    }

    /// Inserts an article first seen (and published) at `at`, else at the
    /// clock's time plus a step, so that later ones are newer.
    @discardableResult
    func article(
        _ title: String?, excerpt: String? = nil, in source: UUID, at: Date? = nil, url: String? = nil, author: String? = nil
    ) async throws -> UUID {
        let step = counter.withLock { value in
            value += 1
            return value
        }
        let time = at ?? clock.now().addingTimeInterval(TimeInterval(step))
        let article = Article(
            id: UUID(), sourceID: source, externalID: "item-\(step)-\(UUID().uuidString)", url: url, title: title, excerpt: excerpt,
            author: author, imageURL: nil, publishedAt: time, firstSeenAt: time, language: nil, readAt: nil, starredAt: nil
        )
        try await library.insert(article)
        return article.id
    }

    /// `count` articles named "<prefix> story NN", oldest first.
    func articles(_ count: Int, in source: UUID, prefix: String = "News", at: Date? = nil) async throws -> [UUID] {
        var ids: [UUID] = []
        for number in stride(from: 1, through: count, by: 1) {
            ids.append(try await article(
                "\(prefix) story " + String(format: "%02d", number), excerpt: "Excerpt \(number).", in: source, at: at
            ))
        }
        return ids
    }

    /// A category with one source and `count` articles first seen now,
    /// titled after the category.
    func filledCategory(_ name: String = "News", mode: OverviewMode = .auto, articles count: Int = 3) async throws -> (UUID, UUID, [UUID]) {
        let category = try await category(name, mode: mode)
        let source = try await source(in: category, name: name)
        let ids = try await articles(count, in: source, prefix: name)
        return (category, source, ids)
    }

    /// The overview requests whose first article is titled after `name`.
    func requests(for name: String) -> [TranslationService.Request] {
        overviewRequests.filter { $0.texts.first?.hasPrefix("[1] \(name) story") == true }
    }

    /// Moves the clock to `date`.
    func setClock(to date: Date) {
        clock.advance(seconds: Int(date.timeIntervalSince(clock.now()).rounded()))
    }

    /// Makes every usage insert fail, as a full disk would.
    func failUsageWrites() async throws {
        try await library.pool.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_usage BEFORE INSERT ON usage BEGIN SELECT RAISE(FAIL, 'refused by the test'); END;")
        }
    }

    // MARK: - Running

    func runDue() async {
        await writer.runDue()
        await writer.settled()
    }

    /// The app enters the background as the app makes it: the state is
    /// set first, then the writer's job in flight is cancelled.
    func enterBackground() async {
        front.set(isInFront: false)
        await writer.enteredBackground()
    }

    func write(_ category: UUID) async -> OverviewWriteOutcome {
        let outcome = await writer.write(category: category)
        await writer.settled()
        return outcome
    }

    var today: String {
        OverviewDay.key(for: clock.now(), calendar: calendar)
    }

    // MARK: - Reading back

    var reported: [OverviewEvent] {
        events.withLock { $0 }
    }

    /// The last blocked map reported.
    var blocked: [UUID: OverviewBlock] {
        for event in reported.reversed() {
            if case .blocked(let map) = event {
                return map
            }
        }
        return [:]
    }

    var lastWorking: Set<UUID>? {
        for event in reported.reversed() {
            if case .working(let ids) = event {
                return ids
            }
        }
        return nil
    }

    /// The stored columns of a row.
    struct RawOverview: Sendable, Hashable {
        let category: String
        let day: String
        let locale: String
        let state: String
        let text: String?
        let highlights: String
        let articleCount: Int
        let coveredUntil: String?
        let model: String?
        let error: String?
    }

    func rows() async throws -> [RawOverview] {
        try await library.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM overview ORDER BY day, locale, category_id").map { row in
                RawOverview(
                    category: row["category_id"], day: row["day"], locale: row["locale"], state: row["state"], text: row["text"],
                    highlights: row["highlights"], articleCount: row["article_count"], coveredUntil: row["covered_until"],
                    model: row["model"], error: row["error"]
                )
            }
        }
    }

    func rows(of category: UUID) async throws -> [RawOverview] {
        try await rows().filter { $0.category == category.databaseKey }
    }

    func usage() async throws -> [UsageRecord] {
        try await library.usageRecords()
    }

    /// The requests that were overview requests.
    var overviewRequests: [TranslationService.Request] {
        service.requests.filter { $0.system.contains(OverviewPrompt.openingPhrase) }
    }

    /// Waits, a bound a stalled runner does not reach, until `condition`
    /// holds.
    func eventually(_ condition: @escaping () async throws -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async rethrows {
        let deadline = ContinuousClock.now + TranslatorFixture.eventualBound
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("the condition did not hold within \(TranslatorFixture.eventualBound)", sourceLocation: sourceLocation)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Waits until the writer is held at `point`.
    func reach(_ point: OverviewWriter.SuspensionPoint, sourceLocation: SourceLocation = #_sourceLocation) async {
        let gate = gate
        await eventually({ gate.reached(point) }, sourceLocation: sourceLocation)
    }

    /// Waits until the service has received `count` requests.
    func requested(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        let service = service
        await eventually({ service.requests.count >= count }, sourceLocation: sourceLocation)
    }
}

/// The fixture's keys, read through a hook (review round 4): the next read
/// first runs the hook once, inside `LibraryModels.send` after its slot read
/// and before the transport, where the tests change the app's state.
final class HookedKeyStore: KeyStore {
    private let inner: InMemoryKeyStore
    private let hook = Mutex<(@Sendable () -> Void)?>(nil)

    init(_ inner: InMemoryKeyStore) {
        self.inner = inner
    }

    var partition: Partition { inner.partition }

    /// Runs `hook` at the next read, once.
    func onNextRead(_ hook: @escaping @Sendable () -> Void) {
        self.hook.withLock { $0 = hook }
    }

    func add(_ key: SecretKey) throws -> String { try inner.add(key) }

    func read(_ reference: String) throws -> SecretKey? {
        let next = hook.withLock { hook in
            defer { hook = nil }
            return hook
        }
        next?()
        return try inner.read(reference)
    }

    func remove(_ reference: String) throws { try inner.remove(reference) }

    func removeAll() throws { try inner.removeAll() }
}
