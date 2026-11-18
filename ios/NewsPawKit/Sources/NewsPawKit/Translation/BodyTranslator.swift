import Foundation

/// A piece of body translation work (RD15 decision 8): the chunks to send,
/// in reading order, each holding only the segments being sent; the
/// reading language; the article (none for reader mode, whose results are
/// never stored); and which model is asked.
public struct BodyTranslationJob: Sendable, Hashable {
    public enum Route: Sendable, Hashable {
        /// The primary, with one retry of a rejected chunk and one attempt
        /// on a usable backup after a service failure (decision 7).
        case primary
        /// Retry with the Backup Model: each chunk once to the backup, no
        /// retry and no further fallback.
        case backupOnly
    }

    public let id: UUID
    public let article: UUID?
    public let locale: ReadingLocale
    public let chunks: [[BodySegment]]
    public let route: Route

    public init(id: UUID = UUID(), article: UUID?, locale: ReadingLocale, chunks: [[BodySegment]], route: Route) {
        self.id = id
        self.article = article
        self.locale = locale
        self.chunks = chunks
        self.route = route
    }
}

/// Why a piece of work stopped with nothing stored for what was left
/// (decision 7).
public enum BodyTranslationStop: Sendable, Hashable {
    /// `limited`, `serverError` or `unreachable`, the primary's reason when
    /// the backup failed too or there is none.
    case service(ModelFailure)
    /// `noModelSetUp`, `keyNeeded`, `keyRejected` or `modelNotFound`.
    case setUp(ModelFailure)
    /// The rows, the article or the slots could not be read.
    case read
    /// The results could not be written.
    case storage
}

/// How a piece of work ended.
public enum BodyTranslationEnd: Sendable, Hashable {
    /// Every chunk was sent: each text is done or failed.
    case finished
    case stopped(BodyTranslationStop)
    /// The article is not in the translator's library (any more): nothing
    /// was sent, or the result was dropped.
    case gone
    /// Cancelled (the screen left, the workspace stopped, the language
    /// changed, other work started): nothing of the request in flight was
    /// stored.
    case cancelled
}

/// What the body translator reports, in order, through its one callback.
public enum BodyTranslatorEvent: Sendable, Hashable {
    /// Accepted translations of a chunk or a part of one, by hash: stored
    /// for an article (or not, when the work then stops for storage).
    case translated(job: UUID, [String: String], model: String)
    /// Texts the model refused or answered unusably, by hash, stored as
    /// failed for an article.
    case failed(job: UUID, [String: TranslationFailure])
    case ended(job: UUID, BodyTranslationEnd)
}

/// Translates article bodies of one library (spec N06, N11; RD15 decisions
/// 6–8): made from a `LibraryModels` alone and working on that object's
/// library, so that a body of one library goes only through its own
/// models. One job at a time, one request in flight: a new job cancels the
/// running one and waits for it to end before it sends. Every request is a
/// usage row with `purpose = body` and `automatic = 0`; none is counted by
/// or held at the daily automatic limit.
public actor BodyTranslator {
    private let models: LibraryModels
    private let library: Library
    private var observer: (@Sendable (BodyTranslatorEvent) async -> Void)?
    private var isStopped = false
    /// Counts the jobs started: a job whose number is no longer the latest
    /// writes and reports nothing more after an `await`.
    private var generation = 0
    private var current: Task<Void, Never>?
    /// The job of `current`.
    private var currentJob: UUID?

    public init(models: LibraryModels) {
        self.models = models
        library = models.library
    }

    // MARK: - The app's calls

    public func setObserver(_ observer: @escaping @Sendable (BodyTranslatorEvent) async -> Void) {
        self.observer = observer
    }

    /// Starts `job`, cancelling the work running; it sends once that work
    /// has ended. After `stop()` the job ends at once, cancelled.
    public func start(_ job: BodyTranslationJob) {
        guard !isStopped else {
            report(.ended(job: job.id, .cancelled))
            return
        }
        let previous = current
        previous?.cancel()
        generation += 1
        let generation = generation
        currentJob = job.id
        current = Task {
            self.waitingForPrevious += 1
            await previous?.value
            self.waitingForPrevious -= 1
            let end = await self.work(job, generation: generation)
            self.report(.ended(job: job.id, end))
        }
    }

    /// Cancels the work running, if any: nothing of its request in flight is
    /// stored.
    public func cancel() {
        generation += 1
        current?.cancel()
    }

    /// Cancels job `id` if it is the work running (or waiting to run).
    public func cancel(_ id: UUID) {
        if currentJob == id {
            cancel()
        }
    }

    /// The workspace is dropped: the work running is cancelled and nothing
    /// starts from here on.
    public func stop() {
        isStopped = true
        cancel()
    }

    /// The article's stored texts in `locale`, from this translator's
    /// library.
    public func storedTexts(ofArticle id: UUID, locale: ReadingLocale) async throws -> [String: StoredBodyText] {
        try await library.bodyTranslations(ofArticle: id, locale: locale)
    }

    /// Retry after a failed write (RD15 review round 4): stores, as done,
    /// translations of an article that were accepted and shown but whose
    /// rows could not be written, with the model of each. Nothing is sent.
    ///
    /// - Returns: whether they are stored (false when the write fails
    ///   again or the article is gone).
    public func storeAccepted(_ texts: [String: String], models: [String: String], ofArticle id: UUID, locale: ReadingLocale) async -> Bool {
        let records = texts.map { hash, text in
            BodyTextRecord(hash: hash, state: .done, text: text, failure: nil, model: models[hash])
        }
        return await write(records, article: id, locale: locale) == .written
    }

    /// The article's title translation (RD14's row) in `locale`, from this
    /// translator's library: what an excerpt shown as the body is pre-filled
    /// from, read in the opening's own language.
    public func titleTranslation(ofArticle id: UUID, locale: ReadingLocale) async throws -> StoredTranslation? {
        try await library.translations(of: [id], locale: locale)[id]
    }

    /// The article's title translation's state, model and time in `locale`,
    /// from this translator's library (Article Info).
    public func titleDetails(ofArticle id: UUID, locale: ReadingLocale) async throws -> TitleTranslationDetails? {
        try await library.titleTranslationDetails(ofArticle: id, locale: locale)
    }

    // MARK: - The work

    /// Whether the job of `generation` may still write and report.
    private func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation && !isStopped && !Task.isCancelled
    }

    /// What a chunk or part leaves the work with.
    private enum Step {
        case next
        case end(BodyTranslationEnd)
    }

    private func work(_ job: BodyTranslationJob, generation: Int) async -> BodyTranslationEnd {
        guard isCurrent(generation) else { return .cancelled }
        var chunks = job.chunks
        if let article = job.article {
            // The article must be this library's (RD14 decision 12's rule).
            let exists: Bool
            let stored: [String: StoredBodyText]
            do {
                exists = try await library.articleExists(article)
                // Read once the work before has ended: rows it wrote after
                // the app planned this job are not sent again.
                stored = exists ? try await library.bodyTranslations(ofArticle: article, locale: job.locale) : [:]
            } catch {
                return isCurrent(generation) ? .stopped(.read) : .cancelled
            }
            guard isCurrent(generation) else { return .cancelled }
            guard exists else { return .gone }
            let sending = Set(chunks.flatMap { $0.map(\.hash) })
            let done = stored.filter { sending.contains($0.key) && $0.value.state == .done }
            if !done.isEmpty {
                for (model, rows) in Dictionary(grouping: done, by: { $0.value.model ?? "" }) {
                    report(.translated(job: job.id, Dictionary(uniqueKeysWithValues: rows.compactMap { key, row in row.text.map { (key, $0) } }), model: model))
                }
                chunks = chunks.map { $0.filter { done[$0.hash] == nil } }
            }
        }
        for chunk in chunks where !chunk.isEmpty {
            guard isCurrent(generation) else { return .cancelled }
            let step = switch job.route {
            case .primary: await sendToPrimary(chunk, job: job, generation: generation)
            case .backupOnly: await sendToBackupOnly(chunk, job: job, generation: generation)
            }
            if case .end(let end) = step {
                return end
            }
        }
        return isCurrent(generation) ? .finished : .cancelled
    }

    /// A chunk to the primary: a rejected reply is retried once as two
    /// halves (one text as itself); a service failure goes once to a
    /// usable backup. A text is in at most two primary requests and one
    /// backup request.
    private func sendToPrimary(_ chunk: [BodySegment], job: BodyTranslationJob, generation: Int) async -> Step {
        switch await attempt(chunk, role: .primary, job: job) {
        case .accepted(let entries, let model):
            return await accept(chunk, entries: entries, model: model, job: job, generation: generation)
        case .content:
            let parts = chunk.count > 1 ? [Array(chunk[..<(chunk.count / 2)]), Array(chunk[(chunk.count / 2)...])] : [chunk]
            for part in parts {
                guard isCurrent(generation) else { return .end(.cancelled) }
                let step: Step = switch await attempt(part, role: .primary, job: job) {
                case .accepted(let entries, let model): await accept(part, entries: entries, model: model, job: job, generation: generation)
                case .content(let failure): await fail(part, failure, job: job, generation: generation)
                case .service(let failure): await sendToBackup(part, after: failure, job: job, generation: generation)
                case .setUp(let failure): .end(.stopped(.setUp(failure)))
                case .read: .end(.stopped(.read))
                case .cancelled: .end(.cancelled)
                }
                if case .end = step {
                    return step
                }
            }
            return .next
        case .service(let failure):
            return await sendToBackup(chunk, after: failure, job: job, generation: generation)
        case .setUp(let failure):
            return .end(.stopped(.setUp(failure)))
        case .read:
            return .end(.stopped(.read))
        case .cancelled:
            return .end(.cancelled)
        }
    }

    /// After a service failure of the primary: once to a usable backup (a
    /// backup slot whose key is not missing), no retry there. Without one,
    /// or when the backup fails with a service or set-up failure, the work
    /// stops with the primary's reason.
    private func sendToBackup(_ part: [BodySegment], after failure: ModelFailure, job: BodyTranslationJob, generation: Int) async -> Step {
        let statuses: [ModelRole: ModelSlotStatus]
        do {
            statuses = try await models.statuses()
        } catch {
            return .end(isCurrent(generation) ? .stopped(.read) : .cancelled)
        }
        guard isCurrent(generation) else { return .end(.cancelled) }
        guard let backup = statuses[.backup], backup.key != .missing else {
            return .end(.stopped(.service(failure)))
        }
        switch await attempt(part, role: .backup, job: job) {
        case .accepted(let entries, let model):
            return await accept(part, entries: entries, model: model, job: job, generation: generation)
        case .content(let reason):
            return await fail(part, reason, job: job, generation: generation)
        case .service, .setUp:
            return .end(.stopped(.service(failure)))
        case .read:
            return .end(.stopped(.read))
        case .cancelled:
            return .end(.cancelled)
        }
    }

    /// Retry with the Backup Model: once to the backup.
    private func sendToBackupOnly(_ chunk: [BodySegment], job: BodyTranslationJob, generation: Int) async -> Step {
        switch await attempt(chunk, role: .backup, job: job) {
        case .accepted(let entries, let model):
            return await accept(chunk, entries: entries, model: model, job: job, generation: generation)
        case .content(let reason):
            return await fail(chunk, reason, job: job, generation: generation)
        case .service(let failure):
            return .end(.stopped(.service(failure)))
        case .setUp(let failure):
            return .end(.stopped(.setUp(failure)))
        case .read:
            return .end(.stopped(.read))
        case .cancelled:
            return .end(.cancelled)
        }
    }

    /// How one request ended.
    private enum Attempt {
        case accepted([String], model: String)
        case content(TranslationFailure)
        case service(ModelFailure)
        case setUp(ModelFailure)
        /// The slot could not be read: nothing was sent.
        case read
        case cancelled
    }

    /// One request of the part's texts, in order, each once; the reply
    /// through RD14's acceptance checks.
    private func attempt(_ part: [BodySegment], role: ModelRole, job: BodyTranslationJob) async -> Attempt {
        guard !Task.isCancelled else { return .cancelled }
        let texts = part.map(\.text)
        let reply: ModelReply
        do {
            reply = try await models.send(
                texts: texts, instructions: TranslationPrompt.body(into: job.locale), purpose: .body, role: role, automatic: false
            )
        } catch is CancellationError {
            return .cancelled
        } catch let failure as ModelFailure {
            switch failure {
            case .refused: return .content(.refused)
            case .cutOff: return .content(.cutOff)
            case .malformed: return .content(.malformed)
            case .badRequest: return .content(.badRequest)
            case .limited, .serverError, .unreachable: return .service(failure)
            case .noModelSetUp, .keyNeeded, .keyRejected, .modelNotFound: return .setUp(failure)
            }
        } catch {
            return .read
        }
        guard !Task.isCancelled else { return .cancelled }
        switch TranslationAcceptance.check(originals: texts, reply: reply) {
        case .success(let entries): return .accepted(entries, model: reply.model)
        case .failure(let failure): return .content(failure)
        }
    }

    // MARK: - Storing and reporting

    /// Stores the accepted entries (for an article) and reports them. A
    /// reply of work cancelled meanwhile is dropped.
    private func accept(_ part: [BodySegment], entries: [String], model: String, job: BodyTranslationJob, generation: Int) async -> Step {
        guard isCurrent(generation) else { return .end(.cancelled) }
        let translations = Dictionary(zip(part.map(\.hash), entries), uniquingKeysWith: { first, _ in first })
        if let article = job.article {
            let records = part.indices.map { index in
                BodyTextRecord(hash: part[index].hash, state: .done, text: entries[index], failure: nil, model: model)
            }
            await suspend(.acceptedWrite)
            switch await write(records, article: article, locale: job.locale) {
            case .written:
                break
            case .gone:
                return .end(.gone)
            case .failed:
                // Shown for this opening, sent again at the next.
                report(.translated(job: job.id, translations, model: model))
                return .end(.stopped(.storage))
            }
        }
        report(.translated(job: job.id, translations, model: model))
        return .next
    }

    /// Stores the part's texts as failed with `failure` (for an article) and
    /// reports them; the work goes on.
    private func fail(_ part: [BodySegment], _ failure: TranslationFailure, job: BodyTranslationJob, generation: Int) async -> Step {
        guard isCurrent(generation) else { return .end(.cancelled) }
        let failures = Dictionary(part.map { ($0.hash, failure) }, uniquingKeysWith: { first, _ in first })
        if let article = job.article {
            let records = part.map { BodyTextRecord(hash: $0.hash, state: .failed, text: nil, failure: failure, model: nil) }
            switch await write(records, article: article, locale: job.locale) {
            case .written:
                break
            case .gone:
                return .end(.gone)
            case .failed:
                report(.failed(job: job.id, failures))
                return .end(.stopped(.storage))
            }
        }
        report(.failed(job: job.id, failures))
        return .next
    }

    private enum Written {
        case written
        case gone
        case failed
    }

    private func write(_ records: [BodyTextRecord], article: UUID, locale: ReadingLocale) async -> Written {
        #if DEBUG
        if writesToFail > 0 {
            writesToFail -= 1
            return .failed
        }
        #endif
        // In a task of its own: a write refuses to start in a cancelled
        // task, and an accepted reply is worth keeping.
        let library = library
        do {
            return try await Task { try await library.storeBodyTranslations(records, ofArticle: article, locale: locale) }.value
                ? .written : .gone
        } catch {
            return .failed
        }
    }

    /// Reports in order, without waiting for the app.
    private var reports: Task<Void, Never>?

    private func report(_ event: BodyTranslatorEvent) {
        guard let observer else { return }
        let previous = reports
        reports = Task {
            await previous?.value
            await observer(event)
        }
    }

    // MARK: - For the tests

    #if DEBUG
    /// How many of the next writes of results fail, as a full disk would
    /// (RD15 review round 4). Set only by the tests and by the app under a
    /// UI-test library directory.
    private var writesToFail = 0

    public func failNextWrites(_ count: Int) {
        writesToFail = count
    }
    #endif

    /// Where the race tests hold the translator: just before the `await`
    /// whose window they test. Nothing holds it in the app.
    enum SuspensionPoint: Sendable, Hashable {
        /// An accepted chunk's rows are about to be written.
        case acceptedWrite
    }

    private var suspensionHook: (@Sendable (SuspensionPoint) async -> Void)?

    func setSuspensionHook(_ hook: @escaping @Sendable (SuspensionPoint) async -> Void) {
        suspensionHook = hook
    }

    private func suspend(_ point: SuspensionPoint) async {
        if let suspensionHook {
            await suspensionHook(point)
        }
    }

    /// Jobs waiting for the work before them to end.
    private(set) var waitingForPrevious = 0

    /// Returns once the work running has ended and every event has been
    /// reported.
    func settled() async {
        while let task = current {
            await task.value
            if current == task {
                break
            }
        }
        await reports?.value
    }
}
