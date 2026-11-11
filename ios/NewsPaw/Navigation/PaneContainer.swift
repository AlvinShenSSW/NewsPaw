import NewsPawKit
import SwiftUI

/// iPad from 700 pt: sibling navigation stacks side by side, separated by
/// hairlines, with no split view, so each pane has its own bar, title and
/// toolbar and a push stays in its pane.
struct PaneContainer: View {
    let layout: WindowLayout
    @Environment(NavigationModel.self) private var navigation
    @Environment(CategoryModel.self) private var categories

    var body: some View {
        HStack(spacing: 0) {
            if layout.sidebarIsPane {
                NavigationStack {
                    SidebarView(form: .pane)
                }
                .frame(width: WindowLayout.sidebarPaneWidth)
                .paneIdentifier(AccessibilityID.sidebarPane)
                PaneSeparator()
            }
            destination
        }
        .fullScreenCover(isPresented: slideOverPresented) {
            SlideOverSidebar()
                .environment(navigation)
                .environment(categories)
        }
    }

    private var slideOverPresented: Binding<Bool> {
        Binding {
            navigation.isSlideOverOpen && !layout.sidebarIsPane
        } set: { open in
            if !open {
                navigation.closeSlideOver()
            }
        }
    }

    @ViewBuilder
    private var destination: some View {
        @Bindable var navigation = navigation
        let selection = navigation.sidebarSelection
        switch selection {
        case .today:
            NavigationStack {
                TodayView()
                    .toolbar { sidebarButton }
            }
            .paneIdentifier(AccessibilityID.fullPane)
        case .settings:
            NavigationStack(path: $navigation.settingsPath) {
                SettingsView()
                    .toolbar { sidebarButton }
                    .navigationDestination(for: SettingsRoute.self) { _ in AboutView() }
            }
            .paneIdentifier(AccessibilityID.fullPane)
        case .allUnread, .starred, .category:
            NavigationStack {
                ArticleListView(kind: ArticleListKind(selection))
                    .toolbar { sidebarButton }
            }
            .id(selection)
            .frame(width: layout.listPaneWidth)
            .paneIdentifier(AccessibilityID.listPane)
            PaneSeparator()
            NavigationStack {
                ReadingPlaceholderView()
            }
            .paneIdentifier(AccessibilityID.readingPane)
        }
    }

    /// On the root of the leading pane only; after a push there the back
    /// button takes its place.
    @ToolbarContentBuilder
    private var sidebarButton: some ToolbarContent {
        if !layout.sidebarIsPane {
            ToolbarItem(placement: .topBarLeading) {
                Button("Show Sidebar", systemImage: "sidebar.leading") {
                    navigation.openSlideOver()
                }
                .accessibilityIdentifier(AccessibilityID.showSidebarButton)
            }
        }
    }
}

/// The hairline between two panes.
struct PaneSeparator: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Theme.hairline
            .frame(width: 1 / displayScale)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

extension View {
    /// Names a pane for the UI tests without adding an element VoiceOver
    /// stops on: the pane becomes a container of its own elements.
    func paneIdentifier(_ identifier: String) -> some View {
        accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
    }
}
