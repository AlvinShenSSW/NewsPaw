import SwiftUI

/// Which article list a list destination shows.
enum ArticleListKind: Hashable {
    case allUnread
    case starred
    case category(UUID)

    init(_ item: SidebarItem) {
        switch item {
        case .starred: self = .starred
        case .category(let id): self = .category(id)
        case .allUnread, .today, .settings: self = .allUnread
        }
    }
}

/// All Unread, Starred or a category. Until article lists exist (RD09),
/// each says truthfully that it has no articles, or how many unread ones
/// its scope holds.
struct ArticleListView: View {
    let kind: ArticleListKind
    @Environment(CategoryModel.self) private var categories
    @Environment(SourceModel.self) private var sources

    var body: some View {
        emptyState
            .stackBackground(Theme.background)
            .navigationTitle(title)
    }

    @ViewBuilder
    private var emptyState: some View {
        switch kind {
        case .allUnread where sources.totalUnread > 0:
            InterimUnreadView(count: sources.totalUnread)
        case .category(let id) where sources.unreadCount(in: id) > 0:
            InterimUnreadView(count: sources.unreadCount(in: id))
        case .allUnread:
            EmptyStateView(title: Text("All caught up"), systemImage: "checkmark.circle", identifier: AccessibilityID.allUnreadEmpty)
        case .starred:
            EmptyStateView(title: Text("No starred articles"), systemImage: "star", identifier: AccessibilityID.starredEmpty)
        case .category:
            EmptyStateView(title: Text("No articles in this category"), systemImage: "tray", identifier: AccessibilityID.categoryEmpty)
        }
    }

    private var title: Text {
        switch kind {
        case .allUnread: Text("All Unread")
        case .starred: Text("Starred")
        case .category(let id): Text(verbatim: categories.summary(id)?.category.name ?? "")
        }
    }
}

/// The reading pane beside a list.
struct ReadingPlaceholderView: View {
    var body: some View {
        EmptyStateView(title: Text("No article selected"), systemImage: "doc.text", identifier: AccessibilityID.noArticleSelected)
            .stackBackground(Theme.background)
            .navigationBarTitleDisplayMode(.inline)
    }
}
