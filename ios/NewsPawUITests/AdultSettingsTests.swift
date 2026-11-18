import XCTest

/// RD18: Settings › Adult Partition — asking before it opens, turning the
/// partition off with its data kept or deleted, and the feature switch.
final class AdultSettingsTests: AdultTestCase {
    // MARK: - Criterion 10

    /// While the partition is on and locked, opening its settings asks for
    /// authentication: cancelled leaves the screen closed with the
    /// sentence, and a passed one opens the screen without unlocking the
    /// partition.
    func testOpeningTheSettingsAsksAndDoesNotUnlock() {
        launchAtFullWidth(authentication: ["passed", "cancelled", "failed", "unavailable", "interrupted", "passed"])
        turnOnAdult()
        for sentence in [Wording.settingsNeedAuthentication, Wording.settingsNeedAuthentication, Wording.passcodeNeeded] {
            tapAdultRow()
            answerAlert(sentence)
            XCTAssertFalse(turnOffButton.exists, "the screen opened after \(sentence)")
            XCTAssertTrue(adultRow.exists)
        }
        // Interrupted: nothing is said and nothing opens.
        tapAdultRow()
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 2))
        XCTAssertFalse(turnOffButton.exists)

        tapAdultRow()
        waitFor(turnOffButton)
        // The partition is still locked: no adult workspace was built and
        // the library was not opened.
        XCTAssertTrue(report.contains(Self.closed) && report.contains("library=released") && report.contains("workspace=none"), report)
        XCTAssertEqual(partitionLabel(), Wording.normal)
        XCTAssertFalse(lockButton.exists)
    }

    // MARK: - Criterion 11

    /// Keep Data Hidden hides the switch and keeps the data: after turning
    /// on again the category is there.
    func testKeepDataHidden() {
        launchAtFullWidth(authentication: ["passed", "passed", "passed", "passed", "passed"])
        turnOnAdult()
        enterAdult()
        createCategory("Velvet")
        tapLock()
        waitForPartition(Wording.normal)

        // From the normal partition: its settings ask first.
        tapAdultRow()
        waitFor(turnOffButton).tap()
        // Cancel leaves everything as it was.
        answerAlert(Wording.turnOffQuestion, with: "Cancel")
        XCTAssertTrue(turnOffButton.exists)
        turnOffButton.tap()
        answerAlert(Wording.turnOffQuestion, with: "Keep Data Hidden")
        // The screen shows its "off" contents; the switch is gone; the file
        // is kept and not held open.
        waitFor(adultToggle)
        XCTAssertEqual(adultToggle.value as? String, "0")
        waitForReport("file=1", Self.closed, Self.dropped)
        XCTAssertFalse(switchIsOffered(), "the partition switch is still shown")

        // Turning on again brings the data back.
        turnOnAdult()
        enterAdult()
        showCategoryList()
        waitFor(element(AccessibilityID.categoryRow("Velvet")))
    }

    // MARK: - Criterion 12

    /// Delete, chosen from inside the adult partition: both questions are
    /// shown, the app returns to the normal partition, the database is
    /// gone, and turning on afterwards shows an empty partition.
    func testDeleteFromInsideTheAdultPartition() {
        launchAtFullWidth(authentication: ["passed", "passed", "passed", "passed"])
        createCategory("World")
        turnOnAdult()
        enterAdult()
        createCategory("Velvet")
        addSource(Fixture.articles, to: "Velvet")

        // Inside the adult partition its settings open without asking.
        tapAdultRow()
        scrollTo(turnOffButton).tap()
        answerAlert(Wording.turnOffQuestion, with: "Delete Data")
        // Cancelling the second question deletes nothing.
        answerAlert(Wording.deleteQuestion, with: "Cancel")
        XCTAssertTrue(turnOffButton.exists)
        XCTAssertTrue(report.contains("file=1") && report.contains("workspace=held"), report)
        turnOffButton.tap()
        answerAlert(Wording.turnOffQuestion, with: "Delete Data")
        answerAlert(Wording.deleteQuestion, with: "Delete")

        // The normal partition, on Settings (the current tab), with the
        // partition off, its file gone and everything of it released.
        waitFor(adultRow)
        XCTAssertFalse(turnOffButton.exists)
        XCTAssertFalse(app.alerts.firstMatch.exists, "a deletion that worked says nothing")
        // The library is closed and its file gone; the workspace is gone.
        waitForReport("file=0", Self.closed, Self.dropped)
        XCTAssertFalse(switchIsOffered(), "the partition switch is still shown")
        showCategoryList()
        waitFor(element(AccessibilityID.categoryRow("World")))
        XCTAssertFalse(element(AccessibilityID.categoryRow("Velvet")).exists)

        // Turning on afterwards: an empty partition.
        turnOnAdult()
        waitForReport("file=1")
        enterAdult()
        showCategoryList()
        waitFor(element(AccessibilityID.noCategories))
        XCTAssertFalse(element(AccessibilityID.categoryRow("Velvet")).exists)
        XCTAssertFalse(element(AccessibilityID.categoryRow("World")).exists)
    }

    // MARK: - Criterion 13

    /// With the feature switch off there is no Settings row and no
    /// partition switch, also when the partition was turned on before and
    /// its file exists; and nothing of it is opened.
    func testFeatureSwitchOff() {
        launchAtFullWidth(authentication: ["passed", "passed"])
        turnOnAdult()
        enterAdult()
        createCategory("Velvet")
        waitForReport("file=1", "pool=open", "library=held")
        app.terminate()

        launchAtFullWidth(authentication: ["passed", "passed"], adultFeatureOff: true)
        openSettings()
        XCTAssertFalse(adultRow.exists, "the Settings row is shown with the feature off")
        if app.tabBars.firstMatch.exists {
            for tab in 0..<3 {
                app.tabBars.buttons.element(boundBy: tab).tap()
                XCTAssertFalse(partitionSwitch.waitForExistence(timeout: 1), "the switch is on tab \(tab)")
            }
        } else {
            openSidebarIfNeeded()
            XCTAssertFalse(partitionSwitch.waitForExistence(timeout: 1))
        }
        XCTAssertFalse(lockButton.exists)
        // The file is there and nothing opened it.
        waitForReport("file=1", Self.closed, "library=released", "workspace=none")

        // The next launch with the feature on has everything again.
        app.terminate()
        launchAtFullWidth(authentication: ["passed"])
        enterAdult()
        showCategoryList()
        waitFor(element(AccessibilityID.categoryRow("Velvet")))
    }
}
