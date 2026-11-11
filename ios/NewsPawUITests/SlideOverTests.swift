import XCTest

/// Criterion 2 below 1100 pt: the sidebar slides over from a button in the
/// leading pane's bar.
final class SlideOverTests: NewsPawUITestCase {
    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(isPad, "iPad structure")
    }

    /// Launches in portrait at full width, which is below 1100 pt on both
    /// iPads.
    private func launchBelow1100() {
        launch()
        rotate(.portrait)
        requireFullWidth()
        XCTAssertLessThan(window.width, 1100)
        XCTAssertGreaterThanOrEqual(window.width, 700)
    }

    private var panel: XCUIElement { element(AccessibilityID.slideOverPanel) }

    func testOpensSelectsAndCloses() throws {
        launchBelow1100()
        waitFor(button(AccessibilityID.showSidebarButton)).tap()
        waitFor(panel)
        let panelFrame = panel.frame
        XCTAssertEqual(panelFrame.minX, window.minX, accuracy: 1, "the panel sits at the leading edge")
        XCTAssertEqual(panelFrame.width, 320, accuracy: 1)
        XCTAssertFalse(element(AccessibilityID.sidebarPane).exists)
        XCTAssertFalse(element(AccessibilityID.todayEmpty).isHittable, "the content behind cannot be reached")
        screenshot("slide-over-open")

        element(AccessibilityID.starredRow).tap()
        waitForAbsence(panel)
        waitFor(element(AccessibilityID.starredEmpty))
        XCTAssertTrue(app.navigationBars["Starred"].exists)

        // The close button closes it too.
        button(AccessibilityID.showSidebarButton).tap()
        waitFor(panel)
        button(AccessibilityID.closeSidebarButton).tap()
        waitForAbsence(panel)
        XCTAssertTrue(app.navigationBars["Starred"].exists)
    }

    /// A tap outside the panel closes it without triggering the control
    /// underneath (here the About row of Settings).
    func testOutsideTapClosesWithoutTriggeringWhatIsBehind() throws {
        launchBelow1100()
        button(AccessibilityID.showSidebarButton).tap()
        waitFor(element(AccessibilityID.settingsRow)).tap()
        waitForAbsence(panel)
        let about = waitFor(element(AccessibilityID.aboutRow)).frame
        XCTAssertGreaterThan(about.maxX, window.minX + 420)

        button(AccessibilityID.showSidebarButton).tap()
        waitFor(panel)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: window.minX + 400, dy: about.midY))
            .tap()
        waitForAbsence(panel)
        XCTAssertFalse(element(AccessibilityID.versionValue).exists, "the About row behind was not triggered")
        XCTAssertTrue(app.navigationBars["Settings"].exists)
    }

    /// Rotating to a width where the sidebar is a pane while the slide-over
    /// is open ends in the pane form.
    func testRotatingWhileOpenEndsInThePaneForm() throws {
        launchBelow1100()
        button(AccessibilityID.showSidebarButton).tap()
        waitFor(panel)
        rotate(.landscapeLeft)
        XCTAssertGreaterThanOrEqual(window.width, 1100)
        waitForAbsence(panel)
        waitFor(element(AccessibilityID.sidebarPane))
        XCTAssertFalse(button(AccessibilityID.showSidebarButton).exists)
        rotate(.portrait)
        waitForAbsence(element(AccessibilityID.sidebarPane))
        XCTAssertFalse(panel.exists, "the slide-over does not reopen")
        waitFor(button(AccessibilityID.showSidebarButton))
    }

    /// In edit mode a tap on a row does not navigate or close the
    /// slide-over; only the reorder handle and the delete control act.
    func testRowTapInEditModeDoesNotNavigate() throws {
        launchBelow1100()
        createCategory("World")
        createCategory("Tech")
        openSidebarIfNeeded()
        let edit = waitFor(button(AccessibilityID.editButton))
        edit.tap()
        XCTAssertEqual(edit.label, "Done")
        element(AccessibilityID.categoryRow("World")).tap()
        element(AccessibilityID.starredRow).tap()
        XCTAssertTrue(panel.exists, "the slide-over stays open")
        edit.tap()
        XCTAssertEqual(edit.label, "Edit")
        button(AccessibilityID.closeSidebarButton).tap()
        waitForAbsence(panel)
        XCTAssertTrue(element(AccessibilityID.todayEmpty).exists, "the destination did not change")
    }

    /// New Category chosen in the slide-over closes it and opens the sheet
    /// from the root.
    func testNewCategoryFromTheSlideOver() throws {
        launchBelow1100()
        button(AccessibilityID.showSidebarButton).tap()
        waitFor(button(AccessibilityID.newCategoryButton)).tap()
        waitFor(app.textFields[AccessibilityID.nameField])
        XCTAssertFalse(panel.exists)
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(app.textFields[AccessibilityID.nameField])
    }
}
