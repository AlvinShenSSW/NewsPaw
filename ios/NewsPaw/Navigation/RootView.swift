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
        case .ready(let categories):
            ShellView()
                .environment(categories)
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
    @Environment(NavigationModel.self) private var navigation
    @State private var width = 0.0

    private var layout: WindowLayout {
        WindowLayout(idiom: UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone, width: width)
    }

    var body: some View {
        @Bindable var categories = categories
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
        .ignoresSafeArea(.keyboard)
        .onGeometryChange(for: Double.self) { $0.size.width } action: { width = $0 }
        .onChange(of: layout) { _, layout in
            // The slide-over exists only for panes below 1100 pt.
            if layout.structure == .tabs || layout.sidebarIsPane {
                navigation.closeSlideOver()
            }
        }
        .sheet(item: $categories.sheet) { sheet in
            CategorySheetView(sheet: sheet)
                .categoryDialogs(host: .sheet)
                .environment(categories)
                .environment(navigation)
                .tint(Theme.accent)
        }
        .categoryDialogs(host: .root)
        .tint(Theme.accent)
        .foregroundStyle(Theme.text)
    }
}
