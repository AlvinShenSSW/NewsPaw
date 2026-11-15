import XCTest

/// Writes the screenshots of RD18 criterion 18 when run with
/// `TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR` set (and, optionally,
/// `TEST_RUNNER_NEWSPAW_SCREENSHOT_VARIANT` = `zh` or `largest-text`; dark
/// appearance is set on the simulator with `xcrun simctl ui`). Skipped
/// otherwise: it asserts nothing beyond what the other tests assert.
final class AdultScreenshotTests: AdultTestCase {
    func testCaptureAdultPartitionScreens() throws {
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
        func enter() {
            revealSwitchPlace()
            waitFor(partitionSwitch).tap()
            waitFor(partitionChoice(adult: true)).tap()
            revealSwitchPlace()
            waitFor(lockButton)
        }

        // Set-up at the default text size, where the shared helpers find
        // every control without scrolling: both partitions with content.
        launch(arguments: language, authentication: ["passed", "passed"])
        rotate(.portrait)
        requireFullWidth()
        createCategory("World", icon: "globe")
        addSource(Fixture.feed, to: "World")
        tapAdultRow()
        flipOn()
        waitFor(turnOffButton)
        enter()
        createCategory("Velvet", icon: "heart")
        addSource(Fixture.articles, to: "Velvet")
        app.terminate()

        // Settings open (passed); turning on refused (cancelled) and then
        // passed; entering (passed).
        launch(arguments: language + size, authentication: ["passed", "cancelled", "passed", "passed"])
        rotate(.portrait)
        requireFullWidth()
        revealSwitchPlace()
        waitFor(partitionSwitch)
        capture("switch-normal")
        partitionSwitch.tap()
        waitFor(partitionChoice(adult: true))
        capture("switch-menu")
        partitionChoice(adult: false).tap()

        openSettings()
        capture("settings")
        scrollTo(adultRow).tap()
        scrollTo(turnOffButton)
        capture("settings-adult-on")
        turnOffButton.tap()
        waitFor(app.alerts.firstMatch)
        capture("question-turn-off")
        alertButton(["Delete Data", "删除数据"]).tap()
        waitFor(alertButton(["Delete", "删除"]))
        capture("question-delete")
        alertButton(["Cancel", "取消"]).tap()
        scrollTo(turnOffButton).tap()
        waitFor(app.alerts.firstMatch)
        alertButton(["Keep Data Hidden", "保留数据并隐藏"]).tap()
        waitFor(adultToggle)
        capture("settings-adult-off")
        flipOn()
        waitFor(app.alerts.firstMatch)
        capture("message-not-turned-on")
        app.alerts.buttons.firstMatch.tap()
        flipOn()
        scrollTo(turnOffButton)

        // The adult partition: the capsule, the lock button, and the accent
        // wherever it shows.
        enter()
        capture("adult-switch")
        showToday()
        capture("adult-today")
        expand("Velvet")
        capture("adult-library")
        waitFor(sourceRow("Articles Feed")).tap()
        waitForAbsence(element(AccessibilityID.slideOverPanel))
        waitFor(articleRow("Image story"))
        capture("adult-list")
        articleRow("Plain story").tap()
        waitFor(element(AccessibilityID.readingTitle))
        capture("adult-article")
        // The browser's bars, on the article's page.
        waitFor(button(AccessibilityID.openOriginalButton)).tap()
        waitFor(moreMenu)
        Thread.sleep(forTimeInterval: 1)
        capture("adult-browser")
        closeBrowser()
        if usesTabs {
            goBack()
        }
        // By the list's own menu, whose items are found in either language.
        openCategoryList("Velvet")
        openListSettings(source: false)
        waitFor(app.textFields[AccessibilityID.nameField])
        capture("adult-category-settings")
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(app.textFields[AccessibilityID.nameField])
        if usesTabs {
            openAddSource()
        } else {
            // Below the fold of the sidebar at the largest text size.
            openSidebarIfNeeded()
            scrollTo(button(AccessibilityID.addSourceButton)).tap()
            waitFor(app.textFields[AccessibilityID.addressField])
        }
        capture("adult-add-source")
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(app.textFields[AccessibilityID.addressField])
        openSettings()
        capture("adult-settings")
        scrollTo(adultRow).tap()
        scrollTo(turnOffButton)
        capture("adult-settings-adult")
        turnOffButton.tap()
        waitFor(app.alerts.firstMatch)
        capture("adult-question-turn-off")
        alertButton(["Cancel", "取消"]).tap()
    }

    /// The check by hand of criterion 9, as steps: with the app's
    /// animations on, "After 1 Minute", and an adult sheet open, the app is
    /// left for longer than a minute and entered again; the timed lock then
    /// swaps the partition under the cover. Run with
    /// `TEST_RUNNER_NEWSPAW_TRANSITION_CHECK=1` while the simulator's
    /// screen is recorded (`xcrun simctl io <id> recordVideo`), and look at
    /// the frames after the return: none may show the sheet or the adult
    /// list. Skipped otherwise; it asserts only where the app ends up.
    func testTimedLockWithAnimationsOn() throws {
        guard ProcessInfo.processInfo.environment["NEWSPAW_TRANSITION_CHECK"] == "1" else {
            throw XCTSkip("set TEST_RUNNER_NEWSPAW_TRANSITION_CHECK=1 and record the screen")
        }
        keepsAnimations = true
        launch(authentication: ["passed", "passed"])
        rotate(.portrait)
        requireFullWidth()
        createCategory("World")
        turnOnAdult()
        chooseTiming("After 1 Minute")
        enterAdult()
        createCategory("Velvet")
        openCategoryList("Velvet")
        openListSettings(source: false)
        let field = waitFor(app.textFields[AccessibilityID.nameField])
        XCTAssertEqual(field.value as? String, "Velvet")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 64)
        // For finding the moment in the recording.
        print("RD18 returning at \(Date().timeIntervalSince1970)")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: timeout))
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(field.exists, "the adult sheet is still shown")
        XCTAssertEqual(partitionLabel(), Wording.normal)
        waitForReport(Self.closed, Self.dropped)
    }
}
