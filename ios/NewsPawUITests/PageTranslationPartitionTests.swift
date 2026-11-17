import XCTest

/// RD16 criterion 8 in the app: in the adult workspace, which has no models
/// of its own until RD19, Translate collects nothing and sends nothing
/// through any slot; the line says "Set up a model to translate" with no
/// link, and the button stays off. The normal library's models are set up.
final class PageTranslationPartitionTests: AdultTestCase {
    static let list = "https://pages.example.invalid/ja-list"
    static let title = "日本語のニュース一覧"

    private var translationRequests: Int {
        guard let match = report.firstMatch(of: /translationRequests=(-?\d+)/) else { return -2 }
        return Int(match.1) ?? -2
    }

    func testTheAdultBrowserDoesNotTranslate() {
        let application = XCUIApplication()
        application.launchEnvironment[UITestLaunchKey.translationModels] = "primary"
        launch(application, authentication: ["passed", "passed", "passed"])
        rotate(.portrait)
        requireFullWidth()
        turnOnAdult()
        enterAdult()
        createCategory("Velvet")
        openAddSource()
        detect(Self.list)
        waitFor(button(AccessibilityID.saveAsWebPageButton)).tap()
        chooseCategoryAndSave("Velvet")
        expand("Velvet")
        scrollTo(sourceRow("Japanese List")).tap()
        waitForPage(Self.title)
        let before = translationRequests
        XCTAssertGreaterThanOrEqual(before, 0, report)

        let translate = waitFor(button(AccessibilityID.browserTranslateButton))
        translate.tap()
        let line = waitFor(element(AccessibilityID.pageTranslationLine))
        XCTAssertEqual(line.label, "Set up a model to translate")
        XCTAssertFalse(button(AccessibilityID.pageTranslationOpenSettings).exists, "no link in the adult partition")
        XCTAssertEqual(translate.value as? String, "Off")
        // Criterion 18's line without a link, when screenshots are asked for.
        let environment = ProcessInfo.processInfo.environment
        if let directory = environment["NEWSPAW_SCREENSHOT_DIR"] {
            let device = (environment["SIMULATOR_DEVICE_NAME"] ?? "device").replacingOccurrences(of: " ", with: "-")
            let variant = environment["NEWSPAW_SCREENSHOT_VARIANT"] ?? "default"
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(device)-\(variant)-pages-adult-no-model.png")
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
        }
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(translationRequests, before, "a request was sent from the adult partition: \(report)")
        let original = app.webViews.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "ニュース 1：新しい製品が発表されました")).firstMatch
        XCTAssertTrue(original.exists)
        // "Always Translate This Source" is shown and stored; it does not
        // translate here.
        chooseInMore("Always Translate This Source")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(translate.value as? String, "Off")
        XCTAssertEqual(translationRequests, before, report)
    }
}
