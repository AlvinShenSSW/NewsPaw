import XCTest

/// RD17 (ux S8; spec N11): Settings › Usage shows the seeded rows of the
/// partition shown per period, and its daily automatic limit, which is
/// stored at once and is the one the next automatic request reads.
/// Criteria 2, 4, 5, 6 and 7 (UI); assumptions A3 and A4.
final class UsageTests: UsageTestCase {
    /// Criteria 2, 4, 5 and 7: the normal partition's rows per period, the
    /// limit stored and kept, the adult partition's own rows and limit, and
    /// no adult row anywhere once the partition locks with its Usage on
    /// screen.
    func testSeededPeriodsAndPartitions() {
        launchForUsage(authentication: ["passed", "passed"])
        openUsage()

        // Today: the two titles rows, one without counts; nothing else.
        XCTAssertTrue(periodPicker.buttons["Today"].isSelected)
        waitFor(element(AccessibilityID.usageModel(Seed.normal)))
        let titles = waitFor(total(Seed.normal, "titles"))
        XCTAssertEqual(titles.label, "Titles and Summaries, 2 requests, 100 input tokens · 20 output tokens, Tokens unknown for 1 request")
        for purpose in ["body", "page", "overview", "test"] {
            XCTAssertFalse(total(Seed.normal, purpose).exists, "\(purpose) is shown for Today")
        }
        XCTAssertEqual(waitFor(todayLine).label, "Automatic requests today: 2 of 200")
        XCTAssertFalse(element(AccessibilityID.usageLimitReached).exists)
        waitForSelectedLimit("200")
        // 0 is not among the fixed values; only the six are offered.
        XCTAssertFalse(limitOption("0").exists)
        screenshot("RD17 usage today")

        // 7 Days adds the article text of 3 days ago.
        choosePeriod("7 Days")
        let body = waitFor(total(Seed.normal, "body"))
        XCTAssertEqual(body.label, "Article Text, 1 request, 300 input tokens · 50 output tokens")
        XCTAssertTrue(total(Seed.normal, "titles").exists)
        XCTAssertFalse(total(Seed.normal, "page").exists)
        XCTAssertFalse(total(Seed.normal, "overview").exists)

        // 30 Days adds the web page of 20 days ago; the overview of 40 days
        // ago is never shown.
        choosePeriod("30 Days")
        let page = waitFor(total(Seed.normal, "page"))
        XCTAssertEqual(page.label, "Web Pages, 1 request, 1,000 input tokens · 200 output tokens")
        XCTAssertTrue(total(Seed.normal, "body").exists)
        XCTAssertFalse(total(Seed.normal, "overview").exists)

        // Criterion 5: a chosen limit is stored at once and kept.
        chooseLimit("500")
        XCTAssertEqual(todayLine.label, "Automatic requests today: 2 of 500")
        openSettings()
        openUsage()
        // The period is not remembered.
        XCTAssertTrue(waitFor(periodPicker.buttons["Today"]).isSelected)
        waitForSelectedLimit("500")
        XCTAssertEqual(todayLine.label, "Automatic requests today: 2 of 500")

        // Criterion 7: inside the adult partition, the adult library's rows
        // and limit only.
        turnOnAdult()
        enterAdult()
        openUsage()
        waitFor(total(Seed.adult, "titles"))
        assertNothingShown(of: [Seed.normal], on: "the adult Usage")
        waitForSelectedLimit("200")
        XCTAssertEqual(todayLine.label, "Automatic requests today: 2 of 200")
        chooseLimit("50")
        XCTAssertEqual(todayLine.label, "Automatic requests today: 2 of 50")
        choosePeriod("30 Days")
        waitFor(total(Seed.adult, "page"))
        assertNothingShown(of: [Seed.normal], on: "the adult Usage over 30 days")
        screenshot("RD17 adult usage")

        // Locked by leaving the app (the timing rule, "Immediately") while
        // the adult Usage shows the adult rows: at once no adult row is
        // anywhere.
        XCTAssertTrue(total(Seed.adult, "titles").exists)
        leaveAndReturn()
        waitForReport(Self.closed, Self.dropped)
        assertNothingShown(of: [Seed.adult], on: "the app at once after the lock")
        waitForPartition(Wording.normal)
        assertNothingShown(of: [Seed.adult], on: "the normal partition after the lock")

        // The normal Usage: its own rows and its own limit, unchanged by the
        // adult partition's 50.
        openUsage()
        waitFor(total(Seed.normal, "titles"))
        assertNothingShown(of: [Seed.adult], on: "the normal Usage after the lock")
        waitForSelectedLimit("500")
        XCTAssertEqual(todayLine.label, "Automatic requests today: 2 of 500")
        choosePeriod("30 Days")
        waitFor(total(Seed.normal, "page"))
        assertNothingShown(of: [Seed.adult], on: "the normal Usage over 30 days after the lock")
    }

    /// Criteria 5 and 6, assumptions A3 and A4: launched with a stored
    /// limit of 0, the feed's rows are stopped by the limit and nothing is
    /// sent; Usage shows the stored 0 as its own row; after 200 is chosen
    /// nothing is sent while Usage is open, and the rows, asked for again
    /// when the list is shown after Settings, are sent and translated
    /// without a pull or any other trigger.
    func testTheChosenLimitIsTheOneTheNextRequestReads() {
        let first = "Foreign story 01"
        launchForUsage(seed: false, models: "primary", limit: 0)
        createCategory("World")
        addSource("https://translation.example.invalid/rss.xml", to: "World")
        openCategoryList("World")
        let row = waitFor(articleRow(first))
        waitFor(button(AccessibilityID.translationWarning(first)))
        waitForLabel(row, containing: "Today's automatic limit is reached. Translate manually, or raise the limit in Settings")
        XCTAssertEqual(translationRequests, 0, report)

        // A3: the stored 0, which is not a fixed value, is shown selected.
        openUsage()
        waitForSelectedLimit("0")
        XCTAssertEqual(todayLine.label, "Automatic requests today: 0 of 0")
        waitFor(element(AccessibilityID.usageLimitReached))
        waitFor(element(AccessibilityID.usageEmpty))
        screenshot("RD17 stored limit 0")
        chooseLimit("200")
        XCTAssertEqual(todayLine.label, "Automatic requests today: 0 of 200")
        waitForAbsence(element(AccessibilityID.usageLimitReached))
        // Once 200 is stored the stored value is a fixed one: 0 is gone.
        waitForAbsence(limitOption("0"))
        // Nothing is sent while Usage is open: no row is on screen and
        // choosing a limit triggers nothing.
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(translationRequests, 0, report)

        // A4: the list shown again — the Library tab on the tab structure,
        // the list chosen in the sidebar on the panes.
        if app.tabBars.firstMatch.exists {
            app.tabBars.buttons.element(boundBy: 1).tap()
            waitFor(app.navigationBars["World"])
        } else {
            openCategoryList("World")
        }
        let translated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            row.exists && row.label.contains("译[zh-Hans]：\(first)")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [translated], timeout: 20), .completed,
                       "\(row.exists ? row.label : "absent"); \(report)")
        XCTAssertGreaterThan(translationRequests, 0, report)
        XCTAssertFalse(button(AccessibilityID.translationWarning(first)).exists)
        screenshot("RD17 translated after the limit was raised")
    }
}
