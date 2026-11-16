import Foundation
import NewsPawKit

/// Which open body a translation belongs to (RD15 decisions 5 and 14): a
/// library article's, or reader mode's temporary article's, which is never
/// stored.
enum BodyKey: Hashable {
    case article(UUID)
    case reader(UUID)

    var article: UUID? {
        if case .article(let id) = self { id } else { nil }
    }
}

/// What the bottom bar shows for a body's translation (decision 12).
enum BodyControl: Equatable {
    /// No translation in this workspace, or nothing to send or convert.
    case none
    /// Nothing translated or converted and no work running.
    case translate
    /// The display-mode menu.
    case modes
}

/// The banner above the body (decision 12): the sentence and its steps.
struct BodyBanner: Equatable {
    let sentence: String
    let steps: [TranslationWording.Step]
}

/// The progress line's numbers: chunks finished of chunks planned.
struct BodyProgress: Equatable {
    let finished: Int
    let total: Int
}

/// What Article Info says of a body's translation (decision 12).
enum BodyTranslationSummary: Equatable {
    case notTranslated
    case converted
    /// Every text sent is translated, by these models; the latest time.
    case translated(models: [String], at: Date)
    /// Some texts sent are not translated; those that are, by these models.
    case partly(models: [String], at: Date?)
}

/// Body translation for one workspace (spec N05, N06; RD15 decisions 5, 8,
/// 9 and 11–14): the body translator of the workspace's library, each open
/// body's plan, what arrived and what failed, its display mode and its
/// work; the counts of the screens showing each body; and what the reading
/// screen and reader mode read from it. Owned by the workspace's
/// `TranslationModel`, made from the same `LibraryModels`, so it exists
/// exactly where title translation does.
@MainActor @Observable
final class BodyTranslationModel {
    /// One open body.
    struct Opening {
        var blocks: [ArticleBlock]
        /// Reader mode's title, planned as the first segment.
        var title: String?
        var isExcerptFallback: Bool
        /// The language of `plan` and of what arrived.
        var locale: ReadingLocale
        /// `nil` while planning.
        var plan: BodyTranslationPlan?
        /// Translations by hash: stored, arrived, or the pre-filled excerpt.
        var done: [String: String] = [:]
        /// The model and time of each translation, for Article Info; `nil`
        /// model for the pre-filled excerpt (RD14's row tells).
        var details: [String: Detail] = [:]
        /// Stored failures (in memory only for reader mode).
        var failed: [String: TranslationFailure] = [:]
        var mode: ReadingDisplayMode
        /// The job running for this body.
        var job: UUID?
        /// The failed texts the running job sends again.
        var retrying: Set<String> = []
        /// The latest work's failure that stored nothing; cleared when new
        /// work starts.
        var stop: BodyTranslationStop?
        var lastEnd: BodyTranslationEnd?
        /// The owner started work in this opening (Translate, Retry).
        var ownerStarted = false
        /// Counts the plans made for this body.
        var generation = 0
        /// The texts filled from RD14's excerpt translation.
        var prefilled: Set<String> = []
    }

    struct Detail: Equatable {
        let model: String?
        let at: Date
    }

    private(set) var openings: [BodyKey: Opening] = [:]

    @ObservationIgnored private let translator: BodyTranslator
    @ObservationIgnored private let settings: TranslationSettings
    @ObservationIgnored private let now: @Sendable () -> Date
    /// How many screens show each body.
    @ObservationIgnored private var appearances: [BodyKey: Int] = [:]
    /// The body and plan generation of each job.
    @ObservationIgnored private var jobs: [UUID: (key: BodyKey, generation: Int)] = [:]
    /// The translator's calls, one after another, so that they reach it in
    /// the order they were made.
    @ObservationIgnored private var calls: Task<Void, Never>?
    @ObservationIgnored private var isStopped = false

    /// The display mode a new opening starts in: Settings › Reading's.
    @ObservationIgnored var defaultMode: @MainActor () -> ReadingDisplayMode = { .standard }
    /// The open article's RD14 row in the reading language, as the reading
    /// model holds it: whether its title waits, and its excerpt's
    /// translation for the pre-fill.
    @ObservationIgnored var titleTranslation: @MainActor (UUID) -> (waiting: Bool, translation: StoredTranslation?)? = { _ in nil }
    /// Translates a waiting title with the body (decision 10).
    @ObservationIgnored var translateTitle: @MainActor (UUID) -> Void = { _ in }

    init(models: LibraryModels, settings: TranslationSettings, now: @escaping @Sendable () -> Date) {
        translator = BodyTranslator(models: models)
        self.settings = settings
        self.now = now
    }

    func start() async {
        await translator.setObserver { [weak self] event in
            await self?.handle(event)
        }
    }

    // MARK: - Bodies

    /// The reading model settled an article's body (never the interim one
    /// while its page is fetched): it is planned, unless it is the body
    /// already planned in the reading language.
    func bodySettled(_ id: UUID, content: ReadingContent) {
        settle(.article(id), blocks: content.blocks, title: nil, isExcerptFallback: content.isExcerptFallback)
    }

    /// The reading model let an article's body go.
    func bodyDropped(_ id: UUID) {
        drop(.article(id))
    }

    /// Reader mode shows a temporary article: planned with its title
    /// first. Another temporary article no screen shows is let go.
    func readerShown(_ id: UUID, title: String, content: ReadingContent) {
        for key in openings.keys {
            if case .reader(let other) = key, other != id, appearances[key, default: 0] == 0 {
                drop(key)
            }
        }
        settle(.reader(id), blocks: content.blocks, title: title, isExcerptFallback: false)
    }

    private func settle(_ key: BodyKey, blocks: [ArticleBlock], title: String?, isExcerptFallback: Bool) {
        guard !isStopped else { return }
        if let opening = openings[key], opening.blocks == blocks, opening.title == title, opening.locale == settings.readingLocale {
            return
        }
        cancelJob(of: key)
        let previous = openings[key]
        openings[key] = Opening(
            blocks: blocks, title: title, isExcerptFallback: isExcerptFallback, locale: settings.readingLocale,
            mode: previous?.mode ?? defaultMode(), ownerStarted: previous?.ownerStarted ?? false, generation: previous?.generation ?? 0
        )
        plan(key)
    }

    private func drop(_ key: BodyKey) {
        cancelJob(of: key)
        openings[key] = nil
    }

    /// Plans the body in the reading language off the main actor, reads
    /// its stored rows (a library article's), then starts work under
    /// decision 5.
    private func plan(_ key: BodyKey) {
        guard var opening = openings[key] else { return }
        let locale = settings.readingLocale
        opening.generation += 1
        opening.locale = locale
        opening.plan = nil
        opening.done = [:]
        opening.details = [:]
        opening.failed = [:]
        opening.prefilled = []
        opening.stop = nil
        opening.lastEnd = nil
        opening.retrying = []
        let generation = opening.generation
        let blocks = opening.blocks
        let title = opening.title
        openings[key] = opening
        let translator = translator
        Task {
            let plan = await Self.makePlan(blocks, title: title, locale: locale)
            var stored: [String: StoredBodyText] = [:]
            var readFailed = false
            if let article = key.article {
                do {
                    stored = try await translator.storedTexts(ofArticle: article, locale: locale)
                } catch {
                    readFailed = true
                }
            }
            guard !isStopped, var opening = openings[key], opening.generation == generation else { return }
            opening.plan = plan
            let sent = plan.sentHashes
            for (hash, row) in stored where sent.contains(hash) {
                switch row.state {
                case .done:
                    opening.done[hash] = row.text
                    opening.details[hash] = Detail(model: row.model, at: row.updatedAt)
                case .failed:
                    opening.failed[hash] = row.failure ?? .malformed
                case .none:
                    break
                }
            }
            // The excerpt's translation stands for the excerpt put in as
            // the body (nothing is sent or written for it).
            if opening.isExcerptFallback, sent.count == 1, let hash = sent.first, opening.done[hash] == nil, let article = key.article,
               let translation = titleTranslation(article)?.translation, translation.state == .done,
               let excerpt = translation.excerpt, !excerpt.isEmpty {
                opening.done[hash] = excerpt
                opening.failed[hash] = nil
                opening.prefilled.insert(hash)
            }
            if readFailed {
                opening.stop = .read
            }
            openings[key] = opening
            if !readFailed {
                startIfDue(key)
            }
        }
    }

    @concurrent
    nonisolated private static func makePlan(_ blocks: [ArticleBlock], title: String?, locale: ReadingLocale) async -> BodyTranslationPlan {
        BodySegments.plan(blocks, title: title, locale: locale)
    }

    // MARK: - Screens

    func screenAppeared(_ key: BodyKey) {
        appearances[key, default: 0] += 1
        if appearances[key] == 1 {
            startIfDue(key)
        }
    }

    /// The last screen of a body went (back, another article, a link
    /// opened, a tab or partition switch): its work stops (N06).
    func screenDisappeared(_ key: BodyKey) {
        let left = appearances[key, default: 1] - 1
        appearances[key] = left > 0 ? left : nil
        if left <= 0 {
            cancelJob(of: key)
        }
    }

    private func isShown(_ key: BodyKey) -> Bool {
        appearances[key, default: 0] > 0
    }

    /// Decision 5: work over the waiting texts (sent, neither done nor
    /// failed) starts by itself when there is one and "Translate Articles
    /// When Opened" is on, or a text is done already, or the owner started
    /// work in this opening.
    private func startIfDue(_ key: BodyKey) {
        guard !isStopped, isShown(key), let opening = openings[key], let plan = opening.plan, opening.job == nil else { return }
        let waiting = plan.sentHashes.filter { opening.done[$0] == nil && opening.failed[$0] == nil }
        guard !waiting.isEmpty else { return }
        guard settings.translatesBodyOnOpen || !opening.done.isEmpty || opening.ownerStarted else { return }
        startJob(key, sending: waiting, route: .primary)
    }

    private func startJob(_ key: BodyKey, sending hashes: Set<String>, route: BodyTranslationJob.Route) {
        guard !isStopped, var opening = openings[key], let plan = opening.plan else { return }
        let job = BodyTranslationJob(article: key.article, locale: opening.locale, chunks: plan.chunks(sending: hashes), route: route)
        guard !job.chunks.isEmpty else { return }
        opening.job = job.id
        opening.stop = nil
        opening.retrying = hashes.intersection(opening.failed.keys)
        openings[key] = opening
        jobs[job.id] = (key, opening.generation)
        call { await $0.start(job) }
        if let article = key.article, titleTranslation(article)?.waiting == true {
            translateTitle(article)
        }
    }

    private func cancelJob(of key: BodyKey) {
        guard let job = openings[key]?.job else { return }
        call { await $0.cancel(job) }
    }

    private func call(_ operation: @escaping @Sendable (BodyTranslator) async -> Void) {
        let previous = calls
        let translator = translator
        calls = Task {
            await previous?.value
            await operation(translator)
        }
    }

    // MARK: - The owner's steps

    /// Translate and Retry: every text sent that is not done, failed and
    /// waiting, cancelling any work running.
    func translate(_ key: BodyKey) {
        guard var opening = openings[key], let plan = opening.plan else { return }
        opening.ownerStarted = true
        openings[key] = opening
        cancelJob(of: key)
        openings[key]?.job = nil
        startJob(key, sending: plan.sentHashes.filter { opening.done[$0] == nil }, route: .primary)
    }

    /// Retry with the Backup Model: the same texts, once each to the
    /// backup.
    func retryWithBackup(_ key: BodyKey) {
        guard var opening = openings[key], let plan = opening.plan else { return }
        opening.ownerStarted = true
        openings[key] = opening
        cancelJob(of: key)
        openings[key]?.job = nil
        startJob(key, sending: plan.sentHashes.filter { opening.done[$0] == nil }, route: .backupOnly)
    }

    // MARK: - Triggers

    /// The reading language changed: work is cancelled and every body is
    /// planned again in the new one (its old rows are kept, not shown).
    func readingLocaleChanged() {
        guard !isStopped else { return }
        for key in openings.keys {
            cancelJob(of: key)
            openings[key]?.job = nil
            plan(key)
        }
    }

    /// A slot changed: the failed rows were deleted with it; every body is
    /// planned again, and its failed texts wait again.
    func slotsChanged() {
        readingLocaleChanged()
    }

    /// The app came to the front: a shown body whose work stopped with a
    /// service failure or a cancellation starts again.
    func cameToFront() {
        guard !isStopped else { return }
        for (key, opening) in openings where isShown(key) && opening.job == nil {
            let resumes: Bool = switch opening.lastEnd {
            case .cancelled?, .stopped(.service)?: true
            default: false
            }
            guard resumes, let plan = opening.plan else { continue }
            let waiting = plan.sentHashes.filter { opening.done[$0] == nil && opening.failed[$0] == nil }
            if !waiting.isEmpty {
                startJob(key, sending: waiting, route: .primary)
            }
        }
    }

    /// The workspace is dropped: work is cancelled and nothing starts.
    func stop() {
        isStopped = true
        call { await $0.stop() }
    }

    // MARK: - Events

    private func handle(_ event: BodyTranslatorEvent) {
        guard !isStopped else { return }
        switch event {
        case .translated(let job, let texts, let model):
            guard let (key, generation) = jobs[job], var opening = openings[key], opening.generation == generation else { return }
            let at = now()
            for (hash, text) in texts {
                opening.done[hash] = text
                opening.details[hash] = Detail(model: model, at: at)
                opening.failed[hash] = nil
                opening.prefilled.remove(hash)
            }
            openings[key] = opening
        case .failed(let job, let failures):
            guard let (key, generation) = jobs[job], var opening = openings[key], opening.generation == generation else { return }
            opening.failed.merge(failures) { _, new in new }
            openings[key] = opening
        case .ended(let job, let end):
            defer { jobs[job] = nil }
            guard let (key, generation) = jobs[job], var opening = openings[key], opening.job == job else { return }
            opening.job = nil
            opening.retrying = []
            guard opening.generation == generation else {
                openings[key] = opening
                return
            }
            opening.lastEnd = end
            if case .stopped(let stop) = end {
                opening.stop = stop
            }
            openings[key] = opening
        }
    }

    // MARK: - What the screens read

    func mode(of key: BodyKey) -> ReadingDisplayMode {
        openings[key]?.mode ?? defaultMode()
    }

    func setMode(_ mode: ReadingDisplayMode, of key: BodyKey) {
        openings[key]?.mode = mode
    }

    /// `T`: the next mode, when the body has the mode menu.
    func cycleMode(of key: BodyKey) {
        guard control(for: key) == .modes, let mode = openings[key]?.mode else { return }
        openings[key]?.mode = mode.next
    }

    /// The text block `index` shows in Translation mode, or `nil` for its
    /// original.
    func translatedText(of index: Int, in key: BodyKey) -> String? {
        guard let opening = openings[key], let plan = opening.plan else { return nil }
        return plan.text(of: index, done: opening.done)
    }

    /// Whether a text sent or converted is shown translated.
    func hasTranslation(_ key: BodyKey) -> Bool {
        guard let opening = openings[key], let plan = opening.plan else { return false }
        return plan.hasConversion || plan.sentHashes.contains { opening.done[$0] != nil }
    }

    func control(for key: BodyKey) -> BodyControl {
        guard let opening = openings[key], let plan = opening.plan, plan.hasWork else { return .none }
        if !hasTranslation(key) && opening.job == nil {
            return .translate
        }
        return .modes
    }

    /// "Translating k of n" while work runs for the body.
    func progress(of key: BodyKey) -> BodyProgress? {
        guard let opening = openings[key], opening.job != nil, let plan = opening.plan, !plan.chunks.isEmpty else { return nil }
        return BodyProgress(finished: plan.finishedChunks(done: opening.done), total: plan.chunks.count)
    }

    /// The banner above the body (decision 12): the latest work's failure
    /// that stored nothing, else the first stored failure in reading order.
    func banner(of key: BodyKey, hasBackup: Bool) -> BodyBanner? {
        guard let opening = openings[key] else { return nil }
        let failedNow = (opening.plan?.chunks.flatMap { $0 } ?? []).filter {
            opening.failed[$0.hash] != nil && !opening.retrying.contains($0.hash)
        }
        let steps: [TranslationWording.Step]
        let reason: String
        if let stop = opening.stop {
            reason = BodyWording.sentence(stop)
            steps = BodyWording.isSetUp(stop) ? [.openSettings] : [.retry]
        } else if let first = failedNow.first, let failure = opening.failed[first.hash] {
            reason = TranslationWording.sentence(failure)
            steps = [.retry]
        } else {
            return nil
        }
        let refused = failedNow.contains { opening.failed[$0.hash] == .refused }
        let allSteps = steps.contains(.retry) && refused && hasBackup ? steps + [.retryWithBackup] : steps
        let partly = hasTranslation(key)
        let sentence = partly ? String(localized: "Some text could not be translated") + " · " + reason : reason
        return BodyBanner(sentence: sentence, steps: allSteps)
    }

    /// What Copy Translation copies, or `nil` when nothing is translated or
    /// converted.
    func copyText(of key: BodyKey, title: String) -> String? {
        guard hasTranslation(key), let opening = openings[key] else { return nil }
        return BodySegments.copyText(title: title, blocks: opening.blocks, plan: opening.plan, done: opening.done)
    }

    /// The first language the recognizer gives for an original block (or
    /// the title), for VoiceOver.
    func originalLanguage(of index: Int, in key: BodyKey) -> String? {
        openings[key]?.plan?.originalLanguages[index]
    }

    /// The body's translation as Article Info says it.
    func summary(of key: BodyKey, prefilledDetail: Detail?) -> BodyTranslationSummary {
        guard let opening = openings[key], let plan = opening.plan else { return .notTranslated }
        let sent = plan.sentHashes
        var details: [Detail] = sent.compactMap { opening.details[$0] }
        if let prefilledDetail, !opening.prefilled.isEmpty {
            details.append(prefilledDetail)
        }
        let models = Array(Set(details.compactMap(\.model))).sorted()
        let latest = details.map(\.at).max()
        let doneCount = sent.filter { opening.done[$0] != nil }.count
        if sent.isEmpty {
            return plan.hasConversion ? .converted : .notTranslated
        }
        if doneCount == 0 {
            return plan.hasConversion ? .converted : .notTranslated
        }
        if doneCount < sent.count {
            return .partly(models: models, at: latest)
        }
        return .translated(models: models, at: latest ?? now())
    }

    /// Whether the body's excerpt was filled from RD14's row.
    func isPrefilled(_ key: BodyKey) -> Bool {
        !(openings[key]?.prefilled.isEmpty ?? true)
    }

    /// The article's title translation details, from the translator's
    /// library.
    func titleDetails(of article: UUID) async -> TitleTranslationDetails? {
        try? await translator.titleDetails(ofArticle: article, locale: settings.readingLocale)
    }

    var readingLocale: ReadingLocale {
        settings.readingLocale
    }
}

/// The wording of a body's work that stopped with nothing stored
/// (decision 12; RD14's sentences, and one of its own for a read).
enum BodyWording {
    static func sentence(_ stop: BodyTranslationStop) -> String {
        switch stop {
        case .service(let failure): TranslationWording.sentence(.service(failure))
        case .setUp(let failure): TranslationWording.sentence(.setUp(failure))
        case .storage: TranslationWording.sentence(.storage)
        case .read: String(localized: "The translation could not be read.")
        }
    }

    static func isSetUp(_ stop: BodyTranslationStop) -> Bool {
        if case .setUp = stop { true } else { false }
    }
}
