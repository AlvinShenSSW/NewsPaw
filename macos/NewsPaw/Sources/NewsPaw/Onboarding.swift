import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - Model presets

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

    /// The preset this profile is, only when provider, address and model all match; anything
    /// else (e.g. a custom gateway serving a preset's model id) stays custom with its own values.
    static func matching(provider: String, baseURL: String?, model: String) -> ModelChoice {
        let normalized = baseURL.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        return allCases.first { choice in
            guard let preset = choice.preset else { return false }
            return preset.provider == provider && preset.baseURL == normalized && preset.model == model
        } ?? .custom
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
    /// Step 1: one Bot, token to paired.
    let pairing = BotPairing()
    /// Step 2: model keys and their checks.
    let keys = KeyChecks()
    // Step 3
    var chosen: Set<String> = ["sub_world", "sub_japan"]
    private(set) var sentTrial = false
    /// The model picked on step 2 differs from the saved one; it takes effect only when a key is
    /// saved for it, so Continue waits.
    var modelUnsaved = false

    private var finishing = false
    private var digestFailures: [String: BackendError] = [:]
    /// Why a chosen digest could not turn on (`subscriptions.preview` blockers).
    private(set) var blockers: [String: [String]] = [:]

    var botId: String? { pairing.botId }
    var bot: BotStatus? { pairing.bot }
    var pair: PairingCode? { pairing.pair }
    var pairedAt: Date? { pairing.pairedAt }
    var probes: [String: ProbeState] { keys.probes }

    /// Every step's failure in one place: "bot", a profile id, a digest id or "trial".
    var failures: [String: BackendError] {
        var all = keys.failures.merging(digestFailures) { _, own in own }
        all["bot"] = pairing.failure
        return all
    }

    /// What is in progress: "bot", a profile id or "finish".
    var working: Set<String> {
        var all = keys.working
        if pairing.working { all.insert("bot") }
        if finishing { all.insert("finish") }
        return all
    }

    /// How often pairing and key checks are read back, and how long a key check may take.
    var pollInterval: Duration {
        get { pairing.pollInterval }
        set {
            pairing.pollInterval = newValue
            keys.pollInterval = newValue
        }
    }
    var probeLimit: Duration {
        get { keys.probeLimit }
        set { keys.probeLimit = newValue }
    }

    var botReady: Bool { pairing.paired }
    func keyReady(_ profile: String) -> Bool { probes[profile]?.passed == true }

    /// Picks up where an earlier visit stopped: the first Bot and the key checks already made.
    func start(model: AppModel) async {
        if let first = model.config?.bots?.first?.id { pairing.adopt(first) }
        // A Bot paired on an earlier visit shows as paired, without inventing when.
        await pairing.load(model: model)
        for profile in ["normal_primary", "adult_primary"] {
            await keys.load(profile, model: model)
        }
        for profile in ["normal_primary", "adult_primary"] {
            // A saved key whose check is still running (e.g. the window was reopened right after
            // saving): keep reading until it has an outcome.
            let saved = model.config?.modelProfiles.first { $0.id == profile }?.credentialRef != nil
            if saved, probes[profile]?.settled != true { await keys.follow(profile, model: model) }
        }
        // Checks started on an earlier visit (or on the Connect page) are followed by their own id.
        await keys.resume(model: model)
    }

    // MARK: Step 1

    /// Saves the token, checks it with Telegram and issues a pairing code.
    func connect(token: String, model: AppModel) async { await pairing.connect(token: token, model: model) }

    /// A new pairing code (also after the old one expired).
    func newCode(model: AppModel) async { await pairing.newCode(model: model) }

    nonisolated static func botProblem(_ status: String?) -> String { BotPairing.problem(status) }

    func waitForPairing(model: AppModel, now: @escaping () -> Date = Date.init) async {
        await pairing.waitForPairing(model: model, now: now)
    }

    // MARK: Step 2

    /// Saves a key (and, for the main model, the chosen model); the backend checks a saved key
    /// on its own (R04), and this reads the result back.
    func saveKey(_ key: String, profile: String, choice: ModelChoice?, customURL: String = "", customModel: String = "", model: AppModel) async {
        await keys.save(key, profile: profile, model: model) {
            guard let choice else { return }
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
    }

    /// Reads the key check until it has an outcome.
    func readProbe(_ profile: String, model: AppModel) async { await keys.readProbe(profile, model: model) }

    /// Runs the key check again for the same saved key. An earlier check whose outcome is
    /// unknown (or still running) may have been charged, so it runs again only once confirmed.
    func recheck(_ profile: String, model: AppModel, confirmed: Bool = false) async {
        await keys.recheck(profile, model: model, confirmed: confirmed)
    }

    // MARK: Step 3

    /// Turns on the chosen digests (each brings in its recommended sources and the only Bot)
    /// and, when asked, sends a trial of the first one. Returns whether every chosen digest is on.
    func finish(sendTrial: Bool, model: AppModel) async -> Bool {
        finishing = true
        defer { finishing = false }
        let digests = DigestsData()
        await digests.load(model.client)
        digestFailures["trial"] = nil
        guard let order = model.config?.subscriptions.map(\.id) else {
            digestFailures["trial"] = BackendError(code: "backend_unreachable")
            return false
        }
        var allOn = true
        for id in order where chosen.contains(id) {
            digestFailures[id] = nil
            // The configuration can vanish mid-way (the backend went away during a refresh):
            // that is a failure to report, not a digest that is already on.
            guard let config = model.config else {
                digestFailures[id] = BackendError(code: "backend_unreachable")
                allOn = false
                continue
            }
            guard let subscription = config.subscriptions.first(where: { $0.id == id }), !subscription.enabled else { continue }
            blockers[id] = nil
            if !(await digests.turnOn(subscription, model: model)) {
                digestFailures[id] = digests.failures[id] ?? digests.failures[subscription.categoryId] ?? BackendError(code: "subscription_not_ready")
                blockers[id] = digests.previews[id]?.blockers
                allOn = false
            }
        }
        digestFailures["trial"] = nil
        // The last save's refresh can find the backend gone: a requested trial needs a configuration.
        guard let config = model.config else {
            digestFailures["trial"] = BackendError(code: "backend_unreachable")
            return false
        }
        let ordinary = Set(config.categories.filter { $0.partition == "normal" }.map(\.id))
        if sendTrial, let first = config.subscriptions.first(where: { chosen.contains($0.id) && $0.enabled && ordinary.contains($0.categoryId) }) {
            sentTrial = await model.sendNow(first.id)
            if !sentTrial {
                digestFailures["trial"] = model.lastFailure ?? BackendError(code: "invalid_reply")
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
    @Environment(\.openWindow) private var openWindow
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
                    .keyboardShortcut(.defaultAction).disabled(!data.keyReady("normal_primary") || data.modelUnsaved)
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
        if sendTrial {
            // Show the trial on the overview, reopening the main window if it was closed.
            model.page = .overview
            openWindow(id: "settings")
            NSApp.activate()
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.text(L10n.Onboarding.telegramTitle)).font(.title2.bold())
            HStack(spacing: 4) {
                Text(model.text(L10n.Onboarding.telegramIntro)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link(model.text(L10n.Onboarding.howTo), destination: URL(string: "https://core.telegram.org/bots/features#botfather")!)
            }
            BotConnectForm(model: model, pairing: data.pairing)
            Text(model.text(L10n.Onboarding.moreBots)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Step 2

private struct ModelStep: View {
    let model: AppModel
    let data: OnboardingData

    /// The picked model is the one saved for the main profile.
    private var matchesSaved: Bool {
        guard let profile = model.config?.modelProfiles.first(where: { $0.id == "normal_primary" }) else { return true }
        let saved = ModelChoice.matching(provider: profile.provider, baseURL: profile.baseUrl, model: profile.model)
        guard saved == choice else { return false }
        return choice != .custom || (customURL == (profile.baseUrl ?? "") && customModel == profile.model)
    }
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
                   save: {
                       await data.saveKey(key, profile: "normal_primary", choice: choice, customURL: customURL, customModel: customModel, model: model)
                       data.modelUnsaved = !matchesSaved
                   })
            if data.modelUnsaved {
                Text(model.text(L10n.Onboarding.saveToUse)).font(.caption).foregroundStyle(.orange)
            }
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
        .onChange(of: choice) { data.modelUnsaved = !matchesSaved }
        .onChange(of: customURL) { data.modelUnsaved = !matchesSaved }
        .onChange(of: customModel) { data.modelUnsaved = !matchesSaved }
        .onAppear {
            if let profile = model.config?.modelProfiles.first(where: { $0.id == "normal_primary" }) {
                choice = ModelChoice.matching(provider: profile.provider, baseURL: profile.baseUrl, model: profile.model)
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
    @State private var confirmRecheck = false

    /// A check whose outcome is unknown may already have been charged; checking again asks first
    /// (the same rule as the Connect page, decided by `KeyChecks.needsConfirmation`).
    private func recheck() {
        if data.keys.needsConfirmation(profile) {
            confirmRecheck = true
        } else {
            Task { await data.recheck(profile, model: model) }
        }
    }

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
                // With the key field empty (a key saved earlier), retrying means checking it again.
                FailureNote(model: model, failure: failure) {
                    Task {
                        if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            recheck()
                        } else {
                            await save()
                        }
                    }
                }
            } else if let probe = data.probes[profile], probe.settled {
                if probe.passed {
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 8, height: 8).accessibilityHidden(true)
                        Text(L10n.Onboarding.keyPassed(model.uiLanguage, ["model": probe.reportedModel ?? currentModel]))
                        Button(model.text(L10n.Onboarding.checkAgain)) { Task { await data.recheck(profile, model: model) } }.buttonStyle(.link)
                    }
                    .font(.callout)
                } else {
                    let failure = BackendError(code: probe.errorKind ?? probe.state, domain: "models")
                    FailureNote(model: model, failure: failure) { recheck() }
                    // Whatever the reason's copy offers, a saved key can always be checked again.
                    if FailureCopy.entry(for: failure).action == nil {
                        Button(model.text(L10n.Onboarding.checkAgain)) { recheck() }.buttonStyle(.link).font(.callout)
                    }
                }
            }
        }
        .confirmationDialog(model.text(L10n.Overview.retryModelTitle), isPresented: $confirmRecheck) {
            Button(model.text(L10n.Onboarding.checkAgain)) { Task { await data.recheck(profile, model: model, confirmed: true) } }
            Button(model.text(L10n.Shell.cancel), role: .cancel) {}
        } message: {
            Text(model.text(L10n.Overview.retryModelBody))
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
