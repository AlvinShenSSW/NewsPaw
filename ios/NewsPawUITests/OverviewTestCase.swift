import XCTest

/// Shared steps of the RD23 tests: launching with the translator fixture
/// (which also answers overview requests: a summary "概览[<language>]：N ·
/// <first title>", "[1] 要点：<title 1>", "[2] 要点：<title 2>" and a
/// highlight out of range), the parts of a category's overview card, and
/// the Overviews setting of Category Settings.
@MainActor
class OverviewTestCase: TranslationTestCase {
    enum Overview {
        static let writing = "Writing overview…"
        static let noModel = "Set up a model to get overviews"
        static let refused = "The model declined to write this overview"
        static let dailyLimit = "Today's automatic limit is reached. Write it manually, or raise the limit in Settings"
        static let note = "An overview rests on titles and excerpts only and is not verification."
        static let nothingNew = "Nothing new today"
        static let caughtUp = "All caught up"

        /// The fixture's summary for a request of `count` articles whose
        /// first title is `first`, in `language`.
        static func summary(_ count: Int, _ first: String, _ language: String = "zh-Hans") -> String {
            "概览[\(language)]：\(count) · \(first)"
        }

        static func highlight(_ title: String) -> String {
            "要点：" + title
        }

        static func footnote(_ count: Int) -> String {
            "Written by fixture-translator from the titles and excerpts of \(count) articles"
        }
    }

    /// Keeps a screenshot with every failure, and writes it to
    /// `NEWSPAW_FAILURE_DIR` when the runner sets it.
    nonisolated override func record(_ issue: XCTIssue) {
        var issue = issue
        let screenshot = MainActor.assumeIsolated { XCUIScreen.main.screenshot().pngRepresentation }
        let attachment = XCTAttachment(data: screenshot, uniformTypeIdentifier: "public.png")
        attachment.lifetime = .keepAlways
        issue.add(attachment)
        if let directory = ProcessInfo.processInfo.environment["NEWSPAW_FAILURE_DIR"] {
            let name = "\(Date().timeIntervalSince1970)-\(issue.sourceCodeContext.location?.lineNumber ?? 0).png"
            try? screenshot.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
        }
        super.record(issue)
    }

    /// Launches on this test's library with the translator fixture's
    /// models (none when `models` is `nil`), and as asked the daily
    /// automatic limit and the seeded earlier overviews.
    func launchOverviews(
        models: String? = "primary", limit: Int? = nil, seed: Bool = false, arguments: [String] = [],
        _ orientation: UIDeviceOrientation = .portrait
    ) {
        app.terminate()
        let application = XCUIApplication()
        if let models {
            application.launchEnvironment[UITestLaunchKey.translationModels] = models
        }
        if let limit {
            application.launchEnvironment[UITestLaunchKey.dailyAutomaticLimit] = String(limit)
        }
        if seed {
            application.launchEnvironment[UITestLaunchKey.seedOverviews] = "1"
        }
        launch(application, arguments: arguments)
        rotate(orientation)
        requireFullSize()
    }

    // MARK: - The card's parts

    func part(_ part: String, _ category: String) -> XCUIElement {
        element(AccessibilityID.overview(part, category))
    }

    func card(_ category: String) -> XCUIElement { part("card", category) }
    func summary(_ category: String) -> XCUIElement { part("summary", category) }
    func highlight(_ number: Int, _ category: String) -> XCUIElement {
        button(AccessibilityID.overviewHighlight(number, category))
    }

    /// Today's row or card header of the category.
    func todayRow(_ category: String) -> XCUIElement {
        element(AccessibilityID.todayCategoryRow(category))
    }

    /// Scrolls Today until `element` can be tapped.
    @discardableResult
    func revealOnToday(_ target: XCUIElement, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let today = app.scrollViews.containing(.any, identifier: AccessibilityID.todayDate).firstMatch
        var swipes = 0
        // At the largest text size Today is many screens long.
        while !(target.waitForExistence(timeout: 2) && target.isHittable), swipes < 30 {
            if swipes < 20 {
                today.swipeUp()
            } else {
                today.swipeDown()
            }
            swipes += 1
        }
        return waitFor(target, file: file, line: line)
    }

    /// Waits until the element's label contains `text`, a longer bound for
    /// what a model answer brings.
    func waitForText(_ target: XCUIElement, _ text: String, seconds: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line) {
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in target.exists && target.label.contains(text) }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: seconds), .completed,
                       "\(target.exists ? target.label : "absent") should contain \(text)", file: file, line: line)
    }

    /// Refreshes the list of `category`: a refresh run, at whose end the due
    /// categories of the whole library are written (adding a source
    /// stores its articles without a run). Then shows Today. (A pull on
    /// Today itself did not start a run on the iPad in portrait.)
    func refreshRun(in category: String) {
        openCategoryList(category)
        // The list's menu, not a pull: at the largest text size the card
        // fills the screen and a pull from a row may not reach.
        waitFor(button(AccessibilityID.listMenu)).tap()
        waitFor(app.buttons.matching(NSPredicate(format: "label IN %@", ["Refresh", "刷新"])).firstMatch).tap()
        showToday()
    }

    // MARK: - Category Settings › Overviews

    /// Opens the category's settings from its list and sets Overviews to
    /// `label` (Automatic, Manual or Off), then saves.
    func setOverviews(of category: String, to label: String) {
        openCategoryList(category)
        openListSettings(source: false)
        waitFor(app.textFields[AccessibilityID.nameField])
        let picker = scrollTo(button(AccessibilityID.overviewModePicker))
        picker.tap()
        waitFor(app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch).tap()
        let chosen = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            picker.exists && ((picker.value as? String)?.contains(label) == true || picker.label.contains(label))
        }, object: nil)
        _ = XCTWaiter.wait(for: [chosen], timeout: timeout)
        tapSave()
        waitForAbsence(app.textFields[AccessibilityID.nameField])
    }
}
