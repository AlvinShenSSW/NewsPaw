import NewsPawKit
import SwiftUI

/// The categories in the owner's order, each with its unread count, with
/// reorder, delete and a context menu with Refresh, Mark All as Read and
/// Category settings, each with a disclosure control that shows its
/// sources: the one category list used by the Library root and by the
/// sidebar.
///
/// Source rows carry `.deleteDisabled(true)` and `.moveDisabled(true)`:
/// without them a swipe on a source row runs the category deletion at the
/// source's index within its category, and edit mode shows handles on
/// them. Expansion is never changed when edit mode starts: collapsing then
/// strips the edit controls from every category but the first (RD05,
/// measured).
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
    @Environment(SourceModel.self) private var sources
    @Environment(RefreshModel.self) private var refresh
    @Environment(ReadingModel.self) private var reading
    @Environment(\.editMode) private var editMode

    var body: some View {
        switch categories.loadState {
        case .loading:
            EmptyView()
        case .failed:
            loadFailure
        case .loaded where sources.loadFailed:
            loadFailure
        case .loaded where categories.summaries.isEmpty:
            // A category awaiting deletion still counts: until the deletion
            // is confirmed the library is not empty.
            Text("No categories yet")
                .foregroundStyle(Theme.secondaryText)
                .accessibilityIdentifier(AccessibilityID.noCategories)
        case .loaded:
            ForEach(categories.listedSummaries) { summary in
                row(summary)
                    .moveDisabled(categories.isBusy)
                    .deleteDisabled(categories.isBusy)
                    .contextMenu {
                        if sources.hasRefreshTarget(in: summary.id) {
                            Button("Refresh", systemImage: "arrow.clockwise") {
                                Task { await refresh.refresh(.category(summary.id)) }
                            }
                        }
                        if sources.unreadCount(in: summary.id) > 0 {
                            Button("Mark All as Read", systemImage: "checkmark.circle") {
                                reading.askMarkAllRead(.category(summary.id))
                            }
                        }
                        Button("Category Settings", systemImage: "gearshape") {
                            presentSheet { categories.beginSettings(summary.id) }
                        }
                    }
                if sources.expanded.contains(summary.id) {
                    ForEach(sources.sources(in: summary.id)) { source in
                        SourceRow(source: source, rowContent: rowContent, presentSheet: presentSheet)
                            .deleteDisabled(true)
                            .moveDisabled(true)
                    }
                }
            }
            .onMove { categories.move(fromOffsets: $0, toOffset: $1) }
            .onDelete { categories.requestDeletion(atOffsets: $0) }
        }
    }

    /// The categories or the sources could not be read.
    private var loadFailure: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("The categories could not be loaded.")
                .foregroundStyle(Theme.secondaryText)
            Button("Try Again") {
                // Reloading the categories reloads the sources too.
                Task { await categories.reload() }
            }
            .foregroundStyle(.tint)
            .frame(minHeight: Theme.minimumTapTarget)
        }
        .accessibilityIdentifier(AccessibilityID.categoriesLoadFailed)
    }

    /// In edit mode the disclosure control is hidden from VoiceOver, so the
    /// row is one element again and the edit controls the system adds are
    /// named after the category ("Reorder World", "Remove, World"); with two
    /// elements in the row the delete control has no name and the handle
    /// is named after the disclosure control (measured). The control still
    /// works for touch, and expansion stays as it is.
    @ViewBuilder
    private func row(_ summary: CategorySummary) -> some View {
        let isEditing = editMode?.wrappedValue.isEditing == true
        let label = Label(summary.category.name, systemImage: summary.category.icon.rawValue)
        let disclosure = DisclosureButton(
            name: summary.category.name, isExpanded: sources.expanded.contains(summary.id)
        ) {
            withAnimation { sources.toggleExpanded(summary.id) }
        }
        .accessibilityHidden(isEditing)
        let unread = sources.unreadCount(in: summary.id)
        switch rowContent {
        case .tagged:
            HStack(spacing: 0) {
                disclosure
                label
                    .frame(maxWidth: .infinity, minHeight: Theme.minimumTapTarget, alignment: .leading)
                    .contentShape(Rectangle())
                    .accessibilityValue(Text("\(unread) unread"))
                    .accessibilityIdentifier(AccessibilityID.categoryRow(summary.category.name))
                if unread > 0 {
                    Text(unread, format: .number)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.leading, Theme.Spacing.small)
                        .accessibilityHidden(true)
                }
            }
            .tag(SidebarItem.category(summary.id))
        case .navigating:
            HStack(spacing: 0) {
                disclosure
                RouteRow(route: .category(summary.id), isEditing: isEditing, showsChevron: false, unread: unread) {
                    label
                }
                .accessibilityIdentifier(AccessibilityID.categoryRow(summary.category.name))
            }
        }
    }
}

/// The leading control of a category row that shows or hides its sources:
/// its own 44 × 44 pt target, so a tap on the rest of the row still opens
/// the category.
struct DisclosureButton: View {
    let name: String
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: Theme.minimumTapTarget, height: Theme.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("Sources of “\(name)”"))
        .accessibilityValue(isExpanded ? Text("Shown") : Text("Hidden"))
        .accessibilityIdentifier(AccessibilityID.disclosure(name))
    }
}

/// The app's own Edit / Done control: an unfilled text button drawn in the
/// text colour, because the system's Done button is a white glyph on the
/// accent (2.5:1 in dark appearance).
struct EditDoneButton: View {
    @Binding var editMode: EditMode
    @Environment(CategoryModel.self) private var categories

    var body: some View {
        Button {
            withAnimation {
                editMode = editMode.isEditing ? .inactive : .active
            }
        } label: {
            if editMode.isEditing {
                Text("Done")
            } else {
                Text("Edit")
            }
        }
        // Edit mode is not entered while a save runs: rows entering it while
        // they cannot be moved or deleted get no edit controls when the save
        // ends (measured). Done stays available.
        .disabled(!editMode.isEditing && categories.isBusy)
        .accessibilityIdentifier(AccessibilityID.editButton)
    }
}
