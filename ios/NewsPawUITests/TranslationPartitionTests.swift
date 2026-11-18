import XCTest

/// RD14 criterion 13 in the app, and RD19 criterion 4's first half: the
/// adult workspace translates only through the adult library's own models
/// (RD19); with none set up it shows its originals and sends nothing
/// through the normal library's models, which are set up and translate the
/// normal partition's rows.
final class TranslationPartitionTests: IsolationTestCase {
    static let feed = "https://translation.example.invalid/rss.xml"
    static let source = "Translation Feed"
    static let first = "Foreign story 01"

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
        // nothing asks for a translation. With no adult model the row shows
        // its original title and what a workspace without a model shows
        // (RD21's no-model mark, batch 2): its question opens the adult
        // slots in Settings › Adult Partition, never the normal ones.
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(row.label.contains("译["), row.label)
        XCTAssertFalse(element(AccessibilityID.translationActivity(Self.first)).exists)
        let mark = waitFor(button(AccessibilityID.translationWarning(Self.first)))
        XCTAssertEqual(mark.label, "Not translated")
        waitForLabel(row, containing: "Not translated, Set up a model to translate")
        mark.tap()
        let question = waitFor(app.alerts.firstMatch)
        XCTAssertTrue(question.staticTexts["Set up a model to translate"].exists, question.debugDescription)
        question.buttons.matching(NSPredicate(format: "label == %@", "Open Settings")).firstMatch.tap()
        waitForAbsence(question)
        waitFor(element(AccessibilityID.adultPrimaryModelRow))
        XCTAssertFalse(element(AccessibilityID.primaryModelRow).exists, "the normal slots were opened from the adult partition")
        XCTAssertEqual(translationRequests, before, "a request was sent from the adult partition: \(report)")
        openCategoryList("Velvet")
        waitFor(articleRow(Self.first))
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

    /// The usage rows of body requests in the adult library (batch 3).
    private var adultBodyRequests: Int {
        guard let match = report.firstMatch(of: /adultBodyRequests=(-?\d+)/) else { return -2 }
        return Int(match.1) ?? -2
    }

    /// RD15 criterion 13 under RD19's rule (batch 3): the adult workspace
    /// translates bodies only through the adult library's own models. With
    /// the normal model set up and no adult slot, an adult foreign body
    /// sends nothing and shows the banner of a workspace without a model,
    /// whose Open Settings opens the adult slots (S10), not the normal
    /// ones; reader mode, whose job names no article, sends nothing either.
    /// With an adult slot set up, the adult body is translated and its
    /// usage rows are the adult library's; the normal library's count does
    /// not move.
    func testTheAdultPartitionTranslatesBodiesOnlyWithItsOwnModels() {
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
        XCTAssertTrue(translatedBlock.waitForExistence(timeout: 60), "the normal partition's body was not translated")
        waitFor(button(AccessibilityID.displayModeMenu))
        let stable = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in self.bodyRequests == 1 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [stable], timeout: 20), .completed, report)
        backToList()

        turnOnAdult()
        enterAdult()
        createCategory("Velvet")
        addSource("https://bodies.example.invalid/rss.xml", to: "Velvet")
        addSource("https://fulltext.example.invalid/rss.xml", to: "Velvet")
        let before = translationRequests
        XCTAssertEqual(adultBodyRequests, 0, report)

        // No adult slot. Reader mode first, whose job names no article:
        // originals, nothing sent.
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
        XCTAssertEqual(translationRequests, before, "a request was sent from the adult partition: \(report)")
        XCTAssertEqual(bodyRequests, 1, report)
        XCTAssertEqual(adultBodyRequests, 0, report)
        button(AccessibilityID.readerCloseButton).tap()
        waitForAbsence(title)
        leaveBrowser()

        // An article's body: its originals and the banner of a workspace
        // without a model; nothing is sent through any slot.
        openSourceList("Body Feed", in: "Velvet")
        openArticle("Long story")
        waitFor(element(AccessibilityID.readingBlock(0)))
        let banner = waitFor(element(AccessibilityID.bodyBanner))
        XCTAssertTrue(button(AccessibilityID.bodyBannerOpenSettings).exists, banner.label)
        XCTAssertFalse(element(AccessibilityID.readingBlock(0)).label.contains("译["))
        XCTAssertEqual(translationRequests, before, "a request was sent from the adult partition: \(report)")
        XCTAssertEqual(bodyRequests, 1, report)
        XCTAssertEqual(adultBodyRequests, 0, report)
        // Its Open Settings opens the adult slots, not the normal ones.
        button(AccessibilityID.bodyBannerOpenSettings).tap()
        waitFor(adultPrimaryRow)
        XCTAssertFalse(element(AccessibilityID.primaryModelRow).exists, "the normal slots were opened")

        // An adult slot, set up there with the normal slot's own values.
        adultPrimaryRow.tap()
        waitFor(button(AccessibilityID.saveButton))
        fillForm(address: Isolation.translateAddress, model: Isolation.translator, key: Isolation.normalFixtureKey)
        runTest(expecting: "Passed")
        tapSave()
        waitForAbsence(button(AccessibilityID.saveButton))
        // Back to the list, and the article opened again.
        if usesTabs {
            app.tabBars.buttons.element(boundBy: 1).tap()
            waitFor(element(AccessibilityID.readingBlock(0)))
            backToList()
        } else {
            openSourceList("Body Feed", in: "Velvet")
        }
        // The article has been read, so a list opened again under Unread
        // leaves it out: All shows it.
        chooseFilter("All")
        // Its title may be translated now: the row is tapped and the body
        // waited for.
        waitFor(articleRow("Long story")).tap()

        // The adult body is translated through it: adult usage rows only.
        XCTAssertTrue(translatedBlock.waitForExistence(timeout: 60), "the adult body was not translated with the adult slot: \(report)")
        let adultRows = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in self.adultBodyRequests >= 1 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [adultRows], timeout: 20), .completed, report)
        XCTAssertEqual(bodyRequests, 1, "a body request of the adult partition was recorded in the normal library: \(report)")

        // Copy Translation there keeps the text on this device (N09): the
        // pasteboard is written local-only, out of Universal Clipboard.
        XCTAssertTrue(report.contains("copy=none"), report)
        waitFor(button(AccessibilityID.readingMoreMenu)).tap()
        let copy = waitFor(button(AccessibilityID.copyTranslationButton))
        waitForEnabled(copy, true)
        copy.tap()
        waitForAbsence(button(AccessibilityID.copyTranslationButton))
        let localOnly = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in self.report.contains("copy=localOnly") }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [localOnly], timeout: 20), .completed, "Copy Translation in the adult partition was not local-only: \(report)")
    }

    private var translatedBlock: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND label BEGINSWITH %@", AccessibilityID.readingBlock(0), "译[zh-Hans]："
        )).firstMatch
    }
}
