import NewsPawKit
import SwiftUI

/// All Unread, Starred, a category or a source (spec N05; ux S3; RD09): the
/// list's snapshot from the reading model, with the Unread / All control of
/// a category or source, swipes and a menu on every row, "Mark All as Read"
/// and a menu with Refresh and the settings in the toolbar, and pull to
/// refresh.
struct ArticleListView: View {
    let kind: ArticleListKind
    @Environment(ReadingModel.self) private var reading

    var body: some View {
        ArticleListContent(kind: kind, model: reading.list(kind))
    }
}

private struct ArticleListContent: View {
    let kind: ArticleListKind
    let model: ArticleListModel
    @Environment(ReadingModel.self) private var reading
    @Environment(SourceModel.self) private var sources
    @Environment(CategoryModel.self) private var categories
    @Environment(NavigationModel.self) private var navigation
    @Environment(RefreshModel.self) private var refresh

    var body: some View {
        List {
            ForEach(model.rows) { row in
                ArticleRowButton(row: row, kind: kind, model: model)
            }
            footer
        }
        // Over the list, which still scrolls and refreshes under it
        // (measured: a pull on the empty state refreshes).
        .overlay {
            if showsEmptyState {
                emptyState
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            if kind.hasFilter {
                filterControl
            }
        }
        .refreshable {
            await reading.refresh(kind)
        }
        .background {
            ArticleShortcuts(list: kind)
        }
        .onAppear {
            reading.appeared(kind)
        }
        .stackBackground(Theme.background)
        .navigationTitle(title)
        .toolbar { toolbar }
    }

    // MARK: - Filter

    private var filterControl: some View {
        Picker("Show", selection: filterBinding) {
            Text("Unread").tag(ArticleFilter.unread)
            Text("All").tag(ArticleFilter.all)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier(AccessibilityID.articleFilter)
        .padding(.horizontal, Theme.Spacing.standard)
        .padding(.vertical, Theme.Spacing.small)
        .frame(maxWidth: .infinity)
        // Not into the safe area, where it would cover the large title.
        .background(Theme.background, ignoresSafeAreaEdges: [])
    }

    private var filterBinding: Binding<ArticleFilter> {
        Binding {
            model.filter
        } set: { filter in
            reading.setFilter(filter, of: kind)
        }
    }

    // MARK: - End of the list

    @ViewBuilder
    private var footer: some View {
        if model.readFailed || model.state == .failed {
            HStack(spacing: Theme.Spacing.small) {
                Text("Could not load")
                    .foregroundStyle(Theme.secondaryText)
                Spacer(minLength: Theme.Spacing.small)
                Button("Try Again") {
                    reading.retry(model)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
                .frame(minHeight: Theme.minimumTapTarget)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.couldNotLoad)
            .listRowBackground(Theme.background)
        } else if model.hasMore {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: Theme.minimumTapTarget)
                .listRowSeparator(.hidden)
                .listRowBackground(Theme.background)
                .onAppear { reading.loadNextPage(model) }
        }
    }

    // MARK: - Empty states (decision 16)

    private var showsEmptyState: Bool {
        model.state == .loaded && model.rows.isEmpty && !model.readFailed
    }

    @ViewBuilder
    private var emptyState: some View {
        let stored = sources.articleCount(of: kind)
        switch kind {
        case .starred:
            EmptyStateView(title: Text("No starred articles"), systemImage: "star", identifier: AccessibilityID.starredEmpty)
        case .allUnread:
            if stored == 0 {
                EmptyStateView(title: Text("No articles yet"), systemImage: "tray", identifier: AccessibilityID.allUnreadEmpty)
            } else {
                EmptyStateView(title: Text("All caught up"), systemImage: "checkmark.circle", identifier: AccessibilityID.allUnreadEmpty)
            }
        case .category:
            filteredEmptyState(stored: stored, identifier: AccessibilityID.categoryEmpty, detail: nil)
        case .source(let id):
            filteredEmptyState(
                stored: stored, identifier: AccessibilityID.sourceEmpty,
                detail: sources.summary(id)?.status.map(SourceWording.status)
            )
        }
    }

    @ViewBuilder
    private func filteredEmptyState(stored: Int?, identifier: String, detail: Text?) -> some View {
        if stored ?? 0 > 0, model.filter == .unread {
            EmptyStateView(
                title: Text("All caught up"), systemImage: "checkmark.circle", identifier: identifier,
                action: .init(title: Text("Show All"), identifier: AccessibilityID.showAllButton) {
                    reading.setFilter(.all, of: kind)
                }
            )
        } else {
            EmptyStateView(title: Text("No articles yet"), systemImage: "tray", identifier: identifier, detail: detail)
        }
    }

    // MARK: - Title and toolbar

    private var title: Text {
        switch kind {
        case .allUnread: Text("All Unread")
        case .starred: Text("Starred")
        case .category(let id): Text(verbatim: categories.summary(id)?.category.name ?? "")
        case .source(let id): Text(verbatim: sources.summary(id)?.name ?? "")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if kind.offersMarkAllRead {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Mark All as Read", systemImage: "checkmark.circle") {
                    reading.askMarkAllRead(kind.scope)
                }
                .disabled(sources.unreadCount(of: kind) == 0)
                .accessibilityIdentifier(AccessibilityID.markAllReadButton)
            }
        }
        if sources.hasRefreshTarget(for: kind) || kind.hasFilter {
            ToolbarItem(placement: .topBarTrailing) {
                listMenu
            }
        }
    }

    /// Refresh, when the scope has something to collect, and the category's
    /// or source's settings.
    private var listMenu: some View {
        Menu("More", systemImage: "ellipsis.circle") {
            if sources.hasRefreshTarget(for: kind) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await reading.refresh(kind) }
                }
            }
            switch kind {
            case .category(let id):
                Button("Category Settings", systemImage: "gearshape") {
                    categories.beginSettings(id)
                }
            case .source(let id):
                Button("Source Settings", systemImage: "gearshape") {
                    sources.beginSettings(id)
                }
            case .allUnread, .starred:
                EmptyView()
            }
        }
        .accessibilityIdentifier(AccessibilityID.listMenu)
    }
}

/// A row as a button that opens its article, with the swipes, the menu and
/// the appearance tracking the snapshot needs.
private struct ArticleRowButton: View {
    let row: ArticleRow
    let kind: ArticleListKind
    let model: ArticleListModel
    @Environment(ReadingModel.self) private var reading
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            reading.open(row, on: kind)
        } label: {
            ArticleRowView(row: row)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.articleRow(row.displayTitle))
        .accessibilityActions {
            Button(ArticleActionWording.read(isRead: row.isRead)) { toggleRead() }
            Button(ArticleActionWording.star(isStarred: row.isStarred)) { toggleStar() }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button(ArticleActionWording.read(isRead: row.isRead), systemImage: row.isRead ? "circle.fill" : "circle") {
                toggleRead()
            }
            .tint(Theme.accent)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(ArticleActionWording.star(isStarred: row.isStarred), systemImage: row.isStarred ? "star.slash" : "star") {
                toggleStar()
            }
            .tint(Theme.accent)
        }
        .contextMenu {
            if let url = row.linkURL {
                Button("Open in Browser", systemImage: "safari") {
                    openURL(url)
                }
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Button("Copy Link", systemImage: "link") {
                    UIPasteboard.general.string = url.absoluteString
                }
            }
            Button(ArticleActionWording.read(isRead: row.isRead), systemImage: row.isRead ? "circle.fill" : "circle") {
                toggleRead()
            }
            Button(ArticleActionWording.star(isStarred: row.isStarred), systemImage: row.isStarred ? "star.slash" : "star") {
                toggleStar()
            }
        }
        .listRowBackground(Theme.background)
        .onAppear {
            model.rowAppeared(row.id)
        }
        .onDisappear {
            model.rowDisappeared(row.id)
        }
    }

    private func toggleRead() {
        reading.setRead(row.id, !row.isRead)
    }

    private func toggleStar() {
        reading.setStarred(row.id, !row.isStarred)
    }
}

/// The keyboard shortcuts of a list and of the reading screen opened from it
/// (decision 15), as hidden buttons that call the same model functions as
/// the swipes and taps. None acts while a sheet, the slide-over or the "Mark
/// All as Read" question is open. The arrow keys are left out: measured on
/// the iPad simulators, a down-arrow shortcut did not open the next article.
struct ArticleShortcuts: View {
    let list: ArticleListKind
    @Environment(ReadingModel.self) private var reading

    var body: some View {
        // Whether a key may act is asked when it is pressed, not observed
        // here: re-rendering these buttons while the slide-over closes and a
        // sheet opens kept the sheet from appearing (measured on the iPad
        // mini).
        VStack {
            shortcut("Next Article", "j") {
                Task { await reading.openNext(on: list) }
            }
            shortcut("Previous Article", "k") {
                reading.openPrevious(on: list)
            }
            shortcut("Star or Unstar", "s") {
                reading.toggleStarOfOpenArticle(on: list)
            }
            shortcut("Mark as Read or Unread", "u") {
                reading.toggleReadOfOpenArticle(on: list)
            }
            shortcut("Refresh", "r") {
                Task { await reading.refresh(list) }
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// A button for `key` alone, hidden from VoiceOver; its title names the
    /// command in the system's list of shortcuts.
    private func shortcut(_ title: LocalizedStringKey, _ key: KeyEquivalent, action: @escaping () -> Void) -> some View {
        Button(title) {
            if reading.keysMayAct(on: list) {
                action()
            }
        }
            .keyboardShortcut(key, modifiers: [])
            .accessibilityHidden(true)
    }
}
