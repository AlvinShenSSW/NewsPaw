import AppKit
import Foundation
import Observation
import SwiftUI

// The two connection flows the first-run window and the Connect page share: one Telegram Bot
// from token to paired (interaction-spec §3 step 1, §6.1), and a model key from saved to checked
// (§3 step 2, §6.2). Each page keeps its own instances; the logic lives here once.

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
    let checkedAt: String?

    init(state: String, errorKind: String? = nil, reportedModel: String? = nil, checkedAt: String? = nil) {
        self.state = state
        self.errorKind = errorKind
        self.reportedModel = reportedModel
        self.checkedAt = checkedAt
    }

    private enum Keys: String, CodingKey { case state, status, errorKind, reportedModel, checkedAt }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        state = try values.decodeIfPresent(String.self, forKey: .state) ?? values.decode(String.self, forKey: .status)
        errorKind = try values.decodeIfPresent(String.self, forKey: .errorKind)
        reportedModel = try values.decodeIfPresent(String.self, forKey: .reportedModel)
        checkedAt = try values.decodeIfPresent(String.self, forKey: .checkedAt)
    }

    /// The check has an outcome for the current key. `stale` is a result for an earlier key
    /// (the new key's check has not finished yet), so it still counts as waiting.
    var settled: Bool { !Self.waiting.contains(state) }
    var passed: Bool { state == "verified" }

    static let waiting: Set<String> = ["pending", "untested", "stale"]
}

extension BackendError {
    /// Any thrown error as the one shape every view shows.
    static func wrapping(_ error: Error) -> BackendError {
        switch error {
        case let failure as BackendError: failure
        case is SocketFailure: BackendError(code: "backend_unreachable")
        default: BackendError(code: "invalid_reply")
        }
    }
}

extension BackendClient {
    /// Stores a secret in the Keychain for a model profile, Bot or the X connection. The
    /// configuration revision is read just before, and a background change is retried once.
    func setCredential(kind: String, id: String, value: String) async throws {
        for attempt in 0..<2 {
            let revision = try await configDocument().revision
            do {
                _ = try await call(.credentialsSet, ["kind": kind, "id": id, "value": value, "revision": revision])
                return
            } catch let error as BackendError where error.isConflict && attempt == 0 {
                continue
            }
        }
    }

    /// Deletes a Bot and removes it from every digest (`targets.delete_bot`), at the revision
    /// its impact was read at, once more after a background change.
    func deleteBot(_ id: String) async throws {
        for attempt in 0..<2 {
            struct Impact: Decodable { let revision: Int }
            let impact: Impact = try BackendRPC.decode(await call(.targetsBotImpact, ["bot_id": id]))
            do {
                _ = try await call(.targetsDeleteBot, ["bot_id": id, "revision": impact.revision])
                return
            } catch let error as BackendError where error.isConflict && attempt == 0 {
                continue
            }
        }
    }

    /// A request id the backend accepts (`[A-Za-z0-9_.:-]{1,120}`).
    static func requestId(_ prefix: String) -> String {
        prefix + "_" + String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16))
    }
}

// MARK: - One Bot, token to paired

/// Connects one Telegram Bot: store the token, check it with Telegram, issue a pairing code and
/// read the Bot until the owner has sent it. The Bot entry is created on first use.
@MainActor @Observable
final class BotPairing {
    private(set) var botId: String?
    private(set) var bot: BotStatus?
    private(set) var pair: PairingCode?
    private(set) var pairedAt: Date?
    private(set) var working = false
    private(set) var failure: BackendError?

    /// How often a waiting Bot is read back.
    @ObservationIgnored var pollInterval: Duration = .seconds(2)
    @ObservationIgnored private var cancelled = false
    /// The Bot entry this attempt created, until it is kept or removed.
    @ObservationIgnored private var created: String?

    var paired: Bool { bot?.paired == true }

    init(botId: String? = nil, bot: BotStatus? = nil) {
        self.botId = botId
        self.bot = bot
    }

    /// Continues with an existing Bot instead of creating one.
    func adopt(_ id: String) {
        if botId == nil { botId = id }
    }

    /// Reads the Bot's current state.
    func load(model: AppModel) async {
        guard let botId else { return }
        if let status: BotStatus = try? BackendRPC.decode(await model.client.call(.botsStatus, ["bot_id": botId])) {
            bot = status
        }
    }

    /// Saves the token, checks it with Telegram and issues a pairing code.
    func connect(token: String, model: AppModel) async {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !working else { return }
        working = true
        defer { working = false }
        failure = nil
        pair = nil
        do {
            let id = try await ensureBot(model: model)
            try checkCancelled()
            try await model.client.setCredential(kind: "bots", id: id, value: token)
            try checkCancelled()
            try await verify(id, model: model)
            try checkCancelled()
        } catch is Cancelled {
            await discard(model: model)
        } catch {
            if cancelled { await discard(model: model) } else { failure = BackendError.wrapping(error) }
        }
        await model.refresh()
    }

    /// Removes the Bot this attempt created (cancelled before it was finished).
    private func discard(model: AppModel) async {
        pair = nil
        failure = nil
        guard let id = created else { return }
        if (try? await model.client.deleteBot(id)) != nil {
            created = nil
            botId = nil
            bot = nil
        }
    }

    /// Checks the stored token with Telegram again (e.g. after a webhook was turned off).
    func reverify(model: AppModel) async {
        guard let botId, !working else { return }
        working = true
        defer { working = false }
        failure = nil
        pair = nil
        do { try await verify(botId, model: model) } catch {
            failure = BackendError.wrapping(error)
        }
        await model.refresh()
    }

    private func verify(_ id: String, model: AppModel) async throws {
        let current: BotStatus = try BackendRPC.decode(await model.client.call(.botsStatus, ["bot_id": id]))
        bot = try BackendRPC.decode(await model.client.call(.botsVerify, ["bot_id": id, "generation": current.generation ?? 0]))
        // `bots.verify` records a refused token in the Bot's status, not as a failed reply.
        guard bot?.verified == true else {
            throw BackendError(code: Self.problem(bot?.status), domain: "bots")
        }
        try checkCancelled()
        // The same token for the same Bot keeps its pairing; a new code would end it.
        if bot?.paired != true { try await issueCode(model: model) }
    }

    /// A new pairing code (also after the old one expired or was used up).
    func newCode(model: AppModel) async {
        guard !working else { return }
        working = true
        defer { working = false }
        failure = nil
        do { try await issueCode(model: model) } catch {
            failure = BackendError.wrapping(error)
        }
        await model.refresh()
    }

    private func issueCode(model: AppModel) async throws {
        guard let botId else { return }
        // Read the Bot's current generation first: a code issued earlier whose reply was lost has
        // already moved it on, and the stale one would be refused (binding_changed) forever.
        bot = try BackendRPC.decode(await model.client.call(.botsStatus, ["bot_id": botId]))
        pair = try BackendRPC.decode(await model.client.call(.botsPairCode, ["bot_id": botId, "generation": bot?.generation ?? 0]))
        pairedAt = nil
        bot = try BackendRPC.decode(await model.client.call(.botsStatus, ["bot_id": botId]))
    }

    /// The Bot's own status when it names a problem (`bots.verify` records the error kind
    /// there), else a generic "not confirmed".
    nonisolated static func problem(_ status: String?) -> String {
        guard let status, FailureCopy.table[status] != nil else { return "bot_not_verified" }
        return status
    }

    /// Reads the Bot until the owner has sent the pairing code (stops when paired, when the
    /// code expires, when the backend ends pairing, or when the task is cancelled).
    func waitForPairing(model: AppModel, now: @escaping () -> Date = Date.init) async {
        guard let botId, pair != nil else { return }
        while !Task.isCancelled, !paired, let pair, now() < pair.expires {
            try? await Task.sleep(for: pollInterval)
            guard !Task.isCancelled else { return }
            if let status: BotStatus = try? BackendRPC.decode(await model.client.call(.botsStatus, ["bot_id": botId])) {
                bot = status
                // Too many wrong codes, or the token stopped working: waiting cannot succeed.
                if status.status == "pair_attempts_exhausted" || !status.verified {
                    failure = BackendError(code: status.verified ? "pair_attempts_exhausted" : Self.problem(status.status), domain: "bots")
                    self.pair = nil
                    return
                }
            }
        }
        if paired {
            pairedAt = pairedAt ?? now()
            pair = nil
            await model.refresh()
        }
    }

    func dismissFailure() { failure = nil }

    /// Stops a connection attempt that is under way: at its next step it removes the Bot it
    /// created and ends, so cancelling at any moment leaves no Bot behind.
    func cancel() { cancelled = true }

    private struct Cancelled: Error {}

    private func checkCancelled() throws {
        if cancelled { throw Cancelled() }
    }

    /// The Bot being connected: the adopted one, else a new entry without a token.
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
        created = id
        return id
    }
}

// MARK: - Model keys, saved to checked

/// Saves model keys and reads their checks back. The backend checks a saved key by itself
/// (R04); this only reads `models.status` until the text check has an outcome for the new key.
@MainActor @Observable
final class KeyChecks {
    /// Each profile's text check, the one that decides whether the key works.
    private(set) var probes: [String: ProbeState] = [:]
    /// Every capability's check per profile, as `models.status` reports it.
    private(set) var states: [String: [String: ProbeState]] = [:]
    private(set) var working: Set<String> = []
    private(set) var failures: [String: BackendError] = [:]

    /// How often a pending check is read back, and how long a check may take: longer than the
    /// 90 seconds a provider gets (`providers.py`), so a slow provider's result is still read.
    @ObservationIgnored var pollInterval: Duration = .seconds(2)
    @ObservationIgnored var probeLimit: Duration = .seconds(120)

    /// Where a capability check's progress and failure are kept: the profile for its text check
    /// (the key's own check), else "profile.capability".
    nonisolated static func key(_ profile: String, _ capability: String) -> String {
        capability == "text" ? profile : profile + "." + capability
    }

    /// Reads one profile's checks.
    func load(_ profile: String, model: AppModel) async {
        if let read: [String: ProbeState] = try? BackendRPC.decode(await model.client.call(.modelsStatus, ["profile_id": profile])) {
            states[profile] = read
            probes[profile] = read["text"]
            // Once the check has an outcome, an earlier "no result yet" note no longer holds.
            if read["text"]?.settled == true, failures[profile]?.code == "probe_pending" { failures[profile] = nil }
        }
    }

    /// Saves a key; `before` runs first (e.g. choosing the model) and stops the save when it throws.
    func save(_ key: String, profile: String, model: AppModel, before: (@MainActor () async throws -> Void)? = nil) async {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !working.contains(profile) else { return }
        working.insert(profile)
        defer { working.remove(profile) }
        failures[profile] = nil
        probes[profile] = nil
        do {
            try await before?()
            try await model.client.setCredential(kind: "model_profiles", id: profile, value: key)
            await readProbe(profile, model: model)
        } catch {
            failures[profile] = BackendError.wrapping(error)
        }
        await model.refresh()
    }

    /// Reads the key check until it has an outcome.
    func readProbe(_ profile: String, model: AppModel) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: probeLimit)
        while !Task.isCancelled, clock.now < deadline {
            await load(profile, model: model)
            if probes[profile]?.settled == true { return }
            try? await Task.sleep(for: pollInterval)
        }
        if probes[profile]?.settled != true { failures[profile] = BackendError(code: "probe_pending", domain: "models") }
    }

    /// Waits for a check that is already running (opened while the backend checks a key).
    func follow(_ profile: String, model: AppModel) async {
        guard !working.contains(profile) else { return }
        working.insert(profile)
        defer { working.remove(profile) }
        await readProbe(profile, model: model)
    }

    /// Whether checking this key again could repeat a charge whose result never came back: the
    /// last check's outcome is unknown, it is still running, or it gave no result in time. Both
    /// the first-run window and the Connect page ask the owner before such a recheck.
    func needsConfirmation(_ profile: String, capability: String = "text") -> Bool {
        let state = capability == "text" ? probes[profile]?.state : states[profile]?[capability]?.state
        return ["outcome_unknown", "pending"].contains(state ?? "") || failures[Self.key(profile, capability)]?.code == "probe_pending"
    }

    /// A finished or followed check: the text check is the key's own result.
    private func record(_ state: ProbeState, profile: String, capability: String) {
        states[profile, default: [:]][capability] = state
        if capability == "text" { probes[profile] = state }
    }

    /// Runs the key check again for the same saved key; `models.probe` returns the finished result.
    /// Without `confirmed`, a check that may already have been charged is not repeated.
    /// A capability other than text (image, vision, speech) is checked with a new probe id: the
    /// backend's automatic check uses one bound to the key's generation and would only return
    /// the same failed record again.
    func recheck(_ profile: String, model: AppModel, capability: String = "text", confirmed: Bool = false) async {
        let key = Self.key(profile, capability)
        guard confirmed || !needsConfirmation(profile, capability: capability), !working.contains(key) else { return }
        working.insert(key)
        defer { working.remove(key) }
        failures[key] = nil
        let request: [String: Any] = [
            "probe_id": BackendClient.requestId("probe"), "profile_id": profile, "capability": capability, "hold_units": 10_000,
        ]
        do {
            let result: ProbeState = try BackendRPC.decode(await model.client.call(.modelsProbe, request))
            await load(profile, model: model)
            record(result, profile: profile, capability: capability)
        } catch is SocketFailure {
            // The connection gave up but the backend keeps checking. Asking again with the same
            // probe id returns this check's own record (no second charge), not an earlier one.
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: probeLimit)
            while !Task.isCancelled, clock.now < deadline {
                try? await Task.sleep(for: pollInterval)
                if let state: ProbeState = try? BackendRPC.decode(await model.client.call(.modelsProbe, request)), state.settled {
                    record(state, profile: profile, capability: capability)
                    await model.refresh()
                    return
                }
            }
            failures[key] = BackendError(code: "probe_pending", domain: "models")
        } catch {
            failures[key] = BackendError.wrapping(error)
        }
        await model.refresh()
    }
}

// MARK: - Pairing code block

/// The code to send in Telegram, its countdown, and reading the Bot every 2 seconds until it is
/// paired. An expired code offers a new one in place.
struct PairBlock: View {
    let model: AppModel
    let pairing: BotPairing
    let pair: PairingCode

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = Int(pair.expires.timeIntervalSince(context.date))
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.Onboarding.sendThis(model.uiLanguage, ["name": pairing.bot?.username.map { "@" + $0 } ?? "Bot"]))
                HStack(spacing: 10) {
                    Text("/pair " + pair.code)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Button(model.text(L10n.Onboarding.copy)) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("/pair " + pair.code, forType: .string)
                    }
                    Button(model.text(L10n.Onboarding.newCode)) { Task { await pairing.newCode(model: model) } }
                        .buttonStyle(.link)
                        .disabled(pairing.working)
                }
                if left > 0 {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L10n.Onboarding.expiresIn(model.uiLanguage, ["minutes": String(left / 60), "seconds": String(left % 60)]))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                } else {
                    Text(model.text(L10n.Onboarding.expired)).foregroundStyle(.orange)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
        .task(id: pair) { await pairing.waitForPairing(model: model) }
    }
}

// MARK: - Token to paired, as one form

/// Token field, check, pairing code and result for one Bot; the first-run window's step 1 and
/// the Connect page's "Add Bot" form show the same thing.
struct BotConnectForm: View {
    let model: AppModel
    let pairing: BotPairing
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if pairing.bot?.verified != true || pairing.failure != nil {
                HStack(spacing: 8) {
                    SecureField(model.text(L10n.Onboarding.tokenPlaceholder), text: $token)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { connect(token) }
                        .onChange(of: token) { old, new in
                            // A paste (a jump of many characters) checks right away.
                            if new.count - old.count > 20 { connect(new) }
                        }
                        .accessibilityLabel(model.text(L10n.Onboarding.tokenPlaceholder))
                    Button(model.text(L10n.Onboarding.paste)) {
                        if let value = NSPasteboard.general.string(forType: .string) {
                            token = value
                            connect(value)
                        }
                    }
                    Button(model.text(L10n.Onboarding.check)) { connect(token) }
                        .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || pairing.working)
                }
            }
            if pairing.working {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(model.text(L10n.Onboarding.checking)).foregroundStyle(.secondary)
                }
            }
            if let failure = pairing.failure {
                FailureNote(model: model, failure: failure) {
                    Task {
                        if pairing.bot?.verified == true { await pairing.newCode(model: model) } else { await pairing.connect(token: token, model: model) }
                    }
                }
            }
            if let bot = pairing.bot, bot.verified {
                Label(L10n.Onboarding.verified(model.uiLanguage, ["name": bot.username.map { "@" + $0 } ?? bot.name]), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if pairing.paired {
                Label(pairing.pairedAt.map { L10n.Onboarding.paired(model.uiLanguage, ["time": Stamp.clock($0)]) }
                        ?? model.text(L10n.Onboarding.pairedEarlier),
                      systemImage: "checkmark.seal.fill")
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.green)
            } else if let pair = pairing.pair {
                PairBlock(model: model, pairing: pairing, pair: pair)
            } else if pairing.bot?.verified == true, pairing.failure == nil, !pairing.working {
                // Checked on an earlier visit but never paired: a fresh code continues from here.
                HStack(spacing: 10) {
                    Text(model.text(L10n.Onboarding.notPaired)).foregroundStyle(.secondary)
                    Button(model.text(L10n.Onboarding.newCode)) { Task { await pairing.newCode(model: model) } }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func connect(_ value: String) {
        Task { await pairing.connect(token: value, model: model) }
    }
}

/// Local times as the interface writes them: 24-hour "HH:MM", and "today 08:12 / yesterday
/// 20:28 / 11-08" for when something last happened (interaction-spec §0.2).
enum Stamp {
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func relative(_ date: Date, now: Date = Date(), _ language: AppLanguage, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return L10n.Connect.todayAt(language, ["time": clock(date)]) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return L10n.Connect.yesterdayAt(language, ["time": clock(date)])
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = calendar.isDate(date, equalTo: now, toGranularity: .year) ? "MM-dd" : "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
