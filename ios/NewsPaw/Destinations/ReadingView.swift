import NewsPawKit
import SwiftUI

/// The reading pane beside a list: the article open on that list, its
/// page in the browser with Close (RD10), or "No article selected".
struct ReadingPane: View {
    let list: ArticleListKind
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        if navigation.pageIsOpen(on: list) {
            BrowserPane(stack: BrowserStack(list)) {
                navigation.closePage(on: list)
            }
        } else if let id = navigation.openArticle(on: list) {
            ReadingView(articleID: id, list: list, isPushed: false)
        } else {
            ReadingPlaceholderView()
        }
    }
}

/// The reading pane with nothing open.
struct ReadingPlaceholderView: View {
    var body: some View {
        EmptyStateView(title: Text("No article selected"), systemImage: "doc.text", identifier: AccessibilityID.noArticleSelected)
            .stackBackground(Theme.background)
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// The reading screen (spec N05; ux S4; RD11): the header (title; source ·
/// author · time), then the feed's body laid out natively as blocks, with
/// what follows a body that is only an excerpt or was cut. Its navigation
/// bar has "Aa" and a More menu, its bottom bar Star, Share, Open Original
/// Page and Next Article. Nothing of the article runs here: there is no web
/// view on this screen, and a link opens the embedded browser above the
/// article.
struct ReadingView: View {
    let articleID: UUID
    let list: ArticleListKind
    /// Whether the screen is pushed on its list (tab structure). Then it
    /// carries the list's keyboard shortcuts, since the list is not on
    /// screen, and hides the tab bar; in the reading pane the list beside it
    /// carries them.
    let isPushed: Bool
    @Environment(ReadingModel.self) private var reading

    var body: some View {
        content
            .background {
                if isPushed {
                    ArticleShortcuts(list: list)
                }
            }
            .onAppear {
                reading.loadArticle(articleID)
            }
            // Pushed in the tab structure, the tab bar would cover the
            // reading screen's bottom bar (measured on iPhone), so it is
            // hidden while the article is open.
            .toolbar(isPushed ? .hidden : .automatic, for: .tabBar)
            .stackBackground(Theme.background)
            .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var content: some View {
        switch reading.articles[articleID] {
        case .loaded(let row):
            ArticleScreen(row: row, list: list, isPushed: isPushed)
                // Another article in the same place (the reading pane)
                // starts at its top, with nothing of the one before.
                .id(articleID)
        case .missing:
            EmptyStateView(
                title: Text("This article is no longer available."), systemImage: "doc.questionmark",
                identifier: AccessibilityID.articleUnavailable
            )
        case nil:
            Color.clear
        }
    }
}

/// One open article: its header, its body and its bars.
private struct ArticleScreen: View {
    let row: ArticleRow
    let list: ArticleListKind
    let isPushed: Bool
    @Environment(ReadingModel.self) private var reading
    @Environment(NavigationModel.self) private var navigation
    @Environment(ReadingSettings.self) private var settings
    @Environment(TranslationModel.self) private var translation: TranslationModel?
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var isShowingSettings = false
    /// The title's size: 22 pt at the default Dynamic Type size, scaled
    /// with it and, as the body is, by the text-size setting.
    @ScaledMetric(relativeTo: .title2) private var scaledTitleSize = 22.0

    /// The column of ux section 5.
    private static let maximumColumnWidth = 680.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.standard) {
                header
                articleBody
            }
            .frame(maxWidth: Self.maximumColumnWidth, alignment: .leading)
            .padding(Theme.Spacing.standard)
            .frame(maxWidth: .infinity)
        }
        .modifier(ReaderPosition(articleID: row.id, reading: reading))
        .articleSwipes(
            layoutDirection: layoutDirection,
            next: { Task { await reading.openNext(on: list) } },
            // On a pushed screen the swipe towards the trailing edge is the
            // system's: back to the list.
            previous: isPushed ? nil : { reading.openPrevious(on: list) }
        )
        .toolbar { bars }
        .onAppear {
            reading.loadBody(of: row)
            // The reading screen asks for its article as a row does (RD14
            // decision 7).
            translation?.articleOpened(row)
        }
        .onDisappear {
            reading.readingScreenClosed(row.id)
        }
    }

    // MARK: - Header

    /// The translated title (large) with the original under it (small,
    /// secondary) when there is a translation (ux S4; RD14 decision 11),
    /// else the original; then the byline. Model text is plain text.
    @ViewBuilder
    private var header: some View {
        let translated = translation == nil ? nil : row.translatedTitle
        Text(verbatim: translated ?? row.displayTitle)
            .font(.system(size: min(scaledTitleSize * settings.textSize.factor, ReadingMetrics.maximumSize), weight: .bold))
            .foregroundStyle(Theme.text)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(AccessibilityID.readingTitle)
        if translated != nil {
            Text(verbatim: row.displayTitle)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(AccessibilityID.readingOriginalTitle)
        }
        Text(verbatim: byline)
            .font(.subheadline)
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(AccessibilityID.readingByline)
    }

    /// Source · author · time; an absent author is left out.
    private var byline: String {
        var parts = [row.sourceName]
        if let author = row.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            parts.append(author)
        }
        parts.append(row.shownAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }

    // MARK: - Body

    @ViewBuilder
    private var articleBody: some View {
        switch reading.bodies[row.id] {
        case .loaded(let content):
            BlocksView(blocks: content.blocks, settings: settings, images: content.images) { url in
                // In the embedded browser above the article, never Safari.
                navigation.openPage(url, on: list)
            }
            if content.isCut {
                note(
                    row.linkURL == nil
                        ? Text("The rest of this article is not shown.")
                        : Text("The rest of this article is on the original page."),
                    identifier: AccessibilityID.readingCutNote
                )
                openOriginalButton
            } else if !content.isFullText {
                note(Text("Only an excerpt is available"), identifier: AccessibilityID.readingExcerptNote)
                openOriginalButton
            }
        case .failed:
            note(Text("This article could not be shown."), identifier: AccessibilityID.readingBodyFailed)
            Button {
                reading.retryBody(of: row)
            } label: {
                Text("Try Again")
                    .frame(minHeight: Theme.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(.tint)
            .accessibilityIdentifier(AccessibilityID.readingTryAgainButton)
        case .loading, nil:
            EmptyView()
        }
    }

    private func note(_ text: Text, identifier: String) -> some View {
        text
            .font(.footnote)
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
    }

    /// "Open Original Page" under an excerpt or a cut body, for an article
    /// with a link.
    @ViewBuilder
    private var openOriginalButton: some View {
        if let url = row.linkURL {
            Button {
                navigation.openPage(url, on: list)
            } label: {
                Text("Open Original Page")
                    .frame(minHeight: Theme.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(.tint)
            .accessibilityIdentifier(AccessibilityID.openOriginalButton)
        }
    }

    // MARK: - Bars (decision 12)

    @ToolbarContentBuilder
    private var bars: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Reading Settings", systemImage: "textformat.size") {
                isShowingSettings = true
            }
            .accessibilityIdentifier(AccessibilityID.readingSettingsButton)
            .popover(isPresented: $isShowingSettings) {
                ReadingSettingsPopover()
                    .environment(settings)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu("More", systemImage: "ellipsis.circle") {
                Button("Previous Article", systemImage: "chevron.up") {
                    reading.openPrevious(on: list)
                }
                .disabled(!reading.hasPrevious(on: list))
                Button(ArticleActionWording.read(isRead: row.isRead), systemImage: row.isRead ? "circle.fill" : "circle") {
                    reading.setRead(row.id, !row.isRead)
                }
            }
            .accessibilityIdentifier(AccessibilityID.readingMoreMenu)
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Button(ArticleActionWording.star(isStarred: row.isStarred), systemImage: row.isStarred ? "star.fill" : "star") {
                reading.setStarred(row.id, !row.isStarred)
            }
            .accessibilityIdentifier(AccessibilityID.readingStarButton)
            Spacer()
            if let url = row.linkURL {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier(AccessibilityID.readingShareButton)
                Spacer()
                Button("Open Original Page", systemImage: "safari") {
                    navigation.openPage(url, on: list)
                }
                .accessibilityIdentifier(AccessibilityID.readingOriginalBarButton)
                Spacer()
            }
            Button("Next Article", systemImage: "chevron.down") {
                Task { await reading.openNext(on: list) }
            }
            .disabled(!reading.hasNext(on: list))
            .accessibilityIdentifier(AccessibilityID.readingNextButton)
        }
    }
}

/// Keeps the reader's place in an open article (RD11, review round 1).
///
/// The reading screen's scroll view reports the block at its top to the
/// model, and a screen built again for an article that stayed open starts
/// at the block the model holds: in the reading pane the screen is taken
/// away while the article's page is in the browser, and a switch between
/// the tab and the pane structure builds it anew. Nothing more is done
/// for the article's top: an article left with its header on screen comes
/// back with it (measured, and held by the UI test). The position is this
/// modifier's own state, so that scrolling does not lay the screen out
/// again.
private struct ReaderPosition: ViewModifier {
    let articleID: UUID
    let reading: ReadingModel
    @State private var position: ScrollPosition

    init(articleID: UUID, reading: ReadingModel) {
        self.articleID = articleID
        self.reading = reading
        let start = reading.position(of: articleID)
        _position = State(initialValue: start.map { ScrollPosition(id: $0, anchor: .top) } ?? ScrollPosition(idType: Int.self))
    }

    func body(content: Content) -> some View {
        content
            .scrollPosition($position, anchor: .top)
            .onChange(of: position.viewID(type: Int.self)) { _, block in
                reading.readerMoved(to: block, in: articleID)
            }
    }
}
