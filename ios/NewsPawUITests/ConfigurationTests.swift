import XCTest

/// RD20: export and import of the configuration file. XCUITest cannot drive
/// the Files picker: under the UI tests "Import Configuration" reads a
/// fixture file (decision 10) through the same bounded read as a chosen
/// file.
///
/// The fixtures: `both` — "Imported News" with "Imported Feed" in the
/// normal partition, "Imported Private" with "Imported Hidden" in the adult
/// one, a model on the fixture host in each, the refresh interval "Every
/// Hour"; `normal` — the same without the adult partition; `refused` — a
/// model service address that is http.
final class ConfigurationTests: AdultTestCase {
    enum Wording {
        static let question = "This file also contains the adult partition."
        static let skipped = "The adult partition in this file was skipped."
        static let replaceNow = "Replace now?"
        static let refusedTitle = "Could not import this file"
        static let onlyNormal = "Only the normal partition is replaced."
        static let notEncrypted = "The file is not encrypted: anyone who has it can read the adult partition's categories and sources."
        static let exportInside = "To include the adult partition, export from inside it."
    }

    /// Launches with "Import Configuration" reading `fixture`.
    func launchReading(_ fixture: String?, authentication: [String] = [], writePause: Int? = nil) {
        let application = XCUIApplication()
        if let fixture {
            application.launchEnvironment[UITestLaunchKey.configurationFixture] = fixture
        }
        if let writePause {
            application.launchEnvironment[UITestLaunchKey.configurationWritePause] = String(writePause)
        }
        launch(application, authentication: authentication)
        rotate(.portrait)
        requireFullWidth()
    }

    /// Settings › Data, from wherever the app is.
    func openDataSettings() {
        openSettings()
        waitFor(element(AccessibilityID.dataRow)).tap()
        waitFor(button(AccessibilityID.importConfigurationButton))
    }

    func text(of element: XCUIElement) -> String {
        [element.label, element.value as? String ?? ""].joined(separator: " ")
    }

    func assertText(_ identifier: String, contains parts: [String], file: StaticString = #filePath, line: UInt = #line) {
        let shown = text(of: waitFor(element(identifier), file: file, line: line))
        for part in parts {
            XCTAssertTrue(shown.contains(part), "\(identifier) says \"\(shown)\", not \(part)", file: file, line: line)
        }
    }

    /// Waits for the alert with `text` and answers it with `answer`. An
    /// alert's button can be listed twice (iOS 27): the first is tapped.
    func answer(_ text: String, with answer: String, file: StaticString = #filePath, line: UInt = #line) {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: timeout), "no alert; expected \(text)", file: file, line: line)
        XCTAssertTrue(alert.staticTexts[text].exists, "the alert says \(alert.staticTexts.allElementsBoundByIndex.map(\.label))", file: file, line: line)
        alert.buttons.matching(NSPredicate(format: "label == %@", answer)).firstMatch.tap()
        waitForAbsence(alert.staticTexts[text], file: file, line: line)
    }

    /// The question's alert, answered with `answer`.
    func answerQuestion(_ answer: String, file: StaticString = #filePath, line: UInt = #line) {
        self.answer(Wording.question, with: answer, file: file, line: line)
    }

    func tapWhenEnabled(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let control = scrollTo(button(identifier), file: file, line: line)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: timeout), .completed, "\(identifier) stayed disabled", file: file, line: line)
        control.tap()
    }

    /// Replace Everything → the review → Replace → "Replace now?" → Replace.
    func replaceEverything(expectingOnlyNormal: Bool, file: StaticString = #filePath, line: UInt = #line) {
        tapWhenEnabled(AccessibilityID.configurationReplaceEverythingButton, file: file, line: line)
        waitFor(button(AccessibilityID.configurationReplaceButton), file: file, line: line)
        XCTAssertEqual(element(AccessibilityID.configurationOnlyNormal).exists, expectingOnlyNormal, file: file, line: line)
        screenshot("review")
        button(AccessibilityID.configurationReplaceButton).tap()
        answer(Wording.replaceNow, with: "Replace", file: file, line: line)
    }

    /// Done on the summary.
    func leaveSummary(file: StaticString = #filePath, line: UInt = #line) {
        waitFor(button(AccessibilityID.configurationDoneButton), file: file, line: line).tap()
        waitForAbsence(button(AccessibilityID.configurationDoneButton), file: file, line: line)
    }

    /// A category of the category list, which shows it.
    func waitForCategory(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        showCategoryList()
        waitFor(element(AccessibilityID.categoryRow(name)), file: file, line: line)
    }

    /// The share sheet is on screen with the exported file, and is closed.
    func assertShareSheetShownAndClose(file: StaticString = #filePath, line: UInt = #line) {
        let sheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(sheet.waitForExistence(timeout: timeout), "no share sheet", file: file, line: line)
        let caption = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'NewsPaw Configuration '")).firstMatch
        XCTAssertTrue(caption.waitForExistence(timeout: timeout), "the sheet does not show the file", file: file, line: line)
        XCTAssertFalse(caption.label.localizedCaseInsensitiveContains("adult"), caption.label, file: file, line: line)
        screenshot("share-sheet")
        let close = app.buttons.matching(NSPredicate(format: "identifier == 'header.closeButton' OR label IN %@", ["Close", "关闭"])).firstMatch
        if close.waitForExistence(timeout: 3) {
            close.tap()
        } else {
            sheet.swipeDown(velocity: .fast)
        }
        waitForAbsence(sheet, file: file, line: line)
    }

    // MARK: - Criterion 11: export

    /// The switch hidden while the partition is off, shown disabled in the
    /// normal partition while it is on, enabled and off inside it; each
    /// export reaches the share sheet.
    func testExportSwitch() {
        launchReading(nil, authentication: ["passed", "passed"])
        openDataSettings()
        XCTAssertFalse(app.switches[AccessibilityID.includeAdultToggle].exists)
        button(AccessibilityID.exportConfigurationButton).tap()
        assertShareSheetShownAndClose()

        turnOnAdult()
        openDataSettings()
        let toggle = waitFor(app.switches[AccessibilityID.includeAdultToggle])
        XCTAssertFalse(toggle.isEnabled)
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertTrue(app.staticTexts[Wording.exportInside].exists)
        button(AccessibilityID.exportConfigurationButton).tap()
        assertShareSheetShownAndClose()

        enterAdult()
        openDataSettings()
        let inside = waitFor(app.switches[AccessibilityID.includeAdultToggle])
        XCTAssertTrue(inside.isEnabled)
        XCTAssertEqual(inside.value as? String, "0")
        XCTAssertFalse(app.staticTexts[Wording.exportInside].exists)
        flip(inside)
        waitFor(app.staticTexts[Wording.notEncrypted])
        screenshot("data-adult-included")
        button(AccessibilityID.exportConfigurationButton).tap()
        assertShareSheetShownAndClose()
        // Off again each time the screen opens.
        goBack()
        waitFor(element(AccessibilityID.dataRow)).tap()
        XCTAssertEqual(waitFor(app.switches[AccessibilityID.includeAdultToggle]).value as? String, "0")
    }

    // MARK: - Criteria 9 and 10: the adult question

    /// Criterion 10: "Unlock" authenticates once, shows the adult partition,
    /// and the preview covers both partitions; Merge; the summary says
    /// which models need a key; Set Up Keys opens the models.
    func testUnlockAndMergeBoth() {
        launchReading("both", authentication: ["passed", "passed"])
        turnOnAdult()
        openDataSettings()
        button(AccessibilityID.importConfigurationButton).tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: timeout))
        XCTAssertTrue(alert.buttons["Unlock"].exists)
        screenshot("question")
        answerQuestion("Unlock")
        assertText(AccessibilityID.configurationCounts("normal"), contains: ["1 category · 1 source"])
        assertText(AccessibilityID.configurationCounts("adult"), contains: ["1 category · 1 source"])
        assertText(AccessibilityID.configurationGroup("new", "adult"), contains: ["3"])
        waitForReport("pool=open")
        screenshot("preview-both")
        tapWhenEnabled(AccessibilityID.configurationMergeButton)
        assertText(AccessibilityID.configurationKeysNeeded("normal"), contains: ["1 model needs a key."])
        assertText(AccessibilityID.configurationKeysNeeded("adult"), contains: ["1 model needs a key."])
        screenshot("summary")
        button(AccessibilityID.configurationSetUpKeys("normal")).tap()
        waitFor(element(AccessibilityID.primaryModelRow))
        XCTAssertTrue(app.staticTexts["Key needed"].exists || app.descendants(matching: .any)["Key needed"].exists)
        waitForPartition(AdultTestCase.Wording.adult)
        waitForCategory(Self.adultCategory)
        tapLock()
        waitForPartition(AdultTestCase.Wording.normal)
        waitForCategory(Self.normalCategory)
        waitForReport(AdultTestCase.closed)
    }

    static let normalCategory = "Imported News"
    static let adultCategory = "Imported Private"

    /// Criterion 10: with the partition off, "Turn On and Unlock"
    /// authenticates twice and shows the preview of both partitions.
    func testTurnOnAndUnlock() {
        launchReading("both", authentication: ["passed", "passed"])
        openDataSettings()
        button(AccessibilityID.importConfigurationButton).tap()
        answerQuestion("Turn On and Unlock")
        assertText(AccessibilityID.configurationCounts("adult"), contains: ["1 category · 1 source"])
        waitForReport("pool=open")
        button(AccessibilityID.configurationCancelButton).tap()
        waitForAbsence(element(AccessibilityID.configurationCounts("adult")))
        waitForPartition(AdultTestCase.Wording.adult)
    }

    /// Criterion 9: "Normal Partition Only" builds the preview of the
    /// normal partition, says the adult part was skipped, and never opens
    /// the adult library; the normal model holds no adult part.
    func testNormalPartitionOnly() {
        launchReading("both", authentication: ["passed"])
        turnOnAdult()
        openDataSettings()
        waitForReport(AdultTestCase.closed, "configuration=none")
        button(AccessibilityID.importConfigurationButton).tap()
        answerQuestion("Normal Partition Only")
        waitFor(element(AccessibilityID.configurationAdultSkipped))
        waitFor(element(AccessibilityID.configurationCounts("normal")))
        XCTAssertFalse(element(AccessibilityID.configurationCounts("adult")).exists)
        waitForReport(AdultTestCase.closed, "configuration=normal")
        tapWhenEnabled(AccessibilityID.configurationMergeButton)
        waitFor(element(AccessibilityID.configurationAdultSkipped))
        waitFor(button(AccessibilityID.configurationDoneButton))
        waitForReport(AdultTestCase.closed)
        leaveSummary()
        waitForReport(AdultTestCase.closed, "configuration=none")
        waitForCategory(Self.normalCategory)
        XCTAssertFalse(element(AccessibilityID.categoryRow(Self.adultCategory)).exists)
    }

    /// Criterion 9: a declined unlock says so, then builds the normal
    /// preview; the adult library is never opened.
    func testDeclinedUnlock() {
        launchReading("both", authentication: ["passed", "cancelled"])
        turnOnAdult()
        openDataSettings()
        button(AccessibilityID.importConfigurationButton).tap()
        answerQuestion("Unlock")
        answerAlert(AdultTestCase.Wording.stillLocked)
        waitFor(element(AccessibilityID.configurationAdultSkipped))
        XCTAssertFalse(element(AccessibilityID.configurationCounts("adult")).exists)
        waitForReport(AdultTestCase.closed, "configuration=normal")
        button(AccessibilityID.configurationCancelButton).tap()
        waitForReport(AdultTestCase.closed, "configuration=none")
    }

    // MARK: - Criteria 6 and 8: Replace

    /// Replace with a normal-only file inside the adult partition: no
    /// question, the review says only the normal partition is replaced,
    /// the second question, and the adult content unchanged after locking
    /// and unlocking. Settings › Refresh shows the file's interval.
    func testReplaceNormalInsideAdult() {
        launchReading("normal", authentication: ["passed", "passed", "passed"])
        turnOnAdult()
        enterAdult()
        createCategory("Hidden Stuff")
        openDataSettings()
        button(AccessibilityID.importConfigurationButton).tap()
        waitFor(element(AccessibilityID.configurationCounts("normal")))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        replaceEverything(expectingOnlyNormal: true)
        waitFor(button(AccessibilityID.configurationDoneButton))
        screenshot("summary-replace")
        leaveSummary()
        waitForCategory("Hidden Stuff")
        tapLock()
        waitForPartition(AdultTestCase.Wording.normal)
        waitForCategory(Self.normalCategory)
        enterAdult()
        waitForCategory("Hidden Stuff")
        XCTAssertFalse(element(AccessibilityID.categoryRow(Self.normalCategory)).exists)
        openSettings()
        waitFor(element(AccessibilityID.refreshRow)).tap()
        XCTAssertTrue(waitFor(timing("Every Hour")).isSelected)
    }

    /// Merge leaves the settings: Settings › Refresh keeps its interval; a
    /// second import finds everything here.
    func testMergeKeepsSettings() {
        launchReading("normal")
        openDataSettings()
        button(AccessibilityID.importConfigurationButton).tap()
        waitFor(button(AccessibilityID.configurationSettingsRow))
        tapWhenEnabled(AccessibilityID.configurationMergeButton)
        leaveSummary()
        openSettings()
        waitFor(element(AccessibilityID.refreshRow)).tap()
        XCTAssertTrue(waitFor(timing("Every 30 Minutes")).isSelected)
        openDataSettings()
        button(AccessibilityID.importConfigurationButton).tap()
        waitFor(element(AccessibilityID.configurationNothingNew))
        XCTAssertFalse(button(AccessibilityID.configurationMergeButton).isEnabled)
        button(AccessibilityID.configurationCancelButton).tap()
    }

    /// Criterion 6 and 12: Cancel at each step changes nothing — the
    /// question, the preview, the review and the second question.
    func testCancelChangesNothing() {
        launchReading("both", authentication: ["passed"])
        turnOnAdult()
        openDataSettings()
        button(AccessibilityID.importConfigurationButton).tap()
        answerQuestion("Cancel")
        waitForAbsence(element(AccessibilityID.configurationCounts("normal")))
        button(AccessibilityID.importConfigurationButton).tap()
        answerQuestion("Normal Partition Only")
        button(AccessibilityID.configurationCancelButton).tap()
        waitForAbsence(element(AccessibilityID.configurationCounts("normal")))
        button(AccessibilityID.importConfigurationButton).tap()
        answerQuestion("Normal Partition Only")
        tapWhenEnabled(AccessibilityID.configurationReplaceEverythingButton)
        button(AccessibilityID.configurationReplaceButton).tap()
        answer(Wording.replaceNow, with: "Cancel")
        // The review's own Back: on the iPad a pane's Back is behind the
        // sheet.
        waitFor(app.navigationBars.matching(identifier: "Before Replacing").buttons.matching(identifier: "BackButton").firstMatch).tap()
        button(AccessibilityID.configurationCancelButton).tap()
        waitForAbsence(element(AccessibilityID.configurationCounts("normal")))
        showCategoryList()
        XCTAssertFalse(element(AccessibilityID.categoryRow(Self.normalCategory)).waitForExistence(timeout: 2))
        openSettings()
        waitFor(element(AccessibilityID.refreshRow)).tap()
        XCTAssertTrue(waitFor(timing("Every 30 Minutes")).isSelected)
    }

    /// A refused file: the alert with its reason; nothing changes.
    func testRefusedFile() {
        launchReading("refused")
        openDataSettings()
        button(AccessibilityID.importConfigurationButton).tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: timeout))
        XCTAssertTrue(alert.staticTexts[Wording.refusedTitle].exists)
        XCTAssertTrue(alert.staticTexts["A model service address is not https (model 1)."].exists,
                      "\(alert.staticTexts.allElementsBoundByIndex.map(\.label))")
        screenshot("refused")
        alert.buttons["OK"].tap()
        waitForAbsence(alert)
        showCategoryList()
        XCTAssertFalse(element(AccessibilityID.categoryRow(Self.normalCategory)).waitForExistence(timeout: 2))
    }

    /// A3: Add source's row closes the sheet and the import goes on from
    /// the root.
    func testFromAddSource() {
        launchReading("normal")
        openAddSource()
        scrollTo(button(AccessibilityID.addSourceImportConfigurationButton)).tap()
        waitForAbsence(app.textFields[AccessibilityID.addressField])
        waitFor(element(AccessibilityID.configurationCounts("normal")))
        tapWhenEnabled(AccessibilityID.configurationMergeButton)
        leaveSummary()
        waitForCategory(Self.normalCategory)
    }

    // MARK: - Criterion 13: a lock during the write

    /// A Replace confirmed inside the adult partition, then a lock while
    /// the write's completion waits: back in the normal partition, the
    /// normal list shows the result, and no summary is shown anywhere.
    func testLockDuringWrite() {
        launchReading("both", authentication: ["passed", "passed", "passed"], writePause: 6)
        turnOnAdult()
        enterAdult()
        openDataSettings()
        button(AccessibilityID.importConfigurationButton).tap()
        waitFor(element(AccessibilityID.configurationCounts("adult")))
        replaceEverything(expectingOnlyNormal: false)
        // The write ran; its completion waits. Leaving the app locks it
        // ("Immediately").
        leaveAndReturn()
        waitForReport(AdultTestCase.closed)
        XCTAssertFalse(button(AccessibilityID.configurationDoneButton).exists)
        // The completion reloaded the normal workspace.
        waitForCategory(Self.normalCategory)
        Thread.sleep(forTimeInterval: 8)
        XCTAssertFalse(button(AccessibilityID.configurationDoneButton).exists)
        enterAdult()
        waitForCategory(Self.adultCategory)
        XCTAssertFalse(button(AccessibilityID.configurationDoneButton).exists)
    }
}
