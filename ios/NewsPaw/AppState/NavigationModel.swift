import Foundation
import NewsPawKit
import SwiftUI

enum AppTab: Hashable {
    case today
    case library
    case starred
    case settings
}

/// What the Library stack can show above its root: a list, and the article
/// opened from it. The Starred stack holds only `.article`.
enum LibraryRoute: Hashable {
    case allUnread
    case category(UUID)
    case source(UUID)
    case article(UUID)

    /// The list this route shows; `nil` for an article.
    var list: ArticleListKind? {
        switch self {
        case .allUnread: .allUnread
        case .category(let id): .category(id)
        case .source(let id): .source(id)
        case .article: nil
        }
    }
}

/// Which article list a list destination shows (RD09 decision 1).
enum ArticleListKind: Hashable {
    case allUnread
    case starred
    case category(UUID)
    case source(UUID)

    init(_ item: SidebarItem) {
        switch item {
        case .starred: self = .starred
        case .category(let id): self = .category(id)
        case .source(let id): self = .source(id)
        case .allUnread, .today, .settings: self = .allUnread
        }
    }

    /// The articles the list reads.
    var scope: ArticleScope {
        switch self {
        case .allUnread: .library
        case .starred: .starred
        case .category(let id): .category(id)
        case .source(let id): .source(id)
        }
    }

    /// What its Refresh collects: the category, the source, or the whole
    /// library for All Unread and Starred (decision 12).
    var refreshScope: RefreshScope {
        switch self {
        case .allUnread, .starred: .library
        case .category(let id): .category(id)
        case .source(let id): .source(id)
        }
    }

    /// Whether the list has the Unread / All control: a category or a
    /// source. All Unread is unread by definition and Starred shows every
    /// starred article.
    var hasFilter: Bool {
        switch self {
        case .category, .source: true
        case .allUnread, .starred: false
        }
    }

    /// The filter of a list without the control.
    var fixedFilter: ArticleFilter {
        self == .allUnread ? .unread : .all
    }

    /// Whether "Mark All as Read" is offered: everywhere but Starred.
    var offersMarkAllRead: Bool {
        self != .starred
    }
}

enum SettingsRoute: Hashable {
    case refresh
    case data
    case about
}

/// The one sheet presented from the root. Two sheets can never be asked for
/// at once, and "is a sheet open" has one answer for every dialog host.
enum AppSheet: Hashable, Identifiable {
    case newCategory
    case categorySettings(UUID)
    case addSource
    case sourceSettings(UUID)

    var id: Self { self }
}

/// A row of the sidebar.
enum SidebarItem: Hashable {
    case today
    case allUnread
    case starred
    case category(UUID)
    case source(UUID)
    case settings

    /// Whether the destination is a list (list pane and reading pane) rather
    /// than one pane.
    var isList: Bool {
        list != nil
    }

    /// The list the row shows.
    var list: ArticleListKind? {
        switch self {
        case .allUnread: .allUnread
        case .starred: .starred
        case .category(let id): .category(id)
        case .source(let id): .source(id)
        case .today, .settings: nil
        }
    }
}

/// Where the user is, in one form that the tab container and the pane
/// container both read, so a change of width needs no translation:
///
/// | State | Tabs | Panes |
/// | --- | --- | --- |
/// | Today | Today tab | sidebar: Today |
/// | Library, empty path | Library root | sidebar: All Unread |
/// | Library, [All Unread] | All Unread pushed | sidebar: All Unread |
/// | Library, [category] | the category pushed | sidebar: the category |
/// | Library, [source] | the source pushed | sidebar: the source |
/// | Library, [list, article] | the article pushed on the list | the list, and the article in the reading pane |
/// | Starred, [] or [article] | Starred tab, the article pushed | sidebar: Starred, the article in the reading pane |
/// | Settings | Settings tab | sidebar: Settings |
///
/// There is one open article for the Library lists and one for Starred
/// (RD09 decision 18).
@MainActor @Observable
final class NavigationModel {
    /// The selected tab. Set by the tab bar through `tab`; the model's own
    /// changes do not count as selecting a tab.
    private(set) var currentTab: AppTab = .today
    var libraryPath: [LibraryRoute] = []
    var starredPath: [LibraryRoute] = []
    var settingsPath: [SettingsRoute] = []
    /// Whether the slide-over sidebar is open (panes below 1100 pt only).
    private(set) var isSlideOverOpen = false
    /// The sheet presented from the root.
    var sheet: AppSheet?
    /// The window's current layout, set by the shell, so that "Show in
    /// Library" knows where the category list is.
    var layout: WindowLayout?
    /// Called when a list is entered (decision 3): its route is pushed, the
    /// sidebar selection changes to it, or its tab is selected while it is
    /// the top of that tab's stack. Set by the app model.
    @ObservationIgnored var onListEntered: (@MainActor (ArticleListKind) -> Void)?

    /// The tab, as the tab bar reads and selects it. Selecting a tab whose
    /// stack has a list at its top enters that list.
    var tab: AppTab {
        get { currentTab }
        set {
            guard newValue != currentTab else { return }
            currentTab = newValue
            switch newValue {
            case .library:
                if let list = libraryPath.last?.list {
                    onListEntered?(list)
                }
            case .starred:
                if starredPath.isEmpty {
                    onListEntered?(.starred)
                }
            case .today, .settings:
                break
            }
        }
    }

    /// The list of the Library stack: the last list route of its path, or
    /// `nil` at the root (which the panes show as All Unread).
    var libraryList: ArticleListKind? {
        libraryPath.last { $0.list != nil }?.list
    }

    /// The sidebar's selection, derived from the state.
    var sidebarSelection: SidebarItem {
        switch currentTab {
        case .today: .today
        case .starred: .starred
        case .settings: .settings
        case .library:
            switch libraryList {
            case .category(let id): .category(id)
            case .source(let id): .source(id)
            case .allUnread, .starred, nil: .allUnread
            }
        }
    }

    /// Writes a sidebar choice back to the state. Choosing the row already
    /// selected changes nothing; choosing another list enters it, and a new
    /// Library list closes the article open on the previous one.
    func select(_ item: SidebarItem) {
        guard item != sidebarSelection else { return }
        switch item {
        case .today:
            currentTab = .today
        case .starred:
            currentTab = .starred
        case .settings:
            currentTab = .settings
        case .allUnread:
            libraryPath = [.allUnread]
            currentTab = .library
        case .category(let id):
            libraryPath = [.category(id)]
            currentTab = .library
        case .source(let id):
            libraryPath = [.source(id)]
            currentTab = .library
        }
        if let list = item.list {
            onListEntered?(list)
        }
    }

    /// Pushes `route` onto the Library stack (tab structure); a list route
    /// is entered.
    func push(_ route: LibraryRoute) {
        libraryPath.append(route)
        if let list = route.list {
            onListEntered?(list)
        }
    }

    /// Opens the article `id` on `list`: pushed on the list (tabs), in the
    /// reading pane (panes). It replaces an article already open there.
    func openArticle(_ id: UUID, on list: ArticleListKind) {
        if list == .starred {
            starredPath = [.article(id)]
            return
        }
        var path = libraryPath.filter { $0.list != nil }
        if path.isEmpty {
            path = [Self.route(for: list)]
        }
        libraryPath = path + [.article(id)]
    }

    /// The article open on `list`, if any.
    func openArticle(on list: ArticleListKind) -> UUID? {
        let path = list == .starred ? starredPath : libraryPath
        guard case .article(let id) = path.last else { return nil }
        if list != .starred, (libraryList ?? .allUnread) != list {
            return nil
        }
        return id
    }

    /// After a category is deleted: if it, or a source it held, was shown,
    /// the selection moves to All Unread (panes) or the Library root (tabs).
    func categoryDeleted(_ id: UUID, sources: Set<UUID>) {
        let shown = libraryPath.contains { route in
            switch route {
            case .category(let category): category == id
            case .source(let source): sources.contains(source)
            case .allUnread, .article: false
            }
        }
        if shown {
            libraryPath = []
        }
    }

    /// After the sources were read again: a source list whose source no
    /// longer exists closes as a deleted category's does (decision 19).
    func sourcesChanged(existing: Set<UUID>) {
        let gone = libraryPath.contains { route in
            if case .source(let id) = route { !existing.contains(id) } else { false }
        }
        if gone {
            libraryPath = []
        }
    }

    /// The category open in Library: the one pushed in the tab structure,
    /// the one selected in the sidebar.
    var openCategory: UUID? {
        guard currentTab == .library, case .category(let id) = libraryList else { return nil }
        return id
    }

    /// Closes the sheet and, in the same state change, shows the category
    /// list where it is.
    func closeSheetAndShowCategoryList() {
        sheet = nil
        showCategoryList()
    }

    /// Shows the category list where it is: the Library tab at its root in
    /// the tab structure; the sidebar pane from 1100 pt; the slide-over,
    /// opened, below 1100 pt.
    func showCategoryList() {
        guard let layout else { return }
        if layout.structure == .tabs {
            currentTab = .library
            libraryPath = []
        } else if !layout.sidebarIsPane {
            openSlideOver()
        }
    }

    /// Opens the slide-over sidebar. The cover's own presentation animation
    /// is switched off; the panel animates itself.
    func openSlideOver() {
        setSlideOver(true)
    }

    /// Closes the slide-over sidebar at once.
    func closeSlideOver() {
        setSlideOver(false)
    }

    private func setSlideOver(_ open: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isSlideOverOpen = open
        }
    }

    private static func route(for list: ArticleListKind) -> LibraryRoute {
        switch list {
        case .allUnread, .starred: .allUnread
        case .category(let id): .category(id)
        case .source(let id): .source(id)
        }
    }
}
