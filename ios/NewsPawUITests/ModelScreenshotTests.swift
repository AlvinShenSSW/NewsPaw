import XCTest

/// RD13 criterion 16: Settings, Models & Translation, the primary and the
/// backup model's forms (scrolled through), the loaded model list, the
/// lines of a form that cannot be saved, the two questions and Models &
/// Translation without a model.
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
        button(AccessibilityID.modelListCancelButton).tap()
        waitForAbsence(button(AccessibilityID.modelListRow(Fixture.models[0])))
        button(AccessibilityID.cancelButton).tap()
        waitFor(element(AccessibilityID.primaryModelRow))

        openForm(backup: true)
        captureForm("backup")

        // The lines of a form that cannot be saved: an address that is
        // refused, "Key needed" once the address names another host, and a
        // key that is refused.
        replaceText(of: AccessibilityID.modelAddressField, with: "http://example.invalid/v1")
        reveal(element(AccessibilityID.modelAddressProblem))
        capture("address-problem")
        reveal(element(AccessibilityID.keyNeeded))
        capture("key-needed")
        typeKey("clé")
        reveal(element(AccessibilityID.keyProblem))
        capture("key-problem")
        // The questions: discarding the changes, removing a model. Each is
        // a popover with one button.
        let confirm = app.popovers.buttons.firstMatch
        button(AccessibilityID.cancelButton).tap()
        waitFor(confirm)
        capture("discard-question")
        confirm.tap()
        waitFor(element(AccessibilityID.primaryModelRow))
        for backup in [true, false] {
            openForm(backup: backup)
            reveal(button(AccessibilityID.removeModelButton)).tap()
            waitFor(confirm)
            if backup {
                capture("remove-question")
            }
            confirm.tap()
            waitForAbsence(button(AccessibilityID.saveButton))
            waitFor(element(AccessibilityID.primaryModelRow))
        }
        // No model: "Not set up", and the backup waiting for a primary.
        waitFor(element(AccessibilityID.backupNeedsPrimary))
        capture("models-empty")
    }
}
