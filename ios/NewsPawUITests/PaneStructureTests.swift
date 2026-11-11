import XCTest

/// Criterion 2 on iPad: panes by window width, one bar per pane, pushes
/// staying in their pane.
final class PaneStructureTests: NewsPawUITestCase {
    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(isPad, "iPad structure")
    }

    func testPanesInPortrait() throws {
        launch()
        rotate(.portrait)
        requireFullWidth()
        try assertPaneStructure()
    }

    func testPanesInLandscape() throws {
        launch()
        rotate(.landscapeLeft)
        requireFullWidth()
        try assertPaneStructure()
    }

    /// Rotation re-establishes the layout from the new width.
    func testRotationReestablishesTheLayout() throws {
        launch()
        rotate(.portrait)
        requireFullWidth()
        try assertPaneStructure()
        rotate(.landscapeLeft)
        try assertPaneStructure()
        rotate(.portrait)
        try assertPaneStructure()
    }

    private func assertPaneStructure() throws {
        let width = window.width
        XCTAssertGreaterThanOrEqual(width, 700)
        let sidebarIsPane = width >= 1100
        XCTAssertFalse(app.tabBars.firstMatch.exists, "no tab bar from 700 pt")

        // Today: one pane over the whole width beside the sidebar.
        selectInSidebar(AccessibilityID.todayRow)
        let full = waitFor(element(AccessibilityID.fullPane)).frame
        let leading = window.minX + (sidebarIsPane ? 280 : 0)
        if sidebarIsPane {
            let sidebar = waitFor(element(AccessibilityID.sidebarPane)).frame
            XCTAssertEqual(sidebar.minX, window.minX, accuracy: 1)
            XCTAssertEqual(sidebar.width, 280, accuracy: 1)
            XCTAssertFalse(button(AccessibilityID.showSidebarButton).exists)
        } else {
            XCTAssertFalse(element(AccessibilityID.sidebarPane).exists)
            XCTAssertTrue(button(AccessibilityID.showSidebarButton).exists)
        }
        XCTAssertEqual(full.minX, leading, accuracy: 1.5)
        XCTAssertEqual(full.maxX, window.maxX, accuracy: 1)
        XCTAssertFalse(element(AccessibilityID.listPane).exists)
        XCTAssertTrue(element(AccessibilityID.todayEmpty).exists)
        assertOneBarPerPane(panes: sidebarIsPane ? [AccessibilityID.sidebarPane, AccessibilityID.fullPane] : [AccessibilityID.fullPane])
        screenshot("today-\(Int(width))")

        // All Unread: list pane and reading pane side by side, tiled.
        selectInSidebar(AccessibilityID.allUnreadRow)
        let list = waitFor(element(AccessibilityID.listPane)).frame
        let reading = waitFor(element(AccessibilityID.readingPane)).frame
        let listAndReading = width - (sidebarIsPane ? 280 : 0)
        XCTAssertEqual(list.width, listAndReading < 800 ? 300 : 340, accuracy: 1)
        XCTAssertEqual(list.minX, leading, accuracy: 1.5)
        XCTAssertLessThanOrEqual(list.maxX, reading.minX + 0.5, "the list pane must not overlap the reading pane")
        XCTAssertEqual(reading.maxX, window.maxX, accuracy: 1)
        XCTAssertTrue(element(AccessibilityID.allUnreadEmpty).exists)
        XCTAssertTrue(element(AccessibilityID.noArticleSelected).exists)
        XCTAssertFalse(element(AccessibilityID.fullPane).exists)
        assertOneBarPerPane(panes: (sidebarIsPane ? [AccessibilityID.sidebarPane] : []) + [AccessibilityID.listPane, AccessibilityID.readingPane])
        screenshot("all-unread-\(Int(width))")

        // Settings: one pane; a push to About stays in that pane.
        selectInSidebar(AccessibilityID.settingsRow)
        waitFor(element(AccessibilityID.fullPane))
        let sidebarBarBefore = sidebarIsPane ? navigationBars(in: frame(of: AccessibilityID.sidebarPane)).first?.identifier : nil
        waitFor(element(AccessibilityID.aboutRow)).tap()
        waitFor(element(AccessibilityID.versionValue))
        XCTAssertTrue(app.navigationBars["About"].exists)
        let settingsPane = frame(of: AccessibilityID.fullPane)
        XCTAssertEqual(app.navigationBars["About"].frame.minX, settingsPane.minX, accuracy: 1, "About is pushed in the Settings pane")
        if sidebarIsPane {
            XCTAssertEqual(navigationBars(in: frame(of: AccessibilityID.sidebarPane)).first?.identifier, sidebarBarBefore, "the sidebar pane is unchanged")
            XCTAssertTrue(element(AccessibilityID.todayRow).exists)
        } else {
            XCTAssertFalse(button(AccessibilityID.showSidebarButton).exists, "the back button takes the sidebar button's place")
        }
        app.navigationBars["About"].buttons.element(boundBy: 0).tap()
        waitForAbsence(element(AccessibilityID.versionValue))
        if !sidebarIsPane {
            waitFor(button(AccessibilityID.showSidebarButton))
        }
        screenshot("settings-\(Int(width))")
    }

    /// Each pane with a title holds exactly one navigation bar at its own
    /// top, and every bar on screen lies inside one pane, so no bar is
    /// shared. The reading pane's bar has no title and no item in this issue
    /// and is not exposed to accessibility, so it is checked only for not
    /// being crossed by another pane's bar.
    private func assertOneBarPerPane(panes: [String], file: StaticString = #filePath, line: UInt = #line) {
        let frames = panes.map { frame(of: $0) }
        for (pane, paneFrame) in zip(panes, frames) {
            let bars = navigationBars(in: paneFrame)
            let expected = pane == AccessibilityID.readingPane ? 0 : 1
            XCTAssertEqual(bars.count, expected, "\(pane) should have \(expected) exposed navigation bar(s), found \(bars.map(\.frame))", file: file, line: line)
            if let bar = bars.first {
                XCTAssertEqual(bar.frame.minX, paneFrame.minX, accuracy: 1, file: file, line: line)
                XCTAssertEqual(bar.frame.width, paneFrame.width, accuracy: 1, file: file, line: line)
            }
        }
        for bar in app.navigationBars.allElementsBoundByIndex {
            let containing = frames.filter { bar.frame.minX >= $0.minX - 1 && bar.frame.maxX <= $0.maxX + 1 }
            XCTAssertEqual(containing.count, 1, "navigation bar \(bar.identifier) \(bar.frame) lies across panes", file: file, line: line)
        }
    }

    /// Chooses a sidebar row, through the slide-over when the sidebar is not
    /// a pane.
    func selectInSidebar(_ row: String) {
        openSidebarIfNeeded()
        waitFor(element(row)).tap()
        waitForAbsence(element(AccessibilityID.slideOverPanel))
    }
}
