import Foundation
import Observation
import SwiftUI

/// One scheduled edition as the overview shows it (interaction-spec §4.3).
struct Occurrence: Decodable, Identifiable, Equatable {
    let id: String
    let subscriptionId: String
    let accountId: String?
    let slot: Int
    let civilDate: String
    let targetAt: String?
    let prepareAt: String?
    let status: String
    let reason: String?
    let jobId: String?
    let updatedAt: String
}

/// What the owner sees for an occurrence and what they can do about it.
enum OccurrenceState: Equatable {
    case waiting, preparing, late, delivered, partial, skipped, paused, abandoned
    case modelUnknown, deliveryUnknown, held, failed, jobPaused

    init(_ occurrence: Occurrence, paused: Bool, abandoned: Bool) {
        let open: Set<String> = ["planned", "preparing", "waiting", "late", "delivering", "blocked"]
        if abandoned {
            self = .abandoned
        } else if paused, open.contains(occurrence.status) {
            self = .paused
        } else if ["waiting", "late"].contains(occurrence.status), occurrence.reason == "job_paused" {
            // This one edition was paused (jobs.pause or Telegram); it waits for a resume.
            self = .jobPaused
        } else if ["waiting", "late", "outcome_unknown"].contains(occurrence.status),
                  occurrence.reason == "model_outcome_unknown" {
            // An unknown model result is reported as soon as it happens, not only after the
            // catch-up window ends (scheduler records it as waiting/late with this reason).
            self = .modelUnknown
        } else if ["waiting", "late", "outcome_unknown"].contains(occurrence.status),
                  occurrence.reason == "delivery_outcome_unknown" {
            self = .deliveryUnknown
        } else {
            switch occurrence.status {
            case "planned": self = .waiting
            case "preparing", "waiting", "delivering": self = .preparing
            case "late": self = .late
            case "delivered": self = .delivered
            case "partial": self = .partial
            case "no_news", "skipped", "superseded", "rescheduled": self = .skipped
            case "outcome_unknown": self = occurrence.reason == "model_outcome_unknown" ? .modelUnknown : .deliveryUnknown
            case "held": self = .held
            default: self = .failed
            }
        }
    }

    var dot: Color {
        switch self {
        case .delivered: .green
        case .late, .partial, .modelUnknown, .deliveryUnknown, .held: .orange
        case .failed: .red
        default: .gray
        }
    }

    var title: Words {
        switch self {
        case .waiting: L10n.Overview.waiting
        case .preparing: L10n.Overview.preparing
        case .late: L10n.Overview.late
        case .delivered: L10n.Overview.delivered
        case .partial: L10n.Overview.partial
        case .skipped: L10n.Overview.skipped
        case .paused: L10n.Shell.paused
        case .jobPaused: L10n.Overview.jobPaused
        case .abandoned: L10n.Overview.abandoned
        case .modelUnknown, .deliveryUnknown: L10n.Overview.unknown
        case .held: L10n.Overview.held
        case .failed: L10n.Overview.failed
        }
    }
}

/// Loads the overview's data whenever the page is visible.
@MainActor @Observable
final class OverviewData {
    private(set) var today: [Occurrence] = []
    private(set) var week: [Occurrence] = []
    private(set) var abandoned: Set<String> = []
    /// Editions with a delivery part whose outcome is unknown (the only parts recovery can act on).
    private(set) var unknownParts: Set<String> = []
    /// The Bots each delivered edition today actually went to (its delivery record).
    private(set) var recipients: [String: [String]] = [:]
    /// The digests (and X accounts with their own times) used for today's later slots, kept for
    /// reloads after a recovery action.
    private var subscriptions: [AppConfig.Subscription] = []
    private var accounts: [AppConfig.Account] = []
    private(set) var spending: Spending?
    private(set) var staleSources: [(id: String, name: String, days: Int)] = []
    private(set) var failure: BackendError?
    private(set) var working: String?

    struct Spending: Equatable {
        var used: Int
        var limit: Int?
        var image: Int
        var unpriced: Int
        var xReads: Int?
        var xLimit: Int?
    }

    func load(_ client: BackendClient, now: Date = Date(), subscriptions: [AppConfig.Subscription]? = nil,
              accounts: [AppConfig.Account]? = nil) async {
        if let subscriptions { self.subscriptions = subscriptions }
        if let accounts { self.accounts = accounts }
        let subscriptions = self.subscriptions
        let accounts = self.accounts
        do {
            let schedule = try await client.call(.scheduleStatus, ["limit": 100])
            let rows = try BackendRPC.decode(schedule) as ScheduleRows
            let day = Self.day(now)
            let start = Self.day(Calendar.current.date(byAdding: .day, value: -6, to: now) ?? now)
            let scheduled = rows.occurrences.filter { Self.localDay($0) == day }
            today = (scheduled + Self.upcoming(subscriptions, accounts: accounts, existing: rows.occurrences, now: now))
                .sorted(by: Self.byTarget)
            week = rows.occurrences.filter { Self.localDay($0) >= start && Self.localDay($0) < day }
                .sorted { Self.localDay($0) != Self.localDay($1) ? Self.localDay($0) > Self.localDay($1) : Self.byTarget($1, $0) }
            var skipped: Set<String> = []
            var unknown: Set<String> = []
            for row in today + week where Self.mayHaveSkippedParts(row) {
                guard let job = row.jobId else { continue }
                do {
                    let parts = try await Self.parts(job, client).flatMap(\.1)
                    let open = parts.contains { $0.state == "outcome_unknown" }
                    if open { unknown.insert(row.id) }
                    // Abandoned only once no part is left unresolved: a skip on one Bot must not
                    // hide another Bot's part that is still unknown.
                    if !open, parts.contains(where: { $0.resolution?.action == "skip" }) { skipped.insert(row.id) }
                } catch let error as BackendError where error.code == "missing_delivery" {
                    // Stopped before delivery: there is nothing to skip, and nothing to show as failed.
                }
            }
            abandoned = skipped
            unknownParts = unknown
            var sent: [String: [String]] = [:]
            for row in today where ["delivered", "partial"].contains(row.status) {
                guard let job = row.jobId else { continue }
                if let summary: DeliveryStatus = try? BackendRPC.decode(await client.call(.deliveryStatus, ["job_id": job])) {
                    sent[row.id] = summary.targets.filter { ["delivered", "partial"].contains($0.value.status ?? "") }.keys.sorted()
                }
            }
            recipients = sent
            spending = Self.spending(try BackendRPC.decode(await client.call(.budgetGet)), now: now)
            let sources: [SourceHealth] = try BackendRPC.decode(await client.call(.sourcesList))
            staleSources = sources.compactMap { item in
                guard item.source.enabled, item.health?.freshness == "stale" else { return nil }
                let latest = item.health?.latestPublication.flatMap(Self.date)
                let days = latest.map { max(1, Int(now.timeIntervalSince($0) / 86_400)) } ?? 0
                return (item.source.id, item.source.name, days)
            }
            failure = nil
        } catch let error as BackendError {
            failure = error
        } catch {
            failure = BackendError(code: error is SocketFailure ? "backend_unreachable" : "invalid_reply")
        }
    }

    /// Runs one recovery action, then reloads. Duplicate-risk actions are confirmed by the caller.
    func resolve(_ occurrence: Occurrence, _ action: Recovery, client: BackendClient) async {
        working = occurrence.id
        defer { working = nil }
        do {
            switch action {
            case .retryModel:
                guard let job = occurrence.jobId else { return }
                _ = try await client.call(.jobsResume, ["job_id": job, "acknowledge_duplicate_charge": true])
            case .resumeJob:
                guard let job = occurrence.jobId else { return }
                _ = try await client.call(.jobsResume, ["job_id": job])
            case .retryDelivery, .stopResending:
                guard let job = occurrence.jobId else { return }
                for (bot, parts) in try await Self.parts(job, client) {
                    for (index, part) in parts.enumerated() where part.state == "outcome_unknown" {
                        let ordinal = part.ordinal ?? index
                        var fields: [String: Any] = ["job_id": job, "bot_id": bot, "ordinal": ordinal]
                        if action == .retryDelivery {
                            fields["action"] = "retry"
                            fields["acknowledge_duplicate_send"] = true
                        } else {
                            fields["action"] = "skip"
                        }
                        _ = try await client.call(.deliveryResolve, fields)
                    }
                }
            case .continueHeld, .stopHeld:
                _ = try await client.call(.scheduleResolve, [
                    "occurrence_id": occurrence.id, "action": action == .continueHeld ? "continue" : "stop",
                ])
            }
            failure = nil
        } catch let error as BackendError {
            failure = error
        } catch {
            failure = BackendError(code: error is SocketFailure ? "backend_unreachable" : "invalid_reply")
        }
        // The reload must not hide why the action did not complete.
        let refused = failure
        await load(client)
        if let refused { failure = refused }
    }

    enum Recovery: Equatable { case retryModel, retryDelivery, stopResending, continueHeld, stopHeld, resumeJob }

    private struct ScheduleRows: Decodable { let occurrences: [Occurrence] }

    /// `delivery.status` lists parts only when asked for one Bot (outbox.status).
    private struct DeliveryStatus: Decodable {
        struct Target: Decodable { let status: String?; let parts: [Part]? }
        struct Part: Decodable {
            let ordinal: Int?
            let state: String
            let resolution: Resolution?
        }
        struct Resolution: Decodable { let action: String }
        let targets: [String: Target]
    }

    private struct SourceHealth: Decodable {
        struct Source: Decodable { let id: String; let name: String; let enabled: Bool }
        struct Health: Decodable { let freshness: String; let latestPublication: String? }
        let source: Source
        let health: Health?
    }

    private struct BudgetReply: Decodable {
        struct Document: Decodable {
            struct Model: Decodable { let monthlyLimit: Int? }
            struct X: Decodable { let dailyLimit: Int? }
            let model: Model
            let x: X
        }
        struct Report: Decodable { let periods: [Period] }
        struct Period: Decodable {
            struct Scope: Decodable { let limit: Int?; let used: Int }
            struct Scopes: Decodable { let total: Scope; let image: Scope? }
            let meter, start, end: String
            let knownSettled, held, unpriced: Int
            let scopes: Scopes
        }
        let document: Document
        let report: Report
    }

    /// Rows whose parts may carry a skip resolution, including an open edition still waiting
    /// on an unknown delivery (scheduler keeps it `waiting`/`late` until it settles).
    nonisolated static func mayHaveSkippedParts(_ row: Occurrence) -> Bool {
        ["partial", "skipped", "outcome_unknown"].contains(row.status)
            || (["waiting", "late"].contains(row.status) && row.reason == "delivery_outcome_unknown")
            // Every unknown part skipped before any arrived: the scheduler records it as blocked.
            || (row.status == "blocked" && row.reason == "targets_unavailable")
    }

    /// Each target Bot's parts for a job: the summary names the Bots, then each is read alone.
    /// Whether the owner chose not to resend and nothing is left unknown (the overview's rule),
    /// for other pages that show an edition's state.
    static func isAbandoned(_ row: Occurrence, client: BackendClient) async throws -> Bool {
        guard mayHaveSkippedParts(row), let job = row.jobId else { return false }
        do {
            let parts = try await Self.parts(job, client).flatMap(\.1)
            return !parts.contains { $0.state == "outcome_unknown" } && parts.contains { $0.resolution?.action == "skip" }
        } catch let error as BackendError where error.code == "missing_delivery" {
            return false
        }
    }

    private static func parts(_ job: String, _ client: BackendClient) async throws -> [(String, [DeliveryStatus.Part])] {
        let summary: DeliveryStatus = try BackendRPC.decode(await client.call(.deliveryStatus, ["job_id": job]))
        var result: [(String, [DeliveryStatus.Part])] = []
        for bot in summary.targets.keys.sorted() {
            let detail: DeliveryStatus = try BackendRPC.decode(await client.call(.deliveryStatus, ["job_id": job, "bot_id": bot]))
            result.append((bot, detail.targets[bot]?.parts ?? []))
        }
        return result
    }

    /// The day an edition belongs to on this Mac: its target time in the local time zone (a
    /// digest's own `civil_date` is in the digest's zone), else its civil date.
    nonisolated static func localDay(_ row: Occurrence) -> String {
        row.targetAt.flatMap(date).map(day) ?? row.civilDate
    }

    /// The scheduler still sends a retried part only while its edition is open; after the
    /// catch-up window it is terminal and a retry would never run.
    nonisolated static func canRetryDelivery(_ row: Occurrence) -> Bool {
        ["waiting", "late", "delivering", "preparing"].contains(row.status)
    }

    /// Likewise a model retry runs only while the edition is open: `jobs.resume` does not reopen
    /// a terminal occurrence.
    nonisolated static func canRetryModel(_ row: Occurrence) -> Bool {
        ["waiting", "late"].contains(row.status)
    }

    /// The scheduler's rule (`resolve_wall_time`): the earliest instant showing that wall time,
    /// or, inside a daylight-saving gap, the first valid minute after it.
    nonisolated static func resolveWallTime(_ civil: DateComponents, hour: Int, minute: Int, calendar: Calendar) -> Date? {
        for step in 0..<(24 * 60 - (hour * 60 + minute)) {
            var wall = civil
            wall.hour = hour + (minute + step) / 60
            wall.minute = (minute + step) % 60
            guard let guess = calendar.date(from: wall) else { continue }
            let matches = [-3_600.0, 0, 3_600].map { guess.addingTimeInterval($0) }.filter { instant in
                let shown = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: instant)
                return shown.year == wall.year && shown.month == wall.month && shown.day == wall.day
                    && shown.hour == wall.hour && shown.minute == wall.minute
            }
            if let earliest = matches.min() { return earliest }
        }
        return nil
    }

    /// Today's slots that the scheduler has not created yet (it creates an occurrence only when
    /// preparation starts), so the list shows the whole day. Mirrors the scheduler's scopes
    /// (`_scopes`): each enabled digest, and each special X account with a remote id under an
    /// enabled digest, on its own times or the digest's. A slot already present is not repeated.
    nonisolated static func upcoming(_ subscriptions: [AppConfig.Subscription], accounts: [AppConfig.Account] = [],
                                     existing: [Occurrence], now: Date) -> [Occurrence] {
        let today = day(now)
        func key(_ subscription: String, _ account: String?, _ instant: Date) -> String {
            "\(subscription)|\(account ?? "")@\(Int(instant.timeIntervalSince1970))"
        }
        let taken = Set(existing.compactMap { row in row.targetAt.flatMap(date).map { key(row.subscriptionId, row.accountId, $0) } })
        let enabled = Dictionary(uniqueKeysWithValues: subscriptions.filter(\.enabled).map { ($0.id, $0) })
        var scopes: [(subscription: AppConfig.Subscription, account: String?, times: [String])] =
            subscriptions.filter(\.enabled).map { ($0, nil, $0.times) }
        for account in accounts where account.priority == "special" && account.remoteId != nil {
            guard let subscription = account.subscriptionId.flatMap({ enabled[$0] }) else { continue }
            scopes.append((subscription, account.id, account.times ?? subscription.times))
        }
        var result: [Occurrence] = []
        for scope in scopes {
            guard let zone = TimeZone(identifier: scope.subscription.timezone) else { continue }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            for offset in -1...1 {
                guard let base = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
                let civil = calendar.dateComponents([.year, .month, .day], from: base)
                for (slot, time) in scope.times.sorted().enumerated() {
                    let parts = time.split(separator: ":").compactMap { Int($0) }
                    guard parts.count == 2,
                          let target = resolveWallTime(civil, hour: parts[0], minute: parts[1], calendar: calendar),
                          target > now, day(target) == today,
                          !taken.contains(key(scope.subscription.id, scope.account, target)) else { continue }
                    let formatter = ISO8601DateFormatter()
                    formatter.timeZone = zone
                    let civilDate = String(format: "%04d-%02d-%02d", civil.year ?? 0, civil.month ?? 0, civil.day ?? 0)
                    result.append(Occurrence(
                        id: "upcoming.\(scope.subscription.id).\(scope.account ?? "-").\(civilDate).\(time)",
                        subscriptionId: scope.subscription.id, accountId: scope.account,
                        slot: slot + 1, civilDate: civilDate, targetAt: formatter.string(from: target), prepareAt: nil,
                        status: "planned", reason: nil, jobId: nil, updatedAt: formatter.string(from: now)
                    ))
                }
            }
        }
        return result
    }

    /// Target-time order across time zones: compare instants, not the offset strings.
    nonisolated static func byTarget(_ a: Occurrence, _ b: Occurrence) -> Bool {
        switch (a.targetAt.flatMap(date), b.targetAt.flatMap(date)) {
        case let (x?, y?): x != y ? x < y : a.id < b.id
        case (_?, nil): true
        case (nil, _?): false
        default: a.id < b.id
        }
    }

    private static func spending(_ reply: BudgetReply, now: Date) -> Spending {
        let current = reply.report.periods.filter { period in
            guard let start = date(period.start), let end = date(period.end) else { return false }
            return start <= now && now < end
        }
        let model = current.first { $0.meter == "model" }
        let x = current.first { $0.meter == "x" }
        // Before the first paid call of a period there is no period row yet; the policy
        // still holds the cap that will apply.
        return Spending(
            used: model.map { $0.knownSettled + $0.held } ?? 0,
            limit: model?.scopes.total.limit ?? reply.document.model.monthlyLimit,
            image: model?.scopes.image?.used ?? 0,
            unpriced: model?.unpriced ?? 0,
            xReads: x?.scopes.total.used ?? 0,
            xLimit: x?.scopes.total.limit ?? reply.document.x.dailyLimit
        )
    }

    nonisolated static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    nonisolated static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    nonisolated static func clock(_ text: String?) -> String {
        guard let text, let value = date(text) else { return "--:--" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: value)
    }
}

/// Dollars with two decimals from micro-dollars; amounts never appear in µUSD.
func dollars(_ micro: Int) -> String {
    String(format: "$%.2f", Double(micro) / 1_000_000)
}

struct OverviewPage: View {
    let model: AppModel
    @State private var data = OverviewData()
    @State private var showWeek = false
    @State private var confirming: (Occurrence, OverviewData.Recovery)?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(dateLine).font(.callout).foregroundStyle(.secondary)
            if let failure = data.failure { FailureNote(model: model, failure: failure) }
            if let readiness = model.readiness, !readiness.complete {
                SetupChecklist(model: model, readiness: readiness, data: data)
            }
            HStack(alignment: .top, spacing: 20) {
                deliveries.frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 20) {
                    spendingSection
                    AttentionSection(model: model, data: data)
                }
                .frame(width: 300)
            }
        }
        .task(id: model.configRevision) {
            while !Task.isCancelled {
                await data.load(model.client, subscriptions: model.config?.subscriptions ?? [], accounts: model.config?.accounts ?? [])
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SendNowMenu(model: model) { await data.load(model.client, subscriptions: model.config?.subscriptions ?? [], accounts: model.config?.accounts ?? []) }
            }
        }
        .confirmationDialog(
            confirming.map { model.text(confirmTitle($0.1)) } ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
        ) {
            if let (row, action) = confirming {
                Button(model.text(confirmButton(action))) {
                    Task { await data.resolve(row, action, client: model.client) }
                }
                Button(model.text(L10n.Shell.cancel), role: .cancel) {}
            }
        } message: {
            if let (_, action) = confirming { Text(model.text(confirmBody(action))) }
        }
    }

    private var dateLine: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: model.uiLanguage.rawValue)
        formatter.dateStyle = .full
        return formatter.string(from: Date()) + " · " + TimeZone.current.identifier
    }

    @ViewBuilder private var deliveries: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.text(L10n.Overview.today)).font(.headline)
                Spacer()
                Button(model.text(showWeek ? L10n.Overview.hideWeek : L10n.Overview.showWeek)) { showWeek.toggle() }
                    .buttonStyle(.link)
            }
            GroupBox {
                if data.today.isEmpty {
                    Text(model.text(L10n.Overview.nothingToday)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                } else {
                    VStack(spacing: 0) {
                        ForEach(data.today) { row in
                            OccurrenceRow(model: model, data: data, row: row) { confirming = (row, $0) }
                            if row.id != data.today.last?.id { Divider() }
                        }
                    }
                }
            }
            if showWeek {
                GroupBox {
                    VStack(spacing: 0) {
                        ForEach(data.week) { row in
                            OccurrenceRow(model: model, data: data, row: row, showDate: true) { confirming = (row, $0) }
                            if row.id != data.week.last?.id { Divider() }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var spendingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.text(L10n.Overview.spending)).font(.headline)
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    if let spending = data.spending {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(dollars(spending.used)).font(.system(size: 24, weight: .bold)).monospacedDigit()
                            Text(spending.limit.map { L10n.Overview.ofCap(model.uiLanguage, ["cap": dollars($0)]) }
                                 ?? model.text(L10n.Overview.noCap))
                                .foregroundStyle(.secondary)
                        }
                        if let limit = spending.limit, limit > 0 {
                            ProgressView(value: min(Double(spending.used), Double(limit)), total: Double(limit))
                        }
                        if spending.image > 0 || spending.unpriced > 0 {
                            Text(L10n.Overview.spendingDetail(model.uiLanguage, [
                                "image": dollars(spending.image), "unpriced": String(spending.unpriced),
                            ]))
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        if let reads = spending.xReads {
                            Divider()
                            LabeledContent(model.text(L10n.Overview.xToday)) {
                                Text(spending.xLimit.map { "\(reads) / \($0)" } ?? "\(reads)").monospacedDigit()
                            }
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }

    private func confirmTitle(_ action: OverviewData.Recovery) -> Words {
        switch action {
        case .retryModel: L10n.Overview.retryModelTitle
        case .retryDelivery: L10n.Overview.retryDeliveryTitle
        case .stopResending: L10n.Overview.stopResendingTitle
        case .continueHeld: L10n.Overview.continueHeld
        case .stopHeld: L10n.Overview.stopHeld
        case .resumeJob: L10n.Overview.resumeTitle
        }
    }

    private func confirmBody(_ action: OverviewData.Recovery) -> Words {
        switch action {
        case .retryModel: L10n.Overview.retryModelBody
        case .retryDelivery: L10n.Overview.retryDeliveryBody
        case .stopResending: L10n.Overview.stopResendingBody
        case .continueHeld, .stopHeld: L10n.Overview.heldBody
        case .resumeJob: L10n.Overview.jobPausedNote
        }
    }

    private func confirmButton(_ action: OverviewData.Recovery) -> Words {
        switch action {
        case .retryModel, .retryDelivery: L10n.Overview.retry
        case .stopResending: L10n.Overview.stopResending
        case .continueHeld: L10n.Overview.continueHeld
        case .stopHeld: L10n.Overview.stopHeld
        case .resumeJob: L10n.Overview.resume
        }
    }
}

struct OccurrenceRow: View {
    let model: AppModel
    let data: OverviewData
    let row: Occurrence
    var showDate = false
    let act: (OverviewData.Recovery) -> Void

    var body: some View {
        let state = OccurrenceState(row, paused: model.schedulingPaused, abandoned: data.abandoned.contains(row.id))
        HStack(spacing: 12) {
            Text((showDate ? String(OverviewData.localDay(row).suffix(5)) + " " : "") + OverviewData.clock(row.targetAt))
                .font(.body.weight(.semibold)).monospacedDigit()
                .frame(width: showDate ? 96 : 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.editionTitle(row.subscriptionId, accountId: row.accountId))
                Text(note(state)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Circle().fill(state.dot).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(model.text(state.title)).font(.callout)
            }
            if data.working == row.id {
                ProgressView().controlSize(.small)
            } else {
                actions(state)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func actions(_ state: OccurrenceState) -> some View {
        switch state {
        case .modelUnknown:
            if OverviewData.canRetryModel(row) {
                Button(model.text(L10n.Overview.retry)) { act(.retryModel) }
            }
        case .jobPaused:
            Button(model.text(L10n.Overview.resume)) { act(.resumeJob) }
        case .deliveryUnknown, .partial:
            // Only unknown parts can be retried or skipped; a retry runs only while the edition is open.
            if data.unknownParts.contains(row.id) {
                if OverviewData.canRetryDelivery(row) {
                    Menu(model.text(L10n.Overview.checkAndResend)) {
                        Button(model.text(L10n.Overview.retry)) { act(.retryDelivery) }
                        Button(model.text(L10n.Overview.stopResending)) { act(.stopResending) }
                    }
                    .fixedSize()
                } else {
                    Button(model.text(L10n.Overview.stopResending)) { act(.stopResending) }
                }
            }
        case .held:
            Button(model.text(L10n.Overview.continueHeld)) { act(.continueHeld) }
            Button(model.text(L10n.Overview.stopHeld)) { act(.stopHeld) }
        default:
            EmptyView()
        }
    }

    static func skipNote(status: String, reason: String?) -> Words {
        if status == "no_news" { return L10n.Overview.noNews }
        if status == "superseded" { return L10n.Overview.superseded }
        switch reason {
        case "scope_disabled": return L10n.Overview.digestOff
        case "schedule_changed": return L10n.Overview.retimed
        case "nonexistent_local_date": return L10n.Overview.noSuchTime
        default: return L10n.Overview.missed
        }
    }

    private func note(_ state: OccurrenceState) -> String {
        switch state {
        case .waiting:
            // A slot not created yet has no preparation time; name where it goes instead.
            guard row.prepareAt != nil else { return model.targetsLine(row.subscriptionId, accountId: row.accountId) }
            return L10n.Overview.preparesAt(model.uiLanguage, ["time": OverviewData.clock(row.prepareAt)])
        case .jobPaused:
            return model.text(L10n.Overview.jobPausedNote)
        case .delivered:
            // The Bots that received it, from its delivery record — not today's settings.
            return data.recipients[row.id].map(model.recipientsLine) ?? ""
        case .late:
            return L10n.Overview.lateNote(model.uiLanguage, ["time": OverviewData.clock(row.targetAt)])
        case .skipped:
            return model.text(Self.skipNote(status: row.status, reason: row.reason))
        case .modelUnknown:
            return model.text(OverviewData.canRetryModel(row) ? L10n.Overview.modelUnknownNote : L10n.Overview.modelExpiredNote)
        case .deliveryUnknown, .partial:
            if !data.unknownParts.contains(row.id) { return model.text(L10n.Overview.partialSettledNote) }
            return model.text(OverviewData.canRetryDelivery(row) ? L10n.Overview.deliveryUnknownNote : L10n.Overview.retryExpiredNote)
        case .abandoned:
            return model.text(L10n.Overview.abandonedNote)
        case .held:
            return model.text(L10n.Overview.heldBody)
        case .failed:
            return FailureCopy.message(for: BackendError(code: row.reason ?? row.status), model.uiLanguage)
        case .preparing, .paused:
            return model.targetsLine(row.subscriptionId, accountId: row.accountId)
        }
    }
}

/// "N more steps" with a button that goes where the step is done (interaction-spec §4.2).
private struct SetupChecklist: View {
    let model: AppModel
    let readiness: Readiness
    let data: OverviewData
    @State private var sending = false

    var body: some View {
        let done = readiness.steps.filter(\.done).count
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.Setup.title(model.uiLanguage, ["count": String(readiness.steps.count - done)])).font(.headline)
                Spacer()
                ProgressView(value: Double(done), total: Double(max(readiness.steps.count, 1))).frame(width: 140)
                Text("\(done) / \(readiness.steps.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            GroupBox {
                VStack(spacing: 0) {
                    ForEach(Array(readiness.steps.enumerated()), id: \.element.id) { index, step in
                        HStack(spacing: 10) {
                            ZStack {
                                Circle().fill(step.done ? Color.green : step.step == readiness.next ? Color.accentColor : Color.clear)
                                Circle().strokeBorder(step.done || step.step == readiness.next ? Color.clear : Color.secondary, lineWidth: 1.5)
                                Text(step.done ? "✓" : String(index + 1)).font(.caption.bold())
                                    .foregroundStyle(step.done || step.step == readiness.next ? Color.white : Color.secondary)
                            }
                            .frame(width: 20, height: 20)
                            .accessibilityHidden(true)
                            Text(model.text(title(step))).fontWeight(step.step == readiness.next ? .semibold : .regular)
                            Spacer()
                            button(step)
                        }
                        .padding(.vertical, 7)
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(model.text(step.done ? L10n.Setup.stepDone : L10n.Setup.stepPending))
                        if index < readiness.steps.count - 1 { Divider() }
                    }
                }
                .padding(.horizontal, 4)
            }
            Text(model.text(L10n.Setup.disappears)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func title(_ step: Readiness.Step) -> Words {
        switch step.step {
        case "bot": L10n.Setup.bot
        case "model": L10n.Setup.model
        case "digest": L10n.Setup.digest
        default: L10n.Setup.delivery
        }
    }

    @ViewBuilder private func button(_ step: Readiness.Step) -> some View {
        let current = step.step == readiness.next
        if step.step == "first_delivery" {
            if current {
                Button(model.text(L10n.Overview.sendTrial)) {
                    Task {
                        sending = true
                        defer { sending = false }
                        await model.sendNow(model.firstEnabledDigest)
                        await data.load(model.client, subscriptions: model.config?.subscriptions ?? [], accounts: model.config?.accounts ?? [])
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(sending || model.firstEnabledDigest == nil)
            }
        } else if step.done || current {
            let target: Page = step.step == "digest" ? .digests : .connect
            let label = step.done ? L10n.Setup.view : step.step == "digest" ? L10n.Setup.turnOn : L10n.Setup.connect
            if current {
                Button(model.text(label)) { model.page = target }.buttonStyle(.borderedProminent)
            } else {
                Button(model.text(label)) { model.page = target }
            }
        }
    }
}

/// Things worth a look, each with a way to it (interaction-spec §4.5).
private struct AttentionSection: View {
    let model: AppModel
    let data: OverviewData

    private struct Item: Identifiable {
        let id: String
        let dot: Color
        let title: String
        let note: String
        let page: Page
    }

    private var items: [Item] {
        var result: [Item] = []
        let language = model.uiLanguage
        if let readiness = model.readiness,
           readiness.steps.contains(where: { $0.step == "model" && $0.blockerCode == "model_failed" }) {
            result.append(Item(id: "model", dot: .red, title: L10n.Attention.keyRejected(language),
                               note: L10n.Attention.keyRejectedNote(language), page: .connect))
        }
        for bot in model.bots where bot.verified && !bot.paired && !bot.paused {
            result.append(Item(id: "bot-" + bot.id, dot: .orange,
                               title: L10n.Attention.botWaiting(language, ["bot": bot.username.map { "@" + $0 } ?? bot.name]),
                               note: L10n.Attention.botWaitingNote(language), page: .connect))
        }
        for source in data.staleSources {
            result.append(Item(id: "source-" + source.id, dot: .orange,
                               title: L10n.Attention.staleSource(language, ["source": source.name, "days": String(source.days)]),
                               note: L10n.Attention.staleSourceNote(language), page: .digests))
        }
        if let spending = data.spending, let limit = spending.limit, spending.used >= limit {
            result.append(Item(id: "budget", dot: .red, title: L10n.Attention.capReached(language),
                               note: L10n.Attention.capReachedNote(language), page: .connect))
        }
        if let spending = data.spending, spending.xReads != nil, spending.xLimit == nil {
            result.append(Item(id: "x-limit", dot: .gray, title: L10n.Attention.xUnlimited(language),
                               note: L10n.Attention.xUnlimitedNote(language), page: .connect))
        }
        if model.config?.modelProfiles.first(where: { $0.partition == "normal" && $0.role == "backup" })?.credentialRef == nil {
            result.append(Item(id: "backup", dot: .gray, title: L10n.Attention.noBackup(language),
                               note: L10n.Attention.noBackupNote(language), page: .connect))
        }
        return result
    }

    var body: some View {
        let items = items
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.text(L10n.Attention.title)).font(.headline)
                GroupBox {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle().fill(item.dot).frame(width: 8, height: 8).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).fontWeight(.medium)
                                    Text(item.note).font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Button(model.text(item.page.title) + " ›") { model.page = item.page }
                                        .buttonStyle(.link).font(.caption)
                                }
                            }
                            .padding(.vertical, 6)
                            if item.id != items.last?.id { Divider() }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }
            }
        }
    }
}

/// Toolbar "Send one now…" (interaction-spec §4.1).
private struct SendNowMenu: View {
    let model: AppModel
    let reload: () async -> Void

    var body: some View {
        let digests = model.config?.subscriptions.filter(\.enabled) ?? []
        Menu(model.text(L10n.Overview.sendNow)) {
            ForEach(digests) { digest in
                Button(model.digestTitle(digest.id)) {
                    Task {
                        await model.sendNow(digest.id)
                        await reload()
                    }
                }
            }
        }
        .disabled(digests.isEmpty || model.connection != .connected)
        .help(model.text(L10n.Overview.sendNowHelp))
    }
}

extension AppModel {
    /// The category's name in the interface language; a split digest (two or more in one
    /// category) uses its own name so the parts stay distinguishable.
    func digestTitle(_ subscriptionId: String) -> String {
        guard let config, let subscription = config.subscriptions.first(where: { $0.id == subscriptionId }) else {
            return subscriptionId
        }
        let siblings = config.subscriptions.filter { $0.categoryId == subscription.categoryId }.count
        if siblings > 1, let name = subscription.name, !name.isEmpty { return name }
        return categoryTitle(subscription.categoryId)
    }

    /// A built-in category's name in the interface language.
    func categoryTitle(_ categoryId: String) -> String {
        let names: [String: Phrase] = [
            "world": .world, "japan": .japan, "australia": .australia, "china": .china,
            "electronics": .electronics, "ai": .ai, "av": .av, "x": .x, "x_adult": .xAdult,
        ]
        return names[categoryId].map(text) ?? categoryId
    }

    /// "→ @bot" for where an edition goes (`targetsLine(row.subscriptionId, accountId: row.accountId)`).
    func targetsLine(_ subscriptionId: String, accountId: String? = nil) -> String {
        recipientsLine(recipients(subscriptionId, accountId: accountId))
    }

    /// The Bots an edition goes to, as routing.py `resolve_route` decides: an X account sent
    /// alone uses its own Bots when it has chosen some, otherwise its digest's.
    func recipients(_ subscriptionId: String, accountId: String?) -> [String] {
        let digest = config?.subscriptions.first { $0.id == subscriptionId }?.botIds ?? []
        guard let accountId, let account = config?.accounts.first(where: { $0.id == accountId }),
              account.priority == "special" else { return digest }
        return account.botIds ?? digest
    }

    /// A row's title: the digest, and for an X account sent alone also its @username.
    func editionTitle(_ subscriptionId: String, accountId: String?) -> String {
        let title = digestTitle(subscriptionId)
        guard let accountId, let account = config?.accounts.first(where: { $0.id == accountId }) else { return title }
        return title + " · @" + account.handle
    }

    /// "→ @bot, @other" for these Bot ids.
    func recipientsLine(_ ids: [String]) -> String {
        let names = ids.map { id in bots.first { $0.id == id }.flatMap { $0.username.map { "@" + $0 } ?? $0.name } ?? id }
        return names.isEmpty ? "" : "→ " + names.joined(separator: ", ")
    }

    /// The digest a trial send uses: the first enabled ordinary one (never an adult one).
    var firstEnabledDigest: String? {
        guard let config else { return nil }
        let ordinary = Set(config.categories.filter { $0.partition == "normal" }.map(\.id))
        return config.subscriptions.first { $0.enabled && ordinary.contains($0.categoryId) }?.id
    }
}
