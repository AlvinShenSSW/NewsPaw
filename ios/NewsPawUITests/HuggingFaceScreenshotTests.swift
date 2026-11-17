import XCTest

/// RD26 criterion 12: the confirm step for an account, for an account with
/// no models, and the address step for a missing account. Written when run
/// with `TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR` set (and, optionally,
/// `TEST_RUNNER_NEWSPAW_SCREENSHOT_VARIANT` = `zh`; dark appearance is set
/// on the simulator with `xcrun simctl ui`). Skipped otherwise: it asserts
/// nothing beyond what `HuggingFaceSourceTests` asserts.
final class HuggingFaceScreenshotTests: NewsPawUITestCase {
    func testCaptureHuggingFaceSteps() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["NEWSPAW_SCREENSHOT_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR to capture screenshots")
        }
        let variant = environment["NEWSPAW_SCREENSHOT_VARIANT"] ?? "default"
        let device = (environment["SIMULATOR_DEVICE_NAME"] ?? "device").replacingOccurrences(of: " ", with: "-")
        let arguments = variant == "zh" ? ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] : []
        var count = 0
        func capture(_ name: String) {
            count += 1
            let url = URL(fileURLWithPath: directory)
                .appendingPathComponent(String(format: "%@-%@-huggingface-%02d-%@.png", device, variant, count, name))
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
        }

        launch(arguments: arguments)
        rotate(.portrait)
        requireFullWidth()
        let category = variant == "zh" ? "模型" : "Models"
        createCategory(category, icon: "cpu")

        openAddSource()
        detect("huggingface.co/NewsPaw-Fixture")
        waitFor(element(AccessibilityID.previewItem))
        capture("confirm-account")
        goBack()
        detect("hf.co/newspaw-empty")
        waitFor(element(AccessibilityID.confirmAddress))
        capture("confirm-no-models")
        goBack()
        detect("huggingface.co/newspaw-missing")
        waitFor(element(AccessibilityID.failureMessage))
        capture("missing-account")
    }
}
