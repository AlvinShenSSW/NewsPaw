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
}
