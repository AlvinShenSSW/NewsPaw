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

    /// The browser's bars in the adult partition (assumption A6), written
    /// under the same conditions as the screens above.
    func testCaptureAdultBrowser() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["NEWSPAW_SCREENSHOT_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR to capture screenshots")
        }
        let variant = environment["NEWSPAW_SCREENSHOT_VARIANT"] ?? "default"
        let device = (environment["SIMULATOR_DEVICE_NAME"] ?? "device").replacingOccurrences(of: " ", with: "-")
        launch(authentication: ["passed", "passed"])
        rotate(.portrait)
        requireFullWidth()
        turnOnAdult()
        enterAdult()
        createCategory("Velvet")
        addWebPageSource(to: "Velvet")
        openWebPageSource(in: "Velvet")
        Thread.sleep(forTimeInterval: 1)
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(device)-\(variant)-adult-browser.png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }

    /// The check by hand of criterion 9, as steps: with the app's
    /// animations on and something of the adult partition open, the app is
    /// left and entered again after the lock rule's time; the lock then
    /// swaps the partition under the cover. Run with
    /// `TEST_RUNNER_NEWSPAW_TRANSITION_CHECK` set while the simulator's
    /// screen is recorded (`xcrun simctl io <id> recordVideo`), and look at
    /// the frames after the return: none may show anything of the adult
    /// partition. Its values: `1` — "After 1 Minute" with the category's
    /// settings sheet open, away for 64 seconds; `immediately` — the
    /// default timing with the sheet open, away for 4 seconds (the lock
    /// happens in the background); `menu` — "After 1 Minute" with a
    /// context menu open on the adult category; `share` — "After 1
    /// Minute" with the system's share sheet open over the adult
    /// browser; `plain` and `plain-immediately` — the two timings with
    /// the adult category's list on screen and nothing open. Skipped
    /// otherwise; it asserts only where the app ends up.
    func testTimedLockWithAnimationsOn() throws {
        let variant = ProcessInfo.processInfo.environment["NEWSPAW_TRANSITION_CHECK"] ?? ""
        guard ["1", "immediately", "menu", "share", "plain", "plain-immediately"].contains(variant) else {
            throw XCTSkip("set TEST_RUNNER_NEWSPAW_TRANSITION_CHECK and record the screen")
        }
        let locksInTheBackground = variant.hasSuffix("immediately")
        keepsAnimations = true
        launch(authentication: ["passed", "passed"])
        rotate(.portrait)
        requireFullWidth()
        createCategory("World")
        turnOnAdult()
        if !locksInTheBackground {
            chooseTiming("After 1 Minute")
        }
        enterAdult()
        createCategory("Velvet")
        let field = app.textFields[AccessibilityID.nameField]
        switch variant {
        case "menu":
            showCategoryList()
            waitFor(element(AccessibilityID.categoryRow("Velvet"))).press(forDuration: 1.2)
            waitFor(app.buttons["Category Settings"])
        case "share":
            addWebPageSource(to: "Velvet")
            openWebPageSource(in: "Velvet")
            waitFor(moreMenu).tap()
            waitFor(app.buttons["Share"]).tap()
            // The system's sheet is another process's; it is given time.
            Thread.sleep(forTimeInterval: 3)
        case "plain", "plain-immediately":
            openCategoryList("Velvet")
        default:
            openCategoryList("Velvet")
            openListSettings(source: false)
            XCTAssertEqual(waitFor(field).value as? String, "Velvet")
        }
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: locksInTheBackground ? 4 : 64)
        // For finding the moment in the recording.
        print("RD18 returning at \(Date().timeIntervalSince1970)")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: timeout))
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(app.buttons["Category Settings"].exists, "the adult menu is still shown")
        XCTAssertFalse(field.exists, "the adult sheet is still shown")
        XCTAssertEqual(partitionLabel(), Wording.normal)
        waitForReport(Self.closed, Self.dropped)
    }
}
