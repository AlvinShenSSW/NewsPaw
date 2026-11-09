import AppKit
import SwiftUI

// MARK: - Status vocabulary

/// A status dot always comes with its words (interaction-spec §2.7).
struct StatusDot: View {
    let color: Color
    let text: String
    var busy = false

    var body: some View {
        HStack(spacing: 5) {
            if busy {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            }
            Text(text).font(.callout)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// What a Bot's group shows as its state (`bots.status`, interaction-spec §6.1).
enum BotState: Equatable {
    case unverified, verifying, waiting, expired, paired, paused, unpaired
    case problem(String)

    init(_ bot: BotStatus) {
        let status = bot.status ?? ""
        // A pause outlives unpairing; such a Bot needs a new pairing (which clears the pause).
        if bot.paused, bot.paired {
            self = .paused
        } else if status == "verifying" {
            self = .verifying
        } else if !bot.verified {
            self = ["", "unverified"].contains(status) ? .unverified : .problem(BotPairing.problem(status))
        } else if bot.paired {
            self = .paired
        } else {
            switch status {
            case "unpaired", "paused": self = .unpaired
            case "pair_expired": self = .expired
            case "pair_attempts_exhausted": self = .problem(status)
            default: self = .waiting
            }
        }
    }

    var color: Color {
        switch self {
        case .paired: .green
        case .waiting: .blue
        case .expired, .unpaired: .orange
        case .problem: .red
        case .unverified, .verifying, .paused: .gray
        }
    }

    var title: Words {
        switch self {
        case .unverified: L10n.Connect.statusUnverified
        case .verifying: L10n.Onboarding.checking
        case .waiting, .expired: L10n.Connect.statusWaiting
        case .paired: L10n.Connect.statusPaired
        case .paused: L10n.Connect.statusPaused
        case .unpaired: L10n.Connect.statusUnpaired
        case .problem: L10n.Connect.statusProblem
        }
    }
}

/// What the line under a Bot shows for its last test message.
enum TestDisplay: Equatable {
    case none, sent, sending, unknown, stillUnknown, notSent

    static func of(_ test: TestSend?, stillUnknown: Bool) -> TestDisplay {
        switch test?.state {
        case "confirmed": .sent
        case "outcome_unknown": stillUnknown ? .stillUnknown : .unknown
        case "inflight": .sending
        case "not_started": .notSent
        default: .none
        }
    }
}

/// Which pause / resume items a Bot's menu offers: only a paired Bot can be paused or resumed
/// (`registry.action` refuses to resume one that is not paired).
enum BotMenu {
    static func canPause(_ bot: BotStatus) -> Bool { bot.paired && !bot.paused }
    static func canResume(_ bot: BotStatus) -> Bool { bot.paired && bot.paused }
}

/// What a model row shows (interaction-spec §6.2 table), from the key, its text check and
/// the profile's cooldown.
enum KeyStatus: Equatable {
    case missing, checking, untested, verified
    case rejected(String)
    case unavailable(String)
    case unknown(String)
    case cooldown(Date, Int)
    case budget
    case uncheckable
    case failed(String)
    case keychain(String)

    enum Action: Equatable { case enterKey, reenterKey, recheck, confirmRecheck, none }

    /// - Parameters:
    ///   - credential: `available`, `missing` or a Keychain error for the stored reference; nil without one.
    static func of(credential: String?, probe: ProbeState?, health: ModelHealth?, working: Bool, now: Date = Date()) -> KeyStatus {
        // A first key being saved has no reference yet; it is already being checked.
        if working { return .checking }
        guard let credential, credential != "missing" else { return .missing }
        guard credential == "available" else { return .keychain(credential) }
        guard let probe else { return .untested }
        switch probe.state {
        case "pending": return .checking
        case "untested", "stale", "cancelled": return .untested
        case "verified":
            // Repeated failures in delivery pause the model even though its key works.
            if let health, health.failures > 0, let until = health.cooldownUntil.flatMap(OverviewData.date), until > now,
               health.checkedAt >= (probe.checkedAt ?? "") {
                return .cooldown(until, health.failures)
            }
            return .verified
        case "outcome_unknown": return .unknown(probe.errorKind ?? "outcome_unknown")
        case "budget_blocked": return .budget
        case "probe_unavailable": return .uncheckable
        default:
            let kind = probe.errorKind ?? probe.state
            switch kind {
            case "authentication_failed", "permission_denied", "invalid_credential": return .rejected(kind)
            case "rate_limited", "quota_exhausted", "connection_failed", "transport_rejected", "provider_failed": return .unavailable(kind)
            default: return .failed(kind)
            }
        }
    }

    var color: Color {
        switch self {
        case .verified: .green
        case .rejected, .failed, .keychain: .red
        case .unavailable, .unknown, .cooldown, .budget: .orange
        case .missing, .checking, .untested, .uncheckable: .gray
        }
    }

    func title(_ language: AppLanguage) -> String {
        switch self {
        case .missing: L10n.Connect.statusNoKey(language)
        case .checking: L10n.Onboarding.checkingKey(language)
        case .untested: L10n.Connect.statusUntested(language)
        case .verified: L10n.Connect.statusUsable(language)
        case .rejected: L10n.Connect.statusKeyInvalid(language)
        case .unavailable: L10n.Connect.statusUnavailable(language)
        case .unknown: L10n.Overview.unknown(language)
        case let .cooldown(until, _): L10n.Connect.statusCooldown(language, ["time": Stamp.clock(until)])
        case .budget: L10n.Connect.statusBudget(language)
        case .uncheckable: L10n.Connect.statusUncheckable(language)
        case .failed: L10n.Connect.statusFailed(language)
        case .keychain: L10n.Connect.statusKeychain(language)
        }
    }

    /// What happened and what to do, naming the provider and its HTTP status where the check had one.
    func note(_ language: AppLanguage, provider: String) -> String? {
        let values = ["provider": provider]
        switch self {
        case .rejected("authentication_failed"): return L10n.Connect.rejected401(language, values)
        case .rejected("permission_denied"): return L10n.Connect.rejected403(language, values)
        case .rejected: return L10n.Connect.rejectedFormat(language)
        case .unavailable("rate_limited"): return L10n.Connect.rateLimited(language, values)
        case .unavailable("quota_exhausted"): return L10n.Connect.quotaExhausted(language, values)
        case .unavailable("provider_failed"): return L10n.Connect.providerError(language, values)
        case .unavailable: return L10n.Connect.unreachable(language, values)
        case .unknown("outcome_unknown"): return L10n.Connect.noReply(language, values)
        case .unknown: return L10n.Connect.interrupted(language)
        case let .cooldown(until, failures):
            return L10n.Connect.cooldownNote(language, ["count": String(failures), "time": Stamp.clock(until)])
        case .budget: return FailureCopy.message(for: BackendError(code: "budget_blocked", domain: "models"), language)
        case .uncheckable: return FailureCopy.message(for: BackendError(code: "probe_unavailable", domain: "models"), language)
        case let .failed(code), let .keychain(code): return FailureCopy.message(for: BackendError(code: code, domain: "models"), language)
        case .missing, .checking, .untested, .verified: return nil
        }
    }

    var action: Action {
        switch self {
        case .missing: .enterKey
        case .rejected, .keychain: .reenterKey
        case .unavailable, .untested, .failed: .recheck
        case .unknown: .confirmRecheck
        case .checking, .verified, .cooldown, .budget, .uncheckable: .none
        }
    }
}

/// How a model and its provider are named on screen.
enum ModelNames {
    static func model(_ id: String) -> String {
        [
            "gpt-6-luna": "GPT-6 Luna", "mimo-v2.6-flash": "MiMo Flash", "deepseek-flash": "DeepSeek Flash", "grok-4.3": "Grok 4.3",
        ][id] ?? id
    }

    static func provider(_ id: String, _ language: AppLanguage) -> String {
        switch id {
        case "openai": "OpenAI"
        case "mimo": L10n.Connect.xiaomi(language)
        case "deepseek": "DeepSeek"
        case "grok": "xAI"
        default: id
        }
    }

    /// Image generation and transcription call OpenAI's own API (`supported_image_profile`,
    /// `supported_stt_profile`); other addresses cannot do them.
    static func openAIOfficial(_ profile: AppConfig.Profile) -> Bool {
        profile.partition == "normal" && profile.provider == "openai"
            && (profile.baseUrl ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "https://api.openai.com/v1"
    }
}

// MARK: - Page

/// Bots, models, spending and the X connection (interaction-spec §6).
struct ConnectPage: View {
    let model: AppModel
    @State private var data: ConnectData

    init(model: AppModel, adding: Bool = false) {
        self.model = model
        let data = ConnectData()
        if adding { data.startAdding() }
        _data = State(initialValue: data)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(model.text(L10n.Connect.intro)).font(.callout).foregroundStyle(.secondary)
            if let failure = data.failures["load"] {
                FailureNote(model: model, failure: failure) { Task { await data.load(model: model) } }
            }
            BotsSection(model: model, data: data)
            ModelsSection(model: model, data: data)
            SpendingSection(model: model, data: data)
            XSection(model: model, data: data)
        }
        .task(id: model.configRevision) { await data.load(model: model) }
        .task {
            // Checks, cooldowns and spending change without a configuration change.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await data.load(model: model)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    data.startAdding()
                } label: {
                    Label(model.text(L10n.Connect.addBot), systemImage: "plus")
                }
                .help(model.text(L10n.Connect.addBot))
                .disabled(data.adding != nil)
            }
        }
    }
}

private struct SectionTitle: View {
    let title: String
    var note: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.headline)
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Bots (§6.1)

private struct BotsSection: View {
    let model: AppModel
    let data: ConnectData

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: model.text(L10n.Connect.botsTitle))
            if let adding = data.adding {
                AddBotForm(model: model, data: data, pairing: adding)
            }
            let listed = model.bots.filter { $0.id != data.adding?.botId }
            if listed.isEmpty, data.adding == nil {
                HStack(spacing: 10) {
                    Text(model.text(L10n.Connect.noBots)).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.text(L10n.Connect.addBot)) { data.startAdding() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(12)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            ForEach(listed) { bot in
                BotGroup(model: model, data: data, bot: bot)
            }
        }
    }
}

/// "＋ Add Bot": token → check → pairing code, inline at the top (no sheet).
private struct AddBotForm: View {
    let model: AppModel
    let data: ConnectData
    let pairing: BotPairing

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(model.text(L10n.Connect.addBot)).font(.headline)
                    Spacer()
                    Button(model.text(L10n.Shell.cancel)) { Task { await data.cancelAdding(model: model) } }
                        .keyboardShortcut(.cancelAction)
                }
                HStack(spacing: 4) {
                    Text(model.text(L10n.Onboarding.telegramIntro)).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link(model.text(L10n.Onboarding.howTo), destination: URL(string: "https://core.telegram.org/bots/features#botfather")!)
                        .font(.callout)
                }
                BotConnectForm(model: model, pairing: pairing)
            }
            .padding(6)
        }
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 1) }
        .onChange(of: pairing.paired) { _, paired in
            if paired { data.finishAdding() }
        }
    }
}

private struct BotGroup: View {
    let model: AppModel
    let data: ConnectData
    let bot: BotStatus
    @State private var renaming = false
    @State private var name = ""
    @State private var token = ""
    @State private var confirmUnpair = false
    @State private var confirmDelete = false
    @State private var adultOff: [String]?

    private var configured: AppConfig.ConfiguredBot? { model.config?.bots?.first { $0.id == bot.id } }
    private var adultAllowed: Bool { configured?.adultAllowed ?? false }
    private var pairing: BotPairing? { data.pairing(bot.id) }
    /// While a code is out or a check runs, the page's own reads are newer than the 3-second
    /// poll; otherwise the poll is (a Telegram command may have changed the Bot meanwhile).
    private var current: BotStatus {
        if let pairing, pairing.pair != nil || pairing.working, let read = pairing.bot, read.id == bot.id { return read }
        return bot
    }
    private var state: BotState { BotState(current) }
    private var displayName: String { current.username.map { "@" + $0 } ?? bot.name }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.bottom, 6)
                VStack(alignment: .leading, spacing: 8) {
                    failures
                    testLine
                    pairingArea
                    tokenField
                }
                Divider().padding(.vertical, 8)
                adultRow
            }
            .padding(4)
        }
        .overlay {
            if [.waiting, .expired].contains(state) { RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.6), lineWidth: 1) }
        }
        .confirmationDialog(L10n.Connect.unpairTitle(model.uiLanguage, ["name": displayName]), isPresented: $confirmUnpair) {
            Button(model.text(L10n.Connect.unpairButton), role: .destructive) { Task { await data.act(bot.id, "unbind", model: model) } }
            Button(model.text(L10n.Shell.cancel), role: .cancel) {}
        } message: {
            Text(model.text(L10n.Connect.unpairBody))
        }
        .confirmationDialog(L10n.Connect.deleteTitle(model.uiLanguage, ["name": displayName]), isPresented: $confirmDelete) {
            Button(model.text(L10n.Connect.deleteButton), role: .destructive) { Task { await data.delete(bot.id, model: model) } }
            Button(model.text(L10n.Shell.cancel), role: .cancel) {}
        } message: {
            Text(deleteImpact)
        }
        .confirmationDialog(L10n.Connect.adultOffTitle(model.uiLanguage, ["name": displayName]),
                            isPresented: Binding(get: { adultOff != nil }, set: { if !$0 { adultOff = nil } })) {
            Button(model.text(L10n.Connect.adultOffButton), role: .destructive) { Task { await data.setAdult(bot.id, false, model: model) } }
            Button(model.text(L10n.Shell.cancel), role: .cancel) {}
        } message: {
            Text(L10n.Connect.adultOffBody(model.uiLanguage, ["names": (adultOff ?? []).map(model.digestTitle).joined(separator: "、")]))
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Text(String((current.username ?? bot.name).prefix(1)).uppercased())
                .font(.system(size: 13, weight: .bold))
                .frame(width: 30, height: 30)
                .background((adultAllowed ? Color.purple : Color.accentColor).opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(adultAllowed ? Color.purple : Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                titleLine
                Text(receivesLine).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            StatusDot(color: state.color, text: statusText, busy: state == .verifying || data.isBusy("bot." + bot.id))
            if state == .paired {
                if data.isBusy("test." + bot.id) {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text(model.text(L10n.Connect.sending)).foregroundStyle(.secondary)
                    }
                } else {
                    Button(model.text(L10n.Connect.sendTest)) { Task { await data.sendTest(bot.id, model: model) } }
                }
            }
            menu
        }
    }

    @ViewBuilder private var titleLine: some View {
        if renaming {
            HStack(spacing: 6) {
                if let username = current.username { Text("@" + username).fontWeight(.medium) }
                TextField(model.text(L10n.Connect.rename), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .onSubmit { saveName() }
                    .onExitCommand { renaming = false }
                Button(model.text(L10n.Connect.save)) { saveName() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } else {
            HStack(spacing: 6) {
                if let username = current.username {
                    Text("@" + username).fontWeight(.medium)
                    Text("· " + bot.name).foregroundStyle(.secondary)
                } else {
                    Text(bot.name).fontWeight(.medium)
                }
                Button {
                    name = bot.name
                    renaming = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help(model.text(L10n.Connect.rename))
                .accessibilityLabel(model.text(L10n.Connect.rename))
                if adultAllowed {
                    Text(model.text(L10n.Digests.adult)).font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.purple.opacity(0.15), in: Capsule()).foregroundStyle(.purple)
                }
                if data.isBusy("name." + bot.id) { ProgressView().controlSize(.mini) }
            }
            .lineLimit(1)
        }
    }

    private func saveName() {
        let value = name
        renaming = false
        Task { await data.rename(bot.id, to: value, model: model) }
    }

    private var receivesLine: String {
        let digests = (model.config?.subscriptions ?? []).filter { $0.enabled && ($0.botIds ?? []).contains(bot.id) }
        guard !digests.isEmpty else { return model.text(L10n.Connect.receivesNone) }
        return L10n.Connect.receives(model.uiLanguage, [
            "count": String(digests.count), "names": digests.map { model.digestTitle($0.id) }.joined(separator: "、"),
        ])
    }

    private var statusText: String {
        if state == .paired, let at = pairing?.pairedAt {
            return L10n.Onboarding.paired(model.uiLanguage, ["time": Stamp.clock(at)])
        }
        return model.text(state.title)
    }

    private var menu: some View {
        Menu {
            if BotMenu.canResume(current) {
                Button(model.text(L10n.Connect.resume)) { Task { await data.act(bot.id, "resume", model: model) } }
            } else if BotMenu.canPause(current) {
                Button(model.text(L10n.Connect.pause)) { Task { await data.act(bot.id, "pause", model: model) } }
            }
            Button(model.text(L10n.Connect.replaceToken)) { data.replacingToken.insert(bot.id) }
            if current.paired || current.verified {
                Button(model.text(L10n.Connect.unpair)) { confirmUnpair = true }
            }
            Divider()
            Button(model.text(L10n.Connect.delete), role: .destructive) {
                Task { if await data.loadImpact(bot.id, model: model) != nil { confirmDelete = true } }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(model.text(L10n.Connect.more))
        .accessibilityLabel(model.text(L10n.Connect.more))
        .disabled(data.isBusy("bot." + bot.id))
    }

    private var deleteImpact: String {
        guard let impact = data.impacts[bot.id] else { return "" }
        let language = model.uiLanguage
        if impact.subscriptions.isEmpty, impact.accounts.isEmpty { return model.text(L10n.Connect.deleteNone) }
        var lines: [String] = []
        if !impact.subscriptions.isEmpty {
            lines.append(L10n.Connect.deleteAffects(language, ["names": impact.subscriptions.map(model.digestTitle).joined(separator: "、")]))
        }
        if !impact.lastTargetSubscriptions.isEmpty {
            lines.append(L10n.Connect.deleteNoTarget(language, ["names": impact.lastTargetSubscriptions.map(model.digestTitle).joined(separator: "、")]))
        }
        if !impact.accounts.isEmpty {
            let handles = impact.accounts.map { account in
                model.config?.accounts.first { $0.id == account.id }.map { "@" + $0.handle } ?? account.id
            }
            lines.append(L10n.Connect.deleteAccounts(language, ["names": handles.joined(separator: "、")]))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Body rows

    @ViewBuilder private var failures: some View {
        if let failure = data.failures["bot." + bot.id] {
            FailureNote(model: model, failure: failure) { data.dismiss("bot." + bot.id) }
        }
        if let failure = data.failures["name." + bot.id] {
            FailureNote(model: model, failure: failure) { saveNameAgain() }
        }
        if case let .problem(code) = state, pairing?.failure == nil, !data.replacingToken.contains(bot.id) {
            FailureNote(model: model, failure: BackendError(code: code, domain: "bots")) { fix(code) }
        }
    }

    private func saveNameAgain() {
        name = bot.name
        renaming = true
    }

    /// The one fix for a Bot problem: paste the token again, check again, or a new code.
    private func fix(_ code: String) {
        switch code {
        case "invalid_token", "token_revoked", "missing_token", "bot_not_verified":
            data.replacingToken.insert(bot.id)
        case "pair_attempts_exhausted", "pair_expired":
            Task { await data.newCode(bot.id, model: model) }
        default:
            Task { await data.reverify(bot.id, model: model) }
        }
    }

    @ViewBuilder private var testLine: some View {
        let language = model.uiLanguage
        if let failure = data.failures["test." + bot.id] {
            FailureNote(model: model, failure: failure) { Task { await data.sendTest(bot.id, model: model) } }
        } else {
            switch TestDisplay.of(data.tests[bot.id], stillUnknown: data.stillUnknown.contains(bot.id)) {
            case .sent:
                Label(L10n.Connect.testSent(language, ["time": Stamp.clock(data.testedAt[bot.id] ?? Date())]), systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            case .unknown, .stillUnknown, .notSent:
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                    Text(model.text(testNote))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if data.stillUnknown.contains(bot.id) || data.tests[bot.id]?.state == "not_started" {
                        Button(model.text(L10n.Connect.sendAgain)) { Task { await data.sendTest(bot.id, model: model) } }
                    } else {
                        Button(model.text(L10n.Connect.checkResult)) { Task { await data.checkTest(bot.id, model: model) } }
                    }
                }
                .font(.callout)
                .padding(10)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .combine)
            case .sending:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(model.text(L10n.Connect.sending)).foregroundStyle(.secondary)
                    Button(model.text(L10n.Connect.checkResult)) { Task { await data.checkTest(bot.id, model: model) } }
                        .buttonStyle(.link)
                }
                .font(.callout)
            case .none:
                EmptyView()
            }
        }
    }

    private var testNote: Words {
        switch TestDisplay.of(data.tests[bot.id], stillUnknown: data.stillUnknown.contains(bot.id)) {
        case .notSent: L10n.Connect.testNotSent
        case .stillUnknown: L10n.Connect.testStillUnknown
        default: L10n.Connect.testUnknown
        }
    }

    @ViewBuilder private var pairingArea: some View {
        if let pairing, let failure = pairing.failure {
            FailureNote(model: model, failure: failure) { fix(failure.code) }
        }
        if let pairing, let pair = pairing.pair, !current.paired {
            PairBlock(model: model, pairing: pairing, pair: pair)
        } else if [.waiting, .expired, .unpaired].contains(state), !(pairing?.working ?? false) {
            HStack(spacing: 10) {
                Text(model.text(state == .unpaired ? L10n.Connect.unpairedNote : state == .expired ? L10n.Onboarding.expired : L10n.Connect.needsPairing))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(model.text(state == .unpaired ? L10n.Connect.pairAgain : state == .expired ? L10n.Onboarding.newCode : L10n.Connect.makeCode)) {
                    Task { await data.newCode(bot.id, model: model) }
                }
            }
            .font(.callout)
            .padding(12)
            .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        } else if pairing?.working == true {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(model.text(L10n.Onboarding.checking)).foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    @ViewBuilder private var tokenField: some View {
        if data.replacingToken.contains(bot.id) || state == .unverified {
            HStack(spacing: 8) {
                SecureField(model.text(L10n.Onboarding.tokenPlaceholder), text: $token)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { replace(token) }
                    .accessibilityLabel(model.text(L10n.Onboarding.tokenPlaceholder))
                Button(model.text(L10n.Onboarding.paste)) {
                    if let value = NSPasteboard.general.string(forType: .string) {
                        token = value
                        replace(value)
                    }
                }
                Button(model.text(L10n.Onboarding.check)) { replace(token) }
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || pairing?.working == true)
                if data.replacingToken.contains(bot.id) {
                    Button(model.text(L10n.Shell.cancel)) { data.replacingToken.remove(bot.id) }
                        .buttonStyle(.link)
                }
            }
        }
    }

    private func replace(_ value: String) {
        Task {
            await data.replaceToken(bot.id, token: value, model: model)
            if data.pairing(bot.id)?.failure == nil { token = "" }
        }
    }

    private var adultRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.text(L10n.Connect.adultAllowed))
                Text(model.text(adultAllowed ? L10n.Connect.adultOnNote : L10n.Connect.adultOffNote))
                    .font(.caption).foregroundStyle(.secondary)
                if let failure = data.failures["adult." + bot.id] {
                    Text(FailureCopy.message(for: failure, model.uiLanguage)).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            if data.isBusy("adult." + bot.id) { ProgressView().controlSize(.small) }
            Toggle(model.text(L10n.Connect.adultAllowed), isOn: Binding(
                get: { adultAllowed },
                set: { on in
                    if on {
                        Task { await data.setAdult(bot.id, true, model: model) }
                    } else if let config = model.config {
                        let affected = ConnectData.adultTargets(bot.id, config: config)
                        if affected.isEmpty { Task { await data.setAdult(bot.id, false, model: model) } } else { adultOff = affected }
                    }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(data.isBusy("adult." + bot.id) || configured == nil)
        }
    }
}

// MARK: - Models (§6.2)

private struct ModelsSection: View {
    let model: AppModel
    let data: ConnectData

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: model.text(L10n.Connect.modelsTitle), note: model.text(L10n.Connect.modelsNote))
            HStack(alignment: .top, spacing: 12) {
                ModelGroup(model: model, data: data, partition: "normal")
                ModelGroup(model: model, data: data, partition: "adult")
            }
            ExtrasGroup(model: model, data: data)
        }
    }
}

private struct ModelGroup: View {
    let model: AppModel
    let data: ConnectData
    let partition: String

    private var profiles: [AppConfig.Profile] {
        (model.config?.modelProfiles ?? []).filter { $0.partition == partition }
            .sorted { ($0.role == "primary" ? 0 : 1, $0.id) < ($1.role == "primary" ? 0 : 1, $1.id) }
    }

    private var digests: String {
        let categories = Set(model.config?.categories.filter { $0.partition == partition }.map(\.id) ?? [])
        var seen = Set<String>()
        return (model.config?.subscriptions ?? []).filter { categories.contains($0.categoryId) && seen.insert($0.categoryId).inserted }
            .map { model.digestTitle($0.id) }.joined(separator: " · ")
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(model.text(partition == "adult" ? L10n.Connect.adultGroup : L10n.Connect.normalGroup)).font(.headline)
                    Text(digests).font(.caption).foregroundStyle(partition == "adult" ? Color.purple : Color.secondary).lineLimit(1)
                }
                .padding(.bottom, 8)
                ForEach(profiles) { profile in
                    Divider()
                    ModelRow(model: model, data: data, profile: profile)
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

private struct ModelRow: View {
    let model: AppModel
    let data: ConnectData
    let profile: AppConfig.Profile
    @State private var editing = false
    @State private var confirmRetry = false

    private var backup: Bool { profile.role == "backup" }
    private var provider: String { ModelNames.provider(profile.provider, model.uiLanguage) }
    private var status: KeyStatus {
        KeyStatus.of(credential: data.credentialState(profile.credentialRef), probe: data.keys.probes[profile.id],
                     health: data.health[profile.id], working: data.keys.working.contains(profile.id))
    }

    var body: some View {
        let status = status
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    (Text((backup ? model.text(L10n.Connect.backupPrefix) : "") + ModelNames.model(profile.model))
                        .foregroundStyle(backup ? Color.secondary : Color.primary)
                     + Text(" · " + provider).font(.caption).foregroundStyle(.secondary))
                        .lineLimit(1)
                    Text(detail(status)).font(.caption)
                        .foregroundStyle(status.color == .red ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                StatusDot(color: status.color, text: status.title(model.uiLanguage), busy: status == .checking)
                actions(status)
            }
            if let failure = data.keys.failures[profile.id] {
                FailureNote(model: model, failure: failure) {
                    // No result yet: the check may have been charged, so another one is confirmed first.
                    if failure.code == "probe_pending" { confirmRetry = true } else { editing = true }
                }
            }
        }
        .padding(.vertical, 8)
        .confirmationDialog(model.text(L10n.Connect.retryTitle), isPresented: $confirmRetry) {
            Button(model.text(L10n.Onboarding.checkAgain)) { Task { await data.recheck(profile.id, model: model, confirmed: true) } }
            Button(model.text(L10n.Shell.cancel), role: .cancel) {}
        } message: {
            Text(model.text(L10n.Connect.retryBody))
        }
    }

    @ViewBuilder private func actions(_ status: KeyStatus) -> some View {
        switch status.action {
        case .recheck:
            Button(model.text(L10n.Onboarding.checkAgain)) { Task { await data.recheck(profile.id, model: model) } }
        case .confirmRecheck:
            Button(model.text(L10n.Connect.checkAndRetry)) { confirmRetry = true }
        case .enterKey, .reenterKey, .none:
            EmptyView()
        }
        keyButton(status)
    }

    private func keyButton(_ status: KeyStatus) -> some View {
        let words = switch status.action {
        case .enterKey: L10n.Connect.enterKey
        case .reenterKey: L10n.Connect.reenterKey
        default: L10n.Connect.replaceKey
        }
        return Button(model.text(words)) { editing = true }
            .buttonStyle(KeyButtonStyle(prominent: status.action == .reenterKey))
            .disabled(status == .checking)
            .popover(isPresented: $editing, arrowEdge: .bottom) {
                KeyPopover(model: model, title: L10n.Connect.keyFor(model.uiLanguage, ["model": ModelNames.model(profile.model)]),
                           note: model.text(L10n.Connect.keySaveNote)) { key in
                    editing = false
                    Task { await data.saveKey(key, profile: profile.id, model: model) }
                }
            }
    }

    /// "Key ••••7Qx2 · Text ✓ Vision ✓ · checked today 08:12", or what went wrong.
    private func detail(_ status: KeyStatus) -> String {
        let language = model.uiLanguage
        if let note = status.note(language, provider: provider) { return note }
        if status == .missing {
            return model.text(backup ? L10n.Connect.backupOptional : L10n.Connect.primaryNeedsKey)
        }
        var parts: [String] = []
        if let tail = data.tail(profile.credentialRef) { parts.append("Key ••••" + tail) }
        let names: [(String, Words)] = [("text", L10n.Connect.capText), ("vision", L10n.Connect.capVision),
                                        ("image", L10n.Connect.capImage), ("stt", L10n.Connect.capSpeech)]
        let passed = names.filter { data.keys.states[profile.id]?[$0.0]?.passed == true }.map { $0.1(language) + " ✓" }
        if status == .verified, !passed.isEmpty { parts.append(passed.joined(separator: " ")) }
        if status == .verified, let at = data.keys.probes[profile.id]?.checkedAt.flatMap(OverviewData.date) {
            parts.append(L10n.Connect.verifiedAt(language, ["when": Stamp.relative(at, language)]))
        }
        if parts.isEmpty, backup { return model.text(L10n.Connect.backupOptional) }
        return parts.joined(separator: " · ")
    }
}

/// A key action is a plain button, except "Enter Again" for a rejected key, the row's one fix.
private struct KeyButtonStyle: PrimitiveButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        if prominent {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }.buttonStyle(.borderedProminent)
        } else {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }.buttonStyle(.bordered)
        }
    }
}

/// Replace / enter a key: SecureField + Paste + Save. Saving starts the backend's check.
struct KeyPopover: View {
    let model: AppModel
    let title: String
    let note: String
    let save: (String) -> Void
    @State private var key = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            HStack(spacing: 8) {
                SecureField(model.text(L10n.Onboarding.keyPlaceholder), text: $key)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit { submit() }
                    .accessibilityLabel(title)
                Button(model.text(L10n.Onboarding.paste)) {
                    if let value = NSPasteboard.general.string(forType: .string) {
                        key = value
                        submit()
                    }
                }
            }
            Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(model.text(L10n.Shell.cancel), role: .cancel) {
                    key = ""
                    dismiss()
                }
                    .keyboardShortcut(.cancelAction)
                Button(model.text(L10n.Connect.save)) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func submit() {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        key = ""
        save(value)
    }
}

// MARK: - Extras

private struct ExtrasGroup: View {
    let model: AppModel
    let data: ConnectData
    @AppStorage("connect.extrasOpen") private var open = false

    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $open) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.text(L10n.Connect.extrasNote)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 8)
                    Divider()
                    ExtraRow(model: model, data: data, kind: .newspaper)
                    Divider()
                    ExtraRow(model: model, data: data, kind: .transcription)
                    Divider()
                    EndpointEditor(model: model, data: data)
                }
            } label: {
                Text(model.text(L10n.Connect.extrasTitle)).fontWeight(.semibold)
            }
            .accessibilityValue(model.text(open ? L10n.Digests.collapse : L10n.Digests.edit))
            .padding(4)
        }
    }
}

private struct ExtraRow: View {
    enum Kind { case newspaper, transcription }

    let model: AppModel
    let data: ConnectData
    let kind: Kind
    @State private var choice = ""

    private var key: String { kind == .newspaper ? "newspaper" : "transcription" }
    private var capability: String { kind == .newspaper ? "image" : "stt" }
    private var on: Bool { kind == .newspaper ? data.extras.newspaperOn : data.extras.transcriptionProfile != nil }
    private var stored: String? { kind == .newspaper ? data.extras.newspaperProfile : data.extras.transcriptionProfile }
    private var options: [AppConfig.Profile] { (model.config?.modelProfiles ?? []).filter(ModelNames.openAIOfficial) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.text(kind == .newspaper ? L10n.Connect.newspaper : L10n.Connect.transcription))
                    Text(model.text(kind == .newspaper ? L10n.Connect.newspaperNote : L10n.Connect.transcriptionNote))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if !options.isEmpty {
                    Picker(model.text(L10n.Connect.useModel), selection: Binding(
                        get: { choice },
                        set: { value in
                            choice = value
                            if on { save(true, value) }
                        }
                    )) {
                        ForEach(options) { profile in
                            Text(ModelNames.model(profile.model) + " · " + ModelNames.provider(profile.provider, model.uiLanguage)).tag(profile.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                status
                if data.isBusy(key) { ProgressView().controlSize(.small) }
                Toggle(model.text(kind == .newspaper ? L10n.Connect.newspaper : L10n.Connect.transcription), isOn: Binding(
                    get: { on },
                    set: { save($0, choice.isEmpty ? nil : choice) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(data.isBusy(key) || (options.isEmpty && !on))
                .help(options.isEmpty ? model.text(L10n.Connect.needsOpenAI) : "")
            }
            if options.isEmpty {
                Text(model.text(L10n.Connect.needsOpenAI)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure = data.failures[key] {
                FailureNote(model: model, failure: failure)
            }
        }
        .padding(.vertical, 8)
        .onAppear { choice = stored ?? options.first?.id ?? "" }
        .onChange(of: stored) { _, value in if let value { choice = value } }
    }

    @ViewBuilder private var status: some View {
        if !on {
            StatusDot(color: .gray, text: model.text(L10n.Connect.off))
        } else if let profile = stored, let check = data.keys.states[profile]?[capability] {
            if check.passed {
                StatusDot(color: .green, text: model.text(L10n.Connect.statusUsable))
            } else if !check.settled {
                StatusDot(color: .gray, text: model.text(L10n.Connect.checkingCapability), busy: check.state == "pending")
            } else {
                StatusDot(color: check.state == "outcome_unknown" ? .orange : .red, text: model.text(L10n.Connect.statusFailed))
                    .help(FailureCopy.message(for: BackendError(code: check.errorKind ?? check.state, domain: "models"), model.uiLanguage))
            }
        } else {
            StatusDot(color: .gray, text: model.text(L10n.Connect.checkingCapability))
        }
    }

    private func save(_ on: Bool, _ profile: String?) {
        Task {
            switch kind {
            case .newspaper: await data.setNewspaper(on, profile: profile, model: model)
            case .transcription: await data.setTranscription(on ? profile : nil, model: model)
            }
        }
    }
}

/// Another OpenAI-compatible address or model ID for one of the four models.
private struct EndpointEditor: View {
    let model: AppModel
    let data: ConnectData
    @State private var profile = "normal_primary"
    @State private var address = ""
    @State private var modelId = ""

    private var profiles: [AppConfig.Profile] { model.config?.modelProfiles ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.text(L10n.Connect.endpoint))
            Text(model.text(L10n.Connect.endpointNote)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Picker(model.text(L10n.Connect.endpoint), selection: $profile) {
                    ForEach(profiles) { entry in Text(label(entry)).tag(entry.id) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                TextField(model.text(L10n.Onboarding.customURL), text: $address)
                    .textFieldStyle(.roundedBorder)
                TextField(model.text(L10n.Onboarding.customModel), text: $modelId)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 170)
                if data.isBusy("endpoint." + profile) { ProgressView().controlSize(.small) }
                Button(model.text(L10n.Connect.save)) {
                    Task { await data.saveEndpoint(profile, baseURL: address, modelId: modelId, model: model) }
                }
                .disabled(unchanged || data.isBusy("endpoint." + profile))
            }
            if let failure = data.failures["endpoint." + profile] {
                FailureNote(model: model, failure: failure)
            } else if let at = data.savedAt["endpoint." + profile] {
                Text(L10n.Shell.savedAt(model.uiLanguage, ["time": Stamp.clock(at)])).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .onAppear(perform: fill)
        .onChange(of: profile) { fill() }
    }

    private var unchanged: Bool {
        guard let entry = profiles.first(where: { $0.id == profile }) else { return true }
        let trimmedAddress = address.trimmingCharacters(in: .whitespaces)
        let trimmedModel = modelId.trimmingCharacters(in: .whitespaces)
        return trimmedAddress.isEmpty || trimmedModel.isEmpty || (trimmedAddress == entry.baseUrl && trimmedModel == entry.model)
    }

    private func fill() {
        guard let entry = profiles.first(where: { $0.id == profile }) else { return }
        address = entry.baseUrl ?? ""
        modelId = entry.model
    }

    private func label(_ entry: AppConfig.Profile) -> String {
        let group = model.text(entry.partition == "adult" ? L10n.Connect.adultGroup : L10n.Connect.normalGroup)
        let role = model.text(entry.role == "primary" ? L10n.Digests.primaryModel : L10n.Digests.backupModel)
        return group + " · " + role
    }
}

// MARK: - Spending (§6.3)

private struct SpendingSection: View {
    let model: AppModel
    let data: ConnectData
    @State private var monthly = ""
    @State private var daily = ""
    @FocusState private var focus: Field?

    private enum Field { case monthly, daily }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: model.text(L10n.Connect.spendingTitle))
            GroupBox {
                VStack(alignment: .leading, spacing: 0) {
                    monthlyRow
                    Divider().padding(.vertical, 8)
                    usageRow
                    Divider().padding(.vertical, 8)
                    dailyRow
                    if let limits = data.budget?.limits, !limits.isEmpty {
                        Divider().padding(.vertical, 8)
                        otherLimits(limits)
                    }
                }
                .padding(4)
            }
            Text(pricingNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: fill)
        .onChange(of: data.budget) { fill() }
        .onChange(of: focus) { old, _ in
            // Leaving a field saves it, like pressing Return.
            if old == .monthly { saveMonthly() }
            if old == .daily { saveDaily() }
        }
    }

    private func fill() {
        guard let budget = data.budget else { return }
        if focus != .monthly { monthly = BudgetSummary.dollarField(budget.monthlyLimit) }
        if focus != .daily { daily = budget.dailyReads.map(String.init) ?? "" }
    }

    private func saveMonthly() {
        guard let budget = data.budget, monthly != BudgetSummary.dollarField(budget.monthlyLimit) else { return }
        Task { await data.saveMonthlyLimit(monthly, model: model) }
    }

    private func saveDaily() {
        guard let budget = data.budget, daily != (budget.dailyReads.map(String.init) ?? "") else { return }
        Task { await data.saveDailyReads(daily, model: model) }
    }

    private var monthlyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.text(L10n.Connect.monthly))
                    Text(model.text(L10n.Connect.monthlyNote)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                saved("budget.monthly")
                Text("$")
                TextField(model.text(L10n.Connect.noLimit), text: $monthly)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .focused($focus, equals: .monthly)
                    .onSubmit(saveMonthly)
                    .accessibilityLabel(model.text(L10n.Connect.monthly))
                Text(model.text(L10n.Connect.perMonth)).foregroundStyle(.secondary)
            }
            if let failure = data.failures["budget.monthly"] {
                FailureNote(model: model, failure: failure) { fill(); data.dismiss("budget.monthly") }
            }
        }
    }

    private var usageRow: some View {
        let budget = data.budget ?? BudgetSummary()
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(usedLine(budget)).font(.callout)
                Spacer()
                if let since = budget.since {
                    Text(L10n.Connect.since(model.uiLanguage, ["date": since.formatted(.dateTime.month().day())]))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let limit = budget.monthlyLimit, limit > 0 {
                ProgressView(value: min(Double(budget.used), Double(limit)), total: Double(limit))
                    .tint(budget.used >= limit ? .red : .accentColor)
                    .accessibilityLabel(model.text(L10n.Connect.monthly))
                    .accessibilityValue(dollars(budget.used) + " / " + dollars(limit))
            }
        }
    }

    private func usedLine(_ budget: BudgetSummary) -> String {
        let language = model.uiLanguage
        var line = L10n.Connect.usedLine(language, ["amount": dollars(budget.used)])
        let parts = budget.parts.map { operationName($0.operation) + " " + dollars($0.amount) }
        if !parts.isEmpty { line += " · " + parts.joined(separator: " · ") }
        return line
    }

    private func operationName(_ operation: String) -> String {
        let names: [String: Words] = [
            "text": L10n.Connect.opText, "image": L10n.Connect.opImage, "vision": L10n.Connect.opVision,
            "stt": L10n.Connect.opSpeech, "search": L10n.Connect.opSearch,
        ]
        return model.text(names[operation] ?? L10n.Connect.opOther)
    }

    private var dailyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.text(L10n.Connect.dailyReads))
                    Text(L10n.Connect.dailyNote(model.uiLanguage, ["count": String(data.budget?.readsToday ?? 0)]))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                saved("budget.daily")
                TextField(model.text(L10n.Connect.noLimit), text: $daily)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .focused($focus, equals: .daily)
                    .onSubmit(saveDaily)
                    .accessibilityLabel(model.text(L10n.Connect.dailyReads))
                Text(model.text(L10n.Connect.perDay)).foregroundStyle(.secondary)
            }
            if let failure = data.failures["budget.daily"] {
                FailureNote(model: model, failure: failure) { fill(); data.dismiss("budget.daily") }
            }
        }
    }

    private func otherLimits(_ limits: [BudgetSummary.Limit]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.text(L10n.Connect.otherLimits))
            ForEach(limits) { limit in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title(limit)).font(.callout)
                        Text(usage(limit)).font(.caption).foregroundStyle(limit.used >= limit.value ? Color.orange : Color.secondary)
                        Spacer()
                        if data.isBusy("budget." + limit.id) { ProgressView().controlSize(.small) }
                        Button(model.text(L10n.Connect.clear)) { Task { await data.clear(limit, model: model) } }
                            .disabled(data.isBusy("budget." + limit.id))
                            .accessibilityLabel(model.text(L10n.Connect.clear) + " " + title(limit))
                    }
                    if let failure = data.failures["budget." + limit.id] { FailureNote(model: model, failure: failure) }
                }
            }
        }
    }

    private func title(_ limit: BudgetSummary.Limit) -> String {
        let language = model.uiLanguage
        let amount = dollars(limit.value)
        let count = String(limit.value)
        switch limit.kind {
        case .image: return L10n.Connect.imageLimit(language, ["amount": amount])
        case let .provider(name): return L10n.Connect.providerLimit(language, ["provider": ModelNames.provider(name, language), "amount": amount])
        case .partition("adult"): return L10n.Connect.adultReadsLimit(language, ["count": count])
        case .partition: return L10n.Connect.normalReadsLimit(language, ["count": count])
        case let .account(id):
            let handle = model.config?.accounts.first { $0.id == id }.map { "@" + $0.handle } ?? id
            return L10n.Connect.accountLimit(language, ["account": handle, "count": count])
        }
    }

    private func usage(_ limit: BudgetSummary.Limit) -> String {
        let language = model.uiLanguage
        if limit.used >= limit.value { return model.text(L10n.Connect.limitReached) }
        return limit.money ? L10n.Connect.usedLine(language, ["amount": dollars(limit.used)])
            : L10n.Connect.readToday(language, ["count": String(limit.used)])
    }

    @ViewBuilder private func saved(_ key: String) -> some View {
        if data.isBusy(key) {
            ProgressView().controlSize(.small)
        } else if let at = data.savedAt[key] {
            Text(L10n.Shell.savedAt(model.uiLanguage, ["time": Stamp.clock(at)])).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var pricingNote: String {
        var note = model.text(L10n.Connect.pricingNote)
        if let unpriced = data.budget?.unpriced, unpriced > 0 {
            note += " " + L10n.Connect.unpricedCount(model.uiLanguage, ["count": String(unpriced)])
        }
        return note
    }
}

// MARK: - X (§6.4)

private struct XSection: View {
    let model: AppModel
    let data: ConnectData
    @State private var editing = false

    private var reference: String? { model.config?.xApi?.credentialRef }

    private enum XState { case missing, keychain(String), working, rejected(Int), saved, verified(Date?) }

    private var state: XState {
        guard let reference, let credential = data.credentialState(reference), credential != "missing" else { return .missing }
        if data.isBusy("x") { return .working }
        if credential != "available" { return .keychain(credential) }
        switch data.xCheck?.state {
        case "ready", "protected": return .verified(data.xCheck?.observedAt.flatMap(OverviewData.date))
        case "authentication_failed": return .rejected(401)
        case "permission_denied": return .rejected(403)
        default: return .saved
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: model.text(L10n.Connect.xTitle))
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("X API Key")
                            Text(detail).font(.caption).foregroundStyle(isProblem ? Color.red : Color.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        dot
                        Button(model.text(reference == nil ? L10n.Connect.enterKey : L10n.Connect.replaceKey)) { editing = true }
                            .disabled(data.isBusy("x"))
                            .popover(isPresented: $editing, arrowEdge: .bottom) {
                                KeyPopover(model: model, title: "X API Key", note: model.text(L10n.Connect.xKeyNote)) { key in
                                    editing = false
                                    Task { await data.saveXKey(key, model: model) }
                                }
                            }
                    }
                    if let failure = data.failures["x"] {
                        FailureNote(model: model, failure: failure) { editing = true }
                    }
                }
                .padding(4)
            }
        }
    }

    private var isProblem: Bool {
        switch state {
        case .keychain, .rejected: true
        default: false
        }
    }

    private var tail: String { data.tail(reference).map { "Key ••••" + $0 } ?? "Key" }

    private var detail: String {
        let language = model.uiLanguage
        switch state {
        case .missing: return model.text(L10n.Connect.xNeedsKey)
        case .working: return model.text(L10n.Connect.saving)
        case let .keychain(code): return FailureCopy.message(for: BackendError(code: code, domain: "credentials"), language)
        case .rejected(401): return model.text(L10n.Connect.xRejected)
        case .rejected: return model.text(L10n.Connect.xForbidden)
        case .saved: return tail + " · " + model.text(L10n.Connect.xUnused)
        case let .verified(at):
            var parts = [tail, model.text(L10n.Connect.xReadsFine)]
            if let at { parts.append(L10n.Connect.verifiedAt(language, ["when": Stamp.relative(at, language)])) }
            return parts.joined(separator: " · ")
        }
    }

    @ViewBuilder private var dot: some View {
        switch state {
        case .missing: StatusDot(color: .gray, text: model.text(L10n.Connect.statusNoKey))
        case .working: StatusDot(color: .gray, text: model.text(L10n.Connect.saving), busy: true)
        case .keychain: StatusDot(color: .red, text: model.text(L10n.Connect.statusKeychain))
        case .rejected: StatusDot(color: .red, text: model.text(L10n.Connect.statusKeyInvalid))
        case .saved: StatusDot(color: .blue, text: model.text(L10n.Connect.statusSaved))
        case .verified: StatusDot(color: .green, text: model.text(L10n.Connect.statusUsable))
        }
    }
}
