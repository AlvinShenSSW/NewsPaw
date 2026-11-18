import XCTest

/// RD21 criteria 9 and 10 in the adult partition: its first opening shows
/// no first run, Today says "No sources yet" and its Add source has no
/// suggested sources; and with no model set up its foreign rows show the
/// no-model mark, whose "Open Settings" opens the adult slots (RD21's note
/// to RD19, RD19's note to RD21: the adult workspace translates with its
/// own models since RD19, so "the adult partition shows no mark" is gone).
final class FirstRunAdultTests: AdultTestCase {
    static let translationFeed = "https://translation.example.invalid/rss.xml"
    static let foreign = "Foreign story 01"

    /// Launches with the first run allowed and the stand-in's answers.
    private func launchFirstRun(authentication: [String]) {
        let application = XCUIApplication()
        application.launchEnvironment[UITestLaunchKey.firstRun] = "1"
        launch(application, authentication: authentication)
        rotate(.portrait)
        requireFullWidth()
    }

    /// Skips the three steps; the first run ends on Today.
    private func skipFirstRun() {
        waitFor(element(AccessibilityID.firstRun))
        for _ in 1...3 {
            waitFor(button(AccessibilityID.firstRunSkip)).tap()
        }
        waitForAbsence(element(AccessibilityID.firstRun))
        waitFor(element(AccessibilityID.todayDate))
    }

    func testTheAdultPartitionsFirstOpening() {
        launchFirstRun(authentication: ["passed", "passed"])
        skipFirstRun()
        waitForReport("file=0")
        turnOnAdult()
        enterAdult()
        showToday()
        XCTAssertFalse(element(AccessibilityID.firstRun).exists, "the adult partition shows a first run")
        XCTAssertEqual(waitFor(element(AccessibilityID.todayEmpty)).label, "No sources yet")
        waitFor(button(AccessibilityID.todayAddSourceButton)).tap()
        waitFor(app.textFields[AccessibilityID.addressField])
        XCTAssertFalse(button(AccessibilityID.suggestedSourcesRow).exists, "the adult partition offers suggested sources")
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(app.textFields[AccessibilityID.addressField])
    }

    /// Criterion 10 in the adult partition, as RD19 left it: no model is set
    /// up in either partition, and the adult partition's foreign rows show
    /// what a workspace without a model shows — the original title and the
    /// mark "Set up a model to translate" — whose "Open Settings" opens the
    /// adult partition's own slots, never the normal partition's (N08: a
    /// partition with no model does not borrow the other's), and nothing is
    /// sent.
    func testTheAdultPartitionShowsNoModelMark() {
        launch(authentication: ["passed", "passed"])
        rotate(.portrait)
        requireFullWidth()
        turnOnAdult()
        enterAdult()
        createCategory("Velvet")
        addSource(Self.translationFeed, to: "Velvet")
        openCategoryList("Velvet")
        let row = waitFor(articleRow(Self.foreign))
        pullList()
        let mark = waitFor(button(AccessibilityID.translationWarning(Self.foreign)))
        XCTAssertEqual(mark.label, "Not translated")
        waitForLabel(row, containing: "Not translated, Set up a model to translate")
        XCTAssertFalse(row.label.contains("译["), row.label)
        mark.tap()
        let question = waitFor(app.alerts.firstMatch)
        XCTAssertTrue(question.staticTexts["Set up a model to translate"].exists, question.debugDescription)
        question.buttons.matching(NSPredicate(format: "label == %@", "Open Settings")).firstMatch.tap()
        waitForAbsence(question)
        waitFor(element(AccessibilityID.adultPrimaryModelRow))
        XCTAssertFalse(element(AccessibilityID.primaryModelRow).exists, "the normal slots were opened from the adult partition")
        let report = self.report
        let sent = report.range(of: "translationRequests=").map { Int(report[$0.upperBound...].prefix { $0.isNumber }) ?? -1 }
        XCTAssertEqual(sent, 0, "a request was sent with no model: \(report)")
    }
}
