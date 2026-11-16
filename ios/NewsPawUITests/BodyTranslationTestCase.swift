import XCTest

/// Shared steps of the RD15 tests: the fixture transport's body feed, the
/// translator fixture's models, the progress line, the banner, the bar's
/// control and the report's count of body requests. The translator answers
/// each text with "译[<language asked for>]：" before it.
@MainActor
class BodyTranslationTestCase: TranslationTestCase {
    enum Body {
        static let feed = "https://bodies.example.invalid/rss.xml"
        static let source = "Body Feed"
        static let category = "Bodies"
        /// 16 paragraphs, eight chunks; chunk 4 stalls once.
        static let long = "Long story"
        /// The same, with paragraph 3 (chunk 2) refused.
        static let refused = "Refused paragraph story"
        /// Six paragraphs; paragraph 3 (chunk 2) answers 503 once.
        static let flaky = "Flaky story"
        /// Four paragraphs; the primary refuses paragraph 1, the backup
        /// translates it.
        static let primaryRefuses = "Primary refuses story"
        static let markup = "Markup story"
        static let markupParagraph = "Read **this in bold**, <a href=\"https://example.invalid/link\">an HTML link</a>, "
            + "[a Markdown link](https://example.invalid/markdown) and javascript:alert(1) here."
        /// 40 short paragraphs.
        static let many = "Many paragraphs story"
        static let chinese = "海港议会讨论新的渡轮时刻表"
        static let short = "Short note"

        /// The start of paragraph `number` (1-based) of `story`.
        static func paragraph(_ number: Int, of story: String) -> String {
            "\(story), paragraph \(number)."
        }
    }

    enum BodySentence {
        static let refused = "Some text could not be translated · The model declined to translate this"
        static let unreachable = "Some text could not be translated · Could not reach the service"
        static let noModel = "Set up a model to translate"
    }

    // MARK: - Launching

    /// Launches with the translator's models and the body feed in its
    /// category, its list shown under All.
    func launchWithBodies(models: String = "primary", arguments: [String] = [], _ orientation: UIDeviceOrientation = .portrait) {
        launchTranslating(models: models, arguments: arguments, orientation)
        addFeed(Body.feed, to: Body.category)
        waitFor(articleRow(Body.long))
    }

    // MARK: - The report

    var report: String {
        element(DebugAccessibilityID.adultReport).label
    }

    /// The usage rows of body requests in the normal library.
    var bodyRequests: Int {
        guard let match = report.firstMatch(of: /bodyRequests=(-?\d+)/) else { return -2 }
        return Int(match.1) ?? -2
    }

    /// The requests the translator fixture has answered in this launch.
    var translatorRequests: Int {
        guard let match = report.firstMatch(of: /translationRequests=(-?\d+)/) else { return -2 }
        return Int(match.1) ?? -2
    }

    /// Waits until the report counts `count` body requests, then a moment
    /// more, so that a further request is seen.
    func expectBodyRequests(_ count: Int, _ what: String, settle: TimeInterval = 1.5, file: StaticString = #filePath, line: UInt = #line) {
        let reached = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            self.bodyRequests == count
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reached], timeout: 60), .completed,
                       "\(what): \(bodyRequests) body requests, not \(count)", file: file, line: line)
        Thread.sleep(forTimeInterval: settle)
        XCTAssertEqual(bodyRequests, count, "\(what): a further body request", file: file, line: line)
    }

    // MARK: - The screen

    var progressLine: XCUIElement { element(AccessibilityID.bodyProgress) }
    var banner: XCUIElement { element(AccessibilityID.bodyBanner) }
    var translateButton: XCUIElement { button(AccessibilityID.translateButton) }
    var modeMenu: XCUIElement { button(AccessibilityID.displayModeMenu) }

    /// Waits until the progress line reads `text`.
    func waitForProgress(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            self.progressLine.exists && self.progressLine.label == text
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 60), .completed,
                       "the progress line reads \(progressLine.exists ? progressLine.label : "nothing"), not \(text)", file: file, line: line)
    }

    /// The banner's sentence: the label of its static text.
    func waitForBanner(_ sentence: String, file: StaticString = #filePath, line: UInt = #line) {
        let text = banner.staticTexts.matching(NSPredicate(format: "label == %@", sentence)).firstMatch
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in text.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 60), .completed,
                       "the banner says \(banner.exists ? banner.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ") : "nothing"), not \(sentence)",
                       file: file, line: line)
    }

    /// The labels of the banner's buttons.
    func bannerSteps() -> Set<String> {
        Set(banner.buttons.allElementsBoundByIndex.map(\.label))
    }

    /// Waits until block `index` reads `text`.
    func waitForBlock(_ index: Int, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let target = block(at: index)
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in target.exists && target.label == text }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 60), .completed,
                       "block \(index) reads \(target.exists ? target.label : "nothing"), not \(text)", file: file, line: line)
    }

    /// Waits until block `index` starts with `prefix`.
    func waitForBlock(_ index: Int, startingWith prefix: String, file: StaticString = #filePath, line: UInt = #line) {
        let target = block(at: index)
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in target.exists && target.label.hasPrefix(prefix) }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 60), .completed,
                       "block \(index) reads \(target.exists ? target.label : "nothing"), not \(prefix)…", file: file, line: line)
    }

    /// Opens a body article by its row and waits for its original title or
    /// its translation.
    func openBody(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        scrollList(to: title, file: file, line: line).tap()
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            // The original, or a translation of it in any language.
            self.readingTitle.exists && (self.readingTitle.label == title || self.readingTitle.label.hasSuffix("]：" + title))
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: timeout), .completed,
                       "the reading screen shows \(readingTitle.exists ? readingTitle.label : "nothing"), not \(title)", file: file, line: line)
    }

    /// Leaves the open article: back to the list on the tab structure; on
    /// the panes, another article (the Chinese one, which sends nothing).
    func leaveArticle(file: StaticString = #filePath, line: UInt = #line) {
        if usesTabs {
            backToList()
        } else {
            openBody(Body.chinese, file: file, line: line)
        }
    }

    /// Chooses a display mode from the bar's menu.
    func chooseMode(_ rawValue: String, file: StaticString = #filePath, line: UInt = #line) {
        waitFor(modeMenu, file: file, line: line).tap()
        let item = app.buttons.matching(identifier: AccessibilityID.displayModeOption(rawValue)).firstMatch
        waitFor(item, file: file, line: line).tap()
        waitForAbsence(item, file: file, line: line)
    }

    /// The display mode the menu says, by its value.
    var modeValue: String {
        (modeMenu.value as? String) ?? ""
    }
}
