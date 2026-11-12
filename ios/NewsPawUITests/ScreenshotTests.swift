import XCTest

/// Writes the screenshots of criterion 12 when run with
/// `TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR` set (and, optionally,
/// `TEST_RUNNER_NEWSPAW_SCREENSHOT_VARIANT` = `zh` or `largest-text`; dark
/// appearance is set on the simulator with `xcrun simctl ui`). Skipped
/// otherwise: it asserts nothing beyond what the other tests assert.
final class ScreenshotTests: NewsPawUITestCase {
    func testCaptureScreens() throws {
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
                .appendingPathComponent(String(format: "%@-%@-%02d-%@.png", device, variant, count, name))
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
        }

        launch(arguments: arguments)
        rotate(.portrait)
        requireFullWidth()
        createCategory("World", icon: "globe")
        createCategory("Tech", icon: "cpu")
        createCategory("Japan", icon: "leaf")

        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            rotate(orientation)
            let side = orientation.isLandscape ? "landscape" : "portrait"
            if app.tabBars.firstMatch.exists {
                app.tabBars.buttons.element(boundBy: 1).tap()
                capture("\(side)-library")
                element(AccessibilityID.categoryRow("Tech")).tap()
                waitFor(element(AccessibilityID.categoryEmpty))
                capture("\(side)-category")
                app.navigationBars.buttons.element(boundBy: 0).tap()
                app.tabBars.buttons.element(boundBy: 0).tap()
                capture("\(side)-today")
                app.tabBars.buttons.element(boundBy: 1).tap()
            } else {
                openSidebarIfNeeded()
                if element(AccessibilityID.slideOverPanel).exists {
                    capture("\(side)-slide-over")
                }
                element(AccessibilityID.categoryRow("Tech")).tap()
                waitFor(element(AccessibilityID.categoryEmpty))
                capture("\(side)-category")
                openSidebarIfNeeded()
                element(AccessibilityID.todayRow).tap()
                waitFor(element(AccessibilityID.todayEmpty))
                capture("\(side)-today")
            }
        }
        rotate(.portrait)
        openNewCategory()
        capture("portrait-new-category")
        button(AccessibilityID.cancelButton).tap()
        if !app.tabBars.firstMatch.exists {
            openSidebarIfNeeded()
        } else {
            app.tabBars.buttons.element(boundBy: 1).tap()
        }
        button(AccessibilityID.editButton).tap()
        capture("portrait-edit-mode")
    }

    /// RD05 criterion 21: the sheet's outcomes, an expanded category with a
    /// working, a paused, a failing and a web-page source, and both
    /// settings variants. Dark appearance is set on the simulator.
    func testCaptureSourceScreens() throws {
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
                .appendingPathComponent(String(format: "%@-%@-sources-%02d-%@.png", device, variant, count, name))
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
        }

        launch(arguments: arguments)
        rotate(.portrait)
        requireFullWidth()
        let category = variant == "zh" ? "世界" : "World"
        createCategory(category, icon: "globe")

        // The sheet's outcomes, each in a fresh sheet: at the largest text
        // size an address overflows the field, and editing it in place is
        // not reliable from a test.
        func freshSheet() {
            button(AccessibilityID.cancelButton).tap()
            waitForAbsence(app.textFields[AccessibilityID.addressField])
            openAddSource()
        }
        openAddSource()
        capture("add-address")
        detect("https://twofeeds.example.invalid/")
        waitFor(element(AccessibilityID.confirmAddress))
        capture("add-confirm-page-with-feeds")
        goBack()
        freshSheet()
        detect("https://nofeed.example.invalid/")
        scrollTo(element(AccessibilityID.noFeedMessage))
        capture("add-no-feed")
        freshSheet()
        detect("forbidden.example.invalid")
        scrollTo(element(AccessibilityID.failureMessage))
        capture("add-failure")
        freshSheet()
        detect("https://feed.example.invalid/rss.xml")
        waitFor(element(AccessibilityID.confirmAddress))
        capture("add-confirm-feed")
        chooseCategoryAndSave(category)
        openAddSource()
        detect("https://feed.example.invalid/rss.xml")
        scrollTo(element(AccessibilityID.duplicateMessage))
        capture("add-duplicate")
        button(AccessibilityID.cancelButton).tap()

        // A working, a paused, a failing and a web-page source.
        addSource("https://sequence.example.invalid/rss.xml", to: category)
        addSource("https://onefeed.example.invalid/feed.xml", to: category)
        openAddSource()
        detect("https://nofeed.example.invalid/")
        scrollTo(button(AccessibilityID.saveAsWebPageButton)).tap()
        chooseCategoryAndSave(category)
        openSourceSettings("One Feed", in: category)
        flip(scrollTo(app.switches[AccessibilityID.pausedToggle]))
        tapSave()
        waitForAbsence(app.switches[AccessibilityID.pausedToggle])
        openSourceSettings("Sequence Feed", in: category)
        scrollTo(button(AccessibilityID.updateNowButton)).tap()
        let failing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", variant == "zh" ? "更新失败" : "Could not update"),
                                                object: element(AccessibilityID.sourceStatus))
        _ = XCTWaiter.wait(for: [failing], timeout: timeout)
        capture("settings-feed")
        button(AccessibilityID.cancelButton).tap()
        expand(category)
        capture("library-expanded")
        openSourceSettings("Plain Page", in: category)
        capture("settings-web-page")
        button(AccessibilityID.cancelButton).tap()
    }
}
