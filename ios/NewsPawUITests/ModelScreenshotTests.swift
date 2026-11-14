import XCTest

/// RD13 criterion 16: Settings, Models & Translation, the primary and the
/// backup model's forms (scrolled through) and the loaded model list.
/// Written when run with `TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR` set (and,
/// optionally, `TEST_RUNNER_NEWSPAW_SCREENSHOT_VARIANT` = `zh` or
/// `largest-text`; dark appearance is set on the simulator with `xcrun
/// simctl ui`). Skipped otherwise: it asserts nothing beyond what
/// `ModelSettingsTests` asserts.
final class ModelScreenshotTests: ModelSettingsTestCase {
    func testCaptureModelScreens() throws {
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
                .appendingPathComponent(String(format: "%@-%@-models-%02d-%@.png", device, variant, count, name))
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
        }
        /// Captures the open form from its top to its Remove Model button.
        func captureForm(_ name: String) {
            var page = 1
            capture("\(name)-\(page)")
            let remove = button(AccessibilityID.removeModelButton)
            while !(remove.exists && remove.isHittable), page < 10 {
                app.swipeUp()
                page += 1
                capture("\(name)-\(page)")
            }
        }

        // Set up in English at the default size, where the helpers' labels
        // and typing work: a primary that passed its Test, and a backup
        // whose Test was limited, each saved with its result.
        launch()
        rotate(.portrait)
        requireFullWidth()
        openModelSettings()
        openForm()
        fill(address: Fixture.passed, model: "fixture-model-a", key: "sk-screenshot-primary-1a2b")
        runTest(expecting: "Passed")
        saveForm()
        openForm(backup: true)
        fill(address: Fixture.limited, model: "fixture-model-c", key: "sk-screenshot-backup-9z8y")
        runTest(expecting: "Quota or rate limit")
        saveForm()

        app.terminate()
        launch(arguments: arguments)
        rotate(.portrait)
        requireFullWidth()
        if app.tabBars.firstMatch.exists {
            app.tabBars.buttons.element(boundBy: 3).tap()
        } else {
            openSidebarIfNeeded()
            scrollTo(element(AccessibilityID.settingsRow)).tap()
            waitForAbsence(element(AccessibilityID.slideOverPanel))
        }
        waitFor(element(AccessibilityID.modelsRow))
        capture("settings")
        element(AccessibilityID.modelsRow).tap()
        waitFor(element(AccessibilityID.primaryModelRow))
        capture("models")

        openForm()
        captureForm("primary")
        // The loaded list.
        let loadList = reveal(button(AccessibilityID.loadListButton))
        waitUntilEnabled(loadList)
        loadList.tap()
        waitFor(button(AccessibilityID.modelListRow(Fixture.models[0])))
        capture("model-list")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        waitForAbsence(button(AccessibilityID.modelListRow(Fixture.models[0])))
        button(AccessibilityID.cancelButton).tap()
        waitFor(element(AccessibilityID.primaryModelRow))

        openForm(backup: true)
        captureForm("backup")
    }
}
