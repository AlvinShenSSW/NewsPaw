import XCTest

/// The measurable parts of criterion 10.
final class AccessibilityTests: NewsPawUITestCase {
    /// Bar buttons are the system's: iOS 26 draws them as a 36 pt glass
    /// shape (frame modifiers do not change it) and takes touches in a larger
    /// region. Their tap target is measured by tapping the edges of a
    /// 44 × 44 pt square centred on the control, along each axis where the
    /// drawn frame is smaller than 44 pt: every such tap must activate it.
    private func assertBarButtonTapTarget(
        _ element: XCUIElement, _ name: String,
        activated: @escaping () -> Bool, reset: () -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        waitFor(element, file: file, line: line)
        let frame = element.frame
        let half = 21.5
        var points: [CGVector] = []
        if frame.height < 44 {
            points += [CGVector(dx: frame.midX, dy: frame.midY - half), CGVector(dx: frame.midX, dy: frame.midY + half)]
        }
        if frame.width < 44 {
            points += [CGVector(dx: frame.midX - half, dy: frame.midY), CGVector(dx: frame.midX + half, dy: frame.midY)]
        }
        for point in points {
            app.coordinate(withNormalizedOffset: .zero).withOffset(point).tap()
            let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in activated() }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 5), .completed,
                           "\(name): a tap at \(point) (drawn frame \(frame)) did not activate it", file: file, line: line)
            reset()
        }
    }

    private func assertTapTarget(_ element: XCUIElement, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        waitFor(element, file: file, line: line)
        // Frames come back with floating-point noise (43.99999999999994).
        XCTAssertGreaterThanOrEqual(element.frame.width, 44 - 0.001, "\(name) width \(element.frame)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height, 44 - 0.001, "\(name) height \(element.frame)", file: file, line: line)
    }

    func testControlsHaveLabelsAndTapTargets() {
        launch()
        rotate(.portrait)
        requireFullWidth()
        let edit = button(AccessibilityID.editButton)
        func toggleEdit() -> Bool { edit.label == "Done" }
        func endEditing() {
            if edit.label == "Done" { edit.tap() }
        }
        if isPad {
            let show = button(AccessibilityID.showSidebarButton)
            XCTAssertEqual(waitFor(show).label, "Show Sidebar")
            let panel = element(AccessibilityID.slideOverPanel)
            let close = button(AccessibilityID.closeSidebarButton)
            assertBarButtonTapTarget(show, "Show Sidebar", activated: { panel.exists }, reset: {
                close.tap()
                waitForAbsence(panel)
            })
            show.tap()
            XCTAssertEqual(waitFor(close).label, "Close Sidebar")
            assertBarButtonTapTarget(close, "Close Sidebar", activated: { !panel.exists }, reset: {
                show.tap()
                waitFor(panel)
            })
            assertBarButtonTapTarget(edit, "Edit", activated: toggleEdit, reset: endEditing)
            assertDoneTapTarget(edit)
            assertTapTarget(button(AccessibilityID.newCategoryButton), "New Category")
            for row in [AccessibilityID.todayRow, AccessibilityID.allUnreadRow, AccessibilityID.starredRow, AccessibilityID.settingsRow] {
                XCTAssertGreaterThanOrEqual(element(row).frame.height, 44 - 0.001, row)
            }
        } else {
            app.tabBars.buttons["Library"].tap()
            let add = button(AccessibilityID.addMenu)
            XCTAssertEqual(waitFor(add).label, "Add")
            let newCategory = button(AccessibilityID.newCategoryButton)
            assertBarButtonTapTarget(add, "Add", activated: { newCategory.exists }, reset: {
                newCategory.tap()
                button(AccessibilityID.cancelButton).tap()
                waitForAbsence(app.textFields[AccessibilityID.nameField])
            })
            assertBarButtonTapTarget(edit, "Edit", activated: toggleEdit, reset: endEditing)
            assertDoneTapTarget(edit)
            assertTapTarget(element(AccessibilityID.allUnreadRow), "All Unread")
        }
        openNewCategory()
        let field = app.textFields[AccessibilityID.nameField]
        assertFieldTapTarget(field, "Name field")
        assertBarButtonTapTarget(button(AccessibilityID.cancelButton), "Cancel", activated: { !field.exists }, reset: {
            self.openNewCategory()
        })
        var saved = 0
        field.tap()
        field.typeText("Target 0\n")
        assertBarButtonTapTarget(button(AccessibilityID.saveButton), "Save", activated: { !field.exists }, reset: {
            saved += 1
            self.openNewCategory()
            field.tap()
            field.typeText("Target \(saved)\n")
        })
        let icons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'editor.icon.'")).allElementsBoundByIndex
        XCTAssertEqual(icons.count, 23)
        for icon in icons {
            assertTapTarget(icon, icon.identifier)
            let symbol = String(icon.identifier.dropFirst("editor.icon.".count))
            XCTAssertFalse(icon.label.isEmpty, symbol)
            XCTAssertNotEqual(icon.label, symbol, "the label describes the symbol rather than naming it")
        }
        // The selected icon is marked by more than colour: the selected trait
        // (and, drawn, a ring and a check mark).
        XCTAssertEqual(icons.filter(\.isSelected).map(\.identifier), [AccessibilityID.iconButton("folder")])
        button(AccessibilityID.iconButton("leaf")).tap()
        XCTAssertEqual(icons.filter(\.isSelected).map(\.identifier), [AccessibilityID.iconButton("leaf")])
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(field)

        // A category row, Category Settings' Delete control, the About row.
        showCategoryList()
        assertTapTarget(element(AccessibilityID.categoryRow("Target 0")), "category row")
        openCategorySettings("Target 0")
        assertFieldTapTarget(app.textFields[AccessibilityID.nameField], "Name field in Category Settings")
        assertTapTarget(button(AccessibilityID.deleteCategoryButton), "Delete Category")
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(field)
        if isPad {
            openSidebarIfNeeded()
            element(AccessibilityID.settingsRow).tap()
        } else {
            app.tabBars.buttons["Settings"].tap()
        }
        assertTapTarget(element(AccessibilityID.aboutRow), "About row")
    }

    /// A text field's tap target: its frame is at least 44 pt tall, and a
    /// tap just inside the top and just inside the bottom of that frame each
    /// gives it keyboard focus. The text itself is drawn 22 pt tall in the
    /// middle, so these taps land on the area around it.
    private func assertFieldTapTarget(_ field: XCUIElement, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let frame = waitFor(field, file: file, line: line).frame
        func focused() -> Bool { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true }
        func unfocus() {
            if focused() {
                field.typeText("\n")
            }
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !focused() }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed, "\(name) kept focus", file: file, line: line)
        }
        unfocus()
        assertTapTarget(field, name, file: file, line: line)
        for y in [frame.minY + 3, frame.maxY - 3] {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: y)).tap()
            let gained = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in focused() }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [gained], timeout: 5), .completed,
                           "\(name): a tap at y = \(y) (frame \(frame)) did not give it focus", file: file, line: line)
            unfocus()
        }
    }

    /// The Edit control in its Done state: a tap at each edge of a 44 pt
    /// square ends edit mode.
    private func assertDoneTapTarget(_ edit: XCUIElement) {
        edit.tap()
        XCTAssertEqual(edit.label, "Done")
        assertBarButtonTapTarget(edit, "Done", activated: { edit.label == "Edit" }, reset: { edit.tap() })
        if edit.label == "Done" {
            edit.tap()
        }
    }

    /// At the largest accessibility text size category rows grow and their
    /// text is not cut to one line.
    func testLargestTextSizeGrowsCategoryRows() {
        let name = "International politics and economics"
        launch()
        rotate(.portrait)
        requireFullWidth()
        createCategory(name)
        let defaultHeight = element(AccessibilityID.categoryRow(name)).frame.height

        app.terminate()
        launch(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        if app.tabBars.firstMatch.exists {
            app.tabBars.buttons.element(boundBy: 1).tap()
        } else {
            openSidebarIfNeeded()
        }
        let row = waitFor(element(AccessibilityID.categoryRow(name)))
        let text = app.staticTexts[name].firstMatch
        XCTAssertGreaterThan(row.frame.height, defaultHeight * 2, "the row grows")
        XCTAssertGreaterThan(text.frame.height, 2 * 40, "the name wraps onto several lines instead of being cut")
        XCTAssertLessThanOrEqual(text.frame.maxX, window.maxX + 0.5)
        screenshot("largest-text-size")
    }
}
