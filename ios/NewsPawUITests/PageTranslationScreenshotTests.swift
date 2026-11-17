import XCTest

/// RD16 criterion 18: the bottom bar with Translate active, each status
/// line, and the More menu with "Always Translate This Source". Written
/// when run with `TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR` set (and, optionally,
/// `TEST_RUNNER_NEWSPAW_SCREENSHOT_VARIANT` = `zh`, `largest-text` or
/// `dark`; dark appearance is set on the simulator with `xcrun simctl ui`).
/// Skipped otherwise: it asserts nothing beyond what the other RD16 tests
/// assert.
final class PageTranslationScreenshotTests: PageTranslationTestCase {
    func testCapturePageTranslationScreens() throws {
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
                .appendingPathComponent(String(format: "%@-%@-pages-%02d-%@.png", device, variant, count, name))
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
        }
        func line(_ identifier: String? = nil) {
            _ = waitFor(self.line)
            if let identifier {
                _ = waitFor(button(identifier))
            }
            sleep(1)
        }

        // Without a model: the line with its link.
        launchPages(models: nil, arguments: arguments)
        openListSource()
        tapTranslate()
        line(AccessibilityID.pageTranslationOpenSettings)
        capture("no-model")

        // With the primary and the backup, and a ceiling of two requests.
        launchPages(models: "primary,backup", ceiling: 2, arguments: arguments)
        openList()
        tapTranslate()
        _ = waitFor(webText(Self.translated(Pages.item(1))))
        line(AccessibilityID.pageTranslationShowOriginal)
        capture("translated")
        waitFor(moreMenu).tap()
        sleep(1)
        capture("more-menu")
        // Away from the page's links: on the navigation bar's title.
        app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForPage(Pages.listTitle)

        openFixture("refusing", title: "拒否されるページ")
        line(AccessibilityID.pageTranslationRetryBackup)
        capture("part-failed")
        backButton.tap()
        waitForPage(Pages.listTitle)
        openFixture("endless", title: "終わらないページ")
        line(AccessibilityID.pageTranslationContinue)
        capture("paused")
        backButton.tap()
        waitForPage(Pages.listTitle)
        // A page reached while on with nothing to translate.
        openFixture("zh-hans", title: "简体中文页面")
        line(AccessibilityID.pageTranslationShowOriginal)
        capture("nothing-while-on")
        // The same page on a tap: the brief message, Translate off.
        tapTranslate()
        waitForTranslate(on: false)
        tapTranslate()
        _ = waitFor(self.line)
        capture("nothing-on-tap")
        // While a request is in flight: "Translating…".
        backButton.tap()
        waitForPage(Pages.listTitle)
        openFixture("never-loads", title: "読み込みが終わらないページ")
        _ = waitFor(self.line)
        capture("translating")
    }
}
