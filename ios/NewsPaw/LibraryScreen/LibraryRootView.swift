import SwiftUI

/// The Library tab's root (tab structure): All Unread, then the categories.
struct LibraryRootView: View {
    @Environment(CategoryModel.self) private var categories
    @State private var editMode = EditMode.inactive

    var body: some View {
        List {
            Section {
                RouteRow(route: .allUnread, isEditing: editMode.isEditing) {
                    Label("All Unread", systemImage: "tray")
                }
                .accessibilityIdentifier(AccessibilityID.allUnreadRow)
            }
            .listRowBackground(Theme.surface)
            Section {
                CategoryRows(rowContent: .navigating, presentSheet: { $0() })
            } header: {
                Text("Categories")
                    .foregroundStyle(Theme.secondaryText)
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.groupedBackground)
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditDoneButton(editMode: $editMode)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Add", systemImage: "plus") {
                    Button("New Category", systemImage: "folder.badge.plus") {
                        categories.beginNewCategory()
                    }
                    .accessibilityIdentifier(AccessibilityID.newCategoryButton)
                }
                .accessibilityIdentifier(AccessibilityID.addMenu)
            }
        }
        .environment(\.editMode, $editMode)
    }
}

/// A row that pushes `route` onto the Library stack, and does nothing while
/// the list is in edit mode.
struct RouteRow<Content: View>: View {
    let route: LibraryRoute
    let isEditing: Bool
    @ViewBuilder let content: () -> Content
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        Button {
            guard !isEditing else { return }
            navigation.libraryPath.append(route)
        } label: {
            HStack {
                content()
                Spacer(minLength: Theme.Spacing.small)
                if !isEditing {
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
    }
}
