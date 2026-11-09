import Foundation
import Observation
import SwiftUI

// MARK: - Backend shapes

/// `credentials.status`: whether each stored reference reads back, and the last four
/// characters of each readable key. `pending` while a credential change is still running.
struct CredentialReport: Decodable, Equatable {
    let pending: Bool
    let references: [String: String]?
    let tails: [String: String]?
}

/// One `models.health` row: consecutive transient failures of a profile and its cooldown.
struct ModelHealth: Decodable, Equatable {
    let profileId: String
    let generation: Int
    let failures: Int
    let cooldownUntil: String?
    let errorKind: String?
    let checkedAt: String
}

/// `targets.bot_impact`: the digests (and separately sent X accounts) a Bot receives.
struct BotImpact: Decodable, Equatable {
    struct Account: Decodable, Equatable { let id: String; let lastTarget: Bool }
    /// The configuration revision this impact describes.
    let revision: Int
    let subscriptions: [String]
    let lastTargetSubscriptions: [String]
    let accounts: [Account]
}

/// `bots.test_send` / `bots.test_status`: `confirmed`, `failed`, `outcome_unknown`,
/// `inflight` or `not_started`.
struct TestSend: Decodable, Equatable {
    let requestId: String
    let generation: Int
    let state: String
    let reason: String?
}

/// The newspaper and media policies as the extras group shows them; saving edits the full
/// stored settings document.
struct ExtraSettings: Equatable {
    var newspaperOn = false
    var newspaperProfile: String?
    var newspaperVision: String?
    var transcriptionProfile: String?
}

/// One capability check of one model.
struct CapabilityCheck: Equatable {
    let profile: String
    let capability: String
}

/// What an extra's row shows: off, working, still being checked, or the first check that blocks it.
enum ExtraStatus: Equatable {
    case off, usable
    case waiting(CapabilityCheck)
    /// Checked for an earlier key or model (`stale`): nothing checks it again by itself.
    case unchecked(CapabilityCheck)
    case failed(CapabilityCheck, ProbeState)

    static func of(on: Bool, checks: [CapabilityCheck], states: [String: [String: ProbeState]], working: Set<String>) -> ExtraStatus {
        guard on else { return .off }
        for check in checks {
            guard !working.contains(KeyChecks.key(check.profile, check.capability)),
                  let state = states[check.profile]?[check.capability] else { return .waiting(check) }
            if state.state == "stale" { return .unchecked(check) }
            guard state.settled else { return .waiting(check) }
            if !state.passed { return .failed(check, state) }
        }
        return .usable
    }
}

/// This month's spending, the limits that apply, and today's X reads (`budget.get`).
struct BudgetSummary: Equatable {
    struct Part: Equatable { let operation: String; let amount: Int }
    /// A limit other than the monthly total and the X daily reads (contract §2: kept, listed, clearable).
    struct Limit: Equatable, Identifiable {
        enum Kind: Equatable { case image, provider(String), partition(String), account(String) }
        let kind: Kind
        let value: Int
        let used: Int
        var id: String {
            switch kind {
            case .image: "image"
            case let .provider(name): "provider." + name
            case let .partition(name): "partition." + name
            case let .account(name): "account." + name
            }
        }
        /// Money limits are in micro-dollars; X limits count reads.
        var money: Bool {
            switch kind {
            case .image, .provider: true
            case .partition, .account: false
            }
        }
    }

    var monthlyLimit: Int?
    var used = 0
    var parts: [Part] = []
    var since: Date?
    var unpriced = 0
    var dailyReads: Int?
    var readsToday = 0
    var limits: [Limit] = []

    private struct Reply: Decodable {
        struct Document: Decodable {
            struct Model: Decodable {
                let monthlyLimit: Int?
                let imageLimit: Int?
                let providerLimits: [String: Int?]
            }
            struct X: Decodable {
                let dailyLimit: Int?
                let partitionLimits: [String: Int?]
                let accountLimits: [String: Int?]
            }
            let model: Model
            let x: X
        }
        struct Report: Decodable { let periods: [Period] }
        struct Period: Decodable {
            struct Scope: Decodable { let limit: Int?; let used: Int }
            struct Scopes: Decodable {
                let total: Scope
                let image: Scope?
                let providers: [String: Scope]?
                let partitions: [String: Scope]?
                let accounts: [String: Scope]?
            }
            struct Operation: Decodable { let knownSettled: Int; let held: Int }
            let meter, start, end: String
            let knownSettled, held, unpriced: Int
            let operations: [String: Operation]?
            let scopes: Scopes
        }
        let document: Document
        let report: Report
    }

    init() {}

    /// Reads a `budget.get` result; the current period of each meter is the one containing `now`.
    init(_ data: Data, now: Date) throws {
        let reply: Reply = try BackendRPC.decode(data)
        let current = reply.report.periods.filter { period in
            guard let start = OverviewData.date(period.start), let end = OverviewData.date(period.end) else { return false }
            return start <= now && now < end
        }
        let model = current.first { $0.meter == "model" }
        let x = current.first { $0.meter == "x" }
        let limits = reply.document
        monthlyLimit = limits.model.monthlyLimit
        used = model.map { $0.knownSettled + $0.held } ?? 0
        parts = (model?.operations ?? [:]).map { Part(operation: $0.key, amount: $0.value.knownSettled + $0.value.held) }
            .filter { $0.amount > 0 }
            .sorted { ($0.amount, $1.operation) > ($1.amount, $0.operation) }
        since = model.flatMap { OverviewData.date($0.start) }
        unpriced = model?.unpriced ?? 0
        dailyReads = limits.x.dailyLimit
        readsToday = x?.scopes.total.used ?? 0
        var others: [Limit] = []
        if let value = limits.model.imageLimit {
            others.append(Limit(kind: .image, value: value, used: model?.scopes.image?.used ?? 0))
        }
        for (name, value) in limits.model.providerLimits.sorted(by: { $0.key < $1.key }) {
            guard let value else { continue }
            others.append(Limit(kind: .provider(name), value: value, used: model?.scopes.providers?[name]?.used ?? 0))
        }
        for name in ["normal", "adult"] {
            guard let value = limits.x.partitionLimits[name] ?? nil else { continue }
            others.append(Limit(kind: .partition(name), value: value, used: x?.scopes.partitions?[name]?.used ?? 0))
        }
        for (name, value) in limits.x.accountLimits.sorted(by: { $0.key < $1.key }) {
            guard let value else { continue }
            others.append(Limit(kind: .account(name), value: value, used: x?.scopes.accounts?[name]?.used ?? 0))
        }
        self.limits = others
    }

    /// Whole dollars typed by the owner as stored micro-dollars; empty means no limit.
    /// `nil` when the text is not a whole number of dollars.
    static func microDollars(_ text: String) -> Int?? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
        if trimmed.isEmpty { return .some(nil) }
        guard let dollars = Int(trimmed), dollars >= 0, dollars <= 9_000_000_000 else { return nil }
        return .some(dollars * 1_000_000)
    }

    /// A whole count of reads per day; empty means no limit.
    static func reads(_ text: String) -> Int?? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .some(nil) }
        guard let count = Int(trimmed), count >= 0, count <= 9_007_199_254_740_992 else { return nil }
        return .some(count)
    }

    /// A stored micro-dollar limit as the field shows it: whole dollars, or empty for no limit.
    static func dollarField(_ micro: Int?) -> String {
        guard let micro else { return "" }
        return micro % 1_000_000 == 0 ? String(micro / 1_000_000) : String(format: "%.2f", Double(micro) / 1_000_000)
    }
}

/// Whether the X key works, from the newest account check made with the current key.
struct XCheck: Equatable {
    let state: String
    let observedAt: String?
    /// The X key reference the check was made with.
    var reference: String? = nil
}

// MARK: - State and actions

/// Everything the Connect page reads and edits (interaction-spec §6). Every configuration
/// change goes through `EditorState` or a revisioned operation retried once after a
/// background change, so nothing the backend changed meanwhile is overwritten.
@MainActor @Observable
final class ConnectData {
    // Bots
    private(set) var pairings: [String: BotPairing] = [:]
    /// The inline "add a Bot" form at the top, while it is open.
    private(set) var adding: BotPairing?
    private(set) var tests: [String: TestSend] = [:]
    private(set) var testedAt: [String: Date] = [:]
    private(set) var impacts: [String: BotImpact] = [:]
    /// Bots whose token field is open (an error to fix, or "Replace Token" chosen).
    var replacingToken: Set<String> = []

    // Models
    let keys = KeyChecks()
    private(set) var credentialStates: [String: String] = [:]
    private(set) var tails: [String: String] = [:]
    private(set) var health: [String: ModelHealth] = [:]
    private(set) var extras = ExtraSettings()

    // Spending and X
    private(set) var budget: BudgetSummary?
    private(set) var xCheck: XCheck?

    private(set) var working: Set<String> = []
    private(set) var failures: [String: BackendError] = [:]
    private(set) var savedAt: [String: Date] = [:]
    private(set) var loaded = false

    @ObservationIgnored var pollInterval: Duration = .seconds(2) {
        didSet {
            keys.pollInterval = pollInterval
            adding?.pollInterval = pollInterval
            for pairing in pairings.values { pairing.pollInterval = pollInterval }
        }
    }

    init() {
        // A saved key's status is read back quickly, so it changes within two seconds.
        keys.pollInterval = .seconds(1)
    }

    func isBusy(_ key: String) -> Bool { working.contains(key) }
    func dismiss(_ key: String) { failures[key] = nil }

    // MARK: Loading

    /// Reads the keys, checks, cooldowns, extras, spending and X state. Each part keeps its last
    /// good value when its read fails; a failed read of the main parts is shown once on the page.
    func load(model: AppModel, now: Date = Date()) async {
        let client = model.client
        failures["load"] = nil
        syncReceipts(model.bots)
        do {
            let report: CredentialReport = try BackendRPC.decode(await client.call(.credentialsStatus))
            // While a key is being stored the backend does not read the Keychain; keep the last view.
            if !report.pending {
                credentialStates = report.references ?? [:]
                tails = report.tails ?? [:]
            }
            for profile in model.config?.modelProfiles ?? [] where !keys.working.contains(profile.id) {
                await keys.load(profile.id, model: model)
            }
            struct Health: Decodable { let profiles: [ModelHealth] }
            let rows: Health = try BackendRPC.decode(await client.call(.modelsHealth))
            // A profile's newest generation is the one its current key runs under.
            health = Dictionary(rows.profiles.map { ($0.profileId, $0) }) { $0.generation >= $1.generation ? $0 : $1 }
            budget = try BudgetSummary(await client.call(.budgetGet), now: now)
        } catch {
            failures["load"] = BackendError.wrapping(error)
        }
        if let paper = try? await client.call(.newspaperPolicy), let media = try? await client.call(.mediaPolicy) {
            extras = Self.extras(paper: paper, media: media)
        }
        if let accounts = try? await client.call(.xAccountsList) {
            xCheck = Self.xCheck(accounts, reference: model.config?.xApi?.credentialRef)
        } else if xCheck?.reference != model.config?.xApi?.credentialRef {
            xCheck = nil
        }
        loaded = true
    }

    nonisolated static func extras(paper: Data, media: Data) -> ExtraSettings {
        struct Paper: Decodable {
            struct Settings: Decodable { let enabled: Bool; let generationProfile: String?; let visionProfile: String? }
            let settings: Settings
        }
        struct Media: Decodable {
            struct Settings: Decodable { let sttProfile: String? }
            let settings: Settings
        }
        var extras = ExtraSettings()
        if let paper: Paper = try? BackendRPC.decode(paper) {
            extras.newspaperOn = paper.settings.enabled
            extras.newspaperProfile = paper.settings.generationProfile
            extras.newspaperVision = paper.settings.visionProfile
        }
        if let media: Media = try? BackendRPC.decode(media) { extras.transcriptionProfile = media.settings.sttProfile }
        return extras
    }

    /// The newest account check made with the stored X key (`x.accounts.list`).
    nonisolated static func xCheck(_ data: Data, reference: String?) -> XCheck? {
        struct Directory: Decodable {
            struct Account: Decodable { let state: String; let observedAt: String? }
            let credentialConfigured: Bool
            let accounts: [Account]
        }
        guard reference != nil, let directory: Directory = try? BackendRPC.decode(data), directory.credentialConfigured else { return nil }
        // An account checked with an earlier key reads `credential_changed`; it says nothing about this key.
        let checked = directory.accounts.filter { $0.observedAt != nil && !["unverified", "credential_changed"].contains($0.state) }
        guard let newest = checked.max(by: { ($0.observedAt ?? "") < ($1.observedAt ?? "") }) else { return nil }
        return XCheck(state: newest.state, observedAt: newest.observedAt, reference: reference)
    }

    /// The last four characters of the key behind a reference, when the Keychain returned it.
    func tail(_ reference: String?) -> String? { reference.flatMap { tails[$0] } }

    /// The X account check that speaks for this key: one made with another key says nothing.
    func xCheck(for reference: String?) -> XCheck? {
        guard let xCheck, reference != nil, xCheck.reference == reference else { return nil }
        return xCheck
    }

    /// The failure of the last test-message action, for the Bot as it is now.
    func testFailure(_ id: String, generation: Int?) -> BackendError? {
        if let sent = testGenerations[id], let generation, sent != generation { return nil }
        return failures["test." + id]
    }

    /// The binding generation each Bot's last test action was made at.
    private(set) var testGenerations: [String: Int] = [:]

    /// A new token or pairing makes the last test's receipt, its failure and its note obsolete;
    /// they go together, so nothing of the earlier binding is shown or retried.
    func syncReceipts(_ bots: [BotStatus]) {
        for (id, sent) in testGenerations {
            guard let current = bots.first(where: { $0.id == id })?.generation, current != sent else { continue }
            dropReceipt(id)
        }
    }

    private func dropReceipt(_ id: String) {
        tests[id] = nil
        testedAt[id] = nil
        testGenerations[id] = nil
        failures["test." + id] = nil
        stillUnknown.remove(id)
    }

    /// The cooldown row of the profile's current generation; one from an earlier key or model
    /// does not apply (`model_runner._health_block` reads the current generation only).
    func currentHealth(_ profile: String) -> ModelHealth? {
        guard let row = health[profile] else { return nil }
        guard let generation = keys.generations[profile] else { return row }
        return row.generation == generation ? row : nil
    }

    /// `available`, `missing`, or the Keychain error for a stored reference; nil without one.
    func credentialState(_ reference: String?) -> String? {
        guard let reference else { return nil }
        return credentialStates[reference] ?? "available"
    }

    // MARK: Bots: adding, pairing, tokens

    func startAdding() {
        guard adding == nil else { return }
        let pairing = BotPairing()
        pairing.pollInterval = pollInterval
        adding = pairing
    }

    /// Closes the add form. A Bot entry created for a token Telegram refused is removed again,
    /// so a failed attempt leaves nothing behind; a checked Bot stays in the list to pair later.
    func cancelAdding(model: AppModel) async {
        guard let pairing = adding, !working.contains("adding") else { return }
        working.insert("adding")
        defer { working.remove("adding") }
        failures["adding"] = nil
        // Still connecting: the attempt removes what it created at its next step; wait for it.
        let midway = pairing.working
        if midway {
            pairing.cancel()
            while pairing.working { try? await Task.sleep(for: .milliseconds(20)) }
        }
        // A Bot the attempt created and did not finish is deleted before the form closes; if that
        // fails, the form stays with the reason so cancelling can be tried again.
        if let id = pairing.botId, midway || pairing.bot?.verified != true {
            do {
                try await deleteBot(id, model: model)
            } catch {
                failures["adding"] = BackendError.wrapping(error)
                await model.refresh()
                return
            }
        } else if let id = pairing.botId {
            pairings[id] = pairing
        }
        adding = nil
        await model.refresh()
    }

    /// The add form's Bot was paired: it moves into the list with its pairing time.
    func finishAdding() {
        guard let pairing = adding, let id = pairing.botId, pairing.paired else { return }
        pairings[id] = pairing
        adding = nil
    }

    func pairing(_ id: String) -> BotPairing? { pairings[id] }

    /// The checks an extra needs to be usable.
    func extraChecks(newspaper: Bool) -> [CapabilityCheck] {
        if newspaper {
            // A newspaper is made by the generation model and checked by the vision model
            // (`Newspapers._profiles`); both checks must pass.
            guard let generation = extras.newspaperProfile else { return [] }
            return [CapabilityCheck(profile: generation, capability: "image"),
                    CapabilityCheck(profile: extras.newspaperVision ?? generation, capability: "vision")]
        }
        return extras.transcriptionProfile.map { [CapabilityCheck(profile: $0, capability: "stt")] } ?? []
    }

    /// What the header's test button does now.
    enum TestAction: Equatable { case send, check }
    /// While the last message's outcome is open, the header checks it instead of sending another.
    func headerTestAction(_ id: String, generation: Int?) -> TestAction {
        ["outcome_unknown", "inflight"].contains(receipt(id, generation: generation)?.state ?? "") ? .check : .send
    }

    /// The last test message's receipt, for the Bot as it is now: a receipt from an earlier
    /// binding (another token, a new pairing) says nothing about this one.
    func receipt(_ id: String, generation: Int?) -> TestSend? {
        guard let test = tests[id], generation == nil || test.generation == generation else { return nil }
        return test
    }

    /// The retry offered under a failed test-message action.
    /// While it is unknown whether the last message arrived, retrying reads that message's
    /// receipt again (same request id); only a message known not to have arrived is sent anew.
    func retryTest(_ id: String, model: AppModel) async {
        syncReceipts(model.bots)
        let current = model.bots.first { $0.id == id }?.generation
        if ["outcome_unknown", "inflight"].contains(receipt(id, generation: current)?.state ?? "") {
            await checkTest(id, model: model)
        } else {
            await sendTest(id, model: model)
        }
    }

    private func ensurePairing(_ id: String, model: AppModel) -> BotPairing {
        if let existing = pairings[id] { return existing }
        let pairing = BotPairing(botId: id, bot: model.bots.first { $0.id == id })
        pairing.pollInterval = pollInterval
        pairings[id] = pairing
        return pairing
    }

    /// A pairing code for a checked Bot (first time, after unpairing, or after the old one expired).
    func newCode(_ id: String, model: AppModel) async {
        await ensurePairing(id, model: model).newCode(model: model)
    }

    /// Checks an existing Bot's stored token with Telegram again.
    func reverify(_ id: String, model: AppModel) async {
        await ensurePairing(id, model: model).reverify(model: model)
    }

    /// A new token for an existing Bot: stored, checked, and a pairing code issued.
    func replaceToken(_ id: String, token: String, model: AppModel) async {
        let pairing = ensurePairing(id, model: model)
        await pairing.connect(token: token, model: model)
        if pairing.failure == nil { replacingToken.remove(id) }
        syncReceipts(model.bots)
    }

    // MARK: Bots: test message

    /// Sends one test message. A reply that never came is kept as unknown so it can be checked.
    func sendTest(_ id: String, model: AppModel) async {
        let key = "test." + id
        guard !working.contains(key) else { return }
        working.insert(key)
        defer { working.remove(key) }
        failures[key] = nil
        tests[id] = nil
        // A new message has its own receipt; "still unknown" was about the earlier one.
        stillUnknown.remove(id)
        var request: TestSend?
        do {
            let status: BotStatus = try BackendRPC.decode(await model.client.call(.botsStatus, ["bot_id": id]))
            testGenerations[id] = status.generation
            let identity = BackendClient.requestId("test")
            request = TestSend(requestId: identity, generation: status.generation ?? 0, state: "inflight", reason: nil)
            let result: TestSend = try BackendRPC.decode(await model.client.call(.botsTestSend, [
                "bot_id": id, "generation": status.generation ?? 0, "request_id": identity,
            ]))
            record(id, result)
        } catch {
            let failure = BackendError.wrapping(error)
            // Unless the backend refused before contacting Telegram, the message may have gone
            // out: keep its request id so "Check Result" reads that receipt, never a new send.
            if let request, !(error is BackendError && Self.refusedBeforeSending.contains(failure.code)) {
                tests[id] = TestSend(requestId: request.requestId, generation: request.generation, state: "outcome_unknown", reason: nil)
                if !(error is SocketFailure) { failures[key] = failure }
            } else {
                failures[key] = failure
            }
        }
    }

    /// What `bots.test_send` refuses before recording or sending anything (`check_send.TestSends.send`,
    /// `registry.snapshot`, the control request check): nothing went out.
    nonisolated static let refusedBeforeSending: Set<String> = [
        "invalid_test_request", "invalid_request", "unknown_operation", "service_stopping", "request_id_conflict",
        "missing_bot", "unregistered_bot", "binding_not_ready", "binding_changed", "credential_unavailable", "send_lane_busy",
    ]

    /// Reads the backend's record of the last test message (`bots.test_status`).
    func checkTest(_ id: String, model: AppModel) async {
        let key = "test." + id
        guard let test = tests[id], !working.contains(key) else { return }
        working.insert(key)
        defer { working.remove(key) }
        failures[key] = nil
        do {
            let result: TestSend = try BackendRPC.decode(await model.client.call(.botsTestStatus, [
                "bot_id": id, "generation": test.generation, "request_id": test.requestId,
            ]))
            record(id, result, checked: true)
        } catch {
            failures[key] = BackendError.wrapping(error)
        }
    }

    /// Whether the last check of an unknown test message still could not tell.
    private(set) var stillUnknown: Set<String> = []

    private func record(_ id: String, _ result: TestSend, checked: Bool = false) {
        tests[id] = result
        testedAt[id] = Date()
        if checked, result.state == "outcome_unknown" { stillUnknown.insert(id) } else { stillUnknown.remove(id) }
        if result.state == "failed", let reason = result.reason {
            failures["test." + id] = BackendError(code: reason, domain: "bots")
        }
    }

    // MARK: Bots: pause, resume, unpair, delete, adult, name

    /// `pause`, `resume` or `unbind`, at the Bot's current generation.
    func act(_ id: String, _ action: String, model: AppModel) async {
        let key = "bot." + id
        guard !working.contains(key) else { return }
        working.insert(key)
        defer { working.remove(key) }
        failures[key] = nil
        do {
            let status: BotStatus = try BackendRPC.decode(await model.client.call(.botsStatus, ["bot_id": id]))
            _ = try await model.client.call(.botsAction, [
                "bot_id": id, "action": action, "generation": status.generation ?? 0,
            ])
            // Any code shown before is void now (the backend clears pairing on every action).
            pairings[id] = nil
            if action == "unbind" { tests[id] = nil }
        } catch {
            failures[key] = BackendError.wrapping(error)
        }
        await model.refresh()
    }

    /// What deleting a Bot (or turning off its adult content) would change.
    func loadImpact(_ id: String, model: AppModel) async -> BotImpact? {
        do {
            let impact: BotImpact = try BackendRPC.decode(await model.client.call(.targetsBotImpact, ["bot_id": id]))
            impacts[id] = impact
            failures["bot." + id] = nil
            return impact
        } catch {
            failures["bot." + id] = BackendError.wrapping(error)
            return nil
        }
    }

    /// How a confirmed change ended: done, refused because what the owner confirmed changed
    /// meanwhile (the new state is loaded and has to be confirmed again), or failed.
    enum Outcome: Equatable { case done, changed, failed }

    /// Deletes a Bot and removes it from every digest (`targets.delete_bot`).
    /// Deletes at the revision of the impact the owner confirmed; if the configuration changed
    /// since, nothing is deleted, the new impact is loaded and has to be confirmed again.
    @discardableResult
    func delete(_ id: String, model: AppModel) async -> Outcome {
        let key = "bot." + id
        guard !working.contains(key) else { return .failed }
        guard let impact = impacts[id] else {
            _ = await loadImpact(id, model: model)
            return .changed
        }
        working.insert(key)
        defer { working.remove(key) }
        failures[key] = nil
        do {
            _ = try await model.client.call(.targetsDeleteBot, ["bot_id": id, "revision": impact.revision])
            pairings[id] = nil
            tests[id] = nil
            impacts[id] = nil
            await model.refresh()
            return .done
        } catch let error as BackendError where error.isConflict {
            working.remove(key)
            _ = await loadImpact(id, model: model)
            await model.refresh()
            return .changed
        } catch {
            failures[key] = BackendError.wrapping(error)
            await model.refresh()
            return .failed
        }
    }

    /// Removes a Bot the add form created and did not finish (no impact was shown for it).
    private func deleteBot(_ id: String, model: AppModel) async throws {
        try await model.client.discardBot(id)
    }

    /// Allows or stops adult content for a Bot; stopping also removes it from adult digests.
    /// With `revision` (the configuration the owner's list of affected digests came from), the
    /// change applies only to that configuration; if it changed, nothing is saved and the caller
    /// asks again with the new list. Without it (allowing adult content removes nothing), the
    /// newest revision is used.
    @discardableResult
    func setAdult(_ id: String, _ allowed: Bool, model: AppModel, revision: Int? = nil) async -> Outcome {
        let key = "adult." + id
        guard !working.contains(key) else { return .failed }
        working.insert(key)
        defer { working.remove(key) }
        failures[key] = nil
        var outcome = Outcome.done
        do {
            if let revision {
                _ = try await model.client.call(.targetsAdultPermission, ["bot_id": id, "allowed": allowed, "revision": revision])
            } else {
                try await revisioned(model) { revision in
                    _ = try await model.client.call(.targetsAdultPermission, ["bot_id": id, "allowed": allowed, "revision": revision])
                }
            }
            savedAt[key] = Date()
        } catch let error as BackendError where error.isConflict && revision != nil {
            outcome = .changed
        } catch {
            failures[key] = BackendError.wrapping(error)
            outcome = .failed
        }
        await model.refresh()
        return outcome
    }

    /// Adult digests (and adult X accounts) that send to this Bot now and would lose it.
    nonisolated static func adultTargets(_ id: String, config: AppConfig) -> [String] {
        let adult = Set(config.categories.filter { $0.partition == "adult" }.map(\.id))
        return config.subscriptions.filter { adult.contains($0.categoryId) && ($0.botIds ?? []).contains(id) }.map(\.id)
    }

    /// Renames a Bot (its name in NewsPaw; the Telegram username stays).
    func rename(_ id: String, to name: String, model: AppModel) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "name." + id
        guard !name.isEmpty, name.count <= 150 else { return }
        working.insert(key)
        defer { working.remove(key) }
        let editor = EditorState(client: model.client)
        if await editor.apply({ document in
            var document = document
            document["bots"] = (document["bots"] as? [[String: Any]] ?? []).map { bot in
                guard bot["id"] as? String == id else { return bot }
                var bot = bot
                bot["name"] = name
                return bot
            }
            return document
        }) {
            failures[key] = nil
            savedAt[key] = editor.savedAt
        } else {
            failures[key] = editor.failure
        }
        await model.refresh()
    }

    /// Runs a revisioned change against the newest configuration revision, once more after a
    /// background change.
    private func revisioned(_ model: AppModel, _ body: (Int) async throws -> Void) async throws {
        for attempt in 0..<2 {
            let revision = try await model.client.configDocument().revision
            do {
                try await body(revision)
                return
            } catch let error as BackendError where error.isConflict && attempt == 0 {
                continue
            }
        }
    }

    // MARK: Models

    /// Saves a model key; the backend checks it by itself and the row reads the result back.
    func saveKey(_ key: String, profile: String, model: AppModel) async {
        await keys.save(key, profile: profile, model: model)
        await load(model: model)
        await recheckExtras(profile, model: model)
    }

    /// A new key or model makes the enabled extras' checks of that model stale, and the backend
    /// re-checks only text: check them again here (new probe ids, same confirmation rule).
    func recheckExtras(_ profile: String, model: AppModel) async {
        var checks: [CapabilityCheck] = []
        if extras.newspaperOn { checks += extraChecks(newspaper: true) }
        if extras.transcriptionProfile != nil { checks += extraChecks(newspaper: false) }
        var seen = Set<String>()
        for check in checks where check.profile == profile && seen.insert(check.capability).inserted {
            guard ["stale", "untested"].contains(keys.states[profile]?[check.capability]?.state ?? "untested") else { continue }
            await keys.recheck(profile, model: model, capability: check.capability)
        }
    }

    /// Checks the saved key again (also "check and retry" after an unknown result, once confirmed).
    func recheck(_ profile: String, model: AppModel, capability: String = "text", confirmed: Bool = false) async {
        await keys.recheck(profile, model: model, capability: capability, confirmed: confirmed)
        await load(model: model)
    }

    /// Whether checking this key again could repeat a charge whose result never came back
    /// (one rule for this page and the first-run window).
    func needsConfirmation(_ profile: String, capability: String = "text") -> Bool {
        keys.needsConfirmation(profile, capability: capability)
    }

    /// Points a model at another OpenAI-compatible address or model ID, then checks its key.
    func saveEndpoint(_ profile: String, baseURL: String, modelId: String, model: AppModel) async {
        let baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelId = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "endpoint." + profile
        guard !baseURL.isEmpty, !modelId.isEmpty, !working.contains(key) else { return }
        working.insert(key)
        defer { working.remove(key) }
        let editor = EditorState(client: model.client)
        let saved = await editor.apply { document in
            var document = document
            document["model_profiles"] = (document["model_profiles"] as? [[String: Any]] ?? []).map { entry in
                guard entry["id"] as? String == profile else { return entry }
                var entry = entry
                entry["base_url"] = baseURL
                entry["model"] = modelId
                return entry
            }
            return document
        }
        if saved {
            failures[key] = nil
            savedAt[key] = editor.savedAt
            await model.refresh()
            // A changed model or address makes the earlier check stale; a saved key is checked again.
            if model.config?.modelProfiles.first(where: { $0.id == profile })?.credentialRef != nil {
                await keys.recheck(profile, model: model)
            }
            await load(model: model)
            await recheckExtras(profile, model: model)
        } else {
            failures[key] = editor.failure
        }
        await load(model: model)
    }

    // MARK: Extras

    /// Turns the AI newspaper on with a model (it generates the page and checks it), or off.
    func setNewspaper(_ on: Bool, profile: String?, model: AppModel) async {
        let client = model.client
        await saveExtra("newspaper", model: model, editor: EditorState(
            load: { try BackendClient.record(await client.call(.newspaperPolicy), field: "settings") },
            store: { _ = try await client.call(.newspaperConfigure, ["settings": $0, "revision": $1]) }
        )) { settings in
            var settings = settings
            settings["enabled"] = on
            if let profile {
                settings["generation_profile"] = profile
                if settings["vision_profile"] == nil || settings["vision_profile"] is NSNull { settings["vision_profile"] = profile }
                if settings["backup_profile"] as? String == profile { settings["backup_profile"] = NSNull() }
            }
            return settings
        }
    }

    /// Chooses the model that transcribes voice messages, or none (off).
    func setTranscription(_ profile: String?, model: AppModel) async {
        let client = model.client
        await saveExtra("transcription", model: model, editor: EditorState(
            load: { try BackendClient.record(await client.call(.mediaPolicy), field: "settings") },
            store: { _ = try await client.call(.mediaConfigure, ["settings": $0, "revision": $1]) }
        )) { settings in
            var settings = settings
            settings["stt_profile"] = profile ?? NSNull()
            // Without a model the amount must be empty too; with one the backend fills its default.
            if profile == nil { settings["stt_hold"] = NSNull() }
            return settings
        }
    }

    private func saveExtra(_ key: String, model: AppModel, editor: EditorState, change: @escaping EditorState.Change) async {
        guard !working.contains(key) else { return }
        working.insert(key)
        defer { working.remove(key) }
        if await editor.apply(change) {
            failures[key] = nil
            savedAt[key] = editor.savedAt
            await load(model: model)
            // Turning an extra on starts automatic checks of its models; follow those by their id.
            let checks = key == "newspaper" ? (extras.newspaperOn ? extraChecks(newspaper: true) : [])
                : (extras.transcriptionProfile != nil ? extraChecks(newspaper: false) : [])
            for check in checks {
                await keys.trackAutomatic(check.profile, capability: check.capability, model: model)
            }
            await keys.resume(model: model)
        } else {
            failures[key] = editor.failure
        }
        await load(model: model)
    }

    // MARK: Spending

    /// Saves the monthly limit typed in whole dollars (empty: no limit).
    @discardableResult
    func saveMonthlyLimit(_ text: String, model: AppModel) async -> Bool {
        guard let value = BudgetSummary.microDollars(text) else {
            failures["budget.monthly"] = BackendError(code: "invalid_amount", domain: "budget")
            return false
        }
        return await saveBudget("budget.monthly", model: model) { document in
            var document = document
            var limits = document["model"] as? [String: Any] ?? [:]
            limits["monthly_limit"] = value ?? NSNull()
            document["model"] = limits
            return document
        }
    }

    /// Saves the X reads per day (empty: no limit).
    @discardableResult
    func saveDailyReads(_ text: String, model: AppModel) async -> Bool {
        guard let value = BudgetSummary.reads(text) else {
            failures["budget.daily"] = BackendError(code: "invalid_count", domain: "budget")
            return false
        }
        return await saveBudget("budget.daily", model: model) { document in
            var document = document
            var limits = document["x"] as? [String: Any] ?? [:]
            limits["daily_limit"] = value ?? NSNull()
            document["x"] = limits
            return document
        }
    }

    /// Clears one of the other limits.
    @discardableResult
    func clear(_ limit: BudgetSummary.Limit, model: AppModel) async -> Bool {
        await saveBudget("budget." + limit.id, model: model) { document in
            var document = document
            var money = document["model"] as? [String: Any] ?? [:]
            var reads = document["x"] as? [String: Any] ?? [:]
            switch limit.kind {
            case .image:
                money["image_limit"] = NSNull()
            case let .provider(name):
                var table = money["provider_limits"] as? [String: Any] ?? [:]
                table.removeValue(forKey: name)
                money["provider_limits"] = table
            case let .partition(name):
                // Both partitions stay listed; no limit is null.
                var table = reads["partition_limits"] as? [String: Any] ?? [:]
                table[name] = NSNull()
                reads["partition_limits"] = table
            case let .account(name):
                var table = reads["account_limits"] as? [String: Any] ?? [:]
                table.removeValue(forKey: name)
                reads["account_limits"] = table
            }
            document["model"] = money
            document["x"] = reads
            return document
        }
    }

    private func saveBudget(_ key: String, model: AppModel, change: @escaping EditorState.Change) async -> Bool {
        guard !working.contains(key) else { return false }
        working.insert(key)
        defer { working.remove(key) }
        let client = model.client
        let editor = EditorState(
            load: { try BackendClient.record(await client.call(.budgetGet), field: "document") },
            store: { _ = try await client.call(.budgetSave, ["document": $0, "revision": $1]) }
        )
        let saved = await editor.apply(change)
        if saved {
            failures[key] = nil
            savedAt[key] = editor.savedAt
        } else {
            failures[key] = editor.failure
        }
        await load(model: model)
        return saved
    }

    // MARK: X

    /// Saves the X API key.
    func saveXKey(_ key: String, model: AppModel) async {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !working.contains("x") else { return }
        working.insert("x")
        defer { working.remove("x") }
        failures["x"] = nil
        do {
            try await model.client.setCredential(kind: "x_api", id: "x", value: key)
            savedAt["x"] = Date()
        } catch {
            failures["x"] = BackendError.wrapping(error)
        }
        await model.refresh()
        await load(model: model)
    }
}
