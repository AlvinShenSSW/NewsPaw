import XCTest

/// RD14 criterion 13 in the app, and RD19 criterion 4's first half: the
/// adult workspace translates only through the adult library's own models
/// (RD19); with none set up it shows its originals and sends nothing
/// through the normal library's models, which are set up and translate the
/// normal partition's rows.
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
}
