import Foundation
import SwiftUI

struct BotSelection: Identifiable {
    let bot: BotStatus?
    let id: String

    init(_ bot: BotStatus?) {
        self.bot = bot
        id = bot?.id ?? "bots_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }
}

struct BotWorkspace: View {
    let model: AppModel
    @State private var selection: BotSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(ConnectionCopy.connectBot.text(model.uiLanguage)) { selection = BotSelection(nil) }
            if model.bots.isEmpty { Text(model.text(.noBots)).foregroundStyle(.secondary) }
            ForEach(model.bots) { bot in
                Button {
                    selection = BotSelection(bot)
                } label: {
                    HStack {
                        Text(bot.name)
                        Spacer()
                        Text(model.text(bot.label)).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").accessibilityHidden(true)
                    }
                    .padding(7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(item: $selection) { BotEditor(model: model, selection: $0) }
    }
}

private struct PairCode: Decodable {
    let code: String
    let expiresAt: Double
}

private struct BotTestReceipt: Decodable {
    let generation: Int
    let state: String
    let reason: String?
}

private struct BotImpact: Decodable {
    struct Account: Decodable, Identifiable {
        let id: String
        let lastTarget: Bool
    }
    let revision: Int
    let subscriptions, lastTargetSubscriptions: [String]
    let accounts: [Account]
}

private struct TestRequest {
    let id = UUID().uuidString.lowercased()
    let generation: Int
}

private struct BotEditor: View {
    let model: AppModel
    let selection: BotSelection
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var revision: Int
    @State private var adult: Bool
    @State private var status: BotStatus?
    @State private var exists: Bool
    @State private var token = ""
    @State private var pairCode: PairCode?
    @State private var testRequest: TestRequest?
    @State private var receipt: BotTestReceipt?
    @State private var impact: BotImpact?
    @State private var confirmTest = false
    @State private var confirmRemove = false
    @State private var failure: Phrase?
    @State private var busy = false

    init(model: AppModel, selection: BotSelection) {
        self.model = model
        self.selection = selection
        _name = State(initialValue: selection.bot?.name ?? "")
        _revision = State(initialValue: model.configRevision)
        _status = State(initialValue: selection.bot)
        _exists = State(initialValue: selection.bot != nil)
        _adult = State(initialValue: model.config?.bots?.first(where: { $0.id == selection.id })?.adultAllowed ?? false)
    }

    private func label(_ key: ConnectionCopy) -> String { key.text(model.uiLanguage) }

    var body: some View {
        VStack {
            Form {
                Section(label(.botName)) {
                    TextField(label(.botName), text: $name)
                    Button(label(.save)) { Task { await saveName() } }.disabled(name.isEmpty)
                }
                Section(label(.token)) {
                    SecureField(label(.token), text: $token)
                    Button(label(.storeKey)) { Task { await storeToken() } }
                        .disabled(!exists || token.isEmpty)
                }
                if exists {
                    Section(label(.verify)) {
                        if let status {
                            Text(model.text(status.label))
                            if let username = status.username, !username.isEmpty {
                                Text("@" + username)
                            }
                            if let reason = status.status, !["verified", "paired", "unpaired", "awaiting_pair", "paused", "unverified"].contains(reason) {
                                Text(connectionReason(reason, locale: model.uiLanguage)).foregroundStyle(.secondary)
                            }
                        }
                        Button(model.text(.refresh)) { Task { await perform { try await refreshBot() } } }
                        Button(label(.verify)) { Task { await lifecycle("verify") } }
                        Button(label(.pair)) { Task { await lifecycle("pair") } }
                            .disabled(status?.verified != true)
                        if let pairCode {
                            Text(label(.pairedCode))
                            Text("/pair " + pairCode.code).textSelection(.enabled)
                            Text(label(.expiry) + " · " + Date(timeIntervalSince1970: pairCode.expiresAt).formatted())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section(ConnectionCopy.policy.text(model.uiLanguage)) {
                        Toggle(label(.allowAdult), isOn: $adult)
                        Button(label(.save)) { Task { await savePermission() } }
                        HStack {
                            Button(label(status?.paused == true ? .resume : .pause)) {
                                Task { await lifecycle(status?.paused == true ? "resume" : "pause") }
                            }
                            .disabled(status?.verified != true)
                            Button(label(.unbind)) { Task { await lifecycle("unbind") } }
                                .disabled(status?.paired != true)
                        }
                        Button(label(.test)) {
                            if let generation = status?.generation {
                                testRequest = TestRequest(generation: generation)
                                confirmTest = true
                            }
                        }
                        .disabled(status?.paired != true || status?.paused == true || status?.generation == nil)
                        if testRequest != nil {
                            Button(label(.testStatus)) { Task { await test(send: false) } }
                        }
                        if let receipt, status?.generation == receipt.generation {
                            Text(connectionReason(receipt.reason ?? receipt.state, locale: model.uiLanguage))
                        }
                        Button(label(.removeBot), role: .destructive) { Task { await previewRemoval() } }
                    }
                }
                if let failure { Text(model.text(failure)).foregroundStyle(.secondary) }
            }
            .formStyle(.grouped)
            HStack { Spacer(); Button(SubscriptionCopy.dismiss.text(model.uiLanguage)) { dismiss() } }.padding()
        }
        .frame(minWidth: 590, minHeight: 580)
        .disabled(busy)
        .task { if exists { await perform { try await refreshBot() } } }
        .confirmationDialog(label(.test), isPresented: $confirmTest) {
            Button(label(.test)) { Task { await test(send: true) } }
        } message: {
            Text(name)
        }
        .confirmationDialog(label(.deleteImpact), isPresented: $confirmRemove, presenting: impact) { impact in
            Button(label(.removeBot), role: .destructive) { Task { await remove(impact) } }
        } message: { impact in
            let subscriptions = model.config?.subscriptions.filter { impact.subscriptions.contains($0.id) } ?? []
            let accounts = model.config?.accounts.filter { account in impact.accounts.contains { $0.id == account.id } } ?? []
            let names = subscriptions.map { $0.name ?? $0.id } + accounts.map { "@" + $0.handle }
            Text(names.isEmpty ? SubscriptionCopy.none.text(model.uiLanguage) : names.joined(separator: "\n"))
        }
    }

    private func perform(_ action: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        failure = nil
        defer { busy = false }
        do { try await action() }
        catch BackendFailure.conflict { failure = .conflict }
        catch { failure = model.viewFailed(error) }
    }

    private func refreshBot() async throws {
        status = try model.decodeReply(await model.request("bots.status", fields: ["bot_id": selection.id]))
        let snapshot: ConfigSnapshot = try model.decodeReply(await model.request("config.get"))
        revision = snapshot.revision
        adult = snapshot.document.bots?.first(where: { $0.id == selection.id })?.adultAllowed ?? false
        if status?.paired == true { pairCode = nil }
        await model.refresh()
    }

    private func saveName() async {
        await perform {
            let current = try ProtectedSettings.record(await model.request("config.get"), revision: revision)
            let changed = try ProtectedSettings.modify(current, collection: "bots", id: selection.id,
                fields: ["name": name],
                new: ["id": selection.id, "credential_ref": NSNull(), "telegram_id": NSNull(), "chat_id": NSNull(),
                      "verified": false, "paired": false, "adult_allowed": false]
            )
            _ = try await model.request("config.save", fields: ["revision": revision, "document": changed])
            exists = true
            try await refreshBot()
        }
    }

    private func storeToken() async {
        let value = token
        token = ""
        pairCode = nil
        await perform {
            _ = try await model.request("credentials.set", fields: [
                "kind": "bots", "id": selection.id, "value": value, "revision": revision,
            ])
            try await refreshBot()
        }
    }

    private func lifecycle(_ action: String) async {
        await perform {
            var request: [String: Any] = ["bot_id": selection.id, "generation": status?.generation ?? 0]
            if action == "pair" {
                pairCode = try model.decodeReply(await model.request("bots.pair_code", fields: request))
            } else if action == "verify" {
                _ = try await model.request("bots.verify", fields: request)
                pairCode = nil
            } else {
                request["action"] = action
                _ = try await model.request("bots.action", fields: request)
                pairCode = nil
            }
            try await refreshBot()
        }
    }

    private func savePermission() async {
        await perform {
            _ = try await model.request("targets.adult_permission", fields: [
                "bot_id": selection.id, "allowed": adult, "revision": revision,
            ])
            try await refreshBot()
        }
    }

    private func test(send: Bool) async {
        guard let request = testRequest else { return }
        await perform {
            receipt = try model.decodeReply(await model.request(send ? "bots.test_send" : "bots.test_status", fields: [
                "bot_id": selection.id, "generation": request.generation, "request_id": request.id,
            ]))
            try await refreshBot()
        }
    }

    private func previewRemoval() async {
        await perform {
            impact = try model.decodeReply(await model.request("targets.bot_impact", fields: ["bot_id": selection.id]))
            confirmRemove = true
        }
    }

    private func remove(_ impact: BotImpact) async {
        await perform {
            _ = try await model.request("targets.delete_bot", fields: ["bot_id": selection.id, "revision": impact.revision])
            await model.refresh()
            dismiss()
        }
    }
}

func connectionReason(_ reason: String, locale: AppLanguage) -> String {
    let words: (String, String, String) = switch reason {
    case "confirmed": ("测试已送达", "Test delivered", "テストを配信しました")
    case "inflight": ("正在等待确认", "Awaiting confirmation", "確認待ちです")
    case "outcome_unknown": ("送达结果不明", "Delivery outcome unknown", "配信結果が不明です")
    case "not_started": ("尚未开始", "Not started", "未開始")
    case "authentication_failed", "token_revoked": ("凭据无效", "Credential rejected", "認証情報が無効です")
    case "permission_denied", "forbidden": ("服务拒绝访问", "Access denied", "アクセスが拒否されました")
    case "model_unavailable": ("模型不可用", "Model unavailable", "モデルを利用できません")
    case "rate_limited", "quota_exhausted": ("已到频率或额度上限", "Rate or quota limit reached", "レートまたは利用上限に達しました")
    case "probe_unavailable", "adapter_not_implemented": ("此能力暂不可验证", "This capability cannot be verified yet", "この機能はまだ検証できません")
    default: ("连接或设置需要检查", "Connection or settings need review", "接続または設定を確認してください")
    }
    return switch locale {
    case .zhHans: words.0
    case .en: words.1
    case .ja: words.2
    }
}
