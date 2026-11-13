import SwiftUI

/// The Library tab's root (tab structure): All Unread, then the categories.
struct LibraryRootView: View {
    @Environment(CategoryModel.self) private var categories
    @Environment(SourceModel.self) private var sources
    @Environment(RefreshModel.self) private var refresh
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
        .refreshable {
            await refresh.refresh(.library)
        }
        .stackBackground(Theme.groupedBackground)
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditDoneButton(editMode: $editMode)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Add", systemImage: "plus") {
                    Button("Add Source", systemImage: "plus.circle") {
                        sources.beginAddSource()
                    }
                    .accessibilityIdentifier(AccessibilityID.addSourceButton)
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
    /// A category row has a leading disclosure control and no trailing
    /// chevron (RD05).
    var showsChevron = true
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
                if !isEditing, showsChevron {
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: Theme.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
