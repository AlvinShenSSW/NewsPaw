import XCTest

/// Criteria 4–7: categories in Library and the sidebar.
final class CategoryFlowTests: NewsPawUITestCase {
    /// Starts at the category list: the Library tab, or the sidebar.
    private func showCategoryList() {
        if app.tabBars.firstMatch.exists {
            app.tabBars.buttons["Library"].tap()
            waitFor(app.navigationBars["Library"])
        } else {
            openSidebarIfNeeded()
        }
    }

    private func launchAtFullWidth(syntheticSources: Int? = nil, failNextSave: Bool = false) {
        launch(syntheticSources: syntheticSources, failNextSave: failNextSave)
        rotate(.portrait)
        requireFullWidth()
    }

    private func setEditing(_ editing: Bool) {
        let edit = waitFor(button(AccessibilityID.editButton))
        if (edit.label == "Done") != editing {
            edit.tap()
        }
    }

    private func reorderHandle(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", "Reorder \(name)")).firstMatch
    }

    /// Edit mode: the delete control, then the row's Delete button.
    private func deleteInEditMode(_ name: String) {
        setEditing(true)
        // The control's element spans the row; its minus sits at the leading
        // edge.
        let remove = waitFor(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Remove, \(name)")).firstMatch)
        remove.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 22, dy: remove.frame.height / 2)).tap()
        waitFor(app.buttons["Delete"]).tap()
    }

    private func openCategorySettings(_ name: String) {
        showCategoryList()
        waitFor(element(AccessibilityID.categoryRow(name))).press(forDuration: 1.2)
        waitFor(app.buttons["Category Settings"]).tap()
        waitFor(app.textFields[AccessibilityID.nameField])
    }

    func testEmptyLibraryAndNewCategory() {
        launchAtFullWidth()
        showCategoryList()
        waitFor(element(AccessibilityID.noCategories))
        createCategory("World", icon: "globe")
        waitForAbsence(element(AccessibilityID.noCategories))
    }

    /// Create, rename, change the icon, reorder and delete; everything is
    /// still there after a relaunch.
    func testWalkThroughSurvivesRelaunch() {
        launchAtFullWidth()
        createCategory("World", icon: "globe")
        createCategory("Tech", icon: "cpu")
        createCategory("Japan")
        showCategoryList()
        XCTAssertEqual(categoryNamesShown(), ["World", "Tech", "Japan"])

        // Rename and change the icon in Category Settings.
        openCategorySettings("Tech")
        let field = app.textFields[AccessibilityID.nameField]
        XCTAssertEqual(field.value as? String, "Tech")
        XCTAssertTrue(button(AccessibilityID.iconButton("cpu")).isSelected)
        field.tap()
        field.clearAndType("Technology\n")
        button(AccessibilityID.iconButton("sparkles")).tap()
        XCTAssertTrue(button(AccessibilityID.iconButton("sparkles")).isSelected)
        XCTAssertFalse(button(AccessibilityID.iconButton("cpu")).isSelected)
        tapSave()
        waitForAbsence(field)
        showCategoryList()
        waitFor(element(AccessibilityID.categoryRow("Technology")))

        // Reorder: Japan to the top.
        setEditing(true)
        waitFor(reorderHandle("Japan")).press(forDuration: 0.8, thenDragTo: reorderHandle("World"))
        let reordered = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            self.categoryNamesShown() == ["Japan", "World", "Technology"]
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reordered], timeout: timeout), .completed, "order: \(categoryNamesShown())")

        // Delete World, which has no sources: a plain confirmation.
        deleteInEditMode("World")
        waitFor(app.staticTexts["Delete “World”?"])
        XCTAssertFalse(app.buttons["Delete Category and Sources"].exists)
        app.buttons["Delete Category"].tap()
        waitForAbsence(element(AccessibilityID.categoryRow("World")))
        setEditing(false)

        relaunch()
        rotate(.portrait)
        showCategoryList()
        waitFor(element(AccessibilityID.categoryRow("Japan")))
        XCTAssertEqual(categoryNamesShown(), ["Japan", "Technology"])
        openCategorySettings("Technology")
        XCTAssertTrue(button(AccessibilityID.iconButton("sparkles")).isSelected)
        button(AccessibilityID.cancelButton).tap()
    }

    /// Criterion 6: empty or over-long names cannot be saved; duplicates can.
    func testNameRules() {
        launchAtFullWidth()
        openNewCategory()
        let field = app.textFields[AccessibilityID.nameField]
        let save = button(AccessibilityID.saveButton)
        XCTAssertFalse(save.isEnabled, "empty")
        field.tap()
        field.typeText("   ")
        XCTAssertFalse(save.isEnabled, "white space only")
        field.clearAndType(String(repeating: "a", count: 101))
        waitFor(element(AccessibilityID.nameTooLongMessage))
        XCTAssertFalse(save.isEnabled, "101 characters")
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        waitForAbsence(element(AccessibilityID.nameTooLongMessage))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: timeout), .completed, "100 characters")
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(field)

        createCategory("Same")
        createCategory("Same")
        showCategoryList()
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == 'Same'")).count, 2, "duplicate names are allowed")
    }

    /// Criterion 5: a category with sources offers moving them to another
    /// category or deleting them; the only category offers deletion only.
    func testDeletionDialogs() {
        launchAtFullWidth()
        createCategory("Full")
        createCategory("Other")
        relaunch(syntheticSources: 2)
        rotate(.portrait)
        showCategoryList()

        deleteInEditMode("Full")
        waitFor(app.staticTexts["Delete “Full”?"])
        XCTAssertTrue(app.staticTexts["This category has 2 sources. Move them to another category, or delete them with it."].exists)
        XCTAssertTrue(app.buttons["Delete Category and Sources"].exists)
        app.buttons["Move Sources to “Other”"].tap()
        waitForAbsence(element(AccessibilityID.categoryRow("Full")))
        setEditing(false)

        // Other now holds the two sources and is the only category.
        deleteInEditMode("Other")
        waitFor(app.staticTexts["Delete “Other”?"])
        XCTAssertTrue(app.staticTexts["This category has 2 sources. There is no other category to move them to, so they are deleted with it."].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Move Sources'")).count, 0)
        app.buttons["Delete Category and Sources"].tap()
        waitFor(element(AccessibilityID.noCategories))
    }

    /// Criterion 5: deleting the category that is shown moves the selection
    /// to All Unread. In the tab structure the category list and a shown
    /// category are never on screen together, so this is an iPad test.
    func testDeletingTheShownCategoryMovesToAllUnread() throws {
        try XCTSkipUnless(isPad, "a shown category and the category list are on screen together only in panes")
        launchAtFullWidth()
        createCategory("World")
        openSidebarIfNeeded()
        element(AccessibilityID.categoryRow("World")).tap()
        waitForAbsence(element(AccessibilityID.slideOverPanel))
        waitFor(app.navigationBars["World"])
        waitFor(element(AccessibilityID.categoryEmpty))

        openCategorySettings("World")
        button(AccessibilityID.deleteCategoryButton).tap()
        // The dialog's button, not the sheet's own Delete Category button.
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Delete Category' AND identifier != %@", AccessibilityID.deleteCategoryButton)).firstMatch
        waitFor(confirm).tap()
        waitForAbsence(app.textFields[AccessibilityID.nameField])
        waitFor(app.navigationBars["All Unread"])
        XCTAssertTrue(element(AccessibilityID.allUnreadEmpty).exists)
    }

    /// Criterion 7: a create that cannot be saved shows the alert, leaves the
    /// sheet open with its text, and the list shows what is stored.
    func testFailedCreateKeepsTheSheetAndText() {
        launchAtFullWidth(failNextSave: true)
        openNewCategory()
        let field = app.textFields[AccessibilityID.nameField]
        field.tap()
        field.typeText("World")
        tapSave()
        let alert = waitFor(app.alerts["The change could not be saved."])
        alert.buttons["OK"].tap()
        waitForAbsence(alert)
        XCTAssertTrue(field.exists, "the sheet stays open")
        XCTAssertEqual(field.value as? String, "World")
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(field)
        showCategoryList()
        waitFor(element(AccessibilityID.noCategories))

        // The next save works.
        createCategory("World")
    }

    /// Criterion 7: a reorder that cannot be saved shows the alert and the
    /// list returns to the stored order.
    func testFailedReorderReloadsTheList() {
        launchAtFullWidth()
        createCategory("A")
        createCategory("B")
        app.terminate()
        launchAtFullWidth(failNextSave: true)
        showCategoryList()
        waitFor(element(AccessibilityID.categoryRow("B")))
        setEditing(true)
        waitFor(reorderHandle("B")).press(forDuration: 0.8, thenDragTo: reorderHandle("A"))
        let alert = waitFor(app.alerts["The change could not be saved."])
        alert.buttons["OK"].tap()
        waitForAbsence(alert)
        XCTAssertEqual(categoryNamesShown(), ["A", "B"], "the list shows the stored order")
    }

    /// Criterion 7 inside Category Settings: the alert is attached to the
    /// sheet, so the sheet stays open with its text.
    func testFailedRenameKeepsTheSheetOpen() {
        launchAtFullWidth()
        createCategory("World")
        app.terminate()
        launchAtFullWidth(failNextSave: true)
        openCategorySettings("World")
        let field = app.textFields[AccessibilityID.nameField]
        field.tap()
        field.clearAndType("Europe")
        tapSave()
        let alert = waitFor(app.alerts["The change could not be saved."])
        alert.buttons["OK"].tap()
        waitForAbsence(alert)
        XCTAssertEqual(field.value as? String, "Europe")
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(field)
        showCategoryList()
        waitFor(element(AccessibilityID.categoryRow("World")))
        XCTAssertFalse(element(AccessibilityID.categoryRow("Europe")).exists)
    }
}

extension XCUIElement {
    /// Replaces a text field's contents.
    func clearAndType(_ text: String) {
        let current = value as? String ?? ""
        tap()
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }
}
