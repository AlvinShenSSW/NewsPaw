import NewsPawKit
import SwiftUI
import UIKit

/// The library failure screen, or the app once its library is open: the
/// shell on the workspace shown, and on nothing else (RD18 decision 3). The
/// adult partition's questions and sentences are presented here, outside
/// the shell, so that they outlive a swap of workspaces.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        content
            .adultPartitionDialogs()
        #if DEBUG
            .overlay(alignment: .topLeading) {
                if model.showsDebugReport {
                    HStack(spacing: 0) {
                        AdultDebugElement()
                        Button {
                            model.slotsChangedForUITests()
                        } label: {
                            Color.clear.frame(width: 1, height: 1).contentShape(Rectangle())
                        }
                        .accessibilityIdentifier(DebugAccessibilityID.slotsChangedButton)
                    }
                }
            }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch model.status {
        case .loading:
            Theme.background.ignoresSafeArea()
        case .failed(let failure):
            LibraryFailureView(failure: failure)
        case .ready:
            if let workspace = model.shown {
                ShellView()
                    .environment(workspace.categories)
                    .environment(workspace.sources)
                    .environment(workspace.refresh)
                    .environment(workspace.reading)
                    .environment(workspace.browser)
                    .environment(workspace.modelSettings)
                    .environment(workspace.readingSettings)
                    .environment(workspace.translationSettings)
                    .environment(workspace.translation)
                    .environment(workspace.navigation)
                    // The accent follows the partition (decision 7).
                    .environment(\.accent, Theme.accent(of: workspace.partition))
                    // The cover waits for the shell of the workspace
                    // shown (decision 12).
                    .onAppear { model.shellDidAppear(of: workspace) }
                    // Another workspace is another shell: no sheet, alert,
                    // menu, pushed screen or view state survives the change.
                    .id(workspace.id)
            }
        }
    }
}

#if DEBUG
/// The element the UI tests read (RD18 decision 4): whether the adult
/// library's file exists, whether its connections are closed, and whether
/// the library object, the adult workspace and its browser model are gone
/// from memory. Present only under a UI-test library directory; a debug
/// build only.
private struct AdultDebugElement: View {
    @Environment(AppModel.self) private var model
    @State private var report = ""

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: report))
            .accessibilityIdentifier(DebugAccessibilityID.adultReport)
            .task {
                while !Task.isCancelled {
                    let current = await model.adultDebugReport()
                    if current != report {
                        report = current
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
    }
}
#endif

/// Measures the window's width and shows the tab container or the pane
/// container. Sheets and the alerts and dialogs for when no sheet is open
/// are presented here, above the container switch, so a switch cannot
/// dismiss them.
struct ShellView: View {
    @Environment(\.accent) private var accent
    @Environment(CategoryModel.self) private var categories
    @Environment(SourceModel.self) private var sources
    @Environment(NavigationModel.self) private var navigation
    @State private var width = 0.0

    private var layout: WindowLayout {
        WindowLayout(idiom: UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone, width: width)
    }

    var body: some View {
        @Bindable var navigation = navigation
        Group {
            if width == 0 {
                Theme.background
            } else if layout.structure == .tabs {
                TabContainer()
            } else {
                PaneContainer(layout: layout)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: Double.self) { $0.size.width } action: { width = $0 }
        .onChange(of: layout, initial: true) { _, layout in
            navigation.layout = width == 0 ? nil : layout
            // The slide-over exists only for panes below 1100 pt.
            if layout.structure == .tabs || layout.sidebarIsPane {
                navigation.closeSlideOver()
            }
        }
        .sheet(item: $navigation.sheet, onDismiss: sheetDismissed) { sheet in
            sheetContent(sheet)
                .categoryDialogs(host: .sheet)
                .sourceDialogs(host: .sheet)
                .environment(categories)
                .environment(sources)
                .tint(accent)
        }
        .categoryDialogs(host: .root)
        .sourceDialogs(host: .root)
        .markAllReadDialog(host: .root)
        .browserDialogs()
        .translationDialogs()
        .tint(accent)
        .foregroundStyle(Theme.text)
    }

    @ViewBuilder
    private func sheetContent(_ sheet: AppSheet) -> some View {
        switch sheet {
        case .newCategory: CategorySheetView(sheet: .newCategory)
        case .categorySettings(let id): CategorySheetView(sheet: .settings(id))
        case .addSource: AddSourceView()
        case .sourceSettings(let id): SourceSettingsView(sourceID: id)
        }
    }

    /// A sheet closed by any means. Add source cancels its detection and
    /// releases what it parsed.
    private func sheetDismissed() {
        if navigation.sheet != .addSource, sources.addSource != nil {
            sources.addSourceClosed()
        }
    }
}
