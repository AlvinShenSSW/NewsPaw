import Foundation

/// What a translator works with besides its models: the reading language
/// and the global switch (RD14 decision 1).
public struct TranslationConfiguration: Sendable, Hashable {
    public var locale: ReadingLocale
    /// `auto_translate_titles`: what a source that follows the global
    /// setting does.
    public var automatic: Bool

    public init(locale: ReadingLocale, automatic: Bool) {
        self.locale = locale
        self.automatic = automatic
    }
}

/// Why an article that needs the model was not sent and nothing was stored
/// (decision 6). It is shown on the article's row while it lasts and never
/// stored.
public enum TranslationBlock: Sendable, Hashable {
    /// A service failure: `limited`, `serverError` or `unreachable`.
    case service(ModelFailure)
    /// The results, or the day's count, could not be read or stored.
    case storage
    /// A set-up failure: `noModelSetUp`, `keyNeeded`, `keyRejected` or
    /// `modelNotFound`.
    case setUp(ModelFailure)
    /// The day's automatic requests reached the limit (decision 8).
    case dailyLimit
    /// A batch whose every article failed for this reason paused automatic
    /// sending.
    case failedBatch(TranslationFailure)
}

/// What the translator reports (decision 12), through its one callback.
public enum TranslatorEvent: Sendable, Hashable {
    /// The articles of the request now in flight; empty when none is.
    case requesting(Set<UUID>)
    /// Translation rows were written for these articles.
    case stored(Set<UUID>)
    /// Every article blocked now, with its reason.
    case blocked([UUID: TranslationBlock])
}

/// How a manual retry ended (decision 10).
public enum ManualTranslationOutcome: Sendable, Hashable {
    /// A row was written (translated, judged, or failed with its reason).
    case stored
    /// Nothing was stored: a service, storage or set-up failure.
    case notStored(TranslationBlock)
    /// The article no longer exists.
    case gone
    /// The translator was stopped, or the work was cancelled.
    case cancelled
    /// `translateIfWaiting` found the article with a row by the time it
    /// ran: nothing was sent.
    case notWaiting
}

/// What starts a resumption (decision 7), and which pauses it ends
/// (decision 6).
public enum TranslationTrigger: Sendable, Hashable {
    /// A refresh run ended: ends a service pause; a set-up pause when the
    /// slots read different.
    case refreshEnded
    /// The app came to the front: as `refreshEnded`.
    case cameToFront
    /// A slot was saved or removed, or its key removed: ends every pause.
    case slotsChanged
    /// The reading language changed: ends no pause.
    case localeChanged
    /// The global switch was turned on: ends no pause.
    case automaticTurnedOn
}

/// Translates the titles and excerpts of one library's articles (spec N06,
/// N11; RD14 decisions 3–10 and 12). It is made from a `LibraryModels` alone
/// and works on that object's library: there is no way to pair one
/// library's articles with another library's models.
///
/// It holds the queue (manual retries, then rows on screen, then the pass),
/// the pause and the one worker, so that one request at most is in flight.
/// Every request is a usage row of its own (RD13).
public actor TitleTranslator {
    /// The most articles a request holds.
    static let batchArticles = 20
    /// The most characters of text a request holds; an article is never
    /// split.
    static let batchCharacters = 6_000
    /// How long a service pause holds.
    static let servicePause = Duration.seconds(600)

    private let models: LibraryModels
    private let library: Library
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let sleep: @Sendable (Duration) async throws -> Void

    private var configuration: TranslationConfiguration?
    private var observer: (@Sendable (TranslatorEvent) async -> Void)?
    private var isStopped = false

    /// A manual retry waiting for the worker.
    private struct ManualJob {
        let id: UUID
        let backup: Bool
        /// Sent only when the article has no row in the reading language
        /// when the job runs (`translateIfWaiting`).
        var onlyIfWaiting = false
        let reply: CheckedContinuation<ManualTranslationOutcome, Never>
    }

    private var manualQueue: [ManualJob] = []
    /// Rows asked for, most recently asked first.
    private var screenQueue: [UUID] = []
    /// The pass's candidates, in order.
    private var passQueue: [UUID] = []
    /// The rows the app has on screen, asked for again by a resumption.
    private var onScreen: Set<UUID> = []
    /// The articles the worker has taken and not finished: not queued again
    /// while it holds them.
    private var taken: Set<UUID> = []
    /// Articles asked for, or found by a pass, while the worker held them:
    /// looked at again once it lets them go (a reading language changed
    /// during their request, for one).
    private var deferredScreen: [UUID] = []
    private var deferredPass: [UUID] = []
    private var blocked: [UUID: TranslationBlock] = [:]
    private var worker: Task<Void, Never>?

    /// Automatic sending is paused (decision 6).
    private enum Pause {
        /// Ends after `servicePause`, at the app's coming to the front, at
        /// the end of a refresh run, at a manual retry that succeeds, at a
        /// change of the slots.
        case service(TranslationBlock, generation: Int)
        /// Ends when the slots change: the rows as read when it began.
        case setUp(TranslationBlock, slots: [ModelRole: ModelSlot]?)

        var block: TranslationBlock {
            switch self {
            case .service(let block, _), .setUp(let block, _): block
            }
        }
    }

    private var pause: Pause?
    private var pauseGeneration = 0
    /// Counts the slot changes this translator was told of: a failure of
    /// the model (set-up, content or service) to a request sent before the
    /// latest one belongs to the old slots and is dropped
    /// (`Attempt.superseded`).
    private var slotsGeneration = 0
    /// Counts the passes started: a pass whose candidates come back after a
    /// newer one started (a changed language, a later trigger) is dropped.
    private var passGeneration = 0
    private var pauseTimer: Task<Void, Never>?
    /// Passes and slot reads started and not ended.
    private var sideWork = 0

    /// - Parameters:
    ///   - models: the library's models; the library worked on is theirs.
    ///   - now: the clock of the pause and of the day's count.
    ///   - calendar: where the device's local day starts.
    ///   - sleep: how the service pause waits (tests inject their own).
    public init(
        models: LibraryModels, now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.models = models
        library = models.library
        self.now = now
        self.calendar = calendar
        self.sleep = sleep
    }

    // MARK: - The app's calls

    /// Sets the one callback.
    public func setObserver(_ observer: @escaping @Sendable (TranslatorEvent) async -> Void) {
        self.observer = observer
    }

    /// Sets the reading language and the global switch. The first call
    /// resumes (the app's launch); later, a changed language or the switch
    /// turned on resumes.
    public func configure(_ configuration: TranslationConfiguration) {
        let previous = self.configuration
        self.configuration = configuration
        guard let previous else {
            resumeWork()
            return
        }
        if previous.locale != configuration.locale {
            resume(after: .localeChanged)
        } else if configuration.automatic, !previous.automatic {
            resume(after: .automaticTurnedOn)
        }
    }

    /// The rows the app has on screen now.
    public func setRowsOnScreen(_ ids: Set<UUID>) {
        onScreen = ids
    }

    /// Rows on screen, or the reading screen's article, ask for their
    /// articles, the most recently asked first. An article already queued
    /// moves up; one the worker holds is not queued again.
    public func ask(_ ids: [UUID]) {
        guard !isStopped else { return }
        deferredScreen += ids.filter { taken.contains($0) && !deferredScreen.contains($0) }
        let fresh = ids.filter { !taken.contains($0) }
        let asked = Set(fresh)
        screenQueue.removeAll { asked.contains($0) }
        passQueue.removeAll { asked.contains($0) }
        var seen = Set<UUID>()
        screenQueue.insert(contentsOf: fresh.filter { seen.insert($0).inserted }, at: 0)
        startWorker()
    }

    /// A trigger of decision 7: ends the pauses it ends (decision 6), then
    /// resumes.
    public func resume(after trigger: TranslationTrigger) {
        guard !isStopped else { return }
        switch trigger {
        case .refreshEnded, .cameToFront:
            if case .service = pause {
                endPause()
            } else if case .setUp(_, let slots) = pause {
                sideWork += 1
                Task {
                    await self.endSetUpPauseIfSlotsChanged(since: slots)
                    self.sideWork -= 1
                }
                return
            }
        case .slotsChanged:
            slotsGeneration += 1
            endPause()
        case .localeChanged, .automaticTurnedOn:
            break
        }
        resumeWork()
    }

    /// Retries one article (decision 10): to the primary under decision 6,
    /// or once to the backup. Not counted as automatic and not limited,
    /// whatever the pause; served before rows and the pass.
    public func retry(_ id: UUID, backup: Bool) async -> ManualTranslationOutcome {
        guard !isStopped else { return .cancelled }
        return await withCheckedContinuation { continuation in
            manualQueue.append(ManualJob(id: id, backup: backup, reply: continuation))
            startWorker()
        }
    }

    /// Translates an article whose body is being translated (RD15 decision
    /// 10): a manual job, served first, not counted and not limited, as
    /// `retry` to the primary, but one that sends nothing when the article
    /// has a row in the reading language by the time it runs — after an
    /// automatic request that held it, for one.
    public func translateIfWaiting(_ id: UUID) async -> ManualTranslationOutcome {
        guard !isStopped else { return .cancelled }
        return await withCheckedContinuation { continuation in
            manualQueue.append(ManualJob(id: id, backup: false, onlyIfWaiting: true, reply: continuation))
            startWorker()
        }
    }

    /// The workspace is dropped: the request in flight is cancelled and
    /// nothing is stored for it; nothing starts from here on.
    public func stop() {
        isStopped = true
        worker?.cancel()
        worker = nil
        pauseTimer?.cancel()
        pauseTimer = nil
        for job in manualQueue {
            job.reply.resume(returning: .cancelled)
        }
        manualQueue = []
        screenQueue = []
        passQueue = []
        deferredScreen = []
        deferredPass = []
    }

    // MARK: - Resuming and pausing

    /// A pass plus asking again for every row on screen (decision 7).
    /// Blocked articles that are not asked for again lose their mark: what
    /// blocked them is looked at again when they are.
    private func resumeWork() {
        guard !isStopped, configuration != nil else { return }
        let rows = onScreen
        let before = blocked
        blocked = blocked.filter { rows.contains($0.key) }
        if blocked != before {
            report(.blocked(blocked))
        }
        ask(Array(rows))
        sideWork += 1
        Task {
            await self.runPass()
            self.sideWork -= 1
        }
    }

    private func runPass() async {
        guard !isStopped, let configuration else { return }
        passGeneration += 1
        let generation = passGeneration
        await suspend(.passCandidates(configuration.locale))
        guard let candidates = try? await library.translationPassCandidates(
            locale: configuration.locale, automatic: configuration.automatic
        ) else { return }
        // A newer pass has filled the queue since this one began: its
        // candidates (of an older language, perhaps) would replace it.
        guard generation == passGeneration, !isStopped else { return }
        let queued = Set(screenQueue).union(taken)
        passQueue = candidates.filter { !queued.contains($0) }
        deferredPass += candidates.filter { taken.contains($0) && !deferredPass.contains($0) }
        startWorker()
    }

    private func endSetUpPauseIfSlotsChanged(since slots: [ModelRole: ModelSlot]?) async {
        let current = try? await library.modelSlots()
        if case .setUp(_, let held) = pause, held == slots, current != slots {
            endPause()
        }
        resumeWork()
    }

    private func endPause() {
        pause = nil
        pauseTimer?.cancel()
        pauseTimer = nil
    }

    private func pauseForService(_ block: TranslationBlock) {
        pauseGeneration += 1
        let generation = pauseGeneration
        pause = .service(block, generation: generation)
        pauseTimer?.cancel()
        let sleep = sleep
        pauseTimer = Task {
            do {
                try await sleep(Self.servicePause)
            } catch {
                return
            }
            self.servicePauseElapsed(generation)
        }
    }

    private func servicePauseElapsed(_ generation: Int) {
        guard case .service(_, let current) = pause, current == generation else { return }
        endPause()
        resumeWork()
    }

    /// A set-up failure: the articles are blocked and sending pauses until
    /// the slots, as read now, change. A slot change during that read
    /// supersedes the failure: nothing is blocked or paused, and the
    /// articles wait (the change asked for them again).
    private func setUpFailed(_ ids: [UUID], _ failure: ModelFailure) async {
        let generation = slotsGeneration
        await suspend(.setUpSlots)
        let slots = try? await library.modelSlots()
        guard generation == slotsGeneration, !isStopped else { return }
        block(ids, .setUp(failure))
        pause = .setUp(.setUp(failure), slots: slots)
        pauseTimer?.cancel()
        pauseTimer = nil
    }

    // MARK: - The worker

    private func startWorker() {
        guard worker == nil, !isStopped, configuration != nil else { return }
        guard !manualQueue.isEmpty || !screenQueue.isEmpty || !passQueue.isEmpty else { return }
        worker = Task { await self.work() }
    }

    private func work() async {
        while !Task.isCancelled, !isStopped {
            if !manualQueue.isEmpty {
                let job = manualQueue.removeFirst()
                let outcome = await runManual(job)
                job.reply.resume(returning: outcome)
            } else if !screenQueue.isEmpty || !passQueue.isEmpty {
                await runAutomatic()
            } else {
                break
            }
        }
        worker = nil
        // Something queued while the last piece of work ended.
        startWorker()
    }

    /// One article to send: its texts as sent, the title first.
    private struct Prepared {
        let id: UUID
        let title: String?
        let excerpt: String?
        let sendsTitle: Bool
        let texts: [String]

        init(_ judgement: TextLanguage.Judgement, id: UUID) {
            self.id = id
            title = judgement.title
            excerpt = judgement.excerpt
            sendsTitle = judgement.sendsTitle
            texts = judgement.textsToSend
        }

        var characters: Int {
            texts.reduce(0) { $0 + $1.count }
        }
    }

    /// Where a taken article came from, to put it back there.
    private enum Tier {
        case screen
        case pass
    }

    /// Takes the next articles off the queues (rows on screen first),
    /// judges them, writes the rows that need no model, and sends the rest
    /// as one batch of at most `batchArticles` articles and
    /// `batchCharacters` characters; during a pause they are blocked
    /// instead. Articles that do not fit go back to the front of their
    /// queue.
    private func runAutomatic() async {
        guard let configuration else { return }
        let locale = configuration.locale
        var batch: [Prepared] = []
        var characters = 0
        var full = false
        var held: [UUID] = []
        defer { release(held) }
        while !full, !Task.isCancelled {
            var chunk: [(UUID, Tier)] = []
            while chunk.count < Self.batchArticles, let next = takeNext() {
                chunk.append(next)
            }
            guard !chunk.isEmpty else { break }
            held += chunk.map(\.0)
            let inputs: [TranslationInput]
            do {
                inputs = try await library.translationInputs(chunk.map(\.0), locale: locale)
            } catch {
                // The work in hand ends; the next trigger tries again.
                return
            }
            let automatic = self.configuration?.automatic ?? configuration.automatic
            var records: [TranslationRecord] = []
            var sendable: [(Prepared, Tier)] = []
            let tiers = Dictionary(chunk, uniquingKeysWith: { first, _ in first })
            for input in inputs where !input.hasTranslation
                && Library.translatesAutomatically(input.autoTranslate, automatic: automatic) {
                let judgement = TextLanguage.judge(title: input.title, excerpt: input.excerpt, reading: locale)
                switch judgement.decision {
                case .keep:
                    records.append(TranslationRecord(
                        articleID: input.id, locale: locale, state: .none, title: nil, excerpt: nil, failure: nil, model: nil
                    ))
                case .converted(let title, let excerpt):
                    records.append(TranslationRecord(
                        articleID: input.id, locale: locale, state: .done, title: title, excerpt: excerpt, failure: nil, model: nil
                    ))
                case .send:
                    sendable.append((Prepared(judgement, id: input.id), tiers[input.id] ?? .pass))
                }
            }
            await store(records)
            var returned: [(UUID, Tier)] = []
            for (article, tier) in sendable {
                if let pause {
                    block([article.id], pause.block)
                } else if full || batch.count >= Self.batchArticles || characters + article.characters > Self.batchCharacters {
                    full = true
                    returned.append((article.id, tier))
                } else {
                    batch.append(article)
                    characters += article.characters
                }
            }
            if batch.count >= Self.batchArticles {
                full = true
            }
            putBack(returned)
            held.removeAll { id in returned.contains { $0.0 == id } }
        }
        guard !batch.isEmpty, !Task.isCancelled else { return }
        await sendAutomatic(batch, locale: locale)
    }

    /// The worker lets articles go: those asked for meanwhile are queued
    /// again, at the front of their queue.
    private func release(_ ids: [UUID]) {
        taken.subtract(ids)
        let stillTaken = taken
        let free = { (id: UUID) in !stillTaken.contains(id) }
        let screen = deferredScreen.filter(free)
        let pass = deferredPass.filter(free)
        guard !screen.isEmpty || !pass.isEmpty, !isStopped else { return }
        deferredScreen.removeAll(where: free)
        deferredPass.removeAll(where: free)
        let queued = Set(screenQueue)
        screenQueue.insert(contentsOf: screen.filter { !queued.contains($0) }, at: 0)
        let queuedAll = Set(screenQueue).union(passQueue)
        passQueue.insert(contentsOf: pass.filter { !queuedAll.contains($0) }, at: 0)
    }

    private func takeNext() -> (UUID, Tier)? {
        while !screenQueue.isEmpty {
            let id = screenQueue.removeFirst()
            if taken.insert(id).inserted {
                return (id, .screen)
            }
        }
        while !passQueue.isEmpty {
            let id = passQueue.removeFirst()
            if taken.insert(id).inserted {
                return (id, .pass)
            }
        }
        return nil
    }

    private func putBack(_ articles: [(UUID, Tier)]) {
        let ids = Set(articles.map(\.0))
        taken.subtract(ids)
        screenQueue.removeAll { ids.contains($0) }
        passQueue.removeAll { ids.contains($0) }
        screenQueue.insert(contentsOf: articles.filter { $0.1 == .screen }.map(\.0), at: 0)
        passQueue.insert(contentsOf: articles.filter { $0.1 == .pass }.map(\.0), at: 0)
    }

    // MARK: - Decision 6

    /// How one request ended.
    private enum Attempt {
        case accepted([String], model: String)
        /// A content failure, with the name of the model that was called
        /// (stored with the failed rows; decision 2).
        case content(TranslationFailure, model: String?)
        case service(ModelFailure)
        case setUp(ModelFailure)
        /// The day's automatic requests are at the limit: nothing was sent.
        case limit
        /// The day's count could not be read: nothing was sent.
        case storage
        case cancelled
        /// A set-up, content or service failure that came back after the
        /// slots changed: it belongs to the old slots, so nothing is stored,
        /// blocked, paused or sent to the backup, and the articles wait (the
        /// change asked for them again). An accepted reply of the old slots
        /// is still stored: it is good text.
        case superseded
    }

    /// An automatic batch through decision 6.
    private func sendAutomatic(_ batch: [Prepared], locale: ReadingLocale) async {
        // A batch failed wholly pauses sending only if the slots did not
        // change while it was sent and its failures stored.
        let generation = slotsGeneration
        let first = await attempt(batch, role: .primary, automatic: true, locale: locale)
        switch first {
        case .accepted(let entries, let model):
            await storeAccepted(batch, entries: entries, model: model, locale: locale, automatic: true)
        case .cancelled, .superseded:
            return
        case .limit:
            block(batch.map(\.id), .dailyLimit)
        case .storage:
            block(batch.map(\.id), .storage)
            pauseForService(.storage)
        case .setUp(let failure):
            await setUpFailed(batch.map(\.id), failure)
        case .service(let failure):
            if case .failed(let reason) = await sendToBackup(batch, after: failure, locale: locale, automatic: true), pause == nil,
               generation == slotsGeneration {
                pauseForService(.failedBatch(reason))
            }
        case .content:
            // Retried once on the primary: as two halves, or as itself.
            let parts = batch.count > 1
                ? [Array(batch[..<(batch.count / 2)]), Array(batch[(batch.count / 2)...])]
                : [batch]
            var failed = 0
            var lastFailure = TranslationFailure.malformed
            for part in parts {
                if let pause {
                    block(part.map(\.id), pause.block)
                    continue
                }
                switch await attempt(part, role: .primary, automatic: true, locale: locale) {
                case .accepted(let entries, let model):
                    await storeAccepted(part, entries: entries, model: model, locale: locale, automatic: true)
                case .content(let failure, let model):
                    if await storeFailed(part, failure: failure, model: model, locale: locale, automatic: true) {
                        failed += part.count
                        lastFailure = failure
                    }
                case .service(let failure):
                    if case .failed(let reason) = await sendToBackup(part, after: failure, locale: locale, automatic: true) {
                        failed += part.count
                        lastFailure = reason
                    }
                case .setUp(let failure):
                    await setUpFailed(part.map(\.id), failure)
                case .limit:
                    block(part.map(\.id), .dailyLimit)
                case .storage:
                    block(part.map(\.id), .storage)
                    pauseForService(.storage)
                case .cancelled:
                    return
                case .superseded:
                    continue
                }
            }
            // A model that fails everything is tried a batch at a time.
            if failed == batch.count, pause == nil, generation == slotsGeneration {
                pauseForService(.failedBatch(lastFailure))
            }
        }
    }

    /// How a backup attempt ended, for the caller's count of failures.
    private enum BackupEnd {
        case stored
        case failed(TranslationFailure)
        case notStored
        /// The slots changed meanwhile: nothing stored, blocked or paused.
        case superseded
    }

    /// After a service failure of the primary: once to a usable backup,
    /// with no retry there. Without one, or when the backup fails with a
    /// service or set-up failure, the articles are blocked with the
    /// primary's reason and, when automatic, sending pauses.
    private func sendToBackup(_ part: [Prepared], after failure: ModelFailure, locale: ReadingLocale, automatic: Bool) async -> BackupEnd {
        let ids = part.map(\.id)
        let generation = slotsGeneration
        await suspend(.backupCheck)
        let usable = await hasUsableBackup()
        // A slot change during the check supersedes the primary's failure.
        guard generation == slotsGeneration else { return .superseded }
        guard usable else {
            block(ids, .service(failure))
            if automatic {
                pauseForService(.service(failure))
            }
            return .notStored
        }
        switch await attempt(part, role: .backup, automatic: automatic, locale: locale) {
        case .accepted(let entries, let model):
            // Not stored: the articles are blocked for storage (and, when
            // automatic, sending pauses) by `storeAccepted`.
            return await storeAccepted(part, entries: entries, model: model, locale: locale, automatic: automatic) ? .stored : .notStored
        case .content(let reason, let model):
            return await storeFailed(part, failure: reason, model: model, locale: locale, automatic: automatic) ? .failed(reason) : .notStored
        case .service, .setUp:
            block(ids, .service(failure))
            if automatic {
                pauseForService(.service(failure))
            }
            return .notStored
        case .limit:
            block(ids, .dailyLimit)
            return .notStored
        case .storage:
            block(ids, .storage)
            if automatic {
                pauseForService(.storage)
            }
            return .notStored
        case .cancelled:
            return .notStored
        case .superseded:
            return .superseded
        }
    }

    private func hasUsableBackup() async -> Bool {
        guard let statuses = try? await models.statuses(), let backup = statuses[.backup] else { return false }
        return backup.key != .missing
    }

    /// One request: the daily limit first when automatic, then the model,
    /// then decision 5's checks.
    private func attempt(_ articles: [Prepared], role: ModelRole, automatic: Bool, locale: ReadingLocale) async -> Attempt {
        if automatic {
            do {
                let start = calendar.startOfDay(for: now())
                let count = try await library.automaticRequestCount(since: start)
                let limit = try await library.dailyAutomaticLimit()
                if count >= limit {
                    return .limit
                }
            } catch {
                return .storage
            }
        }
        guard !Task.isCancelled else { return .cancelled }
        // Before sending: the slots' generation, and the name of the model
        // the slot names, for a failed row (the reply carries it otherwise).
        let generation = slotsGeneration
        let slotModel: String? = if let slot = try? await library.modelSlot(role), case .success(let name) = ModelName.validate(slot.model) {
            name
        } else {
            nil
        }
        let texts = articles.flatMap(\.texts)
        report(.requesting(Set(articles.map(\.id))))
        defer { report(.requesting([])) }
        let reply: ModelReply
        do {
            reply = try await models.send(
                texts: texts, instructions: TranslationPrompt.titles(into: locale), purpose: .titles, role: role, automatic: automatic
            )
        } catch is CancellationError {
            return .cancelled
        } catch let failure as ModelFailure {
            let superseded = slotsGeneration != generation
            switch failure {
            case .refused: return superseded ? .superseded : .content(.refused, model: slotModel)
            case .cutOff: return superseded ? .superseded : .content(.cutOff, model: slotModel)
            case .malformed: return superseded ? .superseded : .content(.malformed, model: slotModel)
            case .badRequest: return superseded ? .superseded : .content(.badRequest, model: slotModel)
            case .limited, .serverError, .unreachable: return superseded ? .superseded : .service(failure)
            case .noModelSetUp, .keyNeeded, .keyRejected, .modelNotFound: return superseded ? .superseded : .setUp(failure)
            }
        } catch {
            // The slot could not be read, or the usage row of this automatic
            // request could not be written (`UsageNotRecorded`): the count
            // of the daily limit cannot be trusted, so sending pauses.
            return .storage
        }
        if Task.isCancelled {
            return .cancelled
        }
        switch TranslationAcceptance.check(originals: texts, reply: reply) {
        case .success(let entries): return .accepted(entries, model: reply.model)
        case .failure(let failure): return slotsGeneration != generation ? .superseded : .content(failure, model: reply.model)
        }
    }

    // MARK: - Storing

    /// Writes the accepted translations: an entry equal to its original
    /// after trimming is stored as null. A failure to store blocks the
    /// articles and, when automatic, pauses sending.
    @discardableResult
    private func storeAccepted(_ part: [Prepared], entries: [String], model: String, locale: ReadingLocale, automatic: Bool) async -> Bool {
        var records: [TranslationRecord] = []
        var index = 0
        func next(for original: String?) -> String? {
            guard let original, TextLanguage.Units(original).hasLetter else { return nil }
            let entry = entries[index]
            index += 1
            return entry == original.trimmingCharacters(in: .whitespacesAndNewlines) ? nil : entry
        }
        for article in part {
            let title = next(for: article.title)
            let excerpt = next(for: article.excerpt)
            records.append(TranslationRecord(
                articleID: article.id, locale: locale, state: .done, title: title, excerpt: excerpt, failure: nil, model: model
            ))
        }
        return await storeOrBlock(records, automatic: automatic)
    }

    @discardableResult
    private func storeFailed(
        _ part: [Prepared], failure: TranslationFailure, model: String?, locale: ReadingLocale, automatic: Bool
    ) async -> Bool {
        let records = part.map { article in
            TranslationRecord(articleID: article.id, locale: locale, state: .failed, title: nil, excerpt: nil, failure: failure, model: model)
        }
        await suspend(.failedRowsWrite)
        return await storeOrBlock(records, automatic: automatic)
    }

    private func storeOrBlock(_ records: [TranslationRecord], automatic: Bool) async -> Bool {
        do {
            try await write(records)
            return true
        } catch {
            block(records.map(\.articleID), .storage)
            if automatic {
                pauseForService(.storage)
            }
            return false
        }
    }

    /// Writes rows that need no model; a failure leaves the articles waiting.
    private func store(_ records: [TranslationRecord]) async {
        try? await write(records)
    }

    private func write(_ records: [TranslationRecord]) async throws {
        guard !records.isEmpty else { return }
        // In a task of its own: a write refuses to start in a cancelled
        // task, and these results are worth keeping.
        let library = library
        let stored = try await Task { try await library.storeTranslations(records) }.value
        let ids = Set(records.map(\.articleID))
        unblock(ids)
        if !stored.isEmpty {
            report(.stored(stored))
        }
    }

    // MARK: - Manual retries (decision 10)

    private func runManual(_ job: ManualJob) async -> ManualTranslationOutcome {
        guard let configuration else { return .cancelled }
        let locale = configuration.locale
        taken.insert(job.id)
        defer { release([job.id]) }
        let inputs: [TranslationInput]
        do {
            inputs = try await library.translationInputs([job.id], locale: locale)
        } catch {
            return .notStored(.storage)
        }
        guard let input = inputs.first else { return .gone }
        // Read after the worker took the job: a row stored by any earlier
        // request is seen here.
        if job.onlyIfWaiting, input.hasTranslation {
            return .notWaiting
        }
        let judgement = TextLanguage.judge(title: input.title, excerpt: input.excerpt, reading: locale)
        switch judgement.decision {
        case .keep:
            return await manualStore([TranslationRecord(
                articleID: input.id, locale: locale, state: .none, title: nil, excerpt: nil, failure: nil, model: nil
            )])
        case .converted(let title, let excerpt):
            return await manualStore([TranslationRecord(
                articleID: input.id, locale: locale, state: .done, title: title, excerpt: excerpt, failure: nil, model: nil
            )])
        case .send:
            break
        }
        let article = [Prepared(judgement, id: input.id)]
        if job.backup {
            switch await attempt(article, role: .backup, automatic: false, locale: locale) {
            case .accepted(let entries, let model):
                return await storeAccepted(article, entries: entries, model: model, locale: locale, automatic: false)
                    ? succeeded() : .notStored(.storage)
            case .content(let failure, let model):
                return await storeFailed(article, failure: failure, model: model, locale: locale, automatic: false)
                    ? .stored : .notStored(.storage)
            case .service(let failure):
                return .notStored(.service(failure))
            case .setUp(let failure):
                return .notStored(.setUp(failure))
            case .storage, .limit:
                return .notStored(.storage)
            case .cancelled, .superseded:
                return .cancelled
            }
        }
        // The primary, with its own retry and its own backup attempt.
        var lastContent: TranslationFailure?
        var lastModel: String?
        for _ in 0..<2 {
            switch await attempt(article, role: .primary, automatic: false, locale: locale) {
            case .accepted(let entries, let model):
                return await storeAccepted(article, entries: entries, model: model, locale: locale, automatic: false)
                    ? succeeded() : .notStored(.storage)
            case .content(let failure, let model):
                lastContent = failure
                lastModel = model
                continue
            case .service(let failure):
                switch await sendToBackup(article, after: failure, locale: locale, automatic: false) {
                case .stored: return succeeded()
                case .failed: return .stored
                case .notStored: return .notStored(blocked[input.id] ?? .service(failure))
                case .superseded: return .cancelled
                }
            case .setUp(let failure):
                return .notStored(.setUp(failure))
            case .storage, .limit:
                return .notStored(.storage)
            case .cancelled, .superseded:
                return .cancelled
            }
        }
        return await storeFailed(article, failure: lastContent ?? .malformed, model: lastModel, locale: locale, automatic: false)
            ? .stored : .notStored(.storage)
    }

    private func manualStore(_ records: [TranslationRecord]) async -> ManualTranslationOutcome {
        do {
            try await write(records)
            return .stored
        } catch {
            return .notStored(.storage)
        }
    }

    /// A manual retry that succeeded ends a service pause, and work
    /// resumes.
    private func succeeded() -> ManualTranslationOutcome {
        if case .service = pause {
            endPause()
            resumeWork()
        }
        return .stored
    }

    // MARK: - For the tests

    /// Where the race tests hold the translator: just before the `await`
    /// whose window they test. Nothing holds it in the app.
    enum SuspensionPoint: Sendable, Hashable {
        /// A pass is about to read its candidates.
        case passCandidates(ReadingLocale)
        /// A set-up failure is about to read the slots for its pause.
        case setUpSlots
        /// A service failure is about to look for a usable backup.
        case backupCheck
        /// Failed rows are about to be written.
        case failedRowsWrite
    }

    private var suspensionHook: (@Sendable (SuspensionPoint) async -> Void)?

    /// Sets the hook the race tests hold the translator with.
    func setSuspensionHook(_ hook: @escaping @Sendable (SuspensionPoint) async -> Void) {
        suspensionHook = hook
    }

    private func suspend(_ point: SuspensionPoint) async {
        if let suspensionHook {
            await suspensionHook(point)
        }
    }

    /// Returns once nothing is queued, no worker or pass is running and
    /// every event has been reported. A pause's timer does not count.
    func settled() async {
        while worker != nil || sideWork > 0 {
            if let worker {
                await worker.value
            } else {
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        await reports?.value
    }

    /// Whether automatic sending is paused, and why.
    var pausedBy: TranslationBlock? {
        pause?.block
    }

    /// Passes and slot reads running now.
    var sideWorkRunning: Int {
        sideWork
    }

    // MARK: - Reporting

    private func block(_ ids: [UUID], _ reason: TranslationBlock) {
        guard !ids.isEmpty else { return }
        for id in ids {
            blocked[id] = reason
        }
        report(.blocked(blocked))
    }

    private func unblock(_ ids: Set<UUID>) {
        let before = blocked.count
        blocked = blocked.filter { !ids.contains($0.key) }
        if blocked.count != before {
            report(.blocked(blocked))
        }
    }

    /// Reports in order, without waiting for the app.
    private var reports: Task<Void, Never>?

    private func report(_ event: TranslatorEvent) {
        guard let observer else { return }
        let previous = reports
        reports = Task {
            await previous?.value
            await observer(event)
        }
    }
}
