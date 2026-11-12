import NewsPawKit
import SwiftUI
import UIKit

/// The library failure screen, or the app once its library is open.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.status {
        case .loading:
            Theme.background.ignoresSafeArea()
        case .failed(let failure):
            LibraryFailureView(failure: failure)
        case .ready(let categories, let sources):
            ShellView()
                .environment(categories)
                .environment(sources)
                .environment(model.navigation)
        }
    }
}

/// Measures the window's width and shows the tab container or the pane
/// container. Sheets and the alerts and dialogs for when no sheet is open
/// are presented here, above the container switch, so a switch cannot
/// dismiss them.
struct ShellView: View {
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
                .tint(Theme.accent)
        }
        .categoryDialogs(host: .root)
        .sourceDialogs(host: .root)
        .tint(Theme.accent)
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
