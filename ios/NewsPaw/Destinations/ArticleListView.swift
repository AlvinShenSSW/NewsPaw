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
        let card = overviewCategory
        List {
            if let card {
                // The overview card (RD23 decision 12): the first row, with
                // no swipe and no separator; its height counts towards "the
                // first row is on screen".
                OverviewListCard(category: card)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Theme.background)
                    .listRowInsets(EdgeInsets(
                        top: Theme.Spacing.small, leading: Theme.Spacing.standard, bottom: Theme.Spacing.small,
                        trailing: Theme.Spacing.standard
                    ))
                    .onGeometryChange(for: Double.self) { $0.size.height } action: { height in
                        model.cardMeasured(height: height + 2 * Theme.Spacing.small)
                    }
                    .onDisappear { model.cardMeasured(height: 0) }
                if showsEmptyState {
                    // Below the card, as a row: an overlay would cover it.
                    emptyState
                        .frame(minHeight: 280)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Theme.background)
                }
            }
            ForEach(model.rows) { row in
                ArticleRowButton(row: row, kind: kind, model: model)
            }
            footer
        }
        // Over the list, which still scrolls and refreshes under it
        // (measured: a pull on the empty state refreshes).
        .overlay {
            if showsEmptyState, card == nil {
                emptyState
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // Where the list stands, for "is the first row on screen" (RD11
        // decision 15): the content offset from the top inset, which is the
        // bars and the filter control.
        .onScrollGeometryChange(for: Double.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            model.scrolled(toOffsetFromTop: offset)
        }
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

    // MARK: - The overview card (RD23)

    /// The category whose overview card heads the list: a category's list
    /// whose overviews are on.
    private var overviewCategory: LibraryCategory? {
        guard case .category(let id) = kind, let category = categories.summary(id)?.category, category.overview != .off else {
            return nil
        }
        return category
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

/// A row as a button that opens its article, with the swipes and the menu,
/// and beside the button the translation's mark (RD14 decision 9): a
/// sibling, since the row's label is one accessibility element, so that the
/// mark has its own tap, label and identifier. The first row reports its
/// height, which says how far the list may be scrolled with that row still
/// on screen. A row reports its appearing and disappearing to the
/// workspace's translation.
private struct ArticleRowButton: View {
    @Environment(\.accent) private var accent
    let row: ArticleRow
    let kind: ArticleListKind
    let model: ArticleListModel
    @Environment(ReadingModel.self) private var reading
    @Environment(NavigationModel.self) private var navigation
    @Environment(TranslationModel.self) private var translation: TranslationModel?
    @Environment(TranslationSettings.self) private var translationSettings

    var body: some View {
        let mark = translation?.mark(for: row)
        HStack(alignment: .top, spacing: 0) {
            Button {
                reading.open(row, on: kind)
            } label: {
                ArticleRowView(
                    row: row, translatedTitle: translation == nil ? nil : row.translatedTitle,
                    showsOriginal: translationSettings.showsOriginalTitles, mark: mark
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.articleRow(row.displayTitle))
            .accessibilityActions {
                Button(ArticleActionWording.read(isRead: row.isRead)) { toggleRead() }
                Button(ArticleActionWording.star(isStarred: row.isStarred)) { toggleStar() }
                if case .warning(let question) = mark, let translation {
                    ForEach(TranslationWording.steps(for: question, hasBackup: translation.hasBackup), id: \.self) { step in
                        Button(TranslationWording.title(step)) {
                            TranslationSteps.take(step, for: question, translation: translation, navigation: navigation)
                        }
                    }
                }
            }
            .contextMenu {
                if let url = row.linkURL {
                    // The article is opened first (and so marked read), then its
                    // page above it: closing the browser returns to the article
                    // (RD10 decision 2).
                    Button("Open in Browser", systemImage: "safari") {
                        reading.open(row, on: kind)
                        navigation.openPage(url, on: kind)
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
            if let mark {
                TranslationMarkView(mark: mark, title: row.displayTitle)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button(ArticleActionWording.read(isRead: row.isRead), systemImage: row.isRead ? "circle.fill" : "circle") {
                toggleRead()
            }
            .tint(accent)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(ArticleActionWording.star(isStarred: row.isStarred), systemImage: row.isStarred ? "star.slash" : "star") {
                toggleStar()
            }
            .tint(accent)
        }
        .listRowBackground(Theme.background)
        .onGeometryChange(for: Double.self) { $0.size.height } action: { height in
            if model.rows.first?.id == row.id {
                model.firstRowMeasured(height: height)
            }
        }
        .onAppear {
            translation?.rowAppeared(row)
        }
        .onDisappear {
            translation?.rowDisappeared(row.id)
        }
    }

    private func toggleRead() {
        reading.setRead(row.id, !row.isRead)
    }

    private func toggleStar() {
        reading.setStarred(row.id, !row.isStarred)
    }
}

/// A row's translation mark (decision 9's table): a small activity mark
/// while its article is in a request or its retry was tapped; a small
/// warning mark, with a 44-point target, whose tap asks the question of the
/// failure or the block.
private struct TranslationMarkView: View {
    let mark: TranslationMark
    /// The article's original title, which names the mark's identifier.
    let title: String
    @Environment(TranslationModel.self) private var translation: TranslationModel?

    var body: some View {
        switch mark {
        case .working:
            ProgressView()
                .controlSize(.small)
                .frame(width: Theme.minimumTapTarget, height: Theme.minimumTapTarget)
                .accessibilityLabel(Text("Translating…"))
                .accessibilityIdentifier(AccessibilityID.translationActivity(title))
        case .warning(let question):
            Button {
                translation?.question = question
            } label: {
                Image(systemName: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: Theme.minimumTapTarget, height: Theme.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Not translated"))
            .accessibilityIdentifier(AccessibilityID.translationWarning(title))
        }
    }
}

/// The keyboard shortcuts of a list and of the reading screen opened from it
/// (decision 15), as hidden buttons that call the same model functions as
/// the swipes and taps. None acts while a sheet, the slide-over or the "Mark
/// All as Read" question is open. The arrow keys are left out: measured on
/// the iPad simulators, a down-arrow shortcut did not open the next article.
/// While the browser shows the article's page the buttons are absent, so a
/// letter typed into the page reaches it (RD10 decision 9).
struct ArticleShortcuts: View {
    let list: ArticleListKind
    @Environment(ReadingModel.self) private var reading
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        if !navigation.pageIsOpen(on: list) {
            buttons
        }
    }

    private var buttons: some View {
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
