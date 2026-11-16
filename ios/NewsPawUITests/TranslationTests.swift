import XCTest

/// RD14 (ux S3, S4, S8; spec N06): rows show their translation where they
/// stand, a title with markup is shown as text, the marks and their
/// questions, the reading language and the original line, on the
/// translator fixture. Criteria 5, 7, 10, 11 and 12 (UI), assumptions A3
/// and A4.
final class TranslationTests: TranslationTestCase {
    /// Criteria 11 and 12: translated rows, Chinese as it is or converted,
    /// a title with HTML and Markdown shown literally, older rows
    /// translated when they appear, and the open article's header.
    func testRowsShowTheirTranslation() {
        launchTranslating()
        addFeed(Translation.feed, to: Translation.category)

        // The rows keep their identifier on the original title.
        let first = waitFor(articleRow(Translation.foreign(1)))
        waitForLabel(first, containing: Translation.translated(Translation.foreign(1)))
        // Criterion 11: the markup comes back and is shown as text.
        let markup = waitFor(articleRow(Translation.markup))
        waitForLabel(markup, containing: Translation.translated(Translation.markup))
        // Simplified Chinese stays as it is; Traditional is converted on the
        // device, with no model.
        let simplified = waitFor(articleRow(Translation.simplified))
        XCTAssertFalse(simplified.label.contains("译["), simplified.label)
        XCTAssertTrue(simplified.label.contains(Translation.simplified), simplified.label)
        waitForLabel(waitFor(articleRow(Translation.traditional)), containing: Translation.traditionalConverted)
        // The original line is off by default.
        XCTAssertFalse(first.label.contains("\(Translation.foreign(1)), \(Translation.foreign(1))"), first.label)
        // No mark on a translated row.
        XCTAssertFalse(warningMark(Translation.foreign(1)).exists)
        XCTAssertFalse(activityMark(Translation.foreign(1)).exists)

        // A row beyond the pass's 50 is translated when it appears.
        let older = scrollList(to: Translation.foreign(58))
        waitForLabel(older, containing: Translation.translated(Translation.foreign(58)))

        // The open article's header: the translation, the original under it.
        openArticle(Translation.foreign(58), showing: Translation.translated(Translation.foreign(58)))
        XCTAssertEqual(waitFor(element(AccessibilityID.readingOriginalTitle)).label, Translation.foreign(58))
        screenshot("RD14 translated rows and article")
    }

    /// Criteria 10 and 12: "Show Original Titles in Lists" adds the
    /// original line; a new reading language shows none of the old one and
    /// translates the rows on screen in the new one (the fixture's mark
    /// names the language).
    func testOriginalLineAndReadingLanguage() {
        launchTranslating()
        addFeed(Translation.feed, to: Translation.category)
        waitForLabel(waitFor(articleRow(Translation.foreign(1))), containing: Translation.translated(Translation.foreign(1)))

        openTranslationSettings()
        let original = app.switches[AccessibilityID.showOriginalTitlesToggle]
        XCTAssertEqual(waitFor(original).value as? String, "0")
        XCTAssertEqual(app.switches[AccessibilityID.autoTranslateToggle].value as? String, "1")
        XCTAssertTrue(option("Simplified Chinese").isSelected)
        flip(original)
        openCategoryList(Translation.category)
        let row = waitFor(articleRow(Translation.foreign(1)))
        waitForLabel(row, containing: "\(Translation.translated(Translation.foreign(1))), \(Translation.foreign(1)),")

        openTranslationSettings()
        option("Japanese").tap()
        let chosen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: option("Japanese"))
        XCTAssertEqual(XCTWaiter.wait(for: [chosen], timeout: timeout), .completed)
        openCategoryList(Translation.category)
        let japanese = waitFor(articleRow(Translation.foreign(1)))
        waitForLabel(japanese, containing: Translation.translated(Translation.foreign(1), "ja"))
        XCTAssertFalse(japanese.label.contains("译[zh-Hans]"), japanese.label)
        // Chinese is foreign under Japanese.
        waitForLabel(waitFor(articleRow(Translation.simplified)), containing: Translation.translated(Translation.simplified, "ja"))

        // Back to Simplified Chinese: the kept rows show again.
        openTranslationSettings()
        option("Simplified Chinese").tap()
        openCategoryList(Translation.category)
        waitForLabel(waitFor(articleRow(Translation.foreign(1))), containing: Translation.translated(Translation.foreign(1)))
    }

    /// Criteria 5 and 12, and assumption A3: a refused row has the warning
    /// mark; its tap asks the question (not the article), with "Retry with
    /// the Backup Model" since a backup is set up; the row itself still
    /// opens its article, swipes and has its menu.
    func testRefusedRowAndItsQuestion() {
        launchTranslating(models: "primary,backup")
        addFeed(Translation.wordFeed("refuse"), to: "Refused")
        let row = waitFor(articleRow(Translation.refused))
        let mark = waitFor(warningMark(Translation.refused))
        waitForLabel(row, containing: "\(Sentence.notTranslated), \(Sentence.refused)")
        XCTAssertGreaterThanOrEqual(mark.frame.width, 43.99)
        XCTAssertGreaterThanOrEqual(mark.frame.height, 43.99)
        XCTAssertEqual(mark.label, Sentence.notTranslated)

        // A3: the mark takes its own tap.
        mark.tap()
        waitFor(question(Sentence.refused))
        XCTAssertEqual(Set(alertButtonLabels()), ["Retry", "Retry with the Backup Model", "Cancel"])
        XCTAssertFalse(readingTitle.exists, "the mark's tap opened the article")
        screenshot("RD14 refused question")
        alertButton("Cancel").tap()
        waitForAbsence(question(Sentence.refused))

        // "Retry with the Backup Model" sends to the backup, which refuses
        // this word too: the row is marked again.
        mark.tap()
        alertButton("Retry with the Backup Model").tap()
        waitForAbsence(question(Sentence.refused))
        waitFor(warningMark(Translation.refused))
        waitForLabel(row, containing: Sentence.refused)

        // A3: the row's swipe and menu still work beside the mark.
        swipeAction(on: row, leading: true, "Mark as Read")
        waitForUnread(row, false)
        row.press(forDuration: 1.2)
        waitFor(menuButton("Mark as Unread")).tap()
        waitForUnread(row, true)
        // The row opens its article, under the original title.
        openArticle(Translation.refused, showing: Translation.refused)
        XCTAssertFalse(element(AccessibilityID.readingOriginalTitle).exists)
    }

    /// RD21 criterion 10 (spec N01): with no model set up, the foreign rows
    /// of a source that translates automatically show the warning mark,
    /// and a row in the reading language none; the mark's question says
    /// "Set up a model to translate" with "Open Settings", which opens
    /// Models & Translation; once a primary model is saved the marks go and
    /// the titles translate.
    func testNoModelMarkOpensSettings() {
        launchReading()
        addFeed(Translation.feed, to: Translation.category)
        let row = waitFor(articleRow(Translation.foreign(1)))
        let mark = waitFor(warningMark(Translation.foreign(1)))
        waitForLabel(row, containing: "Not translated, Set up a model to translate")
        XCTAssertEqual(mark.label, Sentence.notTranslated)
        XCTAssertFalse(warningMark(Translation.simplified).exists, "a row in the reading language is marked")
        XCTAssertFalse(row.label.contains("译["), row.label)

        mark.tap()
        waitFor(question("Set up a model to translate"))
        XCTAssertEqual(Set(alertButtonLabels()), ["Open Settings", "Cancel"])
        XCTAssertFalse(readingTitle.exists, "the mark's tap opened the article")
        alertButton("Open Settings").tap()
        waitForAbsence(question("Set up a model to translate"))
        waitFor(element(AccessibilityID.primaryModelRow)).tap()
        setUpTranslatorInForm()
        waitFor(element(AccessibilityID.primaryModelRow))

        openCategoryList(Translation.category)
        let translated = waitFor(articleRow(Translation.foreign(1)))
        waitLong(for: translated, containing: Translation.translated(Translation.foreign(1)))
        XCTAssertFalse(warningMark(Translation.foreign(1)).exists, "the mark stayed after a model was saved")
    }

    /// Criterion 5 (UI): a 429 without a backup blocks the row with the
    /// service's sentence and Retry; a retry that fails again says so in
    /// an alert and stores nothing.
    func testServiceFailureRow() {
        launchTranslating()
        addFeed(Translation.wordFeed("limit"), to: "Limited")
        let row = waitFor(articleRow(Translation.limited))
        waitFor(warningMark(Translation.limited)).tap()
        waitFor(question(Sentence.limited))
        XCTAssertEqual(Set(alertButtonLabels()), ["Retry", "Cancel"])
        alertButton("Retry").tap()
        // Retried at once, refused again by the service: the sentence again.
        waitFor(question(Sentence.limited))
        alertButton("Cancel").tap()
        waitForAbsence(question(Sentence.limited))
        XCTAssertFalse(row.label.contains("译["), row.label)
        waitFor(warningMark(Translation.limited))
    }

    /// Criteria 7 and 12: at the daily limit the row is marked with section
    /// 4's sentence; Retry sends it anyway and the row shows the activity
    /// mark from the tap until the (slow) answer arrives.
    func testDailyLimitAndActivityMark() {
        launchTranslating(limit: 0)
        addFeed(Translation.wordFeed("slow"), to: "Slow")
        let row = waitFor(articleRow(Translation.slow))
        waitFor(warningMark(Translation.slow)).tap()
        waitFor(question(Sentence.dailyLimit))
        XCTAssertEqual(Set(alertButtonLabels()), ["Retry", "Cancel"])
        alertButton("Retry").tap()
        waitFor(activityMark(Translation.slow))
        XCTAssertTrue(row.label.contains("Translating…"), row.label)
        XCTAssertFalse(warningMark(Translation.slow).exists)
        waitForLabel(row, containing: Translation.translated(Translation.slow))
        waitForAbsence(activityMark(Translation.slow))
        XCTAssertFalse(warningMark(Translation.slow).exists)
    }

    /// Assumption A4: rows updated in place while the list is scrolled do
    /// not move it. The list is scrolled to the middle of the 63 rows, the
    /// reading language changes to Japanese, and the rows on screen are
    /// translated again where they stand.
    func testUpdatesInPlaceKeepTheScrollPosition() {
        launchTranslating()
        addFeed(Translation.feed, to: Translation.category)
        let anchor = scrollList(to: Translation.foreign(30))
        waitForLabel(anchor, containing: Translation.translated(Translation.foreign(30)))
        let before = anchor.frame.minY
        let topBefore = topRowTitle()
        record("A4 before", "top row \(topBefore ?? "none"), Foreign story 30 at \(before)")

        openTranslationSettings()
        option("Japanese").tap()
        if usesTabs {
            // The Library tab keeps its stack and the list's place.
            app.tabBars.buttons.element(boundBy: 1).tap()
        } else {
            openCategoryList(Translation.category)
            _ = scrollList(to: Translation.foreign(30))
        }
        let row = waitFor(articleRow(Translation.foreign(30)))
        waitForLabel(row, containing: Translation.translated(Translation.foreign(30), "ja"))
        let afterFirst = row.frame.minY
        // Wait for the rest of the updates of the rows on screen.
        Thread.sleep(forTimeInterval: 2)
        let after = row.frame.minY
        record("A4 after", "top row \(topRowTitle() ?? "none"), Foreign story 30 at \(afterFirst) then \(after)")
        XCTAssertEqual(afterFirst, after, accuracy: 0.5, "the updates in place moved the list")
        if usesTabs {
            XCTAssertEqual(before, after, accuracy: 0.5, "the list did not keep its place across the change")
        }
    }
}
