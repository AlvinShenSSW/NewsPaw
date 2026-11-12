import XCTest

/// RD05 criteria 10–15: source rows in the category list and Source
/// settings, against the debug fixture transport only.
final class SourceListTests: NewsPawUITestCase {
    private let feed = "https://feed.example.invalid/rss.xml"
    private let sequence = "https://sequence.example.invalid/rss.xml"

    /// Criterion 10: expand and collapse; a swipe on a source row offers no
    /// Delete; with categories expanded, edit mode shows a handle and a
    /// delete control for every category and none for a source; RD03's
    /// reorder and delete still work with sources present.
    func testRowsAndEditModeWithSourcesPresent() {
        launchAtFullWidth()
        createCategory("World")
        createCategory("Tech")
        addSource(feed, to: "World")
        addSource("https://onefeed.example.invalid/feed.xml", to: "Tech")
        expand("World")
        expand("Tech")
        let fixture = waitFor(sourceRow("Fixture Feed"))
        waitFor(sourceRow("One Feed"))

        // Collapse and expand again.
        let disclosure = button(AccessibilityID.disclosure("World"))
        XCTAssertEqual(disclosure.label, "Sources of “World”")
        XCTAssertEqual(disclosure.value as? String, "Shown")
        XCTAssertGreaterThanOrEqual(disclosure.frame.width, 44 - 0.001)
        XCTAssertGreaterThanOrEqual(disclosure.frame.height, 44 - 0.001)
        disclosure.tap()
        waitForAbsence(sourceRow("Fixture Feed"))
        XCTAssertEqual(disclosure.value as? String, "Hidden")
        disclosure.tap()
        waitFor(sourceRow("Fixture Feed"))

        // A swipe on a source row offers no Delete.
        fixture.swipeLeft()
        sleep(1)
        screenshot("swipe-on-source-row")
        XCTAssertFalse(app.buttons["Delete"].exists, "a swipe on a source row offers Delete")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == 'Delete'")).firstMatch.exists)
        // On the iPhone the list does not take a horizontal swipe, so the
        // row's button can take it as a tap and open Source settings.
        if app.textFields[AccessibilityID.nameField].exists {
            button(AccessibilityID.cancelButton).tap()
            waitForAbsence(app.textFields[AccessibilityID.nameField])
        }
        // A source row opened from the slide-over closes it first.
        expand("World")
        waitFor(sourceRow("Fixture Feed"))

        // Edit mode: a handle and a delete control for each category, none
        // for a source.
        setEditing(true)
        waitFor(reorderHandle("World"))
        XCTAssertTrue(reorderHandle("Tech").exists)
        XCTAssertFalse(reorderHandle("Fixture Feed").exists)
        XCTAssertFalse(reorderHandle("One Feed").exists)
        let removes = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Remove, '")).allElementsBoundByIndex
        XCTAssertEqual(Set(removes.map(\.label)), ["Remove, World", "Remove, Tech"])
        XCTAssertTrue(sourceRow("Fixture Feed").exists, "edit mode leaves expansion as it is")
        screenshot("edit-mode-with-sources")

        // RD03's reorder and delete.
        reorderHandle("Tech").press(forDuration: 0.8, thenDragTo: reorderHandle("World"))
        waitForOrder(["Tech", "World"])
        deleteInEditMode("World")
        waitFor(app.staticTexts["Delete “World”?"])
        XCTAssertTrue(app.staticTexts["This category has 1 source. Move it to another category, or delete it with the category."].exists)
        app.buttons["Move Sources to “Tech”"].tap()
        waitForAbsence(element(AccessibilityID.categoryRow("World")))
        setEditing(false)
        expand("Tech")
        waitFor(sourceRow("Fixture Feed"))
        waitFor(sourceRow("One Feed"))
    }

    /// Criteria 11 and 14: rename, pause, the options and a move, each kept
    /// after a relaunch; the row shows the pause mark.
    func testFeedSettingsSurviveRelaunch() {
        launchAtFullWidth()
        createCategory("World")
        createCategory("Tech")
        addSource(feed, to: "World")
        openSourceSettings("Fixture Feed", in: "World")
        XCTAssertEqual(element(AccessibilityID.sourceAddress).label, feed)
        XCTAssertTrue(app.staticTexts["Saved now; used once translation and full-text reading are available."].exists)
        let name = app.textFields[AccessibilityID.nameField]
        name.clearAndType("Renamed\n")
        let paused = app.switches[AccessibilityID.pausedToggle]
        flip(paused)
        XCTAssertEqual(paused.value as? String, "1")
        choose("Off", in: AccessibilityID.translateTitlesPicker)
        choose("Always Fetch the Page", in: AccessibilityID.bodyModePicker)
        choose("Tech", in: AccessibilityID.sourceCategoryPicker)
        tapSave()
        waitForAbsence(name)

        expand("Tech")
        let row = waitFor(sourceRow("Renamed"))
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Paused'"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: timeout), .completed, "\(String(describing: row.value))")
        relaunch()
        rotate(.portrait)
        openSourceSettings("Renamed", in: "Tech")
        XCTAssertEqual(app.switches[AccessibilityID.pausedToggle].value as? String, "1")
        XCTAssertTrue(button(AccessibilityID.translateTitlesPicker).label.contains("Off"))
        XCTAssertTrue(button(AccessibilityID.bodyModePicker).label.contains("Always Fetch the Page"))
        XCTAssertTrue(button(AccessibilityID.sourceCategoryPicker).label.contains("Tech"))
        // Paused: no "Update Now".
        XCTAssertTrue(scrollTo(element(AccessibilityID.sourceStatus)).label.hasPrefix("Paused"))
        XCTAssertFalse(button(AccessibilityID.updateNowButton).exists)
        button(AccessibilityID.cancelButton).tap()
    }

    /// Criterion 12: a web page shows only name, address, category,
    /// "Translate When Opened" and Delete.
    func testWebPageSettings() {
        launchAtFullWidth()
        createCategory("World")
        openAddSource()
        detect("https://nofeed.example.invalid/")
        waitFor(button(AccessibilityID.saveAsWebPageButton)).tap()
        chooseCategoryAndSave("World")
        openSourceSettings("Plain Page", in: "World")
        let toggle = waitFor(app.switches[AccessibilityID.translatePageToggle])
        XCTAssertEqual(toggle.value as? String, "0", "off by default")
        XCTAssertTrue(element(AccessibilityID.sourceAddress).exists)
        XCTAssertTrue(button(AccessibilityID.copyAddressButton).exists)
        XCTAssertTrue(button(AccessibilityID.sourceCategoryPicker).exists)
        XCTAssertTrue(scrollTo(button(AccessibilityID.deleteSourceButton)).exists)
        for absent in [AccessibilityID.pausedToggle, AccessibilityID.translateTitlesPicker, AccessibilityID.bodyModePicker,
                       AccessibilityID.sourceStatus, AccessibilityID.updateNowButton] {
            XCTAssertFalse(element(absent).exists, absent)
        }
        screenshot("web-page-settings")
        flip(toggle)
        tapSave()
        waitForAbsence(toggle)
        relaunch()
        rotate(.portrait)
        openSourceSettings("Plain Page", in: "World")
        XCTAssertEqual(app.switches[AccessibilityID.translatePageToggle].value as? String, "1")
        button(AccessibilityID.cancelButton).tap()
    }

    /// Criterion 13: working → failing → working with "Update Now", the
    /// failing sentence in the row and in the settings.
    func testStatusWorkingFailingWorking() {
        launchAtFullWidth()
        createCategory("World")
        addSource(sequence, to: "World")
        openSourceSettings("Sequence Feed", in: "World")
        let status = scrollTo(element(AccessibilityID.sourceStatus))
        scrollTo(button(AccessibilityID.updateNowButton))
        XCTAssertTrue(status.label.hasPrefix("Working · last updated"), status.label)
        XCTAssertTrue(status.label.contains("Newest item"), status.label)
        let update = button(AccessibilityID.updateNowButton)
        XCTAssertEqual(update.label, "Update Now")
        update.tap()
        let failing = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH 'Could not update · the server answered with error 500 · last worked'"),
            object: status
        )
        XCTAssertEqual(XCTWaiter.wait(for: [failing], timeout: timeout), .completed, status.label)
        XCTAssertEqual(update.label, "Try Again")
        screenshot("status-failing")
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(status)
        showCategoryList()
        let row = waitFor(sourceRow("Sequence Feed"))
        XCTAssertTrue((row.value as? String ?? "").hasPrefix("Could not update · the server answered with error 500"), "\(String(describing: row.value))")

        openSourceSettings("Sequence Feed", in: "World")
        scrollTo(button(AccessibilityID.updateNowButton)).tap()
        let working = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'Working · last updated'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [working], timeout: timeout), .completed, status.label)
        button(AccessibilityID.cancelButton).tap()
        showCategoryList()
        // The third answer holds a new item.
        let row2 = waitFor(sourceRow("Sequence Feed"))
        let two = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '2 unread'"), object: row2)
        XCTAssertEqual(XCTWaiter.wait(for: [two], timeout: timeout), .completed, "\(String(describing: row2.value))")
    }

    /// Criterion 15: the confirmation names the source and its articles;
    /// the settings sheet closes and the row goes.
    func testDeleteFromSettings() {
        launchAtFullWidth()
        createCategory("World")
        addSource(feed, to: "World")
        addSource("https://onefeed.example.invalid/feed.xml", to: "World")
        openSourceSettings("Fixture Feed", in: "World")
        scrollTo(button(AccessibilityID.deleteSourceButton)).tap()
        waitFor(app.staticTexts["Delete “Fixture Feed”?"])
        XCTAssertTrue(app.staticTexts["Its 3 articles are deleted with it, including any you starred."].exists)
        sourceDeletionDialogButton().tap()
        waitForAbsence(app.textFields[AccessibilityID.nameField])
        showCategoryList()
        waitForAbsence(sourceRow("Fixture Feed"))
        XCTAssertTrue(sourceRow("One Feed").exists, "the other source is untouched")
    }

    /// Criterion 15 from the row's menu; criterion 10's Pause and Resume.
    func testRowMenu() {
        launchAtFullWidth()
        createCategory("World")
        addSource(feed, to: "World")
        expand("World")
        let row = waitFor(sourceRow("Fixture Feed"))
        row.press(forDuration: 1.2)
        waitFor(app.buttons["Pause"]).tap()
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Paused'"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: timeout), .completed)
        row.press(forDuration: 1.2)
        waitFor(app.buttons["Resume"]).tap()
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '3 unread'"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: timeout), .completed)
        row.press(forDuration: 1.2)
        waitFor(app.buttons["Delete"]).tap()
        waitFor(app.staticTexts["Delete “Fixture Feed”?"])
        sourceDeletionDialogButton().tap()
        waitForAbsence(row)
    }

    /// Criterion 11: a save that fails shows the alert on the sheet, which
    /// stays open with its values.
    func testFailedSettingsSaveKeepsTheSheet() {
        launchAtFullWidth()
        createCategory("World")
        addSource(feed, to: "World")
        app.terminate()
        launchAtFullWidth(failNextSourceSave: true)
        openSourceSettings("Fixture Feed", in: "World")
        let name = app.textFields[AccessibilityID.nameField]
        name.clearAndType("Changed\n")
        tapSave()
        let alert = waitFor(app.alerts["The change could not be saved."])
        alert.buttons["OK"].tap()
        waitForAbsence(alert)
        XCTAssertEqual(name.value as? String, "Changed")
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(name)
        showCategoryList()
        waitFor(sourceRow("Fixture Feed"))
    }

    /// Criterion 18: at the largest accessibility text size source rows
    /// grow and their text is not cut.
    func testLargestTextSizeGrowsSourceRows() {
        launchAtFullWidth()
        createCategory("World")
        addSource(feed, to: "World")
        let defaultHeight = waitFor(sourceRow("Fixture Feed")).frame.height
        app.terminate()
        launch(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        rotate(.portrait)
        expand("World")
        let row = scrollTo(sourceRow("Fixture Feed"))
        XCTAssertGreaterThan(row.frame.height, defaultHeight * 1.5, "the row grows")
        XCTAssertLessThanOrEqual(row.frame.maxX, window.maxX + 0.5)
        screenshot("largest-text-source-rows")
    }

    // MARK: - Helpers

    /// The deletion dialog's button, not Source settings' own button of the
    /// same name.
    private func sourceDeletionDialogButton() -> XCUIElement {
        waitFor(app.buttons.matching(NSPredicate(
            format: "label == 'Delete Source' AND identifier != %@", AccessibilityID.deleteSourceButton
        )).firstMatch)
    }

    /// Chooses `option` in a menu picker.
    private func choose(_ option: String, in picker: String) {
        waitFor(button(picker)).tap()
        waitFor(app.buttons[option].firstMatch).tap()
        let chosen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", option), object: button(picker))
        XCTAssertEqual(XCTWaiter.wait(for: [chosen], timeout: timeout), .completed, "\(picker): \(button(picker).label)")
    }
}
