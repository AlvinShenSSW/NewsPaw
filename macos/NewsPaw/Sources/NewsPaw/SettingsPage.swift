import AppKit
import SwiftUI

/// Language, backend, data and the collapsed troubleshooting tools (interaction-spec §8).
struct SettingsPage: View {
    let model: AppModel
    @State private var data: SettingsData

    init(model: AppModel, data: SettingsData = SettingsData()) {
        self.model = model
        _data = State(initialValue: data)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(model.text(L10n.Settings.intro)).font(.callout).foregroundStyle(.secondary)
            LanguageSection(model: model)
            BackendSection(model: model)
            DataSection(model: model, data: data)
            AdvancedSection(model: model, data: data)
        }
        .task {
            // The login item can change in System Settings at any time.
            while !Task.isCancelled {
                model.resident.reload(model: model)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

// MARK: - Building blocks

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            GroupBox {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// A 13pt title with an 11pt note on the left and its controls on the right.
private struct SettingsRow<Trailing: View>: View {
    let title: String
    var note: String?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .frame(minHeight: 40)
        .padding(.vertical, 6)
    }
}

/// A failure under its row, by backend code, with nothing else to press.
private struct RowFailure: View {
    let model: AppModel
    let failure: BackendError?

    var body: some View {
        if let failure {
            FailureNote(model: model, failure: failure).padding(.bottom, 8)
        }
    }
}

/// A success note under its row.
private struct RowDone: View {
    let text: String?

    var body: some View {
        if let text {
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
                .padding(.bottom, 8)
        }
    }
}

// MARK: - §8.1 Language

private struct LanguageSection: View {
    let model: AppModel

    var body: some View {
        SettingsGroup(title: model.text(L10n.Settings.language)) {
            SettingsRow(title: model.text(L10n.Settings.uiLanguage), note: model.text(L10n.Settings.uiLanguageNote)) {
                Picker(model.text(L10n.Settings.uiLanguage), selection: Binding(
                    get: { model.uiLanguage },
                    set: { value in Task { await model.chooseDisplayLanguage(value) } }
                )) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .disabled(model.busy)
                .accessibilityIdentifier("display-language")
            }
            Divider()
            SettingsRow(
                title: model.text(L10n.Settings.newsLanguage),
                note: model.text(model.config == nil ? L10n.Settings.newsLanguageOffline : L10n.Settings.newsLanguageNote)
            ) {
                Picker(model.text(L10n.Settings.newsLanguage), selection: Binding(
                    get: { model.config?.newsOutputLocale ?? model.uiLanguage },
                    set: { value in Task { await model.chooseNewsLanguage(value) } }
                )) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .disabled(model.busy || model.config == nil)
                .accessibilityIdentifier("news-language")
            }
        }
    }
}

// MARK: - §8.2 Backend

private struct BackendSection: View {
    let model: AppModel
    @State private var confirmStop = false
    @State private var confirmLoginOff = false

    private var resident: BackendControl { model.resident }

    var body: some View {
        SettingsGroup(title: model.text(L10n.Settings.backend)) {
            SettingsRow(
                title: model.text(L10n.Settings.status),
                note: BackendLine.detail(model.service, build: BackendLine.build(for: model.service?.version), model.uiLanguage)
            ) {
                StatusDot(color: model.settingsStatus.color, text: model.text(model.settingsStatus.words), busy: resident.busy)
                if model.connection == .connected {
                    Button(model.text(L10n.Settings.restart)) { Task { await resident.restart(model: model) } }
                        .disabled(!resident.canRestart || resident.busy || model.busy)
                        .help(resident.canRestart ? "" : model.text(L10n.Settings.restartHelp))
                    Button(role: .destructive) { confirmStop = true } label: {
                        Text(model.text(L10n.Settings.stop)).foregroundStyle(.red)
                    }
                    .disabled(resident.busy || model.busy)
                    .accessibilityIdentifier("stop-backend")
                } else if model.connection == .offline {
                    Button(model.text(L10n.Settings.start)) { Task { await resident.start(model: model) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(resident.busy || !(resident.state == .on || resident.state == .off))
                }
            }
            Divider()
            SettingsRow(title: model.text(L10n.Settings.loginItem), note: model.text(L10n.Settings.loginItemNote)) {
                Toggle(model.text(L10n.Settings.loginItem), isOn: Binding(
                    get: { resident.loginOn },
                    set: { on in
                        if on {
                            Task { await resident.setLoginItem(true, model: model) }
                        } else {
                            confirmLoginOff = true
                        }
                    }
                ))
                .labelsHidden().toggleStyle(.switch)
                .disabled(!resident.canToggle || resident.busy || model.busy)
                .help(resident.note.map { model.text($0.message) } ?? "")
                .accessibilityIdentifier("login-item")
            }
            if let note = resident.note {
                LoginNoteRow(model: model, note: note)
            }
            Divider()
            SettingsRow(title: model.text(L10n.Shell.pauseAll), note: model.text(L10n.Settings.pauseNote)) {
                Toggle(model.text(L10n.Shell.pauseAll), isOn: Binding(
                    get: { model.schedulingPaused },
                    set: { value in Task { await model.setPaused(value) } }
                ))
                .labelsHidden().toggleStyle(.switch)
                .disabled(model.connection != .connected || model.busy)
                .accessibilityIdentifier("pause-all")
            }
            Divider()
            Text(model.text(L10n.Shell.quitNote)).font(.caption).foregroundStyle(.secondary)
                .padding(.vertical, 12)
        }
        .confirmationDialog(model.text(L10n.Shell.stopTitle), isPresented: $confirmStop) {
            Button(model.text(L10n.Shell.stopBackend), role: .destructive) { Task { await model.stopBackend() } }
            Button(model.text(L10n.Shell.cancel), role: .cancel) {}
        } message: {
            Text(model.text(L10n.Shell.stopBody))
        }
        .confirmationDialog(model.text(L10n.Settings.loginOffTitle), isPresented: $confirmLoginOff) {
            Button(model.text(L10n.Settings.loginOffButton), role: .destructive) {
                Task { await resident.setLoginItem(false, model: model) }
            }
            Button(model.text(L10n.Shell.cancel), role: .cancel) {}
        } message: {
            Text(model.text(L10n.Settings.loginOffBody))
        }
    }
}

/// What the login item needs, with System Settings as the way out.
struct LoginNoteRow: View {
    let model: AppModel
    let note: LoginNote

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: note == .notPackaged ? "info.circle" : "exclamationmark.circle.fill")
                .foregroundStyle(note == .notPackaged ? Color.secondary : Color.orange)
                .accessibilityHidden(true)
            Text(model.text(note.message)).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if note.offersSettings {
                Button(model.text(L10n.Settings.openLoginItems)) { model.resident.openSettings() }
            }
        }
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }
}

/// The "backend not running" card's controls (interaction-spec §4.6).
struct BackendStartControls: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(model.text(L10n.Settings.start)) { Task { await model.resident.start(model: model) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.resident.busy || !(model.resident.state == .on || model.resident.state == .off)
                        || model.connection == .connecting || model.connection == .stopping)
                if model.resident.busy { ProgressView().controlSize(.small) }
                Button(model.text(L10n.Settings.openLoginItems)) { model.resident.openSettings() }
                    .disabled(model.resident.state == .notPackaged)
            }
            if let note = model.resident.note {
                LoginNoteRow(model: model, note: note)
            }
        }
        .task {
            while !Task.isCancelled {
                model.resident.reload(model: model)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

// MARK: - §8.4 Data

private struct DataSection: View {
    let model: AppModel
    let data: SettingsData

    private var offline: Bool { model.connection != .connected }

    var body: some View {
        SettingsGroup(title: model.text(L10n.Settings.data)) {
            if let folder = model.dataDirectory {
                SettingsRow(title: model.text(L10n.Settings.storage), note: (folder.path as NSString).abbreviatingWithTildeInPath) {
                    Button(model.text(L10n.Settings.showInFinder)) {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                }
                Divider()
            }
            SettingsRow(title: model.text(L10n.Settings.backup), note: model.text(L10n.Settings.backupNote)) {
                Button(model.text(L10n.Settings.export)) { Task { await data.export(model: model) } }
                    .disabled(offline || data.isBusy("export"))
                Button(model.text(L10n.Settings.import)) { Task { await data.chooseImport(model: model) } }
                    .disabled(offline || data.isBusy("import"))
                    .popover(isPresented: Binding(
                        get: { data.importPreview != nil },
                        set: { shown in if !shown { data.cancelImport() } }
                    ), arrowEdge: .bottom) {
                        if let preview = data.importPreview {
                            ImportPopover(model: model, data: data, preview: preview)
                        }
                    }
            }
            RowFailure(model: model, failure: data.failures["export"])
            RowDone(text: data.done["export"].map(model.text))
            // While the list is open its own failure line is inside it.
            RowFailure(model: model, failure: data.importPreview == nil ? data.failures["import"] : nil)
            RowDone(text: data.done["import"].map(model.text))
            Divider()
            SettingsRow(title: model.text(L10n.Settings.retention), note: model.text(L10n.Settings.retentionNote)) {
                Picker(model.text(L10n.Settings.retention), selection: Binding(
                    get: { model.retentionDays },
                    set: { days in
                        model.setRetentionDays(days)
                        data.retentionChanged(to: days)
                    }
                )) {
                    ForEach(AppModel.retentionChoices, id: \.self) { days in
                        Text(L10n.Settings.days(model.uiLanguage, ["count": String(days)])).tag(days)
                    }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .accessibilityIdentifier("retention")
            }
        }
    }
}

/// The list of what an import would change; it is the confirmation (title, impact, two buttons).
private struct ImportPopover: View {
    let model: AppModel
    let data: SettingsData
    let preview: ImportPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.text(L10n.Settings.importTitle)).font(.headline)
            if preview.changedSincePreview {
                Text(model.text(L10n.Settings.importAgain)).font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if preview.changes.isEmpty {
                Text(model.text(L10n.Settings.importNothing)).font(.callout)
            } else {
                Text(model.text(L10n.Settings.importChanges)).font(.callout).foregroundStyle(.secondary)
                ForEach(Array(preview.changes.enumerated()), id: \.offset) { _, change in
                    ForEach(lines(change), id: \.self) { line in
                        Label(line, systemImage: "circle.fill").labelStyle(Bullet())
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(model.text(L10n.Settings.importStaysOff))
                if preview.requiresPairing { Text(model.text(L10n.Settings.importPairing)) }
                Text(model.text(L10n.Settings.importKeys))
            }
            .font(.caption).foregroundStyle(.secondary)
            RowFailure(model: model, failure: data.failures["import"])
            HStack {
                Spacer()
                Button(model.text(L10n.Shell.cancel), role: .cancel) { data.cancelImport() }
                    .keyboardShortcut(.cancelAction)
                Button(model.text(L10n.Settings.importButton)) { Task { await data.applyImport(model: model) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(data.isBusy("import"))
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private struct Bullet: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                configuration.icon.font(.system(size: 4)).foregroundStyle(.secondary)
                configuration.title.font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func title(_ digest: DigestRef) -> String {
        if let name = digest.name { return name }
        return model.categoryTitle(digest.categoryId)
    }

    private func lines(_ change: ImportChange) -> [String] {
        let language = model.uiLanguage
        switch change {
        case let .uiLanguage(value): return [L10n.Settings.changeUI(language, ["value": value.displayName])]
        case let .newsLanguage(value): return [L10n.Settings.changeNews(language, ["value": value.displayName])]
        case let .timezone(value): return [L10n.Settings.changeTimezone(language, ["value": value])]
        case let .digests(changed, removed):
            var result: [String] = []
            if !changed.isEmpty {
                result.append(L10n.Settings.changeDigests(language, ["names": changed.map(title).joined(separator: "、")]))
            }
            if !removed.isEmpty {
                result.append(L10n.Settings.removeDigests(language, ["names": removed.map(title).joined(separator: "、")]))
            }
            return result
        case let .collection(kind, added, removed, changed):
            let parts = [(L10n.Settings.added, added), (L10n.Settings.removed, removed), (L10n.Settings.changed, changed)]
                .filter { $0.1 > 0 }
                .map { $0.0(language, ["count": String($0.1)]) }
            return [L10n.Settings.collectionLine(language, ["kind": kind.title(language), "parts": parts.joined(separator: " · ")])]
        case let .omitted(count):
            return [L10n.Settings.omittedLine(language, ["count": String(count)])]
        }
    }
}

// MARK: - §8.5 Advanced

private struct AdvancedSection: View {
    let model: AppModel
    let data: SettingsData
    @AppStorage("settings.advancedOpen") private var open = false
    @State private var confirmClean = false

    private var offline: Bool { model.connection != .connected }

    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $open) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.text(L10n.Settings.advancedNote)).font(.caption).foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                    Divider()
                    SettingsRow(title: model.text(L10n.Settings.diagnostics), note: model.text(L10n.Settings.diagnosticsNote)) {
                        Button(model.text(L10n.Settings.copy)) { Task { await data.copyDiagnostics(model: model) } }
                        Button(model.text(L10n.Settings.saveFile)) { Task { await data.saveDiagnostics(model: model) } }
                    }
                    .disabled(offline || data.isBusy("diagnostics"))
                    RowFailure(model: model, failure: data.failures["diagnostics"])
                    RowDone(text: data.done["diagnostics"].map(model.text))
                    Divider()
                    SettingsRow(title: model.text(L10n.Settings.snapshot), note: model.text(L10n.Settings.snapshotNote)) {
                        Button(model.text(L10n.Settings.saveFile)) { Task { await data.saveSnapshot(model: model) } }
                    }
                    .disabled(offline || data.isBusy("snapshot"))
                    RowFailure(model: model, failure: data.failures["snapshot"])
                    RowDone(text: data.done["snapshot"].map(model.text))
                    Divider()
                    SettingsRow(title: model.text(L10n.Settings.backupCheck), note: model.text(L10n.Settings.backupCheckNote)) {
                        if data.isBusy("backup") { ProgressView().controlSize(.small) }
                        Button(model.text(L10n.Settings.chooseBackup)) { Task { await data.verifyBackup(model: model) } }
                    }
                    .disabled(offline || data.isBusy("backup"))
                    if let backup = data.backup, backup.integrity == "ok" {
                        Label(L10n.Settings.backupOK(model.uiLanguage, [
                            "version": String(backup.schemaVersion),
                            "size": ByteCountFormatter.string(fromByteCount: Int64(backup.sizeBytes), countStyle: .file),
                        ]), systemImage: "checkmark.seal.fill")
                        .font(.caption).foregroundStyle(.green).padding(.bottom, 8)
                    }
                    RowFailure(model: model, failure: data.failures["backup"])
                    Divider()
                    cleanupRow
                    Divider()
                    JobsBlock(model: model, data: data, open: open)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.text(L10n.Settings.advanced)).fontWeight(.semibold)
                    Text(model.text(L10n.Settings.advancedSummary)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityValue(model.text(open ? L10n.Digests.collapse : L10n.Digests.edit))
            .padding(4)
        }
        .confirmationDialog(model.text(L10n.Settings.cleanTitle), isPresented: $confirmClean) {
            Button(model.text(L10n.Settings.cleanConfirm), role: .destructive) { Task { await data.applyCleanup(model: model) } }
            Button(model.text(L10n.Shell.cancel), role: .cancel) {}
        } message: {
            Text(model.text(L10n.Settings.cleanBody))
        }
    }

    @ViewBuilder private var cleanupRow: some View {
        SettingsRow(title: model.text(L10n.Settings.cleanup), note: model.text(L10n.Settings.retentionNote)) {
            if data.isBusy("cleanup") { ProgressView().controlSize(.small) }
            Button(model.text(L10n.Settings.previewCleanup)) { Task { await data.previewCleanup(model: model) } }
            if let cleanup = data.cleanup, cleanup.count > 0 {
                Button(role: .destructive) { confirmClean = true } label: {
                    Text(model.text(L10n.Settings.cleanButton)).foregroundStyle(.red)
                }
            }
        }
        .disabled(offline || data.isBusy("cleanup"))
        if let cleanup = data.cleanup {
            VStack(alignment: .leading, spacing: 4) {
                Text(cleanup.count == 0 ? model.text(L10n.Settings.cleanupNothing) : L10n.Settings.cleanupFound(model.uiLanguage, [
                    "count": String(cleanup.count), "logs": String(cleanup.logs), "records": String(cleanup.records),
                    "images": String(cleanup.images), "posts": String(cleanup.xPosts),
                ]))
                if cleanup.mediaDeferred { Text(model.text(L10n.Settings.cleanupDeferred)).foregroundStyle(.secondary) }
            }
            .font(.caption).padding(.bottom, 8)
        }
        if let cleaned = data.cleaned {
            RowDone(text: L10n.Settings.cleaned(model.uiLanguage, ["count": String(cleaned)]))
        }
        RowFailure(model: model, failure: data.failures["cleanup"])
    }
}

/// Recent jobs and, per job, what each Bot received. Read-only.
private struct JobsBlock: View {
    let model: AppModel
    let data: SettingsData
    let open: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsRow(title: model.text(L10n.Settings.jobs)) {
                if data.isBusy("jobs") { ProgressView().controlSize(.small) }
                Button(model.text(data.jobs == nil ? L10n.Settings.jobsLoad : L10n.Shell.refresh)) {
                    Task { await data.loadJobs(model: model) }
                }
                .disabled(model.connection != .connected || data.isBusy("jobs"))
            }
            RowFailure(model: model, failure: data.failures["jobs"])
            if let jobs = data.jobs {
                if jobs.isEmpty {
                    Text(model.text(L10n.Settings.jobsEmpty)).font(.callout).foregroundStyle(.secondary).padding(.bottom, 8)
                }
                ForEach(jobs) { job in
                    JobRow(model: model, data: data, job: job)
                }
            }
        }
        .task(id: open) {
            if open, data.jobs == nil, model.connection == .connected { await data.loadJobs(model: model) }
        }
    }
}

private struct JobRow: View {
    let model: AppModel
    let data: SettingsData
    let job: JobRecord
    @State private var expanded = false

    private var digest: String {
        if let account = job.accountId { return account }
        return job.subscriptionId.map(model.digestTitle) ?? "—"
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                if let delivery = data.deliveries[job.jobId] {
                    if delivery.targets.isEmpty {
                        Text(model.text(L10n.Settings.noDelivery)).foregroundStyle(.secondary)
                    }
                    ForEach(delivery.targets) { target in
                        Text(L10n.Settings.deliveryLine(model.uiLanguage, [
                            "bot": botName(target.botId),
                            "state": target.phrase.map(model.text) ?? target.status,
                            "delivered": String(target.delivered), "parts": String(target.parts),
                        ]))
                    }
                } else if data.isBusy("delivery." + job.jobId) {
                    ProgressView().controlSize(.small)
                }
                RowFailure(model: model, failure: data.failures["delivery." + job.jobId])
            }
            .font(.caption)
            .padding(.leading, 4)
        } label: {
            HStack(spacing: 10) {
                Text(OverviewData.date(job.createdAt).map { Stamp.relative($0, model.uiLanguage) } ?? job.createdAt)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .leading)
                Text(digest).lineLimit(1)
                Spacer()
                Text(job.phrase.map(model.text) ?? job.status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: expanded) { _, open in
            if open { Task { await data.loadDelivery(job.jobId, model: model) } }
        }
        .padding(.vertical, 2)
    }

    private func botName(_ id: String) -> String {
        model.bots.first { $0.id == id }.map { $0.username.map { "@" + $0 } ?? $0.name } ?? id
    }
}

extension AppModel {
    /// The Settings status row: the same "paused" as the sidebar and the menu bar (§8.2, A2).
    var settingsStatus: (color: Color, words: Words) {
        switch connection {
        case .connected: schedulingPaused ? (.orange, L10n.Shell.paused) : (.green, L10n.Settings.running)
        case .connecting: (.gray, L10n.Shell.connecting)
        case .stopping: (.gray, L10n.Shell.stopping)
        case .offline: (.red, L10n.Settings.notRunning)
        case .incompatible: (.red, L10n.Shell.incompatible)
        }
    }
}
