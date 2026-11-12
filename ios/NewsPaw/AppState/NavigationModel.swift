import Foundation
import SwiftUI

enum AppTab: Hashable {
    case today
    case library
    case starred
    case settings
}

/// What the Library stack can show above its root.
enum LibraryRoute: Hashable {
    case allUnread
    case category(UUID)
}

enum SettingsRoute: Hashable {
    case about
}

/// A row of the sidebar.
enum SidebarItem: Hashable {
    case today
    case allUnread
    case starred
    case category(UUID)
    case settings

    /// Whether the destination is a list (list pane and reading pane) rather
    /// than one pane.
    var isList: Bool {
        switch self {
        case .allUnread, .starred, .category: true
        case .today, .settings: false
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
/// | Starred | Starred tab | sidebar: Starred |
/// | Settings | Settings tab | sidebar: Settings |
@MainActor @Observable
final class NavigationModel {
    var tab: AppTab = .today
    var libraryPath: [LibraryRoute] = []
    var settingsPath: [SettingsRoute] = []
    /// Whether the slide-over sidebar is open (panes below 1100 pt only).
    private(set) var isSlideOverOpen = false

    /// The sidebar's selection, derived from the state.
    var sidebarSelection: SidebarItem {
        switch tab {
        case .today: .today
        case .starred: .starred
        case .settings: .settings
        case .library:
            switch libraryPath.last {
            case .category(let id): .category(id)
            case .allUnread, nil: .allUnread
            }
        }
    }

    /// Writes a sidebar choice back to the state.
    func select(_ item: SidebarItem) {
        switch item {
        case .today:
            tab = .today
        case .starred:
            tab = .starred
        case .settings:
            tab = .settings
        case .allUnread:
            tab = .library
            libraryPath = [.allUnread]
        case .category(let id):
            tab = .library
            libraryPath = [.category(id)]
        }
    }

    /// After a category is deleted: if it was shown, the selection moves to
    /// All Unread (panes) or the Library root (tabs).
    func categoryDeleted(_ id: UUID) {
        if libraryPath.contains(.category(id)) {
            libraryPath = []
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
}
