import Foundation
import SwiftUI

enum XCopy: CaseIterable {
    case addAccount, addList, credential, configured, missing, handle, remoteIdentity, listURL, verify, refreshList
    case paidAction, confirm, routing, subscription, unassigned, include, postTypes, original, quote, reply, repost
    case overrideTimes, emptyTimes, overrideBots, changePartition, impact, cached, waiting, oldRoutes, policyReset
    case coverage, latest, completeRange, historical, pages, listMembers, listCurrent, listPending
    case caps, daily, normalCap, adultCap, accountCap, noUsage, failed, noLimit

    func text(_ locale: AppLanguage) -> String {
        let values: (String, String, String) = switch self {
        case .addAccount: ("添加 X 账号", "Add X account", "X アカウントを追加")
        case .addList: ("添加 X 列表", "Add X List", "X リストを追加")
        case .credential: ("X API 凭据", "X API credential", "X API 認証情報")
        case .configured: ("已配置", "Configured", "設定済み")
        case .missing: ("未配置", "Not configured", "未設定")
        case .handle: ("账号名", "Handle", "ユーザー名")
        case .remoteIdentity: ("X 账号 ID", "X account ID", "X アカウント ID")
        case .listURL: ("列表链接或 ID", "List URL or ID", "リストの URL または ID")
        case .verify: ("通过 X 验证账号", "Verify account on X", "X でアカウントを検証")
        case .refreshList: ("通过 X 刷新成员", "Refresh members from X", "X からメンバーを更新")
        case .paidAction: ("这一步可能消耗 X API 读取额度。", "This action can consume X API reads.", "この操作は X API の読み取り枠を消費する場合があります。")
        case .confirm: ("确认", "Confirm", "確認")
        case .routing: ("采集与投递设置", "Collection and delivery", "収集と配信")
        case .subscription: ("所属订阅", "Subscription", "購読")
        case .unassigned: ("未分配", "Unassigned", "未割り当て")
        case .include: ("也加入分区汇总", "Also include in the grouped digest", "区分のまとめにも含める")
        case .postTypes: ("帖子类型", "Post types", "投稿の種類")
        case .original: ("原帖", "Original posts", "オリジナル投稿")
        case .quote: ("引用", "Quotes", "引用")
        case .reply: ("回复", "Replies", "返信")
        case .repost: ("转发", "Reposts", "リポスト")
        case .overrideTimes: ("自定义时间", "Override schedule", "配信時刻を個別設定")
        case .emptyTimes: ("留空将暂停该账号的单独定时简报。", "Leave empty to pause this account’s scheduled digest.", "空欄にすると、このアカウントの個別配信を一時停止します。")
        case .overrideBots: ("自定义 Bot", "Override Bots", "Bot を個別設定")
        case .changePartition: ("更改分类", "Change partition", "区分を変更")
        case .impact: ("确认改分类", "Confirm partition change", "区分変更を確認")
        case .cached: ("留在原分区的缓存帖子", "Cached posts kept in the previous partition", "元の区分に残るキャッシュ済み投稿")
        case .waiting: ("受影响的待处理任务", "Affected pending jobs", "影響を受ける処理待ちのジョブ")
        case .oldRoutes: ("原订阅和 Bot 分配将清除。", "The current subscription and Bot assignment will be cleared.", "現在の購読と Bot の割り当ては解除されます。")
        case .policyReset: ("账号的自定义投递与帖子类型将重置。", "Custom delivery and post types will be reset.", "個別の配信設定と投稿の種類はリセットされます。")
        case .coverage: ("本地覆盖记录", "Local coverage", "ローカルの収集範囲")
        case .latest: ("最近一次", "Latest attempt", "直近の試行")
        case .completeRange: ("最近一次完整覆盖", "Last complete coverage", "直近の完全な収集範囲")
        case .historical: ("旧范围记录", "Historical scope", "以前の範囲")
        case .pages: ("已确认页数", "Confirmed pages", "確認済みページ数")
        case .listMembers: ("已观察到的成员", "Observed members", "確認できたメンバー")
        case .listCurrent: ("成员已验证", "Membership verified", "メンバー確認済み")
        case .listPending: ("等待完整成员验证", "Full membership verification pending", "全メンバーの確認待ち")
        case .caps: ("X 读取上限", "X read caps", "X 読み取り上限")
        case .daily: ("每日总读取上限", "Daily total read cap", "1 日の読み取り合計上限")
        case .normalCap: ("普通分区上限", "Ordinary partition cap", "通常区分の上限")
        case .adultCap: ("成人分区上限", "Adult partition cap", "成人向け区分の上限")
        case .accountCap: ("该账号上限", "This account’s cap", "このアカウントの上限")
        case .noUsage: ("本周期暂无读取记录。", "No reads recorded in this period.", "この期間の読み取り記録はありません。")
        case .failed: ("操作未完成。请刷新本地状态。", "The operation did not complete. Refresh local status.", "操作が完了しませんでした。ローカルの状態を更新してください。")
        case .noLimit: ("留空为不限额", "Leave blank for no cap", "上限なしの場合は空欄")
        }
        return switch locale {
        case .zhHans: values.0
        case .en: values.1
        case .ja: values.2
        }
    }
}

private struct XDirectoryView: Decodable {
    let revision: Int
    let credentialConfigured: Bool
    let accounts: [XAccount]
}

struct XAccount: Decodable, Identifiable {
    let id, handle, priority, state: String
    let partition, subscriptionId, style, observedAt, remoteId: String?
    let botIds, times, postTypes: [String]?
    let includeInAggregate: Bool?
    let canCollect, memberActive: Bool
}

private struct XList: Decodable, Identifiable {
    struct Member: Decodable { let accountId: String }
    let id, partition, state: String
    let name, checkedAt: String?
    let current: Bool
    let members: [Member]
}

struct XCoverage: Decodable {
    struct Observation: Decodable {
        let state: String
        let reason, fromTime, throughTime, observedAt, historyGap: String?
        let completedPages: Int
        let historical: Bool
    }
    let state: String
    let reason: String?
    let latest, lastComplete: Observation?
}

struct XPartitionImpact: Decodable {
    let revision, cachedPosts, pendingJobs: Int
    let partition, subscriptionId: String?
    let aggregateBotIds, specialBotIds: [String]
    let clearsSpecialOverrides, clearsPostTypes: Bool
}

private struct XReceipt: Decodable {
    let state: String
    let reason: String?
}

enum XRouteInput {
    static func overrides(times: String?, bots: Set<String>?, style: String) -> [String: Any] {
        let timesValue: Any = times.map { raw in
            raw.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init).sorted()
        } as Any? ?? NSNull()
        return [
            "times": timesValue,
            "bot_ids": bots.map { $0.sorted() } as Any? ?? NSNull(),
            "style": style.isEmpty ? NSNull() : style as Any,
        ]
    }
}

@MainActor private func xPartition(_ value: String?, _ model: AppModel) -> String {
    model.text(value == "normal" ? .ordinary : value == "adult" ? .adult : .unclassified)
}

@MainActor private func xFailure(_ error: Error, _ model: AppModel) -> String {
    (error as? BackendFailure) == .conflict ? model.text(.conflict) : XCopy.failed.text(model.uiLanguage)
}

func xState(_ value: String, _ locale: AppLanguage) -> String {
    let words: (String, String, String) = switch value {
    case "ready": ("已验证", "Verified", "確認済み")
    case "complete": ("完整", "Complete", "完了")
    case "pending", "running", "unobserved", "unverified": ("待确认", "Pending", "確認待ち")
    case "incomplete", "partial", "page_limit": ("部分覆盖", "Partial", "一部のみ")
    case "pagination_gap": ("分页覆盖有缺口", "Pagination coverage gap", "ページ取得範囲に欠落あり")
    case "outcome_unknown": ("结果未知", "Outcome unknown", "結果不明")
    case "budget_blocked", "account_limit", "partition_limit", "global_limit", "account_limit_requires_individual":
        ("读取额度受限", "Read cap reached", "読み取り上限")
    case "delivered": ("已送达", "Delivered", "配信済み")
    case "quiet_hours": ("安静时段，等待发送", "Deferred during quiet hours", "通知を控える時間帯のため保留")
    case "alert_daily_limit", "video_daily_budget", "model_limit", "provider_limit":
        ("已达预算或数量上限", "Budget or count cap reached", "予算または件数の上限に到達")
    case "alert_cooldown": ("同主题发送间隔未到", "Topic cooldown is active", "同じ話題の通知間隔中")
    case "alert_expired": ("提醒已过期", "Alert expired", "通知の有効期限切れ")
    case "video_audio_unavailable", "video_stt_unavailable":
        ("音频转写不可用", "Audio transcription unavailable", "文字起こしを利用できません")
    case "video_vision_unavailable":
        ("画面识别不可用", "Frame analysis unavailable", "フレームの解析を利用できません")
    case "video_duration_unsupported", "video_format_or_duration_unsupported":
        ("视频格式或时长超出支持范围", "Unsupported video format or duration", "未対応の動画形式または長さ")
    case "video_outcome_unknown", "video_interrupted", "video_timeout":
        ("处理结果未知", "Processing outcome unknown", "処理結果不明")
    case "video_scope_changed", "alert_policy_changed":
        ("授权范围或设置已变更", "Authorization or settings changed", "権限範囲または設定が変更されました")
    case "rate_limited": ("X 接口限流", "X rate limited", "X API レート制限")
    case "fresh_window", "coverage_scope_changed": ("采集范围已变更", "Coverage scope changed", "収集範囲が変更されました")
    case "protected": ("受保护账号", "Protected account", "非公開アカウント")
    case "credential_changed": ("凭据已变更", "Credential changed", "認証情報が変更されました")
    case "configuration_changed": ("配置已变更", "Configuration changed", "設定が変更されました")
    default: ("当前不可用", "Currently unavailable", "現在利用できません")
    }
    return switch locale {
    case .zhHans: words.0
    case .en: words.1
    case .ja: words.2
    }
}

struct XWorkspace: View {
    private enum Editor: String, Identifiable {
        case account, list, credential, budget
        var id: String { rawValue }
    }

    let model: AppModel
    @State private var directory: XDirectoryView?
    @State private var lists: [XList] = []
    @State private var editor: Editor?
    @State private var account: XAccount?
    @State private var list: XList?
    @State private var failure: String?

    private func text(_ key: XCopy) -> String { key.text(model.uiLanguage) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack { actions }
                VStack(alignment: .leading) { actions }
            }
            if let failure { Text(failure).foregroundStyle(.secondary) }
            if let directory {
                Text(text(directory.credentialConfigured ? .configured : .missing) + " · " + text(.credential))
                    .font(.caption).foregroundStyle(.secondary)
                if directory.accounts.isEmpty && lists.isEmpty {
                    Text(model.text(.noAccounts)).foregroundStyle(.secondary)
                }
                ForEach(["normal", "adult", ""], id: \.self) { key in
                    group(key.isEmpty ? nil : key, directory: directory)
                }
            } else {
                ProgressView().controlSize(.small).opacity(failure == nil ? 1 : 0)
            }
        }
        .task(id: model.configRevision) { await reload() }
        .sheet(item: $editor, onDismiss: refresh) { value in
            if value == .budget {
                XBudgetEditor(model: model, accountID: nil)
            } else {
                XAddEditor(model: model, kind: value.rawValue)
            }
        }
        .sheet(item: $account, onDismiss: refresh) {
            XAccountEditor(model: model, account: $0, revision: directory?.revision ?? 0)
        }
        .sheet(item: $list, onDismiss: refresh) { XListEditor(model: model, list: $0) }
    }

    @ViewBuilder private var actions: some View {
        Button(text(.addAccount)) { editor = .account }
        Button(text(.addList)) { editor = .list }
        Button(text(.credential)) { editor = .credential }
        Button(text(.caps)) { editor = .budget }
        XFeatures(model: model)
        Button(model.text(.refresh), action: refresh)
    }

    @ViewBuilder private func group(_ partition: String?, directory: XDirectoryView) -> some View {
        let entries = directory.accounts.filter { $0.partition == partition }
        let matchingLists = lists.filter { $0.partition == partition }
        if !entries.isEmpty || !matchingLists.isEmpty {
            Text(xPartition(partition, model)).font(.headline)
            VStack(spacing: 2) {
                ForEach(entries) { entry in
                    row("@" + entry.handle, entry.state, symbol: "at") { account = entry }
                }
                ForEach(matchingLists) { entry in
                    row(entry.name ?? "List " + entry.id, entry.state, symbol: "list.bullet") { list = entry }
                }
            }
            .padding(6)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func row(_ title: String, _ state: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Text(xState(state, model.uiLanguage)).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").accessibilityHidden(true)
            }
            .padding(7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func refresh() { Task { await reload() } }

    private func reload() async {
        do {
            async let accountsData = model.request("x.accounts.list")
            async let listsData = model.request("x.lists.list")
            let next: XDirectoryView = try model.decodeReply(await accountsData)
            let nextLists: [XList] = try model.decodeReply(await listsData)
            guard !Task.isCancelled else { return }
            directory = next
            lists = nextLists
            failure = nil
        } catch {
            guard !Task.isCancelled else { return }
            failure = xFailure(error, model)
        }
    }
}

private struct XAddEditor: View {
    let model: AppModel
    let kind: String
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var partition = ""
    @State private var includeAdult = false
    @State private var busy = false
    @State private var failure: String?

    private func text(_ key: XCopy) -> String { key.text(model.uiLanguage) }

    var body: some View {
        Form {
            if kind == "credential" {
                SecureField(text(.credential), text: $value)
            } else {
                TextField(text(kind == "list" ? .listURL : .handle), text: $value)
                Picker(text(.changePartition), selection: $partition) {
                    Text(xPartition(nil, model)).tag("")
                    Text(xPartition("normal", model)).tag("normal")
                    Text(xPartition("adult", model)).tag("adult")
                }
                if kind == "list" && partition == "adult" {
                    Toggle(ConnectionCopy.allowAdult.text(model.uiLanguage), isOn: $includeAdult)
                }
            }
            if let failure { Text(failure).foregroundStyle(.secondary) }
            HStack {
                Button(SubscriptionCopy.dismiss.text(model.uiLanguage)) { dismiss() }
                Spacer()
                Button(ConnectionCopy.save.text(model.uiLanguage)) { Task { await save() } }
                    .disabled(busy || value.isEmpty || (kind == "list" && partition.isEmpty))
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 470)
    }

    private func save() async {
        busy = true
        defer { busy = false }
        let revision = model.configRevision
        do {
            switch kind {
            case "credential":
                _ = try await model.request("credentials.set", fields: [
                    "kind": "x_api", "id": "x", "value": value, "revision": revision,
                ])
                value = ""
            case "list":
                _ = try await model.request("x.lists.add", fields: [
                    "value": value, "partition": partition, "revision": revision,
                    "default_adult": partition == "adult" && includeAdult,
                ])
            default:
                _ = try await model.request("x.accounts.add", fields: [
                    "handle": value, "revision": revision,
                    "partition": partition.isEmpty ? NSNull() : partition as Any,
                ])
            }
            await model.refresh()
            dismiss()
        } catch { failure = xFailure(error, model) }
    }
}

private struct XReadRequest {
    let id = UUID().uuidString.lowercased()
    let revision: Int
}

private struct XOfficialRead: View {
    let model: AppModel
    let title: String
    let operation, identityField, identity: String
    let revision: Int
    let onUpdate: () async -> Void
    @State private var request: XReadRequest?
    @State private var receipt: XReceipt?
    @State private var failure: String?
    @State private var confirm = false
    @State private var busy = false

    var body: some View {
        if let receipt {
            Text(xState(receipt.reason ?? receipt.state, model.uiLanguage))
                .foregroundStyle(.secondary)
        }
        if let failure { Text(failure).foregroundStyle(.secondary) }
        if let request {
            Button(model.text(.refresh)) { Task { await read(request, dispatch: false) } }.disabled(busy)
        } else {
            Button(title) { confirm = true }.disabled(busy || revision == 0)
        }
        Text(XCopy.paidAction.text(model.uiLanguage)).font(.caption).foregroundStyle(.secondary)
            .confirmationDialog(title, isPresented: $confirm) {
                Button(XCopy.confirm.text(model.uiLanguage)) {
                    let current = XReadRequest(revision: revision)
                    request = current
                    Task { await read(current, dispatch: true) }
                }
            }
    }

    private func read(_ request: XReadRequest, dispatch: Bool) async {
        busy = true
        failure = nil
        defer { busy = false }
        do {
            let data = try await (
                dispatch
                ? model.request(operation, fields: [
                    identityField: identity, "request_id": request.id, "revision": request.revision,
                ])
                : model.request("x.operation", fields: ["request_id": request.id])
            )
            let result: XReceipt = try model.decodeReply(data)
            receipt = result
            if result.state != "running" && result.state != "outcome_unknown" { self.request = nil }
            await model.refresh()
            await onUpdate()
        } catch {
            if (error as? BackendFailure) == .conflict { self.request = nil }
            failure = xFailure(error, model)
        }
    }
}

private struct XCoverageView: View {
    let model: AppModel
    let coverage: XCoverage?

    var body: some View {
        Section(XCopy.coverage.text(model.uiLanguage)) {
            if let coverage {
                Text(xState(coverage.reason ?? coverage.state, model.uiLanguage))
                if let latest = coverage.latest {
                    observation(latest, label: .latest)
                }
                if let complete = coverage.lastComplete {
                    observation(complete, label: .completeRange)
                }
            } else {
                Text(model.text(.unavailable)).foregroundStyle(.secondary)
            }
        }
    }

    private func observation(_ result: XCoverage.Observation, label: XCopy) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.text(model.uiLanguage)).font(.subheadline)
            if result.historical {
                Text(XCopy.historical.text(model.uiLanguage)).foregroundStyle(.secondary)
            }
            Text(XCopy.pages.text(model.uiLanguage) + " · " + result.completedPages.formatted())
            if let from = result.fromTime { Text(from).font(.caption.monospaced()) }
            if let through = result.throughTime { Text(through).font(.caption.monospaced()) }
            if let gap = result.historyGap {
                Text(xState(gap, model.uiLanguage)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct XAccountEditor: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var account: XAccount
    let revision: Int
    @State private var subscription: String
    @State private var priority: String
    @State private var include: Bool
    @State private var types: Set<String>
    @State private var overrideTimes: Bool
    @State private var times: String
    @State private var overrideBots: Bool
    @State private var bots: Set<String>
    @State private var style: String
    @State private var partition: String
    @State private var coverage: XCoverage?
    @State private var impact: XPartitionImpact?
    @State private var proposedPartition = ""
    @State private var confirmPartition = false
    @State private var budget = false
    @State private var busy = false
    @State private var failure: String?

    init(model: AppModel, account: XAccount, revision: Int) {
        self.model = model
        self.revision = revision
        _account = State(initialValue: account)
        _subscription = State(initialValue: account.subscriptionId ?? "")
        _priority = State(initialValue: account.priority)
        _include = State(initialValue: account.includeInAggregate ?? false)
        _types = State(initialValue: Set(account.postTypes ?? ["original", "quoted"]))
        _overrideTimes = State(initialValue: account.times != nil)
        _times = State(initialValue: account.times?.joined(separator: ", ") ?? "")
        _overrideBots = State(initialValue: account.botIds != nil && account.priority == "special")
        _bots = State(initialValue: Set(account.botIds ?? []))
        _style = State(initialValue: account.style ?? "")
        _partition = State(initialValue: account.partition ?? "")
    }

    private var subscriptions: [AppConfig.Subscription] {
        guard let partition = account.partition else { return [] }
        return model.config?.subscriptions.filter { $0.categoryId == (partition == "adult" ? "x_adult" : "x") } ?? []
    }

    private var isSpecial: Bool { priority == "special" && !subscription.isEmpty }
    private var stale: Bool { revision == 0 || revision != model.configRevision }
    private func text(_ key: XCopy) -> String { key.text(model.uiLanguage) }
    private func subscriptionText(_ key: SubscriptionCopy) -> String { key.text(model.uiLanguage) }

    var body: some View {
        Form {
            Section("@" + account.handle) {
                if let remote = account.remoteId {
                    LabeledContent(text(.remoteIdentity)) {
                        Text(remote).monospacedDigit().textSelection(.enabled)
                    }
                    .accessibilityIdentifier("x-remote-id")
                }
                Text(account.canCollect ? model.text(.enabled) : xState(account.state, model.uiLanguage))
                if let observed = account.observedAt { Text(observed).font(.caption.monospaced()) }
                XOfficialRead(
                    model: model, title: text(.verify), operation: "x.accounts.verify",
                    identityField: "account_id", identity: account.id, revision: stale ? 0 : revision,
                    onUpdate: reload
                )
            }
            Section(text(.routing)) {
                Picker(text(.subscription), selection: $subscription) {
                    Text(text(.unassigned)).tag("")
                    ForEach(subscriptions) { Text($0.name ?? $0.id).tag($0.id) }
                }
                Picker(model.text(.special), selection: $priority) {
                    Text(model.text(.ordinary)).tag("normal")
                    Text(model.text(.special)).tag("special")
                }
                if isSpecial {
                    Toggle(text(.include), isOn: $include)
                    Toggle(text(.overrideTimes), isOn: $overrideTimes)
                    if overrideTimes {
                        TextField(subscriptionText(.times), text: $times, prompt: Text("07:00, 20:30"))
                        Text(text(.emptyTimes)).font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle(text(.overrideBots), isOn: $overrideBots)
                    if overrideBots {
                        ForEach(model.bots.filter { bot in
                            account.partition != "adult" ||
                                model.config?.bots?.contains { $0.id == bot.id && $0.adultAllowed } == true
                        }) { bot in
                            Toggle(bot.name, isOn: membership(bot.id, in: $bots))
                        }
                    }
                    Picker(subscriptionText(.style), selection: $style) {
                        Text(subscriptionText(.inheritStyle)).tag("")
                        Text(subscriptionText(.textStyle)).tag("text")
                        Text(subscriptionText(.imageStyle)).tag("source_image")
                        Text(subscriptionText(.newspaperStyle)).tag("newspaper")
                    }
                }
            }
            Section(text(.postTypes)) {
                Toggle(text(.original), isOn: membership("original", in: $types))
                Toggle(text(.quote), isOn: membership("quoted", in: $types))
                Toggle(text(.reply), isOn: membership("replied_to", in: $types))
                Toggle(text(.repost), isOn: membership("retweeted", in: $types))
            }
            Section(text(.changePartition)) {
                Picker(text(.changePartition), selection: $partition) {
                    Text(xPartition(nil, model)).tag("")
                    Text(xPartition("normal", model)).tag("normal")
                    Text(xPartition("adult", model)).tag("adult")
                }
                Button(text(.impact)) { Task { await previewImpact() } }
                    .disabled(busy || stale || partition == (account.partition ?? ""))
            }
            XCoverageView(model: model, coverage: coverage)
            Button(text(.caps)) { budget = true }
            if stale { Text(model.text(.conflict)).foregroundStyle(.secondary) }
            if let failure { Text(failure).foregroundStyle(.secondary) }
            HStack {
                Button(subscriptionText(.dismiss)) { dismiss() }
                Spacer()
                Button(ConnectionCopy.save.text(model.uiLanguage)) { Task { await save() } }
                    .disabled(busy || stale || types.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 550, minHeight: 500)
        .task { await reload() }
        .sheet(isPresented: $budget) { XBudgetEditor(model: model, accountID: account.id) }
        .confirmationDialog(text(.impact), isPresented: $confirmPartition, presenting: impact) { view in
            Button(text(.confirm), role: .destructive) { Task { await classify(view) } }
        } message: { view in
            Text(impactMessage(view))
        }
    }

    private func membership(_ value: String, in values: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { values.wrappedValue.contains(value) }, set: { enabled in
            if enabled { values.wrappedValue.insert(value) } else { values.wrappedValue.remove(value) }
        })
    }

    private func impactMessage(_ view: XPartitionImpact) -> String {
        let ids = Set(view.aggregateBotIds + view.specialBotIds)
        let targets = ids.sorted().map { id in model.bots.first { $0.id == id }?.name ?? id }
        let route = subscriptions.first { $0.id == view.subscriptionId }?.name ?? view.subscriptionId
        return ([
            xPartition(view.partition, model) + " → " +
                xPartition(proposedPartition.isEmpty ? nil : proposedPartition, model),
            text(.cached) + " · " + view.cachedPosts.formatted(),
            text(.waiting) + " · " + view.pendingJobs.formatted(),
            text(.oldRoutes),
            view.clearsSpecialOverrides || view.clearsPostTypes ? text(.policyReset) : nil,
            route,
            targets.isEmpty ? nil : targets.joined(separator: ", "),
        ] as [String?]).compactMap { $0 }.joined(separator: "\n")
    }

    private func reload() async {
        do {
            async let state = model.request("x.accounts.status", fields: ["account_id": account.id])
            async let report = model.request("x.posts.coverage", fields: ["kind": "account", "scope": account.id])
            account = try model.decodeReply(await state)
            coverage = try model.decodeReply(await report)
        } catch { failure = xFailure(error, model) }
    }

    private func previewImpact() async {
        busy = true
        defer { busy = false }
        do {
            let next: XPartitionImpact = try model.decodeReply(
                await model.request("x.accounts.partition_impact", fields: ["account_id": account.id])
            )
            guard next.revision == revision else { throw BackendFailure.conflict }
            proposedPartition = partition
            impact = next
            confirmPartition = true
        } catch { failure = xFailure(error, model) }
    }

    private func classify(_ view: XPartitionImpact) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await model.request("x.accounts.classify", fields: [
                "account_id": account.id, "revision": view.revision,
                "partition": proposedPartition.isEmpty ? NSNull() : proposedPartition as Any,
            ])
            await model.refresh()
            dismiss()
        } catch { failure = xFailure(error, model) }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            var fields: [String: Any] = [
                "account_id": account.id, "revision": revision, "priority": priority,
                "subscription_id": subscription.isEmpty ? NSNull() : subscription as Any,
                "include_in_aggregate": isSpecial && include, "post_types": types.sorted(),
            ]
            if isSpecial {
                fields["overrides"] = XRouteInput.overrides(
                    times: overrideTimes ? times : nil, bots: overrideBots ? bots : nil, style: style
                )
            }
            _ = try await model.request("x.accounts.route", fields: fields)
            await model.refresh()
            dismiss()
        } catch { failure = xFailure(error, model) }
    }
}

private struct XListEditor: View {
    let model: AppModel
    @State var list: XList
    @Environment(\.dismiss) private var dismiss
    @State private var coverage: XCoverage?
    @State private var failure: String?

    var body: some View {
        Form {
            Section(list.name ?? "List " + list.id) {
                Text((list.current ? XCopy.listCurrent : XCopy.listPending).text(model.uiLanguage))
                Text(XCopy.listMembers.text(model.uiLanguage) + " · " + list.members.count.formatted())
                if let observed = list.checkedAt { Text(observed).font(.caption.monospaced()) }
                XOfficialRead(
                    model: model, title: XCopy.refreshList.text(model.uiLanguage), operation: "x.lists.refresh",
                    identityField: "list_id", identity: list.id, revision: model.configRevision, onUpdate: reload
                )
            }
            XCoverageView(model: model, coverage: coverage)
            if let failure { Text(failure).foregroundStyle(.secondary) }
            HStack {
                Button(SubscriptionCopy.dismiss.text(model.uiLanguage)) { dismiss() }
                Spacer()
                Button(model.text(.refresh)) { Task { await reload() } }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 510, minHeight: 330)
        .task { await reload() }
    }

    private func reload() async {
        do {
            let fields = ["kind": "list", "scope": list.id]
            async let states = model.request("x.lists.list")
            async let report = model.request("x.posts.coverage", fields: fields)
            let entries: [XList] = try model.decodeReply(await states)
            guard let latest = entries.first(where: { $0.id == list.id }) else {
                throw BackendFailure.conflict
            }
            list = latest
            coverage = try model.decodeReply(await report)
            failure = nil
        } catch { failure = xFailure(error, model) }
    }
}

private struct XBudgetReport: Decodable {
    struct Scope: Decodable { let used: Int; let remaining: Int? }
    struct Scopes: Decodable {
        let total: Scope
        let partitions, accounts: [String: Scope]?
    }
    struct Period: Decodable {
        let meter, start, end, timezone: String
        let knownSettled, held: Int
        let scopes: Scopes
    }
    struct Report: Decodable { let periods: [Period] }
    let report: Report
}

private struct XBudgetEditor: View {
    let model: AppModel
    let accountID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var revision = 0
    @State private var document: [String: Any] = [:]
    @State private var period: XBudgetReport.Period?
    @State private var daily = ""
    @State private var normal = ""
    @State private var adult = ""
    @State private var account = ""
    @State private var busy = false
    @State private var failure: String?

    private func text(_ key: XCopy) -> String { key.text(model.uiLanguage) }
    private func budgetText(_ key: ConnectionCopy) -> String { key.text(model.uiLanguage) }

    var body: some View {
        Form {
            Section(text(.caps)) {
                if accountID == nil {
                    TextField(text(.daily), text: $daily)
                    TextField(text(.normalCap), text: $normal)
                    TextField(text(.adultCap), text: $adult)
                } else {
                    TextField(text(.accountCap), text: $account)
                }
                Text(text(.noLimit)).font(.caption).foregroundStyle(.secondary)
            }
            .disabled(busy || revision == 0)
            if let period {
                Section(period.start + " – " + period.end) {
                    Text(budgetText(.settled) + " " + period.knownSettled.formatted() + " · " +
                         budgetText(.reserved) + " " + period.held.formatted())
                    if let accountID {
                        usage(.accountCap, scope: period.scopes.accounts?[accountID])
                    } else {
                        usage(.daily, scope: period.scopes.total)
                        usage(.normalCap, scope: period.scopes.partitions?["normal"])
                        usage(.adultCap, scope: period.scopes.partitions?["adult"])
                    }
                }
            } else {
                Text(text(.noUsage)).foregroundStyle(.secondary)
            }
            if let failure { Text(failure).foregroundStyle(.secondary) }
            HStack {
                Button(SubscriptionCopy.dismiss.text(model.uiLanguage)) { dismiss() }
                Spacer()
                Button(budgetText(.save)) { Task { await save() } }.disabled(busy || revision == 0)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 510, minHeight: 340)
        .task { await load() }
    }

    @ViewBuilder private func usage(_ key: XCopy, scope: XBudgetReport.Scope?) -> some View {
        if let scope {
            if let remaining = scope.remaining {
                LabeledContent(text(key), value: budgetText(.remaining) + " " + remaining.formatted())
            } else {
                LabeledContent(text(key), value: scope.used.formatted())
            }
        }
    }

    private func activePeriod(_ periods: [XBudgetReport.Period]) -> XBudgetReport.Period? {
        let whole = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        let now = Date()
        return periods.last { period in
            guard period.meter == "x",
                  let from = fractional.date(from: period.start) ?? whole.date(from: period.start),
                  let to = fractional.date(from: period.end) ?? whole.date(from: period.end) else { return false }
            return from <= now && now < to
        }
    }

    private func load() async {
        do {
            let data = try await model.request("budget.get")
            let version: SettingsRevision = try model.decodeReply(data)
            let usage: XBudgetReport = try model.decodeReply(data)
            document = try ProtectedSettings.record(data, revision: version.revision)
            guard let x = document["x"] as? [String: Any],
                  let partitionLimits = x["partition_limits"] as? [String: Any],
                  let accountLimits = x["account_limits"] as? [String: Any] else {
                throw BackendFailure.invalidReply
            }
            revision = version.revision
            period = activePeriod(usage.report.periods)
            daily = (x["daily_limit"] as? Int).map(String.init) ?? ""
            normal = (partitionLimits["normal"] as? Int).map(String.init) ?? ""
            adult = (partitionLimits["adult"] as? Int).map(String.init) ?? ""
            account = accountID.flatMap { accountLimits[$0] as? Int }.map(String.init) ?? ""
        } catch { failure = xFailure(error, model) }
    }

    private func limit(_ value: String) throws -> Any {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return NSNull() }
        guard let count = boundedUnits(value) else { throw BackendFailure.rejected }
        return count
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            guard var x = document["x"] as? [String: Any],
                  var accountLimits = x["account_limits"] as? [String: Any] else {
                throw BackendFailure.invalidReply
            }
            if let accountID {
                let value = try limit(account)
                if value is NSNull { accountLimits.removeValue(forKey: accountID) }
                else { accountLimits[accountID] = value }
                x["account_limits"] = accountLimits
            } else {
                x["daily_limit"] = try limit(daily)
                x["partition_limits"] = ["normal": try limit(normal), "adult": try limit(adult)]
            }
            var next = document
            next["x"] = x
            _ = try await model.request("budget.save", fields: ["revision": revision, "document": next])
            dismiss()
        } catch { failure = xFailure(error, model) }
    }
}
