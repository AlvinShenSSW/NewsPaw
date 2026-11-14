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

/// The reading screen until RD11 lays out the body (RD09 decision 9): the
/// header of ux S4 (title; source · author · time), the excerpt as plain
/// text, one sentence that the full layout is not available yet, and "Open
/// Original Page" when the article has a link, which opens it in the
/// embedded browser above the article (RD10). Its bar has star, share and
/// mark unread.
struct ReadingView: View {
    let articleID: UUID
    let list: ArticleListKind
    /// Whether the screen is pushed on its list (tab structure). Then it
    /// carries the list's keyboard shortcuts, since the list is not on
    /// screen, and hides the tab bar; in the reading pane the list beside it
    /// carries them.
    let isPushed: Bool
    @Environment(ReadingModel.self) private var reading
    @Environment(NavigationModel.self) private var navigation

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
            article(row)
                .toolbar { bar(row) }
        case .missing:
            EmptyStateView(
                title: Text("This article is no longer available."), systemImage: "doc.questionmark",
                identifier: AccessibilityID.articleUnavailable
            )
        case nil:
            Color.clear
        }
    }

    private func article(_ row: ArticleRow) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.standard) {
                Text(verbatim: row.displayTitle)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(AccessibilityID.readingTitle)
                Text(verbatim: byline(row))
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AccessibilityID.readingByline)
                if let excerpt = row.excerpt, !excerpt.isEmpty {
                    Text(verbatim: excerpt)
                        .font(.system(Theme.TypeSize.reading))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier(AccessibilityID.readingExcerpt)
                }
                Text("The full article layout is not available in this version yet.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AccessibilityID.readingInterimNote)
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
            .frame(maxWidth: 680, alignment: .leading)
            .padding(Theme.Spacing.standard)
            .frame(maxWidth: .infinity)
        }
    }

    /// Source · author · time; an absent author is left out.
    private func byline(_ row: ArticleRow) -> String {
        var parts = [row.sourceName]
        if let author = row.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            parts.append(author)
        }
        parts.append(row.shownAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }

    @ToolbarContentBuilder
    private func bar(_ row: ArticleRow) -> some ToolbarContent {
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
            }
            Button(ArticleActionWording.read(isRead: row.isRead), systemImage: row.isRead ? "circle.fill" : "circle") {
                reading.setRead(row.id, !row.isRead)
            }
            .accessibilityIdentifier(AccessibilityID.readingReadButton)
        }
    }
}
