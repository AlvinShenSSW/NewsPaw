import Foundation
import NewsPawKit
import UIKit

/// A manual job that stored nothing, or a failed Rewrite, asked from the
/// shell (decision 12).
struct OverviewQuestion: Identifiable, Equatable {
    let category: UUID
    let issue: OverviewIssue

    var id: String {
        "\(category).\(issue)"
    }
}

/// The daily overviews of one workspace (spec N07; RD23 decision 12): the
/// writer of its library, made from the workspace's own models (RD19), the
/// rows the cards read, the work and blocks the writer reports, and the
/// triggers. Calls reach the writer through one serial chain, so that a
/// change of language and a due check cannot reach it out of order.
@MainActor @Observable
final class OverviewModel {
    /// Today's row of each category in the reading language.
    private(set) var today: [UUID: StoredOverview] = [:]
    /// How many articles an overview of each category would be written from.
    private(set) var inputCounts: [UUID: Int] = [:]
    /// The categories queued or in flight, as the writer reports them.
    private(set) var working: Set<UUID> = []
    /// Write Overview, Rewrite or Retry tapped and not ended.
    private(set) var requested: Set<UUID> = []
    /// The writer's blocks.
    private(set) var blocks: [UUID: OverviewBlock] = [:]
    /// Whether the library has a primary slot.
    private(set) var hasPrimary = false
    /// Today's key, by the clock and the device's calendar.
    private(set) var day: String
    /// The list cards that are expanded (collapsed by default).
    var expandedListCards: Set<UUID> = []
    /// Today's cards whose summary is shown whole ("More").
    var expandedTodayCards: Set<UUID> = []
    /// The question of a manual job, asked from the shell.
    var question: OverviewQuestion?

    let settings: TranslationSettings
    /// The library's partition: the adult workspace's cards carry the
    /// adult accent through the environment, nothing else.
    let partition: Partition

    /// The writer, reached only through this chain (review round 1, G1).
    @ObservationIgnored private let chain: OverviewChain
    @ObservationIgnored private let library: Library
    @ObservationIgnored private let models: LibraryModels
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private weak var reading: ReadingModel?
    @ObservationIgnored private let navigation: NavigationModel
    @ObservationIgnored private var isReading = false
    @ObservationIgnored private var readAgain = false
    @ObservationIgnored private var midnight: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: NSObjectProtocol?
    @ObservationIgnored private var isStopped = false

    /// - Parameter models: the library's own models; another library's are
    ///   a programming error (RD23 decision 14).
    init(
        library: Library, models: LibraryModels, settings: TranslationSettings, reading: ReadingModel, navigation: NavigationModel,
        now: @escaping @Sendable () -> Date, calendar: Calendar = .autoupdatingCurrent
    ) {
        precondition(models.belong(to: library), "the models of another library")
        self.library = library
        self.models = models
        self.settings = settings
        self.reading = reading
        self.navigation = navigation
        self.now = now
        self.calendar = calendar
        partition = library.partition
        day = OverviewDay.key(for: now(), calendar: calendar)
        chain = OverviewChain(writer: OverviewWriter(models: models, now: now, calendar: calendar))
        settings.addListener(self)
    }

    /// Starts the writer with the reading language and reads the cards.
    func start() async {
        await chain.writer.setObserver { [weak self] event in
            await self?.handle(event)
        }
        let locale = settings.readingLocale
        enqueue { await $0.configure(locale: locale) }
        timeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.significantTimeChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dayMayHaveChanged() }
        }
        scheduleMidnight()
        await read()
    }

    // MARK: - What a card shows (decision 12)

    func state(of category: LibraryCategory) -> OverviewCardState {
        let id = category.id
        return OverviewCardRule.state(
            mode: category.overview, row: today[id], working: working.contains(id) || requested.contains(id), block: blocks[id],
            hasPrimary: hasPrimary, newCount: inputCounts[id] ?? 0, day: day, locale: settings.readingLocale
        )
    }

    /// The Earlier Overviews of a category: its `done` rows in the reading
    /// language of the days before today in the window, newest first.
    func earlier(_ category: UUID) async -> [StoredOverview] {
        let instant = now()
        let oldest = OverviewDay.oldestKept(instant, calendar: calendar)
        let today = OverviewDay.key(for: instant, calendar: calendar)
        return (try? await library.earlierOverviews(of: category, locale: settings.readingLocale, from: oldest, before: today)) ?? []
    }

    // MARK: - Actions

    /// Write Overview, Rewrite or Retry: a manual job. A failed Rewrite, or
    /// a job that stored nothing, is said in the shell's alert; a job whose
    /// category or articles went meanwhile shows the card afresh with no
    /// message.
    func write(_ category: UUID) {
        guard !isStopped, !requested.contains(category) else { return }
        question = nil
        requested.insert(category)
        let chain = chain
        Task {
            // After every call sent before it — a change of the reading
            // language included (review round 1, G1).
            let outcome = await chain.write(category: category)
            requested.remove(category)
            guard !isStopped else { return }
            switch outcome {
            case .failed(let failure):
                if today[category]?.state == .done {
                    question = OverviewQuestion(category: category, issue: .stored(failure))
                }
            case .notStored(let block):
                question = OverviewQuestion(category: category, issue: .blocked(block.reason))
            case .stored, .nothingNew, .gone, .cancelled:
                break
            }
            await read()
        }
    }

    /// A highlight was tapped: its article opens on the category's list
    /// through the reading model, and is marked read. From Today the
    /// category's list is selected first.
    func open(highlight: OverviewHighlight, category: UUID, fromToday: Bool) {
        guard !isStopped else { return }
        if fromToday {
            navigation.select(.category(category))
        }
        reading?.open(articleID: highlight.articleID, on: .category(category))
    }

    // MARK: - Triggers

    /// A foreground refresh run ended: the cards are read, then the due
    /// categories are written.
    func runEnded() {
        guard !isStopped else { return }
        Task {
            await read()
            enqueue { await $0.runDue() }
        }
    }

    /// A collection ended, the categories were read again, or the app
    /// came to the front: the cards are read again.
    func listsChanged() {
        guard !isStopped else { return }
        Task { await read() }
    }

    /// The app came to the front: the writer may take jobs again (it starts
    /// none), the cards are read and the day's change is waited for afresh.
    func cameToFront() {
        guard !isStopped else { return }
        enqueue { await $0.cameToFront() }
        dayMayHaveChanged()
    }

    /// The app entered the background (design: foreground only; review
    /// round 1, R1): the writer cancels its job in flight, drops its queue
    /// and refuses due checks and jobs until the app comes to the front.
    func enteredBackground() {
        guard !isStopped else { return }
        enqueue { await $0.enteredBackground() }
    }

    /// A slot of this library was saved or removed, or its key removed: its
    /// failed overviews were deleted with it. Starts nothing.
    func slotsChanged() {
        guard !isStopped else { return }
        enqueue { await $0.slotsChanged() }
        Task { await read() }
    }

    /// The reading language changed: the writer is told, and the cards are
    /// read in the new language.
    func readingLocaleChanged() {
        guard !isStopped else { return }
        let locale = settings.readingLocale
        enqueue { await $0.configure(locale: locale) }
        Task { await read() }
    }

    /// The workspace is dropped: the writer's job in flight is cancelled
    /// and nothing starts from here on.
    func stop() {
        isStopped = true
        question = nil
        midnight?.cancel()
        midnight = nil
        if let timeObserver {
            NotificationCenter.default.removeObserver(timeObserver)
        }
        timeObserver = nil
        let writer = chain.writer
        Task { await writer.stop() }
    }

    // MARK: - Reading

    /// Reads today's rows, the input counts and whether a primary slot
    /// exists, one read at a time: a read asked for during a read runs
    /// once more after it.
    func read() async {
        guard !isStopped else { return }
        if isReading {
            readAgain = true
            return
        }
        isReading = true
        defer { isReading = false }
        repeat {
            readAgain = false
            let instant = now()
            let key = OverviewDay.key(for: instant, calendar: calendar)
            let locale = settings.readingLocale
            let library = library
            let calendar = calendar
            let rows = try? await library.overviews(on: key, locale: locale)
            let counts = try? await library.overviewInputCounts(locale: locale, now: instant, calendar: calendar)
            let statuses = try? await models.statuses()
            guard !isStopped else { return }
            // A read of another language or day is not shown: the next
            // read (asked for by the change) is.
            if locale == settings.readingLocale {
                day = key
                if let rows {
                    today = rows
                }
                if let counts {
                    inputCounts = counts
                }
                if let statuses {
                    hasPrimary = statuses[.primary] != nil
                }
            }
        } while readAgain && !isStopped
    }

    private func handle(_ event: OverviewEvent) {
        guard !isStopped else { return }
        switch event {
        case .working(let ids):
            working = ids
        case .blocked(let map):
            blocks = map
        case .stored:
            Task { await read() }
        }
    }

    /// Sends a call to the writer after every call sent before it.
    private func enqueue(_ call: @escaping @Sendable (OverviewWriter) async -> Void) {
        chain.send(call)
    }

    // MARK: - The day (decision 3)

    /// The cards are read and the wait for the next local midnight starts
    /// again: at the coming to the front, at a significant time change, and
    /// at each midnight.
    private func dayMayHaveChanged() {
        guard !isStopped else { return }
        scheduleMidnight()
        Task { await read() }
    }

    private func scheduleMidnight() {
        midnight?.cancel()
        let instant = now()
        let wait = OverviewDay.nextStart(after: instant, calendar: calendar).timeIntervalSince(instant) + 1
        midnight = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(max(1, wait)))
            } catch {
                return
            }
            self?.dayMayHaveChanged()
        }
    }
}
