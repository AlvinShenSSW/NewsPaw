import XCTest

/// RD21 criteria 9 and 10 in the adult partition: its first opening shows
/// no first run, Today says "No sources yet" and its Add source has no
/// suggested sources; and with no model set up its foreign rows show no
/// mark (the adult workspace has no translation until RD19).
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

    /// Criterion 10's "the adult partition shows no mark": no model is set
    /// up, and the adult partition's foreign rows show none (the normal
    /// partition's would).
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
        // Rows appear and are refreshed: long enough for the normal
        // partition's rows to be marked (they are within a second).
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(button(AccessibilityID.translationWarning(Self.foreign)).exists, "an adult row shows the no-model mark")
        XCTAssertFalse(row.label.contains("Set up a model to translate"), row.label)
    }
}
