import XCTest

/// RD08: OPML import from Add source and from Settings › Data, a refused
/// file, a failed write, export and its share sheet, and both in the adult
/// partition. XCUITest cannot drive the Files picker: under the UI tests
/// "Import OPML" reads a fixture document (decision 8) through the same
/// bounded read as a chosen file.
///
/// The `folders` fixture: "News" (Fixture Feed, Two Feeds News in a nested
/// "World", Articles), "Tech" (One Feed, and Fixture Feed again), outside
/// any folder Two Feeds Updates, Fast Feed and an address that is not http
/// or https, and a settings block that is ignored.
final class OPMLTests: AdultTestCase {
    /// Launches with "Import OPML" reading `fixture`.
    func launchReading(_ fixture: String, failNextSourceSave: Bool = false, authentication: [String] = []) {
        let application = XCUIApplication()
        application.launchEnvironment[UITestLaunchKey.opmlFixture] = fixture
        launch(application, failNextSourceSave: failNextSourceSave, authentication: authentication)
        rotate(.portrait)
        requireFullWidth()
    }

    /// Settings › Data, from wherever the app is.
    func openDataSettings() {
        openSettings()
        waitFor(element(AccessibilityID.dataRow)).tap()
        waitFor(button(AccessibilityID.importOPMLButton))
    }

    /// What an element says: its label and its value.
    func text(of element: XCUIElement) -> String {
        [element.label, element.value as? String ?? ""].joined(separator: " ")
    }

    func assertText(_ identifier: String, contains parts: [String], file: StaticString = #filePath, line: UInt = #line) {
        let shown = text(of: waitFor(element(identifier), file: file, line: line))
        for part in parts {
            XCTAssertTrue(shown.contains(part), "\(identifier) says \"\(shown)\", not \(part)", file: file, line: line)
        }
    }

    /// The preview's category row → "New Category…" → `name` → Done.
    func chooseNewCategory(_ name: String) {
        waitFor(button(AccessibilityID.opmlCategoryRow)).tap()
        waitFor(button(AccessibilityID.opmlNewCategoryButton)).tap()
        let field = waitFor(app.textFields[AccessibilityID.opmlNewCategoryField])
        field.tap()
        field.typeText(name)
        waitFor(button(AccessibilityID.opmlUseNameButton)).tap()
        waitFor(button(AccessibilityID.opmlImportButton))
    }

    func tapImportWhenEnabled(file: StaticString = #filePath, line: UInt = #line) {
        let importButton = waitFor(button(AccessibilityID.opmlImportButton), file: file, line: line)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: importButton)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: timeout), .completed, "Import stayed disabled", file: file, line: line)
        importButton.tap()
    }

    // MARK: - Criteria 1, 5 and 9: from Add source

    /// The preview's numbers before anything is written, an existing
    /// category for the feeds outside any folder, the summary with every
    /// skipped entry, Done closing Add source, the Library showing what
    /// was added, and the refresh that follows collecting it.
    func testImportFromAddSource() {
        launchReading("folders")
        createCategory("Tech")
        addSource(Fixture.articles, to: "Tech")

        openAddSource()
        scrollTo(button(AccessibilityID.addSourceImportOPMLButton)).tap()
        assertText(AccessibilityID.opmlFeedsToAdd, contains: ["Feeds to Add", "5"])
        assertText(AccessibilityID.opmlFolder("News"), contains: ["New Category", "2"])
        assertText(AccessibilityID.opmlFolder("Tech"), contains: ["Existing Category", "1"])
        assertText(AccessibilityID.opmlOutsideFeeds, contains: ["2"])
        assertText(AccessibilityID.opmlCategoryRow, contains: ["Required"])
        assertText(AccessibilityID.opmlSkippedRow, contains: ["3"])
        screenshot("preview")
        // Import waits for the category of the feeds outside any folder.
        XCTAssertFalse(button(AccessibilityID.opmlImportButton).isEnabled)
        // Nothing was written by the preview.
        XCTAssertFalse(element(AccessibilityID.categoryRow("News")).exists)

        button(AccessibilityID.opmlCategoryRow).tap()
        waitFor(button(AccessibilityID.opmlCategoryChoice("Tech"))).tap()
        assertText(AccessibilityID.opmlCategoryRow, contains: ["Tech"])
        tapImportWhenEnabled()

        assertText(AccessibilityID.opmlFeedsAdded, contains: ["Feeds Added", "5"])
        assertText(AccessibilityID.opmlFolder("News"), contains: ["New Category", "2"])
        assertText(AccessibilityID.opmlFolder("Tech"), contains: ["Existing Category", "3"])
        scrollTo(button(AccessibilityID.opmlSkippedRow)).tap()
        assertText(AccessibilityID.opmlSkipped(0), contains: ["Articles", Fixture.articles, "Already in Tech"])
        assertText(AccessibilityID.opmlSkipped(1), contains: ["Fixture Feed (again)", Fixture.feed, "Listed earlier in this file"])
        assertText(AccessibilityID.opmlSkipped(2), contains: ["Old Scheme", "feed://oldscheme.example.invalid/rss.xml", "Not an http or https address"])
        goBack()
        waitFor(button(AccessibilityID.opmlDoneButton)).tap()
        waitForAbsence(element(AccessibilityID.opmlFeedsAdded))
        // Done closed Add source too.
        waitForAbsence(app.textFields[AccessibilityID.addressField])

        showCategoryList()
        waitForOrder(["Tech", "News"])
        expand("News")
        waitFor(sourceRow("Fixture Feed"))
        waitFor(sourceRow("Two Feeds News"))
        expand("Tech")
        for name in ["One Feed", "Two Feeds Updates", "Fast Feed"] {
            waitFor(sourceRow(name))
        }
        // The refresh that followed the import reached the new sources.
        waitForValue(sourceRow("Fixture Feed"), "3 unread")
        waitForValue(sourceRow("One Feed"), "1 unread")
    }

    // MARK: - Criteria 1, 4, 5 and 9: from Settings › Data

    /// "New Category…" with the name of a folder of the file, the summary
    /// left by a swipe (the lists already read again, the refresh started),
    /// then the same file again: nothing to add, and Cancel changes
    /// nothing.
    func testImportFromSettingsWithNewCategoryAndAgain() {
        launchReading("folders")
        openDataSettings()
        button(AccessibilityID.importOPMLButton).tap()
        assertText(AccessibilityID.opmlFeedsToAdd, contains: ["6"])
        assertText(AccessibilityID.opmlFolder("News"), contains: ["New Category", "3"])
        assertText(AccessibilityID.opmlFolder("Tech"), contains: ["New Category", "1"])

        chooseNewCategory("News")
        assertText(AccessibilityID.opmlCategoryRow, contains: ["News"])
        tapImportWhenEnabled()
        assertText(AccessibilityID.opmlFeedsAdded, contains: ["6"])
        assertText(AccessibilityID.opmlFolder("News"), contains: ["New Category", "5"])

        // Left by a swipe, not Done.
        let title = waitFor(app.navigationBars["Import Complete"])
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        waitForAbsence(element(AccessibilityID.opmlFeedsAdded))

        showCategoryList()
        waitForOrder(["News", "Tech"])
        expand("News")
        for name in ["Fixture Feed", "Two Feeds News", "Articles", "Two Feeds Updates", "Fast Feed"] {
            waitFor(sourceRow(name))
        }
        waitForValue(sourceRow("Fixture Feed"), "3 unread")

        openDataSettings()
        button(AccessibilityID.importOPMLButton).tap()
        waitFor(element(AccessibilityID.opmlNothingToAdd))
        assertText(AccessibilityID.opmlFeedsToAdd, contains: ["0"])
        assertText(AccessibilityID.opmlFolder("News"), contains: ["Existing Category", "0"])
        XCTAssertFalse(element(AccessibilityID.opmlCategoryRow).exists)
        XCTAssertFalse(button(AccessibilityID.opmlImportButton).isEnabled)
        screenshot("nothing-to-add")
        button(AccessibilityID.opmlCancelButton).tap()
        waitForAbsence(element(AccessibilityID.opmlFeedsToAdd))
        showCategoryList()
        waitForOrder(["News", "Tech"])
    }

    // MARK: - Criterion 2 in the app: a refused file

    /// A file with a document type is refused with its reason, from both
    /// entry points, and nothing changes.
    func testRefusedFile() {
        launchReading("refused")
        let reason = "The file declares a document type (<!DOCTYPE>), which is not accepted."
        openDataSettings()
        button(AccessibilityID.importOPMLButton).tap()
        answerAlert(reason)
        XCTAssertFalse(element(AccessibilityID.opmlFeedsToAdd).waitForExistence(timeout: 2))

        openAddSource()
        scrollTo(button(AccessibilityID.addSourceImportOPMLButton)).tap()
        let alert = waitFor(app.alerts.firstMatch)
        XCTAssertTrue(alert.staticTexts[reason].exists)
        screenshot("refused")
        alert.buttons["OK"].tap()
        // Add source stays open.
        waitFor(app.textFields[AccessibilityID.addressField])
        button(AccessibilityID.cancelButton).tap()
        showCategoryList()
        waitFor(element(AccessibilityID.noCategories))
    }

    // MARK: - Criterion 4 and the failure table: a failed write

    /// The write fails: the preview stays with the reason, nothing was
    /// added, and Import works again.
    func testFailedWriteKeepsThePreview() {
        launchReading("folders", failNextSourceSave: true)
        openDataSettings()
        button(AccessibilityID.importOPMLButton).tap()
        chooseNewCategory("Loose")
        tapImportWhenEnabled()
        assertText(AccessibilityID.opmlFailure, contains: ["The import could not be saved. Nothing was added."])
        assertText(AccessibilityID.opmlFeedsToAdd, contains: ["6"])
        tapImportWhenEnabled()
        assertText(AccessibilityID.opmlFeedsAdded, contains: ["6"])
        button(AccessibilityID.opmlDoneButton).tap()
        showCategoryList()
        waitForOrder(["News", "Tech", "Loose"])
    }

    // MARK: - Criteria 6 and 9: export (A5)

    /// Export is disabled while the library has no feed; Cancel on a
    /// preview changes nothing; after an import Export presents the share
    /// sheet.
    func testExport() {
        launchReading("folders")
        openDataSettings()
        XCTAssertFalse(button(AccessibilityID.exportOPMLButton).isEnabled)
        button(AccessibilityID.importOPMLButton).tap()
        waitFor(element(AccessibilityID.opmlFeedsToAdd))
        button(AccessibilityID.opmlCancelButton).tap()
        waitForAbsence(element(AccessibilityID.opmlFeedsToAdd))
        XCTAssertFalse(button(AccessibilityID.exportOPMLButton).isEnabled)

        button(AccessibilityID.importOPMLButton).tap()
        chooseNewCategory("Loose")
        tapImportWhenEnabled()
        waitFor(button(AccessibilityID.opmlDoneButton)).tap()
        waitForAbsence(element(AccessibilityID.opmlFeedsAdded))

        let export = button(AccessibilityID.exportOPMLButton)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: export)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: timeout), .completed, "Export stayed disabled")
        export.tap()
        assertShareSheetShownAndClose()
    }

    /// A5: the share sheet is on screen; it is closed again.
    func assertShareSheetShownAndClose(file: StaticString = #filePath, line: UInt = #line) {
        let sheet = element(AccessibilityID.opmlShareSheet)
        XCTAssertTrue(sheet.waitForExistence(timeout: timeout), "no share sheet", file: file, line: line)
        screenshot("share-sheet")
        print("RD08 A5 | share sheet elements: \(app.buttons.allElementsBoundByIndex.prefix(30).map(\.label))")
        let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "关闭"])).firstMatch
        if close.waitForExistence(timeout: 3) {
            close.tap()
        } else {
            sheet.swipeDown(velocity: .fast)
        }
        waitForAbsence(sheet)
    }

    // MARK: - Criterion 8 in the app: the adult partition

    /// In the adult partition: import into the adult library and export it;
    /// back in the normal partition nothing of it is there.
    func testImportAndExportInTheAdultPartition() {
        launchReading("folders", authentication: ["passed", "passed"])
        turnOnAdult()
        enterAdult()
        openDataSettings()
        XCTAssertFalse(button(AccessibilityID.exportOPMLButton).isEnabled)
        button(AccessibilityID.importOPMLButton).tap()
        assertText(AccessibilityID.opmlFeedsToAdd, contains: ["6"])
        chooseNewCategory("Adult Loose")
        tapImportWhenEnabled()
        assertText(AccessibilityID.opmlFeedsAdded, contains: ["6"])
        button(AccessibilityID.opmlDoneButton).tap()
        waitForAbsence(element(AccessibilityID.opmlFeedsAdded))
        let export = button(AccessibilityID.exportOPMLButton)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: export)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: timeout), .completed, "Export stayed disabled")
        export.tap()
        assertShareSheetShownAndClose()
        showCategoryList()
        waitForOrder(["News", "Tech", "Adult Loose"])

        chooseNormal()
        waitForPartition(Wording.normal)
        showCategoryList()
        waitFor(element(AccessibilityID.noCategories))
        openDataSettings()
        XCTAssertFalse(button(AccessibilityID.exportOPMLButton).isEnabled)
    }
}
