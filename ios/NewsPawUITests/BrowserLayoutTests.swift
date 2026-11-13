import XCTest

/// RD10 criterion 12: the browser's bars on every simulator, at the
/// largest text size, and on iPad at a Split View width below 700 pt.
final class BrowserLayoutTests: BrowserTestCase {
    static let largestText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    /// The bars are present, their buttons have labels and a tap target of
    /// at least 44 × 44 pt, the title and the host are not clipped at the
    /// largest text size, and the end of a long page scrolls clear of the
    /// bottom bar. Bar buttons are the system's: iOS 26 draws them as 36 pt
    /// glass shapes with a larger touch region, so their target is measured
    /// as in RD03 and RD09, by tapping the edges of a 44 × 44 pt square
    /// centred on each.
    func testBarsAtTheLargestTextSize() {
        // Set up at the default size, where the shared helpers find the
        // sidebar's buttons without scrolling.
        launchAtFullWidth()
        createCategory("World")
        addWebPageSource(to: "World")
        app.terminate()
        launch(arguments: Self.largestText)
        rotate(.portrait)
        requireFullWidth()
        openWebPageSource(in: "World")
        checkBars(title: Page.home, "full width")

        tapLink("Long page")
        waitForPage("Long Page")
        checkBars(title: "Long Page", "the long page")
        assertTapTarget(backButton, "Back", activated: { self.barText(Page.home).exists }) {
            self.forwardButton.tap()
            self.waitForPage("Long Page")
        }
        backButton.tap()
        waitForPage(Page.home)
        assertTapTarget(forwardButton, "Forward", activated: { self.barText("Long Page").exists }) {
            self.backButton.tap()
            self.waitForPage(Page.home)
        }
        forwardButton.tap()
        waitForPage("Long Page")
        assertTapTarget(moreMenu, "More", activated: { self.menuButton("Reload").exists }) {
            // A tap on the page outside the menu closes it.
            self.app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
            self.waitForAbsence(self.menuButton("Reload"))
        }
        let end = app.webViews.staticTexts["End of the long page"]
        let barTop = [backButton, forwardButton, moreMenu].map(\.frame.minY).min() ?? window.maxY
        var swipes = 0
        while !(end.exists && end.isHittable && end.frame.maxY <= barTop), swipes < 40 {
            app.webViews.firstMatch.swipeUp(velocity: .fast)
            swipes += 1
        }
        // Past the end: the page rests where it ends.
        app.webViews.firstMatch.swipeUp(velocity: .fast)
        sleep(1)
        XCTAssertTrue(end.exists, "the end of the long page was not reached")
        XCTAssertLessThanOrEqual(end.frame.maxY, barTop + 0.5, "the end of the page stays under the bottom bar: \(end.frame), bar at \(barTop)")
        screenshot("long-page-end")

        if isPad {
            backButton.tap()
            waitForPage(Page.home)
            cross700(below: true)
            waitForPage(Page.home)
            checkBars(title: Page.home, "Split View below 700 pt")
            cross700(below: false)
        }
    }

    private func checkBars(title: String, _ note: String, file: StaticString = #filePath, line: UInt = #line) {
        for control in [backButton, forwardButton, moreMenu] {
            waitFor(control, file: file, line: line)
            XCTAssertFalse(control.label.isEmpty, "\(note): \(control.identifier) has no label", file: file, line: line)
            XCTAssertTrue(control.isHittable, "\(note): \(control.identifier) is not shown", file: file, line: line)
        }
        XCTAssertEqual(backButton.label, "Back", file: file, line: line)
        XCTAssertEqual(forwardButton.label, "Forward", file: file, line: line)
        XCTAssertEqual(moreMenu.label, "More", file: file, line: line)
        let titleText = waitFor(barText(title), file: file, line: line)
        let hostText = waitFor(barText(Page.host), file: file, line: line)
        guard let bar = app.navigationBars.allElementsBoundByIndex.first(where: { $0.frame.contains(hostText.frame.insetBy(dx: 1, dy: 1)) }) else {
            XCTFail("\(note): the host \(hostText.frame) is not inside a navigation bar", file: file, line: line)
            return
        }
        for text in [titleText, hostText] {
            XCTAssertFalse(text.frame.isEmpty, "\(note): \(text.label) has no size", file: file, line: line)
            XCTAssertTrue(bar.frame.insetBy(dx: -1, dy: -1).contains(text.frame), "\(note): \(text.label) \(text.frame) is clipped by the bar \(bar.frame)", file: file, line: line)
        }
        XCTAssertGreaterThanOrEqual(hostText.frame.minY, titleText.frame.maxY - 1, "\(note): the host is under the title", file: file, line: line)
        XCTAssertTrue(hostText.isHittable, "\(note): the host is shown", file: file, line: line)
    }

    /// Taps the edges of a 44 × 44 pt square centred on `control`, along
    /// each axis where its drawn frame is smaller; every tap must activate
    /// it.
    private func assertTapTarget(
        _ control: XCUIElement, _ name: String, activated: @escaping () -> Bool, reset: () -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let frame = waitFor(control, file: file, line: line).frame
        let half = 21.5
        var points: [CGVector] = []
        if frame.height < 44 {
            points += [CGVector(dx: frame.midX, dy: frame.midY - half), CGVector(dx: frame.midX, dy: frame.midY + half)]
        }
        if frame.width < 44 {
            points += [CGVector(dx: frame.midX - half, dy: frame.midY), CGVector(dx: frame.midX + half, dy: frame.midY)]
        }
        record("tap-target-\(name)", "drawn frame \(frame); edge taps \(points.count)")
        for point in points {
            app.coordinate(withNormalizedOffset: .zero).withOffset(point).tap()
            let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in activated() }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 5), .completed,
                           "\(name): a tap at \(point) (drawn \(frame)) did not activate it", file: file, line: line)
            reset()
        }
    }
}
