import NewsPawKit
import SwiftUI

/// iPad from 700 pt: sibling navigation stacks side by side, separated by
/// hairlines, with no split view, so each pane has its own bar, title and
/// toolbar and a push stays in its pane.
struct PaneContainer: View {
    let layout: WindowLayout
    @Environment(NavigationModel.self) private var navigation
    @Environment(CategoryModel.self) private var categories
    @Environment(SourceModel.self) private var sources
    @Environment(RefreshModel.self) private var refresh
    @Environment(ReadingModel.self) private var reading

    var body: some View {
        HStack(spacing: 0) {
            if layout.sidebarIsPane {
                NavigationStack {
                    SidebarView(form: .pane)
                        .paneRoot(inlineTitle: false)
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
                .environment(sources)
                .environment(refresh)
                .environment(reading)
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
                    .paneRoot(inlineTitle: layout.sidebarIsPane)
            }
            .paneIdentifier(AccessibilityID.fullPane)
        case .source(let id) where navigation.isWebPageSource(id):
            // A web-page source fills the content area as one pane (RD10).
            NavigationStack {
                BrowserPane(stack: .library)
                    .toolbar { sidebarButton }
                    .paneRoot(inlineTitle: false)
            }
            .paneIdentifier(AccessibilityID.fullPane)
        case .settings:
            NavigationStack(path: $navigation.settingsPath) {
                SettingsView()
                    .toolbar { sidebarButton }
                    .paneRoot(inlineTitle: layout.sidebarIsPane)
                    .navigationDestination(for: SettingsRoute.self) { route in
                        SettingsDestination(route: route).paneRoot(inlineTitle: layout.sidebarIsPane, avoidsKeyboard: route.isFormOfTextFields)
                    }
            }
            .paneIdentifier(AccessibilityID.fullPane)
        case .allUnread, .starred, .category, .source, .search:
            let list = ArticleListKind(selection)
            // Hidden, the list pane stays in the hierarchy at no width
            // (RD11 decision 14): its keys still act and it is where it
            // was when it is shown again.
            let isListHidden = navigation.isListHidden
            NavigationStack {
                ArticleListView(kind: list)
                    .toolbar { sidebarButton }
                    .paneRoot(inlineTitle: layout.sidebarIsPane)
            }
            .id(selection)
            .frame(width: layout.listPaneWidth)
            .frame(width: isListHidden ? 0 : layout.listPaneWidth, alignment: .trailing)
            .clipped()
            .allowsHitTesting(!isListHidden)
            .accessibilityHidden(isListHidden)
            .paneIdentifier(AccessibilityID.listPane)
            if !isListHidden {
                PaneSeparator()
            }
            NavigationStack {
                ReadingPane(list: list)
                    .toolbar { listButtons(for: list) }
                    .paneRoot(inlineTitle: false)
            }
            .paneIdentifier(AccessibilityID.readingPane)
        }
    }

    /// In the two-column layout, beside an open article: the button that
    /// hides the list column and shows it again and, while the list is
    /// hidden, the sidebar's button, which the list's bar no longer shows.
    /// Not while the article's page is in the pane: the browser has its own
    /// bar.
    @ToolbarContentBuilder
    private func listButtons(for list: ArticleListKind) -> some ToolbarContent {
        if navigation.canHideList, !navigation.pageIsOpen(on: list) {
            if navigation.isListHidden {
                sidebarButton
            }
            ToolbarItem(placement: .topBarLeading) {
                Button(
                    navigation.isListHidden ? "Show Article List" : "Hide Article List",
                    systemImage: navigation.isListHidden ? "rectangle.split.2x1" : "rectangle"
                ) {
                    navigation.setListHidden(!navigation.isListHidden)
                }
                .accessibilityIdentifier(AccessibilityID.hideListButton)
            }
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
    /// The root view of a pane's navigation stack (and of a view pushed onto
    /// it).
    ///
    /// Keyboard: a navigation stack created after a rotation applies the
    /// software keyboard's last frame from the previous orientation as a
    /// bottom inset although the keyboard is hidden, cutting about a third
    /// off the pane (measured on the iPadOS simulators, RD03 F1). Panes
    /// therefore ignore the keyboard safe area, which is also what criterion
    /// 2 asks: the panes' layout does not change when the keyboard appears.
    /// A later pane whose content holds a text field (RD09 search, unless it
    /// sits in the bar) has to keep that field visible itself, for example
    /// by scrolling it into view, instead of relying on keyboard avoidance.
    ///
    /// `avoidsKeyboard` is for a pushed screen that is a form of text
    /// fields (the model form, RD13): it keeps the keyboard safe area, so
    /// that the system scrolls the field being typed in above the
    /// keyboard. Without it the keyboard covered the model form's key
    /// field on iPad. The inset after a rotation was looked for with that
    /// form on the iPadOS 27 simulator (keyboard shown, hidden, rotated
    /// both ways, the form pushed again, the Settings stack made again) and
    /// did not appear; a form scrolls, so such an inset would shorten it,
    /// not hide a part of it.
    ///
    /// Title: the large-title row of a stack that is not at the window's
    /// leading edge is laid out at the window's margin clipped to the pane,
    /// so the title touches the separator (RD03 F4; safe-area padding and a
    /// child hosting controller do not change it). An inline large title
    /// takes the bar's own inset, so `inlineTitle` is set for the titled
    /// panes beside the sidebar pane (1100 pt and wider). Below 1100 pt every
    /// titled pane starts at the window's leading edge, where the ordinary
    /// large title is inset correctly; there the inline form must not be
    /// used, because it puts the title at the leading edge and moves the
    /// leading bar item, the sidebar button, to the trailing end (RD03 N1).
    @ViewBuilder
    func paneRoot(inlineTitle: Bool, avoidsKeyboard: Bool = false) -> some View {
        if inlineTitle {
            ignoresSafeArea(avoidsKeyboard ? [] : .keyboard)
                .toolbarTitleDisplayMode(.inlineLarge)
        } else {
            ignoresSafeArea(avoidsKeyboard ? [] : .keyboard)
        }
    }

    /// Names a pane for the UI tests without adding an element VoiceOver
    /// stops on: the pane becomes a container of its own elements.
    func paneIdentifier(_ identifier: String) -> some View {
        accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
    }
}
