import XCTest

/// RD06 criterion 17: Today with each status-line state and the failure
/// count, and Settings → Refresh. Written when run with
/// `TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR` set (and, optionally,
/// `TEST_RUNNER_NEWSPAW_SCREENSHOT_VARIANT` = `zh` or `largest-text`; dark
/// appearance is set on the simulator with `xcrun simctl ui`). Skipped
/// otherwise: it asserts nothing beyond what `RefreshTests` asserts.
final class RefreshScreenshotTests: NewsPawUITestCase {
    func testCaptureRefreshScreens() throws {
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
                .appendingPathComponent(String(format: "%@-%@-refresh-%02d-%@.png", device, variant, count, name))
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
        }
        func showToday() {
            if app.tabBars.firstMatch.exists {
                app.tabBars.buttons.element(boundBy: 0).tap()
            } else {
                openSidebarIfNeeded()
                waitFor(element(AccessibilityID.todayRow)).tap()
                waitForAbsence(element(AccessibilityID.slideOverPanel))
            }
        }
        func pull() {
            let start = waitFor(element(AccessibilityID.todayStatus)).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 350)), withVelocity: .slow, thenHoldForDuration: 0.5)
        }
        func waitForLabel(_ predicate: String) {
            let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element(AccessibilityID.todayStatus))
            _ = XCTWaiter.wait(for: [shown], timeout: timeout)
        }

        // Manual only through the argument domain, so that the launch does
        // not record a refresh and Today can say "Not updated yet".
        launch(arguments: arguments + ["-refresh_minutes", "0"])
        rotate(.portrait)
        requireFullWidth()
        let category = variant == "zh" ? "世界" : "World"
        createCategory(category, icon: "globe")
        addSource("https://sequence.example.invalid/rss.xml", to: category)
        addSource("https://slowfeeds.example.invalid/slow.xml", to: category)
        showToday()
        waitFor(element(AccessibilityID.todayStatus))
        capture("today-not-updated")

        // "Updating…" while the slow source, refreshed from its menu, is
        // collected for three seconds. (During a pull the harness waits for
        // the system's refresh indicator to stop before it can look.)
        expand(category)
        scrollTo(sourceRow("Slow Feed")).press(forDuration: 1.2)
        waitFor(app.buttons[variant == "zh" ? "刷新" : "Refresh"].firstMatch).tap()
        showToday()
        waitForLabel("label BEGINSWITH 'Updating' OR label BEGINSWITH '正在更新'")
        capture("today-updating")
        waitForLabel("NOT (label BEGINSWITH 'Updating' OR label BEGINSWITH '正在更新')")

        // The sequenced source fails on its second request.
        pull()
        waitFor(button(AccessibilityID.failedSourcesButton))
        waitForLabel("NOT (label BEGINSWITH 'Updating' OR label BEGINSWITH '正在更新')")
        capture("today-updated-one-failed")

        // The third request succeeds.
        pull()
        waitForAbsence(button(AccessibilityID.failedSourcesButton))
        waitForLabel("NOT (label BEGINSWITH 'Updating' OR label BEGINSWITH '正在更新')")
        capture("today-updated")

        // Settings → Refresh with the stored values, without the argument.
        relaunch()
        rotate(.portrait)
        if app.tabBars.firstMatch.exists {
            app.tabBars.buttons.element(boundBy: 3).tap()
        } else {
            openSidebarIfNeeded()
            waitFor(element(AccessibilityID.settingsRow)).tap()
            waitForAbsence(element(AccessibilityID.slideOverPanel))
        }
        capture("settings")
        waitFor(element(AccessibilityID.refreshRow)).tap()
        waitFor(button(AccessibilityID.refreshIntervalPicker))
        capture("settings-refresh")
        if variant == "largest-text" {
            app.swipeUp()
            capture("settings-refresh-scrolled")
        }
    }
}
