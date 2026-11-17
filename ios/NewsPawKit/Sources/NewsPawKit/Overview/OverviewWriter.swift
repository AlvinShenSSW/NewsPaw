import Foundation

/// Why a category's overview was not written and nothing was stored (RD23
/// decision 6). A value in memory, shown while it lasts, for its day and
/// reading locale only; a relaunch forgets it.
public struct OverviewBlock: Sendable, Hashable {
    public enum Reason: Sendable, Hashable {
        /// A service failure: `limited`, `serverError` or `unreachable`.
        case service(ModelFailure)
        /// A set-up failure: `noModelSetUp`, `keyNeeded`, `keyRejected` or
        /// `modelNotFound`.
        case setUp(ModelFailure)
        /// The day's automatic requests reached the limit (decision 7).
        case dailyLimit
        /// A read or the store failed, or an automatic request's usage row
        /// could not be written.
        case storage
    }

    public let reason: Reason
    /// The job's day (`OverviewDay.key`).
    public let day: String
    public let locale: ReadingLocale

    public init(reason: Reason, day: String, locale: ReadingLocale) {
        self.reason = reason
        self.day = day
        self.locale = locale
    }
}

/// What the writer reports (decision 10), through its one callback, in
/// order.
public enum OverviewEvent: Sendable, Hashable {
    /// The categories queued or in flight.
    case working(Set<UUID>)
    /// A row was written for this category.
    case stored(UUID)
    /// Every category blocked now, with its block.
    case blocked([UUID: OverviewBlock])
}

/// How a manual job ("Write Overview", "Rewrite", "Retry") ended (decision
/// 8).
public enum OverviewWriteOutcome: Sendable, Hashable {
    /// A `done` row was written.
    case stored
    /// No article to write from.
    case nothingNew
    /// A content failure, stored as `failed` or, with a `done` row in
    /// place, not stored.
    case failed(TranslationFailure)
    /// Nothing was stored: a service, set-up, limit or storage failure.
    case notStored(OverviewBlock)
    /// The category, or an article that was sent, no longer exists in it.
    case gone
    /// The writer was stopped, the locale or the slots changed meanwhile,
    /// or the work was cancelled.
    case cancelled
}

/// Writes the daily overviews of one library's categories (spec N07, N11;
/// RD23 decisions 6–11). It is made from a `LibraryModels` alone and works
/// on that object's library, as `TitleTranslator` is: there is no way to
/// pair one library's categories with another library's models.
///
/// One serial worker: manual jobs first, then the automatic ones in the
/// owner's order, one request at most in flight. Every request is a usage
/// row of its own; automatic ones carry `automatic` and are refused at the
/// daily limit.
public actor OverviewWriter {
    private let models: LibraryModels
    private let library: Library
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    private var locale: ReadingLocale?
    private var observer: (@Sendable (OverviewEvent) async -> Void)?
    private var isStopped = false
    /// Counts the `configure` calls: a job whose read began before a change
    /// of the locale is dropped (decision 11 (a)).
    private var configGeneration = 0
    /// Counts the slot changes this writer was told of: a failure of a
    /// request sent before the latest one belongs to the old slots and is
    /// superseded (decision 11 (d)–(g)).
    private var slotsGeneration = 0

    private struct ManualJob {
        let category: UUID
        let reply: CheckedContinuation<OverviewWriteOutcome, Never>
    }

    private var manualQueue: [ManualJob] = []
    private var automaticQueue: [UUID] = []
    private var inFlight: UUID?
    private var blocks: [UUID: OverviewBlock] = [:]
    private var worker: Task<Void, Never>?

    /// Automatic jobs hold after a set-up failure until the slots change
    /// (decision 6): the slots as the failed job read them.
    private struct Hold {
        let reason: OverviewBlock.Reason
        let slots: [ModelRole: SlotIdentity]
        let generation: Int
    }

    private var hold: Hold?
    private var holdGeneration = 0
    private var lastWorking: Set<UUID> = []

    /// - Parameters:
    ///   - models: the library's models; the library worked on is theirs.
    ///   - now: the clock of the day and of the day's count.
    ///   - calendar: where the device's local day starts and its time zone.
    public init(models: LibraryModels, now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .autoupdatingCurrent) {
        self.models = models
        library = models.library
        self.now = now
        self.calendar = calendar
    }

    // MARK: - The app's calls

    /// Sets the one callback.
    public func setObserver(_ observer: @escaping @Sendable (OverviewEvent) async -> Void) {
        self.observer = observer
    }

    /// Sets the reading locale. Starts nothing; a job whose read began
    /// before is dropped.
    public func configure(locale: ReadingLocale) {
        self.locale = locale
        configGeneration += 1
    }

    /// At the end of a foreground refresh run (decision 8): queues an
    /// automatic job for each due category, in the owner's order, that is
    /// not already queued or in flight. Under a set-up hold it first reads
    /// the slots and ends the hold if they differ from those held;
    /// otherwise it queues nothing and reports the due categories blocked.
    public func runDue() async {
        guard !isStopped, let locale else { return }
        if let held = hold {
            if let current = try? await library.slotIdentities(), hold?.generation == held.generation, current != held.slots {
                hold = nil
            }
        }
        let now = now()
        let day = OverviewDay.key(for: now, calendar: calendar)
        guard let due = try? await library.overviewDueCategories(day: day, dayStart: OverviewDay.start(of: now, calendar: calendar)),
              !isStopped, locale == self.locale
        else { return }
        let queued = queuedOrInFlight
        let fresh = due.filter { !queued.contains($0) }
        if let hold {
            for id in fresh {
                blocks[id] = OverviewBlock(reason: hold.reason, day: day, locale: locale)
            }
            report(.blocked(blocks))
            return
        }
        automaticQueue += fresh
        reportWorking()
        startWorker()
    }

    /// A slot was saved or removed, or its key removed: the hold ends, the
    /// blocks go (they belonged to the old slots), and a failure of a
    /// request in flight is superseded. Starts nothing.
    public func slotsChanged() {
        slotsGeneration += 1
        hold = nil
        if !blocks.isEmpty {
            blocks = [:]
            report(.blocked(blocks))
        }
    }

    /// A manual job: served before queued automatic ones, neither counted
    /// nor limited.
    public func write(category: UUID) async -> OverviewWriteOutcome {
        guard !isStopped, locale != nil else { return .cancelled }
        return await withCheckedContinuation { continuation in
            manualQueue.append(ManualJob(category: category, reply: continuation))
            reportWorking()
            startWorker()
        }
    }

    /// The workspace is dropped: the job in flight is cancelled and stores
    /// nothing; queued manual jobs answer `cancelled`; nothing starts again.
    public func stop() {
        isStopped = true
        worker?.cancel()
        worker = nil
        for job in manualQueue {
            job.reply.resume(returning: .cancelled)
        }
        manualQueue = []
        automaticQueue = []
    }

    // MARK: - The worker

    private var queuedOrInFlight: Set<UUID> {
        var ids = Set(automaticQueue).union(manualQueue.map(\.category))
        if let inFlight {
            ids.insert(inFlight)
        }
        return ids
    }

    private func startWorker() {
        guard worker == nil, !isStopped, locale != nil, !manualQueue.isEmpty || !automaticQueue.isEmpty else { return }
        worker = Task { await self.work() }
    }

    private func work() async {
        while !Task.isCancelled, !isStopped {
            if !manualQueue.isEmpty {
                let job = manualQueue.removeFirst()
                inFlight = job.category
                reportWorking()
                let outcome = await run(job.category, automatic: false)
                inFlight = nil
                reportWorking()
                job.reply.resume(returning: outcome)
            } else if !automaticQueue.isEmpty {
                let category = automaticQueue.removeFirst()
                inFlight = category
                reportWorking()
                _ = await run(category, automatic: true)
                inFlight = nil
                reportWorking()
            } else {
                break
            }
        }
        worker = nil
        // Something queued while the last job ended.
        startWorker()
    }

    /// How one request ended.
    private enum Attempt {
        case accepted(OverviewAcceptance.Accepted, model: String)
        /// A content failure, with the name of the model that was called.
        case content(TranslationFailure, model: String?)
        case service(ModelFailure)
        case setUp(ModelFailure)
        /// The day's automatic requests are at the limit: nothing was sent.
        case limit
        /// The day's count could not be read, or the usage row of an
        /// automatic request could not be written.
        case storage
        case cancelled
        /// A failure that came back after the slots changed: nothing is
        /// stored, blocked or held.
        case superseded
    }

    /// What one job works with after its read.
    private struct Job {
        let category: UUID
        let automatic: Bool
        let locale: ReadingLocale
        let day: String
        let dayStart: Date
        let input: [OverviewArticle]
        let texts: [String]
        /// The slots as read at (b), and the slot changes counted then.
        let slots: [ModelRole: SlotIdentity]
        let generation: Int
    }

    /// One job through decision 9: (a) the read, (b) the slots, (c) the
    /// limit, (d) the primary, (e) a retry or the backup, (f) the store,
    /// (g) the report. The return value of an automatic job is not used:
    /// `cancelled` there means dropped.
    private func run(_ category: UUID, automatic: Bool) async -> OverviewWriteOutcome {
        guard let locale else { return .cancelled }
        let configuration = configGeneration
        unblock(category)
        // (a)
        await suspend(.jobRead)
        let read: OverviewJobRead
        do {
            read = try await library.overviewJobRead(category: category, locale: locale, now: now(), calendar: calendar)
        } catch {
            guard !isStopped, configuration == configGeneration else { return .cancelled }
            let day = OverviewDay.key(for: now(), calendar: calendar)
            return block(category, .storage, day: day, locale: locale, automatic: automatic, generation: slotsGeneration)
        }
        guard !isStopped, configuration == configGeneration else { return .cancelled }
        guard let mode = read.mode else { return .gone }
        if automatic, mode != .auto || read.hasRowThatDay || !read.hasArticleFirstSeenThatDay {
            return .cancelled
        }
        guard !read.input.isEmpty else { return .nothingNew }
        // (b)
        let generation = slotsGeneration
        let slots: [ModelRole: SlotIdentity]
        do {
            slots = try await library.slotIdentities()
        } catch {
            guard !isStopped else { return .cancelled }
            return block(category, .storage, day: read.day, locale: locale, automatic: automatic, generation: generation)
        }
        guard !isStopped else { return .cancelled }
        let job = Job(
            category: category, automatic: automatic, locale: locale, day: read.day, dayStart: read.dayStart, input: read.input,
            texts: OverviewPrompt.texts(read.input), slots: slots, generation: generation
        )
        // (c)–(d), and (e)'s retry: a content failure is tried once more
        // on the primary.
        var result = await attempt(job, role: .primary)
        if case .content = result {
            result = await attempt(job, role: .primary)
        }
        switch result {
        case .accepted(let accepted, let model):
            return await storeDone(job, accepted, model: model)
        case .content(let failure, let model):
            return await storeFailed(job, failure, model: model)
        case .service(let failure):
            return await sendToBackup(job, after: failure)
        case .setUp(let failure):
            return setUpFailed(job, failure)
        case .limit:
            return block(job, .dailyLimit)
        case .storage:
            return block(job, .storage)
        case .cancelled, .superseded:
            return .cancelled
        }
    }

    /// (e) After a service failure of the primary: once to a usable backup,
    /// with no retry there. Without one, or when the backup fails with a
    /// service or set-up failure, the category is blocked with the
    /// primary's reason.
    private func sendToBackup(_ job: Job, after failure: ModelFailure) async -> OverviewWriteOutcome {
        await suspend(.backupCheck)
        let usable = await hasUsableBackup()
        guard !isStopped, !Task.isCancelled else { return .cancelled }
        // A slot change during the check supersedes the primary's failure.
        guard job.generation == slotsGeneration else { return .cancelled }
        guard usable else { return block(job, .service(failure)) }
        switch await attempt(job, role: .backup) {
        case .accepted(let accepted, let model):
            return await storeDone(job, accepted, model: model)
        case .content(let reason, let model):
            return await storeFailed(job, reason, model: model)
        case .service, .setUp:
            return block(job, .service(failure))
        case .limit:
            return block(job, .dailyLimit)
        case .storage:
            return block(job, .storage)
        case .cancelled, .superseded:
            return .cancelled
        }
    }

    private func hasUsableBackup() async -> Bool {
        guard let statuses = try? await models.statuses(), let backup = statuses[.backup] else { return false }
        return backup.key != .missing
    }

    /// One request: (c) the daily limit first when automatic, read
    /// immediately before sending, then (d) the model, then decision 5's
    /// checks.
    private func attempt(_ job: Job, role: ModelRole) async -> Attempt {
        if job.automatic {
            do {
                let count = try await library.automaticRequestCount(since: job.dayStart)
                let limit = try await library.dailyAutomaticLimit()
                if count >= limit {
                    return .limit
                }
            } catch {
                return .storage
            }
        }
        await suspend(.send(role))
        guard !Task.isCancelled, !isStopped else { return .cancelled }
        let slotModel = job.slots[role]?.model
        let reply: ModelReply
        do {
            reply = try await models.send(
                texts: job.texts, instructions: OverviewPrompt.instructions(into: job.locale), purpose: .overview, role: role,
                automatic: job.automatic
            )
        } catch is CancellationError {
            return .cancelled
        } catch let failure as ModelFailure {
            guard !Task.isCancelled, !isStopped else { return .cancelled }
            guard slotsGeneration == job.generation else { return .superseded }
            switch failure {
            case .refused: return .content(.refused, model: slotModel)
            case .cutOff: return .content(.cutOff, model: slotModel)
            case .malformed: return .content(.malformed, model: slotModel)
            case .badRequest: return .content(.badRequest, model: slotModel)
            case .limited, .serverError, .unreachable: return .service(failure)
            case .noModelSetUp, .keyNeeded, .keyRejected, .modelNotFound: return .setUp(failure)
            }
        } catch {
            // The slot could not be read, or the usage row of this automatic
            // request could not be written (`UsageNotRecorded`): the count
            // of the daily limit cannot be trusted, so automatic work stops.
            guard !Task.isCancelled, !isStopped else { return .cancelled }
            return .storage
        }
        guard !Task.isCancelled, !isStopped else { return .cancelled }
        switch OverviewAcceptance.check(reply: reply, count: job.input.count) {
        case .success(let accepted):
            return .accepted(accepted, model: reply.model)
        case .failure(let failure):
            return slotsGeneration == job.generation ? .content(failure, model: reply.model) : .superseded
        }
    }

    // MARK: - Storing (f)

    private func storeDone(_ job: Job, _ accepted: OverviewAcceptance.Accepted, model: String) async -> OverviewWriteOutcome {
        let highlights = accepted.highlights.map { highlight in
            OverviewHighlight(articleID: job.input[highlight.number - 1].id, text: highlight.text)
        }
        let record = OverviewRecord(
            categoryID: job.category, day: job.day, locale: job.locale, state: .done, text: accepted.summary, highlights: highlights,
            articleCount: job.input.count, coveredUntil: job.input.map(\.firstSeenAt).max(), model: model, failure: nil
        )
        return await store(job, record)
    }

    private func storeFailed(_ job: Job, _ failure: TranslationFailure, model: String?) async -> OverviewWriteOutcome {
        let record = OverviewRecord(
            categoryID: job.category, day: job.day, locale: job.locale, state: .failed, text: nil, highlights: [],
            articleCount: job.input.count, coveredUntil: nil, model: model, failure: failure
        )
        return await store(job, record)
    }

    private func store(_ job: Job, _ record: OverviewRecord) async -> OverviewWriteOutcome {
        await suspend(.store)
        guard !isStopped else { return .cancelled }
        // In a task of its own: a write refuses to start in a cancelled
        // task, and this result is worth keeping.
        let library = library
        let sent = job.input.map(\.id)
        let slots = job.slots
        let result: OverviewStoreResult
        do {
            result = try await Task { try await library.storeOverview(record, sent: sent, slots: slots) }.value
        } catch {
            guard !isStopped else { return .cancelled }
            return block(job, .storage)
        }
        switch result {
        case .stored:
            unblock(job.category)
            report(.stored(job.category))
            return record.failure.map(OverviewWriteOutcome.failed) ?? .stored
        case .doneKept:
            return record.failure.map(OverviewWriteOutcome.failed) ?? .stored
        case .gone:
            return job.automatic ? .cancelled : .gone
        case .slotsChanged:
            return .cancelled
        }
    }

    // MARK: - Blocks and the hold (g)

    private func setUpFailed(_ job: Job, _ failure: ModelFailure) -> OverviewWriteOutcome {
        let outcome = block(job, .setUp(failure))
        if job.generation == slotsGeneration, !isStopped {
            holdGeneration += 1
            hold = Hold(reason: .setUp(failure), slots: job.slots, generation: holdGeneration)
        }
        return outcome
    }

    private func block(_ job: Job, _ reason: OverviewBlock.Reason) -> OverviewWriteOutcome {
        block(job.category, reason, day: job.day, locale: job.locale, automatic: job.automatic, generation: job.generation)
    }

    /// Blocks the category, and, for an automatic job, ends the run: its
    /// remaining categories are blocked with the same reason. Nothing is
    /// blocked when the slots changed since the job read them, or the
    /// writer was stopped.
    private func block(
        _ category: UUID, _ reason: OverviewBlock.Reason, day: String, locale: ReadingLocale, automatic: Bool, generation: Int
    ) -> OverviewWriteOutcome {
        let block = OverviewBlock(reason: reason, day: day, locale: locale)
        guard generation == slotsGeneration, !isStopped else { return .cancelled }
        blocks[category] = block
        if automatic {
            for remaining in automaticQueue {
                blocks[remaining] = block
            }
            automaticQueue = []
            reportWorking()
        }
        report(.blocked(blocks))
        return .notStored(block)
    }

    private func unblock(_ category: UUID) {
        if blocks.removeValue(forKey: category) != nil {
            report(.blocked(blocks))
        }
    }

    // MARK: - Reporting

    private func reportWorking() {
        let working = queuedOrInFlight
        guard working != lastWorking else { return }
        lastWorking = working
        report(.working(working))
    }

    /// Reports in order, without waiting for the app.
    private var reports: Task<Void, Never>?

    private func report(_ event: OverviewEvent) {
        guard let observer else { return }
        let previous = reports
        reports = Task {
            await previous?.value
            await observer(event)
        }
    }

    // MARK: - For the tests

    /// Where the race tests hold the writer: just before the `await` whose
    /// window they test (decision 11's held awaits). Nothing holds it in
    /// the app.
    enum SuspensionPoint: Sendable, Hashable {
        /// A job is about to read (a).
        case jobRead
        /// A request is about to be sent to the slot of this role (d).
        case send(ModelRole)
        /// A service failure is about to look for a usable backup (e).
        case backupCheck
        /// A row is about to be stored (f).
        case store
    }

    private var suspensionHook: (@Sendable (SuspensionPoint) async -> Void)?

    /// Sets the hook the race tests hold the writer with.
    func setSuspensionHook(_ hook: @escaping @Sendable (SuspensionPoint) async -> Void) {
        suspensionHook = hook
    }

    private func suspend(_ point: SuspensionPoint) async {
        if let suspensionHook {
            await suspensionHook(point)
        }
    }

    /// Returns once no job is queued or running and every event has been
    /// reported.
    func settled() async {
        while let worker {
            await worker.value
        }
        await reports?.value
    }

    /// Whether automatic jobs hold after a set-up failure.
    var isHeld: Bool {
        hold != nil
    }

    /// Manual jobs queued and not yet taken.
    var queuedManualJobs: Int {
        manualQueue.count
    }
}
