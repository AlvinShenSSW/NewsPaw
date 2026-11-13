import XCTest

/// Shared launching, waiting and measuring for the UI tests. Each test uses
/// its own library directory inside the app's temporary directory, so tests
/// never see each other's categories or the simulator's real library.
@MainActor
class NewsPawUITestCase: XCTestCase {
    private(set) var app = XCUIApplication()
    private(set) var libraryName = ""
    let timeout: TimeInterval = 10

    override func setUp() async throws {
        continueAfterFailure = false
        libraryName = "uitest-\(UUID().uuidString)"
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() async throws {
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    /// Launches the app on this test's library.
    @discardableResult
    func launch(
        syntheticSources: Int? = nil, failNextSave: Bool = false, slowNextSave: Int? = nil, failNextSourceSave: Bool = false,
        clockOffsetDays: Int? = nil, arguments: [String] = []
    ) -> XCUIApplication {
        app = XCUIApplication()
        app.launchArguments = arguments
        app.launchEnvironment[UITestLaunchKey.libraryDirectory] = libraryName
        if let syntheticSources {
            app.launchEnvironment[UITestLaunchKey.syntheticSources] = String(syntheticSources)
        }
        if failNextSave {
            app.launchEnvironment[UITestLaunchKey.failNextSave] = "1"
        }
        if let slowNextSave {
            app.launchEnvironment[UITestLaunchKey.slowNextSave] = String(slowNextSave)
        }
        if failNextSourceSave {
            app.launchEnvironment[UITestLaunchKey.failNextSourceSave] = "1"
        }
        if let clockOffsetDays {
            app.launchEnvironment[UITestLaunchKey.clockOffsetDays] = String(clockOffsetDays)
        }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: timeout))
        return app
    }

    func relaunch(syntheticSources: Int? = nil) {
        app.terminate()
        launch(syntheticSources: syntheticSources)
    }

    // MARK: - Elements

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func button(_ identifier: String) -> XCUIElement {
        app.buttons.matching(identifier: identifier).firstMatch
    }

    @discardableResult
    func waitFor(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(element) did not appear", file: file, line: line)
        return element
    }

    func waitForAbsence(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: timeout), .completed, "\(element) did not disappear", file: file, line: line)
    }

    // MARK: - Window

    var window: CGRect {
        app.windows.firstMatch.frame
    }

    /// The screen in the current orientation, from SpringBoard.
    var screen: CGRect {
        XCUIApplication(bundleIdentifier: "com.apple.springboard").windows.firstMatch.frame
    }

    func rotate(_ orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        let landscape = orientation.isLandscape
        // Judged on the screen: a narrow window can stay taller than wide in
        // landscape.
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            let frame = self.screen
            return landscape ? frame.width > frame.height : frame.height > frame.width
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: timeout), .completed, "the screen did not rotate")
    }

    /// Drags the window's lower trailing corner by `dx` points (iPad
    /// windowing). Returns the new width.
    @discardableResult
    func resizeWindow(by dx: CGFloat) -> CGFloat {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let origin = springboard.coordinate(withNormalizedOffset: .zero)
        let frame = window
        let start = origin.withOffset(CGVector(dx: frame.maxX - 4, dy: frame.maxY - 4))
        let end = origin.withOffset(CGVector(dx: frame.maxX - 4 + dx, dy: frame.maxY - 4))
        start.press(forDuration: 0.6, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        return window.width
    }

    /// The simulator remembers window sizes between launches: grows the
    /// window to the full screen width and asserts that it got there before
    /// any structure is judged.
    func requireFullWidth(file: StaticString = #filePath, line: UInt = #line) {
        var attempts = 0
        while isPad, window.width < screen.width - 1, attempts < 8 {
            resizeWindow(by: 400)
            attempts += 1
        }
        XCTAssertEqual(window.width, screen.width, accuracy: 1, "the window is not full width", file: file, line: line)
    }

    // MARK: - Panes

    func frame(of identifier: String) -> CGRect {
        element(identifier).frame
    }

    /// The navigation bars whose frames lie horizontally inside `pane`.
    func navigationBars(in pane: CGRect) -> [XCUIElement] {
        app.navigationBars.allElementsBoundByIndex.filter { bar in
            bar.frame.minX >= pane.minX - 1 && bar.frame.maxX <= pane.maxX + 1
        }
    }

    // MARK: - Categories

    /// Opens New Category from wherever it is offered on this structure.
    func openNewCategory() {
        if app.tabBars.firstMatch.exists {
            showCategoryList()
            waitFor(button(AccessibilityID.addMenu)).tap()
            waitFor(button(AccessibilityID.newCategoryButton)).tap()
        } else {
            openSidebarIfNeeded()
            waitFor(button(AccessibilityID.newCategoryButton)).tap()
        }
        waitFor(app.textFields[AccessibilityID.nameField])
    }

    func createCategory(_ name: String, icon: String? = nil) {
        openNewCategory()
        let field = app.textFields[AccessibilityID.nameField]
        field.tap()
        // Return dismisses the keyboard, which would cover the icon grid.
        field.typeText(name + "\n")
        if let icon {
            button(AccessibilityID.iconButton(icon)).tap()
        }
        tapSave()
        waitForAbsence(field)
        if !app.tabBars.firstMatch.exists {
            openSidebarIfNeeded()
        }
        waitFor(element(AccessibilityID.categoryRow(name)))
    }

    /// Taps Save once SwiftUI has enabled it for the typed name.
    func tapSave(file: StaticString = #filePath, line: UInt = #line) {
        let save = waitFor(button(AccessibilityID.saveButton), file: file, line: line)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: timeout), .completed, "Save stayed disabled", file: file, line: line)
        save.tap()
    }

    /// Opens the slide-over when the sidebar is not a pane.
    func openSidebarIfNeeded() {
        if !element(AccessibilityID.sidebarPane).exists, !element(AccessibilityID.slideOverPanel).exists {
            waitFor(button(AccessibilityID.showSidebarButton)).tap()
            let panel = waitFor(element(AccessibilityID.slideOverPanel))
            // A tap while the panel still slides in can land on the dimmed
            // layer, which closes it (seen in RD09's runs).
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
                panel.frame.minX >= self.window.minX - 0.5
            }, object: nil)
            _ = XCTWaiter.wait(for: [settled], timeout: timeout)
        }
    }

    /// The category names in the order shown.
    func categoryNamesShown() -> [String] {
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.categoryRowPrefix))
            .allElementsBoundByIndex
        var seen: [(String, CGFloat)] = []
        for row in rows {
            let name = String(row.identifier.dropFirst(AccessibilityID.categoryRowPrefix.count))
            if !seen.contains(where: { $0.0 == name }) {
                seen.append((name, row.frame.minY))
            }
        }
        return seen.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// Starts at the category list: the Library tab, or the sidebar.
    func showCategoryList() {
        if app.tabBars.firstMatch.exists {
            // By position, so that it also works in Simplified Chinese.
            app.tabBars.buttons.element(boundBy: 1).tap()
            // A list pushed on the Library tab (RD09): a second tap on the
            // selected tab returns to its root.
            if !button(AccessibilityID.addMenu).waitForExistence(timeout: 3) {
                app.tabBars.buttons.element(boundBy: 1).tap()
            }
            waitFor(button(AccessibilityID.addMenu))
        } else {
            openSidebarIfNeeded()
        }
    }

    func launchAtFullWidth(
        _ orientation: UIDeviceOrientation = .portrait, syntheticSources: Int? = nil, failNextSave: Bool = false,
        slowNextSave: Int? = nil, failNextSourceSave: Bool = false
    ) {
        launch(syntheticSources: syntheticSources, failNextSave: failNextSave, slowNextSave: slowNextSave, failNextSourceSave: failNextSourceSave)
        rotate(orientation)
        requireFullWidth()
    }

    func setEditing(_ editing: Bool) {
        let edit = waitFor(button(AccessibilityID.editButton))
        if (edit.label == "Done") != editing {
            edit.tap()
        }
    }

    func reorderHandle(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", "Reorder \(name)")).firstMatch
    }

    /// Edit mode: the delete control, then the row's Delete button.
    func deleteInEditMode(_ name: String) {
        setEditing(true)
        // The control's element spans the row; its minus sits at the leading
        // edge.
        let remove = waitFor(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Remove, \(name)")).firstMatch)
        remove.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 22, dy: remove.frame.height / 2)).tap()
        waitFor(app.buttons["Delete"]).tap()
    }

    func openCategorySettings(_ name: String) {
        showCategoryList()
        waitFor(element(AccessibilityID.categoryRow(name))).press(forDuration: 1.2)
        waitFor(app.buttons["Category Settings"]).tap()
        waitFor(app.textFields[AccessibilityID.nameField])
    }

    /// Waits until the categories are shown in `names`' order.
    func waitForOrder(_ names: [String], file: StaticString = #filePath, line: UInt = #line) {
        let ordered = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            self.categoryNamesShown() == names
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ordered], timeout: timeout), .completed, "order: \(categoryNamesShown())", file: file, line: line)
    }

    /// A button of the deletion dialog (not a sheet's own button of the same
    /// name).
    func deletionDialogButton(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ AND NOT (identifier BEGINSWITH 'editor.')", label)).firstMatch
    }

    /// Taps far from a popover dialog, which closes it.
    func tapOutsideDialog() {
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: window.maxX - 30, dy: window.maxY - 30))
            .tap()
    }

    // MARK: - Sources

    /// Opens Add source from wherever it is offered on this structure.
    func openAddSource() {
        if app.tabBars.firstMatch.exists {
            showCategoryList()
            waitFor(button(AccessibilityID.addMenu)).tap()
            waitFor(button(AccessibilityID.addSourceButton)).tap()
        } else {
            openSidebarIfNeeded()
            waitFor(button(AccessibilityID.addSourceButton)).tap()
        }
        waitFor(app.textFields[AccessibilityID.addressField])
    }

    /// Types `address` into the address field and submits it.
    func detect(_ address: String) {
        let field = waitFor(app.textFields[AccessibilityID.addressField])
        // Back to the top of the step when an outcome was scrolled to; the
        // field is at the top, so the sheet is never swiped further.
        var swipes = 0
        while !field.isHittable, swipes < 3 {
            app.swipeDown()
            swipes += 1
        }
        // At the trailing end, so that the cursor follows the text and the
        // deletes below remove all of it.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        let current = field.value as? String ?? ""
        let placeholder = field.placeholderValue ?? ""
        let existing = current == placeholder ? 0 : current.count
        // Return submits the field, as Continue does. A tap on Continue right
        // after typing was sometimes not delivered on the iPad simulators.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing) + address + "\n")
    }

    /// On the confirm step: chooses `category` and saves; waits for the
    /// sheet to close.
    func chooseCategoryAndSave(_ category: String) {
        waitFor(button(AccessibilityID.categoryChoiceRow)).tap()
        waitFor(button(AccessibilityID.categoryChoice(category))).tap()
        waitForAbsence(button(AccessibilityID.categoryChoice(category)))
        tapSave()
        waitForAbsence(button(AccessibilityID.saveButton))
    }

    /// Adds `address` to `category` through the sheet, choosing the first
    /// candidate the sheet chose.
    func addSource(_ address: String, to category: String) {
        openAddSource()
        detect(address)
        waitFor(element(AccessibilityID.confirmAddress))
        chooseCategoryAndSave(category)
    }

    /// The back button of the frontmost navigation stack (inside a sheet,
    /// the sheet's).
    func goBack() {
        waitFor(app.buttons.matching(identifier: "BackButton").firstMatch).tap()
    }

    /// Scrolls the frontmost list up until `element` exists, a few times
    /// at most; rows below the fold are not in the hierarchy.
    @discardableResult
    func scrollTo(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        // In the slide-over the sidebar scrolls, not what is behind it.
        let panel = self.element(AccessibilityID.slideOverPanel)
        var swipes = 0
        // Each look waits a little, so that an outcome still being shown is
        // not scrolled past.
        while !(element.waitForExistence(timeout: 2) && element.isHittable), swipes < 5 {
            if panel.exists {
                panel.swipeUp()
            } else {
                app.swipeUp()
            }
            swipes += 1
        }
        return waitFor(element, file: file, line: line)
    }

    /// Flips a SwiftUI toggle: its element spans the row, and only the
    /// switch at its trailing end flips it.
    func flip(_ toggle: XCUIElement) {
        let before = toggle.value as? String
        waitFor(toggle).coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let flipped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in toggle.value as? String != before }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [flipped], timeout: timeout), .completed, "the toggle did not flip")
    }

    func sourceRow(_ name: String) -> XCUIElement {
        element(AccessibilityID.sourceRow(name))
    }

    /// Shows the category list with `category` expanded.
    func expand(_ category: String) {
        showCategoryList()
        let disclosure = scrollTo(button(AccessibilityID.disclosure(category)))
        if !isShown(disclosure) {
            disclosure.tap()
        }
    }

    func collapse(_ category: String) {
        showCategoryList()
        let disclosure = waitFor(button(AccessibilityID.disclosure(category)))
        if isShown(disclosure) {
            disclosure.tap()
        }
    }

    /// A disclosure control's value, in English or Simplified Chinese.
    private func isShown(_ disclosure: XCUIElement) -> Bool {
        ["Shown", "已展开"].contains(disclosure.value as? String ?? "")
    }

    /// Opens Source settings from the source's row: a web page's row opens
    /// them; a feed's row opens its article list, whose toolbar menu has
    /// Source Settings (RD09 criterion 19).
    func openSourceSettings(_ name: String, in category: String) {
        expand(category)
        waitFor(sourceRow(name)).tap()
        let field = app.textFields[AccessibilityID.nameField]
        let menu = button(AccessibilityID.listMenu)
        let either = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in field.exists || menu.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [either], timeout: timeout), .completed, "neither the settings nor the list opened")
        if !field.exists {
            openListSettings(source: true)
        }
        waitFor(field)
    }

    /// Opens Category Settings or Source Settings from the shown list's
    /// toolbar menu.
    func openListSettings(source: Bool) {
        waitFor(button(AccessibilityID.listMenu)).tap()
        let labels = source ? ["Source Settings", "来源设置"] : ["Category Settings", "分类设置"]
        waitFor(app.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch).tap()
    }

    // MARK: - Articles (RD09)

    func articleRow(_ title: String) -> XCUIElement {
        element(AccessibilityID.articleRow(title))
    }

    /// The article rows shown, top to bottom.
    func articleRowsShown() -> [XCUIElement] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.articleRowPrefix))
            .allElementsBoundByIndex
            .filter { $0.exists && !$0.frame.isEmpty }
            .sorted { $0.frame.minY < $1.frame.minY }
    }

    /// Whether a row's label says it is unread (its first part).
    func isUnread(_ row: XCUIElement) -> Bool {
        row.label.hasPrefix("Unread, ") || row.label.hasPrefix("未读, ")
    }

    func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
