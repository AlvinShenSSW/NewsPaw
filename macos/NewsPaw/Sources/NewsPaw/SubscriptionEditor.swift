import Foundation
import SwiftUI

enum SubscriptionCopy {
    case edit, new, name, zone, times, count, inherit, explicit, style, sourceList, botList
    case dismiss, inheritStyle, textStyle, imageStyle, newspaperStyle
    case weighted, domestic, entertainment, preview, draft, activate, route, ready, needsReview
    case missingTime, missingSource, missingBot, missingModel, previewSource
    case catalog, sourceURL, discover, saveSource, trial, accepted, pause, remove, impact
    case newSource, sourceType, xDestination, previewPassed, previewUnavailable
    case current, stale, unknownFreshness, partialCoverage
    case none, importOPML, duplicate, added, rejected, neutral, unsupported, enableSource
    case pauseCategory, pauseCategoryImpact, chooseSubscription, categoryPauseFailed

    func text(_ language: AppLanguage) -> String {
        let words: (String, String, String) = switch self {
        case .edit: ("编辑订阅", "Edit subscription", "購読を編集")
        case .new: ("新增订阅", "New subscription", "新しい購読")
        case .name: ("名称", "Name", "名前")
        case .zone: ("时区", "Time zone", "タイムゾーン")
        case .times: ("时间（HH:MM，逗号分隔）", "Times (HH:MM, comma separated)", "時刻（HH:MM、カンマ区切り）")
        case .count: ("每期条数上限", "Maximum items per edition", "1 号あたりの上限")
        case .inherit: ("使用分类来源", "Use category sources", "カテゴリの情報源を使う")
        case .explicit: ("仅使用勾选的来源", "Use only selected sources", "選択した情報源のみ")
        case .style: ("推送样式", "Delivery style", "配信形式")
        case .sourceList: ("来源", "Sources", "情報源")
        case .botList: ("推送 Bot", "Delivery Bots", "配信先 Bot")
        case .dismiss: ("取消", "Cancel", "キャンセル")
        case .inheritStyle: ("继承样式", "Inherit style", "既定の形式を使用")
        case .textStyle: ("文字和链接", "Text and links", "テキストとリンク")
        case .imageStyle: ("来源配图", "Source image", "情報源の画像")
        case .newspaperStyle: ("AI 报纸图", "AI newspaper", "AI 新聞画像")
        case .weighted: ("调整国内与娱乐的权重", "Weight domestic and entertainment coverage", "国内とエンタメの重みを調整")
        case .domestic: ("国内", "Domestic", "国内")
        case .entertainment: ("娱乐", "Entertainment", "エンタメ")
        case .preview: ("查看生效路由", "Preview effective route", "配信経路を確認")
        case .draft: ("保存为停用草稿", "Save inactive draft", "無効の下書きを保存")
        case .activate: ("保存并启用", "Save and enable", "保存して有効にする")
        case .route: ("生效路由", "Effective route", "配信経路")
        case .ready: ("可启用", "Ready to enable", "有効化できます")
        case .needsReview: ("配置待检查", "Configuration needs review", "設定を確認してください")
        case .missingTime: ("还没有推送时间", "No delivery time is set", "配信時刻が未設定です")
        case .missingSource: ("缺少可用来源", "No eligible sources", "利用可能な情報源がありません")
        case .missingBot: ("缺少已配对的推送 Bot", "A paired delivery Bot is needed", "ペアリング済みの Bot が必要です")
        case .missingModel: ("模型槽缺少凭据或能力验证", "Model credentials or verification are missing", "モデルの認証情報または検証が必要です")
        case .previewSource: ("来源需先通过试采集", "Sources need a collection preview", "情報源の試験取得が必要です")
        case .newSource: ("添加来源", "Add source", "情報源を追加")
        case .sourceType: ("来源类型", "Source type", "情報源の種類")
        case .xDestination: ("请在 X 账号页添加", "Add this on the X Accounts page", "X アカウント画面で追加してください")
        case .previewPassed: ("实际试采集通过", "Collection preview passed", "試験取得に成功しました")
        case .previewUnavailable: ("尚未通过试采集", "Collection preview has not passed", "試験取得は未確認です")
        case .current: ("当前有符合时间窗的新闻", "Current items in the time window", "対象期間内の記事があります")
        case .stale: ("时间窗内没有可用新闻", "No current items in the time window", "対象期間内の記事はありません")
        case .unknownFreshness: ("新鲜度未知", "Freshness unknown", "鮮度不明")
        case .partialCoverage: ("采集覆盖不完整", "Collection coverage is partial", "取得範囲は一部です")
        case .catalog: ("来源目录", "Source catalog", "情報源カタログ")
        case .sourceURL: ("来源网址", "Source URL", "情報源 URL")
        case .discover: ("识别来源", "Identify source", "情報源を識別")
        case .saveSource: ("保存停用来源", "Save inactive source", "無効の情報源を保存")
        case .trial: ("试采集", "Preview collection", "試験取得")
        case .accepted: ("符合条件的条数", "Eligible items", "対象記事数")
        case .pause: ("暂停来源", "Pause source", "情報源を一時停止")
        case .remove: ("删除来源", "Remove source", "情報源を削除")
        case .impact: ("受影响的订阅", "Affected subscriptions", "影響を受ける購読")
        case .none: ("无", "None", "なし")
        case .importOPML: ("导入 OPML", "Import OPML", "OPML を読み込む")
        case .duplicate: ("重复", "Duplicates", "重複")
        case .added: ("新增草稿", "Drafts added", "追加した下書き")
        case .rejected: ("未导入", "Rejected", "読み込み不可")
        case .neutral: ("未分类", "Unclassified", "未分類")
        case .unsupported: ("需要适配，已保留为草稿", "Adapter needed. Saved as a draft.", "アダプターが必要です。下書きとして保存しました")
        case .enableSource: ("启用已验证来源", "Enable verified source", "検証済みの情報源を有効にする")
        case .pauseCategory: ("暂停此分类", "Pause this category", "このカテゴリを一時停止")
        case .pauseCategoryImpact: ("该分类中启用的订阅将暂停，配置会保留。", "Active subscriptions in this category will pause. Their settings are kept.", "このカテゴリの有効な購読を一時停止します。設定は保持されます。")
        case .chooseSubscription: ("选择要启用的订阅", "Choose a subscription to activate", "有効にする購読を選択")
        case .categoryPauseFailed: ("未能暂停此分类", "Could not pause this category", "このカテゴリを一時停止できませんでした")
        }
        return switch language {
        case .zhHans: words.0
        case .en: words.1
        case .ja: words.2
        }
    }
}

struct SubscriptionSelection: Identifiable {
    let category: AppConfig.Category
    let subscription: AppConfig.Subscription?
    var revision: Int? = nil
    var previewsOnOpen = false
    var id: String { subscription?.id ?? "new-" + category.id }
}

struct CategorySubscriptionToggle: View {
    private enum Intent {
        case pause(revision: Int)
        case choose(revision: Int, subscriptions: [AppConfig.Subscription])
    }

    let model: AppModel
    let category: AppConfig.Category
    let title: String
    let subscriptions: [AppConfig.Subscription]
    let enabled: Bool
    let revision: Int
    let openEditor: (SubscriptionSelection) -> Void
    @State private var intent: Intent?
    @State private var failure: BackendFailure?

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Toggle(title, isOn: Binding(get: { enabled }, set: { prepare($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(title)
                .accessibilityIdentifier("category-toggle-\(category.id)")
                .disabled(model.busy)
            if let failure {
                Text(failure == .conflict ? model.text(.conflict) : label(.categoryPauseFailed))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(
            dialogTitle, isPresented: Binding(
                get: { intent != nil }, set: { if !$0 { intent = nil } }
            ), titleVisibility: .visible, presenting: intent
        ) { action in
            switch action {
            case .pause(let revision):
                Button(label(.pauseCategory), role: .destructive) {
                    Task { await pause(revision) }
                }
            case .choose(let revision, let options):
                ForEach(options) { subscription in
                    Button(subscription.name ?? subscription.id) {
                        preview(subscription, revision: revision)
                    }
                }
            }
            Button(label(.dismiss), role: .cancel) {}
        } message: { action in
            if case .pause = action {
                Text(label(.pauseCategoryImpact))
            }
        }
    }

    private var dialogTitle: String {
        if case .pause = intent { return label(.pauseCategory) }
        return label(.chooseSubscription)
    }

    private func prepare(_ on: Bool) {
        guard on != enabled, !model.busy else { return }
        failure = nil
        if !on {
            intent = .pause(revision: revision)
        } else if subscriptions.count > 1 {
            intent = .choose(revision: revision, subscriptions: subscriptions)
        } else {
            preview(subscriptions.first, revision: revision)
        }
    }

    private func preview(_ subscription: AppConfig.Subscription?, revision: Int) {
        openEditor(SubscriptionSelection(
            category: category, subscription: subscription, revision: revision, previewsOnOpen: true
        ))
    }

    private func pause(_ revision: Int) async {
        do {
            try await model.pauseCategory(category.id, revision: revision)
        } catch {
            failure = (error as? BackendFailure) ?? .rejected
        }
    }

    private func label(_ copy: SubscriptionCopy) -> String { copy.text(model.uiLanguage) }
}

struct SubscriptionDraft {
    let id: String
    let category: String
    var name: String
    var timezone: String
    var times: String
    var maxItems: Int
    var sourceIds: Set<String>
    var botIds: Set<String>
    var inherited: Bool
    var style: String
    var weighted: Bool
    var domestic: Int
    var entertainment: Int

    init(_ selection: SubscriptionSelection, defaultTimezone: String = "Asia/Tokyo") {
        let existing = selection.subscription
        id = existing?.id ?? "subscriptions_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        category = selection.category.id
        name = existing?.name ?? selection.category.name
        timezone = existing?.timezone ?? defaultTimezone
        times = existing?.times.joined(separator: ", ") ?? ""
        maxItems = existing?.maxItems ?? 5
        sourceIds = Set(existing?.sourceIds ?? [])
        botIds = Set(existing?.botIds ?? [])
        inherited = existing?.sourceMode.map { $0 == "category" } ?? sourceIds.isEmpty
        style = existing?.style ?? "text"
        weighted = existing?.focusWeights != nil
        domestic = existing?.focusWeights?["domestic"] ?? 50
        entertainment = existing?.focusWeights?["entertainment"] ?? 50
    }

    var isRegional: Bool { ["japan", "australia", "china"].contains(category) }

    var fields: [String: Any] {
        let slots = Set(times.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
        var result: [String: Any] = [
            "id": id, "category_id": category, "name": name,
            "timezone": timezone, "times": slots.sorted(), "max_items": maxItems,
            "source_mode": inherited ? "category" : "explicit",
            "source_ids": inherited ? [] : sourceIds.sorted(), "bot_ids": botIds.sorted(),
            "style": style,
        ]
        if isRegional && weighted {
            result["focus_weights"] = ["domestic": domestic, "entertainment": entertainment]
        }
        return result
    }
}

struct SubscriptionRoute: Decodable {
    struct Profile: Decodable { let provider, model, status: String }
    struct Source: Decodable, Identifiable { let id, name: String; let ready: Bool }
    let partition, timezone, style: String
    let times, bots, blockers: [String]
    let profiles: [String: Profile]
    let sources: [Source]
}

struct SubscriptionEditor: View {
    let model: AppModel
    let selection: SubscriptionSelection
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SubscriptionDraft
    @State private var revision: Int
    @State private var route: SubscriptionRoute?
    @State private var previewKey: Data?
    @State private var failure: Phrase?
    @State private var busy = false

    init(model: AppModel, selection: SubscriptionSelection) {
        self.model = model
        self.selection = selection
        _draft = State(initialValue: SubscriptionDraft(selection, defaultTimezone: model.config?.timezone ?? "Asia/Tokyo"))
        _revision = State(initialValue: selection.revision ?? model.configRevision)
    }

    private func label(_ key: SubscriptionCopy) -> String { key.text(model.uiLanguage) }
    private var draftKey: Data? {
        try? JSONSerialization.data(withJSONObject: draft.fields, options: [.sortedKeys])
    }

    private func selected(_ item: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(item) }, set: { enabled in
            if enabled { set.wrappedValue.insert(item) } else { set.wrappedValue.remove(item) }
        })
    }

    var body: some View {
        VStack(alignment: .leading) {
            Form {
                Section(selection.category.name) {
                    TextField(label(.name), text: $draft.name)
                    TextField(label(.zone), text: $draft.timezone)
                    TextField(label(.times), text: $draft.times)
                    Stepper("\(label(.count)) · \(draft.maxItems)", value: $draft.maxItems, in: 1...20)
                    Picker(label(.style), selection: $draft.style) {
                        Text(label(.textStyle)).tag("text")
                        Text(label(.imageStyle)).tag("source_image")
                        Text(label(.newspaperStyle)).tag("newspaper")
                    }
                }
                Section(label(.sourceList)) {
                    Picker(label(.sourceList), selection: $draft.inherited) {
                        Text(label(.inherit)).tag(true)
                        Text(label(.explicit)).tag(false)
                    }
                    if !draft.inherited {
                        ForEach(model.config?.sources.filter { $0.categoryIds?.contains(draft.category) == true } ?? []) { source in
                            Toggle(source.name, isOn: selected(source.id, in: $draft.sourceIds))
                        }
                    }
                    if draft.isRegional {
                        Toggle(label(.weighted), isOn: $draft.weighted)
                        if draft.weighted {
                            Stepper("\(label(.domestic)) · \(draft.domestic)", value: $draft.domestic, in: 0...100)
                            Stepper("\(label(.entertainment)) · \(draft.entertainment)", value: $draft.entertainment, in: 0...100)
                        }
                    }
                }
                Section(label(.botList)) {
                    ForEach(model.bots) { bot in
                        Toggle(bot.name, isOn: selected(bot.id, in: $draft.botIds))
                    }
                }
                if let route, previewKey == draftKey {
                    Section(label(.route)) {
                        Text(route.times.joined(separator: ", ") + " · " + route.timezone)
                        Text(model.text(route.partition == "adult" ? .adult : .ordinary))
                        Text(label(route.style == "source_image" ? .imageStyle : route.style == "newspaper" ? .newspaperStyle : .textStyle))
                        Text(route.profiles.keys.sorted().compactMap { route.profiles[$0]?.model }.joined(separator: " · "))
                        Text(route.sources.map(\.name).joined(separator: " · "))
                        Text(model.bots.filter { route.bots.contains($0.id) }.map(\.name).joined(separator: " · "))
                        ForEach(Array(Set(route.blockers.map(blocker))).sorted(), id: \.self) { Text($0) }
                        if route.blockers.isEmpty { Text(label(.ready)) }
                    }
                }
                if let failure { Text(model.text(failure)).foregroundStyle(.secondary) }
            }
            .formStyle(.grouped)
            HStack {
                Button(label(.dismiss)) { dismiss() }
                Spacer()
                Button(label(.preview)) { Task { await run(save: false, enable: false) } }
                Button(label(.draft)) { Task { await run(save: true, enable: false) } }
                Button(label(.activate)) { Task { await run(save: true, enable: true) } }
                    .disabled(route?.blockers.isEmpty != true || previewKey != draftKey)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .disabled(busy)
        .frame(minWidth: 590, minHeight: 560)
        .task {
            if selection.previewsOnOpen { await run(save: false, enable: false) }
        }
    }

    private func blocker(_ code: String) -> String {
        switch code {
        case "schedule_missing": label(.missingTime)
        case "no_sources", "source_disabled", "source_unadapted": label(.missingSource)
        case "no_target", "target_unpaired", "no_ready_bot", "missing_owner": label(.missingBot)
        case "source_preview_required": label(.previewSource)
        case let value where value.contains("primary") || value.contains("backup"): label(.missingModel)
        default: label(.needsReview)
        }
    }

    private func run(save: Bool, enable: Bool) async {
        guard !busy else { return }
        busy = true
        failure = nil
        defer { busy = false }
        do {
            let fields: [String: Any] = ["draft": draft.fields, "revision": revision]
            route = try model.decodeReply(await model.request("subscriptions.preview", fields: fields))
            previewKey = draftKey
            if save {
                guard !enable || route?.blockers.isEmpty == true else { return }
                _ = try await model.request("subscriptions.save", fields: fields.merging(["enable": enable]) { _, new in new })
                await model.refresh()
                dismiss()
            }
        } catch BackendFailure.conflict {
            failure = .conflict
        } catch {
            failure = model.viewFailed(error)
        }
    }
}
