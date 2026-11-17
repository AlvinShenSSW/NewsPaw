import XCTest

/// RD17 criterion 11 and assumption A2: Settings › Usage with the seeded
/// rows (Today and 30 Days) and the limit section, page by page down to the
/// limit's footer, and the empty period. Written when run with
/// `TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR` set (and, optionally,
/// `TEST_RUNNER_NEWSPAW_SCREENSHOT_VARIANT` = `zh`, `largest-text` or
/// `zh-largest-text`; dark appearance is set on the simulator with `xcrun
/// simctl ui`). Skipped otherwise: it asserts nothing beyond what
/// `UsageTests` asserts.
final class UsageScreenshotTests: UsageTestCase {
    func testCaptureUsageScreens() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["NEWSPAW_SCREENSHOT_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR to capture screenshots")
        }
        let variant = environment["NEWSPAW_SCREENSHOT_VARIANT"] ?? "default"
        let device = (environment["SIMULATOR_DEVICE_NAME"] ?? "device").replacingOccurrences(of: " ", with: "-")
        let chinese = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        let largest = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        let arguments: [String] = switch variant {
        case "zh": chinese
        case "largest-text": largest
        case "zh-largest-text": chinese + largest
        default: []
        }
        var count = 0
        func capture(_ name: String) {
            count += 1
            let url = URL(fileURLWithPath: directory)
                .appendingPathComponent(String(format: "%@-%@-usage-%02d-%@.png", device, variant, count, name))
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
        }
        /// Captures the screen, then page by page until the limit's last
        /// row is on screen, and then once more scrolled to the end, so
        /// that the limit's footer is in the last picture.
        func capturePages(_ name: String) {
            capture("\(name)-page1")
            let last = limitOption("2,000")
            var page = 1
            var lastSeen = last.exists && last.isHittable
            while page < 8 {
                if lastSeen {
                    break
                }
                app.swipeUp()
                page += 1
                capture("\(name)-page\(page)")
                lastSeen = last.exists && last.isHittable
            }
            app.swipeUp()
            capture("\(name)-end")
        }

        // The empty period first: this test's library has no usage yet.
        launchForUsage(seed: false, arguments: arguments)
        openUsage()
        waitFor(element(AccessibilityID.usageEmpty))
        capturePages("empty")

        // The same library launched with the seeding: the rows.
        launchForUsage(arguments: arguments)
        openUsage()
        // The today line is below the fold at the largest text size: the
        // pages below reach it.
        waitFor(total(Seed.normal, "titles"))
        capturePages("today")
        // 30 Days, by position: its label is translated.
        app.swipeDown()
        app.swipeDown()
        app.swipeDown()
        let thirty = waitFor(periodPicker).buttons.element(boundBy: 2)
        thirty.tap()
        // The rows the period adds can be below the fold at the largest
        // text size: the segment is waited for, and the read's moment.
        let chosen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: thirty)
        XCTAssertEqual(XCTWaiter.wait(for: [chosen], timeout: timeout), .completed)
        Thread.sleep(forTimeInterval: 1)
        capturePages("30-days")
    }
}
