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
    @State private var isShowingInfo = false
    /// The title's size: 22 pt at the default Dynamic Type size, scaled
    /// with it and, as the body is, by the text-size setting.
    @ScaledMetric(relativeTo: .title2) private var scaledTitleSize = 22.0

    /// The column of ux section 5.
    private static let maximumColumnWidth = 680.0

    /// The body's translation (RD15): only in a workspace with translation.
    private var body_: BodyTranslationModel? {
        translation?.body
    }

    private var key: BodyKey {
        .article(row.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.standard) {
                header
                articleBody
            }
            .frame(maxWidth: Self.maximumColumnWidth, alignment: .leading)
            .padding(Theme.Spacing.standard)
            .frame(maxWidth: .infinity)
            // The scroll content's own coordinates, for the rows' frames.
            .coordinateSpace(.named(BlockRowFrames.space))
        }
        // "Translating k of n" under the navigation bar while work runs
        // (assumption A4).
        .safeAreaInset(edge: .top, spacing: 0) {
            if let progress = body_?.progress(of: key) {
                BodyProgressLine(progress: progress)
            }
        }
        .modifier(ReaderPosition(articleID: row.id, reading: reading, mode: body_?.mode(of: key)))
        // A body replaced by the article's page (RD12) starts at the top,
        // header and all: the scroll view and its position are made anew.
        // (Kept, the position would hold the old body's block at the top
        // of the screen, and the new body's block of that number with it.)
        .id(reading.replacements[row.id] ?? 0)
        .articleSwipes(
            layoutDirection: layoutDirection,
            next: { Task { await reading.openNext(on: list) } },
            // On a pushed screen the swipe towards the trailing edge is the
            // system's: back to the list.
            previous: isPushed ? nil : { reading.openPrevious(on: list) }
        )
        .toolbar { bars }
        .sheet(isPresented: $isShowingInfo) {
            ArticleInfoView(row: row, content: content, key: key)
                .environment(translation)
        }
        .onAppear {
            reading.loadBody(of: row)
            // The reading screen asks for its article as a row does (RD14
            // decision 7).
            translation?.articleOpened(row)
            // Leaving the screen stops the body's work; coming back
            // resumes it (RD15 decision 9).
            body_?.screenAppeared(key)
        }
        .onDisappear {
            reading.readingScreenClosed(row.id)
            translation?.articleClosed(row.id)
            body_?.screenDisappeared(key)
        }
    }

    /// The body shown now, settled or interim.
    private var content: ReadingContent? {
        switch reading.bodies[row.id] {
        case .loaded(let content): content
        case .fetching(let feed): feed
        default: nil
        }
    }

    // MARK: - Header

    /// The translated title (large) with the original under it (small,
    /// secondary) when there is a translation (ux S4; RD14 decision 11),
    /// else the original; then the byline. Model text is plain text.
    @ViewBuilder
    private var header: some View {
        let translated = translation == nil ? nil : row.translatedTitle
        // Each line carries its language for VoiceOver (RD15 decision 13):
        // the translation the reading language, the original the
        // recognizer's.
        let originalLanguage = translation == nil ? nil : BodySegments.language(of: row.displayTitle)
        Text(verbatim: translated ?? row.displayTitle)
            .speechLanguage(translated != nil ? body_?.readingLocale.rawValue : originalLanguage)
            .font(.system(size: min(scaledTitleSize * settings.textSize.factor, ReadingMetrics.maximumSize), weight: .bold))
            .foregroundStyle(Theme.text)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(AccessibilityID.readingTitle)
        if translated != nil {
            Text(verbatim: row.displayTitle)
                .speechLanguage(originalLanguage)
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
            if content.isExtracted {
                note(Text("Full text from the original page"), identifier: AccessibilityID.readingFullTextNote)
            }
            // The banner is the first content above the body (ux S4).
            if let body_, let banner = body_.banner(of: key, hasBackup: translation?.hasBackup ?? false) {
                BodyBannerView(banner: banner) { step in
                    take(step, body: body_)
                }
            }
            blocks(content)
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
        case .fetching(let feed):
            // Where the full-text line then stands (RD12 decision 4).
            HStack(spacing: Theme.Spacing.small) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text("Loading the full text…")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.readingLoadingNote)
            if let feed {
                blocks(feed)
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

    private func blocks(_ content: ReadingContent) -> some View {
        BlocksView(blocks: content.blocks, settings: settings, images: content.images, translation: blockTranslation) { url in
            // In the embedded browser above the article, never Safari.
            navigation.openPage(url, on: list)
        }
    }

    /// What the blocks show of the body's translation.
    private var blockTranslation: BlockTranslation? {
        guard let body_, body_.openings[key]?.plan != nil else { return nil }
        let key = key
        return BlockTranslation(
            mode: body_.mode(of: key), language: body_.readingLocale.rawValue,
            text: { body_.translatedText(of: $0, in: key) }, originalLanguage: { body_.originalLanguage(of: $0, in: key) }
        )
    }

    /// A banner step.
    private func take(_ step: TranslationWording.Step, body: BodyTranslationModel) {
        switch step {
        case .retry: body.translate(key)
        case .retryWithBackup: body.retryWithBackup(key)
        case .openSettings: navigation.openModelSettings()
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
                if let body_ {
                    Button("Copy Translation", systemImage: "doc.on.doc") {
                        if let text = body_.copyText(of: key, title: row.translatedTitle ?? row.displayTitle) {
                            UIPasteboard.general.string = text
                        }
                    }
                    .disabled(!body_.hasTranslation(key))
                    .accessibilityIdentifier(AccessibilityID.copyTranslationButton)
                }
                Button("Article Info", systemImage: "info.circle") {
                    isShowingInfo = true
                }
                .accessibilityIdentifier(AccessibilityID.articleInfoButton)
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
            // Display mode first (ux S4): Translate, or the mode menu.
            if let body_, body_.control(for: key) != .none {
                BodyControlView(
                    control: body_.control(for: key), mode: body_.mode(of: key),
                    translate: { body_.translate(key) }, setMode: { body_.setMode($0, of: key) }
                )
                Spacer()
            }
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
///
/// A change of display mode sets the block that was at the top back at the
/// top (RD15 decision 11, assumption A3).
struct ReaderPosition: ViewModifier {
    let articleID: UUID
    let reading: ReadingModel
    /// The body's display mode; `nil` without translation.
    var mode: ReadingDisplayMode?
    @State private var position: ScrollPosition

    init(articleID: UUID, reading: ReadingModel, mode: ReadingDisplayMode? = nil) {
        self.articleID = articleID
        self.reading = reading
        self.mode = mode
        let start = reading.position(of: articleID)
        _position = State(initialValue: start.map { ScrollPosition(id: $0, anchor: .top) } ?? ScrollPosition(idType: Int.self))
    }

    /// Where the reader's rows are and where the visible top edge is, in
    /// the content's coordinates: not observed, read at a switch.
    @State private var rows = BlockRowFrames()

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            positioned(content, proxy: proxy)
        }
    }

    private func positioned(_ content: Content, proxy: ScrollViewProxy) -> some View {
        content
            .environment(\.blockRowFrames, rows)
            .scrollPosition($position, anchor: .top)
            .onScrollGeometryChange(for: Double.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, top in
                rows.visibleTop = top
            }
            .onChange(of: position.viewID(type: Int.self)) { _, block in
                reading.readerMoved(to: block, in: articleID)
            }
            .onChange(of: mode) {
                keepTopBlock(proxy)
            }
    }

    /// Counts the switches, so that a newer one ends an older one's
    /// scrolls.
    @State private var switches = 0

    /// The block at the top stays there across a switch (assumption A3).
    /// It is the block whose row holds the visible top edge before the
    /// switch — not the position's `viewID`, which names the first block
    /// below that edge (measured: the reader saw block 16 at the top and
    /// the position held 17). That block is scrolled to the top, and
    /// scrolled to again after the lazy stack's next passes while the rows
    /// around it take their new sizes; a newer switch ends these scrolls.
    ///
    /// Measured on the iPhone (fix round 1): scrolled to once, going into
    /// Side by Side it landed 233 pt low (in the same update as the
    /// switch) or 878 pt low (after one layout pass), or 790–970 pt above
    /// the top (scrolled to before the blocks changed): the rows above it
    /// are scrolled through at sizes not yet measured in the new mode. With
    /// the scrolls repeated over 0.5 s its first line stayed at the top
    /// (131 pt, the bar ending at 116) in every switch. Nothing is
    /// scrolled at the article's top.
    private func keepTopBlock(_ proxy: ScrollViewProxy) {
        guard let block = rows.block(atTop: rows.visibleTop) else { return }
        switches += 1
        let switchNumber = switches
        proxy.scrollTo(block, anchor: .top)
        Task { @MainActor in
            for delay in [0, 50, 150, 300] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard switchNumber == switches else { return }
                proxy.scrollTo(block, anchor: .top)
            }
        }
    }
}
