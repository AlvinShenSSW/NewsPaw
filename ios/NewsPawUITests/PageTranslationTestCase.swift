import XCTest

/// Shared steps of the RD16 tests: the page translation fixture pages on
/// `pages.example.invalid`, saved as a web-page source, the translator
/// fixture's models, the Translate button, the status line and the debug
/// report's counts. The translator answers each text with "译[<language>]："
/// before it; no test reaches a real host.
@MainActor
class PageTranslationTestCase: BrowserTestCase {
    enum Pages {
        static let list = "https://pages.example.invalid/ja-list"
        static let listTitle = "日本語のニュース一覧"
        /// The source's name: the fixture transport's title for the list.
        static let source = "Japanese List"
        static let category = "Pages"

        static func item(_ number: Int) -> String {
            number % 10 == 0 ? "東京都議会選挙 \(number)" : "ニュース \(number)：新しい製品が発表されました"
        }
    }

    enum Line {
        static let translating = "Translating…"
        static let translated = "Translated to Simplified Chinese"
        static let nothing = "Nothing to translate on this page"
        static let noModel = "Set up a model to translate"
        static let refused = "Some text could not be translated · The model declined to translate this"
        static let limited = "Some text could not be translated · The service is limiting requests. Try again later"
        static let paused = "Some text could not be translated · Translation paused on this long page"
    }

    /// What the translator makes of `text`.
    static func translated(_ text: String) -> String {
        "译[zh-Hans]：" + text
    }

    /// Launches with the translator's models ("primary", "primary,backup"
    /// or none), the ceiling of a period when given, and `arguments`.
    func launchPages(models: String? = "primary", ceiling: Int? = nil, arguments: [String] = []) {
        app.terminate()
        let application = XCUIApplication()
        if let models {
            application.launchEnvironment[UITestLaunchKey.translationModels] = models
        }
        if let ceiling {
            application.launchEnvironment[UITestLaunchKey.pageTranslationCeiling] = String(ceiling)
        }
        launch(application, arguments: arguments)
        rotate(.portrait)
        requireFullWidth()
    }

    /// Saves the list page as a web-page source in its category and opens
    /// it.
    func openListSource() {
        createCategory(Pages.category)
        openAddSource()
        detect(Pages.list)
        waitFor(button(AccessibilityID.saveAsWebPageButton)).tap()
        chooseCategoryAndSave(Pages.category)
        openList()
    }

    /// Opens the saved list source.
    func openList() {
        expand(Pages.category)
        scrollTo(sourceRow(Pages.source)).tap()
        waitForAbsence(element(AccessibilityID.slideOverPanel))
        waitForPage(Pages.listTitle)
    }

    /// Follows the fixture navigation's link to `path` (without its slash)
    /// and waits for the page's title.
    func openFixture(_ path: String, title: String) {
        tapLink(path)
        waitForPage(title)
    }

    // MARK: - The page

    /// Text of the page, as the web view's accessibility exposes it.
    func webText(_ text: String) -> XCUIElement {
        app.webViews.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", text, text)).firstMatch
    }

    func waitForWebText(_ text: String, timeout: TimeInterval? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(webText(text).waitForExistence(timeout: timeout ?? self.timeout), "the page did not show \(text)", file: file, line: line)
    }

    // MARK: - Translate and its line

    var translateButton: XCUIElement {
        button(AccessibilityID.browserTranslateButton)
    }

    var line: XCUIElement {
        element(AccessibilityID.pageTranslationLine)
    }

    func tapTranslate() {
        waitFor(translateButton).tap()
    }

    /// Waits until the line reads `sentence`.
    func waitForLine(_ sentence: String, timeout: TimeInterval? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            self.line.exists && self.line.label == sentence
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: timeout ?? self.timeout), .completed,
                       "the line read \(self.line.exists ? self.line.label : "nothing"), not \(sentence)", file: file, line: line)
    }

    func lineAction(_ identifier: String) -> XCUIElement {
        button(identifier)
    }

    /// Whether Translate shows as on.
    func waitForTranslate(on: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let state = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", on ? "On" : "Off"), object: translateButton)
        XCTAssertEqual(XCTWaiter.wait(for: [state], timeout: timeout), .completed,
                       "Translate's value is \(String(describing: translateButton.value))", file: file, line: line)
    }

    // MARK: - The report

    var report: String {
        element(DebugAccessibilityID.adultReport).label
    }

    func count(_ name: String) -> Int {
        let report = self.report
        guard let range = report.range(of: name + "=") else { return -1 }
        return Int(report[range.upperBound...].prefix { $0.isNumber }) ?? -1
    }

    var translationRequests: Int {
        count("translationRequests")
    }

    var neverSent: Int {
        count("neverSent")
    }

    /// Waits until the translator fixture's count stops moving for a
    /// second, and returns it.
    func settledRequests() -> Int {
        var last = -2
        var stable = 0
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            let now = translationRequests
            stable = now == last ? stable + 1 : 0
            last = now
            if stable >= 4 {
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return last
    }

    /// Scrolls the page until `text` is on screen, between the bars.
    func scrollPage(to text: String, file: StaticString = #filePath, line: UInt = #line) {
        let page = app.webViews.firstMatch
        var swipes = 0
        while swipes < 40 {
            let element = webText(text)
            if element.exists, element.isHittable {
                return
            }
            page.swipeUp(velocity: .fast)
            swipes += 1
        }
        XCTFail("\(text) never came on screen", file: file, line: line)
    }
}
