import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - Backend shapes

struct PairingCode: Decodable, Equatable {
    let code: String
    let expiresAt: Double
    var expires: Date { Date(timeIntervalSince1970: expiresAt) }
}

/// One capability's check: a `models.status` entry (`state`) or a `models.probe` result (`status`).
struct ProbeState: Decodable, Equatable {
    let state: String
    let errorKind: String?
    let reportedModel: String?

    init(state: String, errorKind: String? = nil, reportedModel: String? = nil) {
        self.state = state
        self.errorKind = errorKind
        self.reportedModel = reportedModel
    }

    private enum Keys: String, CodingKey { case state, status, errorKind, reportedModel }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        state = try values.decodeIfPresent(String.self, forKey: .state) ?? values.decode(String.self, forKey: .status)
        errorKind = try values.decodeIfPresent(String.self, forKey: .errorKind)
        reportedModel = try values.decodeIfPresent(String.self, forKey: .reportedModel)
    }

    /// The check has an outcome for the current key. `stale` is a result for an earlier key
    /// (the new key's check has not finished yet), so it still counts as waiting.
    var settled: Bool { !["pending", "untested", "stale"].contains(state) }
    var passed: Bool { state == "verified" }
}

/// The model presets the first-run window offers (the defaults in `app_config.default_config`).
enum ModelChoice: String, CaseIterable, Identifiable {
    case luna, mimo, custom
    var id: String { rawValue }

    var preset: (provider: String, baseURL: String, model: String)? {
        switch self {
        case .luna: ("openai", "https://api.openai.com/v1", "gpt-6-luna")
        case .mimo: ("mimo", "https://api.xiaomimimo.com/v1", "mimo-v2.6-flash")
        case .custom: nil
        }
    }

    var title: Words {
        switch self {
        case .luna: L10n.Onboarding.luna
        case .mimo: L10n.Onboarding.mimo
        case .custom: L10n.Onboarding.custom
        }
    }
}

// MARK: - State and actions

/// The first-run window (interaction-spec §3): connect a Bot, save a model key, choose digests.
/// Every step can be skipped; whatever is left stays on the overview checklist.
@MainActor @Observable
final class OnboardingData {
    enum Step: Int, CaseIterable { case telegram, model, digests }

    var step: Step = .telegram
    // Step 1
    private(set) var botId: String?
    private(set) var bot: BotStatus?
    private(set) var pair: PairingCode?
    private(set) var pairedAt: Date?
    // Step 2
    private(set) var probes: [String: ProbeState] = [:]
    // Step 3
    var chosen: Set<String> = ["sub_world", "sub_japan"]
    private(set) var sentTrial = false

    private(set) var working: Set<String> = []
    private(set) var failures: [String: BackendError] = [:]
    /// Why a chosen digest could not turn on (`subscriptions.preview` blockers).
    private(set) var blockers: [String: [String]] = [:]

    /// How often pairing and key checks are read back, and how long a key check may take.
    var pollInterval: Duration = .seconds(2)
    var probeLimit: Duration = .seconds(90)

    var botReady: Bool { bot?.paired == true }
    func keyReady(_ profile: String) -> Bool { probes[profile]?.passed == true }

    /// Picks up where an earlier visit stopped: the first Bot and the key checks already made.
    func start(model: AppModel) async {
        if botId == nil, let first = model.config?.bots?.first?.id { botId = first }
        if let botId { bot = try? BackendRPC.decode(await model.client.call(.botsStatus, ["bot_id": botId])) }
        // A Bot paired on an earlier visit shows as paired, without inventing when.
        for profile in ["normal_primary", "adult_primary"] {
            if let states: [String: ProbeState] = try? BackendRPC.decode(await model.client.call(.modelsStatus, ["profile_id": profile])) {
                probes[profile] = states["text"]
            }
        }
    }

    // MARK: Step 1

    /// Saves the token, checks it with Telegram and issues a pairing code.
    func connect(token: String, model: AppModel) async {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !working.contains("bot") else { return }
        working.insert("bot")
        defer { working.remove("bot") }
        failures["bot"] = nil
        pair = nil
        do {
            let id = try await ensureBot(model: model)
            try await setCredential(kind: "bots", id: id, value: token, model: model)
            let current: BotStatus = try BackendRPC.decode(await model.client.call(.botsStatus, ["bot_id": id]))
            bot = try BackendRPC.decode(await model.client.call(.botsVerify, ["bot_id": id, "generation": current.generation ?? 0]))
            guard bot?.verified == true else {
                throw BackendError(code: Self.botProblem(bot?.status), domain: "bots")
            }
            try await issueCode(model: model)
        } catch {
            failures["bot"] = error as? BackendError ?? BackendError(code: error is SocketFailure ? "backend_unreachable" : "invalid_reply")
        }
        await model.refresh()
    }

    /// A new pairing code (also after the old one expired).
    func newCode(model: AppModel) async {
        working.insert("bot")
        defer { working.remove("bot") }
        failures["bot"] = nil
        do { try await issueCode(model: model) } catch {
            failures["bot"] = error as? BackendError ?? BackendError(code: "invalid_reply")
        }
    }

    private func issueCode(model: AppModel) async throws {
        guard let botId else { return }
        pair = try BackendRPC.decode(await model.client.call(.botsPairCode, ["bot_id": botId, "generation": bot?.generation ?? 0]))
        bot = try BackendRPC.decode(await model.client.call(.botsStatus, ["bot_id": botId]))
    }

    /// The Bot's own status when it names a problem (`bots.verify` records the error kind
    /// there), else a generic "not confirmed".
    nonisolated static func botProblem(_ status: String?) -> String {
        guard let status, FailureCopy.table[status] != nil else { return "bot_not_verified" }
        return status
    }

    /// Reads the Bot until the owner has sent the pairing code (stops when paired, when the
    /// code expires, when the backend ends pairing, or when the task is cancelled).
    func waitForPairing(model: AppModel, now: @escaping () -> Date = Date.init) async {
        guard let botId, pair != nil else { return }
        while !Task.isCancelled, !botReady, let pair, now() < pair.expires {
            try? await Task.sleep(for: pollInterval)
            guard !Task.isCancelled else { return }
            if let status: BotStatus = try? BackendRPC.decode(await model.client.call(.botsStatus, ["bot_id": botId])) {
                bot = status
                // Too many wrong codes, or the token stopped working: waiting cannot succeed.
                if status.status == "pair_attempts_exhausted" || !status.verified {
                    failures["bot"] = BackendError(code: status.verified ? "pair_attempts_exhausted" : Self.botProblem(status.status), domain: "bots")
                    self.pair = nil
                    return
                }
            }
        }
        if botReady {
            pairedAt = pairedAt ?? now()
            pair = nil
            await model.refresh()
        }
    }

    /// The window's Bot: the first configured one, else a new entry without a token.
    private func ensureBot(model: AppModel) async throws -> String {
        if let botId { return botId }
        let id = "bot_" + String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12))
        let editor = EditorState(client: model.client)
        let saved = await editor.apply { document in
            var document = document
            var bots = document["bots"] as? [[String: Any]] ?? []
            bots.append([
                "id": id, "name": "Telegram", "credential_ref": NSNull(), "telegram_id": NSNull(), "chat_id": NSNull(),
                "verified": false, "paired": false, "adult_allowed": false,
            ])
            document["bots"] = bots
            return document
        }
        guard saved else { throw editor.failure ?? BackendError(code: "invalid_reply") }
        botId = id
        return id
    }

    private func setCredential(kind: String, id: String, value: String, model: AppModel) async throws {
        for attempt in 0..<2 {
            let revision = try await model.client.configDocument().revision
            do {
                _ = try await model.client.call(.credentialsSet, ["kind": kind, "id": id, "value": value, "revision": revision])
                return
            } catch let error as BackendError where error.isConflict && attempt == 0 {
                continue
            }
        }
    }

    // MARK: Step 2

    /// Saves a key (and, for the main model, the chosen model); the backend checks a saved key
    /// on its own (R04), and this reads the result back.
    func saveKey(_ key: String, profile: String, choice: ModelChoice?, customURL: String = "", customModel: String = "", model: AppModel) async {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !working.contains(profile) else { return }
        working.insert(profile)
        defer { working.remove(profile) }
        failures[profile] = nil
        probes[profile] = nil
        do {
            if let choice {
                let preset = choice.preset ?? ("openai", customURL.trimmingCharacters(in: .whitespaces), customModel.trimmingCharacters(in: .whitespaces))
                let editor = EditorState(client: model.client)
                let saved = await editor.apply { document in
                    var document = document
                    document["model_profiles"] = (document["model_profiles"] as? [[String: Any]] ?? []).map { entry in
                        guard entry["id"] as? String == profile else { return entry }
                        var entry = entry
                        entry["provider"] = preset.0
                        entry["base_url"] = preset.1
                        entry["model"] = preset.2
                        return entry
                    }
                    return document
                }
                guard saved else { throw editor.failure ?? BackendError(code: "invalid_reply") }
            }
            try await setCredential(kind: "model_profiles", id: profile, value: key, model: model)
            await readProbe(profile, model: model)
        } catch {
            failures[profile] = error as? BackendError ?? BackendError(code: error is SocketFailure ? "backend_unreachable" : "invalid_reply")
        }
        await model.refresh()
    }

    /// Reads the key check until it has an outcome.
    func readProbe(_ profile: String, model: AppModel) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: probeLimit)
        while !Task.isCancelled, clock.now < deadline {
            if let states: [String: ProbeState] = try? BackendRPC.decode(await model.client.call(.modelsStatus, ["profile_id": profile])),
               let text = states["text"] {
                probes[profile] = text
                if text.settled { return }
            }
            try? await Task.sleep(for: pollInterval)
        }
        if probes[profile]?.settled != true { failures[profile] = BackendError(code: "probe_pending", domain: "models") }
    }

    /// Runs the key check again for the same saved key.
    func recheck(_ profile: String, model: AppModel) async {
        working.insert(profile)
        defer { working.remove(profile) }
        failures[profile] = nil
        let probe = "probe_" + String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16))
        do {
            // `models.probe` runs the check and returns its finished result.
            probes[profile] = try BackendRPC.decode(await model.client.call(.modelsProbe, [
                "probe_id": probe, "profile_id": profile, "capability": "text", "hold_units": 10_000,
            ]))
        } catch {
            failures[profile] = error as? BackendError ?? BackendError(code: "invalid_reply")
        }
    }

    // MARK: Step 3

    /// Turns on the chosen digests (each brings in its recommended sources and the only Bot)
    /// and, when asked, sends a trial of the first one. Returns whether every chosen digest is on.
    func finish(sendTrial: Bool, model: AppModel) async -> Bool {
        working.insert("finish")
        defer { working.remove("finish") }
        let digests = DigestsData()
        await digests.load(model.client)
        let order = model.config?.subscriptions.map(\.id) ?? []
        var allOn = true
        for id in order where chosen.contains(id) {
            failures[id] = nil
            guard let subscription = model.config?.subscriptions.first(where: { $0.id == id }), !subscription.enabled else { continue }
            blockers[id] = nil
            if !(await digests.turnOn(subscription, model: model)) {
                failures[id] = digests.failures[id] ?? digests.failures[subscription.categoryId] ?? BackendError(code: "subscription_not_ready")
                blockers[id] = digests.previews[id]?.blockers
                allOn = false
            }
        }
        failures["trial"] = nil
        let ordinary = Set(model.config?.categories.filter { $0.partition == "normal" }.map(\.id) ?? [])
        if sendTrial, let first = model.config?.subscriptions.first(where: { chosen.contains($0.id) && $0.enabled && ordinary.contains($0.categoryId) }) {
            sentTrial = await model.sendNow(first.id)
            if !sentTrial {
                failures["trial"] = model.lastFailure ?? BackendError(code: "invalid_reply")
                return false
            }
        }
        return allOn
    }
}

extension AppModel {
    private static let onboardingKey = "onboardingSeen"

    /// The first-run window has been finished or skipped once; it no longer opens by itself.
    var onboardingSeen: Bool {
        get { defaultsValue(Self.onboardingKey) }
        set { setDefaultsValue(newValue, Self.onboardingKey) }
    }

    /// Opens by itself on a launch where setup is incomplete and the window was never closed.
    var shouldOfferOnboarding: Bool {
        guard let readiness, connection == .connected else { return false }
        return !readiness.complete && !onboardingSeen
    }
}

// MARK: - Window

struct OnboardingWindow: View {
    @Environment(\.dismissWindow) private var dismissWindow
    let model: AppModel
    @State private var data: OnboardingData

    init(model: AppModel, step: OnboardingData.Step = .telegram) {
        self.model = model
        let data = OnboardingData()
        data.step = step
        _data = State(initialValue: data)
    }

    var body: some View {
        VStack(spacing: 0) {
            StepBar(model: model, step: data.step, done: [data.botReady, data.keyReady("normal_primary"), false])
                .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 14)
            Divider()
            ScrollView {
                Group {
                    switch data.step {
                    case .telegram: TelegramStep(model: model, data: data)
                    case .model: ModelStep(model: model, data: data)
                    case .digests: DigestStep(model: model, data: data)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
            }
            Divider()
            footer.padding(.horizontal, 28).padding(.vertical, 14)
        }
        .frame(width: 760, height: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await data.start(model: model) }
        // Closing the window any way (title bar, ⌘W) counts as seen; it does not come back by itself.
        .onDisappear { model.onboardingSeen = true }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if data.step != .digests {
                Button(model.text(L10n.Onboarding.skip)) { advance() }.buttonStyle(.link)
            } else {
                Button(model.text(L10n.Onboarding.finishLater)) { close() }.buttonStyle(.link)
            }
            Spacer()
            if data.step != .telegram {
                Button(model.text(L10n.Onboarding.back)) {
                    data.step = OnboardingData.Step(rawValue: data.step.rawValue - 1) ?? .telegram
                }
            }
            switch data.step {
            case .telegram:
                Button(model.text(L10n.Onboarding.next)) { advance() }
                    .keyboardShortcut(.defaultAction).disabled(!data.botReady)
            case .model:
                Button(model.text(L10n.Onboarding.next)) { advance() }
                    .keyboardShortcut(.defaultAction).disabled(!data.keyReady("normal_primary"))
            case .digests:
                // Without a usable Bot nothing can turn on; the step says so and only closing is offered.
                let blocked = data.chosen.isEmpty || data.working.contains("finish") || model.usableBots(for: "world").isEmpty
                if data.working.contains("finish") { ProgressView().controlSize(.small) }
                Button(model.text(L10n.Onboarding.finishQuietly)) { Task { await finish(sendTrial: false) } }
                    .disabled(blocked)
                Button(model.text(L10n.Onboarding.finishAndSend)) { Task { await finish(sendTrial: true) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(blocked)
            }
        }
    }

    private func advance() {
        if let next = OnboardingData.Step(rawValue: data.step.rawValue + 1) { data.step = next } else { close() }
    }

    private func finish(sendTrial: Bool) async {
        // A digest that could not turn on stays on screen with its reason.
        guard await data.finish(sendTrial: sendTrial, model: model) else { return }
        if sendTrial { model.page = .overview }
        close()
    }

    private func close() {
        model.onboardingSeen = true
        dismissWindow(id: "onboarding")
    }
}

private struct StepBar: View {
    let model: AppModel
    let step: OnboardingData.Step
    let done: [Bool]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(OnboardingData.Step.allCases, id: \.self) { item in
                let finished = done[item.rawValue] && item != step
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(item == step ? Color.accentColor : finished ? Color.green : Color.secondary.opacity(0.25))
                        if finished {
                            Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white)
                        } else {
                            Text(String(item.rawValue + 1)).font(.caption.bold()).foregroundStyle(item == step ? .white : .secondary)
                        }
                    }
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                    Text(model.text(title(item))).fontWeight(item == step ? .semibold : .regular)
                        .foregroundStyle(item == step ? .primary : .secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(model.text(item == step ? L10n.Onboarding.current : finished ? L10n.Onboarding.stepDone : L10n.Onboarding.stepPending))
                if item != .digests {
                    Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1).frame(maxWidth: 60)
                }
            }
            Spacer()
        }
    }

    private func title(_ item: OnboardingData.Step) -> Words {
        switch item {
        case .telegram: L10n.Onboarding.telegramTitle
        case .model: L10n.Onboarding.modelTitle
        case .digests: L10n.Onboarding.digestsTitle
        }
    }
}

// MARK: - Step 1

private struct TelegramStep: View {
    let model: AppModel
    let data: OnboardingData
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.text(L10n.Onboarding.telegramTitle)).font(.title2.bold())
            HStack(spacing: 4) {
                Text(model.text(L10n.Onboarding.telegramIntro)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link(model.text(L10n.Onboarding.howTo), destination: URL(string: "https://core.telegram.org/bots/features#botfather")!)
            }
            if data.bot?.verified != true || data.failures["bot"] != nil {
                HStack(spacing: 8) {
                    SecureField(model.text(L10n.Onboarding.tokenPlaceholder), text: $token)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await data.connect(token: token, model: model) } }
                        .onChange(of: token) { old, new in
                            // A paste (a jump of many characters) checks right away.
                            if new.count - old.count > 20 { Task { await data.connect(token: new, model: model) } }
                        }
                    Button(model.text(L10n.Onboarding.check)) { Task { await data.connect(token: token, model: model) } }
                        .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || data.working.contains("bot"))
                }
            }
            if data.working.contains("bot") {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(model.text(L10n.Onboarding.checking)).foregroundStyle(.secondary)
                }
            }
            if let failure = data.failures["bot"] {
                FailureNote(model: model, failure: failure) {
                    Task {
                        if data.bot?.verified == true { await data.newCode(model: model) } else { await data.connect(token: token, model: model) }
                    }
                }
            }
            if let bot = data.bot, bot.verified {
                Label(L10n.Onboarding.verified(model.uiLanguage, ["name": bot.username.map { "@" + $0 } ?? bot.name]), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if data.botReady {
                pairedBlock
            } else if let pair = data.pair {
                PairBlock(model: model, data: data, pair: pair, username: data.bot?.username)
            } else if data.bot?.verified == true, data.failures["bot"] == nil, !data.working.contains("bot") {
                // Verified on an earlier visit but never paired: a fresh code continues from here.
                HStack(spacing: 10) {
                    Text(model.text(L10n.Onboarding.notPaired)).foregroundStyle(.secondary)
                    Button(model.text(L10n.Onboarding.newCode)) { Task { await data.newCode(model: model) } }
                        .keyboardShortcut(.defaultAction)
                }
            }
            Text(model.text(L10n.Onboarding.moreBots)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var pairedBlock: some View {
        Label(data.pairedAt.map { L10n.Onboarding.paired(model.uiLanguage, ["time": $0.formatted(date: .omitted, time: .shortened)]) }
                ?? model.text(L10n.Onboarding.pairedEarlier),
              systemImage: "checkmark.seal.fill")
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(.green)
    }
}

private struct PairBlock: View {
    let model: AppModel
    let data: OnboardingData
    let pair: PairingCode
    let username: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = Int(pair.expires.timeIntervalSince(context.date))
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.Onboarding.sendThis(model.uiLanguage, ["name": username.map { "@" + $0 } ?? "Bot"]))
                HStack(spacing: 10) {
                    Text("/pair " + pair.code)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Button(model.text(L10n.Onboarding.copy)) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("/pair " + pair.code, forType: .string)
                    }
                }
                if left > 0 {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L10n.Onboarding.expiresIn(model.uiLanguage, ["minutes": String(left / 60), "seconds": String(left % 60)]))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                } else {
                    HStack {
                        Text(model.text(L10n.Onboarding.expired)).foregroundStyle(.orange)
                        Button(model.text(L10n.Onboarding.newCode)) { Task { await data.newCode(model: model) } }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        .task(id: pair) { await data.waitForPairing(model: model) }
    }
}

// MARK: - Step 2

private struct ModelStep: View {
    let model: AppModel
    let data: OnboardingData
    @State private var choice: ModelChoice = .luna
    @State private var key = ""
    @State private var customURL = ""
    @State private var customModel = ""
    @State private var adultKey = ""
    @State private var backupKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.text(L10n.Onboarding.modelTitle)).font(.title2.bold())
            Text(model.text(L10n.Onboarding.modelIntro)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker(model.text(L10n.Onboarding.whichModel), selection: $choice) {
                ForEach(ModelChoice.allCases) { Text(model.text($0.title)).tag($0) }
            }
            .fixedSize()
            if choice == .custom {
                TextField(model.text(L10n.Onboarding.customURL), text: $customURL).textFieldStyle(.roundedBorder)
                TextField(model.text(L10n.Onboarding.customModel), text: $customModel).textFieldStyle(.roundedBorder)
            }
            KeyRow(model: model, data: data, profile: "normal_primary", key: $key,
                   save: { await data.saveKey(key, profile: "normal_primary", choice: choice, customURL: customURL, customModel: customModel, model: model) })
            DisclosureGroup(model.text(L10n.Onboarding.adultOptional)) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.text(L10n.Onboarding.adultNote)).font(.caption).foregroundStyle(.secondary)
                    KeyRow(model: model, data: data, profile: "adult_primary", key: $adultKey,
                           save: { await data.saveKey(adultKey, profile: "adult_primary", choice: nil, model: model) })
                }
                .padding(.top, 6)
            }
            DisclosureGroup(model.text(L10n.Onboarding.advanced)) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.text(L10n.Onboarding.backupNote)).font(.caption).foregroundStyle(.secondary)
                    KeyRow(model: model, data: data, profile: "normal_backup", key: $backupKey,
                           save: { await data.saveKey(backupKey, profile: "normal_backup", choice: nil, model: model) })
                }
                .padding(.top, 6)
            }
            Text(model.text(L10n.Onboarding.costNote)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            if let profile = model.config?.modelProfiles.first(where: { $0.id == "normal_primary" }) {
                choice = ModelChoice.allCases.first { $0.preset?.model == profile.model } ?? .custom
                if choice == .custom {
                    customURL = profile.baseUrl ?? ""
                    customModel = profile.model
                }
            }
        }
    }
}

private struct KeyRow: View {
    let model: AppModel
    let data: OnboardingData
    let profile: String
    @Binding var key: String
    let save: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SecureField(model.text(L10n.Onboarding.keyPlaceholder), text: $key)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await save() } }
                Button(model.text(L10n.Onboarding.paste)) {
                    if let value = NSPasteboard.general.string(forType: .string) {
                        key = value
                        Task { await save() }
                    }
                }
                Button(model.text(L10n.Onboarding.saveAndCheck)) { Task { await save() } }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || data.working.contains(profile))
            }
            if data.working.contains(profile) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(model.text(L10n.Onboarding.checkingKey)).foregroundStyle(.secondary)
                }
            } else if let failure = data.failures[profile] {
                FailureNote(model: model, failure: failure) { Task { await save() } }
            } else if let probe = data.probes[profile], probe.settled {
                if probe.passed {
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 8, height: 8).accessibilityHidden(true)
                        Text(L10n.Onboarding.keyPassed(model.uiLanguage, ["model": probe.reportedModel ?? currentModel]))
                        Button(model.text(L10n.Onboarding.checkAgain)) { Task { await data.recheck(profile, model: model) } }.buttonStyle(.link)
                    }
                    .font(.callout)
                } else {
                    FailureNote(model: model, failure: BackendError(code: probe.errorKind ?? probe.state, domain: "models")) {
                        Task { await data.recheck(profile, model: model) }
                    }
                }
            }
        }
    }

    private var currentModel: String {
        model.config?.modelProfiles.first { $0.id == profile }?.model ?? ""
    }
}

// MARK: - Step 3

private struct DigestStep: View {
    let model: AppModel
    let data: OnboardingData

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.text(L10n.Onboarding.digestsTitle)).font(.title2.bold())
            Text(sendLine).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(model.config?.subscriptions ?? []) { subscription in
                    row(subscription)
                    Divider()
                }
            }
            if data.sentTrial {
                Label(model.text(L10n.Digests.sent), systemImage: "paperplane.fill").foregroundStyle(.green)
            }
            if let failure = data.failures["trial"] {
                FailureNote(model: model, failure: failure)
            }
        }
    }

    private var sendLine: String {
        let usable = model.usableBots(for: "world")
        if let phrase = model.botsPhrase(Array(usable.prefix(1))), usable.count == 1 {
            return L10n.Onboarding.sendTo(model.uiLanguage, ["bot": phrase])
        }
        return model.text(usable.isEmpty ? L10n.Digests.needsBot : L10n.Onboarding.chooseLater)
    }

    private func row(_ subscription: AppConfig.Subscription) -> some View {
        let adult = model.config?.categories.first { $0.id == subscription.categoryId }?.partition == "adult"
        let blocked = adult && (!model.adultModelReady || model.usableBots(for: subscription.categoryId).isEmpty)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                CategorySymbol(id: subscription.categoryId)
                    .foregroundStyle(blocked ? Color.secondary : adult ? Color.purple : Color.accentColor)
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.digestTitle(subscription.id))
                    Text(blocked ? model.text(L10n.Digests.needsAdultSetup)
                         : L10n.Digests.everyDay(model.uiLanguage, ["times": subscription.times.joined(separator: "、")]))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(model.digestTitle(subscription.id), isOn: Binding(
                    get: { subscription.enabled || data.chosen.contains(subscription.id) },
                    set: { on in
                        if on { data.chosen.insert(subscription.id) } else { data.chosen.remove(subscription.id) }
                    }
                ))
                .toggleStyle(.switch).labelsHidden()
                .disabled(blocked || subscription.enabled)
            }
            if let failure = data.failures[subscription.id] {
                Text(FailureCopy.message(for: failure, model.uiLanguage)).font(.caption).foregroundStyle(.red)
                ForEach(data.blockers[subscription.id] ?? [], id: \.self) { code in
                    Text("• " + FailureCopy.message(for: BackendError(code: code, domain: "subscriptions"), model.uiLanguage))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 7)
    }
}
