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

    static func disclosure(_ categoryName: String) -> String {
        "row.disclosure." + categoryName
    }

    // Sources
    static let addSourceButton = "sources.add"
    static let sourceRowPrefix = "row.source."

    static func sourceRow(_ name: String) -> String {
        sourceRowPrefix + name
    }

    // Add source
    static let addressField = "add.address"
    static let pasteButton = "add.paste"
    static let continueButton = "add.continue"
    static let addressProblem = "add.addressProblem"
    static let detecting = "add.detecting"
    static let noFeedMessage = "add.noFeed"
    static let duplicateMessage = "add.duplicate"
    static let failureMessage = "add.failure"
    static let saveAsWebPageButton = "add.saveAsWebPage"
    static let tryAnotherAddressButton = "add.tryAnother"
    static let tryAgainButton = "add.tryAgain"
    static let showInLibraryButton = "add.showInLibrary"
    static let suggestedSourcesRow = "add.suggested"
    static let confirmAddress = "add.confirmAddress"
    static let pageItselfChoice = "add.choice.page"
    static let categoryChoiceRow = "add.category"
    static let kindValue = "add.kind"
    static let previewItem = "add.preview"
    static let newCategoryInSheetButton = "add.newCategory"
    static let newCategoryNameField = "add.newCategoryName"
    static let createCategoryButton = "add.createCategory"

    static func candidateChoice(_ address: String) -> String {
        "add.choice." + address
    }

    static func categoryChoice(_ name: String) -> String {
        "add.categoryChoice." + name
    }

    static func suggestedSource(_ name: String) -> String {
        "add.suggested." + name
    }

    // Source settings
    static let sourceAddress = "source.address"
    static let copyAddressButton = "source.copy"
    static let sourceCategoryPicker = "source.category"
    static let pausedToggle = "source.paused"
    static let translateTitlesPicker = "source.translateTitles"
    static let bodyModePicker = "source.body"
    static let translatePageToggle = "source.translatePage"
    static let sourceStatus = "source.status"
    static let updateNowButton = "source.updateNow"
    static let deleteSourceButton = "source.delete"

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
    static let sourceEmpty = "empty.source"
    static let aboutRow = "settings.about"
    static let versionValue = "about.version"

    // Article lists (RD09)
    static let articleRowPrefix = "article.row."
    static let articleFilter = "list.filter"
    static let markAllReadButton = "list.markAllRead"
    static let listMenu = "list.menu"
    static let couldNotLoad = "list.couldNotLoad"
    static let showAllButton = "list.showAll"

    /// A list row, named by the title it shows.
    static func articleRow(_ title: String) -> String {
        articleRowPrefix + title
    }

    // Reading screen (RD09, interim until RD11)
    static let readingTitle = "reading.title"
    static let readingByline = "reading.byline"
    static let readingExcerpt = "reading.excerpt"
    static let readingInterimNote = "reading.interim"
    static let openOriginalButton = "reading.openOriginal"
    static let readingStarButton = "reading.star"
    static let readingShareButton = "reading.share"
    static let readingReadButton = "reading.read"
    static let articleUnavailable = "reading.unavailable"

    // Today (RD09)
    static let todayDate = "today.date"
    static let todayCategoryRowPrefix = "today.category."

    static func todayCategoryRow(_ name: String) -> String {
        todayCategoryRowPrefix + name
    }

    // Settings → Data (RD09)
    static let dataRow = "settings.data"
    static let cacheSize = "data.cacheSize"
    static let clearCacheButton = "data.clearCache"

    // Refresh
    static let todayStatus = "today.status"
    static let failedSourcesButton = "today.failedSources"
    static let refreshRow = "settings.refresh"

    // Models & Translation (RD13)
    static let modelsRow = "settings.models"
    static let primaryModelRow = "models.primary"
    static let backupModelRow = "models.backup"
    static let backupNeedsPrimary = "models.backupNeedsPrimary"
    static let backupIntro = "slot.backupIntro"
    static let modelAddressField = "slot.address"
    static let modelAddressProblem = "slot.addressProblem"
    static let modelNameField = "slot.model"
    static let modelNameProblem = "slot.modelProblem"
    static let loadListButton = "slot.loadList"
    static let loadListLine = "slot.loadListLine"
    static let keyField = "slot.key"
    static let keyProblem = "slot.keyProblem"
    static let storedKey = "slot.storedKey"
    static let keyNeeded = "slot.keyNeeded"
    static let replaceKeyButton = "slot.replaceKey"
    static let removeKeyButton = "slot.removeKey"
    static let cancelReplaceKeyButton = "slot.cancelReplaceKey"
    static let testButton = "slot.test"
    static let testLine = "slot.testLine"
    static let testSentence = "slot.testSentence"
    static let removeModelButton = "slot.removeModel"
    static let removeBackupFirst = "slot.removeBackupFirst"
    static let modelListPrefix = "modelList."

    /// A preset's row in the form's service picker.
    static func presetOption(_ rawValue: String) -> String {
        "slot.preset." + rawValue
    }

    /// A model of the loaded list.
    static func modelListRow(_ name: String) -> String {
        modelListPrefix + name
    }
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
    /// A number of seconds the next category save waits before it runs.
    static let slowNextSave = "NEWSPAW_UITEST_SLOW_NEXT_SAVE"
    /// "1" makes the next source save fail.
    static let failNextSourceSave = "NEWSPAW_UITEST_FAIL_NEXT_SOURCE_SAVE"
    /// A whole number of days added to the app's clock; honoured only with
    /// `libraryDirectory`.
    static let clockOffsetDays = "NEWSPAW_UITEST_CLOCK_OFFSET_DAYS"
}
#endif
