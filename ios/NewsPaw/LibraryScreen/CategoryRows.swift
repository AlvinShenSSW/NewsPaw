import NewsPawKit
import SwiftUI

/// The categories in the owner's order, with reorder, delete and a context
/// menu with Category settings: the one category list used by the Library
/// root and by the sidebar.
struct CategoryRows: View {
    enum RowContent {
        /// Rows tagged for the sidebar's selection.
        case tagged
        /// Rows that push the category onto the Library stack.
        case navigating
    }

    let rowContent: RowContent
    /// Presents a sheet from the root; the sidebar closes its slide-over
    /// first.
    let presentSheet: (() -> Void) -> Void
    @Environment(CategoryModel.self) private var categories
    @Environment(\.editMode) private var editMode

    var body: some View {
        switch categories.loadState {
        case .loading:
            EmptyView()
        case .failed:
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text("The categories could not be loaded.")
                    .foregroundStyle(Theme.secondaryText)
                Button("Try Again") {
                    Task { await categories.reload() }
                }
                .foregroundStyle(.tint)
                .frame(minHeight: Theme.minimumTapTarget)
            }
            .accessibilityIdentifier(AccessibilityID.categoriesLoadFailed)
        case .loaded where categories.summaries.isEmpty:
            Text("No categories yet")
                .foregroundStyle(Theme.secondaryText)
                .accessibilityIdentifier(AccessibilityID.noCategories)
        case .loaded:
            ForEach(categories.summaries) { summary in
                row(summary)
                    .accessibilityIdentifier(AccessibilityID.categoryRow(summary.category.name))
                    .contextMenu {
                        Button("Category Settings", systemImage: "gearshape") {
                            presentSheet { categories.beginSettings(summary.id) }
                        }
                    }
            }
            .onMove { categories.move(fromOffsets: $0, toOffset: $1) }
            .onDelete { categories.requestDeletion(atOffsets: $0) }
        }
    }

    @ViewBuilder
    private func row(_ summary: CategorySummary) -> some View {
        let label = Label(summary.category.name, systemImage: summary.category.icon.rawValue)
        switch rowContent {
        case .tagged:
            label.tag(SidebarItem.category(summary.id))
        case .navigating:
            RouteRow(route: .category(summary.id), isEditing: editMode?.wrappedValue.isEditing == true) {
                label
            }
        }
    }
}

/// The app's own Edit / Done control: an unfilled text button in the
/// accent, because the system's Done button is a white glyph on the accent
/// (2.5:1 in dark appearance).
struct EditDoneButton: View {
    @Binding var editMode: EditMode

    var body: some View {
        Button {
            withAnimation {
                editMode = editMode.isEditing ? .inactive : .active
            }
        } label: {
            if editMode.isEditing {
                Text("Done").minimumTapTarget()
            } else {
                Text("Edit").minimumTapTarget()
            }
        }
        .accessibilityIdentifier(AccessibilityID.editButton)
    }
}
