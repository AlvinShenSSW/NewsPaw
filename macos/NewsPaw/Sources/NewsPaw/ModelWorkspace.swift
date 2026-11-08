import CoreFoundation
import Foundation
import SwiftUI

enum ConnectionCopy {
    case editModel, provider, endpoint, modelId, key, save, storeKey, clearKey, probe, retryProbe, hold
    case text, vision, image, speech, extraModel, routing, inherit, ordinaryText, adultText
    case connectBot, token, botName, verify, pair, test, testStatus, pause, resume, unbind
    case allowAdult, removeBot, deleteImpact, affected, pairedCode, expiry
    case policy, budget, modelLimit, imageLimit, xLimit, settled, reserved, remaining, unknown
    case reported, estimated, pages, unclassifiedMedia
    case schedule, automatic, normalHold, adultHold, search, tools, configureImage, configureSpeech

    func text(_ locale: AppLanguage) -> String {
        let values: (String, String, String) = switch self {
        case .editModel: ("编辑模型", "Edit model", "モデルを編集")
        case .provider: ("供应商", "Provider", "プロバイダー")
        case .endpoint: ("API 地址", "API URL", "API URL")
        case .modelId: ("模型 ID", "Model ID", "モデル ID")
        case .key: ("API Key", "API key", "API キー")
        case .save: ("保存", "Save", "保存")
        case .storeKey: ("存入钥匙串", "Save to Keychain", "キーチェーンに保存")
        case .clearKey: ("移除凭据", "Remove credential", "認証情報を削除")
        case .probe: ("验证能力", "Verify capability", "機能を検証")
        case .retryProbe: ("重试同一验证请求", "Retry the same verification", "同じ検証を再試行")
        case .hold: ("单次预算上限（微美元）", "Attempt cap (micro-USD)", "試行上限（マイクロ米ドル）")
        case .text: ("文字", "Text", "テキスト")
        case .vision: ("视觉理解", "Vision", "画像認識")
        case .image: ("生图", "Image generation", "画像生成")
        case .speech: ("语音转写", "Transcription", "音声の文字起こし")
        case .unclassifiedMedia: ("历史媒体费用（类型不明）", "Older media costs (type unknown)", "過去のメディア費用（種類不明）")
        case .extraModel: ("添加独立能力模型", "Add capability profile", "機能別モデルを追加")
        case .routing: ("分类模型覆盖", "Category model overrides", "カテゴリ別モデル設定")
        case .inherit: ("使用分区默认", "Use partition default", "区分の既定値を使用")
        case .ordinaryText: ("普通新闻文字主备", "Ordinary news text models", "通常ニュースのテキストモデル")
        case .adultText: ("成人分区文字主备", "Adult partition text models", "成人向け区分のテキストモデル")
        case .connectBot: ("添加 Telegram Bot", "Add Telegram Bot", "Telegram Bot を追加")
        case .token: ("Bot Token", "Bot token", "Bot トークン")
        case .botName: ("Bot 显示名称", "Bot display name", "Bot の表示名")
        case .verify: ("验证 Bot", "Verify Bot", "Bot を検証")
        case .pair: ("生成配对码", "Generate pairing code", "ペアリングコードを作成")
        case .test: ("发送测试消息", "Send test message", "テストメッセージを送信")
        case .testStatus: ("查看测试结果", "Check test result", "テスト結果を確認")
        case .pause: ("暂停 Bot", "Pause Bot", "Bot を一時停止")
        case .resume: ("恢复 Bot", "Resume Bot", "Bot を再開")
        case .unbind: ("解除配对", "Unpair", "ペアリングを解除")
        case .allowAdult: ("允许成人分区投递", "Allow adult deliveries", "成人向け配信を許可")
        case .removeBot: ("删除 Bot", "Remove Bot", "Bot を削除")
        case .deleteImpact: ("删除影响", "Removal impact", "削除の影響")
        case .affected: ("受影响的订阅", "Affected subscriptions", "影響を受ける購読")
        case .pairedCode: ("请将这条命令发给该 Bot", "Send this command to this Bot", "この Bot にコマンドを送信してください")
        case .expiry: ("有效期", "Expires", "有効期限")
        case .policy: ("运行策略", "Run policy", "実行ポリシー")
        case .budget: ("费用和预算", "Usage and limits", "使用量と予算")
        case .modelLimit: ("模型每月上限（微美元）", "Monthly model cap (micro-USD)", "モデル月間上限（マイクロ米ドル）")
        case .imageLimit: ("生图每月上限（微美元）", "Monthly image cap (micro-USD)", "画像生成の月間上限（マイクロ米ドル）")
        case .xLimit: ("X 每日读取上限", "Daily X read cap", "X の日次読み取り上限")
        case .settled: ("已结算", "Settled", "精算済み")
        case .reserved: ("预留", "Held", "予約済み")
        case .pages: ("报纸图页数", "Newspaper pages", "新聞画像のページ数")
        case .reported: ("供应商报告", "Provider reported", "プロバイダー報告")
        case .estimated: ("按用量估算", "Usage-derived estimate", "使用量に基づく見積もり")
        case .remaining: ("剩余", "Remaining", "残り")
        case .unknown: ("结果不明", "Outcome unknown", "結果不明")
        case .schedule: ("定时推送", "Scheduled delivery", "定時配信")
        case .automatic: ("启用定时推送", "Enable scheduled delivery", "定時配信を有効にする")
        case .normalHold: ("普通每次模型预留（微美元）", "Ordinary attempt hold (micro-USD)", "通常試行の予約（マイクロ米ドル）")
        case .adultHold: ("成人每次模型预留（微美元）", "Adult attempt hold (micro-USD)", "成人向け試行の予約（マイクロ米ドル）")
        case .search: ("网页搜索", "Web search", "ウェブ検索")
        case .tools: ("独立多模态能力", "Separate media capabilities", "独立したメディア機能")
        case .configureImage: ("报纸图路由", "Newspaper image routing", "新聞画像の配信経路")
        case .configureSpeech: ("附件和语音配置", "Attachment and speech settings", "添付ファイルと音声設定")
        }
        return switch locale {
        case .zhHans: values.0
        case .en: values.1
        case .ja: values.2
        }
    }
}

struct SettingsRevision: Decodable { let revision: Int }

enum ProtectedSettings {
    static func record(_ data: Data, revision: Int, field: String = "document") throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let actual = result["revision"] as? NSNumber,
              CFGetTypeID(actual) != CFBooleanGetTypeID(), actual.doubleValue == Double(actual.intValue),
              let document = result[field] as? [String: Any] else { throw BackendFailure.invalidReply }
        guard actual.intValue == revision else { throw BackendFailure.conflict }
        return document
    }

    static func modify(
        _ document: [String: Any], collection: String, id: String,
        fields: [String: Any], new: [String: Any]? = nil
    ) throws -> [String: Any] {
        var document = document
        guard var records = document[collection] as? [[String: Any]] else { throw BackendFailure.invalidReply }
        if let index = records.firstIndex(where: { $0["id"] as? String == id }) {
            records[index].merge(fields) { _, new in new }
        } else if var entry = new {
            entry.merge(fields) { _, new in new }
            records.append(entry)
        } else {
            throw BackendFailure.conflict
        }
        document[collection] = records
        return document
    }
}

struct ProfileSelection: Identifiable {
    let profile: AppConfig.Profile?
    let partition: String
    let id: String

    init(profile: AppConfig.Profile?, partition: String) {
        self.profile = profile
        self.partition = partition
        id = profile?.id ?? "model_profiles_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }
}

struct ModelWorkspace: View {
    let model: AppModel
    let config: AppConfig
    @State private var editor: ProfileSelection?
    @State private var routing = false

    private func label(_ key: ConnectionCopy) -> String { key.text(model.uiLanguage) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(["normal", "adult"], id: \.self) { group in
                VStack(alignment: .leading, spacing: 7) {
                    Text(label(group == "adult" ? .adultText : .ordinaryText)).font(.headline)
                    ForEach(config.modelProfiles.filter { $0.partition == group }) { profile in
                        Button {
                            editor = ProfileSelection(profile: profile, partition: group)
                        } label: {
                            HStack {
                                Text(model.text(profile.role == "primary" ? .primary : .backup))
                                Text(profile.provider + " · " + profile.model)
                                Spacer()
                                Text(model.text(profile.capabilities.contains("text") ? .verified : .unverified))
                                Image(systemName: "chevron.right").accessibilityHidden(true)
                            }
                            .padding(8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Button(label(.extraModel)) { editor = ProfileSelection(profile: nil, partition: group) }
                }
            }
            Button(label(.routing)) { routing = true }
            CapabilityRouting(model: model, profiles: config.modelProfiles.filter { $0.partition == "normal" })
        }
        .sheet(item: $editor) { selection in ProfileEditor(model: model, selection: selection) }
        .sheet(isPresented: $routing) { CategoryRoutingEditor(model: model, config: config) }
    }
}

private struct ProbeProjection: Decodable {
    let state: String
    let errorKind: String?
}

private struct ProbeResult: Decodable {
    let status: String
    let errorKind: String?
}

struct ModelProbeRequest {
    let id = UUID().uuidString.lowercased()
    let revision: Int
    let capability: String
    let units: Int

    func fields(profileId: String) -> [String: Any] {
        ["probe_id": id, "profile_id": profileId, "capability": capability, "hold_units": units, "revision": revision]
    }
}

private struct ProfileEditor: View {
    let model: AppModel
    let selection: ProfileSelection
    @Environment(\.dismiss) private var dismiss
    @State private var revision: Int
    @State private var provider: String
    @State private var endpoint: String
    @State private var modelId: String
    @State private var role: String
    @State private var exists: Bool
    @State private var savedIdentity: [String]
    @State private var credential = ""
    @State private var capability = "text"
    @State private var hold = ""
    @State private var statuses: [String: ProbeProjection] = [:]
    @State private var last: ProbeResult?
    @State private var failure: Phrase?
    @State private var busy = false
    @State private var confirmClear = false

    init(model: AppModel, selection: ProfileSelection) {
        self.model = model
        self.selection = selection
        let previous = selection.profile
        let standard = selection.partition == "normal" ? "openai" : "deepseek"
        _revision = State(initialValue: model.configRevision)
        _provider = State(initialValue: previous?.provider ?? standard)
        _endpoint = State(initialValue: previous?.baseUrl ?? (standard == "openai" ? "https://api.openai.com/v1" : "https://api.deepseek.com"))
        _modelId = State(initialValue: previous?.model ?? "")
        _role = State(initialValue: previous?.role ?? "primary")
        _exists = State(initialValue: previous != nil)
        _savedIdentity = State(initialValue: previous.map { [$0.provider, $0.baseUrl ?? "", $0.model] } ?? [])
        if let pending = model.pendingModelProbes[selection.id] {
            _capability = State(initialValue: pending.capability)
            _hold = State(initialValue: String(pending.units))
        }
    }

    private func label(_ key: ConnectionCopy) -> String { key.text(model.uiLanguage) }
    private var configured: Bool { exists && savedIdentity == [provider, endpoint, modelId] }
    private var pendingProbe: ModelProbeRequest? { model.pendingModelProbes[selection.id] }

    var body: some View {
        VStack {
            Form {
                Section(label(.editModel)) {
                    Text(model.text(selection.partition == "adult" ? .adult : .ordinary))
                    Picker(label(.provider), selection: $provider) {
                        ForEach(Array(Set(["openai", "mimo", "deepseek", "grok", provider])).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    TextField(label(.endpoint), text: $endpoint)
                    TextField(label(.modelId), text: $modelId)
                    Picker(model.text(.modelSlots), selection: $role) {
                        Text(model.text(.primary)).tag("primary")
                        Text(model.text(.backup)).tag("backup")
                    }
                    .disabled(exists)
                    Button(label(.save)) { Task { await saveProfile() } }
                        .disabled(modelId.isEmpty || endpoint.isEmpty)
                }
                Section(label(.key)) {
                    SecureField(label(.key), text: $credential)
                    Button(label(.storeKey)) { Task { await changeCredential(clear: false) } }
                        .disabled(!configured || credential.isEmpty)
                    Button(label(.clearKey), role: .destructive) { confirmClear = true }.disabled(!exists)
                }
                Section(label(.probe)) {
                    Picker(label(.probe), selection: $capability) {
                        Text(label(.text)).tag("text")
                        if selection.partition == "normal" {
                            Text(label(.vision)).tag("vision")
                            Text(label(.image)).tag("image")
                            Text(label(.speech)).tag("stt")
                        }
                    }
                    .disabled(pendingProbe != nil)
                    if let status = statuses[capability] {
                        Text(model.text(status.state == "verified" ? .verified : .unverified))
                        if let error = status.errorKind { Text(connectionReason(error, locale: model.uiLanguage)).font(.caption).foregroundStyle(.secondary) }
                    }
                    TextField(label(.hold), text: $hold)
                        .disabled(pendingProbe != nil)
                    Button(label(pendingProbe == nil ? .probe : .retryProbe)) { Task { await probe() } }
                        .disabled(!configured || (pendingProbe == nil && (boundedUnits(hold) ?? 0) <= 0))
                    if let error = last?.errorKind, error != statuses[capability]?.errorKind {
                        Text(connectionReason(error, locale: model.uiLanguage)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let failure { Text(model.text(failure)).foregroundStyle(.secondary) }
            }
            .formStyle(.grouped)
            HStack { Spacer(); Button(SubscriptionCopy.dismiss.text(model.uiLanguage)) { dismiss() } }.padding()
        }
        .disabled(busy)
        .frame(minWidth: 600, minHeight: 560)
        .task { if exists { await perform { try await refreshStatuses() } } }
        .confirmationDialog(label(.clearKey), isPresented: $confirmClear) {
            Button(label(.clearKey), role: .destructive) { Task { await changeCredential(clear: true) } }
        }
    }

    private func perform(_ action: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        failure = nil
        defer { busy = false }
        do { try await action() }
        catch BackendFailure.conflict { failure = .conflict }
        catch { failure = .saveFailed }
    }

    private func refreshStatuses() async throws {
        statuses = try BackendRPC.decode(await model.request("models.status", fields: ["profile_id": selection.id]))
    }

    private func saveProfile() async {
        await perform {
            let current = try ProtectedSettings.record(await model.request("config.get"), revision: revision)
            let fields: [String: Any] = ["provider": provider, "base_url": endpoint, "model": modelId]
            let changed = try ProtectedSettings.modify(
                current, collection: "model_profiles", id: selection.id, fields: fields,
                new: ["id": selection.id, "partition": selection.partition, "role": role, "credential_ref": NSNull(), "capabilities": []]
            )
            let result: SettingsRevision = try BackendRPC.decode(await model.request(
                "config.save", fields: ["revision": revision, "document": changed]
            ))
            revision = result.revision
            exists = true
            savedIdentity = [provider, endpoint, modelId]
            try await refreshStatuses()
            await model.refresh()
        }
    }

    private func changeCredential(clear: Bool) async {
        let value = credential
        credential = ""
        await perform {
            var fields: [String: Any] = ["kind": "model_profiles", "id": selection.id, "revision": revision]
            if !clear { fields["value"] = value }
            let result: SettingsRevision = try BackendRPC.decode(await model.request(
                clear ? "credentials.remove" : "credentials.set", fields: fields
            ))
            revision = result.revision
            try await refreshStatuses()
            await model.refresh()
        }
    }

    private func probe() async {
        await perform {
            let request: ModelProbeRequest
            if let pendingProbe {
                request = pendingProbe
            } else {
                guard let units = boundedUnits(hold), units > 0 else { throw BackendFailure.rejected }
                request = ModelProbeRequest(revision: revision, capability: capability, units: units)
                model.pendingModelProbes[selection.id] = request
                last = nil
            }
            let result: ProbeResult
            do {
                result = try BackendRPC.decode(await model.request(
                    "models.probe", fields: request.fields(profileId: selection.id)
                ))
            } catch BackendFailure.conflict {
                model.pendingModelProbes[selection.id] = nil
                throw BackendFailure.conflict
            }
            if result.status != "pending" { model.pendingModelProbes[selection.id] = nil }
            let current: ConfigSnapshot = try BackendRPC.decode(await model.request("config.get"))
            guard let saved = current.document.modelProfiles.first(where: { $0.id == selection.id }),
                  savedIdentity == [saved.provider, saved.baseUrl ?? "", saved.model] else {
                throw BackendFailure.conflict
            }
            revision = current.revision
            last = result
            try await refreshStatuses()
            await model.refresh()
        }
    }
}

func boundedUnits(_ raw: String) -> Int? {
    guard let number = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
          (0...9_007_199_254_740_992).contains(number) else { return nil }
    return number
}
