import XCTest

/// Shared steps of the RD11 tests: the reading feed of the fixture
/// transport, the blocks of an open article, and the reading settings.
@MainActor
class ReadingTestCase: BrowserTestCase {
    enum Reading {
        static let feed = "https://reading.example.invalid/rss.xml"
        static let source = "Reading Feed"
        static let category = "World"
        /// The fixture's items, newest first: the list's order.
        static let titles = [
            "Every block", "Line heights", "Short note", "Hostile story", "Cut story", "Cut linkless story",
            "Picture story", "Hundred pictures", "Empty body",
        ]
    }

    static let largestText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    /// Launches at full size, in portrait on iPhone and as asked on iPad,
    /// with the reading feed in "World" and its source's list shown.
    func launchWithReadingFeed(_ orientation: UIDeviceOrientation = .portrait, arguments: [String] = [], pageSize: Int? = nil) {
        launchReading(orientation, arguments: arguments, pageSize: pageSize)
        createCategory(Reading.category)
        addSource(Reading.feed, to: Reading.category)
        openSourceList(Reading.source, in: Reading.category)
        waitFor(articleRow("Every block"))
    }

    /// Shows the reading feed's source list under All, so that an article
    /// read in an earlier launch is listed.
    func openReadingListUnderAll() {
        openCategoryList(Reading.category)
        chooseFilter("All")
    }

    /// Launches on this test's library, as it stands.
    func launchReading(_ orientation: UIDeviceOrientation = .portrait, arguments: [String] = [], pageSize: Int? = nil) {
        app.terminate()
        let application = XCUIApplication()
        if let pageSize {
            application.launchEnvironment[UITestLaunchKey.articlePageSize] = String(pageSize)
        }
        launch(application, arguments: arguments)
        rotate(orientation)
        requireFullSize()
    }

    /// The simulator remembers a window's size: full width and full height.
    func requireFullSize(file: StaticString = #filePath, line: UInt = #line) {
        requireFullWidth(file: file, line: line)
        var attempts = 0
        while isPad, window.height < screen.height - 1, attempts < 6 {
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let frame = window
            let start = springboard.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.maxX - 4, dy: frame.maxY - 4))
            start.press(forDuration: 0.6, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 300)), withVelocity: .slow, thenHoldForDuration: 0.3)
            attempts += 1
        }
        XCTAssertEqual(window.height, screen.height, accuracy: 1, "the window is not full height", file: file, line: line)
    }

    /// No pane at all: the tab structure. (While the list column is hidden
    /// only the reading pane is there.)
    override var usesTabs: Bool {
        super.usesTabs && !element(AccessibilityID.readingPane).exists
    }

    /// Scrolls the article list, in its own pane, until the row of `title`
    /// can be tapped: at the largest text size the later rows are below the
    /// fold, and a swipe on the window's middle scrolls the article.
    @discardableResult
    func scrollList(to title: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let row = articleRow(title)
        let pane = element(AccessibilityID.listPane)
        let area = pane.exists ? pane.frame : window
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: area.midX, dy: area.midY + 150))
        var drags = 0
        while !(row.waitForExistence(timeout: 1) && row.isHittable), drags < 30 {
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -350)), withVelocity: 800, thenHoldForDuration: 0.2)
            drags += 1
        }
        XCTAssertTrue(row.exists && row.isHittable, "the row \(title) was not reached", file: file, line: line)
        return row
    }

    // MARK: - The open article

    var readingTitle: XCUIElement { element(AccessibilityID.readingTitle) }

    /// The area the article is read in: the window, or the reading pane.
    var readingArea: CGRect {
        let pane = element(AccessibilityID.readingPane)
        return pane.exists ? pane.frame : window
    }

    func waitForTitle(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", title), object: readingTitle)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: timeout), .completed,
                       "the reading screen shows \(readingTitle.exists ? readingTitle.label : "nothing"), not \(title)", file: file, line: line)
    }

    /// The text block (paragraph, heading or code) whose label is `text`.
    func block(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", AccessibilityID.readingBlockPrefix, text
        )).firstMatch
    }

    /// The text block whose label contains `text`.
    func block(containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", AccessibilityID.readingBlockPrefix, text
        )).firstMatch
    }

    /// The text block at `index` of the body.
    func block(at index: Int) -> XCUIElement {
        element(AccessibilityID.readingBlock(index))
    }

    /// Scrolls the article up until `element` is in the hierarchy and can
    /// be tapped: a block below the fold is not laid out yet.
    @discardableResult
    func scrollArticle(to element: XCUIElement, swipes: Int = 20, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        var done = 0
        while !(element.exists && element.isHittable), done < swipes {
            dragArticle(by: -readingArea.height * 0.45)
            done += 1
        }
        XCTAssertTrue(element.exists && element.isHittable, "\(element) was not reached after \(done) drags", file: file, line: line)
        return element
    }

    /// Drags the article vertically by `distance` points, slowly enough not
    /// to coast.
    func dragArticle(by distance: CGFloat) {
        let area = readingArea
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: area.midX, dy: distance < 0 ? area.midY + 150 : area.midY - 150))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)), withVelocity: 600, thenHoldForDuration: 0.2)
    }

    /// Back at the top of the article.
    func scrollArticleToTop() {
        var done = 0
        while !(readingTitle.exists && readingTitle.isHittable), done < 30 {
            dragArticle(by: readingArea.height * 0.45)
            done += 1
        }
    }

    /// An item of the reading screen's open More menu. Not the hidden
    /// button of the keyboard shortcut with the same title ("Previous
    /// Article"), which is in the hierarchy without a frame or an
    /// identifier: a menu item carries its symbol's name.
    func moreItem(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != ''", label)).firstMatch
    }

    /// Closes the open More menu without choosing: a tap on the byline,
    /// which does nothing of its own. A tap on a bar's button would both
    /// close the menu and press the button (seen with Next Article).
    func dismissMoreMenu() {
        element(AccessibilityID.readingByline).tap()
    }

    // MARK: - Settings

    /// Shows a row of Settings' root: leaves a pushed reading screen first,
    /// then the Settings tab, or Settings in the sidebar.
    func openSettings(row identifier: String) {
        if usesTabs {
            if readingTitle.exists {
                goBack()
                waitForAbsence(readingTitle)
            }
            app.tabBars.buttons.element(boundBy: 3).tap()
            if !element(identifier).waitForExistence(timeout: 3) {
                app.tabBars.buttons.element(boundBy: 3).tap()
            }
        } else {
            openSidebarIfNeeded()
            scrollTo(element(AccessibilityID.settingsRow)).tap()
            waitForAbsence(element(AccessibilityID.slideOverPanel))
            if !element(identifier).waitForExistence(timeout: 3) {
                goBack()
            }
        }
        scrollTo(element(identifier)).tap()
    }

    // MARK: - Reading settings

    /// Opens "Aa".
    func openReadingSettings() {
        waitFor(button(AccessibilityID.readingSettingsButton)).tap()
        waitFor(button(AccessibilityID.textSizeLargerButton))
    }

    func closeReadingSettings() {
        waitFor(button(AccessibilityID.readingSettingsCloseButton)).tap()
        waitForAbsence(button(AccessibilityID.textSizeLargerButton))
    }

    /// A row of an inline picker, by its option's label.
    func option(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// Chooses an option of the reading settings, scrolling their own list
    /// to it: at the largest text size the options are below the fold, and
    /// a swipe outside the popover would close it.
    func chooseReadingOption(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let list = app.collectionViews.containing(.button, identifier: AccessibilityID.textSizeLargerButton).firstMatch
        let row = option(label)
        var swipes = 0
        while !(row.exists && row.isHittable), swipes < 8 {
            list.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(row.exists && row.isHittable, "\(label) was not reached", file: file, line: line)
        row.tap()
        let chosen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [chosen], timeout: timeout), .completed, "\(label) was not chosen", file: file, line: line)
    }

    /// The line pitch of the Latin text of "Line heights": the height of
    /// its three lines less the height of the same lines at two. A
    /// difference, because the frame the system reports for a text that
    /// can be selected is taller than the text by a constant (measured: 32
    /// pt at the default size).
    func latinPitch() -> CGFloat {
        let two = block(at: 0)
        let three = block(at: 1)
        guard two.exists, three.exists else { return -1 }
        return three.frame.height - two.frame.height
    }

    func waitForLatinPitch(_ expected: CGFloat, accuracy: CGFloat = 1, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let reached = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            abs(self.latinPitch() - expected) <= accuracy
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reached], timeout: timeout), .completed,
                       "\(what): the pitch is \(latinPitch()), not \(expected)", file: file, line: line)
    }

    /// A failure is photographed where the run names a directory: what was
    /// on screen says more than the line.
    override func record(_ issue: XCTIssue) {
        capture("failure-\(name.replacingOccurrences(of: " ", with: "-").filter { $0.isLetter || $0.isNumber || $0 == "-" })")
        super.record(issue)
    }

    /// Writes a screenshot to the directory the run names, as the other
    /// screenshot tests do; nothing otherwise.
    func capture(_ name: String) {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["NEWSPAW_SCREENSHOT_DIR"] else { return }
        let variant = environment["NEWSPAW_SCREENSHOT_VARIANT"] ?? "default"
        let device = (environment["SIMULATOR_DEVICE_NAME"] ?? "device").replacingOccurrences(of: " ", with: "-")
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(device)-\(variant)-reading-\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }
}
