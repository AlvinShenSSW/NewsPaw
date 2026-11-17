import XCTest

/// RD20 criterion 17: the Data section, the adult question, the preview
/// and its lists, the review, the second question, the summary and a
/// refused file. Written when run with `TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR`
/// set (and, optionally, `TEST_RUNNER_NEWSPAW_SCREENSHOT_VARIANT` = `zh` or
/// `largest-text`; dark appearance is set on the simulator with `xcrun
/// simctl ui`). Skipped otherwise: it asserts nothing beyond what
/// `ConfigurationTests` asserts.
final class ConfigurationScreenshotTests: AdultTestCase {
    func testCaptureConfigurationScreens() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["NEWSPAW_SCREENSHOT_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR to capture screenshots")
        }
        let variant = environment["NEWSPAW_SCREENSHOT_VARIANT"] ?? "default"
        let device = (environment["SIMULATOR_DEVICE_NAME"] ?? "device").replacingOccurrences(of: " ", with: "-")
        let arguments: [String] = switch variant {
        case "zh": ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        case "largest-text": ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        default: []
        }
        var count = 0
        func capture(_ name: String) {
            count += 1
            let url = URL(fileURLWithPath: directory)
                .appendingPathComponent(String(format: "%@-%@-configuration-%02d-%@.png", device, variant, count, name))
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
        }
        func launchReading(_ fixture: String, authentication: [String]) {
            let application = XCUIApplication()
            application.launchEnvironment[UITestLaunchKey.configurationFixture] = fixture
            launch(application, arguments: arguments, authentication: authentication)
            rotate(.portrait)
            requireFullWidth()
        }
        func openData() {
            openSettings()
            scrollTo(element(AccessibilityID.dataRow)).tap()
            waitFor(button(AccessibilityID.importConfigurationButton))
        }
        func scrollDownAndCapture(_ name: String) {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.5)
            capture(name)
        }

        launchReading("both", authentication: ["passed", "passed"])
        // Turned on with scrolling: at the largest text size Turn Off is
        // below the fold.
        tapAdultRow()
        scrollTo(adultToggle).coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        scrollTo(turnOffButton)
        openData()
        capture("data-normal")
        button(AccessibilityID.importConfigurationButton).tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: timeout))
        capture("question")
        // "Unlock" in either language.
        app.alerts.firstMatch.buttons.matching(NSPredicate(format: "label IN %@", ["Unlock", "解锁"])).firstMatch.tap()
        // The normal section: at the largest text size the adult one is
        // below the fold.
        waitFor(element(AccessibilityID.configurationCounts("normal")))
        capture("preview")
        scrollDownAndCapture("preview-end")
        scrollTo(button(AccessibilityID.configurationGroup("new", "adult"))).tap()
        Thread.sleep(forTimeInterval: 0.5)
        capture("group-new")
        goBack()
        scrollTo(button(AccessibilityID.configurationSettingsRow)).tap()
        Thread.sleep(forTimeInterval: 0.5)
        capture("settings")
        scrollDownAndCapture("settings-end")
        goBack()
        scrollTo(button(AccessibilityID.configurationReplaceEverythingButton)).tap()
        // The review's title: its Replace button can be below the fold.
        waitFor(app.navigationBars.staticTexts.matching(NSPredicate(format: "label IN %@", ["Before Replacing", "替换前确认"])).firstMatch)
        capture("review")
        scrollDownAndCapture("review-end")
        scrollTo(button(AccessibilityID.configurationReplaceButton)).tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: timeout))
        capture("replace-now")
        // Cancel, by its label: iOS 27 lists an alert's buttons twice.
        let alert = app.alerts.firstMatch
        alert.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch.tap()
        waitForAbsence(alert)
        goBack()
        scrollTo(button(AccessibilityID.configurationMergeButton)).tap()
        waitFor(button(AccessibilityID.configurationDoneButton))
        capture("summary")
        scrollDownAndCapture("summary-end")
        button(AccessibilityID.configurationDoneButton).tap()
        waitForAbsence(button(AccessibilityID.configurationDoneButton))
        openData()
        flip(waitFor(app.switches[AccessibilityID.includeAdultToggle]))
        Thread.sleep(forTimeInterval: 0.5)
        capture("data-adult")
        scrollDownAndCapture("data-adult-end")
        app.terminate()

        launchReading("refused", authentication: [])
        openData()
        button(AccessibilityID.importConfigurationButton).tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: timeout))
        capture("refused")
    }
}
