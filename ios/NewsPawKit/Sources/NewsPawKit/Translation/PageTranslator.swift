import Foundation

/// Whether a page can be translated now (RD16 decision 10).
public enum PageReadiness: Sendable, Hashable {
    /// The primary slot is set up with its key; `hasBackup` when the backup
    /// is too.
    case ready(hasBackup: Bool)
    /// No primary slot, its key is missing, or the slots cannot be read.
    case noModel
}

/// Why runs of a page were not translated (decision 12).
public enum PageFailureReason: Sendable, Hashable {
    /// The model's answer could not be used, after its retry.
    case content(TranslationFailure)
    /// The service failed, and the backup did not help (or there is none).
    case service(ModelFailure)
    /// The slot cannot be used.
    case setUp(ModelFailure)
}

/// Which model a unit goes to.
enum PageRoute: Sendable, Hashable {
    /// The primary, with one retry of a content failure and one attempt on
    /// a usable backup after a service failure.
    case primary
    /// Retry with the Backup Model: each request once to the backup.
    case backupOnly
}

/// What the translator decided for a collection before anything is sent
/// (decision 5).
struct PagePreparation: Sendable {
    /// Runs left as they are (already in the reading language, no letter).
    var kept: [Int] = []
    /// Texts to write without a request: converted on the device, or found
    /// in the session's memory or in `page_text`.
    var writes: [PageWrite] = []
    /// How many of `writes` were converted on the device.
    var converted = 0
    /// The groups to send, in collection order.
    var groups: [PageGroup] = []
}

/// How one unit ended (decision 12).
struct PageUnitOutcome: Sendable {
    /// The accepted translations of the unit's runs.
    var writes: [PageWrite] = []
    /// Groups that failed, with the reason.
    var failed: [(group: PageGroup, reason: PageFailureReason)] = []
    /// Groups not sent because the period's ceiling was reached.
    var paused: [PageGroup] = []
    /// A service or set-up failure that stops sending for the document
    /// until Retry.
    var stop: PageFailureReason?
    /// Requests sent for the unit (retries and backup attempts included).
    var requests = 0
    var cancelled = false
}

/// Translates the text of one browser session's pages (spec N06, N11;
/// RD16 decisions 5, 7, 11 and 12). Made from a `LibraryModels` alone: it
/// sends only through those models and caches only in their library, so
/// text of one library goes only through that library's models. Every
/// request is a usage row with `purpose = page` and `automatic = 0`; none
/// is counted by or held at the daily automatic limit.
///
/// It also keeps the session's memory of translated groups, by host,
/// reading language and the group's exact texts, and the count of the
/// period's requests against the ceiling.
public actor PageTranslator {
    /// The most requests of one period (decision 11).
    public static let standardCeiling = 50
    /// The most groups the memory holds; it is emptied when full.
    static let memoryLimit = 2_000

    private let models: LibraryModels
    private let library: Library
    let ceiling: Int
    /// Requests sent in the current period.
    private(set) var sentInPeriod = 0

    struct MemoryKey: Hashable {
        let host: String
        let locale: ReadingLocale
        let texts: [String]
    }

    private var memory: [MemoryKey: [String]] = [:]

    public init(models: LibraryModels, ceiling: Int = PageTranslator.standardCeiling) {
        self.models = models
        library = models.library
        self.ceiling = max(1, ceiling)
    }

    /// Whether `library` is the library this translator reads and writes
    /// (decision 13).
    public nonisolated func belongs(to library: Library) -> Bool {
        models.belong(to: library)
    }

    // MARK: - Readiness and periods

    public func readiness() async -> PageReadiness {
        guard let statuses = try? await models.statuses(), let primary = statuses[.primary], primary.key != .missing else {
            return .noModel
        }
        return .ready(hasBackup: statuses[.backup].map { $0.key != .missing } ?? false)
    }

    /// A period begins (decision 11): the owner turned translation on, or
    /// tapped Continue or Retry.
    func beginPeriod() {
        sentInPeriod = 0
    }

    // MARK: - Before sending

    /// Judges each block's runs, writes conversions, and looks the groups
    /// to send up in the memory and, for a whole run, in `page_text`
    /// (decision 5). A row that cannot be read is a miss.
    func prepare(_ runs: [PageRun], host: String?, locale: ReadingLocale, pageHasKana: Bool) async -> PagePreparation {
        var preparation = PagePreparation()
        var toLookUp: [(group: PageGroup, key: String)] = []
        var sending: [PageGroup] = []
        for group in PageBatcher.groups(runs) {
            switch TextLanguage.judge(block: group.texts, reading: locale, pageHasKana: pageHasKana) {
            case .keep:
                preparation.kept += group.runs.map(\.id)
            case .converted(let texts):
                for (run, text) in zip(group.runs, texts) {
                    if let text {
                        preparation.writes.append(PageWrite(id: run.id, text: text))
                        preparation.converted += 1
                    } else {
                        preparation.kept.append(run.id)
                    }
                }
            case .send:
                if let host, let found = memory[MemoryKey(host: host, locale: locale, texts: group.texts)] {
                    preparation.writes += zip(group.runs, found).map { PageWrite(id: $0.id, text: $1) }
                } else if group.isCacheable, let key = PageBatcher.cacheKey(host: host, text: group.runs[0].text) {
                    toLookUp.append((group, key))
                    sending.append(group)
                } else {
                    sending.append(group)
                }
            }
        }
        var found: [String: String] = [:]
        if !toLookUp.isEmpty {
            found = (try? await library.pageTexts(toLookUp.map(\.key), locale: locale)) ?? [:]
        }
        var hits = Set<Int>()
        for (group, key) in toLookUp {
            if let text = found[key] {
                preparation.writes.append(PageWrite(id: group.runs[0].id, text: text))
                hits.insert(group.block)
            }
        }
        preparation.groups = sending.filter { !hits.contains($0.block) }
        return preparation
    }

    // MARK: - Sending

    /// Sends one unit (decision 12): on the primary with one retry of a
    /// content failure (a unit of several groups as two halves split at a
    /// group boundary, one group as itself) and one attempt on a usable
    /// backup after a service failure; or, for Retry with the Backup Model,
    /// each request once to the backup. Every attempt counts towards the
    /// period's ceiling; at the ceiling what is left of the unit is paused,
    /// not failed. Accepted translations are kept in the memory, and a
    /// whole, uncut run in `page_text`, unless the work was cancelled.
    func send(_ unit: PageUnit, host: String?, locale: ReadingLocale, route: PageRoute) async -> PageUnitOutcome {
        var outcome = PageUnitOutcome()
        if unit.requests.count == 1 {
            await sendGroups(unit.groups, host: host, locale: locale, route: route, retry: true, into: &outcome)
        } else if let group = unit.groups.first {
            await sendLargeGroup(group, requests: unit.requests, host: host, locale: locale, route: route, into: &outcome)
        }
        return outcome
    }

    /// Sends `groups` in one request; after a content failure on the
    /// primary, `retry` sends them again once (halves at a group boundary).
    private func sendGroups(
        _ groups: [PageGroup], host: String?, locale: ReadingLocale, route: PageRoute, retry: Bool, into outcome: inout PageUnitOutcome
    ) async {
        guard !outcome.cancelled, outcome.stop == nil else { return }
        let entries = groups.flatMap(PageBatcher.entries(of:))
        let role: ModelRole = route == .backupOnly ? .backup : .primary
        switch await attempt(entries, role: role, locale: locale, into: &outcome) {
        case .accepted(let translations, let model):
            await accept(groups, entries: entries, translations: translations, model: model, host: host, locale: locale, into: &outcome)
        case .paused:
            outcome.paused += groups
        case .cancelled:
            outcome.cancelled = true
        case .content(let failure):
            guard route == .primary, retry else {
                outcome.failed += groups.map { ($0, .content(failure)) }
                return
            }
            let parts = groups.count > 1 ? [Array(groups[..<(groups.count / 2)]), Array(groups[(groups.count / 2)...])] : [groups]
            for part in parts {
                if outcome.cancelled {
                    return
                }
                if let stop = outcome.stop {
                    // A service or set-up failure of the other half stops
                    // the document: this half is failed with it.
                    outcome.failed += part.map { ($0, stop) }
                    continue
                }
                await sendGroups(part, host: host, locale: locale, route: .primary, retry: false, into: &outcome)
            }
        case .service(let failure):
            guard route == .primary else {
                outcome.failed += groups.map { ($0, .service(failure)) }
                outcome.stop = .service(failure)
                return
            }
            await sendToBackup(groups, entries: entries, after: failure, host: host, locale: locale, into: &outcome)
        case .setUp(let failure):
            outcome.failed += groups.map { ($0, .setUp(failure)) }
            outcome.stop = .setUp(failure)
        }
    }

    /// After a service failure of the primary: once to a usable backup (a
    /// backup slot whose key is not missing), no retry there. Without one,
    /// or when the backup fails with a service or set-up failure, the
    /// groups fail with the primary's reason and the document stops.
    private func sendToBackup(
        _ groups: [PageGroup], entries: [PageEntry], after failure: ModelFailure, host: String?, locale: ReadingLocale,
        into outcome: inout PageUnitOutcome
    ) async {
        guard await hasUsableBackup() else {
            outcome.failed += groups.map { ($0, .service(failure)) }
            outcome.stop = .service(failure)
            return
        }
        guard !Task.isCancelled else {
            outcome.cancelled = true
            return
        }
        switch await attempt(entries, role: .backup, locale: locale, into: &outcome) {
        case .accepted(let translations, let model):
            await accept(groups, entries: entries, translations: translations, model: model, host: host, locale: locale, into: &outcome)
        case .paused:
            outcome.paused += groups
        case .cancelled:
            outcome.cancelled = true
        case .content(let reason):
            outcome.failed += groups.map { ($0, .content(reason)) }
        case .service, .setUp:
            outcome.failed += groups.map { ($0, .service(failure)) }
            outcome.stop = .service(failure)
        }
    }

    /// One group too large for a request, sent as consecutive requests; a
    /// request that fails with a content failure is sent again once as
    /// itself. The group is written only when every request was accepted.
    private func sendLargeGroup(
        _ group: PageGroup, requests: [[PageEntry]], host: String?, locale: ReadingLocale, route: PageRoute,
        into outcome: inout PageUnitOutcome
    ) async {
        var translations: [String] = []
        var models: [String] = []
        let role: ModelRole = route == .backupOnly ? .backup : .primary
        for entries in requests {
            var tries = route == .primary ? 2 : 1
            var accepted: [String]?
            while accepted == nil, tries > 0 {
                tries -= 1
                switch await attempt(entries, role: role, locale: locale, into: &outcome) {
                case .accepted(let result, let model):
                    accepted = result
                    models.append(model)
                case .paused:
                    outcome.paused.append(group)
                    return
                case .cancelled:
                    outcome.cancelled = true
                    return
                case .content(let failure):
                    if tries == 0 {
                        outcome.failed.append((group, .content(failure)))
                        return
                    }
                case .service(let failure):
                    guard route == .primary else {
                        outcome.failed.append((group, .service(failure)))
                        outcome.stop = .service(failure)
                        return
                    }
                    guard await hasUsableBackup(), !Task.isCancelled else {
                        outcome.failed.append((group, .service(failure)))
                        outcome.stop = .service(failure)
                        return
                    }
                    switch await attempt(entries, role: .backup, locale: locale, into: &outcome) {
                    case .accepted(let result, let model):
                        accepted = result
                        models.append(model)
                    case .paused:
                        outcome.paused.append(group)
                        return
                    case .cancelled:
                        outcome.cancelled = true
                        return
                    case .content(let reason):
                        outcome.failed.append((group, .content(reason)))
                        return
                    case .service, .setUp:
                        outcome.failed.append((group, .service(failure)))
                        outcome.stop = .service(failure)
                        return
                    }
                case .setUp(let failure):
                    outcome.failed.append((group, .setUp(failure)))
                    outcome.stop = .setUp(failure)
                    return
                }
            }
            guard let accepted else { return }
            translations += accepted
        }
        let entries = requests.flatMap { $0 }
        await accept([group], entries: entries, translations: translations, model: models.last ?? "", host: host, locale: locale, into: &outcome)
    }

    private func hasUsableBackup() async -> Bool {
        guard let statuses = try? await models.statuses(), let backup = statuses[.backup] else { return false }
        return backup.key != .missing
    }

    /// How one request ended.
    private enum Attempt {
        case accepted([String], model: String)
        case content(TranslationFailure)
        case service(ModelFailure)
        case setUp(ModelFailure)
        /// The ceiling was reached: nothing was sent.
        case paused
        case cancelled
    }

    /// One request of `entries`, in order, through RD14's acceptance checks;
    /// counted against the ceiling before it is sent.
    private func attempt(_ entries: [PageEntry], role: ModelRole, locale: ReadingLocale, into outcome: inout PageUnitOutcome) async -> Attempt {
        guard !Task.isCancelled else { return .cancelled }
        guard sentInPeriod < ceiling else { return .paused }
        sentInPeriod += 1
        outcome.requests += 1
        let texts = entries.map(\.text)
        let reply: ModelReply
        do {
            reply = try await models.send(
                texts: texts, instructions: TranslationPrompt.page(into: locale), purpose: .page, role: role, automatic: false
            )
        } catch is CancellationError {
            return .cancelled
        } catch let failure as ModelFailure {
            switch TranslationFailureKind(failure) {
            case .content(let reason): return .content(reason)
            case .service(let failure): return .service(failure)
            case .setUp(let failure): return .setUp(failure)
            }
        } catch {
            // The slot could not be read: nothing was sent.
            return .setUp(.noModelSetUp)
        }
        guard !Task.isCancelled else { return .cancelled }
        switch TranslationAcceptance.check(originals: texts, reply: reply) {
        case .success(let translations): return .accepted(translations, model: reply.model)
        case .failure(let failure): return .content(failure)
        }
    }

    // MARK: - Accepting

    /// The runs' translations from the accepted entries (a cut run's pieces
    /// joined), kept in the memory by group and, for a whole uncut run, in
    /// `page_text`. Nothing is kept for cancelled work.
    private func accept(
        _ groups: [PageGroup], entries: [PageEntry], translations: [String], model: String, host: String?, locale: ReadingLocale,
        into outcome: inout PageUnitOutcome
    ) async {
        guard !Task.isCancelled else {
            outcome.cancelled = true
            return
        }
        var byRun: [Int: [String]] = [:]
        for (entry, translation) in zip(entries, translations) {
            byRun[entry.run, default: []].append(translation)
        }
        var cached: [String: String] = [:]
        for group in groups {
            let texts = group.runs.map { PageBatcher.join(byRun[$0.id] ?? [], into: locale) }
            outcome.writes += zip(group.runs, texts).map { PageWrite(id: $0.id, text: $1) }
            if let host {
                if memory.count >= Self.memoryLimit {
                    memory = [:]
                }
                memory[MemoryKey(host: host, locale: locale, texts: group.texts)] = texts
            }
            if group.isCacheable, let key = PageBatcher.cacheKey(host: host, text: group.runs[0].text) {
                cached[key] = texts[0]
            }
        }
        guard !cached.isEmpty else { return }
        // In a task of its own: a write refuses to start in a cancelled
        // task. One that cannot be written is dropped; the page shows the
        // translation.
        let library = library
        _ = await Task { try? await library.storePageTexts(cached, locale: locale, model: model) }.value
    }

    // MARK: - For the tests

    var memoryCount: Int {
        memory.count
    }
}
