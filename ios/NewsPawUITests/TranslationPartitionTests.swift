import XCTest

/// RD14 criterion 13 in the app: the adult workspace has no translation of
/// its own until RD19, shows its originals, and sends nothing through the
/// normal library's models, which are set up and translate the normal
/// partition's rows.
final class TranslationPartitionTests: AdultTestCase {
    static let feed = "https://translation.example.invalid/rss.xml"
    static let source = "Translation Feed"
    static let first = "Foreign story 01"

    /// The translator fixture's requests so far, from the debug report.
    private var translationRequests: Int {
        let report = self.report
        guard let range = report.range(of: "translationRequests=") else { return -1 }
        return Int(report[range.upperBound...].prefix { $0.isNumber }) ?? -1
    }

    func testTheAdultPartitionShowsOriginalsAndSendsNothing() {
        let application = XCUIApplication()
        application.launchEnvironment[UITestLaunchKey.translationModels] = "primary"
        launch(application, authentication: ["passed", "passed", "passed"])
        rotate(.portrait)
        requireFullWidth()

        // The normal partition translates with the normal library's models.
        createCategory("World")
        addSource(Self.feed, to: "World")
        openCategoryList("World")
        waitForLabel(waitFor(articleRow(Self.first)), containing: "译[zh-Hans]：\(Self.first)")
        // A refresh ends: the pass translates the category's newest 50.
        pullList()
        // Let the pass end: its requests are counted before the adult
        // partition is entered.
        var settled = -2
        let stable = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            let now = self.translationRequests
            defer { settled = now }
            return now == settled && now > 0
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [stable], timeout: 20), .completed, report)
        let before = translationRequests
        XCTAssertGreaterThanOrEqual(before, 1, "the normal partition's rows were translated")

        turnOnAdult()
        enterAdult()
        createCategory("Velvet")
        addSource(Self.feed, to: "Velvet")
        openCategoryList("Velvet")
        let row = waitFor(articleRow(Self.first))
        pullList()
        // Rows of the adult partition appear, are refreshed, and are scrolled:
        // nothing asks for a translation.
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(row.label.contains("译["), row.label)
        XCTAssertFalse(button(AccessibilityID.translationWarning(Self.first)).exists)
        XCTAssertFalse(element(AccessibilityID.translationActivity(Self.first)).exists)
        app.swipeUp()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(translationRequests, before, "a request was sent from the adult partition: \(report)")
        // The reading screen shows the original too.
        app.swipeDown()
        app.swipeDown()
        openArticle(Self.first)
        XCTAssertFalse(element(AccessibilityID.readingOriginalTitle).exists)
        XCTAssertEqual(translationRequests, before, report)

        // Back in the normal partition, its rows are still translated.
        tapLock()
        waitForPartition(Wording.normal)
        openCategoryList("World")
        waitForLabel(waitFor(articleRow(Self.first)), containing: "译[zh-Hans]：\(Self.first)")
    }

    /// The usage rows of body requests in the normal library (RD15).
    private var bodyRequests: Int {
        guard let match = report.firstMatch(of: /bodyRequests=(-?\d+)/) else { return -2 }
        return Int(match.1) ?? -2
    }

    /// RD15 criterion 13: with the normal model set up, the adult
    /// workspace shows no translation control, banner or progress line for
    /// a foreign article or in reader mode, and no body request is made.
    func testTheAdultPartitionTranslatesNoBody() {
        let application = XCUIApplication()
        application.launchEnvironment[UITestLaunchKey.translationModels] = "primary"
        launch(application, authentication: ["passed", "passed", "passed"])
        rotate(.portrait)
        requireFullWidth()

        // The normal partition translates a body.
        createCategory("World")
        addSource("https://bodies.example.invalid/rss.xml", to: "World")
        openCategoryList("World")
        // Its title may be translated already: the row is tapped and the
        // body waited for.
        waitFor(articleRow("Markup story")).tap()
        let translated = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND label BEGINSWITH %@", AccessibilityID.readingBlock(0), "译[zh-Hans]："
        )).firstMatch
        XCTAssertTrue(translated.waitForExistence(timeout: 60), "the normal partition's body was not translated")
        waitFor(button(AccessibilityID.displayModeMenu))
        let stable = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in self.bodyRequests == 1 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [stable], timeout: 20), .completed, report)
        backToList()

        turnOnAdult()
        enterAdult()
        createCategory("Velvet")
        addSource("https://bodies.example.invalid/rss.xml", to: "Velvet")
        addSource("https://fulltext.example.invalid/rss.xml", to: "Velvet")
        openSourceList("Body Feed", in: "Velvet")
        openArticle("Long story")
        waitFor(element(AccessibilityID.readingBlock(0)))
        Thread.sleep(forTimeInterval: 3)
        for identifier in [
            AccessibilityID.translateButton, AccessibilityID.displayModeMenu, AccessibilityID.bodyBanner, AccessibilityID.bodyProgress,
            AccessibilityID.copyTranslationButton,
        ] {
            XCTAssertFalse(element(identifier).exists, "\(identifier) in the adult partition")
        }
        XCTAssertFalse(element(AccessibilityID.readingBlock(0)).label.contains("译["))
        XCTAssertEqual(bodyRequests, 1, report)

        // Reader mode in the adult partition: originals, nothing sent.
        backToList()
        openSourceList("Full Text Feed", in: "Velvet")
        chooseFilter("All")
        openArticle("Fetched story")
        waitFor(element(AccessibilityID.readingFullTextNote))
        waitFor(button(AccessibilityID.readingOriginalBarButton)).tap()
        let reader = button(AccessibilityID.browserReaderButton)
        waitForEnabled(reader, true)
        reader.tap()
        let title = waitFor(element(AccessibilityID.readerTitle))
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(title.label.contains("译["), title.label)
        XCTAssertFalse(element(AccessibilityID.displayModeMenu).exists)
        XCTAssertFalse(element(AccessibilityID.translateButton).exists)
        XCTAssertFalse(element(AccessibilityID.bodyBanner).exists)
        XCTAssertEqual(bodyRequests, 1, report)
    }
}
