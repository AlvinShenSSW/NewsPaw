import XCTest

/// Shared steps of the RD14 tests: the translator fixture's models set up
/// at launch, the translation feeds of the fixture transport, and the
/// marks and questions of a row. The translator answers each text with
/// "译[<language asked for>]：" before it.
@MainActor
class TranslationTestCase: ReadingTestCase {
    enum Translation {
        static let feed = "https://translation.example.invalid/rss.xml"
        static let source = "Translation Feed"
        static let category = "World"
        /// The feed's first three items, newest first, then "Foreign story
        /// 01" … "60".
        static let markup = "Markup <b>bold</b> **stars** [a link](https://example.invalid)"
        static let simplified = "国务院发布新的数据安全管理条例"
        static let traditional = "台灣半導體產業持續擴張"
        static let traditionalConverted = "台湾半导体产业持续扩张"

        static func foreign(_ number: Int) -> String {
            String(format: "Foreign story %02d", number)
        }

        /// A feed of one item that holds the translator's word.
        static func wordFeed(_ word: String) -> String {
            "https://translationwords.example.invalid/\(word).xml"
        }

        static let refused = "A story the model refuses fixture:refuse"
        static let refusingSource = "Refusing Feed"
        static let limited = "A story the service limits fixture:limit"
        static let limitedSource = "Limited Feed"
        static let slow = "A story that takes its time fixture:slow"
        static let slowSource = "Slow Translation Feed"

        /// What the translator makes of `text` in `language`.
        static func translated(_ text: String, _ language: String = "zh-Hans") -> String {
            "译[\(language)]：" + text
        }
    }

    enum Sentence {
        static let refused = "The model declined to translate this"
        static let limited = "The service is limiting requests. Try again later"
        static let dailyLimit = "Today's automatic limit is reached. Translate manually, or raise the limit in Settings"
        static let notTranslated = "Not translated"
    }

    /// Launches on this test's library with the translator's models — the
    /// primary, or the primary and the backup — and, when given, the daily
    /// automatic limit.
    func launchTranslating(
        models: String = "primary", limit: Int? = nil, arguments: [String] = [], _ orientation: UIDeviceOrientation = .portrait
    ) {
        app.terminate()
        let application = XCUIApplication()
        application.launchEnvironment[UITestLaunchKey.translationModels] = models
        if let limit {
            application.launchEnvironment[UITestLaunchKey.dailyAutomaticLimit] = String(limit)
        }
        launch(application, arguments: arguments)
        rotate(orientation)
        requireFullSize()
    }

    /// On the panes Settings › Models & Translation, pushed on the leading
    /// pane, has the back button where the sidebar button is: it is left
    /// first (as `AdultTestCase` does).
    override func openSidebarIfNeeded() {
        var backs = 0
        while !app.tabBars.firstMatch.exists, !element(AccessibilityID.sidebarPane).exists,
              !element(AccessibilityID.slideOverPanel).exists,
              !button(AccessibilityID.showSidebarButton).waitForExistence(timeout: 1), backs < 3 {
            goBack()
            backs += 1
        }
        super.openSidebarIfNeeded()
    }

    /// Creates `category`, adds `feed` to it and opens the category's list.
    func addFeed(_ feed: String, to category: String) {
        createCategory(category)
        addSource(feed, to: category)
        openCategoryList(category)
    }

    func warningMark(_ title: String) -> XCUIElement {
        button(AccessibilityID.translationWarning(title))
    }

    func activityMark(_ title: String) -> XCUIElement {
        element(AccessibilityID.translationActivity(title))
    }

    /// The alert of a row's question, by its sentence.
    func question(_ sentence: String) -> XCUIElement {
        app.alerts.matching(NSPredicate(format: "label == %@", sentence)).firstMatch
    }

    /// The alert's button `label`.
    func alertButton(_ label: String) -> XCUIElement {
        app.alerts.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// The labels of the open alert's buttons (the system orders them).
    func alertButtonLabels() -> [String] {
        app.alerts.firstMatch.buttons.allElementsBoundByIndex.map(\.label)
    }

    /// Opens a row's article by tapping the row, and waits for the reading
    /// screen's title to read `shown`.
    func openArticle(_ title: String, showing shown: String) {
        waitFor(articleRow(title)).tap()
        waitForTitle(shown)
    }

    /// Settings › Models & Translation.
    func openTranslationSettings() {
        openSettings(row: AccessibilityID.modelsRow)
        waitFor(element(AccessibilityID.primaryModelRow))
    }
}
