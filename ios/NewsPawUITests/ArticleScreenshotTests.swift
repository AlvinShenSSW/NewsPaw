import XCTest

/// RD09 criterion 20: a list (unread, with a thumbnail row and a row
/// without; all; empty), Today with rows, Starred, Settings → Data and the
/// interim reading screen. Written when run with
/// `TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR` set (and, optionally,
/// `TEST_RUNNER_NEWSPAW_SCREENSHOT_VARIANT` = `zh` or `largest-text`; dark
/// appearance is set on the simulator with `xcrun simctl ui`). Skipped
/// otherwise: it asserts nothing beyond what the other RD09 tests assert.
final class ArticleScreenshotTests: ArticleTestCase {
    func testCaptureArticleScreens() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["NEWSPAW_SCREENSHOT_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR to capture screenshots")
        }
        let variant = environment["NEWSPAW_SCREENSHOT_VARIANT"] ?? "default"
        let device = (environment["SIMULATOR_DEVICE_NAME"] ?? "device").replacingOccurrences(of: " ", with: "-")
        var arguments: [String] = []
        switch variant {
        case "zh": arguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        case "largest-text": arguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        default: break
        }
        var count = 0
        func capture(_ name: String) {
            count += 1
            let url = URL(fileURLWithPath: directory)
                .appendingPathComponent(String(format: "%@-%@-articles-%02d-%@.png", device, variant, count, name))
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
        }

        // Set up at the default text size, where the shared helpers find
        // the sidebar's buttons without scrolling.
        launch(arguments: variant == "largest-text" ? [] : arguments)
        rotate(.portrait)
        requireFullWidth()
        let world = variant == "zh" ? "世界" : "World"
        let tech = variant == "zh" ? "科技" : "Tech"
        let quiet = variant == "zh" ? "安静" : "Quiet"
        createCategory(world, icon: "globe")
        createCategory(tech, icon: "cpu")
        createCategory(quiet, icon: "leaf")
        addSource(Fixture.articles, to: world)
        addSource(Fixture.feed, to: tech)

        app.terminate()
        launch(arguments: arguments)
        rotate(.portrait)
        requireFullWidth()
        showToday()
        capture("today-rows")

        openCategoryList(world)
        waitFor(articleRow("Image story"))
        // Time for the thumbnail to load.
        sleep(2)
        capture("list-unread-thumbnail-and-without")
        openArticle("Plain story")
        capture("reading-interim")
        backToList()
        swipeAction(on: articleRow("Image story"), leading: false, variant == "zh" ? "收藏" : "Star")
        chooseFilter(variant == "zh" ? "全部" : "All")
        sleep(1)
        capture("list-all")
        openStarred()
        waitFor(articleRow("Image story"))
        sleep(1)
        capture("starred")

        openCategoryList(quiet)
        waitFor(element(AccessibilityID.categoryEmpty))
        capture("list-empty")

        if usesTabs {
            app.tabBars.buttons.element(boundBy: 3).tap()
        } else {
            openSidebarIfNeeded()
            scrollTo(element(AccessibilityID.settingsRow)).tap()
            waitForAbsence(element(AccessibilityID.slideOverPanel))
        }
        scrollTo(element(AccessibilityID.dataRow)).tap()
        let size = waitFor(element(AccessibilityID.cacheSize))
        _ = size.label
        capture("settings-data")
    }
}
