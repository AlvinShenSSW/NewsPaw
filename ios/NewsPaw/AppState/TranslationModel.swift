import Foundation
import NewsPawKit

/// What a row's warning mark explains, asked from its alert (RD14 decision
/// 9): a stored failure, or a block of the translator.
enum TranslationQuestion: Identifiable, Equatable {
    case failed(UUID, TranslationFailure)
    case blocked(UUID, TranslationBlock)

    var article: UUID {
        switch self {
        case .failed(let id, _), .blocked(let id, _): id
        }
    }

    var id: String {
        switch self {
        case .failed(let id, let failure): "failed.\(id).\(failure.rawValue)"
        case .blocked(let id, let block): "blocked.\(id).\(block)"
        }
    }
}

/// What a row shows of its translation's work (decision 9's table).
enum TranslationMark: Equatable {
    /// In a request, or a manual retry was just tapped.
    case working
    /// A stored failure, or a block with a reason to show.
    case warning(TranslationQuestion)
}

/// Translation for one workspace (spec N06; RD14 decisions 7, 9, 10 and
/// 12): the translator of the workspace's library, the articles in a
/// request and the blocked ones with their reasons as the rows read them,
/// the rows on screen, and the calls the rows and the triggers use. Made
/// only for a workspace whose library has its own models; a workspace
/// without one shows originals.
@MainActor @Observable
final class TranslationModel {
    /// The articles of the request in flight.
    private(set) var inRequest: Set<UUID> = []
    /// The articles blocked now, with their reasons.
    private(set) var blocked: [UUID: TranslationBlock] = [:]
    /// The articles whose manual retry was tapped and has not ended.
    private(set) var retrying: Set<UUID> = []
    /// Whether the library's backup model is set up: "Retry with the
    /// Backup Model" is offered only then.
    private(set) var hasBackup = false
    /// The question of a row's warning mark, or of a retry that stored
    /// nothing, asked from the shell.
    var question: TranslationQuestion?

    let settings: TranslationSettings
    /// The translation of article bodies (RD15 decision 15), made from the
    /// same models: it exists exactly where this model does.
    let body: BodyTranslationModel

    @ObservationIgnored private let translator: TitleTranslator
    @ObservationIgnored private let models: LibraryModels
    @ObservationIgnored private weak var reading: ReadingModel?
    /// The rows on screen, as their appearing and disappearing report them.
    @ObservationIgnored private var onScreen: Set<UUID> = []
    /// The articles open on a reading screen, from its appearing to its
    /// disappearing: on screen as a row is, so that a resumption asks for
    /// them again.
    @ObservationIgnored private var openArticles: Set<UUID> = []
    /// What the translator is told is on screen.
    private var shown: Set<UUID> {
        onScreen.union(openArticles)
    }
    /// Rows asked for and not yet passed on, most recent last.
    @ObservationIgnored private var asked: [UUID] = []
    @ObservationIgnored private var gathering: Task<Void, Never>?
    @ObservationIgnored private var isStopped = false

    /// How long rows asking for their articles are gathered into one ask.
    static let gatheringTime = Duration.milliseconds(333)

    init(models: LibraryModels, settings: TranslationSettings, reading: ReadingModel, now: @escaping @Sendable () -> Date) {
        self.models = models
        self.settings = settings
        self.reading = reading
        translator = TitleTranslator(models: models, now: now)
        body = BodyTranslationModel(models: models, settings: settings, now: now)
        settings.addListener(self)
        body.translateTitle = { [weak self] id in
            self?.translateIfWaiting(id)
        }
    }

    /// Starts the translator with the settings: a first resumption.
    func start() async {
        await body.start()
        await refreshBackup()
        await translator.setObserver { [weak self] event in
            await self?.handle(event)
        }
        await translator.configure(settings.configuration)
    }

    // MARK: - What a row shows

    /// The mark of an article's row, from its stored state and this model.
    /// A library with no model set up shows no mark.
    func mark(for row: ArticleRow) -> TranslationMark? {
        if inRequest.contains(row.id) || retrying.contains(row.id) {
            return .working
        }
        if let translation = row.translation, translation.state == .failed {
            return .warning(.failed(row.id, translation.failure ?? .malformed))
        }
        // A block is shown only on a row waiting in the reading language: a
        // row with its translation in that language was not stopped by it
        // (a block of a request begun before the language was switched
        // back can arrive after the switch). A stored failure is shown above.
        if row.translation == nil, let block = blocked[row.id], block != .setUp(.noModelSetUp) {
            return .warning(.blocked(row.id, block))
        }
        return nil
    }

    // MARK: - Rows on screen (decision 7)

    func rowAppeared(_ row: ArticleRow) {
        onScreen.insert(row.id)
        if row.translation == nil {
            ask(row.id)
        }
    }

    func rowDisappeared(_ id: UUID) {
        onScreen.remove(id)
    }

    /// The reading screen asks for its article as a row does, and keeps it
    /// on screen while it is shown.
    func articleOpened(_ row: ArticleRow) {
        openArticles.insert(row.id)
        if row.translation == nil {
            ask(row.id)
        }
    }

    func articleClosed(_ id: UUID) {
        openArticles.remove(id)
    }

    private func ask(_ id: UUID) {
        guard !isStopped else { return }
        asked.removeAll { $0 == id }
        asked.append(id)
        guard gathering == nil else { return }
        gathering = Task { [weak self] in
            try? await Task.sleep(for: Self.gatheringTime)
            await self?.passAskedOn()
        }
    }

    private func passAskedOn() async {
        gathering = nil
        guard !isStopped else { return }
        let ids = Array(asked.reversed())
        asked = []
        await translator.setRowsOnScreen(shown)
        await translator.ask(ids)
    }

    // MARK: - Triggers (decisions 6 and 7)

    func refreshEnded() {
        resume(after: .refreshEnded)
    }

    func cameToFront() {
        resume(after: .cameToFront)
        body.cameToFront()
    }

    /// The app went to the background: the bodies' work stops (RD15,
    /// review round 2). Titles go on as RD14 has them.
    func appEnteredBackground() {
        guard !isStopped else { return }
        body.appEnteredBackground()
    }

    /// A slot was saved or removed, or its key removed: the library's
    /// failed rows were deleted with it, so the rows showing a failure wait
    /// again.
    func slotsChanged() {
        guard !isStopped else { return }
        reading?.failedTranslationsCleared()
        Task { await refreshBackup() }
        resume(after: .slotsChanged)
        body.slotsChanged()
    }

    func readingLocaleChanged() {
        guard !isStopped else { return }
        reading?.translationLocaleChanged()
        body.readingLocaleChanged()
        let configuration = settings.configuration
        let shown = shown
        Task {
            await translator.setRowsOnScreen(shown)
            await translator.configure(configuration)
        }
    }

    func automaticTranslationChanged() {
        guard !isStopped else { return }
        let configuration = settings.configuration
        let shown = shown
        Task {
            await translator.setRowsOnScreen(shown)
            await translator.configure(configuration)
        }
    }

    private func resume(after trigger: TranslationTrigger) {
        guard !isStopped else { return }
        let shown = shown
        Task {
            await translator.setRowsOnScreen(shown)
            await translator.resume(after: trigger)
        }
    }

    private func refreshBackup() async {
        let statuses = try? await models.statuses()
        hasBackup = statuses?[.backup].map { $0.key != .missing } ?? false
    }

    // MARK: - Manual retry (decision 10)

    /// "Retry" or "Retry with the Backup Model": the row shows the activity
    /// mark from the tap. A failure that stores nothing is said in an
    /// alert.
    func retry(_ id: UUID, backup: Bool) {
        guard !isStopped, !retrying.contains(id) else { return }
        question = nil
        retrying.insert(id)
        Task {
            let outcome = await translator.retry(id, backup: backup)
            retrying.remove(id)
            if case .notStored(let block) = outcome, !isStopped {
                question = .blocked(id, block)
            }
        }
    }

    /// The title of an article whose body is being translated (RD15
    /// decision 10): one manual request when it still waits by the time
    /// the worker takes it. The header updates through the stored event.
    func translateIfWaiting(_ id: UUID) {
        guard !isStopped else { return }
        let translator = translator
        Task { _ = await translator.translateIfWaiting(id) }
    }

    // MARK: - Events

    private func handle(_ event: TranslatorEvent) {
        guard !isStopped else { return }
        switch event {
        case .requesting(let ids):
            inRequest = ids
        case .blocked(let map):
            blocked = map
        case .stored(let ids):
            reading?.applyTranslations(of: ids)
        }
    }

    /// The workspace is dropped (RD18 decision 4): the request in flight is
    /// cancelled and nothing starts from here on.
    func stop() {
        isStopped = true
        gathering?.cancel()
        gathering = nil
        question = nil
        body.stop()
        let translator = translator
        Task { await translator.stop() }
    }
}
