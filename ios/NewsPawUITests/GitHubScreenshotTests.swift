import XCTest

/// RD07 criterion 12: the confirm step for a repository, for a repository
/// with no tag, and with Releases already added. Written when run with
/// `TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR` set (and, optionally,
/// `TEST_RUNNER_NEWSPAW_SCREENSHOT_VARIANT` = `zh`; dark appearance is set
/// on the simulator with `xcrun simctl ui`). Skipped otherwise: it asserts
/// nothing beyond what `GitHubSourceTests` asserts.
final class GitHubScreenshotTests: NewsPawUITestCase {
    func testCaptureGitHubConfirmSteps() throws {
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
                .appendingPathComponent(String(format: "%@-%@-github-%02d-%@.png", device, variant, count, name))
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
        }
        func releasesRow(_ repository: String) -> XCUIElement {
            button(AccessibilityID.candidateChoice("https://github.com/newspaw-fixture/\(repository)/releases.atom"))
        }

        launch(arguments: arguments)
        rotate(.portrait)
        requireFullWidth()
        let category = variant == "zh" ? "开源" : "Open Source"
        createCategory(category, icon: "laptopcomputer")

        openAddSource()
        detect("https://github.com/NewsPaw-Fixture/Project")
        waitFor(releasesRow("project"))
        capture("confirm-repository")
        goBack()
        detect("https://github.com/NewsPaw-Fixture/Untagged")
        waitFor(releasesRow("untagged"))
        capture("confirm-no-tag")
        goBack()
        detect("https://github.com/NewsPaw-Fixture/Project")
        waitFor(releasesRow("project"))
        // Below the fold in the iPad's sheet.
        scrollTo(button(AccessibilityID.categoryChoiceRow))
        chooseCategoryAndSave(category)

        openAddSource()
        detect("https://github.com/NewsPaw-Fixture/Project")
        waitFor(releasesRow("project"))
        capture("confirm-releases-added")
    }
}
