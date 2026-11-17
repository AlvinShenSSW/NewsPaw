import XCTest

/// Shared steps of the RD21 tests: a launch that lets the first run show
/// (its launch key), the steps' controls, the model form on the
/// translator fixture, and the checks that nothing of the first run names
/// the adult partition.
@MainActor
class FirstRunTestCase: TranslationTestCase {
    /// Launches on this test's library with the first run allowed.
    func launchFirstRun(
        _ orientation: UIDeviceOrientation = .portrait, arguments: [String] = [], failNextSave: Bool = false,
        authentication: [String] = [], opmlFixture: String? = nil
    ) {
        app.terminate()
        let application = XCUIApplication()
        application.launchEnvironment[UITestLaunchKey.firstRun] = "1"
        if let opmlFixture {
            // "Import OPML" reads this fixture document (RD08 decision 8).
            application.launchEnvironment[UITestLaunchKey.opmlFixture] = opmlFixture
        }
        launch(application, failNextSave: failNextSave, arguments: arguments, authentication: authentication)
        rotate(orientation)
        requireFullSize()
    }

    // MARK: - The steps

    var firstRun: XCUIElement { element(AccessibilityID.firstRun) }
    var stepLine: XCUIElement { element(AccessibilityID.firstRunStep) }
    var skipButton: XCUIElement { button(AccessibilityID.firstRunSkip) }
    var stepBackButton: XCUIElement { button(AccessibilityID.firstRunBack) }
    var continueButton: XCUIElement { button(AccessibilityID.firstRunContinue) }
    var doneButton: XCUIElement { button(AccessibilityID.firstRunDone) }
    var addSourceButton: XCUIElement { button(AccessibilityID.firstRunAddSource) }
    var primaryModelRow: XCUIElement { element(AccessibilityID.firstRunPrimaryModel) }

    func categoryRow(_ group: String) -> XCUIElement {
        button(AccessibilityID.firstRunCategory(group))
    }

    /// Waits until the step line reads "Step `number` of 3".
    func waitForStep(_ number: Int, file: StaticString = #filePath, line: UInt = #line) {
        let shown = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@ OR label == %@", "Step \(number) of 3", "第 \(number) 步，共 3 步"), object: stepLine
        )
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: timeout), .completed,
                       "the step line is \(stepLine.exists ? stepLine.label : "absent")", file: file, line: line)
    }

    /// The shell's containers are not there: no tab bar, sidebar,
    /// slide-over button or partition switch.
    func assertNoContainers(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(app.tabBars.firstMatch.exists, "a tab bar is shown", file: file, line: line)
        XCTAssertFalse(element(AccessibilityID.sidebarPane).exists, "a sidebar is shown", file: file, line: line)
        XCTAssertFalse(button(AccessibilityID.showSidebarButton).exists, "the sidebar button is shown", file: file, line: line)
        XCTAssertFalse(element(AccessibilityID.partitionSwitch).exists, "the partition switch is shown", file: file, line: line)
    }

    /// The shell is shown on Today: its tab bar or its sidebar, and no
    /// first run.
    func waitForShellOnToday(file: StaticString = #filePath, line: UInt = #line) {
        waitFor(element(AccessibilityID.todayDate), file: file, line: line)
        XCTAssertFalse(firstRun.exists, "the first run is still shown", file: file, line: line)
        XCTAssertTrue(app.tabBars.firstMatch.exists || element(AccessibilityID.sidebarPane).exists
            || button(AccessibilityID.showSidebarButton).exists, "neither the tab bar nor the sidebar is shown", file: file, line: line)
    }

    /// No element on screen has a label naming the adult partition, in
    /// English or in Simplified Chinese.
    func assertNothingNamesTheAdultPartition(_ screen: String, file: StaticString = #filePath, line: UInt = #line) {
        let named = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'adult' OR label CONTAINS '成人'"))
            .allElementsBoundByIndex.map(\.label)
        XCTAssertEqual(named, [], "\(screen) names the adult partition", file: file, line: line)
        XCTAssertFalse(element(AccessibilityID.partitionSwitch).exists, "\(screen) shows the partition switch", file: file, line: line)
    }

    /// The debug report of RD18: whether the adult library's file exists.
    var adultReport: String {
        element(DebugAccessibilityID.adultReport).label
    }

    func waitForAdultFileAbsent(file: StaticString = #filePath, line: UInt = #line) {
        let reported = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            self.adultReport.contains("file=0")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reported], timeout: timeout), .completed, "the report is \(adultReport)", file: file, line: line)
    }

    /// The bottom bar's button of the step shown: Continue, or Done.
    var primaryButton: XCUIElement {
        doneButton.exists ? doneButton : continueButton
    }

    /// Scrolls the step's list until `element` lies wholly above the
    /// bottom bar and below the top bar, then returns it.
    @discardableResult
    func revealAboveTheBar(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        waitFor(element, file: file, line: line)
        var swipes = 0
        while swipes < 8 {
            let bar = primaryButton.frame.minY
            let top = app.navigationBars.firstMatch.frame.maxY
            let frame = element.frame
            if frame.maxY > bar - 4 {
                app.swipeUp(velocity: .slow)
            } else if frame.minY < top {
                app.swipeDown(velocity: .slow)
            } else {
                break
            }
            swipes += 1
        }
        XCTAssertLessThanOrEqual(element.frame.maxY, primaryButton.frame.minY, "\(element) is under the bottom bar", file: file, line: line)
        return element
    }

    /// Taps step 3's row of `group`, once it is clear of the bottom bar.
    func tick(_ group: String) {
        revealAboveTheBar(categoryRow(group)).tap()
    }

    /// Step 3's row of `group` is ticked (it carries the selected trait).
    func isTicked(_ group: String) -> Bool {
        waitFor(categoryRow(group)).isSelected
    }

    /// Waits until `element`'s frame is the same in two reads half a second
    /// apart (as RD08's tests do for its form sheet).
    func waitUntilStill(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        var last = element.frame
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            let now = element.frame
            if now == last {
                return
            }
            last = now
        }
        XCTFail("\(element) kept moving", file: file, line: line)
    }

    // MARK: - Add source from the first run or Today

    /// On Add source's confirm step: creates `category` inside the sheet
    /// and saves.
    func saveIntoNewCategory(_ category: String) {
        waitFor(button(AccessibilityID.categoryChoiceRow)).tap()
        waitFor(button(AccessibilityID.newCategoryInSheetButton)).tap()
        let field = waitFor(app.textFields[AccessibilityID.newCategoryNameField])
        field.tap()
        field.typeText(category + "\n")
        button(AccessibilityID.createCategoryButton).tap()
        let row = waitFor(button(AccessibilityID.categoryChoiceRow))
        XCTAssertTrue(row.label.contains(category), row.label)
        tapSave()
        waitForAbsence(button(AccessibilityID.saveButton))
    }
}

/// RD13's model form, unchanged, filled on the translator fixture: from the
/// first run's step 2 and from Settings (RD21 criteria 3 and 10).
extension TranslationTestCase {
    /// The translator fixture's host, which answers Test as well
    /// (`FixtureModelHTTP.Address.translate`).
    static let translatorAddress = "https://translate.models.example.invalid/v1"
    static let translatorModel = "fixture-translator"
    /// A bound a stalled runner does not reach; a wait returns as soon as
    /// its condition holds.
    static let longWait: TimeInterval = 60

    /// Scrolls the form until `element` can be tapped.
    @discardableResult
    func revealInForm(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        var swipes = 0
        while !(element.waitForExistence(timeout: 1) && element.isHittable), swipes < 16 {
            if swipes < 8 {
                app.swipeUp()
            } else {
                app.swipeDown()
            }
            swipes += 1
        }
        return waitFor(element, file: file, line: line)
    }

    /// Replaces a field's text with `text` and ends with Return.
    func typeIntoForm(_ identifier: String, _ text: String, secure: Bool = false) {
        let field = secure ? app.secureTextFields[identifier] : app.textFields[identifier]
        revealInForm(field)
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

    /// Fills the open form with the translator fixture (Custom service),
    /// runs Test until it passes and saves.
    func setUpTranslatorInForm() {
        waitFor(button(AccessibilityID.saveButton))
        revealInForm(app.buttons.matching(NSPredicate(format: "label == 'Custom'")).firstMatch).tap()
        typeIntoForm(AccessibilityID.modelAddressField, Self.translatorAddress)
        typeIntoForm(AccessibilityID.modelNameField, Self.translatorModel)
        typeIntoForm(AccessibilityID.keyField, "sk-fixture-first-run-0123", secure: true)
        let test = revealInForm(button(AccessibilityID.testButton))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: test)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: timeout), .completed, "Test stayed disabled")
        test.tap()
        let testLine = revealInForm(element(AccessibilityID.testLine))
        let passed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Passed'"), object: testLine)
        XCTAssertEqual(XCTWaiter.wait(for: [passed], timeout: Self.longWait), .completed, "Test line: \(testLine.label)")
        tapSave()
        waitForAbsence(button(AccessibilityID.saveButton))
    }

    /// Waits for `element`'s label to contain `text`, up to the long bound.
    func waitLong(for element: XCUIElement, containing text: String, file: StaticString = #filePath, line: UInt = #line) {
        let state = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in element.exists && element.label.contains(text) }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [state], timeout: Self.longWait), .completed,
                       "\(element.exists ? element.label : "absent") does not contain \(text)", file: file, line: line)
    }
}
