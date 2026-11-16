import XCTest

/// RD12 criterion 13: the screenshots. Skipped unless
/// `TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR` is set, as the other screenshot
/// tests are; they assert nothing beyond what `FullTextTests` asserts.
final class FullTextScreenshotTests: FullTextTestCase {
    /// A fetched full text with its line, the loading line, the excerpt
    /// state after a page without an article, the alert of a page with no
    /// readable article, and reader mode with its bar. Optionally with
    /// `TEST_RUNNER_NEWSPAW_SCREENSHOT_VARIANT` = `zh` or `largest-text`;
    /// dark appearance is set on the simulator with `xcrun simctl ui`.
    func testCaptureFullTextScreens() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NEWSPAW_SCREENSHOT_DIR"] != nil else {
            throw XCTSkip("set TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR to capture screenshots")
        }
        let variant = environment["NEWSPAW_SCREENSHOT_VARIANT"] ?? "default"
        var arguments: [String] = []
        switch variant {
        case "zh": arguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        case "largest-text": arguments = Self.largestText
        default: break
        }
        // Set up at the default text size, where the shared helpers find
        // the sidebar's buttons without scrolling.
        launchReading(arguments: variant == "largest-text" ? [] : arguments)
        let category = variant == "zh" ? "世界" : "World"
        createCategory(category)
        addSource(FullText.feed, to: category)
        launchReading(arguments: arguments)
        openSourceList(FullText.source, in: category)

        openArticle("Fetched story")
        waitFor(fullTextNote)
        waitFor(block(containing: "Edition "))
        capture("rd12-01-full-text")
        backToList()

        scrollList(to: "Stalled story")
        openArticle("Stalled story")
        waitFor(loadingNote)
        capture("rd12-02-loading")
        backToList()

        scrollList(to: "List story")
        openArticle("List story")
        waitFor(excerptNote)
        capture("rd12-03-no-article-excerpt")
        backToList()

        scrollList(to: "Fetched story")
        openArticle("Fetched story")
        waitFor(fullTextNote)
        openOriginalPage()
        capture("rd12-04-browser-reader-button")
        openReaderMode()
        capture("rd12-05-reader-mode")
        button(AccessibilityID.readerCloseButton).tap()
        waitForAbsence(readerTitle)
        tapLink("the latest stories")
        waitForPage(FullText.listTitle)
        waitForEnabled(readerButton, true)
        readerButton.tap()
        waitFor(app.alerts.firstMatch)
        capture("rd12-06-no-readable-article")
        app.alerts.firstMatch.buttons.firstMatch.tap()
    }
}
