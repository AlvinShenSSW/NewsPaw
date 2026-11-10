import AppKit
import SwiftUI

// MARK: - Page

/// Ordinary | adult accounts, the add row, the account list, the digest summary, reads per day
/// and the advanced extras (interaction-spec §7). Adult accounts are only ever listed, added and
/// routed on the adult side.
struct XAccountsPage: View {
    let model: AppModel
    @State private var data: XAccountsData
    @State private var partition: String

    init(model: AppModel, partition: String = "normal", data: XAccountsData = XAccountsData()) {
        self.model = model
        _partition = State(initialValue: partition)
        _data = State(initialValue: data)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.text(L10n.XAccounts.intro)).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let failure = data.failures["load"] {
                FailureNote(model: model, failure: failure) { Task { await data.load(model: model) } }
            }
            notices
            if let failure = data.failures["rules"] {
                XRetryNote(model: model, what: L10n.XAccounts.rulesLeft, failure: failure) {
                    Task { await data.retryRuleCleanup(model: model) }
                }
            }
            XAddRow(model: model, data: data, partition: partition, blocked: addBlocked)
            XAccountList(model: model, data: data, partition: partition)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    XDigestCard(model: model, data: data, partition: partition)
                    XReadsCard(model: model, data: data)
                }
                VStack(alignment: .leading, spacing: 14) {
                    XDigestCard(model: model, data: data, partition: partition)
                    XReadsCard(model: model, data: data)
                }
            }
            XAdvanced(model: model, data: data, partition: partition)
        }
        .task(id: model.configRevision) { await data.load(model: model) }
        .task {
            // Reads, coverage and alert results change without a configuration change.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await data.load(model: model)
                // A rule cleanup left pending by a failed read is finished once reads work again.
                if data.hasPendingRuleCleanup { await data.retryRuleCleanup(model: model) }
            }
        }
        .onChange(of: partition) { data.outcome = nil }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(model.text(L10n.XAccounts.kind), selection: $partition) {
                    Text(L10n.XAccounts.normalTab(model.uiLanguage, ["count": String(data.accounts(in: "normal").count)])).tag("normal")
                    Text(L10n.XAccounts.adultTab(model.uiLanguage, ["count": String(data.accounts(in: "adult").count)])).tag("adult")
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityIdentifier("x-partition")
            }
        }
    }

    /// Adding needs the X key, and on the adult side an adult model key (spec §7.1).
    private var addBlocked: Bool { !data.keyConfigured || (partition == "adult" && !model.adultModelReady) }

    @ViewBuilder private var notices: some View {
        // Only a directory read that worked can say there is no key (a failed read is shown above).
        if data.loaded, data.failures["load"] == nil, !data.keyConfigured {
            XNotice(model: model, text: L10n.XAccounts.needsXKey, action: L10n.XAccounts.goConnect) { model.page = .connect }
        }
        if partition == "adult", !model.adultModelReady {
            XNotice(model: model, text: L10n.XAccounts.needsAdultKey, action: L10n.XAccounts.goConnect) { model.page = .connect }
        }
    }
}

/// A step that failed after the main change was saved: what is left over, why, and a retry
/// that repeats only that step.
private struct XRetryNote: View {
    let model: AppModel
    let what: Words
    let failure: BackendError
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).accessibilityHidden(true)
            Text(model.text(what) + " " + FailureCopy.message(for: failure, model.uiLanguage))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(model.text(L10n.Shell.retry), action: retry)
        }
        .font(.callout)
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

/// A yellow line with one way to fix it.
private struct XNotice: View {
    let model: AppModel
    let text: Words
    let action: Words
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            Text(model.text(text)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(model.text(action), action: perform)
        }
        .font(.callout)
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

/// The partition word ("普通账号" / "成人博主").
@MainActor private func kindName(_ partition: String, _ model: AppModel) -> String {
    model.text(partition == "adult" ? L10n.XAccounts.adultKind : L10n.XAccounts.normalKind)
}

/// What the owner does about a failure, when the copy offers an action.
/// What the owner does about a failure, when the copy offers an action: fix the X key or a
/// limit in Connect, else `retry` — which repeats the failed step. Without a step to repeat there
/// is no button (a button that only hides the note would be a lie).
@MainActor private func fix(_ failure: BackendError, model: AppModel, retry: (() -> Void)?) -> (() -> Void)? {
    let keyProblems: Set<String> = ["credential_missing", "authentication_failed", "permission_denied", "x_limit", "partition_limit", "account_limit"]
    return keyProblems.contains(failure.code) ? { model.page = .connect } : retry
}

// MARK: - Add row (§7.2)

private struct XAddRow: View {
    let model: AppModel
    let data: XAccountsData
    let partition: String
    let blocked: Bool
    @State private var text = ""

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(model.text(L10n.XAccounts.add)).fontWeight(.medium)
                    TextField(model.text(L10n.XAccounts.addPlaceholder), text: $text)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                        .disabled(blocked)
                        .accessibilityLabel(model.text(L10n.XAccounts.addPlaceholder))
                    if data.isBusy("add") {
                        ProgressView().controlSize(.small)
                        Text(model.text(L10n.XAccounts.reading)).foregroundStyle(.secondary)
                    } else {
                        Button(model.text(L10n.XAccounts.add), action: add)
                            .buttonStyle(.borderedProminent)
                            .disabled(blocked || XAccountsData.entry(text) == nil)
                    }
                }
                Text(model.text(L10n.XAccounts.addNote)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if data.slow.contains("add"), data.outcomePartition == partition {
                    Text(model.text(L10n.XAccounts.stillGoing)).font(.caption).foregroundStyle(.secondary)
                }
                // An add made on the other side (the owner switched meanwhile) is not shown here.
                if let outcome = data.outcome(in: partition) { result(outcome) }
                if let failure = data.failures["add"], data.outcomePartition == partition { FailureNote(model: model, failure: failure) }
            }
            .padding(4)
        }
    }

    private func add() {
        guard !blocked, XAccountsData.entry(text) != nil else { return }
        let value = text
        Task {
            await data.add(value, partition: partition, model: model)
            if case .failed = data.outcome {} else { text = "" }
        }
    }

    private func handle(_ id: String) -> String { data.account(id).map { "@" + $0.handle } ?? "" }

    @ViewBuilder private func result(_ outcome: XAddOutcome) -> some View {
        let language = model.uiLanguage
        switch outcome {
        case let .added(id):
            line("checkmark.circle.fill", .green, L10n.XAccounts.added(language, ["handle": handle(id)]))
        case let .protected(id):
            HStack(spacing: 8) {
                line("lock.fill", .orange, L10n.XAccounts.protectedResult(language, ["handle": handle(id)]))
                Spacer(minLength: 8)
                Button(model.text(L10n.XAccounts.keepAnyway)) { data.keep(id) }
                Button(model.text(L10n.XAccounts.discard)) { Task { await data.discard(id, model: model) } }
            }
        case let .missing(name):
            line("xmark.circle.fill", .red, L10n.XAccounts.missingResult(language, ["handle": "@" + name]))
        case let .exists(id):
            line("info.circle.fill", .secondary, L10n.XAccounts.alreadyListed(language, ["handle": handle(id)]))
        case let .otherPartition(name, other):
            line("info.circle.fill", .secondary, L10n.XAccounts.inOtherKind(language, [
                "name": name.allSatisfy(\.isNumber) ? name : "@" + name, "kind": kindName(other, model),
            ]))
        case let .failed(failure, draft):
            FailureNote(model: model, failure: failure, action: fix(failure, model: model, retry: draft.map { draft in
                { Task { await data.retryAdd(draft, partition: partition, model: model) } }
            }))
        case let .listFailed(failure, id):
            FailureNote(model: model, failure: failure, action: fix(failure, model: model) {
                Task { await data.retryList(id, model: model) }
            })
        case let .cleanupFailed(failure, _, then):
            VStack(alignment: .leading, spacing: 6) {
                AnyView(result(then))
                XRetryNote(model: model, what: L10n.XAccounts.draftLeft, failure: failure) {
                    Task { await data.retryCleanup(model: model) }
                }
            }
        case let .list(id):
            if let list = data.lists.first(where: { $0.id == id }) {
                HStack(spacing: 8) {
                    line("list.bullet.rectangle", .accentColor, L10n.XAccounts.listResult(language, [
                        "name": list.name ?? id, "count": String(list.members.count),
                    ]))
                    Spacer(minLength: 8)
                    Button(model.text(L10n.XAccounts.add)) { Task { await data.adoptMembers(id, model: model) } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func line(_ symbol: String, _ color: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Account list (§7.3)

private struct XAccountList: View {
    let model: AppModel
    let data: XAccountsData
    let partition: String

    var body: some View {
        let accounts = data.accounts(in: partition)
        let lists = data.lists(in: partition)
        let waiting = partition == "normal" ? data.unclassified : []
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                if accounts.isEmpty, lists.isEmpty, waiting.isEmpty {
                    Text(model.text(partition == "adult" ? L10n.XAccounts.emptyAdult : L10n.XAccounts.emptyNormal))
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                    if index > 0 { Divider() }
                    XAccountRow(model: model, data: data, account: account)
                }
                ForEach(lists) { list in
                    if !accounts.isEmpty || list.id != lists.first?.id { Divider() }
                    XListRow(model: model, data: data, list: list)
                }
                ForEach(waiting) { account in
                    if !accounts.isEmpty || !lists.isEmpty || account.id != waiting.first?.id { Divider() }
                    XWaitingRow(model: model, data: data, account: account)
                }
            }
            .padding(2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct Avatar: View {
    let text: String
    let adult: Bool
    var square = false

    var body: some View {
        Group {
            if square {
                Image(systemName: "list.bullet").font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background((adult ? Color.purple : Color.accentColor).opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
            } else {
                Text(String(text.prefix(1)).uppercased()).font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background((adult ? Color.purple : Color.accentColor).opacity(0.15), in: Circle())
            }
        }
        .foregroundStyle(adult ? Color.purple : Color.accentColor)
        .accessibilityHidden(true)
    }
}

private struct XAccountRow: View {
    let model: AppModel
    let data: XAccountsData
    let account: XAccountItem
    @State private var editing = false
    @State private var confirmRemove = false
    @State private var confirmJoin = false
    @State private var moving: XPartitionImpact?

    private var state: XAccountState { XAccountState(account.state) }
    private var partition: String { account.partition ?? "normal" }
    private var other: String { partition == "adult" ? "normal" : "adult" }
    private var digest: AppConfig.Subscription? {
        model.config?.subscriptions.first { $0.id == account.subscriptionId } ?? model.config?.xDigest(partition)
    }
    private var working: Bool { data.isBusy("route." + account.id) || data.isBusy("verify." + account.id) || data.isBusy("move." + account.id) || data.isBusy("remove." + account.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Avatar(text: account.handle, adult: partition == "adult")
                VStack(alignment: .leading, spacing: 2) {
                    Text("@" + account.handle).fontWeight(.medium)
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    // A gap in what was read stays visible (other states say why it is not read).
                    if state == .readable, let gap = data.activity[account.id]?.gap {
                        Label(model.text(gap.words), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 8)
                StatusDot(color: state.color, text: model.text(state.words), busy: working)
                if [.recheck, .unverified].contains(state), !data.isBusy("verify." + account.id) {
                    Button(model.text(L10n.XAccounts.readAgain)) { Task { await data.reverify(account.id, model: model) } }
                        .buttonStyle(.link)
                }
                if [.noPermission, .keyRejected].contains(state) {
                    Button(model.text(L10n.XAccounts.goConnect)) { model.page = .connect }.buttonStyle(.link)
                }
                if state.removable {
                    Button(model.text(L10n.XAccounts.remove)) { askRemove() }
                        .disabled(working)
                } else {
                    modeSwitch
                }
                menu
            }
            ForEach(["route.", "verify.", "move.", "remove."], id: \.self) { prefix in
                if let failure = data.failures[prefix + account.id] {
                    FailureNote(model: model, failure: failure, action: fix(failure, model: model, retry: retry(prefix)))
                }
            }
            if data.slow.contains("verify." + account.id) {
                Text(model.text(L10n.XAccounts.stillGoing)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(background, in: RoundedRectangle(cornerRadius: 6))
        .confirmationDialog(L10n.XAccounts.joinTitle(model.uiLanguage, ["handle": "@" + account.handle]), isPresented: $confirmJoin) {
            Button(model.text(L10n.XAccounts.inDigest), role: .destructive) { Task { await data.joinDigest(account.id, model: model) } }
            Button(model.text(L10n.Shell.cancel), role: .cancel) {}
        } message: {
            Text(L10n.XAccounts.rulesDropped(model.uiLanguage, ["count": String(data.rulesOn(account.id) ?? 0)]))
        }
        .confirmationDialog(L10n.XAccounts.removeTitle(model.uiLanguage, ["handle": "@" + account.handle]), isPresented: $confirmRemove) {
            Button(model.text(L10n.XAccounts.remove), role: .destructive) { Task { await data.remove(account.id, model: model) } }
            Button(model.text(L10n.Shell.cancel), role: .cancel) {}
        } message: {
            Text(removeImpact)
        }
        .confirmationDialog(L10n.XAccounts.moveTitle(model.uiLanguage, ["handle": "@" + account.handle, "kind": kindName(other, model)]),
                            isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } }), presenting: moving) { impact in
            Button(model.text(L10n.XAccounts.moveButton), role: .destructive) {
                Task {
                    // Changed meanwhile: ask again with what the move would change now.
                    if !(await data.move(account.id, to: other, impact: impact, model: model)),
                       data.failures["move." + account.id]?.isConflict == true {
                        moving = data.impacts[account.id]
                    }
                }
            }
            Button(model.text(L10n.Shell.cancel), role: .cancel) {}
        } message: { impact in
            Text(moveImpact(impact))
        }
    }

    /// Removal is confirmed with the rules it drops, so they are read first (unreadable: not asked).
    private func askRemove() {
        Task {
            guard await data.rulesBeforeChange(account.id, key: "remove." + account.id, model: model) != nil else { return }
            confirmRemove = true
        }
    }

    /// "Try Again" repeats what failed: the last digest change, or the read. A refused move or
    /// removal has nothing to repeat without asking again, so it offers no button.
    private func retry(_ prefix: String) -> (() -> Void)? {
        switch prefix {
        case "route.": data.canRetryRoute(account.id) ? { Task { await data.retryRoute(account.id, model: model) } } : nil
        case "verify.": { Task { await data.reverify(account.id, model: model) } }
        default: nil
        }
    }

    private var background: Color {
        if data.highlighted == account.id { return Color.accentColor.opacity(0.10) }
        if state == .protected { return Color.orange.opacity(0.07) }
        return .clear
    }

    // MARK: Summary line

    private var summary: String {
        let language = model.uiLanguage
        switch state {
        case .protected: return model.text(L10n.XAccounts.protectedNote)
        case .gone: return model.text(L10n.XAccounts.goneNote)
        default: break
        }
        var parts = [typesText(account.types, language)]
        if let activity = data.activity[account.id] {
            if let read = activity.lastRead {
                parts.append(L10n.XAccounts.lastRead(language, ["when": Stamp.relative(read, language)]))
            }
            if let count = activity.newToday {
                parts.append(L10n.XAccounts.newToday(language, ["count": String(count) + (activity.capped ? "+" : "")]))
            }
        } else if account.observedAt == nil {
            parts.append(model.text(L10n.XAccounts.notReadYet))
        }
        if account.sendsAlone, let recipients = recipients, !recipients.isEmpty {
            parts.append(model.recipientsLine(recipients))
        }
        if account.subscriptionId == nil { parts.append(model.text(L10n.XAccounts.notInDigest)) }
        return parts.joined(separator: " · ")
    }

    /// The Bots its own digest goes to: its own choice, else its digest's (routing.py).
    private var recipients: [String]? { account.botIds ?? digest?.botIds }

    // MARK: Send alone / in the digest

    private var aloneLabel: String {
        guard account.sendsAlone, let time = account.times?.first ?? digest?.times.first else { return model.text(L10n.XAccounts.alone) }
        return L10n.XAccounts.aloneAt(model.uiLanguage, ["time": time])
    }

    private var modeSwitch: some View {
        HStack(spacing: 0) {
            segment(aloneLabel, selected: account.sendsAlone) { editing = true }
                .popover(isPresented: $editing, arrowEdge: .bottom) {
                    XAlonePopover(model: model, data: data, account: account, digest: digest) { editing = false }
                }
            segment(model.text(L10n.XAccounts.inDigest), selected: account.inDigest) {
                guard !account.inDigest else { return }
                // Alert rules on an account sent alone go with that choice: ask first.
                guard account.sendsAlone else {
                    Task { await data.joinDigest(account.id, model: model) }
                    return
                }
                Task {
                    // Unknown rules are read first; unreadable, nothing changes (the reason is shown).
                    guard let rules = await data.rulesBeforeChange(account.id, key: "route." + account.id, model: model) else { return }
                    if rules > 0 { confirmJoin = true } else { await data.joinDigest(account.id, model: model) }
                }
            }
        }
        .padding(2)
        .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
        // Busy while any change to this row runs (a move, a removal), not only a send choice.
        .disabled(digest == nil || working)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.text(L10n.XAccounts.sendChoice))
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.callout.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(selected ? Color(nsColor: .controlBackgroundColor) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                .shadow(color: selected ? .black.opacity(0.12) : .clear, radius: 0.5, y: 0.5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: More

    private var menu: some View {
        Menu {
            Menu(model.text(L10n.XAccounts.postTypes)) {
                ForEach(XPostType.all, id: \.self) { type in
                    Toggle(model.text(typeWord(type)), isOn: Binding(
                        get: { account.types.contains(type) },
                        set: { on in Task { await data.setPostType(account.id, type, on: on, model: model) } }
                    ))
                    .disabled(account.types == [type])
                }
            }
            .disabled(digest == nil)
            Button(model.text(L10n.XAccounts.readAgainMenu)) { Task { await data.reverify(account.id, model: model) } }
            Button(L10n.XAccounts.moveMenu(model.uiLanguage, ["kind": kindName(other, model)])) {
                Task {
                    guard await data.rulesBeforeChange(account.id, key: "move." + account.id, model: model) != nil else { return }
                    moving = await data.loadImpact(account.id, model: model)
                }
            }
            Divider()
            Button(model.text(L10n.XAccounts.removeMenu), role: .destructive) { askRemove() }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(working)
        .accessibilityLabel(L10n.XAccounts.moreFor(model.uiLanguage, ["handle": "@" + account.handle]))
    }

    // MARK: Confirmations

    private var removeImpact: String {
        let language = model.uiLanguage
        var lines = [model.text(L10n.XAccounts.removeBody)]
        if account.sendsAlone, let time = account.times?.first ?? digest?.times.first {
            lines.append(L10n.XAccounts.removeAlone(language, ["time": time, "bots": model.recipientsLine(recipients ?? [])]))
        }
        if let rules = data.rulesOn(account.id), rules > 0 { lines.append(L10n.XAccounts.rulesDropped(language, ["count": String(rules)])) }
        return lines.joined(separator: "\n")
    }

    private func moveImpact(_ impact: XPartitionImpact) -> String {
        let language = model.uiLanguage
        let from = kindName(partition, model)
        var lines: [String] = []
        if impact.aggregate {
            lines.append(L10n.XAccounts.moveLeavesDigest(language, ["kind": from, "bots": model.recipientsLine(impact.aggregateBotIds)]))
        }
        if impact.special {
            lines.append(L10n.XAccounts.moveStopsAlone(language, ["bots": model.recipientsLine(impact.specialBotIds)]))
        }
        if impact.clearsPostTypes { lines.append(model.text(L10n.XAccounts.moveResetsTypes)) }
        if impact.cachedPosts > 0 { lines.append(L10n.XAccounts.moveKeepsPosts(language, ["count": String(impact.cachedPosts), "kind": from])) }
        if impact.pendingJobs > 0 { lines.append(L10n.XAccounts.movePending(language, ["count": String(impact.pendingJobs)])) }
        if let rules = data.rulesOn(account.id), rules > 0 { lines.append(L10n.XAccounts.rulesDropped(language, ["count": String(rules)])) }
        lines.append(L10n.XAccounts.moveJoins(language, ["kind": kindName(other, model)]))
        return lines.joined(separator: "\n")
    }
}

func typeWord(_ type: String) -> Words {
    switch type {
    case "original": L10n.XAccounts.typeOriginal
    case "quoted": L10n.XAccounts.typeQuote
    case "replied_to": L10n.XAccounts.typeReply
    default: L10n.XAccounts.typeRepost
    }
}

func typesText(_ types: [String], _ language: AppLanguage) -> String {
    XPostType.all.filter(types.contains).map { typeWord($0)(language) }.joined(separator: " + ")
}

/// "单独发": time, Bots (the digest's by default) and style for the account's own digest.
private struct XAlonePopover: View {
    let model: AppModel
    let data: XAccountsData
    let account: XAccountItem
    let digest: AppConfig.Subscription?
    let close: () -> Void
    @State private var time = DigestTimes.parse("20:30")!
    @State private var bots: Set<String> = []
    @State private var style = "text"

    private var category: String { digest?.categoryId ?? (account.partition == "adult" ? "x_adult" : "x") }
    private var usable: [String] { model.usableBots(for: category) }
    private var inherited: [String] { digest?.botIds ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.XAccounts.aloneTitle(model.uiLanguage, ["handle": "@" + account.handle])).font(.headline)
            HStack(spacing: 8) {
                Text(model.text(L10n.Digests.times)).frame(width: 70, alignment: .trailing)
                DatePicker(model.text(L10n.Digests.times), selection: $time, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.stepperField)
                    .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                    .environment(\.locale, Locale(identifier: "en_GB"))
            }
            HStack(alignment: .top, spacing: 8) {
                Text(model.text(L10n.Digests.sendTo)).frame(width: 70, alignment: .trailing)
                VStack(alignment: .leading, spacing: 4) {
                    if usable.isEmpty {
                        Text(model.text(account.partition == "adult" ? L10n.XAccounts.noAdultBot : L10n.XAccounts.noBot))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(usable, id: \.self) { id in
                        Toggle(botName(id), isOn: Binding(
                            get: { bots.contains(id) },
                            set: { if $0 { bots.insert(id) } else { bots.remove(id) } }
                        ))
                        .toggleStyle(.checkbox)
                    }
                    Text(model.text(L10n.XAccounts.botsInherit)).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Text(model.text(L10n.Digests.style)).frame(width: 70, alignment: .trailing)
                Picker(model.text(L10n.Digests.style), selection: $style) {
                    Text(model.text(L10n.Digests.styleText)).tag("text")
                    Text(model.text(L10n.Digests.styleImage)).tag("source_image")
                    if data.newspaperReady || style == "newspaper" { Text(model.text(L10n.Digests.stylePaper)).tag("newspaper") }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Text(model.text(L10n.XAccounts.aloneNote)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(model.text(L10n.Shell.cancel), role: .cancel, action: close).keyboardShortcut(.cancelAction)
                // Only Bots that can still receive it count (one may have stopped meanwhile).
                let none = XAccountsData.aloneBots(bots, usable: usable).isEmpty
                Button(model.text(L10n.Connect.save)) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(none)
                    .help(none ? model.text(L10n.XAccounts.chooseBot) : "")
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear(perform: fill)
    }

    private func botName(_ id: String) -> String {
        model.bots.first { $0.id == id }.map { $0.username.map { "@" + $0 } ?? $0.name } ?? id
    }

    private func fill() {
        let current = (account.sendsAlone ? account.times?.first : nil) ?? digest?.times.first ?? "20:30"
        time = DigestTimes.parse(current) ?? time
        let chosen = (account.sendsAlone ? account.botIds : nil) ?? inherited
        bots = Set(chosen.filter(usable.contains))
        style = (account.sendsAlone ? account.style : nil) ?? digest?.style ?? "text"
    }

    private func save() {
        // The digest's own Bots and style stay inherited, so a later change there follows here too.
        // Only Bots that can still receive it (one may have stopped allowing adult content meanwhile).
        let chosen = XAccountsData.aloneBots(bots, usable: usable)
        guard !chosen.isEmpty else { return }
        let ownBots: [String]? = Set(chosen) == Set(inherited) ? nil : chosen
        let ownStyle: String? = style == (digest?.style ?? "text") ? nil : style
        let value = DigestTimes.format(time)
        close()
        Task { await data.sendAlone(account.id, time: value, bots: ownBots, style: ownStyle, model: model) }
    }
}

// MARK: - Lists and accounts waiting for a kind

private struct XListRow: View {
    let model: AppModel
    let data: XAccountsData
    let list: XListItem
    @State private var showing = false

    var body: some View {
        let pending = data.pending(list)
        let outside = data.notInDigest(list)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Avatar(text: list.name ?? "L", adult: list.partition == "adult", square: true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(list.name ?? "List " + list.id).fontWeight(.medium)
                        Text("· " + L10n.XAccounts.memberCount(model.uiLanguage, ["count": String(list.members.count)]))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    // Says "all members are in the digest" only when they are.
                    Text(model.text(data.listNote(list)))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                if !pending.isEmpty {
                    StatusDot(color: .orange, text: L10n.XAccounts.pendingMembers(model.uiLanguage, ["count": String(pending.count)]),
                              busy: data.isBusy("list." + list.id))
                    Button(model.text(L10n.XAccounts.view)) { showing = true }
                        .popover(isPresented: $showing, arrowEdge: .bottom) {
                            XMembersPopover(model: model, data: data, list: list)
                        }
                } else if !outside.isEmpty {
                    StatusDot(color: .orange, text: L10n.XAccounts.membersOutside(model.uiLanguage, ["count": String(outside.count)]),
                              busy: data.isBusy("list." + list.id))
                    Button(model.text(L10n.XAccounts.inDigest)) { Task { await data.adoptMembers(list.id, key: "list." + list.id, model: model) } }
                        .disabled(data.isBusy("list." + list.id))
                } else {
                    StatusDot(color: stateColor, text: model.text(stateWords), busy: data.isBusy("list." + list.id))
                }
                Menu {
                    Button(model.text(L10n.XAccounts.readMembers)) { Task { await data.refreshList(list.id, model: model) } }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(data.isBusy("list." + list.id))
                .accessibilityLabel(L10n.XAccounts.moreFor(model.uiLanguage, ["handle": list.name ?? list.id]))
            }
            if let failure = data.failures["list." + list.id] {
                FailureNote(model: model, failure: failure, action: fix(failure, model: model) {
                    Task { await data.refreshList(list.id, model: model) }
                })
            }
            if data.slow.contains("list." + list.id) {
                Text(model.text(L10n.XAccounts.stillGoing)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
    }

    private var stateColor: Color {
        switch list.state {
        case "ready" where list.current: .green
        case "unverified": .gray
        case "credential_changed", "partial", "rate_limited", "outcome_unknown", "interrupted": .orange
        case "ready": .orange
        default: .red
        }
    }

    private var stateWords: Words {
        switch list.state {
        case "ready" where list.current: L10n.XAccounts.listRead
        case "unverified": L10n.XAccounts.listUnread
        case "private": L10n.XAccounts.listPrivate
        case "unavailable": L10n.XAccounts.stateGone
        case "permission_denied": L10n.XAccounts.stateNoPermission
        case "authentication_failed": L10n.XAccounts.stateKeyRejected
        case "credential_changed", "ready": L10n.XAccounts.stateRecheck
        default: L10n.XAccounts.listIncomplete
        }
    }
}

/// New List members, each to be made ordinary, adult, or left out.
private struct XMembersPopover: View {
    let model: AppModel
    let data: XAccountsData
    let list: XListItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.XAccounts.membersTitle(model.uiLanguage, ["name": list.name ?? list.id])).font(.headline)
            Text(model.text(L10n.XAccounts.membersNote)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(data.pending(list)) { member in
                        HStack(spacing: 8) {
                            Text("@" + member.handle)
                            Spacer(minLength: 8)
                            if data.isBusy("member." + member.id) { ProgressView().controlSize(.small) }
                            Button(model.text(L10n.XAccounts.normalKind)) { Task { await data.choose(member.id, partition: "normal", model: model) } }
                            Button(model.text(L10n.XAccounts.adultKind)) { Task { await data.choose(member.id, partition: "adult", model: model) } }
                            Button(model.text(L10n.XAccounts.ignore)) { Task { await data.choose(member.id, partition: nil, model: model) } }
                        }
                        .disabled(data.isBusy("member." + member.id))
                        if let failure = data.failures["member." + member.id] { FailureNote(model: model, failure: failure) }
                    }
                    if data.pending(list).isEmpty {
                        Text(model.text(L10n.XAccounts.membersDone)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(16)
        .frame(width: 420)
    }
}

/// An account in neither kind yet (added before kinds were required): one choice, then it joins.
private struct XWaitingRow: View {
    let model: AppModel
    let data: XAccountsData
    let account: XAccountItem
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Avatar(text: account.handle, adult: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text("@" + account.handle).fontWeight(.medium)
                    Text(model.text(L10n.XAccounts.waitingNote)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if data.isBusy("member." + account.id) { ProgressView().controlSize(.small) }
                Button(model.text(L10n.XAccounts.normalKind)) { Task { await data.choose(account.id, partition: "normal", model: model) } }
                Button(model.text(L10n.XAccounts.adultKind)) { Task { await data.choose(account.id, partition: "adult", model: model) } }
                Button(model.text(L10n.XAccounts.remove)) { confirmRemove = true }
            }
            .disabled(data.isBusy("member." + account.id))
            if let failure = data.failures["member." + account.id] ?? data.failures["remove." + account.id] {
                FailureNote(model: model, failure: failure)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .confirmationDialog(L10n.XAccounts.removeTitle(model.uiLanguage, ["handle": "@" + account.handle]), isPresented: $confirmRemove) {
            Button(model.text(L10n.XAccounts.remove), role: .destructive) { Task { await data.remove(account.id, model: model) } }
            Button(model.text(L10n.Shell.cancel), role: .cancel) {}
        } message: {
            Text(model.text(L10n.XAccounts.removeBody))
        }
    }
}

// MARK: - Digest summary and reads (§7.4)

private struct XDigestCard: View {
    let model: AppModel
    let data: XAccountsData
    let partition: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.text(partition == "adult" ? L10n.XAccounts.adultDigest : L10n.XAccounts.normalDigest)).font(.headline)
                .accessibilityAddTraits(.isHeader)
            GroupBox {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(firstLine).fontWeight(.medium)
                        Text(secondLine).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let digest {
                        Button(model.text(L10n.XAccounts.editInDigests)) {
                            model.openDigest = digest.id
                            model.page = .digests
                        }
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var digest: AppConfig.Subscription? { model.config?.xDigest(partition) }

    private var firstLine: String {
        guard let digest else { return model.text(L10n.XAccounts.noDigest) }
        let language = model.uiLanguage
        let times = digest.times.isEmpty ? "--:--" : digest.times.joined(separator: "、")
        let target = model.botsPhrase(digest.botIds ?? []) ?? "· " + model.text(L10n.Digests.noTarget)
        let line = L10n.Digests.everyDay(language, ["times": times]) + " " + target
        return digest.enabled ? line : model.text(L10n.Digests.offPrefix) + " · " + line
    }

    private var secondLine: String {
        guard let digest, let config = model.config else { return "" }
        let language = model.uiLanguage
        var parts = [L10n.XAccounts.aggregateCount(language, ["count": String(config.aggregateAccounts(digest).count)])]
        let lists = data.lists(in: partition).count
        if lists > 0 { parts[0] += " + " + L10n.XAccounts.listCount(language, ["count": String(lists)]) }
        let style: Words = switch digest.style {
        case "source_image": L10n.Digests.styleImage
        case "newspaper": L10n.Digests.stylePaper
        default: L10n.Digests.styleText
        }
        parts.append(model.text(style))
        return parts.joined(separator: " · ")
    }
}

private struct XReadsCard: View {
    let model: AppModel
    let data: XAccountsData
    @State private var text = ""
    /// Only what the owner typed is saved; a field that merely had focus never clears a limit.
    @State private var edited = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.text(L10n.XAccounts.readsTitle)).font(.headline).accessibilityAddTraits(.isHeader)
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField(model.text(L10n.Connect.noLimit), text: Binding(get: { text }, set: { if $0 != text { text = $0; edited = true } }))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .focused($focused)
                            .onSubmit(save)
                            .accessibilityLabel(model.text(L10n.XAccounts.readsTitle))
                        Text(L10n.XAccounts.readsLine(model.uiLanguage, ["count": String(budget.readsToday)]))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        if data.isBusy("budget.daily") {
                            ProgressView().controlSize(.small)
                        } else if let at = data.savedAt["budget.daily"] {
                            Text(L10n.Shell.savedAt(model.uiLanguage, ["time": Stamp.clock(at)])).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let limit = budget.dailyReads, limit > 0 {
                        ProgressView(value: min(Double(budget.readsToday), Double(limit)), total: Double(limit))
                            .tint(budget.readsToday >= limit ? .red : .accentColor)
                            .accessibilityLabel(model.text(L10n.XAccounts.readsTitle))
                            .accessibilityValue("\(budget.readsToday) / \(limit)")
                    }
                    Text(model.text(L10n.XAccounts.readsNote)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let failure = data.failures["budget.daily"] {
                        FailureNote(model: model, failure: failure)
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: fill)
        .onChange(of: data.budget) { fill() }
        .onChange(of: focused) { old, _ in if old { save() } }
    }

    private var budget: BudgetSummary { data.budget ?? BudgetSummary() }

    private func fill() {
        guard !edited, let budget = data.budget else { return }
        text = budget.dailyReads.map(String.init) ?? ""
    }

    private func save() {
        guard edited, let budget = data.budget else { return }
        edited = false
        guard text != (budget.dailyReads.map(String.init) ?? "") else { return }
        Task { if !(await data.saveDailyReads(text, model: model)) { edited = true } }
    }
}

// MARK: - Advanced (§7.5)

private struct XAdvanced: View {
    let model: AppModel
    let data: XAccountsData
    let partition: String
    @AppStorage("x.advancedOpen") private var open = false

    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $open) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.text(L10n.XAccounts.advancedNote)).font(.caption).foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                    Divider()
                    XAlertsBlock(model: model, data: data, partition: partition)
                    if partition == "normal" {
                        Divider()
                        XVideoBlock(model: model, data: data)
                    }
                    Divider()
                    XPartitionLimits(model: model, data: data)
                }
            } label: {
                Text(model.text(L10n.XAccounts.advancedTitle)).fontWeight(.semibold)
            }
            .accessibilityValue(model.text(open ? L10n.Digests.collapse : L10n.Digests.edit))
            .padding(4)
        }
    }
}

private struct XAlertsBlock: View {
    let model: AppModel
    let data: XAccountsData
    let partition: String
    @State private var phrase = ""
    @State private var scope = ""

    private var digests: [AppConfig.Subscription] {
        model.config?.subscriptions.filter { $0.categoryId == (partition == "adult" ? "x_adult" : "x") } ?? []
    }
    private var policy: XAlertPolicy { data.alerts ?? XAlertPolicy() }
    private var rules: [XAlertRule] { policy.rules.filter { rule in digests.contains { $0.id == rule.subscriptionId } } }
    /// Rule scopes: the digest itself, or one of its accounts sent alone (x/alerts.py).
    private var scopes: [(id: String, title: String)] {
        guard let digest = model.config?.xDigest(partition) else { return [] }
        let alone = data.accounts(in: partition).filter { $0.sendsAlone && $0.subscriptionId == digest.id }
        return [("", model.text(L10n.XAccounts.ruleDigest))] + alone.map { ($0.id, "@" + $0.handle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.text(L10n.XAccounts.alerts))
                    Text(L10n.XAccounts.alertsNote(model.uiLanguage, ["count": String(policy.dailyLimit > 0 ? policy.dailyLimit : XAccountsData.defaultAlertsPerDay)]))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                saved("alerts")
                Toggle(model.text(L10n.XAccounts.alerts), isOn: Binding(
                    get: { policy.enabled },
                    set: { on in Task { await data.setAlerts(on, model: model) } }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(data.alerts == nil || (policy.rules.isEmpty && !policy.enabled) || data.isBusy("alerts"))
                .help(policy.rules.isEmpty ? model.text(L10n.XAccounts.alertsNeedRule) : "")
            }
            ForEach(rules) { rule in
                HStack(spacing: 8) {
                    Image(systemName: "bell").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("「" + rule.phrase + "」")
                    Text(scopeTitle(rule)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await data.removeRule(rule, model: model) }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(model.text(L10n.XAccounts.removeRule) + " " + rule.phrase)
                    .disabled(data.isBusy("alerts"))
                }
            }
            HStack(spacing: 8) {
                TextField(model.text(L10n.XAccounts.rulePlaceholder), text: $phrase)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addRule)
                    .accessibilityLabel(model.text(L10n.XAccounts.rulePlaceholder))
                Picker(model.text(L10n.XAccounts.ruleScope), selection: $scope) {
                    ForEach(scopes, id: \.id) { Text($0.title).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
                Button(model.text(L10n.XAccounts.addRule), action: addRule)
                    .disabled(!canAdd)
            }
            if let failure = data.failures["alerts"] {
                FailureNote(model: model, failure: failure)
            }
        }
        .padding(.vertical, 10)
        // Another side, or the chosen account joined the digest: back to the whole digest.
        .onChange(of: scopes.map(\.id)) { if chosenScope == nil { scope = "" } }
    }

    private var canAdd: Bool {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 2 && trimmed.count <= 100 && policy.rules.count < 20 && model.config?.xDigest(partition) != nil && !data.isBusy("alerts")
            && chosenScope != nil
    }

    /// The chosen scope if it is still offered (an account that joined the digest, or one from the
    /// other side, is not); nil otherwise.
    private var chosenScope: String? { XAccountsData.ruleScope(scope, among: scopes.map(\.id).filter { !$0.isEmpty }) }

    private func addRule() {
        guard canAdd, let digest = model.config?.xDigest(partition), let chosen = chosenScope else { return }
        let rule = XAlertRule(subscriptionId: digest.id, accountId: chosen.isEmpty ? nil : chosen,
                              phrase: phrase.trimmingCharacters(in: .whitespacesAndNewlines))
        Task { if await data.addRule(rule, model: model) { phrase = "" } }
    }

    private func scopeTitle(_ rule: XAlertRule) -> String {
        guard let id = rule.accountId else { return model.text(L10n.XAccounts.ruleDigest) }
        return data.account(id).map { "@" + $0.handle } ?? id
    }

    @ViewBuilder private func saved(_ key: String) -> some View {
        if data.isBusy(key) {
            ProgressView().controlSize(.small)
        } else if let at = data.savedAt[key] {
            Text(L10n.Shell.savedAt(model.uiLanguage, ["time": Stamp.clock(at)])).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct XVideoBlock: View {
    let model: AppModel
    let data: XAccountsData
    @State private var budgetText = ""
    @State private var edited = false
    @State private var confirming: XVideoCandidate?
    @FocusState private var focused: Bool

    private var policy: XVideoPolicy { data.video ?? XVideoPolicy() }
    private var ready: Bool {
        let models = XAccountsData.videoModels(model.config)
        return !models.vision.isEmpty && !models.speech.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.text(L10n.XAccounts.video))
                    Text(model.text(L10n.XAccounts.videoNote)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if data.isBusy("video") { ProgressView().controlSize(.small) }
                Toggle(model.text(L10n.XAccounts.video), isOn: Binding(
                    get: { policy.enabled },
                    set: { on in Task { await data.setVideo(on, model: model) } }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(data.video == nil || (!ready && !policy.enabled) || data.isBusy("video"))
                .help(ready ? "" : model.text(L10n.XAccounts.videoNeedsModels))
            }
            if !ready, !policy.enabled {
                HStack(spacing: 8) {
                    Text(model.text(L10n.XAccounts.videoNeedsModels)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(model.text(L10n.XAccounts.goConnect)) { model.page = .connect }.buttonStyle(.link).font(.caption)
                }
            }
            if let failure = data.failures["video"] { FailureNote(model: model, failure: failure) }
            if policy.enabled {
                HStack(spacing: 8) {
                    Text(model.text(L10n.XAccounts.videoBudget))
                    Spacer()
                    if data.isBusy("video.budget") { ProgressView().controlSize(.small) }
                    Text("$")
                    TextField("1", text: Binding(get: { budgetText }, set: { if $0 != budgetText { budgetText = $0; edited = true } }))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                        .focused($focused)
                        .onSubmit(saveBudget)
                        .accessibilityLabel(model.text(L10n.XAccounts.videoBudget))
                    Text(model.text(L10n.XAccounts.perDayMoney)).foregroundStyle(.secondary)
                }
                if let failure = data.failures["video.budget"] {
                    FailureNote(model: model, failure: failure)
                }
                candidates
            }
        }
        .padding(.vertical, 10)
        .onAppear(perform: fill)
        .onChange(of: data.video) { fill() }
        .onChange(of: focused) { old, _ in if old { saveBudget() } }
        .confirmationDialog(model.text(L10n.XAccounts.inspectTitle), isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            presenting: confirming) { candidate in
            Button(model.text(L10n.XAccounts.inspect)) { Task { await data.inspect(candidate, model: model) } }
            Button(model.text(L10n.Shell.cancel), role: .cancel) {}
        } message: { _ in
            Text(model.text(L10n.XAccounts.inspectBody))
        }
    }

    @ViewBuilder private var candidates: some View {
        if data.candidates.isEmpty {
            Text(model.text(L10n.XAccounts.noVideos)).font(.caption).foregroundStyle(.secondary)
        } else {
            ForEach(data.candidates.prefix(5)) { candidate in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(candidate.title).lineLimit(1)
                            Text("@" + candidate.author).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if data.isBusy("video." + candidate.id) {
                            ProgressView().controlSize(.small)
                        } else if candidate.requestId != nil {
                            Button(model.text(L10n.XAccounts.viewResult)) { Task { await data.inspect(candidate, model: model) } }
                        } else {
                            Button(model.text(L10n.XAccounts.inspect)) { confirming = candidate }
                        }
                    }
                    if let failure = data.failures["video." + candidate.id] { FailureNote(model: model, failure: failure) }
                    if let result = data.inspections[candidate.id] { XVideoResultView(model: model, result: result) }
                }
            }
        }
    }

    private func fill() {
        guard !edited, let video = data.video else { return }
        budgetText = BudgetSummary.dollarField(video.dailyModelLimit > 0 ? video.dailyModelLimit : nil)
    }

    private func saveBudget() {
        guard edited, let video = data.video, video.enabled else { return }
        edited = false
        guard budgetText != BudgetSummary.dollarField(video.dailyModelLimit) else { return }
        Task { if !(await data.saveVideoBudget(budgetText, model: model)) { edited = true } }
    }
}

private struct XVideoResultView: View {
    let model: AppModel
    let result: XVideoResult
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array((result.frames ?? []).enumerated()), id: \.offset) { _, frame in
                    Text(String(format: "%.0f s · ", frame.second) + frame.observation).font(.caption)
                }
                if let transcript = result.transcript {
                    Text(model.text(L10n.XAccounts.transcript)).font(.caption.bold())
                    Text(transcript).font(.caption).textSelection(.enabled)
                }
                ForEach(Array(Set(result.gaps ?? [])).sorted(), id: \.self) { gap in
                    Text(FailureCopy.message(for: BackendError(code: gap, domain: "x"), model.uiLanguage)).font(.caption).foregroundStyle(.secondary)
                }
            }
        } label: {
            Text(model.text(result.state == "complete" ? L10n.XAccounts.videoDone : L10n.XAccounts.videoPartial)).font(.caption)
        }
    }
}

private struct XPartitionLimits: View {
    let model: AppModel
    let data: XAccountsData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.text(L10n.XAccounts.partitionLimits))
            Text(model.text(L10n.XAccounts.partitionLimitsNote)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            XPartitionLimitRow(model: model, data: data, partition: "normal")
            XPartitionLimitRow(model: model, data: data, partition: "adult")
        }
        .padding(.vertical, 10)
    }
}

private struct XPartitionLimitRow: View {
    let model: AppModel
    let data: XAccountsData
    let partition: String
    @State private var text = ""
    @FocusState private var focused: Bool

    @State private var edited = false

    private var key: String { "budget." + partition }
    private var limit: BudgetSummary.Limit? { data.partitionLimit(partition) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(kindName(partition, model)).frame(minWidth: 80, alignment: .leading)
                if let limit {
                    Text(L10n.Connect.readToday(model.uiLanguage, ["count": String(limit.used)])).font(.caption)
                        .foregroundStyle(limit.used >= limit.value ? Color.orange : Color.secondary)
                }
                Spacer()
                if data.isBusy(key) {
                    ProgressView().controlSize(.small)
                } else if let at = data.savedAt[key] {
                    Text(L10n.Shell.savedAt(model.uiLanguage, ["time": Stamp.clock(at)])).font(.caption).foregroundStyle(.secondary)
                }
                TextField(model.text(L10n.Connect.noLimit), text: Binding(get: { text }, set: { if $0 != text { text = $0; edited = true } }))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .focused($focused)
                    .onSubmit(save)
                    .accessibilityLabel(L10n.XAccounts.partitionLimitLabel(model.uiLanguage, ["kind": kindName(partition, model)]))
                Text(model.text(L10n.Connect.perDay)).foregroundStyle(.secondary)
            }
            if let failure = data.failures[key] {
                FailureNote(model: model, failure: failure)
            }
        }
        .onAppear(perform: fill)
        .onChange(of: data.budget) { fill() }
        .onChange(of: focused) { old, _ in if old { save() } }
    }

    private func fill() {
        guard !edited, data.budget != nil else { return }
        text = limit.map { String($0.value) } ?? ""
    }

    private func save() {
        guard edited, data.budget != nil else { return }
        edited = false
        guard text != (limit.map { String($0.value) } ?? "") else { return }
        Task { if !(await data.savePartitionReads(partition, text, model: model)) { edited = true } }
    }
}
