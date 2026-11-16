import XCTest

/// RD14 criterion 17: a list with translated rows (and with the original
/// line), a failed row with its reason, a row blocked by the daily limit
/// with its reason, a row translating, the reading screen's header and
/// Settings › Models & Translation with the three settings.
/// Written when run with `TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR` set (and,
/// optionally, `TEST_RUNNER_NEWSPAW_SCREENSHOT_VARIANT` = `zh` or
/// `largest-text`; dark appearance is set on the simulator with `xcrun
/// simctl ui`). Skipped otherwise: it asserts nothing beyond what
/// `TranslationTests` asserts.
final class TranslationScreenshotTests: TranslationTestCase {
    func testCaptureTranslationScreens() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["NEWSPAW_SCREENSHOT_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR to capture screenshots")
        }
        let variant = environment["NEWSPAW_SCREENSHOT_VARIANT"] ?? "default"
        let device = (environment["SIMULATOR_DEVICE_NAME"] ?? "device").replacingOccurrences(of: " ", with: "-")
        var arguments: [String] = []
        switch variant {
        case "zh": arguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        case "largest-text": arguments = Self.largestText
        default: break
        }
        // The alert's buttons, found by their label: the system orders them
        // (Cancel first when there are two).
        let (retry, cancel) = variant == "zh" ? ("重试", "取消") : ("Retry", "Cancel")
        var count = 0
        func capture(_ name: String) {
            count += 1
            let url = URL(fileURLWithPath: directory)
                .appendingPathComponent(String(format: "%@-%@-translation-%02d-%@.png", device, variant, count, name))
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
        }

        // Set up in English at the default size: the translated feed, and a
        // refused row with a backup set up.
        launchTranslating(models: "primary,backup")
        addFeed(Translation.feed, to: Translation.category)
        waitForLabel(waitFor(articleRow(Translation.foreign(1))), containing: Translation.translated(Translation.foreign(1)))
        addFeed(Translation.wordFeed("refuse"), to: "Refused")
        waitFor(warningMark(Translation.refused))
        // A row the daily limit stops: added at a limit of 0.
        launchTranslating(models: "primary,backup", limit: 0)
        addFeed(Translation.wordFeed("slow"), to: "Slow")
        waitFor(warningMark(Translation.slow))

        // The captures, at a limit of 0 so that nothing changes by itself.
        launchTranslating(models: "primary,backup", limit: 0, arguments: arguments)
        openCategoryList(Translation.category)
        waitFor(articleRow(Translation.foreign(1)))
        capture("list")
        openArticle(Translation.foreign(1), showing: Translation.translated(Translation.foreign(1)))
        capture("article")
        backToList()

        openCategoryList("Refused")
        waitFor(warningMark(Translation.refused))
        capture("refused-row")
        warningMark(Translation.refused).tap()
        waitFor(app.alerts.firstMatch)
        capture("refused-question")
        alertButton(cancel).tap()
        waitForAbsence(app.alerts.firstMatch)

        openCategoryList("Slow")
        waitFor(warningMark(Translation.slow)).tap()
        waitFor(app.alerts.firstMatch)
        capture("limit-question")
        // Retry: the slow word keeps the row translating for two seconds.
        alertButton(retry).tap()
        waitFor(activityMark(Translation.slow))
        capture("translating-row")
        waitForAbsence(activityMark(Translation.slow))

        openTranslationSettings()
        capture("settings")
        let original = app.switches[AccessibilityID.showOriginalTitlesToggle]
        if !(original.exists && original.isHittable) {
            app.swipeUp()
        }
        flip(original)
        capture("settings-original-on")
        // "Foreign story 01" was opened above, so it is read and left out
        // of the Unread list.
        openCategoryList(Translation.category)
        waitFor(articleRow(Translation.foreign(2)))
        capture("list-with-originals")
    }
}
