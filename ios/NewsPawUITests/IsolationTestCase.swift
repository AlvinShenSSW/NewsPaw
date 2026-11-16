import XCTest

/// Shared steps of the RD19 tests: Settings › Adult Partition with the
/// adult models, the thumbnails switch and Clear Browsing Data; the model
/// form (as `ModelSettingsTestCase` drives it); the `/storage` fixture page;
/// Settings › Data's size; moving a category. Every page, feed and model
/// answer comes from the debug fixtures; no test reaches a real host.
@MainActor
class IsolationTestCase: AdultTestCase {
    enum Isolation {
        /// The translator fixture's address and model (RD14).
        static let translateAddress = "https://translate.models.example.invalid/v1"
        static let translator = "fixture-translator"
        /// The key the normal library's fixture slot is saved with at launch.
        static let normalFixtureKey = "sk-fixture-translator-primary-0123"
        static let translationFeed = "https://translation.example.invalid/rss.xml"
        static let readingFeed = "https://reading.example.invalid/rss.xml"
        static let firstForeign = "Foreign story 01"
        static let elsewhere = "The adult partition's models, list thumbnails and daily limit are set inside the adult partition."
        static let clearQuestion = "Clear the adult partition's browsing data?"
        static let cleared = "Browsing data was cleared."
    }

    var zero: String {
        Int64(0).formatted(.byteCount(style: .file))
    }

    /// Keeps a screenshot with every failure, to see what the screen
    /// showed.
    nonisolated override func record(_ issue: XCTIssue) {
        var issue = issue
        let screenshot = MainActor.assumeIsolated { XCUIScreen.main.screenshot().pngRepresentation }
        let attachment = XCTAttachment(data: screenshot, uniformTypeIdentifier: "public.png")
        attachment.lifetime = .keepAlways
        issue.add(attachment)
        super.record(issue)
    }

    // MARK: - The debug report

    /// The translator fixture's requests so far, from the debug report.
    var translationRequests: Int {
        let report = self.report
        guard let range = report.range(of: "translationRequests=") else { return -1 }
        return Int(report[range.upperBound...].prefix { $0.isNumber }) ?? -1
    }

    // MARK: - Settings › Adult Partition

    /// Settings, at its root, also from a pushed article or page: on the
    /// tab structure they hide the tab bar.
    override func openSettings() {
        leaveBrowser()
        super.openSettings()
    }

    /// Settings › Adult Partition, from inside the adult partition (it
    /// opens without asking) or with the stand-in's next answer.
    func openAdultSettings() {
        tapAdultRow()
        waitFor(turnOffButton)
    }

    var adultPrimaryRow: XCUIElement { element(AccessibilityID.adultPrimaryModelRow) }
    var adultBackupRow: XCUIElement { element(AccessibilityID.adultBackupModelRow) }
    var thumbnailsToggle: XCUIElement { app.switches[AccessibilityID.showThumbnailsToggle] }
    var clearBrowsingButton: XCUIElement { button(AccessibilityID.clearBrowsingDataButton) }

    /// Clear Browsing Data, answered with Clear; waits for its footer.
    func clearBrowsingData() {
        scrollTo(clearBrowsingButton).tap()
        let alert = waitFor(app.alerts.firstMatch)
        XCTAssertTrue(alert.staticTexts[Isolation.clearQuestion].exists, alert.label)
        waitFor(button(AccessibilityID.confirmClearBrowsingDataButton)).tap()
        scrollTo(element(AccessibilityID.browsingDataCleared))
    }

    /// Sets "Show Thumbnails in Lists" on S10 to `on`.
    func setThumbnails(_ on: Bool) {
        let toggle = scrollTo(thumbnailsToggle)
        if (toggle.value as? String == "1") != on {
            flip(toggle)
        }
        XCTAssertEqual(toggle.value as? String, on ? "1" : "0")
    }

    // MARK: - The model form (as `ModelSettingsTestCase`)

    /// Scrolls the form until `element` is on screen and between the bars.
    @discardableResult
    func reveal(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        var swipes = 0
        while !(element.waitForExistence(timeout: 1) && element.isHittable), swipes < 16 {
            if swipes < 8 {
                app.swipeUp()
            } else {
                app.swipeDown()
            }
            swipes += 1
        }
        waitFor(element, file: file, line: line)
        let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : window.minY
        let bottom = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : window.maxY
        let centre = element.frame.midY
        if centre > bottom - 8 || centre < top + 8 {
            let distance = centre > bottom - 8 ? bottom - centre - 80 : top - centre + 80
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)), withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        return element
    }

    /// Replaces a text field's whole text with `text`, ending with Return.
    func replaceText(of identifier: String, with text: String, secure: Bool = false) {
        let field = secure ? app.secureTextFields[identifier] : app.textFields[identifier]
        reveal(field)
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        var taps = 0
        repeat {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
            taps += 1
        } while XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: focused, object: field)], timeout: 3) != .completed && taps < 3
        let current = field.value as? String ?? ""
        let placeholder = field.placeholderValue ?? ""
        let existing = current == placeholder || secure ? 0 : current.count
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing) + text + "\n")
    }

    /// Fills the open form with the custom preset, `address`, `model` and
    /// `key`.
    func fillForm(address: String, model: String, key: String) {
        reveal(app.buttons.matching(NSPredicate(format: "label == %@", "Custom")).firstMatch).tap()
        replaceText(of: AccessibilityID.modelAddressField, with: address)
        replaceText(of: AccessibilityID.modelNameField, with: model)
        replaceText(of: AccessibilityID.keyField, with: key, secure: true)
    }

    /// Taps Test once it is enabled and waits for its line to read
    /// `expected`.
    func runTest(expecting expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let test = reveal(button(AccessibilityID.testButton), file: file, line: line)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: test)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: timeout), .completed, "Test stayed disabled", file: file, line: line)
        test.tap()
        let label = reveal(element(AccessibilityID.testLine), file: file, line: line)
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: label)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: timeout), .completed,
                       "Test line: \(label.exists ? label.label : "none")", file: file, line: line)
    }

    /// A button of a question by its label, not one of the form's own.
    func dialogButton(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ AND NOT (identifier BEGINSWITH 'slot.') AND NOT (identifier BEGINSWITH 'editor.')", label)).firstMatch
    }

    // MARK: - The browser's storage page (criterion 6)

    /// Opens the article's original page and from it the `/storage` page,
    /// and returns the mark it reports ("adult", "normal", "none" or
    /// "unavailable").
    @discardableResult
    func openStoragePage(of article: String, in category: String) -> String {
        leaveBrowser()
        openCategoryList(category)
        // Read since its first opening: listed under All.
        chooseFilter("All")
        openArticle(article)
        waitFor(button(AccessibilityID.openOriginalButton)).tap()
        waitForPage("Original of \(article.lowercased().replacingOccurrences(of: " ", with: "-"))")
        tapLink("Storage page")
        return storageMark()
    }

    /// The mark the `/storage` page reports, once it has read it.
    func storageMark(file: StaticString = #filePath, line: UInt = #line) -> String {
        let read = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            self.barTexts().contains { $0.hasPrefix("Storage: ") }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [read], timeout: timeout), .completed, "the storage page did not report: \(barTexts())",
                       file: file, line: line)
        return barTexts().first { $0.hasPrefix("Storage: ") }.map { String($0.dropFirst("Storage: ".count)) } ?? ""
    }

    /// Taps one of the page's links that store a mark, and waits for it.
    func storeMark(adult: Bool, file: StaticString = #filePath, line: UInt = #line) {
        tapLink(adult ? "Store Adult Mark" : "Store Normal Mark", file: file, line: line)
        waitForPage("Storage: \(adult ? "adult" : "normal")", file: file, line: line)
    }

    // MARK: - Settings › Data

    /// Settings › Data of the partition shown, read afresh.
    func imageCacheSize() -> String {
        leaveBrowser()
        if usesTabs, !app.tabBars.firstMatch.exists {
            backToList()
        }
        openSettings()
        scrollTo(element(AccessibilityID.dataRow)).tap()
        let size = waitFor(element(AccessibilityID.cacheSize))
        let read = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "–"), object: size)
        _ = XCTWaiter.wait(for: [read], timeout: timeout)
        let label = size.label
        goBack()
        return label
    }

    /// Waits, reading Settings › Data again and again, until its size is
    /// zero (`zero`) or above zero.
    func waitForImageCache(zero expectZero: Bool, seconds: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(seconds)
        var size = imageCacheSize()
        while (size == zero) != expectZero, Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
            size = imageCacheSize()
        }
        XCTAssertEqual(size == zero, expectZero, "Settings › Data reads \(size)", file: file, line: line)
    }

    // MARK: - Moving

    /// The category's settings sheet: from its list's own menu (the row's
    /// context menu did not always open after the row was expanded).
    func openCategorySheet(_ name: String) {
        leaveBrowser()
        if usesTabs, !app.tabBars.firstMatch.exists {
            backToList()
        }
        openCategoryList(name)
        openListSettings(source: false)
        waitFor(app.textFields[AccessibilityID.nameField])
    }

    var moveButton: XCUIElement { button(AccessibilityID.moveCategoryButton) }

    /// Taps the sheet's move button once it is enabled.
    func tapMove(file: StaticString = #filePath, line: UInt = #line) {
        let move = scrollTo(moveButton, file: file, line: line)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: move)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: timeout), .completed, "the move button stayed disabled", file: file, line: line)
        move.tap()
    }

    /// The open alert, once it is there.
    func waitForAlert(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: timeout * 2), "no alert", file: file, line: line)
        return alert
    }

    /// The texts of the open alert, title and message.
    func alertTexts() -> [String] {
        app.alerts.firstMatch.staticTexts.allElementsBoundByIndex.map(\.label)
    }

    /// The category rows shown in the category list.
    func categoriesShown() -> [String] {
        leaveBrowser()
        if usesTabs, !app.tabBars.firstMatch.exists {
            backToList()
        }
        showCategoryList()
        _ = element(AccessibilityID.categoryRowPrefix).waitForExistence(timeout: 1)
        return categoryNamesShown()
    }

    /// Writes the screenshot to the test's result with a name the
    /// evidence keeps.
    func capture(_ name: String) {
        screenshot("rd19-\(name)")
    }
}
