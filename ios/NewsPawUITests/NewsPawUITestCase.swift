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
    func launch(syntheticSources: Int? = nil, failNextSave: Bool = false, arguments: [String] = []) -> XCUIApplication {
        app = XCUIApplication()
        app.launchArguments = arguments
        app.launchEnvironment[UITestLaunchKey.libraryDirectory] = libraryName
        if let syntheticSources {
            app.launchEnvironment[UITestLaunchKey.syntheticSources] = String(syntheticSources)
        }
        if failNextSave {
            app.launchEnvironment[UITestLaunchKey.failNextSave] = "1"
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
            app.tabBars.buttons.element(boundBy: 1).tap()
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
            waitFor(element(AccessibilityID.slideOverPanel))
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

    func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
