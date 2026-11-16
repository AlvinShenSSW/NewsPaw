import XCTest

/// Shared steps of the RD12 tests: the fixture transport's full-text feed,
/// the lines under the reading screen's header, the edition number of the
/// fixture article, and the report's count of page requests.
@MainActor
class FullTextTestCase: ReadingTestCase {
    enum FullText {
        static let feed = "https://fulltext.example.invalid/rss.xml"
        static let source = "Full Text Feed"
        static let category = "World"
        static let articleTitle = "The ferry at dawn"
        static let listTitle = "Latest stories"
        static let host = "fulltext.example.invalid"
        static let noArticle = "This page has no readable article"
    }

    /// Launches at full size with the full-text feed in "World" and its
    /// source's list shown under All.
    func launchWithFullTextFeed(_ orientation: UIDeviceOrientation = .portrait, arguments: [String] = []) {
        launchReading(orientation, arguments: arguments)
        createCategory(FullText.category)
        addSource(FullText.feed, to: FullText.category)
        openSourceList(FullText.source, in: FullText.category)
        waitFor(articleRow("Fetched story"))
        // Opened articles stay listed.
        chooseFilter("All")
    }

    /// Scrolls the article list back up until the row of `title` can be
    /// tapped: `scrollList(to:)` only scrolls down.
    func scrollListUp(to title: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = articleRow(title)
        let pane = element(AccessibilityID.listPane)
        let area = pane.exists ? pane.frame : window
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: area.midX, dy: area.midY - 150))
        var drags = 0
        while !(row.waitForExistence(timeout: 1) && row.isHittable), drags < 30 {
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 350)), withVelocity: 800, thenHoldForDuration: 0.2)
            drags += 1
        }
        XCTAssertTrue(row.exists && row.isHittable, "the row \(title) was not reached", file: file, line: line)
    }

    var fullTextNote: XCUIElement { element(AccessibilityID.readingFullTextNote) }
    var loadingNote: XCUIElement { element(AccessibilityID.readingLoadingNote) }
    var excerptNote: XCUIElement { element(AccessibilityID.readingExcerptNote) }
    var readerButton: XCUIElement { button(AccessibilityID.browserReaderButton) }
    var readerTitle: XCUIElement { element(AccessibilityID.readerTitle) }

    // MARK: - The report

    /// The UI tests' report element, which carries `pages=<number>`.
    var report: String {
        element(DebugAccessibilityID.adultReport).label
    }

    /// How many requests for the full-text pages the fixture transport was
    /// asked for in this launch.
    var pagesRequested: Int {
        guard let match = report.firstMatch(of: /pages=(-?\d+)/) else { return -2 }
        return Int(match.1) ?? -2
    }

    /// Waits until the report counts `count` page requests, and a moment
    /// more, so that a request that would follow is seen.
    func expectPages(_ count: Int, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let reached = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            self.pagesRequested == count
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reached], timeout: timeout), .completed,
                       "\(what): \(pagesRequested) page requests, not \(count)", file: file, line: line)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(pagesRequested, count, "\(what): a further page request", file: file, line: line)
    }

    // MARK: - The article page

    /// The edition number in the text of the fixture article: a new one for
    /// every request of the page.
    func edition(file: StaticString = #filePath, line: UInt = #line) -> String {
        let paragraph = waitFor(block(containing: "Edition "), file: file, line: line)
        guard let match = paragraph.label.firstMatch(of: /Edition (\d+)/) else {
            XCTFail("no edition in \(paragraph.label)", file: file, line: line)
            return ""
        }
        return String(match.1)
    }

    /// Opens `title` and waits for its body to settle: the full text from
    /// its page, or the excerpt state.
    func openAndSettle(_ title: String, fullText: Bool, file: StaticString = #filePath, line: UInt = #line) {
        scrollList(to: title, file: file, line: line)
        openArticle(title)
        waitFor(fullText ? fullTextNote : excerptNote, file: file, line: line)
        XCTAssertFalse(loadingNote.exists, "the loading line stays", file: file, line: line)
        XCTAssertEqual(fullTextNote.exists, fullText, file: file, line: line)
    }

    /// From an open article, its page in the browser, through the bottom
    /// bar's "Open Original Page".
    func openOriginalPage(file: StaticString = #filePath, line: UInt = #line) {
        waitFor(button(AccessibilityID.readingOriginalBarButton), file: file, line: line).tap()
        waitForPage(FullText.articleTitle, file: file, line: line)
    }

    /// Reader Mode, then the temporary article.
    func openReaderMode(file: StaticString = #filePath, line: UInt = #line) {
        waitForEnabled(readerButton, true, file: file, line: line)
        readerButton.tap()
        waitFor(readerTitle, file: file, line: line)
    }

    /// Saves the source's settings as they are, from its list's menu.
    func saveSourceSettingsUnchanged() {
        openListSettings(source: true)
        tapSave()
        waitForAbsence(app.textFields[AccessibilityID.nameField])
    }

    /// Chooses `option` for the source's body and saves.
    func chooseBody(_ option: String) {
        openListSettings(source: true)
        waitFor(button(AccessibilityID.bodyModePicker)).tap()
        waitFor(app.buttons[option].firstMatch).tap()
        let chosen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", option), object: button(AccessibilityID.bodyModePicker))
        XCTAssertEqual(XCTWaiter.wait(for: [chosen], timeout: timeout), .completed, button(AccessibilityID.bodyModePicker).label)
        tapSave()
        waitForAbsence(app.textFields[AccessibilityID.nameField])
    }
}
