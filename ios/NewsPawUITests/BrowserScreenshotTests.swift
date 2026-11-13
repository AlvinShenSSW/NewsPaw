import XCTest

/// RD10 criterion 15: the browser with a page, and once per device the
/// loading state, the failure state, the More menu, the other-app question
/// and the file notice. Written when run with
/// `TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR` set (and, optionally,
/// `TEST_RUNNER_NEWSPAW_SCREENSHOT_VARIANT` = `zh`, `largest-text` or
/// `dark`; dark appearance is set on the simulator with `xcrun simctl ui`).
/// The states are captured in the default variant only. Skipped otherwise:
/// it asserts nothing beyond what the other RD10 tests assert.
final class BrowserScreenshotTests: BrowserTestCase {
    func testCaptureBrowserScreens() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["NEWSPAW_SCREENSHOT_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR to capture screenshots")
        }
        let variant = environment["NEWSPAW_SCREENSHOT_VARIANT"] ?? "default"
        let device = (environment["SIMULATOR_DEVICE_NAME"] ?? "device").replacingOccurrences(of: " ", with: "-")
        var arguments: [String] = []
        switch variant {
        case "zh": arguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        case "largest-text": arguments = BrowserLayoutTests.largestText
        default: break
        }
        var count = 0
        func capture(_ name: String) {
            count += 1
            let url = URL(fileURLWithPath: directory)
                .appendingPathComponent(String(format: "%@-%@-browser-%02d-%@.png", device, variant, count, name))
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
        }

        launch(arguments: variant == "largest-text" ? [] : arguments)
        rotate(.portrait)
        requireFullWidth()
        let world = variant == "zh" ? "世界" : "World"
        createCategory(world, icon: "globe")
        addWebPageSource(to: world)
        addSource(Fixture.articles, to: world)

        app.terminate()
        launch(arguments: arguments)
        rotate(.portrait)
        requireFullWidth()
        openWebPageSource(in: world)
        sleep(1)
        capture("web-page-source")
        leaveBrowser()

        // An article's page: pushed on the article (tabs), in the reading
        // pane (panes).
        openCategoryList(world)
        openArticle("Plain story")
        waitFor(button(AccessibilityID.openOriginalButton)).tap()
        waitForPage("Original of plain-story")
        sleep(1)
        capture("article-page")

        guard variant == "default" else { return }
        leaveBrowser()
        openWebPageSource(in: world)
        tapLink("Slow page")
        if element(AccessibilityID.browserProgress).waitForExistence(timeout: 2) {
            capture("loading")
        }
        waitForPage("Slow Page")
        backButton.tap()
        waitForPage(Page.home)

        tapLink("Missing page")
        waitFor(element(AccessibilityID.browserFailure))
        capture("failure")
        backButton.tap()
        waitForPage(Page.home)

        waitFor(moreMenu).tap()
        waitFor(menuButton("Copy Link"))
        capture("more-menu")
        menuButton("Copy Link").tap()
        waitForAbsence(menuButton("Open in Safari"))

        tapLink("Mail link")
        waitFor(alert(Wording.question))
        capture("other-app-question")
        answer(Wording.question, "Cancel")

        tapLink("Download link")
        waitFor(alert(Wording.fileNotice))
        capture("file-notice")
        answer(Wording.fileNotice, "OK")
    }
}
