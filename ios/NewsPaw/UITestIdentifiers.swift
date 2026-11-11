// Compiled into the app and into the UI-test target (see the project's
// membership exception), so the identifiers the UI tests rely on have one
// definition. Plain Swift only: the UI-test target does not import SwiftUI.

/// Accessibility identifiers of the panes and controls the UI tests use.
enum AccessibilityID {
    // Panes
    static let sidebarPane = "pane.sidebar"
    static let slideOverPanel = "pane.slideOver"
    static let listPane = "pane.list"
    static let readingPane = "pane.reading"
    static let fullPane = "pane.full"

    // Sidebar
    static let showSidebarButton = "sidebar.show"
    static let closeSidebarButton = "sidebar.close"
    static let todayRow = "row.today"
    static let allUnreadRow = "row.allUnread"
    static let starredRow = "row.starred"
    static let settingsRow = "row.settings"

    // Category list
    static let editButton = "categories.edit"
    static let addMenu = "categories.add"
    static let newCategoryButton = "categories.new"
    static let noCategories = "categories.empty"
    static let categoriesLoadFailed = "categories.loadFailed"
    static let categoryRowPrefix = "row.category."

    static func categoryRow(_ name: String) -> String {
        categoryRowPrefix + name
    }

    // Category editor sheets
    static let nameField = "editor.name"
    static let nameTooLongMessage = "editor.nameTooLong"
    static let saveButton = "editor.save"
    static let cancelButton = "editor.cancel"
    static let deleteCategoryButton = "editor.delete"

    static func iconButton(_ symbolName: String) -> String {
        "editor.icon." + symbolName
    }

    // Destinations
    static let todayEmpty = "empty.today"
    static let allUnreadEmpty = "empty.allUnread"
    static let starredEmpty = "empty.starred"
    static let categoryEmpty = "empty.category"
    static let noArticleSelected = "empty.reading"
    static let aboutRow = "settings.about"
    static let versionValue = "about.version"
}

#if DEBUG
/// Launch-environment keys that debug builds accept from the UI tests and
/// nowhere else. Release builds contain neither the keys nor their handling.
enum UITestLaunchKey {
    /// A single path component: the subdirectory of the app's temporary
    /// directory to use as the library directory.
    static let libraryDirectory = "NEWSPAW_UITEST_LIBRARY_DIRECTORY"
    /// A number of synthetic sources to put into the first category.
    static let syntheticSources = "NEWSPAW_UITEST_SYNTHETIC_SOURCES"
    /// "1" makes the next category save fail.
    static let failNextSave = "NEWSPAW_UITEST_FAIL_NEXT_SAVE"
}
#endif
