import XCTest

/// RD08: the import preview with folders, feeds outside any folder and
/// skipped entries, the category picker, the skipped list, the summary, a
/// refused file, and Settings › Data with the OPML rows. Written when run
/// with `TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR` set (and, optionally,
/// `TEST_RUNNER_NEWSPAW_SCREENSHOT_VARIANT` = `zh`; dark appearance is set
/// on the simulator with `xcrun simctl ui`). Skipped otherwise: it asserts
/// nothing beyond what `OPMLTests` asserts.
final class OPMLScreenshotTests: AdultTestCase {
    func testCaptureOPMLScreens() throws {
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
                .appendingPathComponent(String(format: "%@-%@-opml-%02d-%@.png", device, variant, count, name))
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
        }
        func launchReading(_ fixture: String) {
            let application = XCUIApplication()
            application.launchEnvironment[UITestLaunchKey.opmlFixture] = fixture
            launch(application, arguments: arguments)
            rotate(.portrait)
            requireFullWidth()
        }
        func openData() {
            openSettings()
            waitFor(element(AccessibilityID.dataRow)).tap()
            waitFor(button(AccessibilityID.importOPMLButton))
        }

        // A refused file, from Settings › Data.
        launchReading("refused")
        openData()
        capture("data-empty")
        button(AccessibilityID.importOPMLButton).tap()
        waitFor(app.alerts.firstMatch)
        capture("refused")
        app.alerts.firstMatch.buttons.element(boundBy: 0).tap()
        app.terminate()

        // The preview with every kind of row: a category the file's "Tech"
        // matches, and the articles feed already in it.
        launchReading("folders")
        let tech = "Tech"
        createCategory(tech)
        addSource("https://articles.example.invalid/rss.xml", to: tech)
        openAddSource()
        capture("add-source-row")
        scrollTo(button(AccessibilityID.addSourceImportOPMLButton)).tap()
        waitFor(element(AccessibilityID.opmlFeedsToAdd))
        capture("preview")
        button(AccessibilityID.opmlCategoryRow).tap()
        waitFor(button(AccessibilityID.opmlNewCategoryButton))
        capture("category-picker")
        button(AccessibilityID.opmlCategoryChoice(tech)).tap()
        waitFor(element(AccessibilityID.opmlFeedsToAdd))
        capture("preview-chosen")
        scrollTo(button(AccessibilityID.opmlSkippedRow)).tap()
        waitFor(element(AccessibilityID.opmlSkipped(0)))
        capture("skipped")
        goBack()
        let importButton = waitFor(button(AccessibilityID.opmlImportButton))
        importButton.tap()
        waitFor(element(AccessibilityID.opmlFeedsAdded))
        capture("summary")
        button(AccessibilityID.opmlDoneButton).tap()
        waitForAbsence(element(AccessibilityID.opmlFeedsAdded))
        openData()
        capture("data")
    }
}
