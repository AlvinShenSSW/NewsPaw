import XCTest

/// Shared steps of the RD09 tests: the fixture addresses, reaching each
/// list on either structure, choosing a filter, pulling and reading counts.
@MainActor
class ArticleTestCase: NewsPawUITestCase {
    enum Fixture {
        static let articles = "https://articles.example.invalid/rss.xml"
        static let longCounting = "https://longcounting.example.invalid/rss.xml"
        static let feed = "https://feed.example.invalid/rss.xml"
        static let noFeed = "https://nofeed.example.invalid/"
        static let articlesLink = "https://example.invalid/articles/plain-story"
    }

    /// The tab structure: no pane. (The tab bar itself is hidden while an
    /// article is open on a list.)
    var usesTabs: Bool {
        !element(AccessibilityID.listPane).exists && !element(AccessibilityID.fullPane).exists
    }

    // MARK: - Reaching lists

    func showToday() {
        if usesTabs {
            app.tabBars.buttons.element(boundBy: 0).tap()
        } else {
            openSidebarIfNeeded()
            waitFor(element(AccessibilityID.todayRow)).tap()
            waitForAbsence(element(AccessibilityID.slideOverPanel))
        }
        waitFor(element(AccessibilityID.todayDate))
    }

    /// The category's list: pushed from the Library root, or selected in the
    /// sidebar.
    func openCategoryList(_ name: String) {
        if usesTabs {
            showCategoryList()
            // Back to the root when a list is pushed.
            if !element(AccessibilityID.categoryRow(name)).exists {
                app.tabBars.buttons.element(boundBy: 1).tap()
            }
            waitFor(element(AccessibilityID.categoryRow(name))).tap()
        } else {
            openSidebarIfNeeded()
            scrollTo(element(AccessibilityID.categoryRow(name))).tap()
            waitForAbsence(element(AccessibilityID.slideOverPanel))
        }
        waitFor(app.navigationBars[name])
    }

    func openSourceList(_ name: String, in category: String) {
        expand(category)
        waitFor(sourceRow(name)).tap()
        waitForAbsence(element(AccessibilityID.slideOverPanel))
        waitFor(app.navigationBars[name])
    }

    func openAllUnread() {
        if usesTabs {
            showCategoryList()
            if !element(AccessibilityID.allUnreadRow).exists {
                app.tabBars.buttons.element(boundBy: 1).tap()
            }
            waitFor(element(AccessibilityID.allUnreadRow)).tap()
        } else {
            openSidebarIfNeeded()
            waitFor(element(AccessibilityID.allUnreadRow)).tap()
            waitForAbsence(element(AccessibilityID.slideOverPanel))
        }
    }

    func openStarred() {
        if usesTabs {
            app.tabBars.buttons.element(boundBy: 2).tap()
        } else {
            openSidebarIfNeeded()
            waitFor(element(AccessibilityID.starredRow)).tap()
            waitForAbsence(element(AccessibilityID.slideOverPanel))
        }
    }

    /// Opens a row's article; on the tab structure the reading screen is
    /// pushed, on the panes it fills the reading pane.
    func openArticle(_ title: String) {
        waitFor(articleRow(title)).tap()
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", title), object: element(AccessibilityID.readingTitle))
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: timeout), .completed, "the reading screen did not show \(title)")
    }

    /// Back from the reading screen to its list (tab structure only).
    func backToList() {
        if usesTabs {
            goBack()
            waitForAbsence(element(AccessibilityID.readingTitle))
        }
    }

    // MARK: - Filter

    var filter: XCUIElement {
        element(AccessibilityID.articleFilter)
    }

    /// Chooses a segment of the Unread / All control by its label.
    func chooseFilter(_ label: String) {
        let segment = waitFor(filter).buttons[label]
        waitFor(segment).tap()
        let chosen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: segment)
        XCTAssertEqual(XCTWaiter.wait(for: [chosen], timeout: timeout), .completed, "\(label) was not chosen")
    }

    func selectedFilter() -> String? {
        waitFor(filter).buttons.allElementsBoundByIndex.first(where: \.isSelected)?.label
    }

    // MARK: - Rows

    func waitForUnread(_ row: XCUIElement, _ unread: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let state = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            row.exists && self.isUnread(row) == unread
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [state], timeout: timeout), .completed,
                       "\(row.exists ? row.label : "absent") should be \(unread ? "unread" : "read")", file: file, line: line)
    }

    func waitForLabel(_ element: XCUIElement, containing text: String, _ contains: Bool = true,
                      file: StaticString = #filePath, line: UInt = #line) {
        let state = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            element.exists && element.label.contains(text) == contains
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [state], timeout: timeout), .completed,
                       "\(element.exists ? element.label : "absent") should\(contains ? "" : " not") contain \(text)", file: file, line: line)
    }

    func waitForValue(_ element: XCUIElement, _ value: String, file: StaticString = #filePath, line: UInt = #line) {
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: timeout), .completed,
                       "value: \(String(describing: element.value)), expected \(value)", file: file, line: line)
    }

    /// The title of the top row of the shown list.
    func topRowTitle() -> String? {
        articleRowsShown().first.map { String($0.identifier.dropFirst(AccessibilityID.articleRowPrefix.count)) }
    }

    /// Drags the shown list down far enough to start a refresh.
    func pullList() {
        let anchor = articleRowsShown().first ?? app.collectionViews.firstMatch
        let start = anchor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let distance = min(600, window.maxY - anchor.frame.midY - 20)
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)), withVelocity: .slow, thenHoldForDuration: 1)
    }

    /// Writes a screenshot as an attachment that is kept.
    func record(_ name: String, _ text: String) {
        let note = XCTAttachment(string: text)
        note.name = name
        note.lifetime = .keepAlways
        add(note)
        print("RD09 \(name): \(text)")
    }

    /// A button of the open context menu or toolbar menu.
    func menuButton(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// Swipes a row from its leading or trailing edge and taps the action
    /// `label` if the swipe revealed it rather than running it.
    func swipeAction(on row: XCUIElement, leading: Bool, _ label: String) {
        if leading {
            row.swipeRight()
        } else {
            row.swipeLeft()
        }
        let action = app.buttons.matching(NSPredicate(format: "label == %@ AND NOT (identifier BEGINSWITH 'article.row.')", label)).firstMatch
        if action.waitForExistence(timeout: 2), action.isHittable {
            action.tap()
        }
    }
}
