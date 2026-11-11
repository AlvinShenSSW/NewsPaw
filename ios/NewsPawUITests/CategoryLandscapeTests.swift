import XCTest

/// Criteria 4–7 in landscape on each device (F2): the sidebar pane and the
/// root dialog host on iPad from 1100 pt, the tab structure on iPhone.
final class CategoryLandscapeTests: NewsPawUITestCase {
    /// Create, rename through Category Settings, reorder, and delete the
    /// shown category with the dialog; the order is still there after a
    /// relaunch.
    func testEssentialPathsInLandscape() {
        launchAtFullWidth(.landscapeLeft)
        if isPad {
            XCTAssertGreaterThanOrEqual(window.width, 1100)
            waitFor(element(AccessibilityID.sidebarPane))
        }
        createCategory("Alpha")
        createCategory("Beta")

        openCategorySettings("Beta")
        let field = app.textFields[AccessibilityID.nameField]
        field.clearAndType("Gamma\n")
        tapSave()
        waitForAbsence(field)
        showCategoryList()
        waitFor(element(AccessibilityID.categoryRow("Gamma")))

        setEditing(true)
        waitFor(reorderHandle("Gamma")).press(forDuration: 0.8, thenDragTo: reorderHandle("Alpha"))
        waitForOrder(["Gamma", "Alpha"])
        setEditing(false)

        // Show Alpha, then delete it from edit mode.
        element(AccessibilityID.categoryRow("Alpha")).tap()
        waitFor(app.navigationBars["Alpha"])
        waitFor(element(AccessibilityID.categoryEmpty))
        if !isPad {
            app.navigationBars["Alpha"].buttons.element(boundBy: 0).tap()
            waitFor(app.navigationBars["Library"])
        }
        deleteInEditMode("Alpha")
        waitFor(app.staticTexts["Delete “Alpha”?"])
        if isPad {
            // The pending category is still a category: its pane keeps its
            // title behind the dialog (F7).
            XCTAssertTrue(app.navigationBars["Alpha"].exists, "the shown category keeps its title while the dialog is open")
        }
        deletionDialogButton("Delete Category").tap()
        waitForAbsence(element(AccessibilityID.categoryRow("Alpha")))
        setEditing(false)
        if isPad {
            waitFor(app.navigationBars["All Unread"])
            XCTAssertTrue(element(AccessibilityID.allUnreadEmpty).exists, "the selection moved to All Unread")
        }

        relaunch()
        rotate(.landscapeLeft)
        showCategoryList()
        waitFor(element(AccessibilityID.categoryRow("Gamma")))
        XCTAssertEqual(categoryNamesShown(), ["Gamma"])
    }

    /// A save that fails in landscape shows the alert and keeps the sheet
    /// open with its text.
    func testForcedFailureInLandscape() {
        launchAtFullWidth(.landscapeLeft, failNextSave: true)
        openNewCategory()
        let field = app.textFields[AccessibilityID.nameField]
        field.tap()
        field.typeText("World\n")
        tapSave()
        let alert = waitFor(app.alerts["The change could not be saved."])
        alert.buttons["OK"].tap()
        waitForAbsence(alert)
        XCTAssertEqual(field.value as? String, "World")
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(field)
        showCategoryList()
        waitFor(element(AccessibilityID.noCategories))
    }
}
