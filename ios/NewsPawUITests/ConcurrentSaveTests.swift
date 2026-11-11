import XCTest

/// RD03 C1, C2: a save that is still running when the user acts again. The
/// debug launch key makes the next save wait before it runs; each test fails
/// as inconclusive if its own steps did not finish well inside that wait.
final class ConcurrentSaveTests: NewsPawUITestCase {
    /// Waits `seconds` without polling the app.
    private func pause(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "the slow save")], timeout: seconds)
    }

    private func requireWithinDelay(since start: Date, delay: TimeInterval, _ what: String) -> Bool {
        let elapsed = Date().timeIntervalSince(start)
        if elapsed < delay - 5 {
            return true
        }
        XCTFail("inconclusive: \(what) took \(Int(elapsed)) s, not well inside the \(Int(delay)) s save")
        return false
    }

    /// C1: a New Category save that finishes after its editor was cancelled
    /// does not close a second New Category editor opened meanwhile. (The
    /// Category Settings variant takes the same path through the editor
    /// session; it is not run here because each context menu costs the test
    /// harness about 60 s of idle wait, more than the save's delay.)
    func testAnEarlierSaveDoesNotCloseAReplacementEditor() {
        let delay = 25.0
        launchAtFullWidth(slowNextSave: Int(delay))
        openNewCategory()
        let field = app.textFields[AccessibilityID.nameField]
        field.tap()
        field.typeText("Alpha\n")
        tapSave()
        let saved = Date()
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(field)
        showCategoryList()
        XCTAssertFalse(element(AccessibilityID.categoryRow("Alpha")).exists, "the slow save has not finished yet")

        openNewCategory()
        field.tap()
        field.typeText("Beta")
        guard requireWithinDelay(since: saved, delay: delay, "opening the second editor") else { return }

        pause(delay - Date().timeIntervalSince(saved) + 4)
        XCTAssertTrue(field.exists, "the second editor is still open after the first save finished")
        XCTAssertEqual(field.value as? String, "Beta", "the second editor keeps its text")

        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(field)
        showCategoryList()
        waitFor(element(AccessibilityID.categoryRow("Alpha")))
        XCTAssertFalse(element(AccessibilityID.categoryRow("Beta")).exists)
    }

    /// C2: while a confirmed deletion is still running, rows cannot be
    /// moved, neither with the reorder handle in edit mode nor by a long
    /// press and drag; no save error follows and the order is unchanged.
    func testRowsCannotMoveWhileADeletionRuns() {
        let delay = 90.0
        launchAtFullWidth()
        createCategory("Alpha")
        createCategory("Beta")
        createCategory("Gamma")
        app.terminate()
        launchAtFullWidth(slowNextSave: Int(delay))
        showCategoryList()
        waitForOrder(["Alpha", "Beta", "Gamma"])

        deleteInEditMode("Beta")
        waitFor(app.staticTexts["Delete “Beta”?"])
        deletionDialogButton("Delete Category").tap()
        let confirmed = Date()
        waitForAbsence(element(AccessibilityID.categoryRow("Beta")))

        // Edit mode: the reorder handle.
        let handle = reorderHandle("Gamma")
        let handleShown = handle.exists
        if handleShown {
            handle.press(forDuration: 0.8, thenDragTo: reorderHandle("Alpha"))
        }
        XCTAssertFalse(handleShown, "no reorder handle while a deletion runs")
        XCTAssertEqual(categoryNamesShown(), ["Alpha", "Gamma"], "the handle did not move a row")

        // Out of edit mode: a long press and drag.
        setEditing(false)
        element(AccessibilityID.categoryRow("Gamma"))
            .press(forDuration: 1.2, thenDragTo: element(AccessibilityID.categoryRow("Alpha")))
        let menu = app.buttons["Category Settings"]
        if menu.exists {
            // The long press opened the row's context menu instead of a
            // drag; a tap on the bar's title area closes it.
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: window.minX + 150, dy: window.minY + 100))
                .tap()
            waitForAbsence(menu)
            showCategoryList()
        }
        XCTAssertEqual(categoryNamesShown(), ["Alpha", "Gamma"], "a long press and drag did not move a row")
        guard requireWithinDelay(since: confirmed, delay: delay, "the move attempts") else { return }

        // The reorder handle comes back when the deletion has finished.
        setEditing(true)
        let back = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: reorderHandle("Gamma"))
        XCTAssertEqual(XCTWaiter.wait(for: [back], timeout: delay + 30), .completed, "rows can be moved again after the deletion")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(confirmed), delay - 1, "moving came back only after the save's delay")
        XCTAssertFalse(app.alerts["The change could not be saved."].exists, "no save error")
        XCTAssertFalse(element(AccessibilityID.categoryRow("Beta")).exists, "the deleted category is gone")
        XCTAssertEqual(categoryNamesShown(), ["Alpha", "Gamma"])
        setEditing(false)

        relaunch()
        rotate(.portrait)
        showCategoryList()
        waitForOrder(["Alpha", "Gamma"])
    }
}
