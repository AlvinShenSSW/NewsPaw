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

    /// F1: after the software keyboard has been used in portrait, panes
    /// created after rotating to landscape keep the whole height: each pane
    /// reaches the bottom of the window and its empty state is centred in
    /// the pane below its bar.
    func testPanesKeepTheirHeightAfterTypingAndRotating() throws {
        launch()
        rotate(.portrait)
        requireFullWidth()
        createCategory("World")
        button(AccessibilityID.closeSidebarButton).tap()
        waitForAbsence(element(AccessibilityID.slideOverPanel))
        rotate(.landscapeLeft)
        requireFullWidth()
        let destinations: [(row: String, emptyStates: [String])] = [
            (AccessibilityID.allUnreadRow, [AccessibilityID.allUnreadEmpty, AccessibilityID.noArticleSelected]),
            (AccessibilityID.categoryRow("World"), [AccessibilityID.categoryEmpty, AccessibilityID.noArticleSelected]),
            (AccessibilityID.starredRow, [AccessibilityID.starredEmpty, AccessibilityID.noArticleSelected]),
            (AccessibilityID.todayRow, [AccessibilityID.todayEmpty]),
        ]
        for destination in destinations {
            selectInSidebar(destination.row)
            for emptyState in destination.emptyStates {
                assertCentredInItsPane(emptyState)
            }
        }
        // Today's grouped background reaches every edge of its pane (the
        // white of an uncovered stack background shows otherwise).
        assertBackgroundFillsPane(AccessibilityID.fullPane)
        selectInSidebar(AccessibilityID.settingsRow)
        assertBackgroundFillsPane(AccessibilityID.fullPane)
        screenshot("after-typing-and-rotating")
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
        assertCentredInItsPane(AccessibilityID.todayEmpty)
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
        assertCentredInItsPane(AccessibilityID.allUnreadEmpty)
        assertCentredInItsPane(AccessibilityID.noArticleSelected)
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
                // F4: the title keeps the system's leading inset in every
                // pane, wherever the pane sits in the window.
                let title = bar.staticTexts[bar.identifier]
                if title.exists {
                    XCTAssertGreaterThanOrEqual(title.frame.minX, paneFrame.minX + 16,
                                                "\(pane)'s title \(title.frame) is not inset in its pane \(paneFrame)", file: file, line: line)
                }
            }
            // Every pane reaches the bottom of the window.
            XCTAssertEqual(paneFrame.maxY, window.maxY, accuracy: 1, "\(pane) \(paneFrame) does not reach the bottom", file: file, line: line)
        }
        for bar in app.navigationBars.allElementsBoundByIndex {
            let containing = frames.filter { bar.frame.minX >= $0.minX - 1 && bar.frame.maxX <= $0.maxX + 1 }
            XCTAssertEqual(containing.count, 1, "navigation bar \(bar.identifier) \(bar.frame) lies across panes", file: file, line: line)
        }
    }

    /// The empty state is centred vertically in its pane, below the pane's
    /// bar (the reading pane exposes no bar), within 30 pt; a pane that lost
    /// part of its height moves it up by half of what it lost.
    private func assertCentredInItsPane(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let state = waitFor(element(identifier), file: file, line: line).frame
        let panes = [AccessibilityID.fullPane, AccessibilityID.listPane, AccessibilityID.readingPane]
            .map { element($0) }
            .filter(\.exists)
            .map(\.frame)
        guard let pane = panes.first(where: { $0.minX <= state.midX && state.midX <= $0.maxX }) else {
            XCTFail("\(identifier) \(state) lies in no pane", file: file, line: line)
            return
        }
        XCTAssertEqual(pane.maxY, window.maxY, accuracy: 1, "the pane \(pane) does not reach the bottom", file: file, line: line)
        let top = navigationBars(in: pane).first?.frame.maxY ?? pane.minY
        XCTAssertEqual(state.midY, (top + pane.maxY) / 2, accuracy: 30,
                       "\(identifier) \(state) is not centred in \(pane) below \(top)", file: file, line: line)
    }

    /// The colour at the middle of each edge of the pane (2 px in) is the
    /// colour of the pane's background a quarter of the way in. Checking all
    /// four edges does not depend on how the screenshot is oriented.
    private func assertBackgroundFillsPane(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let image = waitFor(element(identifier), file: file, line: line).screenshot().image.cgImage else {
            XCTFail("no screenshot of \(identifier)", file: file, line: line)
            return
        }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            XCTFail("could not read the screenshot of \(identifier)", file: file, line: line)
            return
        }
        func colour(_ x: Int, _ y: Int) -> [Int] {
            let offset = (y * width + x) * 4
            return [Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2])]
        }
        let reference = colour(width / 4, height / 4)
        let edges = [(width / 2, 2), (width / 2, height - 3), (2, height / 2), (width - 3, height / 2)]
        for (x, y) in edges {
            let sample = colour(x, y)
            let difference = zip(sample, reference).map { abs($0 - $1) }.max() ?? 0
            XCTAssertLessThanOrEqual(difference, 6, "\(identifier): colour \(sample) at (\(x), \(y)) of \(width)×\(height) differs from the background \(reference)", file: file, line: line)
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
