import XCTest

/// RD21 criterion 14: the first run's three steps (step 3 also with a
/// ticked row, and in landscape on iPad), Today with no source, the
/// no-model question, About and one licence.
/// Written when run with `TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR` set (and,
/// optionally, `TEST_RUNNER_NEWSPAW_SCREENSHOT_VARIANT` = `zh` or
/// `largest-text`; dark appearance is set on the simulator with `xcrun
/// simctl ui`). Skipped otherwise: it asserts nothing beyond what
/// `FirstRunTests`, `TranslationTests` and `SettingsRowTests` assert.
final class FirstRunScreenshotTests: FirstRunTestCase {
    func testCaptureFirstRunScreens() throws {
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
        let cancel = variant == "zh" ? "取消" : "Cancel"
        var count = 0
        func capture(_ name: String) {
            count += 1
            let url = URL(fileURLWithPath: directory)
                .appendingPathComponent(String(format: "%@-%@-firstrun-%02d-%@.png", device, variant, count, name))
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
        }

        launchFirstRun(arguments: arguments)
        waitForStep(1)
        capture("step1")
        // Skip keeps the standard reading language (Simplified Chinese), so
        // that the fixture's English rows are the foreign ones below,
        // whatever the simulator's language preselects.
        skipButton.tap()
        waitForStep(2)
        capture("step2")
        continueButton.tap()
        waitForStep(3)
        capture("step3")
        categoryRow("world").tap()
        XCTAssertTrue(isTicked("world"))
        capture("step3-ticked")
        if isPad {
            rotate(.landscapeLeft)
            requireFullSize()
            waitForStep(3)
            capture("step3-landscape")
            rotate(.portrait)
            requireFullSize()
        }
        skipButton.tap()
        waitForShellOnToday()
        waitFor(button(AccessibilityID.todayAddSourceButton))
        capture("today-no-sources")

        // A source whose foreign rows wait for a model.
        button(AccessibilityID.todayAddSourceButton).tap()
        detect(Translation.feed)
        waitFor(element(AccessibilityID.confirmAddress))
        saveIntoNewCategory("World")
        waitForAbsence(app.textFields[AccessibilityID.addressField])
        openCategoryList("World")
        let mark = waitFor(warningMark(Translation.foreign(1)))
        capture("no-model-row")
        mark.tap()
        waitFor(app.alerts.firstMatch)
        capture("no-model-question")
        alertButton(cancel).tap()
        waitForAbsence(app.alerts.firstMatch)

        openSettings(row: AccessibilityID.aboutRow)
        waitFor(element(AccessibilityID.versionValue))
        capture("about")
        scrollTo(element(AccessibilityID.licenceRow("readability"))).tap()
        waitFor(element(AccessibilityID.licenceText))
        capture("licence")
    }
}
