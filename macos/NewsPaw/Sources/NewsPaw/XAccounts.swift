import Foundation
import Observation
import SwiftUI

// MARK: - Backend shapes

/// One row of `x.accounts.list`: the stored account plus what the last read with the current
/// X key found (`state`) and whether its posts can be collected now.
struct XAccountItem: Decodable, Identifiable, Equatable {
    let id, handle, priority, state: String
    let partition, subscriptionId, style, observedAt, remoteId: String?
    let botIds, times, postTypes: [String]?
    let includeInAggregate: Bool?
    let direct: Bool?
    let memberActive, canCollect: Bool

    /// The post types read for this account (`X_DEFAULT_POST_TYPES` when none are stored).
    var types: [String] { postTypes ?? XPostType.defaults }
    /// "单独发": its own digest at its own time (routing.py `special`).
    var sendsAlone: Bool { priority == "special" && subscriptionId != nil }
    /// "并入汇总": in a digest and not sent alone. An account in no digest yet (a List member
    /// just taken in, or a draft whose digest choice failed) is neither.
    var inDigest: Bool { subscriptionId != nil && priority != "special" }
}

/// One X List (`x.lists.list`). `current` is false until its members were read with the current key.
struct XListItem: Decodable, Identifiable, Equatable {
    struct Member: Decodable, Equatable { let accountId: String; let remoteId: String }
    let id, partition, state: String
    let defaultAdult: Bool
    let name, checkedAt: String?
    let current: Bool
    let members: [Member]
}

/// What a read of X answered (`x.accounts.verify`, `x.lists.refresh`, `x.operation`).
/// `state` is `ready`, `protected`, `duplicate`, `private`, `running`, or a failure such as
/// `unavailable`, `rate_limited`, `outcome_unknown`, `budget_blocked` (then `reason` says which limit).
struct XOperationReply: Decodable, Equatable {
    let state: String
    let reason: String?
    let retryAfter: Int?
    let account: XAccountItem?
    let canonicalAccountId: String?
    let list: XListItem?

    /// The failure this reply stands for, as the copy table names it; nil for an answer.
    var failure: BackendError? {
        switch state {
        case "ready", "protected", "duplicate", "running": return nil
        case "budget_blocked": return BackendError(code: reason ?? "x_limit", domain: "budget")
        default: return BackendError(code: state == "private" ? "private" : (reason ?? state), domain: "x")
        }
    }
}

/// `x.accounts.partition_impact`: what moving an account to the other kind would change.
struct XPartitionImpact: Decodable, Equatable {
    let revision: Int
    let accountId: String
    let partition: String?
    let subscriptionId: String?
    let aggregate, special: Bool
    let aggregateBotIds, specialBotIds: [String]
    let clearsSpecialOverrides, clearsPostTypes: Bool
    let cachedPosts, pendingJobs: Int
}

/// When an account was last read and how many of its posts arrived today.
struct XActivity: Equatable {
    var lastRead: Date?
    /// nil until a count was read: an unread count is never shown as 0.
    var newToday: Int?
    /// Today's count reached the read limit (`XAccountsData.postsLimit`): "50+".
    var capped = false
    /// What the last read of the account's posts missed, if anything (`x.posts.coverage`).
    var gap: XCoverageGap?
    /// The kind of content these were read under: after a move they no longer apply.
    var partition: String?
}

/// A gap in what was read of an account's posts, kept visible (`x.posts.coverage`, x/timelines.py).
enum XCoverageGap: Equatable {
    /// Stopped at the read's page or window limit.
    case partial
    /// A pagination gap, or a fresh read that skipped past the earlier one.
    case gap
    /// Did not finish (rate limit, unknown outcome, read limit, interrupted, scope changed).
    case unfinished

    init?(state: String, reason: String?, historyGap: String?) {
        if reason == "pagination_gap" || historyGap != nil {
            self = .gap
            return
        }
        switch state {
        case "complete", "unobserved", "pending", "running": return nil
        case "incomplete" where ["page_limit", "bounded_window", "checkpoint_limit"].contains(reason ?? ""): self = .partial
        // Not collectable is the row's own state; a changed scope means earlier reads no longer cover it.
        case "unavailable": guard ["coverage_scope_changed", "timeline_access_changed"].contains(reason ?? "") else { return nil }
            self = .unfinished
        default: self = .unfinished
        }
    }

    var words: Words {
        switch self {
        case .partial: L10n.XAccounts.coveragePartial
        case .gap: L10n.XAccounts.coverageGap
        case .unfinished: L10n.XAccounts.coverageUnfinished
        }
    }
}

/// One opt-in alert rule (`x.alerts.save`): a phrase within one X digest, or one of its
/// separately sent accounts.
struct XAlertRule: Equatable, Hashable, Identifiable {
    let subscriptionId: String
    let accountId: String?
    let phrase: String
    var id: String { subscriptionId + "/" + (accountId ?? "") + "/" + phrase }
    var fields: [String: Any] {
        ["subscription_id": subscriptionId, "account_id": accountId as Any? ?? NSNull(), "phrase": phrase]
    }
}

struct XAlertPolicy: Equatable {
    var enabled = false
    var dailyLimit = 0
    var rules: [XAlertRule] = []

    init() {}

    init(_ settings: [String: Any]) {
        enabled = settings["enabled"] as? Bool ?? false
        dailyLimit = settings["daily_limit"] as? Int ?? 0
        rules = (settings["rules"] as? [[String: Any]] ?? []).compactMap { rule in
            guard let subscription = rule["subscription_id"] as? String, let phrase = rule["phrase"] as? String else { return nil }
            return XAlertRule(subscriptionId: subscription, accountId: rule["account_id"] as? String, phrase: phrase)
        }
    }
}

struct XVideoPolicy: Equatable {
    var enabled = false
    var dailyLimit = 0
    /// Micro-dollars a day for frame and audio checks.
    var dailyModelLimit = 0

    init() {}

    init(_ settings: [String: Any]) {
        enabled = settings["enabled"] as? Bool ?? false
        dailyLimit = settings["daily_limit"] as? Int ?? 0
        dailyModelLimit = settings["daily_model_limit"] as? Int ?? 0
    }
}

/// A post in a sent ordinary X digest whose video can be checked (`x.video.candidates`).
struct XVideoCandidate: Decodable, Identifiable, Equatable {
    let jobId, postId, title, author: String
    let requestId: String?
    var id: String { jobId + "/" + postId }
}

/// A video check (`x.video.inspect` / `x.video.status`).
struct XVideoResult: Decodable, Equatable {
    struct Frame: Decodable, Equatable { let second: Double; let observation: String }
    let requestId: String?
    let state: String
    let frames: [Frame]?
    let transcript: String?
    let gaps: [String]?
}

enum XPostType {
    static let all = ["original", "quoted", "replied_to", "retweeted"]
    static let defaults = ["original", "quoted"]
}

/// What an account row shows as its state (interaction-spec §7.3).
enum XAccountState: Equatable {
    case readable, protected, gone, recheck, noPermission, keyRejected, unverified

    init(_ state: String) {
        switch state {
        case "ready": self = .readable
        case "protected": self = .protected
        case "unavailable", "invalidated": self = .gone
        case "permission_denied": self = .noPermission
        case "authentication_failed": self = .keyRejected
        case "unverified": self = .unverified
        // credential_changed, identity_mismatch: read once more with the current key.
        default: self = .recheck
        }
    }

    var color: Color {
        switch self {
        case .readable: .green
        case .protected, .recheck: .orange
        case .gone, .noPermission, .keyRejected: .red
        case .unverified: .gray
        }
    }

    var words: Words {
        switch self {
        case .readable: L10n.XAccounts.stateReadable
        case .protected: L10n.XAccounts.stateProtected
        case .gone: L10n.XAccounts.stateGone
        case .recheck: L10n.XAccounts.stateRecheck
        case .noPermission: L10n.XAccounts.stateNoPermission
        case .keyRejected: L10n.XAccounts.stateKeyRejected
        case .unverified: L10n.XAccounts.stateUnverified
        }
    }

    /// Accounts that cannot be read stay listed with "Remove" instead of the send choice.
    var removable: Bool { self == .protected || self == .gone }
}

/// What the add row shows under its field after the owner pressed Add (interaction-spec §7.2).
enum XAddOutcome: Equatable {
    /// Read and added; the row is highlighted.
    case added(String)
    /// Exists but is protected: keep it anyway, or drop it.
    case protected(String)
    /// X has no such account (the draft was removed again).
    case missing(String)
    /// Already in this list.
    case exists(String)
    /// Already listed under the other kind of content; it is not moved from here.
    case otherPartition(String, String)
    /// The read did not finish; the draft account is kept so it can be read again or dropped.
    case failed(BackendError, String?)
    /// A List was read: its members can be taken into the digest.
    case list(String)
    /// Reading a List's members failed; it is kept and can be read again.
    case listFailed(BackendError, String)
    /// The draft the add created could not be removed again (X has no such account, or it is
    /// already listed): what happened, and "Try Again" removes the leftover draft.
    indirect case cleanupFailed(BackendError, String, XAddOutcome)
}

extension BackendClient {
    /// Runs a revisioned operation against the newest configuration revision, once more after a
    /// background change (the same rule as `EditorState`).
    func revisioned<Value>(_ body: (Int) async throws -> Value) async throws -> Value {
        var retried = false
        while true {
            let revision = try await configDocument().revision
            do {
                return try await body(revision)
            } catch let error as BackendError where error.isConflict && !retried {
                retried = true
            }
        }
    }

    /// The budget document, edited like every other record (newest revision, one replay).
    func budgetEditor() -> EditorState {
        EditorState(
            load: { try BackendClient.record(await self.call(.budgetGet), field: "document") },
            store: { _ = try await self.call(.budgetSave, ["document": $0, "revision": $1]) }
        )
    }
}

/// Changes to the budget document shared by the Connect and X pages.
enum BudgetChange {
    /// X reads per day for both kinds of accounts together; nil is no limit.
    static func dailyReads(_ value: Int?) -> EditorState.Change {
        { document in
            var document = document
            var limits = document["x"] as? [String: Any] ?? [:]
            limits["daily_limit"] = value ?? NSNull()
            document["x"] = limits
            return document
        }
    }

    /// X reads per day for one kind of account; nil is no limit (both kinds stay listed).
    static func partitionReads(_ partition: String, _ value: Int?) -> EditorState.Change {
        { document in
            var document = document
            var limits = document["x"] as? [String: Any] ?? [:]
            var table = limits["partition_limits"] as? [String: Any] ?? [:]
            table[partition] = value ?? NSNull()
            limits["partition_limits"] = table
            document["x"] = limits
            return document
        }
    }
}

extension AppConfig {
    /// The X digest of a kind of content: "x" for ordinary accounts, "x_adult" for adult ones.
    func xDigest(_ partition: String) -> Subscription? {
        displaySubscription(for: partition == "adult" ? "x_adult" : "x")
    }

    /// Accounts collected into this X digest (`in_x_aggregate`): ordinary members, and accounts
    /// sent alone that also opted into the digest.
    func aggregateAccounts(_ subscription: Subscription) -> [Account] {
        guard ["x", "x_adult"].contains(subscription.categoryId) else { return [] }
        return accounts.filter { $0.subscriptionId == subscription.id && ($0.priority == "normal" || $0.includeInAggregate == true) }
    }

    /// Accounts with their own digest under this X digest.
    func separateAccounts(_ subscription: Subscription) -> [Account] {
        accounts.filter { $0.subscriptionId == subscription.id && $0.priority == "special" }
    }
}

// MARK: - State and actions

/// Everything the X accounts page reads and edits (interaction-spec §7). Account changes are
/// the backend's revisioned X operations, retried once after a background change; the budget,
/// alert and video policies go through `EditorState`. Changes to one account run in order.
@MainActor @Observable
final class XAccountsData {
    private(set) var accounts: [XAccountItem] = []
    private(set) var lists: [XListItem] = []
    /// Whether an X key exists; false until a directory read has shown one (adding stays closed).
    private(set) var keyConfigured = false
    private(set) var loaded = false
    private(set) var activity: [String: XActivity] = [:]
    private(set) var budget: BudgetSummary?
    private(set) var alerts: XAlertPolicy?
    private(set) var video: XVideoPolicy?
    private(set) var candidates: [XVideoCandidate] = []
    private(set) var inspections: [String: XVideoResult] = [:]
    private(set) var newspaperReady = false
    private(set) var impacts: [String: XPartitionImpact] = [:]

    var outcome: XAddOutcome?
    /// The side the add row's result belongs to; it is shown only there.
    private(set) var outcomePartition: String?
    private(set) var highlighted: String?
    private(set) var working: Set<String> = []
    /// Work that has run for more than ten seconds ("still going, you can do something else").
    private(set) var slow: Set<String> = []
    private(set) var failures: [String: BackendError] = [:]
    private(set) var savedAt: [String: Date] = [:]
    /// List members the owner chose not to take in; kept on this Mac (UserDefaults).
    private(set) var ignored: Set<String> = []

    @ObservationIgnored var pollInterval: Duration = .seconds(1)
    /// How long a read that outlived its socket deadline is followed before the page lets go.
    @ObservationIgnored var followLimit: Duration = .seconds(120)
    @ObservationIgnored private var queues: [String: Task<Void, Never>] = [:]
    /// The change that failed last for each account, so "Try Again" repeats exactly that change
    /// against the fresh state. Each queued change has its own identity: an earlier change
    /// finishing never clears (or stands in for) a later one's failure.
    private struct FailedRoute { let change: UUID; let fields: RouteFields }
    @ObservationIgnored private var failedRoutes: [String: FailedRoute] = [:]
    /// Today's post counts are local but not free (one `x.posts.list` per account): they are
    /// read again only when the readable accounts change or after this long.
    @ObservationIgnored var activityInterval: Duration = .seconds(600)
    @ObservationIgnored private var activityRead: (at: ContinuousClock.Instant, accounts: Set<String>)?

    /// Posts read per account to count today's (shown as "50+" when reached).
    static let postsLimit = 50

    /// Fields of one `x.accounts.route` from the account's fresh state and its digest; nil sends nothing.
    typealias RouteFields = (XAccountItem, String) -> [String: Any]?
    @ObservationIgnored private let defaults: UserDefaults

    static let ignoredKey = "x.ignoredMembers"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ignored = Set(defaults.stringArray(forKey: Self.ignoredKey) ?? [])
    }

    func isBusy(_ key: String) -> Bool { working.contains(key) }
    func dismiss(_ key: String) { failures[key] = nil }
    func account(_ id: String) -> XAccountItem? { accounts.first { $0.id == id } }

    /// Accounts of one kind of content; nothing from the other kind is ever listed with them.
    func accounts(in partition: String) -> [XAccountItem] {
        accounts.filter { $0.partition == partition }.sorted { $0.handle.lowercased() < $1.handle.lowercased() }
    }

    func lists(in partition: String) -> [XListItem] { lists.filter { $0.partition == partition } }

    /// Accounts in no kind yet that no List explains (older drafts): they wait for a choice.
    var unclassified: [XAccountItem] {
        let members = Set(lists.flatMap { $0.members.map(\.accountId) })
        return accounts.filter { $0.partition == nil && !members.contains($0.id) }
    }

    /// A List's members still waiting for the owner to say which kind they are.
    func pending(_ list: XListItem) -> [XAccountItem] {
        let ids = Set(list.members.map(\.accountId))
        return accounts.filter { ids.contains($0.id) && $0.partition == nil && !ignored.contains($0.id) }
    }

    /// A List's members of its own kind that are in no digest yet (an adult List's members are
    /// adult from the start, but join the digest only when taken in).
    func notInDigest(_ list: XListItem) -> [XAccountItem] {
        let ids = Set(list.members.map(\.accountId))
        return accounts.filter { ids.contains($0.id) && $0.partition == list.partition && $0.subscriptionId == nil && !ignored.contains($0.id) }
    }

    /// The add row's result for one side (nil on the other side).
    func outcome(in partition: String) -> XAddOutcome? { outcomePartition == partition ? outcome : nil }

    /// A rule scope still offered (the whole digest, "", or one of `ids`); nil when it no longer is.
    nonisolated static func ruleScope(_ chosen: String, among ids: [String]) -> String? {
        chosen.isEmpty || ids.contains(chosen) ? chosen : nil
    }

    /// Whether the account's failed change can be repeated ("Try Again" on its row).
    func canRetryRoute(_ id: String) -> Bool { failedRoutes[id] != nil }

    /// A List row's note: "all members are in the digest" only when none waits for a kind or
    /// is outside the digest.
    func listNote(_ list: XListItem) -> Words {
        if !pending(list).isEmpty { return L10n.XAccounts.listNotePending }
        if !notInDigest(list).isEmpty { return L10n.XAccounts.listNoteOutside }
        return list.partition == "adult" ? L10n.XAccounts.listNoteAdult : L10n.XAccounts.listNote
    }

    /// Alert rules on this account (they go if it stops being sent alone).
    /// nil while the alert policy has not been read: unknown, not "no rules".
    func rulesOn(_ id: String) -> Int? { alerts.map { $0.rules.filter { $0.accountId == id }.count } }

    /// The rules on an account, read fresh from the backend right before a change that may drop
    /// them is confirmed or sent (another writer may have added one since the page last read).
    /// Unreadable: nil, and the reason under `key` — a cached answer is not used instead.
    func rulesBeforeChange(_ id: String, key: String, model: AppModel) async -> Int? {
        if let failure = await readAlerts(model.client) {
            failures[key] = failure
            return nil
        }
        return rulesOn(id)
    }

    @discardableResult
    private func readAlerts(_ client: BackendClient) async -> BackendError? {
        do {
            alerts = XAlertPolicy(try BackendClient.record(await client.call(.xAlertsStatus), field: "settings").document)
            return nil
        } catch {
            return BackendError.wrapping(error)
        }
    }

    // MARK: Loading

    /// Reads accounts, Lists, today's reads and the alert and video policies. Each part keeps
    /// its last good value when its read fails; a failed directory read is shown on the page.
    func load(model: AppModel, now: Date = Date()) async {
        let client = model.client
        do {
            struct Directory: Decodable { let credentialConfigured: Bool; let accounts: [XAccountItem] }
            let directory: Directory = try BackendRPC.decode(await client.call(.xAccountsList))
            let lists: [XListItem] = try BackendRPC.decode(await client.call(.xListsList))
            accounts = directory.accounts
            keyConfigured = directory.credentialConfigured
            self.lists = lists
            failures["load"] = nil
        } catch {
            failures["load"] = BackendError.wrapping(error)
        }
        if let data = try? await client.call(.budgetGet), let summary = try? BudgetSummary(data, now: now) { budget = summary }
        await readAlerts(client)
        if let data = try? await client.call(.xVideoPolicy), let record = try? BackendClient.record(data, field: "settings") {
            video = XVideoPolicy(record.document)
        }
        if video?.enabled == true, let data = try? await client.call(.xVideoCandidates),
           let list: [XVideoCandidate] = try? BackendRPC.decode(data) {
            candidates = list
        }
        if let data = try? await client.call(.newspaperPolicy) {
            struct Paper: Decodable {
                struct Settings: Decodable { let enabled: Bool; let generationProfile: String? }
                let settings: Settings
            }
            if let paper: Paper = try? BackendRPC.decode(data) {
                newspaperReady = paper.settings.enabled && paper.settings.generationProfile != nil
            }
        }
        // Keyed by account and kind: counts read under the other kind no longer apply.
        let readable = Set(accounts.filter(\.canCollect).map { $0.id + "|" + ($0.partition ?? "") })
        if let last = activityRead, last.accounts == readable, ContinuousClock.now - last.at < activityInterval {
            activity = activity.filter { readable.contains($0.key + "|" + ($0.value.partition ?? "")) }
        } else if await loadActivity(client, now: now) {
            activityRead = (ContinuousClock.now, readable)
        }
        loaded = true
    }

    /// When each readable account was last read and how many of its posts were published today.
    /// Local reads only (`x.posts.coverage`, `x.posts.list`); nothing is fetched from X.
    /// Returns whether every read worked; a failed read keeps what was known before (and the
    /// counts are read again on the next poll).
    private func loadActivity(_ client: BackendClient, now: Date) async -> Bool {
        struct Coverage: Decodable {
            struct Observation: Decodable { let observedAt: String?; let throughTime: String?; let historyGap: String? }
            let state: String
            let reason: String?
            let latest: Observation?
        }
        struct Post: Decodable { let publishedAt: String }
        var next: [String: XActivity] = [:]
        var complete = true
        let day = OverviewData.day(now)
        for account in accounts where account.canCollect {
            var entry = activity[account.id].flatMap { $0.partition == account.partition ? $0 : nil } ?? XActivity()
            entry.partition = account.partition
            let scope: [String: Any] = ["kind": "account", "scope": account.id]
            if let data = try? await client.call(.xPostsCoverage, scope), let coverage: Coverage = try? BackendRPC.decode(data) {
                entry.lastRead = (coverage.latest?.observedAt ?? coverage.latest?.throughTime).flatMap(OverviewData.date)
                entry.gap = XCoverageGap(state: coverage.state, reason: coverage.reason, historyGap: coverage.latest?.historyGap)
            } else {
                complete = false
            }
            var request = scope
            request["limit"] = Self.postsLimit
            if let data = try? await client.call(.xPostsList, request), let posts: [Post] = try? BackendRPC.decode(data) {
                // Newest first: today's posts are the first ones.
                let count = posts.filter { OverviewData.date($0.publishedAt).map(OverviewData.day) == day }.count
                entry.newToday = count
                entry.capped = count >= Self.postsLimit
            } else {
                complete = false
            }
            next[account.id] = entry
        }
        activity = next
        return complete
    }

    // MARK: Adding

    /// What the add field holds: a List link, or an account's username (with or without "@",
    /// or its x.com link).
    enum Entry: Equatable { case list(String), handle(String) }

    nonisolated static func entry(_ text: String) -> Entry? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.contains("/lists/") { return .list(value) }
        if let url = URL(string: value), let host = url.host?.lowercased(),
           ["x.com", "www.x.com", "twitter.com", "www.twitter.com"].contains(host) {
            let parts = url.path.split(separator: "/")
            return parts.count == 1 ? .handle(String(parts[0])) : .handle(value)
        }
        return .handle(value.hasPrefix("@") ? String(value.dropFirst()) : value)
    }

    /// Adds an account or a List to one kind of content. An account is read once (one read of
    /// X) to learn whether it exists and is protected, and joins the digest of its kind.
    func add(_ text: String, partition: String, model: AppModel) async {
        guard let entry = Self.entry(text), !working.contains("add") else { return }
        working.insert("add")
        defer { working.remove("add") }
        outcome = nil
        outcomePartition = partition
        failures["add"] = nil
        highlighted = nil
        switch entry {
        case let .list(value): await addList(value, partition: partition, model: model)
        case let .handle(name): await addAccount(name, partition: partition, model: model)
        }
    }

    private func addAccount(_ name: String, partition: String, model: AppModel) async {
        let client = model.client
        // The backend finds an existing username itself (case-insensitive); say so before any read.
        // An account known only from a List (not followed directly) of this kind goes to
        // x.accounts.add, which follows it directly (no X read, no digest change).
        if let existing = accounts.first(where: { $0.handle.lowercased() == name.lowercased() }),
           !(existing.direct == false && (existing.partition == partition || existing.partition == nil)) {
            outcome = existing.partition == partition || existing.partition == nil
                ? .exists(existing.id) : .otherPartition(existing.handle, existing.partition ?? partition)
            highlighted = existing.id
            await takeIn(existing, as: partition, model: model)
            return
        }
        var draft: String?
        do {
            struct Added: Decodable { let revision: Int; let account: XAccountItem }
            var sent = 0
            let added: Added
            do {
                added = try await client.revisioned { revision in
                    sent = revision
                    return try BackendRPC.decode(await client.call(.xAccountsAdd, ["handle": name, "revision": revision, "partition": partition]))
                }
            } catch let error where !(error is BackendError) {
                // The reply may be lost after the backend made the draft: the fresh list says.
                // Only a fresh draft of this kind (no digest, never read) is taken as ours.
                guard let fresh = await freshAccounts(client),
                      let found = fresh.first(where: { $0.handle.lowercased() == name.lowercased() }) else { throw error }
                let ours = found.partition == partition && found.subscriptionId == nil && found.remoteId == nil
                added = Added(revision: ours ? sent + 1 : sent, account: found)
            }
            // `add_account` returns an account it already has unchanged (same revision): one this
            // page had not read yet. It is not a draft: no digest change and no read of X.
            if added.revision == sent {
                let existing = added.account
                if let other = existing.partition, other != partition {
                    outcome = .otherPartition(existing.handle, other)
                } else {
                    outcome = .exists(existing.id)
                    highlighted = existing.id
                    await takeIn(existing, as: partition, model: model)
                }
                await reload(model)
                return
            }
            draft = added.account.id
            await finishDraft(added.account.id, handle: name, partition: partition, model: model)
        } catch {
            outcome = .failed(BackendError.wrapping(error), draft)
        }
        await reload(model)
    }

    /// Adding by name an account that is here but in no kind yet (a List member still waiting for
    /// a choice, or one the owner chose to ignore) is that choice: the ignore mark goes and it
    /// joins this kind and its digest, so it is never left hidden and uncollected.
    private func takeIn(_ existing: XAccountItem, as partition: String, model: AppModel) async {
        guard existing.partition == nil else { return }
        if ignored.remove(existing.id) != nil { defaults.set(ignored.sorted(), forKey: Self.ignoredKey) }
        let key = "member." + existing.id
        if !(await classify([existing.id], as: partition, key: key, model: model)) {
            outcome = .failed(failures[key] ?? BackendError(code: "invalid_reply"), nil)
        }
    }

    /// The rest of adding a draft, in the account's queue (so a row change made meanwhile is
    /// applied after it): join the digest of its kind first, so it is never left outside both
    /// choices, then read it once and say what was found.
    private func finishDraft(_ id: String, handle: String, partition: String, model: AppModel) async {
        await queued(id) { [self] in
            do {
                try await joinOwnDigest(id, model: model)
                let reply = try await verify(id, key: "add", model: model)
                await settle(reply, draft: id, handle: handle, partition: partition, model: model)
            } catch {
                outcome = .failed(BackendError.wrapping(error), id)
            }
        }
    }

    /// What the add row says once the read answered.
    private func settle(_ reply: XOperationReply, draft: String, handle: String, partition: String, model: AppModel) async {
        switch reply.state {
        case "ready":
            outcome = .added(draft)
            highlighted = draft
        case "protected":
            outcome = .protected(draft)
            highlighted = draft
        case "unavailable":
            // Not on X: nothing is left behind.
            await removeDraft(draft, then: .missing(handle), model: model)
        case "duplicate":
            // The same X account is already here under another (older) username.
            let canonical = reply.canonicalAccountId ?? reply.account?.id ?? draft
            let existing = reply.account
            let then: XAddOutcome = if let existing, let other = existing.partition, other != partition {
                .otherPartition(existing.handle, other)
            } else {
                .exists(canonical)
            }
            if canonical != draft {
                await removeDraft(draft, then: then, model: model)
            } else {
                outcome = then
            }
            if case let .exists(id) = outcome { highlighted = id }
        case "running":
            outcome = .failed(BackendError(code: "x_still_running", domain: "x"), draft)
        default:
            outcome = .failed(reply.failure ?? BackendError(code: reply.state, domain: "x"), draft)
        }
    }

    /// Removes a draft the add made, then says `then`; a failed removal is said with a retry.
    private func removeDraft(_ draft: String, then: XAddOutcome, model: AppModel) async {
        do {
            try await removeAccount(draft, model: model)
            outcome = then
            if case let .exists(id) = then { highlighted = id }
        } catch {
            outcome = .cleanupFailed(BackendError.wrapping(error), draft, then)
        }
    }

    /// Removes the leftover draft of a failed cleanup.
    func retryCleanup(model: AppModel) async {
        guard case let .cleanupFailed(_, draft, then) = outcome, !working.contains("add") else { return }
        working.insert("add")
        defer { working.remove("add") }
        await queued(draft) { [self] in await removeDraft(draft, then: then, model: model) }
        await reload(model)
    }

    /// Keeps a protected (or not yet read) account as it is.
    func keep(_ id: String) {
        outcome = nil
        highlighted = id
    }

    /// Drops the account the add row just created.
    func discard(_ id: String, model: AppModel) async {
        guard !working.contains("add") else { return }
        working.insert("add")
        defer { working.remove("add") }
        await queued(id) { [self] in
            do {
                try await removeAccount(id, model: model)
                outcome = nil
            } catch {
                failures["add"] = BackendError.wrapping(error)
            }
        }
        await reload(model)
    }

    /// Puts an account of a kind that is in no digest into its kind's X digest. Nothing is sent
    /// when it is already in one (or sent alone).
    private func joinOwnDigest(_ id: String, model: AppModel) async throws {
        let client = model.client
        do {
            try await sendJoin(id, model: model)
        } catch let error where !(error is BackendError) {
            // A lost reply: done if the fresh list shows it in a digest.
            guard let fresh = await freshAccounts(client), fresh.first(where: { $0.id == id })?.subscriptionId != nil else { throw error }
        }
    }

    private func sendJoin(_ id: String, model: AppModel) async throws {
        let client = model.client
        _ = try await client.revisioned { revision -> Data? in
            struct Directory: Decodable { let accounts: [XAccountItem] }
            let directory: Directory = try BackendRPC.decode(await client.call(.xAccountsList))
            guard let account = directory.accounts.first(where: { $0.id == id }), account.subscriptionId == nil,
                  let partition = account.partition, let digest = model.config?.xDigest(partition) else { return nil }
            return try await client.call(.xAccountsRoute, [
                "account_id": id, "subscription_id": digest.id, "priority": "normal", "revision": revision,
            ])
        }
    }

    /// Finishes adding the add row's draft after a failure: it joins its digest if that step
    /// failed, and is read again.
    func retryAdd(_ id: String, partition: String, model: AppModel) async {
        guard let handle = account(id)?.handle, !working.contains("add") else { return }
        working.insert("add")
        defer { working.remove("add") }
        outcome = nil
        await finishDraft(id, handle: handle, partition: partition, model: model)
        await reload(model)
    }

    // MARK: Reading X

    /// One account read (`x.accounts.verify`). A read that outlives the socket deadline keeps
    /// running in the backend; its record (`x.operation`) is followed instead of reporting a
    /// lost backend, and the same request id never reads twice.
    func verify(_ id: String, key: String, model: AppModel) async throws -> XOperationReply {
        let client = model.client
        var request = BackendClient.requestId("xacct")
        let marker = markSlow(key)
        defer { marker.cancel(); slow.remove(key) }
        do {
            let reply: XOperationReply = try await client.revisioned { revision in
                request = BackendClient.requestId("xacct")
                return try BackendRPC.decode(await client.call(.xAccountsVerify, [
                    "account_id": id, "request_id": request, "revision": revision,
                ]))
            }
            return reply.state == "running" ? try await follow(request, client: client) : reply
        } catch is SocketFailure {
            return try await follow(request, client: client)
        }
    }

    private func markSlow(_ key: String) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.slow.insert(key)
        }
    }

    /// Reads an X operation's record until it finished (or the page stops waiting).
    private func follow(_ request: String, client: BackendClient) async throws -> XOperationReply {
        let clock = ContinuousClock()
        let deadline = clock.now + followLimit
        while true {
            let reply: XOperationReply
            do {
                reply = try BackendRPC.decode(await client.call(.xOperation, ["request_id": request]))
            } catch let error as BackendError where error.code == "missing_operation" {
                // The request never reached the backend.
                throw BackendError(code: "backend_unreachable")
            }
            if reply.state != "running" || clock.now >= deadline { return reply }
            try await Task.sleep(for: pollInterval)
        }
    }

    /// Reads a listed account again (after a key change, or to see whether it is still there).
    func reverify(_ id: String, model: AppModel) async {
        let key = "verify." + id
        guard !working.contains(key) else { return }
        working.insert(key)
        defer { working.remove(key) }
        failures[key] = nil
        do {
            let reply = try await verify(id, key: key, model: model)
            if reply.state == "running" {
                failures[key] = BackendError(code: "x_still_running", domain: "x")
            } else if !["unavailable", "permission_denied", "authentication_failed"].contains(reply.state) {
                // Those three are shown by the row's own state; the rest are said once here.
                failures[key] = reply.failure
            }
        } catch {
            failures[key] = BackendError.wrapping(error)
        }
        await reload(model)
    }

    // MARK: Sending alone or in the digest

    /// Runs changes to one account one after another, in the order they were made.
    private func queued(_ id: String, _ work: @escaping @MainActor () async -> Void) async {
        let prior = queues[id]
        let mine = Task { @MainActor in
            _ = await prior?.value
            await work()
        }
        queues[id] = mine
        await mine.value
    }

    /// "并入汇总": the account joins its kind's X digest (and loses its own time, Bots and style).
    /// Alert rules on it go too; the page asks first when there are any (`rulesOn`).
    func joinDigest(_ id: String, model: AppModel) async {
        await route(id, model: model, fields: Self.joinFields)
    }

    /// "单独发": its own digest at `time`, to `bots` (nil: the digest's Bots) in `style`
    /// (nil: the digest's style).
    func sendAlone(_ id: String, time: String, bots: [String]?, style: String?, model: AppModel) async {
        // An explicit empty list would send it alone to nobody (e.g. every chosen Bot stopped
        // being able to receive it while the choice was open): nothing is saved.
        if let bots, bots.isEmpty {
            failures["route." + id] = BackendError(code: "no_ready_bot", domain: "x")
            return
        }
        await route(id, model: model) { _, digest in
            [
                "subscription_id": digest, "priority": "special",
                "overrides": ["times": [time], "bot_ids": bots.map { $0.sorted() } as Any? ?? NSNull(), "style": style as Any? ?? NSNull()],
            ]
        }
    }

    /// The Bots a send-alone choice can still send to: the chosen ones that can receive it now.
    nonisolated static func aloneBots(_ chosen: Set<String>, usable: [String]) -> [String] {
        chosen.filter(usable.contains).sorted()
    }

    /// Turns reading one kind of post on or off, applied to the account's newest stored types
    /// (two quick changes both stick). The last kind is never turned off.
    func setPostType(_ id: String, _ type: String, on: Bool, model: AppModel) async {
        await route(id, model: model) { account, digest in
            var types = Set(account.types)
            if on { types.insert(type) } else { types.remove(type) }
            guard !types.isEmpty, types != Set(account.types) else { return nil }
            return ["subscription_id": digest, "priority": account.sendsAlone ? "special" : "normal",
                    "post_types": XPostType.all.filter(types.contains)]
        }
    }

    /// Repeats the account's change that failed, as itself, against its fresh state. With no
    /// failed change there is nothing to repeat (never a substitute change).
    func retryRoute(_ id: String, model: AppModel) async {
        guard let failed = failedRoutes[id] else { return }
        await route(id, model: model, change: failed.change, fields: failed.fields)
    }

    /// `x.accounts.route` against the account's newest stored state. The digest is the one it is
    /// in, else the X digest of its own kind; never one of the other kind.
    private func route(_ id: String, model: AppModel, change: UUID = UUID(), fields: @escaping RouteFields) async {
        await queued(id) { [self] in await routeNow(id, model: model, change: change, fields: fields) }
    }

    /// The body of `route`, for work already running in the account's queue.
    private func routeNow(_ id: String, model: AppModel, change: UUID = UUID(), fields: @escaping RouteFields) async {
        let key = "route." + id
        working.insert(key)
        defer { working.remove(key) }
        failures[key] = nil
        let client = model.client
        do {
            _ = try await client.revisioned { revision -> Data? in
                struct Directory: Decodable { let accounts: [XAccountItem] }
                let directory: Directory = try BackendRPC.decode(await client.call(.xAccountsList))
                guard let account = directory.accounts.first(where: { $0.id == id }), let partition = account.partition else {
                    throw BackendError(code: "missing_account", domain: "x")
                }
                guard let digest = account.subscriptionId ?? model.config?.xDigest(partition)?.id else {
                    throw BackendError(code: "incompatible_subscription", domain: "x")
                }
                guard var request = fields(account, digest) else { return nil }
                request["account_id"] = id
                request["revision"] = revision
                return try await client.call(.xAccountsRoute, request)
            }
            savedAt[key] = Date()
            if failedRoutes[id]?.change == change { failedRoutes[id] = nil }
        } catch {
            failures[key] = BackendError.wrapping(error)
            failedRoutes[id] = FailedRoute(change: change, fields: fields)
        }
        await reload(model)
        await pruneRules(for: [id], model: model)
    }

    /// A failure that does not say whether the backend made the change (the reply was lost or
    /// unreadable). After such a failure the page reads the stored state and decides from it.
    nonisolated static func uncertain(_ failure: BackendError?) -> Bool {
        ["backend_unreachable", "invalid_reply"].contains(failure?.code ?? "")
    }

    /// Records a settings save. A failure whose reply was lost counts as saved when the state
    /// read back afterwards (`reload`) shows the change (`applied`).
    private func settle(_ key: String, editor: EditorState, saved: Bool, model: AppModel, applied: (() -> Bool)?) async -> Bool {
        await reload(model)
        if saved || (Self.uncertain(editor.failure) && applied?() == true) {
            failures[key] = nil
            savedAt[key] = editor.savedAt ?? Date()
            return true
        }
        failures[key] = editor.failure
        return false
    }

    /// The accounts as the backend has them now; nil when that cannot be read.
    private func freshAccounts(_ client: BackendClient) async -> [XAccountItem]? {
        struct Directory: Decodable { let accounts: [XAccountItem] }
        let directory: Directory? = try? BackendRPC.decode(await client.call(.xAccountsList))
        return directory?.accounts
    }

    /// The join fields of "并入汇总".
    private static let joinFields: RouteFields = { _, digest in ["subscription_id": digest, "priority": "normal"] }

    // MARK: Kind of content and removal

    /// What moving the account to the other kind would change (shown before confirming).
    @discardableResult
    func loadImpact(_ id: String, model: AppModel) async -> XPartitionImpact? {
        let key = "move." + id
        failures[key] = nil
        do {
            let impact: XPartitionImpact = try BackendRPC.decode(await model.client.call(.xAccountsPartitionImpact, ["account_id": id]))
            impacts[id] = impact
            return impact
        } catch {
            failures[key] = BackendError.wrapping(error)
            return nil
        }
    }

    /// Moves an account to the other kind of content, against the configuration the owner saw
    /// the impact of; then it joins that kind's X digest. Both steps run in the account's queue,
    /// so a send choice made meanwhile is applied after them and stays. A change made meanwhile
    /// shows the impact again instead of moving on a stale view. A reply lost after the backend
    /// moved it is settled from the fresh account list, and the join still follows.
    @discardableResult
    func move(_ id: String, to partition: String, impact: XPartitionImpact, model: AppModel) async -> Bool {
        let key = "move." + id
        guard !working.contains(key) else { return false }
        working.insert(key)
        defer { working.remove(key) }
        failures[key] = nil
        var moved = false
        await queued(id) { [self] in
            let client = model.client
            do {
                _ = try await client.call(.xAccountsClassify, ["account_id": id, "partition": partition, "revision": impact.revision])
            } catch let error as BackendError where error.isConflict {
                // The owner confirmed an impact that no longer holds: read it again and ask again.
                await loadImpact(id, model: model)
                failures[key] = error
                await reload(model)
                return
            } catch {
                guard let fresh = await freshAccounts(client), fresh.first(where: { $0.id == id })?.partition == partition else {
                    failures[key] = BackendError.wrapping(error)
                    await reload(model)
                    return
                }
            }
            impacts[id] = nil
            moved = true
            await model.refresh()
            // Then it joins the new kind's digest; a failure there is the row's, with "Try Again".
            await routeNow(id, model: model, fields: Self.joinFields)
        }
        return moved
    }

    /// Removes an account from NewsPaw (its own digest and alerts on it stop). Runs in the
    /// account's queue, after any change still being saved.
    @discardableResult
    func remove(_ id: String, model: AppModel) async -> Bool {
        let key = "remove." + id
        guard !working.contains(key) else { return false }
        working.insert(key)
        defer { working.remove(key) }
        failures[key] = nil
        var removed = false
        await queued(id) { [self] in
            do {
                try await removeAccount(id, model: model)
                removed = true
                if highlighted == id { highlighted = nil }
                await reload(model)
                await pruneRules(for: [id], model: model)
            } catch {
                failures[key] = BackendError.wrapping(error)
                await reload(model)
            }
        }
        return removed
    }

    /// `x.accounts.remove`, idempotent: an account already gone (`missing_account`, or a reply
    /// lost after the backend removed it, as the fresh list shows) counts as removed.
    private func removeAccount(_ id: String, model: AppModel) async throws {
        let client = model.client
        do {
            _ = try await client.revisioned { revision in
                try await client.call(.xAccountsRemove, ["account_id": id, "revision": revision])
            }
        } catch let error as BackendError where error.code == "missing_account" {
            return
        } catch {
            if let fresh = await freshAccounts(client), !fresh.contains(where: { $0.id == id }) { return }
            throw error
        }
    }

    // MARK: Lists

    private func addList(_ value: String, partition: String, model: AppModel) async {
        let client = model.client
        do {
            let list: XListItem
            do {
                list = try await client.revisioned { revision in
                    try BackendRPC.decode(await client.call(.xListsAdd, [
                        "value": value, "partition": partition, "revision": revision, "default_adult": partition == "adult",
                    ]))
                }
            } catch let error where !(error is BackendError) {
                // A lost reply: the List is there if the backend added it.
                let known: [XListItem]? = try? BackendRPC.decode(await client.call(.xListsList))
                guard let id = Self.listId(value), let found = known?.first(where: { $0.id == id }) else { throw error }
                list = found
            }
            if list.partition != partition {
                outcome = .otherPartition(list.name ?? list.id, list.partition)
                return
            }
            await settleList(list.id, model: model)
        } catch {
            outcome = .failed(BackendError.wrapping(error), nil)
        }
        await reload(model)
    }

    private func settleList(_ id: String, model: AppModel) async {
        do {
            let reply = try await readMembers(id, key: "add", model: model)
            if let failure = reply.failure {
                outcome = .listFailed(failure, id)
            } else if reply.state == "running" {
                outcome = .listFailed(BackendError(code: "x_still_running", domain: "x"), id)
            } else {
                outcome = .list(id)
            }
        } catch {
            outcome = .listFailed(BackendError.wrapping(error), id)
        }
    }

    /// Reads the add row's List again after a failed read.
    func retryList(_ id: String, model: AppModel) async {
        guard !working.contains("add") else { return }
        working.insert("add")
        defer { working.remove("add") }
        outcome = nil
        await settleList(id, model: model)
        await reload(model)
    }

    /// The List id in a link, as `x/client.py list_id` reads it (x.com/i/lists/<id>).
    nonisolated static func listId(_ value: String) -> String? {
        guard let match = value.range(of: "/i/lists/[1-9][0-9]{0,18}/?$", options: .regularExpression) else { return nil }
        return value[match].split(separator: "/").last.map(String.init)
    }

    /// Reads a List's name and members (up to 4 pages of 25, one read each, plus one for the List).
    private func readMembers(_ id: String, key: String, model: AppModel) async throws -> XOperationReply {
        let client = model.client
        var request = BackendClient.requestId("xlist")
        let marker = markSlow(key)
        defer { marker.cancel(); slow.remove(key) }
        do {
            let reply: XOperationReply = try await client.revisioned { revision in
                request = BackendClient.requestId("xlist")
                return try BackendRPC.decode(await client.call(.xListsRefresh, ["list_id": id, "request_id": request, "revision": revision]))
            }
            return reply.state == "running" ? try await follow(request, client: client) : reply
        } catch is SocketFailure {
            return try await follow(request, client: client)
        }
    }

    /// Reads a listed List's members again; new members wait for the owner's choice.
    func refreshList(_ id: String, model: AppModel) async {
        let key = "list." + id
        guard !working.contains(key) else { return }
        working.insert(key)
        defer { working.remove(key) }
        failures[key] = nil
        do {
            let reply = try await readMembers(id, key: key, model: model)
            failures[key] = reply.state == "running" ? BackendError(code: "x_still_running", domain: "x") : reply.failure
        } catch {
            failures[key] = BackendError.wrapping(error)
        }
        await reload(model)
    }

    /// Takes a List's members into the List's kind and its X digest (the add row's "Add", or the
    /// List row's "In Digest" for members still outside it).
    func adoptMembers(_ listId: String, key: String = "add", model: AppModel) async {
        guard let list = lists.first(where: { $0.id == listId }) else { return }
        let ids = (pending(list) + notInDigest(list)).map(\.id)
        if await classify(ids, as: list.partition, key: key, model: model), key == "add" { outcome = nil }
    }

    /// The owner's choice for one new List member: ordinary, adult, or not at all.
    func choose(_ id: String, partition: String?, model: AppModel) async {
        guard let partition else {
            ignored.insert(id)
            defaults.set(ignored.sorted(), forKey: Self.ignoredKey)
            return
        }
        _ = await classify([id], as: partition, key: "member." + id, model: model)
    }

    /// Puts accounts that are in no kind yet, or already of `partition` but in no digest, into
    /// `partition` and its X digest, in one saved change. An account of the other kind is left as
    /// it is (never moved here), and one already in a digest keeps its choice.
    @discardableResult
    private func classify(_ ids: [String], as partition: String, key: String, model: AppModel) async -> Bool {
        guard !ids.isEmpty else { return true }
        let digest = model.config?.xDigest(partition)?.id
        working.insert(key)
        defer { working.remove(key) }
        let editor = EditorState(client: model.client)
        let wanted = Set(ids)
        let saved = await editor.apply { document in
            var document = document
            document["accounts"] = (document["accounts"] as? [[String: Any]] ?? []).map { entry in
                let kind = entry["partition"] as? String
                guard let id = entry["id"] as? String, wanted.contains(id), kind == nil || kind == partition else {
                    return entry
                }
                var entry = entry
                entry["partition"] = partition
                if let digest, entry["subscription_id"] is NSNull || entry["subscription_id"] == nil {
                    entry["subscription_id"] = digest
                    entry["priority"] = "normal"
                    entry["bot_ids"] = [String]()
                    entry["times"] = NSNull()
                    entry["style"] = NSNull()
                }
                return entry
            }
            return document
        }
        await reload(model)
        // A lost reply: done when every account asked for is now in a digest, or of the other kind.
        let done = saved || (Self.uncertain(editor.failure) && accounts.filter { wanted.contains($0.id) }.allSatisfy { account in
            account.partition != nil && (account.partition != partition || account.subscriptionId != nil)
        })
        failures[key] = done ? nil : editor.failure
        return done
    }

    // MARK: Reads per day

    @discardableResult
    func saveDailyReads(_ text: String, model: AppModel) async -> Bool {
        guard let value = BudgetSummary.reads(text) else {
            failures["budget.daily"] = BackendError(code: "invalid_count", domain: "budget")
            return false
        }
        return await saveBudget("budget.daily", model: model, change: BudgetChange.dailyReads(value)) { $0.dailyReads == value }
    }

    @discardableResult
    func savePartitionReads(_ partition: String, _ text: String, model: AppModel) async -> Bool {
        let key = "budget." + partition
        guard let value = BudgetSummary.reads(text) else {
            failures[key] = BackendError(code: "invalid_count", domain: "budget")
            return false
        }
        return await saveBudget(key, model: model, change: BudgetChange.partitionReads(partition, value)) { budget in
            budget.limits.first { $0.kind == .partition(partition) }?.value == value
        }
    }

    /// The reads-per-day limit of one kind of content, when one is set.
    func partitionLimit(_ partition: String) -> BudgetSummary.Limit? {
        budget?.limits.first { $0.kind == .partition(partition) }
    }

    private func saveBudget(_ key: String, model: AppModel, change: @escaping EditorState.Change,
                            applied: @escaping (BudgetSummary) -> Bool) async -> Bool {
        guard !working.contains(key) else { return false }
        working.insert(key)
        defer { working.remove(key) }
        let editor = model.client.budgetEditor()
        let saved = await editor.apply(change)
        return await settle(key, editor: editor, saved: saved, model: model) { self.budget.map(applied) ?? false }
    }

    // MARK: Alerts

    private func alertsEditor(_ client: BackendClient) -> EditorState {
        EditorState(
            load: { try BackendClient.record(await client.call(.xAlertsStatus), field: "settings") },
            store: { _ = try await client.call(.xAlertsSave, ["settings": $0, "revision": $1]) }
        )
    }

    /// Default number of alerts a day when the owner turns alerts on (the stored 0 allows none).
    static let defaultAlertsPerDay = 3

    func setAlerts(_ on: Bool, model: AppModel) async {
        await saveAlerts(model: model, change: { settings in
            var settings = settings
            settings["enabled"] = on
            if on, (settings["daily_limit"] as? Int ?? 0) == 0 { settings["daily_limit"] = Self.defaultAlertsPerDay }
            return settings
        }, applied: { $0.enabled == on })
    }

    func addRule(_ rule: XAlertRule, model: AppModel) async -> Bool {
        await saveAlerts(model: model, change: { settings in
            var settings = settings
            settings["rules"] = (settings["rules"] as? [[String: Any]] ?? []) + [rule.fields]
            return settings
        }, applied: { $0.rules.contains(rule) })
    }

    func removeRule(_ rule: XAlertRule, model: AppModel) async {
        await saveAlerts(model: model, change: { settings in
            var settings = settings
            let rules = (settings["rules"] as? [[String: Any]] ?? []).filter { entry in
                !(entry["subscription_id"] as? String == rule.subscriptionId && entry["account_id"] as? String == rule.accountId
                    && entry["phrase"] as? String == rule.phrase)
            }
            settings["rules"] = rules
            // Alerts cannot stay on without a rule (x/alerts.py `_valid`).
            if rules.isEmpty { settings["enabled"] = false }
            return settings
        }, applied: { !$0.rules.contains(rule) })
    }

    /// `x.alerts.save` checks every stored rule, so a rule on an account that is no longer sent
    /// alone (moved into the digest, to the other kind, or removed) would make each later alert
    /// change fail. Such rules go with the account; alerts without a rule turn off.
    ///
    /// - Only the rules of the accounts whose change caused it (and earlier ones still pending)
    ///   are touched, so a rule someone else saved meanwhile survives a conflict retry.
    /// - Whether an account is still sent alone is decided from a directory read made now, after
    ///   the change, never from the page's cached view; the policy is read fresh too.
    /// - Cleanups run one at a time; what is not done stays pending, shown as the page's own
    ///   failure ("rules") with a retry, and the page's poll finishes it once reads work again.
    private func pruneRules(for ids: Set<String>, model: AppModel) async {
        cleanupPending.formUnion(ids)
        let prior = cleanupQueue
        let mine = Task { @MainActor [self] in
            _ = await prior?.value
            await runCleanup(model: model)
        }
        cleanupQueue = mine
        await mine.value
    }

    private func runCleanup(model: AppModel) async {
        let targets = cleanupPending
        guard !targets.isEmpty else {
            failures["rules"] = nil
            return
        }
        let client = model.client
        let fresh: [XAccountItem]
        do {
            struct Directory: Decodable { let accounts: [XAccountItem] }
            let directory: Directory = try BackendRPC.decode(await client.call(.xAccountsList))
            fresh = directory.accounts
        } catch {
            failures["rules"] = BackendError.wrapping(error)
            return
        }
        if let failure = await readAlerts(client) {
            failures["rules"] = failure
            return
        }
        let stale = targets.subtracting(fresh.filter(\.sendsAlone).map(\.id))
        guard let rules = alerts?.rules, rules.contains(where: { $0.accountId.map(stale.contains) ?? false }) else {
            cleanupPending.subtract(targets)
            failures["rules"] = cleanupPending.isEmpty ? nil : failures["rules"]
            return
        }
        let saved = await saveAlerts("rules", model: model) { settings in
            var settings = settings
            let kept = (settings["rules"] as? [[String: Any]] ?? []).filter { entry in
                !((entry["account_id"] as? String).map(stale.contains) ?? false)
            }
            settings["rules"] = kept
            if kept.isEmpty { settings["enabled"] = false }
            return settings
        }
        if saved { cleanupPending.subtract(targets) }
    }

    /// Accounts whose alert-rule cleanup has not succeeded yet.
    @ObservationIgnored private var cleanupPending: Set<String> = []
    @ObservationIgnored private var cleanupQueue: Task<Void, Never>?
    var hasPendingRuleCleanup: Bool { !cleanupPending.isEmpty }

    /// Reruns only the pending cleanup of alert rules (the note's retry, and the page's poll).
    func retryRuleCleanup(model: AppModel) async {
        await pruneRules(for: [], model: model)
    }

    @discardableResult
    private func saveAlerts(_ key: String = "alerts", model: AppModel, change: @escaping EditorState.Change,
                            applied: ((XAlertPolicy) -> Bool)? = nil) async -> Bool {
        guard !working.contains(key) else { return false }
        working.insert(key)
        defer { working.remove(key) }
        let editor = alertsEditor(model.client)
        let saved = await editor.apply(change)
        // A lost reply on the rule cleanup stays pending: its next run reads the stored rules.
        return await settle(key, editor: editor, saved: saved, model: model) {
            guard let applied, let alerts = self.alerts else { return false }
            return applied(alerts)
        }
    }

    // MARK: Video

    /// Ordinary models that can look at frames, and ones that can transcribe audio (OpenAI's own
    /// address, as `supported_stt_profile` requires), each with a passed check.
    nonisolated static func videoModels(_ config: AppConfig?) -> (vision: [String], speech: [String]) {
        let ordinary = config?.modelProfiles.filter { $0.partition == "normal" && $0.credentialRef != nil } ?? []
        let vision = ordinary.filter { $0.capabilities.contains("vision") }.map(\.id)
        let speech = ordinary.filter { profile in
            profile.capabilities.contains("stt") && profile.provider == "openai"
                && (profile.baseUrl ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "https://api.openai.com/v1"
        }.map(\.id)
        return (vision, speech)
    }

    /// Built-in amounts used when video checks are turned on with nothing set (contract §2:
    /// $0.05 per vision and transcription call; one dollar and five videos a day).
    static let videoDefaults: [String: Int] = [
        "vision_hold": 50_000, "stt_hold": 50_000, "daily_model_limit": 1_000_000, "daily_limit": 5,
    ]

    func setVideo(_ on: Bool, model: AppModel) async {
        await saveVideo("video", model: model, applied: { $0.enabled == on }) { settings in
            var settings = settings
            settings["enabled"] = on
            if on {
                for (name, value) in Self.videoDefaults where (settings[name] as? Int ?? 0) == 0 { settings[name] = value }
            }
            return settings
        }
    }

    /// `x.video.save` checks every stored model id, on or off: an id that is no longer an
    /// ordinary model able to do it (removed, changed, or its check lost) would refuse every save.
    /// Such ids are dropped, and a list left empty while on is filled from the models that can.
    nonisolated static func usableVideoModels(_ settings: [String: Any], config: AppConfig?) -> [String: Any] {
        let models = videoModels(config)
        var settings = settings
        let on = settings["enabled"] as? Bool ?? false
        for (key, valid) in [("vision_profiles", models.vision), ("stt_profiles", models.speech)] {
            var kept = (settings[key] as? [String] ?? []).filter(valid.contains)
            if on, kept.isEmpty { kept = Array(valid.prefix(1)) }
            settings[key] = kept
        }
        return settings
    }

    /// Whole dollars a day for video checks (at least $1 while they are on).
    @discardableResult
    func saveVideoBudget(_ text: String, model: AppModel) async -> Bool {
        guard let parsed = BudgetSummary.microDollars(text), let value = parsed, value > 0 else {
            failures["video.budget"] = BackendError(code: "invalid_video_amount", domain: "x")
            return false
        }
        return await saveVideo("video.budget", model: model, applied: { $0.dailyModelLimit == value }) { settings in
            var settings = settings
            settings["daily_model_limit"] = value
            return settings
        }
    }

    @discardableResult
    private func saveVideo(_ key: String, model: AppModel, applied: @escaping (XVideoPolicy) -> Bool,
                           change: @escaping EditorState.Change) async -> Bool {
        guard !working.contains(key) else { return false }
        working.insert(key)
        defer { working.remove(key) }
        let client = model.client
        let editor = EditorState(
            load: { try BackendClient.record(await client.call(.xVideoPolicy), field: "settings") },
            store: { _ = try await client.call(.xVideoSave, ["settings": $0, "revision": $1]) }
        )
        let config = model.config
        let saved = await editor.apply { Self.usableVideoModels(try change($0), config: config) }
        return await settle(key, editor: editor, saved: saved, model: model) { self.video.map(applied) ?? false }
    }

    /// Checks one video (may use X reads and model budget; the owner confirms first). A check
    /// already made is read back instead of being paid for again.
    func inspect(_ candidate: XVideoCandidate, model: AppModel) async {
        let key = "video." + candidate.id
        guard !working.contains(key) else { return }
        working.insert(key)
        defer { working.remove(key) }
        failures[key] = nil
        let client = model.client
        let request = candidate.requestId ?? BackendClient.requestId("xvideo")
        do {
            let result: XVideoResult = candidate.requestId != nil
                ? try BackendRPC.decode(await client.call(.xVideoStatus, ["request_id": request]))
                : try BackendRPC.decode(await client.call(.xVideoInspect, ["request_id": request, "job_id": candidate.jobId, "post_id": candidate.postId]))
            inspections[candidate.id] = result
        } catch is SocketFailure {
            // Still running in the backend: its record answers once it is done.
            failures[key] = BackendError(code: "x_still_running", domain: "x")
        } catch {
            failures[key] = BackendError.wrapping(error)
        }
        if let data = try? await client.call(.xVideoCandidates), let list: [XVideoCandidate] = try? BackendRPC.decode(data) {
            candidates = list
        }
    }

    // MARK: Refresh

    private func reload(_ model: AppModel) async {
        await model.refresh()
        await load(model: model)
    }
}
