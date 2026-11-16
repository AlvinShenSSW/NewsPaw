import XCTest

/// Writes the screenshots of RD19 criterion 16 when run with
/// `TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR` set (and, optionally,
/// `TEST_RUNNER_NEWSPAW_SCREENSHOT_VARIANT` = `zh`, `largest-text` or `dark`;
/// dark appearance is set on the simulator with `xcrun simctl ui`): Settings
/// › Adult Partition from both entry points, the model form inside it, the
/// Clear question and its footer, the move's confirmation and two of its
/// messages. Skipped otherwise: it asserts nothing beyond what the other
/// tests assert.
final class IsolationScreenshotTests: IsolationTestCase {
    func testCaptureIsolationScreens() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["NEWSPAW_SCREENSHOT_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR to capture screenshots")
        }
        let variant = environment["NEWSPAW_SCREENSHOT_VARIANT"] ?? "default"
        let device = (environment["SIMULATOR_DEVICE_NAME"] ?? "device").replacingOccurrences(of: " ", with: "-")
        let language = variant == "zh" ? ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] : []
        let size = variant == "largest-text" ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : []
        var count = 0
        func capture(_ name: String) {
            count += 1
            let url = URL(fileURLWithPath: directory)
                .appendingPathComponent(String(format: "%@-%@-%02d-%@.png", device, variant, count, name))
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
        }
        /// An alert's button by its English or Simplified Chinese title.
        func alertButton(_ titles: [String]) -> XCUIElement {
            app.alerts.buttons.matching(NSPredicate(format: "label IN %@", titles)).firstMatch
        }
        /// Enters the adult partition with the next passed answer, in either
        /// language.
        func enter() {
            revealSwitchPlace()
            waitFor(partitionSwitch).tap()
            waitFor(partitionChoice(adult: true)).tap()
            revealSwitchPlace()
            waitFor(lockButton)
        }
        /// A category's settings from its list's own menu, in either language.
        func openSheet(_ name: String) {
            openCategoryList(name)
            openListSettings(source: false)
            waitFor(app.textFields[AccessibilityID.nameField])
        }
        /// Scrolls the screen to its end, where the last section's footer is.
        func scrollToEnd() {
            for _ in 0..<6 {
                app.swipeUp()
            }
        }

        // Set-up at the default text size, in English: a normal category
        // with two sources, an adult one with one of the same addresses.
        launch(authentication: ["passed", "passed"])
        rotate(.portrait)
        requireFullWidth()
        createCategory("World", icon: "globe")
        addSource(Fixture.articles, to: "World")
        addSource(Fixture.feed, to: "World")
        turnOnAdult()
        enterAdult()
        createCategory("Velvet", icon: "heart")
        addSource(Fixture.articles, to: "Velvet")
        app.terminate()

        // Settings opened from the normal partition (passed), entering
        // (passed), and the move's unlock (passed); the move's deletion
        // fails once.
        let application = XCUIApplication()
        application.launchEnvironment[UITestLaunchKey.failNextMoveDeletion] = "1"
        launch(application, arguments: language + size, authentication: ["passed", "passed", "passed"])
        rotate(.portrait)
        requireFullWidth()

        // S10 from the normal partition.
        openSettings()
        scrollTo(adultRow).tap()
        // Below the fold at the largest text size.
        scrollTo(turnOffButton)
        app.swipeDown()
        capture("s10-from-normal")
        scrollToEnd()
        capture("s10-from-normal-end")
        scrollTo(clearBrowsingButton).tap()
        waitFor(app.alerts.firstMatch)
        capture("question-clear")
        alertButton(["Cancel", "取消"]).tap()
        waitForAbsence(app.alerts.firstMatch)

        // S10 inside the adult partition.
        enter()
        tapAdultRow()
        scrollTo(turnOffButton)
        for _ in 0..<6 {
            app.swipeDown()
        }
        capture("s10-inside")
        scrollToEnd()
        capture("s10-inside-end")
        scrollTo(clearBrowsingButton).tap()
        waitFor(button(AccessibilityID.confirmClearBrowsingDataButton)).tap()
        scrollTo(element(AccessibilityID.browsingDataCleared))
        capture("s10-cleared")
        // The S9 form inside S10.
        for _ in 0..<6 {
            app.swipeDown()
        }
        waitFor(adultPrimaryRow).tap()
        waitFor(button(AccessibilityID.saveButton))
        capture("s9-in-s10")
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(button(AccessibilityID.saveButton))

        // Moving the adult "Velvet": its one source is in the normal
        // partition already.
        openSheet("Velvet")
        tapMove()
        waitFor(app.alerts.firstMatch)
        capture("message-nothing-to-move")
        app.alerts.buttons.firstMatch.tap()
        waitForAbsence(app.alerts.firstMatch)
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(app.textFields[AccessibilityID.nameField])

        // Moving the normal "World": the confirmation, then the deletion
        // that fails once.
        tapLock()
        revealSwitchPlace()
        waitForAbsence(lockButton)
        openSheet("World")
        capture("category-settings-move-button")
        tapMove()
        waitFor(button(AccessibilityID.confirmMoveButton))
        capture("move-confirmation")
        button(AccessibilityID.confirmMoveButton).tap()
        waitFor(app.alerts.firstMatch)
        capture("message-copied-not-removed")
        app.alerts.buttons.firstMatch.tap()
    }
}
