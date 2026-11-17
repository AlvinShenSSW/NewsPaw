import Foundation
import Observation

/// What the browser's status line says about page translation (ux S5;
/// RD16 decision 10).
public enum PageTranslationLine: Sendable, Hashable {
    /// "Translating…", with Show Original.
    case translating
    /// "Translated to ⟨language⟩", with Show Original.
    case translated(ReadingLocale)
    /// "Some text could not be translated · ⟨reason⟩", with Retry, and
    /// Retry with the Backup Model when `offersBackup`.
    case failed(PageFailureReason, offersBackup: Bool)
    /// "Some text could not be translated · The page did not respond", with
    /// Retry.
    case didNotRespond
    /// "Some text could not be translated · Translation paused on this long
    /// page", with Continue.
    case paused
    /// "Nothing to translate on this page": `brief` after the owner turned
    /// translation on (it is then off, and the line goes after a moment);
    /// otherwise on a page reached while on, with Show Original.
    case nothingToTranslate(brief: Bool)
    /// "Set up a model to translate", with Open Settings when
    /// `opensSettings`. Translation is off.
    case noModel(opensSettings: Bool)
    /// Translation was turned off and the page did not answer the call that
    /// restores it: "The page did not respond", with Show Original, which
    /// tries again.
    case restoreDidNotRespond
}

/// In-place translation of one browser session's pages (spec N06, N11,
/// N12; RD16 decisions 4 and 8–12): whether it is on, the period's
/// ceiling, the document generations, the poll, the requests in flight and
/// the status line. One per browser session; made with a translator of the
/// workspace's library, or with none (the adult workspace before RD19),
/// which shows "Set up a model to translate" and calls nothing.
///
/// Every await is followed by a check that the session still works on the
/// same document generation (and is still on, where that matters): an
/// answer, an error or an expiry of an older document is dropped silently,
/// and nothing of it is written, stored or shown.
@MainActor @Observable
public final class PageTranslationSession {
    /// The session's timings, shortened by the tests.
    public struct Timing: Sendable {
        /// How often the page is asked for its runs while translation is on.
        public var poll: Duration = .seconds(1)
        /// How long after the page stops scrolling it is asked again.
        public var afterScroll: Duration = .milliseconds(150)
        /// When a document that has not loaded is decided.
        public var decideAfter: Duration = .seconds(10)
        /// How long the brief "Nothing to translate" stays.
        public var briefMessage: Duration = .seconds(4)

        public init() {}
    }

    /// The most units of work in flight at once (decision 5).
    static let maximumInFlight = 2

    /// Whether translation is on: the Translate button is active.
    public private(set) var isOn = false
    /// The status line, or `nil` for none.
    public private(set) var line: PageTranslationLine?

    @ObservationIgnored private let scripting: any PageScripting
    @ObservationIgnored private let translator: PageTranslator?
    @ObservationIgnored private let readingLocale: @MainActor () -> ReadingLocale
    @ObservationIgnored private let isSeen: @MainActor () -> Bool
    @ObservationIgnored private let timing: Timing
    @ObservationIgnored private let clock = ContinuousClock()

    /// A failed group and its reason, in the order failures came.
    private struct Failure {
        let group: PageGroup
        let reason: PageFailureReason
    }

    /// One document of the page in one period of translation being on
    /// (decision 9): from a commit, or from turning translation on, to the
    /// next commit or to turning it off.
    ///
    /// Work for the document lives in three places. `pending` holds the
    /// groups of the latest collection and is replaced by each collection.
    /// `queue` holds work the session owns: Retry's and Retry with the
    /// Backup Model's groups and the deferred rest of units (at the ceiling,
    /// or when the page stopped being seen); no collection replaces it.
    /// `failures` holds what failed; only Retry (once the page says which
    /// runs still hold their originals) or Show Original empties it.
    private struct Document {
        let generation: Int
        /// The lower-cased host of an `http` or `https` document.
        let host: String?
        var locale: ReadingLocale
        /// Translation was turned on by the owner (or by "Translate When
        /// Opened") on this document: nothing to translate turns it off.
        var startedHere = false
        var firstCollection: ContinuousClock.Instant?
        var decided = false
        /// Decided with nothing to translate on a document reached while on.
        var nothing = false
        var hasKana = false
        /// Something was written, converted, sent or is waiting to be sent.
        var didSomething = false
        /// The script state's token this document's runs belong to (from
        /// the first `collect`); every `apply` carries it.
        var token: String?
        /// Prepared groups of the latest collection, waiting to be sent.
        var pending: [PageGroup] = []
        /// Work the session owns, sent before `pending`.
        var queue: [PageWork] = []
        var failures: [Failure] = []
        /// The runs in requests in flight.
        var inFlight: Set<Int> = []
        /// Runs whose translation waits to be written into the page.
        var awaitingWrite: Set<Int> = []
        /// Runs the page confirmed written.
        var written: Set<Int> = []
        /// A service or set-up failure: nothing more is sent until Retry.
        var stopped = false
        /// A call into the page expired or failed: the poll ends until
        /// Retry.
        var unresponsive = false
        /// The period's ceiling was reached.
        var paused = false
        /// A `collect` of this document is outstanding.
        var collecting = false

        /// Whether a run is in a request, queued, failed, waiting for its
        /// write or written: a collection does not send it again.
        func isTaken(_ id: Int) -> Bool {
            inFlight.contains(id) || awaitingWrite.contains(id) || written.contains(id)
                || queue.contains { $0.unit.runIDs.contains(id) } || failures.contains { $0.group.runs.contains { $0.id == id } }
        }

        var latestFailure: PageFailureReason? {
            failures.last?.reason
        }

        var hasRefused: Bool {
            failures.contains { $0.reason == .content(.refused) }
        }
    }

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var document: Document?
    /// Translation was turned on before the first document committed.
    @ObservationIgnored private var startsNextDocument = false
    /// The session wrote into a page: a page shown again from the
    /// back-forward cache while off is restored (decision 8).
    @ObservationIgnored private var translatedAny = false
    @ObservationIgnored private var hasBackup = false
    @ObservationIgnored private var turningOn = false
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var units: [UUID: Task<Void, Never>] = [:]
    /// What waits to be written into the page while the session is not
    /// seen, with its generation.
    @ObservationIgnored private var queued = PageApplyRequest()
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var scrollWait: Task<Void, Never>?
    @ObservationIgnored private var brief: Task<Void, Never>?

    /// - Parameters:
    ///   - translator: the workspace library's page translator, or `nil`
    ///     where the workspace has none.
    ///   - readingLocale: the reading language, read when a document
    ///     starts.
    ///   - isSeen: whether the session's page is on screen: its stack is
    ///     the selected one, the app is active, and no temporary article
    ///     covers it. Nothing calls into the page otherwise, except to end
    ///     translation.
    public init(
        scripting: any PageScripting, translator: PageTranslator?, readingLocale: @escaping @MainActor () -> ReadingLocale,
        isSeen: @escaping @MainActor () -> Bool, timing: Timing = Timing()
    ) {
        self.scripting = scripting
        self.translator = translator
        self.readingLocale = readingLocale
        self.isSeen = isSeen
        self.timing = timing
    }

    // MARK: - The owner's actions

    /// The Translate button: on, or off when on.
    public func toggle() {
        if isOn {
            showOriginal()
        } else {
            turnOn()
        }
    }

    /// Turns translation on for the page shown (the owner's tap, "Always
    /// Translate This Source", or a session opened with "Translate When
    /// Opened"): a period begins. Without a usable primary model it says
    /// so and stays off; nothing is collected.
    public func turnOn() {
        guard !closed, !isOn, !turningOn else { return }
        brief?.cancel()
        guard let translator else {
            line = .noModel(opensSettings: false)
            return
        }
        turningOn = true
        Task {
            let readiness = await translator.readiness()
            if case .ready = readiness {
                await translator.beginPeriod()
            }
            turningOn = false
            guard !closed, !isOn else { return }
            guard case .ready(let backup) = readiness else {
                line = .noModel(opensSettings: true)
                return
            }
            hasBackup = backup
            isOn = true
            if let document {
                // A new period on the same page: a new generation, so that
                // no answer of the period before is taken for this one.
                generation += 1
                self.document = Document(generation: generation, host: document.host, locale: readingLocale(), startedHere: true)
            } else {
                startsNextDocument = true
            }
            refreshLine()
            startPoll()
        }
    }

    /// Show Original, or the Translate button while on: requests in flight
    /// are cancelled (nothing of them is written or stored), the poll stops,
    /// and the page's own text is put back.
    public func showOriginal() {
        guard !closed else { return }
        if isOn {
            isOn = false
            stopWork()
            if let document {
                generation += 1
                self.document = Document(generation: generation, host: document.host, locale: document.locale)
            }
            startsNextDocument = false
        }
        line = nil
        let generation = generation
        Task {
            let ended = await scripting.end(restore: true)
            guard !closed, !isOn, generation == self.generation else { return }
            if case .failure = ended {
                line = .restoreDidNotRespond
            }
        }
    }

    /// Retry: a period begins; the failed runs that still hold their
    /// originals are sent again (with their retry and backup attempt); the
    /// poll starts again if it had ended. The failures stay recorded until
    /// the page has said which runs still hold their originals: if it does
    /// not answer, they stay, and the line says the page did not respond.
    public func retry() {
        guard !closed, isOn, var document, let translator else { return }
        let failures = document.failures
        document.stopped = false
        document.unresponsive = false
        document.paused = false
        self.document = document
        refreshLine()
        let generation = document.generation
        Task {
            await translator.beginPeriod()
            guard isCurrent(generation) else { return }
            await resend(failures, route: .primary, generation: generation)
            startPoll()
        }
    }

    /// Retry with the Backup Model: the refused runs that still hold their
    /// originals go once to the backup, through the same dispatcher as the
    /// rest (two in flight, only while seen).
    public func retryWithBackup() {
        guard !closed, isOn, let document else { return }
        let refused = document.failures.filter { $0.reason == .content(.refused) }
        let generation = document.generation
        Task {
            await resend(refused, route: .backupOnly, generation: generation)
        }
    }

    /// Asks the page which of `failures`' runs still hold their originals,
    /// then queues those runs on `route` and forgets `failures`. If the page
    /// does not answer, nothing is forgotten and the line says so.
    private func resend(_ failures: [Failure], route: PageRoute, generation: Int) async {
        guard !failures.isEmpty else {
            dispatch()
            refreshLine()
            return
        }
        let groups = failures.map(\.group)
        let ids = Set(groups.flatMap { $0.runs.map(\.id) })
        let answer = await holding(groups, generation: generation)
        guard isCurrent(generation), var document = self.document else { return }
        guard let holding = answer else {
            document.unresponsive = true
            self.document = document
            refreshLine()
            return
        }
        document.failures.removeAll { failure in failure.group.runs.contains { ids.contains($0.id) } }
        document.queue += PageBatcher.units(holding).map { PageWork(unit: $0, route: route) }
        self.document = document
        dispatch()
        refreshLine()
    }

    /// Continue, at the ceiling: a period begins and sending goes on.
    public func continueTranslating() {
        guard !closed, isOn, var document, let translator else { return }
        document.paused = false
        self.document = document
        refreshLine()
        let generation = document.generation
        Task {
            await translator.beginPeriod()
            guard isCurrent(generation) else { return }
            dispatch()
            refreshLine()
        }
    }

    // MARK: - The browser's events

    /// A main-frame document committed (a back-forward cache restore
    /// included): a new generation. Work of the old document is cancelled
    /// and dropped; with translation on the poll goes on with the new
    /// document; with it off, a page the session translated before is
    /// restored once, in case it is shown again from the cache.
    public func documentCommitted(_ url: URL?) {
        guard !closed else { return }
        generation += 1
        cancelUnits()
        queued = PageApplyRequest()
        let scheme = url?.scheme?.lowercased()
        let host = scheme == "http" || scheme == "https" ? url?.host(percentEncoded: false)?.lowercased() : nil
        document = Document(generation: generation, host: host, locale: readingLocale(), startedHere: startsNextDocument)
        startsNextDocument = false
        if !isOn {
            // The old document's messages are forgotten.
            brief?.cancel()
            line = nil
            if translatedAny {
                Task { _ = await scripting.end(restore: true) }
            }
        }
        refreshLine()
    }

    /// The page's scroll view moved: the page is asked again once it has
    /// been still for a moment.
    public func scrolled() {
        guard isOn, !closed else { return }
        scrollWait?.cancel()
        let wait = timing.afterScroll
        scrollWait = Task {
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await tick()
        }
    }

    /// The session became seen again (its tab selected, the app active, a
    /// temporary article closed): the poll goes on at once.
    public func becameSeen() {
        guard isOn, !closed else { return }
        Task { await tick() }
    }

    /// The browser session ends (closed, or its workspace dropped): requests
    /// are cancelled, the poll ends, nothing is written or stored.
    public func close() {
        closed = true
        isOn = false
        stopWork()
        brief?.cancel()
        line = nil
    }

    // MARK: - The poll (decision 4)

    /// The poll: a step about once a second. Each step runs in a task of
    /// its own, so that a `collect` a navigation left hanging (A3) does not
    /// hold back the next document's steps; a step does nothing while a
    /// `collect` of its document is outstanding.
    private func startPoll() {
        guard poll == nil, isOn, !closed else { return }
        let interval = timing.poll
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                Task { await self.tick() }
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func stopWork() {
        poll?.cancel()
        poll = nil
        scrollWait?.cancel()
        scrollWait = nil
        cancelUnits()
        queued = PageApplyRequest()
    }

    private func cancelUnits() {
        for task in units.values {
            task.cancel()
        }
        units = [:]
    }

    private func isCurrent(_ generation: Int) -> Bool {
        !closed && isOn && document?.generation == generation
    }

    /// One step of the poll: what waits is written, then the page is asked
    /// for its runs, which are judged, looked up and sent.
    func tick() async {
        guard isOn, !closed, document != nil, isSeen() else { return }
        await flush()
        guard isOn, !closed, var document, !document.unresponsive, !document.collecting, let translator else { return }
        let generation = document.generation
        document.collecting = true
        self.document = document
        let collected = await scripting.collect()
        // An answer of an older document, or one that came after Show
        // Original, is dropped.
        guard isCurrent(generation), var document = self.document else { return }
        // An answer from another script state than this document's (a
        // state ended and made again) addresses other nodes: dropped.
        if case .success(let collection) = collected, let token = document.token, collection.state != token {
            document.collecting = false
            self.document = document
            return
        }
        let result: PageCollection
        switch collected {
        case .failure:
            document.collecting = false
            document.unresponsive = true
            self.document = document
            refreshLine()
            return
        case .success(let collection):
            result = collection
        }
        document.token = result.state
        if document.firstCollection == nil {
            document.firstCollection = clock.now
        }
        // A document shown again from the back-forward cache holds the
        // translations written before: it is not "nothing to translate".
        if result.written {
            document.didSomething = true
            document.nothing = false
        }
        switch result {
        case .held:
            // A field has focus: nothing is decided until it leaves.
            document.collecting = false
            self.document = document
        case .unchanged(let loaded, _, _):
            document.collecting = false
            self.document = document
            decide(loaded: loaded)
            // What waits (the page was not seen, or both slots were busy)
            // goes now.
            dispatch()
        case .runs(let runs, let loaded, _, _):
            if runs.contains(where: { TextLanguage.Units($0.text).kana > 0 }) {
                document.hasKana = true
            }
            let fresh = runs.filter { !document.isTaken($0.id) }
            self.document = document
            // The document stays "collecting" until its runs are prepared,
            // so that no second step prepares the same runs meanwhile.
            let preparation = await translator.prepare(fresh, host: document.host, locale: document.locale, pageHasKana: document.hasKana)
            guard isCurrent(generation), var document = self.document else { return }
            document.collecting = false
            // Runs that went into a request, failed or were translated
            // while they were prepared are not sent again.
            document.pending = preparation.groups.filter { group in !group.runs.contains { document.isTaken($0.id) } }
            if !preparation.writes.isEmpty || !preparation.groups.isEmpty {
                document.didSomething = true
                document.nothing = false
            }
            self.document = document
            queue(PageApplyRequest(writes: preparation.writes, settle: preparation.kept))
            decide(loaded: loaded)
            dispatch()
            await flush()
        }
        refreshLine()
    }

    /// Decides the document once it has loaded, or `decideAfter` after its
    /// first collection (decision 10): with nothing sent, written or
    /// waiting, there is nothing to translate.
    private func decide(loaded: Bool) {
        guard var document, !document.decided, let first = document.firstCollection else { return }
        guard loaded || clock.now - first >= timing.decideAfter else { return }
        document.decided = true
        self.document = document
        guard !document.didSomething, units.isEmpty else { return }
        if document.startedHere {
            // On the owner's tap: a brief message, and translation is off.
            isOn = false
            stopWork()
            line = .nothingToTranslate(brief: true)
            let wait = timing.briefMessage
            brief?.cancel()
            brief = Task {
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled, line == .nothingToTranslate(brief: true) else { return }
                line = nil
            }
            Task { _ = await scripting.end(restore: true) }
        } else {
            document.nothing = true
            self.document = document
        }
    }

    // MARK: - Sending (decisions 5, 11 and 12)

    /// The one dispatcher of every route (decision 5): it starts work while
    /// fewer than two units are in flight, the document is neither stopped
    /// nor paused nor unresponsive, and the page is seen — first the
    /// session's queue (retries, backup retries, deferred work), then the
    /// latest collection's groups.
    private func dispatch() {
        guard isOn, !closed, let document, !document.stopped, !document.unresponsive, !document.paused, isSeen() else { return }
        while units.count < Self.maximumInFlight, var current = self.document {
            let work: PageWork
            if !current.queue.isEmpty {
                work = current.queue.removeFirst()
            } else if let next = PageBatcher.nextUnit(from: current.pending) {
                current.pending = next.rest
                work = PageWork(unit: next.unit, route: .primary)
            } else {
                break
            }
            self.document = current
            start(work)
        }
    }

    private func start(_ work: PageWork) {
        guard let translator, var document else { return }
        document.inFlight.formUnion(work.unit.runIDs)
        document.didSomething = true
        document.nothing = false
        self.document = document
        let id = UUID()
        let generation = document.generation
        let host = document.host
        let locale = document.locale
        units[id] = Task { [weak self] in
            // Every attempt after the unit's first asks whether the session
            // may go on: still on, on this document, and seen (decision 11).
            let outcome = await translator.send(work, host: host, locale: locale, mayContinue: { [weak self] in
                await self?.mayContinue(generation) ?? false
            })
            self?.unitEnded(id, work: work, outcome: outcome, generation: generation)
        }
    }

    /// Whether a unit of `generation` may send its next request.
    private func mayContinue(_ generation: Int) -> Bool {
        isCurrent(generation) && isSeen()
    }

    private func unitEnded(_ id: UUID, work: PageWork, outcome: PageUnitOutcome, generation: Int) {
        // A unit cancelled by a commit or by Show Original is no longer
        // listed; its result is dropped.
        guard units.removeValue(forKey: id) != nil, isCurrent(generation), var document else { return }
        document.inFlight.subtract(work.unit.runIDs)
        var request = PageApplyRequest(writes: outcome.writes)
        for (group, reason) in outcome.failed {
            document.failures.append(Failure(group: group, reason: reason))
            request.settle += group.runs.map(\.id)
        }
        // What the unit could not send goes back to the front of the queue,
        // with what it accepted.
        document.queue.insert(contentsOf: outcome.deferred, at: 0)
        if outcome.atCeiling {
            document.paused = true
        }
        if outcome.stop != nil {
            document.stopped = true
        }
        self.document = document
        queue(request)
        dispatch()
        refreshLine()
        Task { await flush() }
    }

    /// The groups' runs that still hold their originals, asked of the page;
    /// `nil` when the page did not answer.
    private func holding(_ groups: [PageGroup], generation: Int) async -> [PageGroup]? {
        let ids = groups.flatMap { $0.runs.map(\.id) }
        let token = document?.token
        guard case .success(let applied) = await scripting.apply(PageApplyRequest(check: ids, state: token)), !applied.foreign,
              isCurrent(generation)
        else { return nil }
        let holding = Set(applied.holding)
        return groups.compactMap { group in
            let runs = group.runs.filter { holding.contains($0.id) }
            return runs.isEmpty ? nil : PageGroup(block: group.block, runs: runs)
        }
    }

    // MARK: - Writing into the page (decision 6)

    /// Queues writes and settled runs; written runs wait for the page's
    /// confirmation.
    private func queue(_ request: PageApplyRequest) {
        queued.writes += request.writes
        queued.settle += request.settle
        document?.awaitingWrite.formUnion(request.writes.map(\.id))
    }

    /// Writes what waits, while the page is seen. A run counts as written
    /// only once the page says so; a write the page did not answer, or
    /// skipped, lets its run be collected again (its translation then comes
    /// from the memory, without a request).
    private func flush() async {
        guard isOn, !closed, !queued.isEmpty, let document, isSeen() else { return }
        var request = queued
        request.state = document.token
        queued = PageApplyRequest()
        let generation = document.generation
        let applied = await scripting.apply(request)
        guard isCurrent(generation), var document = self.document else { return }
        document.awaitingWrite.subtract(request.writes.map(\.id))
        switch applied {
        case .success(let result):
            document.written.formUnion(result.written)
            if !result.written.isEmpty {
                translatedAny = true
            }
        case .failure:
            document.unresponsive = true
        }
        self.document = document
        refreshLine()
    }

    // MARK: - The line (decision 10)

    private func refreshLine() {
        guard !closed else {
            line = nil
            return
        }
        guard isOn else {
            switch line {
            case .nothingToTranslate(brief: true), .noModel, .restoreDidNotRespond: break
            default: line = nil
            }
            return
        }
        guard let document else {
            line = .translating
            return
        }
        if document.paused {
            line = .paused
        } else if document.unresponsive {
            line = .didNotRespond
        } else if let failure = document.latestFailure {
            line = .failed(failure, offersBackup: failure == .content(.refused) && hasBackup && document.hasRefused)
        } else if document.nothing && units.isEmpty && document.pending.isEmpty && document.queue.isEmpty {
            line = .nothingToTranslate(brief: false)
        } else if !units.isEmpty || !document.decided || !document.pending.isEmpty || !document.queue.isEmpty || !queued.isEmpty
            || !document.awaitingWrite.isEmpty {
            line = .translating
        } else {
            line = .translated(document.locale)
        }
    }

    // MARK: - For the tests

    var unitsInFlight: Int {
        units.count
    }

    var currentGeneration: Int {
        generation
    }
}
