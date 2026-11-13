import XCTest

/// RD09 criterion 16: the keyboard shortcuts, by `typeKey`, on the iPad
/// simulators.
///
/// It runs last on purpose (classes run in name order): `typeKey` attaches
/// a hardware keyboard to the simulator until the simulator restarts, and
/// with one attached every wait for the app to be idle after typing into a
/// text field lasts 60 seconds (measured on this branch and on main before
/// RD09, so it is the harness, not the app). Restart the iPad simulators
/// before running the suite again.
final class TypedKeyTests: ArticleTestCase {
    /// Each key does what decision 15 says; with a sheet open none does
    /// anything. iPad simulators, by `typeKey`.
    func testKeyboardShortcuts() throws {
        try XCTSkipUnless(isPad, "a hardware keyboard on iPad")
        launch()
        rotate(.landscapeLeft)
        requireFullWidth()
        createCategory("World")
        createCategory("Long")
        addSource(Fixture.articles, to: "World")
        addSource(Fixture.longCounting, to: "Long")
        openCategoryList("World")
        waitFor(articleRow("Image story"))
        let title = element(AccessibilityID.readingTitle)
        func press(_ key: String) {
            app.typeKey(key, modifierFlags: [])
        }
        func expectOpen(_ expected: String, _ note: String, file: StaticString = #filePath, line: UInt = #line) {
            let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: title)
            XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: timeout), .completed,
                           "\(note): \(title.exists ? title.label : "nothing open")", file: file, line: line)
        }
        // S and U with nothing open do nothing.
        press("s")
        press("u")
        sleep(1)
        XCTAssertFalse(title.exists)
        XCTAssertTrue(isUnread(articleRow("Image story")))
        XCTAssertFalse(articleRow("Image story").label.contains("Starred"))

        press("j")
        expectOpen("Image story", "J with nothing open opens the first row")
        waitForUnread(articleRow("Image story"), false)
        press("j")
        expectOpen("Plain story", "J")
        press("k")
        expectOpen("Image story", "K")
        press("k")
        sleep(1)
        expectOpen("Image story", "K at the first row does nothing")
        press("s")
        waitForLabel(button(AccessibilityID.readingStarButton), containing: "Unstar")
        waitForLabel(articleRow("Image story"), containing: ", Starred")
        press("u")
        waitForLabel(button(AccessibilityID.readingReadButton), containing: "Mark as Read")
        waitForUnread(articleRow("Image story"), true)
        press("u")
        waitForUnread(articleRow("Image story"), false)

        // The open article left the snapshot: J opens the first row.
        press("j")
        press("j")
        expectOpen("Linkless story", "J to the last row")
        press("j")
        sleep(1)
        expectOpen("Linkless story", "J at the last row with no further page")
        // All three are read now. Plain story is marked unread under All;
        // back under Unread the snapshot holds it alone.
        chooseFilter("All")
        swipeAction(on: articleRow("Plain story"), leading: true, "Mark as Unread")
        waitForUnread(articleRow("Plain story"), true)
        chooseFilter("Unread")
        waitForAbsence(articleRow("Linkless story"))
        expectOpen("Linkless story", "the open article stays open across a reload")
        press("j")
        expectOpen("Plain story", "J when the open article is no longer in the snapshot opens the first row")

        // With a sheet open no key does anything.
        openListSettings(source: false)
        let field = waitFor(app.textFields[AccessibilityID.nameField])
        for key in ["j", "k", "s", "u", "r"] {
            press(key)
        }
        sleep(1)
        XCTAssertEqual(field.value as? String, "World", "nothing was typed into the sheet")
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(field)
        expectOpen("Plain story", "no key acted while the sheet was open")
        XCTAssertFalse(articleRow("Plain story").label.contains("Starred"))

        // R refreshes the list: the long counting source brings a row.
        openCategoryList("Long")
        waitFor(articleRow("Long story 01"))
        let top = topRowTitle()
        press("r")
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            let now = self.topRowTitle()
            return now != nil && now != top
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: timeout), .completed, "R did not refresh the list")
    }
}
