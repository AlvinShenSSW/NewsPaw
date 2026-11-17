import NewsPawKit
import SwiftUI

/// How the sidebar is shown.
enum SidebarForm {
    /// A pane that is always shown (1100 pt and wider).
    case pane
    /// The slide-over panel, with the action that closes it.
    case slideOver(close: (_ animated: Bool) -> Void)
}

/// The sidebar's content, the same in both forms: Today, All Unread with
/// its unread count, Starred; the categories with their sources, with edit
/// mode for reorder and delete; Add source, New category and Settings at
/// the bottom. A feed-like source is selected like a category.
struct SidebarView: View {
    let form: SidebarForm
    @Environment(NavigationModel.self) private var navigation
    @Environment(CategoryModel.self) private var categories
    @Environment(SourceModel.self) private var sources
    @Environment(AppModel.self) private var model
    @State private var editMode = EditMode.inactive

    var body: some View {
        List(selection: selection) {
            if model.showsPartitionSwitch {
                // At the top of the sidebar, in the pane and in the
                // slide-over alike (ux section 2).
                Section {
                    PartitionSwitch(beforeChoice: closeSlideOver)
                        .listRowInsets(EdgeInsets(top: 0, leading: Theme.Spacing.small, bottom: 0, trailing: Theme.Spacing.small))
                        .listRowBackground(Color.clear)
                        .selectionDisabled()
                }
            }
            Section {
                Label("Today", systemImage: "sun.max")
                    .tag(SidebarItem.today)
                    .accessibilityIdentifier(AccessibilityID.todayRow)
                HStack {
                    Label("All Unread", systemImage: "tray")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityValue(Text("\(sources.totalUnread) unread"))
                        .accessibilityIdentifier(AccessibilityID.allUnreadRow)
                    if sources.totalUnread > 0 {
                        Text(sources.totalUnread, format: .number)
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                            .accessibilityHidden(true)
                    }
                }
                .tag(SidebarItem.allUnread)
                Label("Starred", systemImage: "star")
                    .tag(SidebarItem.starred)
                    .accessibilityIdentifier(AccessibilityID.starredRow)
            }
            Section {
                CategoryRows(rowContent: .tagged, presentSheet: presentSheet)
            } header: {
                Text("Categories")
            }
            Section {
                Button {
                    presentSheet { sources.beginAddSource() }
                } label: {
                    Label("Add Source", systemImage: "plus.circle")
                        .foregroundStyle(.tint)
                }
                .accessibilityIdentifier(AccessibilityID.addSourceButton)
                Button {
                    presentSheet { categories.beginNewCategory() }
                } label: {
                    Label("New Category", systemImage: "plus")
                        .foregroundStyle(.tint)
                }
                .accessibilityIdentifier(AccessibilityID.newCategoryButton)
                Label("Settings", systemImage: "gearshape")
                    .tag(SidebarItem.settings)
                    .accessibilityIdentifier(AccessibilityID.settingsRow)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("NewsPaw")
        .toolbar {
            // Search (RD25 decision 9), before Edit. In the slide-over it
            // closes the slide-over first, as the other choices there do.
            ToolbarItem(placement: .topBarTrailing) {
                Button("Search", systemImage: "magnifyingglass") {
                    closeSlideOver()
                    navigation.openSearch()
                }
                .disabled(editMode.isEditing)
                .accessibilityIdentifier(AccessibilityID.sidebarSearchButton)
            }
            ToolbarItem(placement: .topBarTrailing) {
                EditDoneButton(editMode: $editMode)
            }
            if case .slideOver(let close) = form {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close Sidebar", systemImage: "xmark") {
                        close(true)
                    }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AccessibilityID.closeSidebarButton)
                }
            }
        }
        .environment(\.editMode, $editMode)
    }

    /// The selection is derived from the navigation state and writes back to
    /// it. While the list is in edit mode a tap on a row does not navigate.
    private var selection: Binding<SidebarItem?> {
        Binding {
            navigation.sidebarSelection
        } set: { item in
            guard let item, !editMode.isEditing else { return }
            navigation.select(item)
            if case .slideOver(let close) = form {
                close(true)
            }
        }
    }

    /// A partition chosen, or the lock button pressed, in the slide-over:
    /// it closes at once, so that what follows is shown at the root.
    private func closeSlideOver() {
        if case .slideOver(let close) = form {
            close(false)
        }
    }

    /// A sheet asked for from inside the slide-over's cover would wait until
    /// the cover closed, so the slide-over closes first and the sheet is
    /// presented from the root.
    private func presentSheet(_ begin: () -> Void) {
        if case .slideOver(let close) = form {
            close(false)
        }
        begin()
    }
}
