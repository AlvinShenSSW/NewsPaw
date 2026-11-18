import XCTest

/// RD16 criterion 8 under RD19's rule (batch 3): the adult workspace's
/// page translators are made from the adult library's own models. With
/// the normal library's model set up and no adult slot, Translate in the
/// adult browser collects nothing and sends nothing through any slot; the
/// line says "Set up a model to translate" with Open Settings, which opens
/// the adult slots (Settings › Adult Partition), not the normal ones. With
/// an adult slot set up there, the adult page is translated through it:
/// the adult library's page usage rows grow and the normal library's do
/// not.
final class PageTranslationPartitionTests: IsolationTestCase {
    static let list = "https://pages.example.invalid/ja-list"
    static let title = "日本語のニュース一覧"
    static let firstItem = "ニュース 1：新しい製品が発表されました"

    private func count(_ name: String) -> Int {
        guard let match = report.firstMatch(of: try! Regex("(?:^| )\(name)=(-?\\d+)")),
              let value = match.output[1].substring.flatMap({ Int($0) }) else { return -2 }
        return value
    }

    private var pageRequests: Int { count("pageRequests") }
    private var adultPageRequests: Int { count("adultPageRequests") }

    private func webText(_ text: String) -> XCUIElement {
        app.webViews.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", text, text)).firstMatch
    }

    private func openList() {
        expand("Velvet")
        scrollTo(sourceRow("Japanese List")).tap()
        waitForPage(Self.title)
    }

    func testTheAdultBrowserTranslatesOnlyWithItsOwnModels() {
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
        openList()
        let before = translationRequests
        XCTAssertGreaterThanOrEqual(before, 0, report)
        XCTAssertEqual(pageRequests, 0, report)
        XCTAssertEqual(adultPageRequests, 0, report)

        // No adult slot: nothing collected or sent; the line links to the
        // adult slots.
        let translate = waitFor(button(AccessibilityID.browserTranslateButton))
        translate.tap()
        let line = waitFor(element(AccessibilityID.pageTranslationLine))
        XCTAssertEqual(line.label, "Set up a model to translate")
        XCTAssertTrue(report.contains("translateOn=0"), report)
        // Criterion 18's line, when screenshots are asked for.
        let environment = ProcessInfo.processInfo.environment
        if let directory = environment["NEWSPAW_SCREENSHOT_DIR"] {
            let device = (environment["SIMULATOR_DEVICE_NAME"] ?? "device").replacingOccurrences(of: " ", with: "-")
            let variant = environment["NEWSPAW_SCREENSHOT_VARIANT"] ?? "default"
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(device)-\(variant)-pages-adult-no-model.png")
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
        }
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(translationRequests, before, "a request was sent from the adult partition: \(report)")
        XCTAssertTrue(webText(Self.firstItem).exists)
        // "Always Translate This Source" is stored; it sends nothing either.
        chooseInMore("Always Translate This Source")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(report.contains("translateOn=0"), report)
        XCTAssertEqual(translationRequests, before, report)
        waitFor(button(AccessibilityID.pageTranslationOpenSettings)).tap()
        waitFor(adultPrimaryRow)
        XCTAssertFalse(element(AccessibilityID.primaryModelRow).exists, "the normal slots were opened")

        // An adult slot, set up in S10 with the normal slot's own values.
        adultPrimaryRow.tap()
        waitFor(button(AccessibilityID.saveButton))
        fillForm(address: Isolation.translateAddress, model: Isolation.translator, key: Isolation.normalFixtureKey)
        runTest(expecting: "Passed")
        tapSave()
        waitForAbsence(button(AccessibilityID.saveButton))
        let afterTest = translationRequests

        // The source translates when opened (the switch above), through
        // the adult slot: the adult library's page usage rows grow, the
        // normal library's do not.
        openList()
        XCTAssertTrue(webText("译[zh-Hans]：" + Self.firstItem).waitForExistence(timeout: 60), "the adult page was not translated: \(report)")
        XCTAssertGreaterThan(translationRequests, afterTest, report)
        let adultRows = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in self.adultPageRequests >= 1 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [adultRows], timeout: 20), .completed, report)
        XCTAssertEqual(pageRequests, 0, "a page request of the adult partition was recorded in the normal library: \(report)")
    }
}
