import AppKit
import SwiftUI

/// Routes the selected sidebar page. Pages not yet redesigned (R07–R12) host the settings
/// views they replace, so the app stays usable between the redesign's merges.
struct PageContent: View {
    let model: AppModel
    let page: Page

    var body: some View {
        if model.connection != .connected, page != .settings {
            BackendUnavailable(model: model)
        } else {
            switch page {
            case .overview: OverviewPage(model: model)
            case .digests: if let config = model.config { DigestsPage(model: model, config: config) }
            case .xAccounts: XAccountsPage(model: model)
            case .connect: ConnectPage(model: model)
            case .settings: SettingsPage(model: model)
            }
        }
    }
}

/// Shown on every page while the backend cannot be reached (interaction-spec §4.6).
struct BackendUnavailable: View {
    let model: AppModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.text(model.statusTitle)).font(.headline)
                Text(model.text(L10n.Shell.notRunningNote)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ResidentControls(model: model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }
}

struct CategorySymbol: View {
    let id: String

    var body: some View {
        if id == "av",
           let url = Bundle.module.url(forResource: "newspaw-female-head-preview", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
                .frame(width: 17, height: 17)
        } else {
            Image(systemName: [
                "world": "globe", "japan": "location", "australia": "map",
                "china": "building.columns", "electronics": "desktopcomputer",
                "ai": "brain.head.profile", "x": "at", "x_adult": "at",
            ][id] ?? "newspaper")
            .font(.system(size: 16))
        }
    }
}

/// Language, backend and data (interaction-spec §8); data tools until R12.
struct SettingsPage: View {
    @Bindable var model: AppModel
    @State private var confirmStop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Form {
                Section(model.text(.language)) {
                    Picker(model.text(.appLanguage), selection: Binding(
                        get: { model.uiLanguage },
                        set: { value in Task { await model.chooseDisplayLanguage(value) } }
                    )) {
                        ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                    }
                    .disabled(model.busy)
                    .accessibilityIdentifier("display-language")
                    if let current = model.config?.newsOutputLocale {
                        Picker(model.text(.newsLanguage), selection: Binding(
                            get: { model.config?.newsOutputLocale ?? current },
                            set: { value in Task { await model.chooseNewsLanguage(value) } }
                        )) {
                            ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                        }
                        .disabled(model.busy)
                        .accessibilityIdentifier("news-language")
                    } else {
                        LabeledContent(model.text(.newsLanguage), value: model.text(.newsUnavailable))
                    }
                }
                Section(model.text(L10n.Shell.running)) {
                    LabeledContent(model.text(L10n.Shell.running)) { StatusLine(model: model) }
                    if model.connection == .connected {
                        Toggle(model.text(L10n.Shell.pauseAll), isOn: Binding(
                            get: { model.schedulingPaused },
                            set: { value in Task { await model.setPaused(value) } }
                        ))
                        .disabled(model.busy)
                        .accessibilityIdentifier("pause-all")
                    }
                    HStack {
                        Button(model.text(L10n.Shell.stopBackend), role: .destructive) { confirmStop = true }
                            .disabled(model.connection != .connected || model.busy)
                            .accessibilityIdentifier("stop-backend")
                        Button(model.text(L10n.Shell.quitWindow)) { NSApp.terminate(nil) }
                            .accessibilityIdentifier("quit-settings")
                    }
                    Text(model.text(L10n.Shell.quitNote)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            ResidentControls(model: model)
            if model.connection == .connected {
                OperationsWorkspace(model: model)
            }
        }
        .confirmationDialog(model.text(L10n.Shell.stopTitle), isPresented: $confirmStop) {
            Button(model.text(L10n.Shell.stopBackend), role: .destructive) { Task { await model.stopBackend() } }
            Button(model.text(L10n.Shell.cancel), role: .cancel) {}
        } message: {
            Text(model.text(L10n.Shell.stopBody))
        }
    }
}
