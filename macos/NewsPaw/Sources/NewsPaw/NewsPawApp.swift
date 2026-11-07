import AppKit
import SwiftUI

@MainActor
final class WindowLifetime: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main @MainActor
struct NewsPawApp: App {
    @NSApplicationDelegateAdaptor(WindowLifetime.self) private var lifetime
    @State private var model = AppModel(socket: AppModel.defaultSocket())

    private var developmentAppearance: ColorScheme? {
        switch Bundle.main.object(forInfoDictionaryKey: "NewsPawDevelopmentAppearance") as? String {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    var body: some Scene {
        Window("NewsPaw", id: "settings") {
            SettingsWindow(model: model)
                .frame(minWidth: 680, minHeight: 450)
                .preferredColorScheme(developmentAppearance)
                .task { model.startMonitoring() }
        }
        .defaultSize(width: 990, height: 680)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button(model.text(.quitSettings)) { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            CommandMenu(model.text(.settings)) {
                ForEach(Array(SettingsPage.allCases.enumerated()), id: \.element) { index, page in
                    Button(model.text(page.title)) { model.page = page }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option])
                }
                Divider()
                Button(model.text(.refresh)) { Task { await model.refresh() } }
                    .keyboardShortcut("r")
            }
        }

        MenuBarExtra {
            ServiceMenu(model: model)
        } label: {
            Label("NewsPaw", systemImage: "pawprint.fill")
        }
    }
}

private struct ServiceMenu: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    var body: some View {
        Text(model.text(model.connection.phrase))
        Divider()
        Button(model.text(.openSettings)) {
            openWindow(id: "settings")
            NSApp.activate()
        }
        Button(model.text(.refresh)) { Task { await model.refresh() } }
        Divider()
        Button(model.text(.stopBackend)) { Task { await model.stopBackend() } }
            .disabled(model.connection != .connected || model.busy)
        Button(model.text(.quitSettings)) { NSApp.terminate(nil) }
    }
}

struct SettingsWindow: View {
    @Bindable var model: AppModel
    @State private var subscriptionEditor: SubscriptionSelection?

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    BrandMark(size: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("NewsPaw").font(.headline)
                        Text(model.text(.tagline))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                List(SettingsPage.allCases, selection: $model.page) { page in
                    Label(model.text(page.title), systemImage: page.symbol)
                        .tag(page)
                        .accessibilityIdentifier("page-\(page.id)")
                }
                .listStyle(.sidebar)
                ConnectionBadge(model: model)
                    .padding(.horizontal, 13)
                    .padding(.bottom, 12)
            }
            .navigationSplitViewColumnWidth(min: 188, ideal: 215, max: 265)
        } detail: {
            let page = model.page ?? .subscriptions
            ScrollView {
                VStack(alignment: .leading, spacing: 21) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.text(page.title))
                            .font(.title2.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("page-title")
                        Text(model.text(page.subtitle))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = model.error {
                        Label(model.text(error), systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    pageContent(page)
                }
                .frame(maxWidth: 880, alignment: .leading)
                .padding(25)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label(model.text(.refresh), systemImage: "arrow.clockwise")
                    }
                    .help(model.text(.refresh))
                }
            }
        }
        .sheet(item: $subscriptionEditor) { selection in
            SubscriptionEditor(model: model, selection: selection)
        }
    }

    @ViewBuilder private func pageContent(_ page: SettingsPage) -> some View {
        if page == .language {
            languagePage
        } else if page == .delivery {
            VStack(alignment: .leading, spacing: 16) {
                ResidentControls(model: model)
                if model.config != nil {
                    delivery
                } else {
                    statusCard(model.text(model.connection.phrase), note: model.text(.offlineNote))
                }
            }
        } else if let config = model.config {
            switch page {
            case .subscriptions: subscriptions(config)
            case .accounts: XWorkspace(model: model)
            case .models: models(config)
            case .delivery, .language: EmptyView()
            }
        } else {
            statusCard(model.text(model.connection.phrase), note: model.text(.offlineNote))
        }
    }

    private func subscriptions(_ config: AppConfig) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 305), spacing: 11)], spacing: 11) {
                ForEach(config.categories) { category in
                    let enabled = config.subscriptions.contains { $0.categoryId == category.id && $0.enabled }
                    let time = config.subscriptions.first { $0.categoryId == category.id }
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
                        Text(model.text(enabled ? .enabled : .disabled))
                            .font(.caption)
                            .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
                        Menu {
                            ForEach(config.subscriptions.filter { $0.categoryId == category.id }) { subscription in
                                Button(subscription.name ?? categoryTitle(category)) {
                                    subscriptionEditor = SubscriptionSelection(category: category, subscription: subscription)
                                }
                            }
                            Button(SubscriptionCopy.new.text(model.uiLanguage)) {
                                subscriptionEditor = SubscriptionSelection(category: category, subscription: nil)
                            }
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .accessibilityLabel(SubscriptionCopy.edit.text(model.uiLanguage))
                        .fixedSize()
                    }
                    .padding(13)
                    .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
                    .background(cardBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(enabled ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            SourceWorkspace(model: model, sources: config.sources)
        }
    }

    private func models(_ config: AppConfig) -> some View {
        ModelWorkspace(model: model, config: config)
    }

    private var delivery: some View {
        VStack(alignment: .leading, spacing: 16) {
            BotWorkspace(model: model)
            RuntimePolicyWorkspace(model: model)
            OperationsWorkspace(model: model)
            VStack(alignment: .leading, spacing: 11) {
                ConnectionBadge(model: model)
                Text(model.text(.lifecycleNote)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack { stopButton; quitButton }
                    VStack(alignment: .leading) { stopButton; quitButton }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
        }
    }

    private var stopButton: some View {
        Button(model.text(.stopBackend)) { Task { await model.stopBackend() } }
            .disabled(model.connection != .connected || model.busy)
            .accessibilityIdentifier("stop-backend")
    }

    private var quitButton: some View {
        Button(model.text(.quitSettings)) { NSApp.terminate(nil) }
            .accessibilityIdentifier("quit-settings")
    }

    private var languagePage: some View {
        VStack(alignment: .leading, spacing: 17) {
            VStack(alignment: .leading, spacing: 7) {
                Picker(model.text(.appLanguage), selection: Binding(
                    get: { model.uiLanguage },
                    set: { value in Task { await model.chooseDisplayLanguage(value) } }
                )) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .disabled(model.busy)
                .accessibilityIdentifier("display-language")
                Text(model.text(.displayLocal)).font(.caption).foregroundStyle(.secondary)
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
            VStack(alignment: .leading, spacing: 7) {
                if let current = model.config?.newsOutputLocale {
                    Picker(model.text(.newsLanguage), selection: Binding(
                        get: { model.config?.newsOutputLocale ?? current },
                        set: { value in Task { await model.chooseNewsLanguage(value) } }
                    )) {
                        ForEach(AppLanguage.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .disabled(model.busy)
                    .accessibilityIdentifier("news-language")
                } else {
                    Text(model.text(.newsLanguage)).font(.headline)
                    Text(model.text(.newsUnavailable)).foregroundStyle(.secondary)
                }
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor))
    }

    private func sectionTitle(_ key: Phrase) -> some View {
        Text(model.text(key)).font(.headline).accessibilityAddTraits(.isHeader)
    }

    private func line(_ title: String, note: String? = nil, status: Phrase? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let status {
                Text(model.text(status)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .accessibilityElement(children: .combine)
    }

    private func statusCard(_ title: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if let note { Text(note).foregroundStyle(.secondary) }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
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

private struct ConnectionBadge: View {
    let model: AppModel

    var body: some View {
        Label {
            Text(model.text(model.connection.phrase))
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: model.connection == .connected ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(model.connection == .connected ? Color.accentColor : Color.secondary)
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("backend-state")
    }
}

private struct BrandMark: View {
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white.frame(width: size, height: size)
            if let url = Bundle.module.url(forResource: "newspaw-logo-preview", withExtension: "jpg"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: size * 1.64, height: size * 1.64)
                    .offset(x: -size * 0.30, y: -size * 0.24)
            }
        }
        .frame(width: size, height: size, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.23))
        .accessibilityHidden(true)
    }
}

private struct CategorySymbol: View {
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
