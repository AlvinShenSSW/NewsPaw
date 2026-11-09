import AppKit
import SwiftUI

@MainActor
final class WindowLifetime: NSObject, NSApplicationDelegate {
    var revealSettings: (() -> Void)?
    var openSetup: (() -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows, let revealSettings else { return true }
        revealSettings()
        return false
    }

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
            MainWindow(model: model) { action in
                lifetime.revealSettings = {
                    action(id: "settings")
                    NSApp.activate()
                }
                lifetime.openSetup = {
                    action(id: "onboarding")
                    NSApp.activate()
                }
            }
            .frame(minWidth: 900, minHeight: 600)
            .preferredColorScheme(developmentAppearance)
            .task {
                model.startMonitoring()
                // A backend stopped from Settings starts again when NewsPaw is opened (§8.2).
                await model.resident.startIfStopped(model: model)
            }
        }
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(model.text(L10n.Onboarding.openSetup)) { lifetime.openSetup?() }
            }
            CommandGroup(replacing: .appSettings) {
                Button(model.text(L10n.Page.settings)) {
                    model.page = .settings
                    lifetime.revealSettings?()
                }
                .keyboardShortcut(",")
            }
            CommandGroup(replacing: .appTermination) {
                Button(model.text(L10n.Shell.quitWindow)) { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            CommandMenu("NewsPaw") {
                ForEach(Array(Page.allCases.enumerated()), id: \.element) { index, page in
                    Button(model.text(page.title)) { model.page = page }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
                Divider()
                Button(model.text(L10n.Shell.refresh)) { Task { await model.refresh() } }
                    .keyboardShortcut("r")
            }
        }

        Window(model.text(L10n.Onboarding.windowTitle), id: "onboarding") {
            OnboardingWindow(model: model)
                .preferredColorScheme(developmentAppearance)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        MenuBarExtra {
            ServiceMenu(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
    }
}

/// The menu bar icon: an outlined paw and "paused" while every delivery is paused.
private struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        if model.menuBarPaused {
            HStack(spacing: 3) {
                Image(systemName: "pawprint")
                Text(model.text(L10n.Settings.menuPaused))
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel("NewsPaw · " + model.text(L10n.Shell.paused))
        } else {
            Image(systemName: "pawprint.fill").accessibilityLabel("NewsPaw")
        }
    }
}

/// Menu bar item (interaction-spec §8.3), built from `AppModel.menuItems`. Stopping the backend
/// lives in Settings, behind a confirmation, so it cannot be chosen by accident from here.
private struct ServiceMenu: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    var body: some View {
        ForEach(Array(model.menuItems().enumerated()), id: \.offset) { _, item in
            switch item {
            case let .status(line):
                Text(line)
            case .divider:
                Divider()
            case .open:
                Button(model.text(L10n.Shell.openNewsPaw)) {
                    openWindow(id: "settings")
                    NSApp.activate()
                }
                .keyboardShortcut("o")
            case let .pause(checked):
                // A checkmark item: ✓ while paused; choosing it again resumes.
                Toggle(model.text(L10n.Shell.pauseAll), isOn: Binding(
                    get: { checked },
                    set: { value in Task { await model.setPaused(value) } }
                ))
                .disabled(model.busy)
            case .quit:
                Button(model.text(L10n.Shell.quitWindow)) { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
    }
}

struct MainWindow: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var model: AppModel
    var registerOpen: ((OpenWindowAction) -> Void)? = nil

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 240)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let error = model.error {
                        if let failure = model.lastFailure {
                            FailureNote(model: model, failure: failure, action: model.retryLast.map { retry in
                                { Task { await retry() } }
                            })
                        } else {
                            Label(model.text(error), systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                    PageContent(model: model, page: model.page)
                }
                .frame(maxWidth: 960, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(model.text(model.page.title))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label(model.text(L10n.Shell.refresh), systemImage: "arrow.clockwise")
                    }
                    .help(model.text(L10n.Shell.refresh))
                }
            }
        }
        .onAppear { registerOpen?(openWindow) }
        // First launch with setup unfinished: open the setup window once (interaction-spec §3).
        .onChange(of: model.shouldOfferOnboarding, initial: true) { _, offer in
            if offer { openWindow(id: "onboarding") }
        }
    }
}

private struct Sidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                BrandMark(size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("NewsPaw").font(.headline)
                    Text(model.text(L10n.Shell.tagline)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            List(Page.allCases, selection: Binding(get: { model.page }, set: { model.page = $0 ?? .overview })) { page in
                Label {
                    Text(model.text(page.title))
                } icon: {
                    PageIcon(page: page)
                }
                .tag(page)
                .accessibilityIdentifier("page-\(page.id)")
            }
            .listStyle(.sidebar)
            StatusLine(model: model)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        }
    }
}

/// 20pt rounded colour tile with a white symbol, as in System Settings.
struct PageIcon: View {
    let page: Page

    private var tint: Color {
        switch page {
        case .overview: .blue
        case .digests: .orange
        case .xAccounts: .black
        case .connect: .green
        case .settings: .gray
        }
    }

    var body: some View {
        Image(systemName: page.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(tint, in: RoundedRectangle(cornerRadius: 5))
            .accessibilityHidden(true)
    }
}

/// Connection and pause state in words, never colour alone.
struct StatusLine: View {
    let model: AppModel

    private var dot: Color {
        switch model.connection {
        case .connected: model.schedulingPaused ? .orange : .green
        case .connecting, .stopping: .gray
        case .offline, .incompatible: .red
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(model.text(model.statusTitle)).font(.caption)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("backend-state")
    }
}

extension AppModel {
    var statusTitle: Words {
        switch connection {
        case .connected: schedulingPaused ? L10n.Shell.paused : L10n.Shell.running
        case .connecting: L10n.Shell.connecting
        case .offline: L10n.Shell.notRunning
        case .stopping: L10n.Shell.stopping
        case .incompatible: L10n.Shell.incompatible
        }
    }
}

struct BrandMark: View {
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

/// "What happened. What to do." with at most one action (interaction-spec §2.4).
struct FailureNote: View {
    let model: AppModel
    let failure: BackendError
    var action: (() -> Void)? = nil

    var body: some View {
        let entry = FailureCopy.entry(for: failure)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).accessibilityHidden(true)
            Text(FailureCopy.message(for: failure, model.uiLanguage))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let action, let label = entry.action {
                Button(model.text(label), action: action)
            }
        }
        .font(.callout)
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
