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
            case .xAccounts: XWorkspace(model: model)
            case .connect: if let config = model.config { ConnectPage(model: model, config: config) }
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

/// Category cards and sources, hosted until the digest page is redesigned (R09).
struct DigestsPage: View {
    let model: AppModel
    let config: AppConfig
    @State private var subscriptionEditor: SubscriptionSelection?

    var body: some View {
        let revision = model.configRevision
        VStack(alignment: .leading, spacing: 17) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 305), spacing: 11)], spacing: 11) {
                ForEach(config.categories) { category in
                    let entries = config.subscriptions.filter { $0.categoryId == category.id }
                    let time = config.displaySubscription(for: category.id)
                    let enabled = time?.enabled == true
                    HStack(alignment: .center, spacing: 11) {
                        CategorySymbol(id: category.id)
                            .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
                            .frame(width: 23)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(categoryTitle(category)).font(.headline)
                            Text(model.text(category.partition == "adult" ? .adult : .ordinary))
                                .font(.caption).foregroundStyle(.secondary)
                            if let time, !time.times.isEmpty {
                                Text(time.times.joined(separator: " · ") + "  " + time.timezone)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 5)
                        CategorySubscriptionToggle(
                            model: model, category: category, title: categoryTitle(category),
                            subscriptions: entries, enabled: enabled, revision: revision
                        ) { subscriptionEditor = $0 }
                        Menu {
                            ForEach(entries) { subscription in
                                Button(subscription.name ?? categoryTitle(category)) {
                                    subscriptionEditor = SubscriptionSelection(
                                        category: category, subscription: subscription, revision: revision
                                    )
                                }
                            }
                            Button(SubscriptionCopy.new.text(model.uiLanguage)) {
                                subscriptionEditor = SubscriptionSelection(
                                    category: category, subscription: nil, revision: revision
                                )
                            }
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .accessibilityLabel(SubscriptionCopy.edit.text(model.uiLanguage))
                        .fixedSize()
                    }
                    .padding(13)
                    .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(enabled ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
                    }
                    .accessibilityElement(children: .contain)
                }
            }
            SourceWorkspace(model: model, sources: config.sources)
        }
        .sheet(item: $subscriptionEditor) { selection in
            SubscriptionEditor(model: model, selection: selection)
        }
    }

    private func categoryTitle(_ category: AppConfig.Category) -> String {
        let names: [String: Phrase] = [
            "world": .world, "japan": .japan, "australia": .australia,
            "china": .china, "electronics": .electronics, "ai": .ai,
            "av": .av, "x": .x, "x_adult": .xAdult,
        ]
        return names[category.id].map(model.text) ?? category.name
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

/// Bots, models and spending, hosted until the connections page is redesigned (R10).
struct ConnectPage: View {
    let model: AppModel
    let config: AppConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            BotWorkspace(model: model)
            ModelWorkspace(model: model, config: config)
            RuntimePolicyWorkspace(model: model)
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
