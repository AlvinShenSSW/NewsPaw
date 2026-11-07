import Foundation
import SwiftUI

private enum XFeature: String, Identifiable {
    case alerts, video
    var id: String { rawValue }

    var readOperation: String { self == .alerts ? "x.alerts.status" : "x.video.policy" }
    var saveOperation: String { "x." + rawValue + ".save" }

    func label(_ language: AppLanguage) -> String {
        self == .alerts ? XFeatureCopy.alerts.text(language) : XFeatureCopy.video.text(language)
    }
}

private enum XFeatureCopy {
    case alerts, video, daily, cooldown, quietStart, quietEnd, age, topic, add, aggregate
    case spend, visionHold, audioHold, none, candidates, inspect, charge, result, transcript, observations

    func text(_ language: AppLanguage) -> String {
        let words: (String, String, String) = switch self {
        case .alerts: ("重大事件提醒", "Major event alerts", "重要イベント通知")
        case .video: ("视频覆盖", "Video coverage", "動画の確認範囲")
        case .daily: ("每日上限", "Daily limit", "1 日の上限")
        case .cooldown: ("同主题间隔（分钟）", "Topic cooldown (minutes)", "同じ話題の間隔（分）")
        case .quietStart: ("安静时段开始", "Quiet hours start", "通知を控える開始時刻")
        case .quietEnd: ("安静时段结束", "Quiet hours end", "通知を控える終了時刻")
        case .age: ("提醒有效期（分钟）", "Alert expiry (minutes)", "通知の有効時間（分）")
        case .topic: ("主题关键词", "Topic phrase", "話題のキーワード")
        case .add: ("添加规则", "Add rule", "ルールを追加")
        case .aggregate: ("分区汇总", "Grouped digest", "区分のまとめ")
        case .spend: ("每日模型预算（微美元）", "Daily model budget (micro-USD)", "1 日のモデル予算（マイクロ米ドル）")
        case .visionHold: ("每张画面预留（微美元）", "Per-frame hold (micro-USD)", "フレームごとの予約（マイクロ米ドル）")
        case .audioHold: ("转写预留（微美元）", "Transcription hold (micro-USD)", "文字起こしの予約（マイクロ米ドル）")
        case .none: ("未选择", "Unselected", "未選択")
        case .candidates: ("简报中的普通 X 帖子", "Ordinary X posts from briefs", "ニュース要約に掲載された通常の X 投稿")
        case .inspect: ("检查视频覆盖", "Inspect video coverage", "動画の確認範囲を調べる")
        case .charge: ("可能消耗 X 读取和模型额度。", "This can use X reads and model budget.", "X の読み取り枠とモデル予算を消費する場合があります。")
        case .result: ("最近结果", "Latest results", "直近の結果")
        case .transcript: ("音频转写（原文）", "Audio transcript (original)", "音声の文字起こし（原文）")
        case .observations: ("画面观察", "Frame observations", "フレームの観察結果")
        }
        return switch language {
        case .zhHans: words.0
        case .en: words.1
        case .ja: words.2
        }
    }
}

struct XFeatures: View {
    let model: AppModel
    @State private var feature: XFeature?

    var body: some View {
        Menu {
            Button(XFeature.alerts.label(model.uiLanguage)) { feature = .alerts }
            Button(XFeature.video.label(model.uiLanguage)) { feature = .video }
        } label: {
            Label(ConnectionCopy.policy.text(model.uiLanguage), systemImage: "ellipsis.circle")
        }
        .sheet(item: $feature) { XFeatureSheet(model: model, feature: $0) }
    }
}

private struct XAlertRule: Decodable, Identifiable {
    let subscriptionId: String
    let accountId: String?
    let phrase: String
    var id: String { subscriptionId + "/" + (accountId ?? "") + "/" + phrase }
    var fields: [String: Any] {
        ["subscription_id": subscriptionId, "account_id": accountId as Any? ?? NSNull(), "phrase": phrase]
    }
}

private struct XAlertFeed: Decodable {
    struct Occurrence: Decodable, Identifiable {
        let jobId, state: String
        let reason: String?
        var id: String { jobId }
    }
    struct Settings: Decodable { let rules: [XAlertRule] }
    let settings: Settings
    let occurrences: [Occurrence]
}

private struct XVideoCandidate: Decodable, Identifiable {
    let jobId, postId, title, author: String
    let requestId: String?
    var id: String { jobId + "/" + postId }
}

private struct XVideoView: Decodable {
    struct Frame: Decodable { let second: Double; let observation: String }
    let state: String
    let frames: [Frame]?
    let transcript, source: String?
    let gaps: [String]?
}

private struct XFeatureSheet: View {
    let model: AppModel
    let feature: XFeature
    @Environment(\.dismiss) private var dismiss
    @State private var revision = 0
    @State private var document: [String: Any] = [:]
    @State private var enabled = false
    @State private var timezone = "Asia/Tokyo"
    @State private var daily = ""
    @State private var cooldown = ""
    @State private var age = ""
    @State private var quietStart = ""
    @State private var quietEnd = ""
    @State private var topic = ""
    @State private var subscription = ""
    @State private var account = ""
    @State private var rules: [XAlertRule] = []
    @State private var occurrences: [XAlertFeed.Occurrence] = []
    @State private var spend = ""
    @State private var visionHold = ""
    @State private var audioHold = ""
    @State private var visionPrimary = ""
    @State private var visionBackup = ""
    @State private var speechPrimary = ""
    @State private var speechBackup = ""
    @State private var candidates: [XVideoCandidate] = []
    @State private var chosen: XVideoCandidate?
    @State private var videoRequest: String?
    @State private var video: XVideoView?
    @State private var confirming = false
    @State private var busy = false
    @State private var failure: String?

    private func text(_ key: XFeatureCopy) -> String { key.text(model.uiLanguage) }
    private func copy(_ key: ConnectionCopy) -> String { key.text(model.uiLanguage) }

    private var xSubscriptions: [AppConfig.Subscription] {
        model.config?.subscriptions.filter { $0.categoryId == "x" || $0.categoryId == "x_adult" } ?? []
    }

    var body: some View {
        Form {
            Section(feature.label(model.uiLanguage)) {
                Toggle(model.text(.enabled), isOn: $enabled)
                TextField(SubscriptionCopy.zone.text(model.uiLanguage), text: $timezone)
                TextField(text(.daily), text: $daily)
            }
            if feature == .alerts { alerts }
            else { videos }
            if let failure { Text(failure).foregroundStyle(.secondary) }
            HStack {
                Button(SubscriptionCopy.dismiss.text(model.uiLanguage)) { dismiss() }
                Spacer()
                Button(model.text(.refresh)) { Task { await load() } }.disabled(busy)
                Button(copy(.save)) { Task { await save() } }.disabled(busy || revision == 0)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 570, minHeight: 500)
        .task { await load() }
        .confirmationDialog(text(.inspect), isPresented: $confirming, presenting: chosen) { selected in
            Button(XCopy.confirm.text(model.uiLanguage)) { Task { await inspect(selected) } }
        } message: { _ in Text(text(.charge)) }
    }

    @ViewBuilder private var alerts: some View {
        Section {
            TextField(text(.cooldown), text: $cooldown)
            TextField(text(.age), text: $age)
            TextField(text(.quietStart), text: $quietStart, prompt: Text("22:00"))
            TextField(text(.quietEnd), text: $quietEnd, prompt: Text("07:00"))
        }
        Section(text(.add)) {
            Picker(XCopy.subscription.text(model.uiLanguage), selection: $subscription) {
                Text(text(.none)).tag("")
                ForEach(xSubscriptions) { Text($0.name ?? $0.id).tag($0.id) }
            }
            .onChange(of: subscription) { _, _ in account = "" }
            Picker(model.text(.accounts), selection: $account) {
                Text(text(.aggregate)).tag("")
                ForEach(model.config?.accounts.filter {
                    $0.priority == "special" && $0.subscriptionId == subscription
                } ?? []) { Text("@" + $0.handle).tag($0.id) }
            }
            TextField(text(.topic), text: $topic)
            Button(text(.add)) {
                rules.append(XAlertRule(subscriptionId: subscription, accountId: account.isEmpty ? nil : account, phrase: topic))
                topic = ""
            }
            .disabled(subscription.isEmpty || topic.trimmingCharacters(in: .whitespaces).count < 2 || rules.count >= 20)
            ForEach(rules) { rule in
                HStack {
                    Text(rule.phrase)
                    Text(rule.accountId.flatMap { id in
                        model.config?.accounts.first { $0.id == id }.map { "@" + $0.handle }
                    } ?? (xSubscriptions.first { $0.id == rule.subscriptionId }?.name ?? rule.subscriptionId))
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) { rules.removeAll { $0.id == rule.id } } label: {
                        Image(systemName: "minus.circle")
                    }
                }
            }
        }
        if !occurrences.isEmpty {
            Section(text(.result)) {
                ForEach(occurrences) { row in
                    Text(xState(row.reason ?? row.state, model.uiLanguage)).font(.caption)
                }
            }
        }
    }

    @ViewBuilder private var videos: some View {
        Section {
            TextField(text(.spend), text: $spend)
            TextField(text(.visionHold), text: $visionHold)
            TextField(text(.audioHold), text: $audioHold)
            profiles(copy(.vision), capability: "vision", primary: $visionPrimary, backup: $visionBackup)
            profiles(copy(.speech), capability: "stt", primary: $speechPrimary, backup: $speechBackup)
        }
        Section(text(.candidates)) {
            ForEach(candidates) { candidate in
                Button {
                    if let request = candidate.requestId {
                        Task { await inspectStatus(request) }
                    } else {
                        chosen = candidate
                        confirming = true
                    }
                } label: {
                    VStack(alignment: .leading) {
                        Text(candidate.title)
                        Text(candidate.author).font(.caption)
                    }
                }
                .disabled(busy || document["enabled"] as? Bool != true)
            }
            if let videoRequest {
                Button(model.text(.refresh)) { Task { await inspectStatus(videoRequest) } }.disabled(busy)
            }
        }
        if let video {
            Section(text(.result)) {
                Text(xState(video.state, model.uiLanguage)).font(.caption)
                if let source = video.source, let url = URL(string: source) { Link(source, destination: url) }
                if let frames = video.frames, !frames.isEmpty {
                    Text(text(.observations)).font(.headline)
                    ForEach(Array(frames.enumerated()), id: \.offset) { _, frame in
                        Text(frame.second.formatted() + " s · " + frame.observation)
                    }
                }
                if let transcript = video.transcript {
                    Text(text(.transcript)).font(.headline)
                    Text(transcript)
                }
                ForEach(Array(Set(video.gaps ?? [])).sorted(), id: \.self) {
                    Text(xState($0, model.uiLanguage)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func profiles(_ name: String, capability: String, primary: Binding<String>, backup: Binding<String>) -> some View {
        let available = model.config?.modelProfiles.filter {
            $0.partition == "normal" && $0.capabilities.contains(capability)
        } ?? []
        ForEach([false, true], id: \.self) { isBackup in
            Picker(name + " · " + model.text(isBackup ? .backup : .primary), selection: isBackup ? backup : primary) {
                Text(text(.none)).tag("")
                ForEach(available) { Text($0.model).tag($0.id) }
            }
        }
    }

    private func load() async {
        do {
            let data = try await model.request(feature.readOperation)
            let view: SettingsRevision = try BackendRPC.decode(data)
            document = try ProtectedSettings.record(data, revision: view.revision, field: "settings")
            revision = view.revision
            enabled = document["enabled"] as? Bool ?? false
            timezone = document["timezone"] as? String ?? "Asia/Tokyo"
            daily = number("daily_limit")
            if feature == .alerts {
                let feed: XAlertFeed = try BackendRPC.decode(data)
                rules = feed.settings.rules
                occurrences = feed.occurrences
                cooldown = number("cooldown_minutes")
                age = number("max_age_minutes")
                quietStart = document["quiet_start"] as? String ?? ""
                quietEnd = document["quiet_end"] as? String ?? ""
            } else {
                spend = number("daily_model_limit")
                visionHold = number("vision_hold")
                audioHold = number("stt_hold")
                let vision = document["vision_profiles"] as? [String] ?? []
                let speech = document["stt_profiles"] as? [String] ?? []
                visionPrimary = vision.first ?? ""
                visionBackup = vision.dropFirst().first ?? ""
                speechPrimary = speech.first ?? ""
                speechBackup = speech.dropFirst().first ?? ""
                candidates = try BackendRPC.decode(await model.request("x.video.candidates"))
            }
        } catch { failure = XCopy.failed.text(model.uiLanguage) }
    }

    private func number(_ key: String) -> String { (document[key] as? Int).map(String.init) ?? "" }

    private func units(_ value: String) throws -> Int {
        guard let units = boundedUnits(value) else { throw BackendFailure.rejected }
        return units
    }

    private func save() async {
        busy = true
        failure = nil
        defer { busy = false }
        do {
            var next = document
            next["enabled"] = enabled
            next["timezone"] = timezone
            next["daily_limit"] = try units(daily)
            if feature == .alerts {
                next["cooldown_minutes"] = try units(cooldown)
                next["max_age_minutes"] = try units(age)
                next["quiet_start"] = quietStart.isEmpty ? NSNull() : quietStart as Any
                next["quiet_end"] = quietEnd.isEmpty ? NSNull() : quietEnd as Any
                next["rules"] = rules.map(\.fields)
            } else {
                next["daily_model_limit"] = try units(spend)
                next["vision_hold"] = try units(visionHold)
                next["stt_hold"] = try units(audioHold)
                next["vision_profiles"] = [visionPrimary, visionBackup].filter { !$0.isEmpty }
                next["stt_profiles"] = [speechPrimary, speechBackup].filter { !$0.isEmpty }
            }
            _ = try await model.request(feature.saveOperation, fields: ["revision": revision, "settings": next])
            await load()
        } catch { failure = XCopy.failed.text(model.uiLanguage) }
    }

    private func inspect(_ selected: XVideoCandidate) async {
        let request = UUID().uuidString.lowercased()
        videoRequest = request
        video = nil
        busy = true
        failure = nil
        defer { busy = false }
        do {
            video = try BackendRPC.decode(await model.request("x.video.inspect", fields: [
                "request_id": request, "job_id": selected.jobId, "post_id": selected.postId,
            ]))
        } catch { failure = XCopy.failed.text(model.uiLanguage) }
        if let latest: [XVideoCandidate] = try? BackendRPC.decode(await model.request("x.video.candidates")) {
            candidates = latest
        }
    }

    private func inspectStatus(_ request: String) async {
        busy = true
        failure = nil
        defer { busy = false }
        do {
            video = try BackendRPC.decode(await model.request("x.video.status", fields: ["request_id": request]))
        } catch { failure = XCopy.failed.text(model.uiLanguage) }
    }
}
