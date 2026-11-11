import NewsPawKit
import SwiftUI

/// How the sidebar is shown.
enum SidebarForm {
    /// A pane that is always shown (1100 pt and wider).
    case pane
    /// The slide-over panel, with the action that closes it.
    case slideOver(close: (_ animated: Bool) -> Void)
}

/// The sidebar's content, the same in both forms: Today, All Unread,
/// Starred; the categories, with edit mode for reorder and delete; New
/// category and Settings at the bottom.
struct SidebarView: View {
    let form: SidebarForm
    @Environment(NavigationModel.self) private var navigation
    @Environment(CategoryModel.self) private var categories
    @State private var editMode = EditMode.inactive

    var body: some View {
        List(selection: selection) {
            Section {
                Label("Today", systemImage: "sun.max")
                    .tag(SidebarItem.today)
                    .accessibilityIdentifier(AccessibilityID.todayRow)
                Label("All Unread", systemImage: "tray")
                    .tag(SidebarItem.allUnread)
                    .accessibilityIdentifier(AccessibilityID.allUnreadRow)
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
