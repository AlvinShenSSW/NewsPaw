import XCTest

/// Shared steps of the RD10 tests: a web-page source and the fixture pages
/// of the embedded browser, its bars, its menu and its alerts. Every page
/// comes from the debug fixture table; no test reaches a real host.
@MainActor
class BrowserTestCase: ArticleTestCase {
    enum Page {
        static let home = "Fixture Home"
        static let host = "nofeed.example.invalid"
        static let homeAddress = "https://nofeed.example.invalid/"
        static let secondAddress = "https://nofeed.example.invalid/second"
        static let missingAddress = "https://nofeed.example.invalid/missing"
        /// The web-page source's name, the fixture transport's title for
        /// its address.
        static let sourceName = "Plain Page"
    }

    enum Wording {
        static let question = "Open this link in another app?"
        static let noApp = "No app on this device can open this link."
        static let fileNotice = "This link is a file. NewsPaw does not download files."
    }

    // MARK: - Opening

    /// Adds the web-page source at the fixture home's address to `category`.
    func addWebPageSource(to category: String) {
        openAddSource()
        detect(Fixture.noFeed)
        waitFor(button(AccessibilityID.saveAsWebPageButton)).tap()
        chooseCategoryAndSave(category)
    }

    /// Taps the web-page source's row and waits for the fixture home.
    func openWebPageSource(in category: String) {
        expand(category)
        // Below the fold at the largest text size.
        scrollTo(sourceRow(Page.sourceName)).tap()
        waitForAbsence(element(AccessibilityID.slideOverPanel))
        waitForPage(Page.home)
    }

    // MARK: - The bars

    /// The title or the host, as the browser's navigation bar shows it.
    func barText(_ text: String) -> XCUIElement {
        app.navigationBars.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
    }

    /// Waits until the browser's title is `title`.
    func waitForPage(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            self.barText(title).exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: timeout), .completed,
                       "the browser did not show \(title): \(barTexts())", file: file, line: line)
    }

    func barTexts() -> [String] {
        app.navigationBars.staticTexts.allElementsBoundByIndex.map(\.label)
    }

    var backButton: XCUIElement { button(AccessibilityID.browserBackButton) }
    var forwardButton: XCUIElement { button(AccessibilityID.browserForwardButton) }
    var moreMenu: XCUIElement { button(AccessibilityID.browserMoreMenu) }

    func waitForEnabled(_ element: XCUIElement, _ enabled: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let state = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == %@", NSNumber(value: enabled)), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [state], timeout: timeout), .completed,
                       "\(element.identifier) should be \(enabled ? "enabled" : "disabled")", file: file, line: line)
    }

    /// Chooses `label` in the browser's More menu.
    func chooseInMore(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        waitFor(moreMenu, file: file, line: line).tap()
        waitFor(menuButton(label), file: file, line: line).tap()
    }

    /// Back to the article: the system back button (tabs) or Close (the
    /// reading pane).
    func closeBrowser() {
        if usesTabs {
            goBack()
        } else {
            waitFor(button(AccessibilityID.browserCloseButton)).tap()
        }
        waitForAbsence(moreMenu)
    }

    /// In the tab structure, back out of a pushed browser (and the article
    /// under it) until the tab bar shows again, so that the shared helpers,
    /// which read the structure from the tab bar, find it. Nothing on the
    /// panes.
    func leaveBrowser() {
        guard usesTabs else { return }
        // The tab bar comes back with the pop's animation.
        var backs = 0
        while !app.tabBars.firstMatch.waitForExistence(timeout: 3), backs < 3 {
            goBack()
            backs += 1
        }
        waitFor(app.tabBars.firstMatch)
    }

    // MARK: - Pages

    /// Taps a link of the shown page, scrolling the page until the link is
    /// between the bars: the page runs behind them, and a tap on a link
    /// under the floating bottom bar reaches the bar.
    func tapLink(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let link = waitFor(app.webViews.links[label], file: file, line: line)
        let page = app.webViews.firstMatch
        var swipes = 0
        while swipes < 8 {
            let top = app.navigationBars.allElementsBoundByIndex.map(\.frame.maxY).max() ?? window.minY
            let bottom = backButton.exists ? backButton.frame.minY - 8 : window.maxY
            let frame = link.frame
            if link.isHittable, frame.minY >= top, frame.maxY <= bottom {
                break
            }
            if frame.maxY > bottom {
                page.swipeUp(velocity: .slow)
            } else {
                page.swipeDown(velocity: .slow)
            }
            swipes += 1
        }
        link.tap()
    }

    // MARK: - Alerts

    func alert(_ title: String) -> XCUIElement {
        app.alerts.matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    func answer(_ title: String, _ button: String, file: StaticString = #filePath, line: UInt = #line) {
        let alert = waitFor(self.alert(title), file: file, line: line)
        waitFor(alert.buttons[button], file: file, line: line).tap()
        waitForAbsence(alert, file: file, line: line)
    }

    // MARK: - Add source's field

    /// Empties Add source's address field.
    func clearAddressField() {
        let field = waitFor(app.textFields[AccessibilityID.addressField])
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        let current = field.value as? String ?? ""
        let placeholder = field.placeholderValue ?? ""
        let existing = current == placeholder ? 0 : current.count
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing))
    }

    /// Pastes into Add source's field with its Paste button and waits for
    /// `expected`.
    func paste(expecting expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let paste = waitFor(button(AccessibilityID.pasteButton), file: file, line: line)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: paste)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: timeout), .completed, "the paste button stayed disabled", file: file, line: line)
        paste.tap()
        waitForValue(app.textFields[AccessibilityID.addressField], expected, file: file, line: line)
    }

    // MARK: - Window

    /// Resizes the window across 700 pt (iPad).
    func cross700(below: Bool, file: StaticString = #filePath, line: UInt = #line) {
        var attempts = 0
        while below ? window.width >= 700 : window.width < 700, attempts < 10 {
            resizeWindow(by: below ? -120 : 120)
            attempts += 1
        }
        XCTAssertEqual(window.width < 700, below, "the window could not be resized across 700 pt", file: file, line: line)
    }
}
