import XCTest

/// The measurable parts of criterion 10.
final class AccessibilityTests: NewsPawUITestCase {
    private func assertTapTarget(_ element: XCUIElement, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        waitFor(element, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.width, 44, "\(name) width \(element.frame)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height, 44, "\(name) height \(element.frame)", file: file, line: line)
    }

    func testControlsHaveLabelsAndTapTargets() {
        launch()
        rotate(.portrait)
        requireFullWidth()
        if isPad {
            let show = button(AccessibilityID.showSidebarButton)
            assertTapTarget(show, "Show Sidebar")
            XCTAssertEqual(show.label, "Show Sidebar")
            show.tap()
            let close = button(AccessibilityID.closeSidebarButton)
            assertTapTarget(close, "Close Sidebar")
            XCTAssertEqual(close.label, "Close Sidebar")
            assertTapTarget(button(AccessibilityID.editButton), "Edit")
            assertTapTarget(button(AccessibilityID.newCategoryButton), "New Category")
            for row in [AccessibilityID.todayRow, AccessibilityID.allUnreadRow, AccessibilityID.starredRow, AccessibilityID.settingsRow] {
                XCTAssertGreaterThanOrEqual(element(row).frame.height, 44, row)
            }
        } else {
            app.tabBars.buttons["Library"].tap()
            let add = button(AccessibilityID.addMenu)
            assertTapTarget(add, "Add")
            XCTAssertEqual(add.label, "Add")
            assertTapTarget(button(AccessibilityID.editButton), "Edit")
            XCTAssertGreaterThanOrEqual(element(AccessibilityID.allUnreadRow).frame.height, 44)
        }
        openNewCategory()
        assertTapTarget(button(AccessibilityID.saveButton), "Save")
        assertTapTarget(button(AccessibilityID.cancelButton), "Cancel")
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
