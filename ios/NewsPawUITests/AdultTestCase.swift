import XCTest

/// Shared steps of the RD18 tests: the stand-in authenticator's answers,
/// Settings › Adult Partition, the partition switch on either structure,
/// leaving and returning, and the debug element that reports whether the
/// adult library and its workspace are released. LocalAuthentication is
/// never called: under a UI-test library directory the app uses the
/// stand-in, which answers from the launch option.
@MainActor
class AdultTestCase: BrowserTestCase {
    enum Wording {
        static let stillLocked = "The adult partition is still locked."
        static let notTurnedOn = "The adult partition was not turned on."
        static let settingsNeedAuthentication = "Authentication is needed to open these settings."
        static let passcodeNeeded = "Set a device passcode to use the adult partition."
        static let turnOffQuestion = "Turn off the adult partition?"
        static let deleteQuestion = "Delete everything in the adult partition?"
        static let normal = "Partition: Normal"
        static let adult = "Partition: Adult"
    }

    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    // MARK: - The report (decision 4)

    /// `file=<0|1> pool=<open|closed> library=<held|released>
    /// workspace=<none|held|released> browser=<none|held|released>`:
    /// whether the adult library's file exists, whether connections are
    /// open on it, and whether the library object, the adult workspace and
    /// its browser model are gone from memory.
    var report: String {
        element(DebugAccessibilityID.adultReport).label
    }

    /// What every lock leaves at once, on every path (RD18 criterion 7 as
    /// built): the adult library's connections are closed, and the
    /// workspace object is gone, so no cycle of the app's own holds it.
    static let closed = "pool=closed"
    static let dropped = "workspace=released"
    /// How long that may take: the lock's own step, with the read or the
    /// write in flight.
    static let atOnce: TimeInterval = 10
    /// Asserts that the adult library object and the browser model object
    /// are gone from memory, on the panes; on the tab structure records
    /// what the report says instead. On the tab structure UIKit kept them
    /// after every lock that was measured, also after nothing but the
    /// adult Today screen had been shown (assumption A4), so there is no
    /// path there on which their release could be asserted.
    func expectObjectsReleased(within seconds: TimeInterval = AdultTestCase.atOnce, _ note: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        if usesTabs {
            Thread.sleep(forTimeInterval: 2)
            record("RD18 objects after a lock (\(note))", report)
        } else {
            waitForReport("library=released", "browser=released", seconds: seconds, file: file, line: line)
        }
    }

    /// Waits until the report holds every one of `parts`.
    func waitForReport(_ parts: String..., seconds: TimeInterval = AdultTestCase.atOnce,
                       file: StaticString = #filePath, line: UInt = #line) {
        let asked = Date()
        let reported = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            let report = self.report
            return parts.allSatisfy { report.contains($0) }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reported], timeout: seconds), .completed,
                       "the report is \"\(report)\", expected \(parts)", file: file, line: line)
        print("RD18 report \(parts) after \(String(format: "%.1f", Date().timeIntervalSince(asked))) s (line \(line))")
    }

    // MARK: - Settings

    /// Settings, at its root.
    func openSettings() {
        if app.tabBars.firstMatch.exists {
            app.tabBars.buttons.element(boundBy: 3).tap()
        } else {
            openSidebarIfNeeded()
            scrollTo(element(AccessibilityID.settingsRow)).tap()
            waitForAbsence(element(AccessibilityID.slideOverPanel))
        }
        // Back to the root from a screen pushed on it: a second tap on the
        // selected tab, or the back button of the pane.
        var backs = 0
        while !element(AccessibilityID.modelsRow).waitForExistence(timeout: 2), backs < 3 {
            if app.tabBars.firstMatch.exists {
                app.tabBars.buttons.element(boundBy: 3).tap()
            } else {
                goBack()
            }
            backs += 1
        }
        waitFor(element(AccessibilityID.modelsRow))
    }

    /// On the panes a screen pushed on the leading pane (a Settings
    /// screen) has the back button where the sidebar button is, so it is
    /// left first.
    override func openSidebarIfNeeded() {
        var backs = 0
        while !app.tabBars.firstMatch.exists, !element(AccessibilityID.sidebarPane).exists,
              !element(AccessibilityID.slideOverPanel).exists,
              !button(AccessibilityID.showSidebarButton).waitForExistence(timeout: 1), backs < 3 {
            goBack()
            backs += 1
        }
        super.openSidebarIfNeeded()
    }

    var adultRow: XCUIElement { element(AccessibilityID.adultPartitionRow) }
    var adultToggle: XCUIElement { app.switches[AccessibilityID.adultPartitionToggle] }
    var turnOffButton: XCUIElement { button(AccessibilityID.turnOffAdultButton) }

    /// Settings › Adult Partition: taps the row. What follows depends on
    /// the stand-in's next answer when the partition is on and locked.
    func tapAdultRow() {
        openSettings()
        waitFor(adultRow).tap()
    }

    /// Waits for Settings › Adult Partition's "on" contents by their first
    /// row: the adult slots inside the adult partition, the lock timing
    /// outside it. Turn Off, the last row, is below the fold on an iPhone
    /// once the adult rows are shown (and then not in the hierarchy).
    func waitForAdultSettings(file: StaticString = #filePath, line: UInt = #line) {
        let slots = element(AccessibilityID.adultPrimaryModelRow)
        let timing = element(AccessibilityID.lockTimingPicker)
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in slots.exists || timing.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: timeout), .completed, "Settings › Adult Partition is not shown", file: file, line: line)
    }

    /// Turns the partition on through Settings; the stand-in's next answer
    /// must be `passed`. Ends on the screen's "on" contents.
    func turnOnAdult() {
        tapAdultRow()
        flipOn()
        waitFor(turnOffButton)
    }

    /// Taps the switch of Settings › Adult Partition. It turns on only
    /// when the authentication passes, so nothing is waited for here.
    func flipOn() {
        waitFor(adultToggle).coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    /// A lock timing's row.
    func timing(_ label: String) -> XCUIElement {
        app.buttons[label].firstMatch
    }

    func chooseTiming(_ label: String) {
        let row = scrollTo(timing(label))
        row.tap()
        let chosen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [chosen], timeout: timeout), .completed, "\(label) was not selected")
    }

    // MARK: - The partition switch

    var partitionSwitch: XCUIElement { button(AccessibilityID.partitionSwitch) }
    var lockButton: XCUIElement { button(AccessibilityID.lockButton) }

    /// Makes the place of the switch visible: a root screen of Today on the
    /// tab structure (unless one of the three root screens shows it
    /// already), the sidebar on the panes.
    func revealSwitchPlace() {
        leaveBrowser()
        if app.tabBars.firstMatch.exists {
            if !partitionSwitch.exists {
                showToday()
            }
        } else {
            openSidebarIfNeeded()
        }
    }

    /// Whether the switch is offered where it would be.
    func switchIsOffered() -> Bool {
        revealSwitchPlace()
        return partitionSwitch.waitForExistence(timeout: 2)
    }

    /// The label of the switch: "Partition: Normal" or "Partition: Adult".
    func partitionLabel() -> String {
        revealSwitchPlace()
        return waitFor(partitionSwitch).label
    }

    /// Waits until the switch is offered and reads `label`. It checks in a
    /// plain loop, not in a waiter's predicate: a check navigates and waits
    /// (`switchIsOffered()`), and inside a predicate that made one
    /// evaluation so long under load that the waiter's time ran out with
    /// the label already right (#165). It checks once more at the deadline.
    func waitForPartition(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if switchIsOffered(), partitionSwitch.label == label {
                return
            }
            if Date() >= deadline {
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("the switch reads \(partitionSwitch.exists ? partitionSwitch.label : "nothing"), expected \(label)",
                file: file, line: line)
    }

    /// A choice of the switch's open menu, by its identifier or, where the
    /// menu does not carry it, by its English or Simplified Chinese name.
    func partitionChoice(adult: Bool) -> XCUIElement {
        let identifier = adult ? AccessibilityID.partitionAdultChoice : AccessibilityID.partitionNormalChoice
        let names = adult ? ["Adult", "成人"] : ["Normal", "普通"]
        return app.buttons.matching(NSPredicate(format: "identifier == %@ OR label IN %@", identifier, names)).firstMatch
    }

    /// Opens the switch's menu and taps Adult; what follows is the
    /// stand-in's next answer.
    func chooseAdult() {
        revealSwitchPlace()
        waitFor(partitionSwitch).tap()
        waitFor(partitionChoice(adult: true)).tap()
    }

    /// Chooses Adult with a passed answer and waits for the adult
    /// partition.
    func enterAdult() {
        chooseAdult()
        waitForPartition(Wording.adult)
    }

    func chooseNormal() {
        revealSwitchPlace()
        waitFor(partitionSwitch).tap()
        waitFor(partitionChoice(adult: false)).tap()
    }

    func tapLock() {
        revealSwitchPlace()
        waitFor(lockButton).tap()
    }

    // MARK: - Alerts

    /// Waits for the alert with `text` and answers it with `answer`.
    func answerAlert(_ text: String, with answer: String = "OK", file: StaticString = #filePath, line: UInt = #line) {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: timeout), "no alert; expected \(text)", file: file, line: line)
        XCTAssertTrue(alert.staticTexts[text].exists, "the alert says \(alert.staticTexts.allElementsBoundByIndex.map(\.label))", file: file, line: line)
        alert.buttons[answer].tap()
        waitForAbsence(alert.staticTexts[text], file: file, line: line)
    }

    // MARK: - Leaving

    /// Home, a pause, and back: the scene enters the background.
    func leaveAndReturn(seconds: TimeInterval = 2) {
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: seconds)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: timeout))
    }

    /// Control Centre over the app and away again: the scene is inactive
    /// and never in the background (measured, RD18 assumption A7).
    func showControlCentre() {
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.001))
            .press(forDuration: 0.05, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)))
    }

    func hideControlCentre() {
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)).tap()
    }

    // MARK: - Content

    /// Whether any element on screen names one of `names` in its label,
    /// value or identifier.
    func shownNames(of names: [String]) -> [String] {
        let format = names.map { _ in "label CONTAINS %@ OR value CONTAINS %@ OR identifier CONTAINS %@" }.joined(separator: " OR ")
        let arguments = names.flatMap { [$0, $0, $0] }
        let found = app.descendants(matching: .any).matching(NSPredicate(format: format, argumentArray: arguments))
        return found.allElementsBoundByIndex.prefix(5).map { "\($0.elementType.rawValue):\($0.identifier):\($0.label)" }
    }

    func assertNothingShown(of names: [String], on screen: String, file: StaticString = #filePath, line: UInt = #line) {
        let shown = shownNames(of: names)
        XCTAssertTrue(shown.isEmpty, "\(screen) shows \(shown)", file: file, line: line)
    }
}
