import XCTest

/// RD15 criterion 19: the progress line, the banner, Side by Side, Article
/// Info and the Settings rows (Models & Translation, Reading). Written when
/// run with `TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR` set (and, optionally,
/// `TEST_RUNNER_NEWSPAW_SCREENSHOT_VARIANT` = `zh` or `largest-text`; dark
/// appearance is set on the simulator with `xcrun simctl ui`). Skipped
/// otherwise: it asserts nothing beyond what the other RD15 tests assert.
final class BodyTranslationScreenshotTests: BodyTranslationTestCase {
    func testCaptureBodyTranslationScreens() throws {
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
        var count = 0
        func capture(_ name: String) {
            count += 1
            let url = URL(fileURLWithPath: directory)
                .appendingPathComponent(String(format: "%@-%@-body-%02d-%@.png", device, variant, count, name))
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
        }

        // Set up in English at the default size, then the captures in the
        // variant (a new launch: the stalling chunk stalls again).
        launchWithBodies(models: "primary,backup")
        launchTranslating(models: "primary,backup", arguments: arguments)
        openCategoryList(Body.category)

        // The progress line while chunk 4 stalls.
        openBody(Body.long)
        let stalled = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            self.progressLine.exists && self.block(at: 5).exists && self.block(at: 5).label.hasPrefix("译[")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [stalled], timeout: 60), .completed)
        capture("progress")
        leaveArticle()

        // The banner after a refusal, with the backup's step.
        openBody(Body.refused)
        waitFor(banner)
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: progressLine)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 60), .completed)
        capture("banner")

        // Side by Side, at the top and scrolled.
        chooseMode("side_by_side")
        waitFor(element(AccessibilityID.readingOriginalBlock(0)))
        capture("side-by-side")
        dragArticle(by: -readingArea.height * 0.4)
        capture("side-by-side-scrolled")
        chooseMode("translation")

        // Article Info.
        waitFor(button(AccessibilityID.readingMoreMenu)).tap()
        capture("more-menu")
        waitFor(button(AccessibilityID.articleInfoButton)).tap()
        waitFor(element(AccessibilityID.articleInfoTranslation))
        capture("article-info")
        waitFor(button(AccessibilityID.articleInfoDoneButton)).tap()
        waitForAbsence(element(AccessibilityID.articleInfoTranslation))

        // The settings rows.
        openSettings(row: AccessibilityID.modelsRow)
        waitFor(app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier IN %@", [AccessibilityID.readingLanguagePicker, AccessibilityID.autoTranslateToggle]
        )).firstMatch)
        _ = scrollTo(app.switches[AccessibilityID.translateBodyOnOpenToggle])
        capture("settings-models")
        openSettings(row: AccessibilityID.readingSettingsRow)
        _ = scrollTo(app.buttons.matching(identifier: AccessibilityID.displayModeOption("side_by_side")).firstMatch)
        capture("settings-reading")
    }
}
