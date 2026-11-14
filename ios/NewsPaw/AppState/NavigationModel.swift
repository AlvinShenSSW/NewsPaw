import Foundation
import NewsPawKit
import SwiftUI

enum AppTab: Hashable {
    case today
    case library
    case starred
    case settings
}

/// What the Library stack can show above its root: a list, the article
/// opened from it and that article's page in the embedded browser (RD10).
/// A web-page source's `.source` route shows the browser instead of a list.
/// The Starred stack holds `[.article]` or `[.article, .page]`. Which list a
/// route shows is `NavigationModel.list(of:)`, which knows a source's kind.
enum LibraryRoute: Hashable {
    case allUnread
    case category(UUID)
    case source(UUID)
    case article(UUID)
    /// An article's original page in the embedded browser, above the article.
    case page(URL)
}

/// The two stacks that can show the embedded browser; each holds at most
/// one browser session (RD10 decision 3).
enum BrowserStack: Hashable {
    case library
    case starred

    init(_ list: ArticleListKind) {
        self = list == .starred ? .starred : .library
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
/// | Library, [list, article, page] | the browser pushed on the article | the list, and the browser in the reading pane |
/// | Library, [web-page source] | the browser pushed | sidebar: the source, the browser as one pane |
/// | Starred, [], [article] or [article, page] | Starred tab, the article and the browser pushed | sidebar: Starred, the article or the browser in the reading pane |
/// | Settings | Settings tab | sidebar: Settings |
///
/// There is one open article for the Library lists and one for Starred
/// (RD09 decision 18).
@MainActor @Observable
final class NavigationModel {
    /// The selected tab. Set by the tab bar through `tab`; the model's own
    /// changes do not count as selecting a tab.
    private(set) var currentTab: AppTab = .today
    var libraryPath: [LibraryRoute] = [] {
        didSet {
            if libraryPath != oldValue {
                onStacksChanged?()
            }
        }
    }
    var starredPath: [LibraryRoute] = [] {
        didSet {
            if starredPath != oldValue {
                onStacksChanged?()
            }
        }
    }
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
    /// Called after the Library or the Starred path changed, so that the
    /// browser keeps the session of the browser route on top of each stack
    /// and ends the others (RD10 decision 3). Set by the app model.
    @ObservationIgnored var onStacksChanged: (@MainActor () -> Void)?
    /// Whether a source is a web page, whose route shows the browser rather
    /// than a list. Set by the app model from the source model.
    @ObservationIgnored var isWebPageSource: @MainActor (UUID) -> Bool = { _ in false }

    /// The tab, as the tab bar reads and selects it. Selecting a tab whose
    /// stack has a list at its top enters that list.
    var tab: AppTab {
        get { currentTab }
        set {
            guard newValue != currentTab else { return }
            currentTab = newValue
            switch newValue {
            case .library:
                if let last = libraryPath.last, let list = list(of: last) {
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
        libraryPath.last { list(of: $0) != nil }.flatMap { list(of: $0) }
    }

    /// The list a route shows: none for an article, a page or a web-page
    /// source.
    func list(of route: LibraryRoute) -> ArticleListKind? {
        switch route {
        case .allUnread: .allUnread
        case .category(let id): .category(id)
        case .source(let id): isWebPageSource(id) ? nil : .source(id)
        case .article, .page: nil
        }
    }

    /// The list a sidebar row shows: none for Today, Settings or a web-page
    /// source, which fill the content area as one pane.
    func list(of item: SidebarItem) -> ArticleListKind? {
        switch item {
        case .allUnread: .allUnread
        case .starred: .starred
        case .category(let id): .category(id)
        case .source(let id): isWebPageSource(id) ? nil : .source(id)
        case .today, .settings: nil
        }
    }

    private func path(of stack: BrowserStack) -> [LibraryRoute] {
        stack == .starred ? starredPath : libraryPath
    }

    /// The route at the top of `stack` that shows the browser: an article's
    /// page, or a web-page source.
    func browserRoute(of stack: BrowserStack) -> LibraryRoute? {
        switch path(of: stack).last {
        case .page(let url): .page(url)
        case .source(let id) where isWebPageSource(id): .source(id)
        default: nil
        }
    }

    /// Whether an article's page is shown above the article open on `list`.
    func pageIsOpen(on list: ArticleListKind) -> Bool {
        if case .page = path(of: BrowserStack(list)).last { true } else { false }
    }

    /// The sidebar's selection, derived from the state.
    var sidebarSelection: SidebarItem {
        switch currentTab {
        case .today: return .today
        case .starred: return .starred
        case .settings: return .settings
        case .library:
            // A web-page source shows the browser, not a list.
            if case .source(let id) = libraryPath.first, isWebPageSource(id) {
                return .source(id)
            }
            switch libraryList {
            case .category(let id): return .category(id)
            case .source(let id): return .source(id)
            case .allUnread, .starred, nil: return .allUnread
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
        if let list = list(of: item) {
            onListEntered?(list)
        }
    }

    /// Pushes `route` onto the Library stack (tab structure); a list route
    /// is entered.
    func push(_ route: LibraryRoute) {
        libraryPath.append(route)
        if let list = list(of: route) {
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
        var path = libraryPath.filter { self.list(of: $0) != nil }
        if path.isEmpty {
            path = [Self.route(for: list)]
        }
        libraryPath = path + [.article(id)]
    }

    /// The article open on `list`, if any; also while its page is shown
    /// above it in the browser.
    func openArticle(on list: ArticleListKind) -> UUID? {
        var path = self.path(of: BrowserStack(list))
        if case .page = path.last {
            path.removeLast()
        }
        guard case .article(let id) = path.last else { return nil }
        if list != .starred, (libraryList ?? .allUnread) != list {
            return nil
        }
        return id
    }

    /// Shows `url` in the browser above the article open on `list`: pushed
    /// on it (tabs), in the reading pane (panes). Nothing when no article is
    /// open there.
    func openPage(_ url: URL, on list: ArticleListKind) {
        guard let article = openArticle(on: list) else { return }
        if list == .starred {
            starredPath = [.article(article), .page(url)]
        } else {
            var path = libraryPath
            if case .page = path.last {
                path.removeLast()
            }
            libraryPath = path + [.page(url)]
        }
    }

    /// Closes the browser above the article open on `list`, which is shown
    /// again.
    func closePage(on list: ArticleListKind) {
        if list == .starred {
            if case .page = starredPath.last {
                starredPath.removeLast()
            }
        } else if case .page = libraryPath.last {
            libraryPath.removeLast()
        }
    }

    /// After a category is deleted: if it, or a source it held, was shown,
    /// the selection moves to All Unread (panes) or the Library root (tabs).
    func categoryDeleted(_ id: UUID, sources: Set<UUID>) {
        let shown = libraryPath.contains { route in
            switch route {
            case .category(let category): category == id
            case .source(let source): sources.contains(source)
            case .allUnread, .article, .page: false
            }
        }
        if shown {
            closeLibraryList()
        }
    }

    /// After the sources were read again: a source list whose source no
    /// longer exists closes as a deleted category's does (decision 19).
    func sourcesChanged(existing: Set<UUID>) {
        let gone = libraryPath.contains { route in
            if case .source(let id) = route { !existing.contains(id) } else { false }
        }
        if gone {
            closeLibraryList()
        }
    }

    /// Closes the Library list: the Library root (tabs), All Unread
    /// (panes), which is entered so that it is read again and holds no
    /// article of what was deleted.
    private func closeLibraryList() {
        libraryPath = []
        onListEntered?(.allUnread)
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
