import XCTest

/// Shared steps of the RD17 tests: launching with the usage seeding, the
/// translator fixture's model and a stored limit; Settings › Usage, its
/// period control, its rows and its limit picker. The seeding inserts, in
/// each library opened, five rows of `seed-<partition>`: two `titles`
/// rows now (100 / 20 tokens, and none), automatic; `body` 3 days ago
/// (300 / 50), `page` 20 days ago (1,000 / 200) and `overview` 40 days ago
/// (5,000 / 500), manual.
@MainActor
class UsageTestCase: AdultTestCase {
    enum Seed {
        static let normal = "seed-normal"
        static let adult = "seed-adult"
    }

    /// Launches on this test's library; with `seed`, the seeding runs on
    /// each library opened.
    func launchForUsage(
        seed: Bool = true, models: String? = nil, limit: Int? = nil, arguments: [String] = [], authentication: [String] = []
    ) {
        app.terminate()
        let application = XCUIApplication()
        if seed {
            application.launchEnvironment[UITestLaunchKey.seedUsage] = "1"
        }
        if let models {
            application.launchEnvironment[UITestLaunchKey.translationModels] = models
        }
        if let limit {
            application.launchEnvironment[UITestLaunchKey.dailyAutomaticLimit] = String(limit)
        }
        launch(application, arguments: arguments, authentication: authentication)
        rotate(.portrait)
        requireFullWidth()
        // The shell is drawn once the library is open: until then neither
        // the tab bar nor the sidebar is there to start from.
        let tabs = app.tabBars.firstMatch
        let sidebar = button(AccessibilityID.showSidebarButton)
        let pane = element(AccessibilityID.sidebarPane)
        let shell = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            tabs.exists || sidebar.exists || pane.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [shell], timeout: timeout), .completed, "the shell was not drawn")
    }

    /// Settings › Usage, from wherever the app is.
    func openUsage(file: StaticString = #filePath, line: UInt = #line) {
        openSettings()
        scrollTo(element(AccessibilityID.usageRow), file: file, line: line).tap()
        waitFor(element(AccessibilityID.usagePeriodPicker), file: file, line: line)
    }

    var periodPicker: XCUIElement {
        element(AccessibilityID.usagePeriodPicker)
    }

    /// Chooses a segment of the period control by its label.
    func choosePeriod(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let segment = waitFor(periodPicker, file: file, line: line).buttons[label]
        waitFor(segment, file: file, line: line).tap()
        let chosen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: segment)
        XCTAssertEqual(XCTWaiter.wait(for: [chosen], timeout: timeout), .completed, "\(label) was not chosen", file: file, line: line)
    }

    /// The row of one purpose of one model.
    func total(_ model: String, _ purpose: String) -> XCUIElement {
        element(AccessibilityID.usageTotal(model: model, purpose: purpose))
    }

    var todayLine: XCUIElement {
        element(AccessibilityID.usageToday)
    }

    /// A row of the limit picker, by its value as shown.
    func limitOption(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// Chooses a limit and waits until it is selected and stored, which
    /// the today line reports.
    func chooseLimit(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let option = scrollTo(limitOption(label), file: file, line: line)
        option.tap()
        let chosen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: option)
        XCTAssertEqual(XCTWaiter.wait(for: [chosen], timeout: timeout), .completed, "\(label) was not chosen", file: file, line: line)
        waitForLabel(todayLine, containing: " of \(label)", file: file, line: line)
    }

    /// Waits until the limit option `label` is selected.
    func waitForSelectedLimit(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let option = scrollTo(limitOption(label), file: file, line: line)
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: option)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: timeout), .completed, "\(label) is not selected", file: file, line: line)
    }

    /// The translator fixture's requests so far, from the debug report.
    var translationRequests: Int {
        let report = self.report
        guard let range = report.range(of: "translationRequests=") else { return -1 }
        return Int(report[range.upperBound...].prefix { $0.isNumber }) ?? -1
    }
}
