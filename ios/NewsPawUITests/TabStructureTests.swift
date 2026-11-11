import XCTest

/// Criterion 1, the tab structure below 700 pt on iPad (criterion 2), the
/// switch across 700 pt (criterion 3) and the destinations (criterion 8).
final class TabStructureTests: NewsPawUITestCase {
    private let tabNames = ["Today", "Library", "Starred", "Settings"]

    func testIPhoneTabBarInPortraitAndLandscape() throws {
        try XCTSkipIf(isPad, "iPhone structure")
        launch()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            rotate(orientation)
            assertBottomTabBar()
            XCTAssertFalse(element(AccessibilityID.sidebarPane).exists)
            XCTAssertFalse(element(AccessibilityID.listPane).exists)
            XCTAssertFalse(button(AccessibilityID.showSidebarButton).exists)
            screenshot("iphone-tabs-\(orientation.isLandscape ? "landscape" : "portrait")")
        }
    }

    func testIPhoneDestinationsAreRealAndEmpty() throws {
        try XCTSkipIf(isPad, "iPhone structure")
        launch()
        assertTabDestinations()
    }

    /// Below 700 pt an iPad window uses the tab structure with the bottom
    /// tab bar, and crossing 700 pt keeps the destination and an open
    /// category editor's text.
    func testIPadBelow700AndBackKeepsDestinationAndDraft() throws {
        try XCTSkipUnless(isPad, "iPad window resizing")
        launch()
        rotate(.landscapeLeft)
        requireFullWidth()

        // Panes: choose Starred, then open New Category and type.
        waitFor(element(AccessibilityID.starredRow)).tap()
        waitFor(element(AccessibilityID.starredEmpty))
        openNewCategory()
        let field = app.textFields[AccessibilityID.nameField]
        field.tap()
        // Return dismisses the keyboard, which covers the window's resize
        // corner; the text stays in the field.
        field.typeText("Draft\n")

        var attempts = 0
        while window.width >= 700, attempts < 10 {
            resizeWindow(by: -120)
            attempts += 1
        }
        XCTAssertLessThan(window.width, 700, "the window could not be made narrower than 700 pt")
        XCTAssertEqual(field.value as? String, "Draft", "the editor keeps its text across the switch")
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(field)
        assertBottomTabBar()
        XCTAssertTrue(app.tabBars.buttons["Starred"].isSelected, "the destination is kept")
        XCTAssertTrue(element(AccessibilityID.starredEmpty).exists)
        screenshot("ipad-below-700-\(Int(window.width))")
        assertTabDestinations()

        // Back across 700 pt with the editor open again. New Category is in
        // the Library tab, so the destination is now the Library root, which
        // the panes show as All Unread.
        openNewCategory()
        field.tap()
        field.typeText("Again\n")
        attempts = 0
        while window.width < 700, attempts < 10 {
            resizeWindow(by: 120)
            attempts += 1
        }
        XCTAssertGreaterThanOrEqual(window.width, 700)
        XCTAssertEqual(field.value as? String, "Again")
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(field)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        waitFor(element(AccessibilityID.listPane))
        XCTAssertTrue(element(AccessibilityID.allUnreadEmpty).exists, "the destination is kept")
        XCTAssertTrue(app.navigationBars["All Unread"].exists)
        requireFullWidth()
    }

    // MARK: - Helpers

    private func assertBottomTabBar(file: StaticString = #filePath, line: UInt = #line) {
        let bar = waitFor(app.tabBars.firstMatch, file: file, line: line)
        XCTAssertEqual(bar.buttons.allElementsBoundByIndex.map(\.label), tabNames, file: file, line: line)
        XCTAssertGreaterThan(bar.frame.midY, window.midY, "the tab bar is at the bottom", file: file, line: line)
    }

    /// Each tab is a real destination with a truthful empty state; Settings
    /// shows About with the version.
    private func assertTabDestinations() {
        let tabs = app.tabBars.firstMatch
        tabs.buttons["Today"].tap()
        waitFor(element(AccessibilityID.todayEmpty))
        tabs.buttons["Starred"].tap()
        waitFor(element(AccessibilityID.starredEmpty))
        tabs.buttons["Library"].tap()
        waitFor(element(AccessibilityID.noCategories))
        element(AccessibilityID.allUnreadRow).tap()
        waitFor(element(AccessibilityID.allUnreadEmpty))
        app.navigationBars["All Unread"].buttons.element(boundBy: 0).tap()
        waitFor(element(AccessibilityID.noCategories))
        tabs.buttons["Settings"].tap()
        waitFor(element(AccessibilityID.aboutRow)).tap()
        let version = waitFor(element(AccessibilityID.versionValue))
        XCTAssertTrue(version.label.range(of: #"^\d+\.\d+\.\d+ \(\d+\)$"#, options: .regularExpression) != nil, version.label)
        app.navigationBars["About"].buttons.element(boundBy: 0).tap()
        waitForAbsence(version)
    }
}
