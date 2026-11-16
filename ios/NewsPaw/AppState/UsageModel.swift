import Foundation
import NewsPawKit

/// Settings › Usage of one workspace (spec N11; ux S8; RD17 decisions 1, 4
/// and 5): the totals of a period, the daily automatic limit and today's
/// automatic requests, all of the workspace's own library — never another
/// library and never the normal library's models. It reads when the
/// screen appears, when the period changes and after a limit is stored; it
/// does not follow new requests while the screen stays. It has no call
/// into translation: the translator reads the limit before every automatic
/// request (decision 6).
@MainActor @Observable
final class UsageModel {
    /// The requests of one model in the period, its purposes in
    /// `UsagePurpose` order.
    struct ModelUsage: Identifiable, Equatable {
        let model: String
        let totals: [UsageTotal]

        var id: String { model }

        /// All requests of the model, saturating.
        var requests: Int {
            totals.reduce(0) { sum, total in
                let (added, overflow) = sum.addingReportingOverflow(total.requests)
                return overflow ? Int.max : added
            }
        }
    }

    /// What the screen shows: nothing yet, what was read, or that it could
    /// not be read.
    enum Content: Equatable {
        case loading
        case loaded(Snapshot)
        case failed
    }

    /// One read of the library.
    struct Snapshot: Equatable {
        let period: UsagePeriod
        /// Ordered by total requests, most first, then by name.
        let models: [ModelUsage]
        let limit: Int
        let automaticToday: Int
    }

    /// The limit's fixed choices (decision 5). 0 is not one of them; a
    /// stored value outside them is shown as its own row.
    static let limitChoices = [50, 100, 200, 500, 1_000, 2_000]

    private(set) var content = Content.loading
    /// Whether a limit is being stored: the picker is disabled meanwhile,
    /// so writes are applied in the order chosen.
    private(set) var isStoringLimit = false
    /// The limit chosen and being stored, shown selected until the write
    /// ends.
    private(set) var pendingLimit: Int?
    /// Whether "The change could not be saved." is shown.
    var isShowingSaveError = false

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let calendar: Calendar
    /// Counts the reads, so that only the latest one's result is shown.
    @ObservationIgnored private var reads = 0
    @ObservationIgnored private var isStopped = false

    /// - Parameter library: the library of the workspace this model belongs
    ///   to, and no other (decision 1).
    init(library: Library, now: @escaping @Sendable () -> Date, calendar: Calendar) {
        self.library = library
        self.now = now
        self.calendar = calendar
    }

    /// The limit's rows: the fixed choices, and the stored value in its
    /// place when it is none of them.
    var limitOptions: [Int] {
        guard case .loaded(let snapshot) = content, !Self.limitChoices.contains(snapshot.limit) else { return Self.limitChoices }
        return (Self.limitChoices + [snapshot.limit]).sorted()
    }

    /// The limit the picker shows selected.
    var selectedLimit: Int? {
        if let pendingLimit {
            return pendingLimit
        }
        if case .loaded(let snapshot) = content {
            return snapshot.limit
        }
        return nil
    }

    /// Reads the totals of `period`, the limit and today's automatic
    /// requests. A failure of any of them shows "Usage could not be read."
    /// until the next read. A read that a later one overtook, or that ends
    /// after the workspace was dropped, is dropped.
    func load(_ period: UsagePeriod) async {
        guard !isStopped else { return }
        reads += 1
        let read = reads
        let instant = now()
        let start = period.start(now: instant, calendar: calendar)
        let today = UsagePeriod.today.start(now: instant, calendar: calendar)
        let library = library
        let result: Content
        do {
            let totals = try await library.usageTotals(since: start)
            let limit = try await library.dailyAutomaticLimit()
            let automaticToday = try await library.automaticRequestCount(since: today)
            result = .loaded(Snapshot(period: period, models: Self.byModel(totals), limit: limit, automaticToday: automaticToday))
        } catch {
            result = .failed
        }
        guard !isStopped, read == reads else { return }
        content = result
    }

    /// Stores `limit` at once (decision 5) and reads again; one write at a
    /// time. A failure says so, and the stored value is read and shown
    /// again.
    func chooseLimit(_ limit: Int, period: UsagePeriod) async {
        guard !isStopped, !isStoringLimit, limit != selectedLimit else { return }
        isStoringLimit = true
        pendingLimit = limit
        defer {
            isStoringLimit = false
            pendingLimit = nil
        }
        do {
            try await library.setDailyAutomaticLimit(limit)
        } catch {
            guard !isStopped else { return }
            isShowingSaveError = true
        }
        guard !isStopped else { return }
        await load(period)
    }

    /// The workspace is dropped (RD18 decision 4): a read or a write in
    /// flight keeps nothing of its result, nothing new starts, and no alert
    /// is raised.
    func stop() {
        isStopped = true
        isShowingSaveError = false
    }

    /// The totals grouped by model: most requests first, then by name.
    static func byModel(_ totals: [UsageTotal]) -> [ModelUsage] {
        Dictionary(grouping: totals, by: \.model)
            .map { model, totals in
                let order = Dictionary(uniqueKeysWithValues: UsagePurpose.allCases.enumerated().map { ($1, $0) })
                return ModelUsage(model: model, totals: totals.sorted { order[$0.purpose, default: 0] < order[$1.purpose, default: 0] })
            }
            .sorted { first, second in
                first.requests != second.requests ? first.requests > second.requests : first.model < second.model
            }
    }
}
