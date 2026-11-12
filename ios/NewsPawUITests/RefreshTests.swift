import XCTest

/// RD06 criteria 8–11 and 16: Today's status line, pull to refresh, the
/// entry refresh and clean-up, the menus' Refresh and the row's indicator,
/// and Settings → Refresh, against the debug fixture transport only.
final class RefreshTests: NewsPawUITestCase {
    private enum Fixture {
        static let feed = "https://feed.example.invalid/rss.xml"
        static let sequence = "https://sequence.example.invalid/rss.xml"
        static let slow = "https://slowfeeds.example.invalid/slow.xml"
        static let counting = "https://counting.example.invalid/rss.xml"
        static let noFeed = "https://nofeed.example.invalid/"
    }

    // MARK: - Criterion 9: the status line

    /// No line without a feed-like source. A pull refreshes the whole
    /// library: the line goes from about a day ago to "Updated just now". The status line shows "Updating…" while a collection is in
    /// flight, then an "Updated" line.
    ///
    /// The harness waits for the app to be idle after a gesture, and the
    /// system's refresh indicator keeps it busy until the refresh action
    /// returns, so "Updating…" cannot be read during a pull of the 3-second
    /// slow source; how long the pull kept the app busy is recorded instead
    /// (the `.refreshable` assumption of RD06), and "Updating…" is read
    /// during a refresh started from the category's menu.
    func testPullShowsUpdatingThenUpdated() {
        launchAtFullWidth()
        showToday()
        waitFor(element(AccessibilityID.todayEmpty))
        XCTAssertFalse(element(AccessibilityID.todayStatus).exists, "no status line without a feed-like source")
        createCategory("World")
        openAddSource()
        detect(Fixture.noFeed)
        waitFor(button(AccessibilityID.saveAsWebPageButton)).tap()
        chooseCategoryAndSave("World")
        showToday()
        waitFor(element(AccessibilityID.todayEmpty))
        XCTAssertFalse(element(AccessibilityID.todayStatus).exists, "no status line with a web page only")
        addSource(Fixture.slow, to: "World")
        openRefreshSettings()
        choose("Manual Only", in: AccessibilityID.refreshIntervalPicker)

        // A day later by the app's clock, with no entry refresh.
        app.terminate()
        launch(clockOffsetDays: 1)
        rotate(.portrait)
        showToday()
        let status = waitFor(element(AccessibilityID.todayStatus))
        // About a day ago ("23 hours ago" when the minutes the test took
        // are counted).
        XCTAssertTrue(status.label.hasPrefix("Updated "), status.label)
        XCTAssertNotEqual(status.label, "Updated just now")
        let pulled = Date()
        pullToRefresh()
        let busy = Date().timeIntervalSince(pulled)
        print("RD06 pull: the pull gesture returned after \(busy) s (slow source: 3 s)")
        waitForLabel(status, "Updated just now")
        XCTAssertFalse(element(AccessibilityID.failedSourcesButton).exists)

        // "Updating…" while the slow source is collected, then "Updated".
        // From the category's menu with the category collapsed: a row's
        // activity indicator, even in a tab not shown, keeps the app busy
        // and the harness waiting until the collection has ended.
        collapse("World")
        openMenu(ofCategory: "World")
        waitFor(menuButton("Refresh")).tap()
        showToday()
        waitForLabel(status, "Updating…", timeout: 5)
        screenshot("today-updating")
        waitForLabel(status, "Updated just now")
    }

    /// With the sequenced source made to fail by a pull, "1 source failed"
    /// shows the category list with that category expanded and the failing
    /// row: the Library tab's root (iPhone); the slide-over below 1100 pt
    /// and the sidebar pane from 1100 pt (iPad).
    func testFailedSourcesOpenTheirCategory() {
        launchAtFullWidth()
        createCategory("World")
        createCategory("Tech")
        addSource(Fixture.sequence, to: "Tech")
        collapse("Tech")
        if element(AccessibilityID.slideOverPanel).exists {
            button(AccessibilityID.closeSidebarButton).tap()
            waitForAbsence(element(AccessibilityID.slideOverPanel))
        }
        showToday()
        waitFor(element(AccessibilityID.todayStatus))
        pullToRefresh()
        let failures = waitFor(button(AccessibilityID.failedSourcesButton))
        XCTAssertEqual(failures.label, "1 source failed")
        XCTAssertGreaterThanOrEqual(failures.frame.width, 44 - 0.001)
        XCTAssertGreaterThanOrEqual(failures.frame.height, 44 - 0.001)
        // Every attempt failed, so the line keeps the launch's time.
        XCTAssertTrue(element(AccessibilityID.todayStatus).label.hasPrefix("Updated"), element(AccessibilityID.todayStatus).label)
        screenshot("today-one-failed")
        failures.tap()
        assertFailingRowShown(structure: "portrait")

        guard isPad else { return }
        // From 1100 pt the sidebar is a pane.
        button(AccessibilityID.closeSidebarButton).tap()
        waitForAbsence(element(AccessibilityID.slideOverPanel))
        collapse("Tech")
        if element(AccessibilityID.slideOverPanel).exists {
            button(AccessibilityID.closeSidebarButton).tap()
            waitForAbsence(element(AccessibilityID.slideOverPanel))
        }
        rotate(.landscapeLeft)
        requireFullWidth()
        waitFor(element(AccessibilityID.sidebarPane))
        element(AccessibilityID.todayRow).tap()
        waitFor(button(AccessibilityID.failedSourcesButton)).tap()
        assertFailingRowShown(structure: "landscape")
        XCTAssertFalse(element(AccessibilityID.slideOverPanel).exists)
    }

    /// The status line and the failure count in Simplified Chinese.
    func testStatusLineInSimplifiedChinese() {
        launch(arguments: ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"])
        rotate(.portrait)
        requireFullWidth()
        createCategory("世界")
        addSource(Fixture.sequence, to: "世界")
        showToday()
        let status = waitFor(element(AccessibilityID.todayStatus))
        XCTAssertTrue(status.label.hasSuffix("更新"), status.label)
        pullToRefresh()
        XCTAssertEqual(waitFor(button(AccessibilityID.failedSourcesButton)).label, "1 个来源更新失败")
    }

    // MARK: - Criterion 8: Settings → Refresh

    func testSettingsSurviveRelaunch() {
        launchAtFullWidth()
        openRefreshSettings()
        XCTAssertTrue(button(AccessibilityID.refreshIntervalPicker).label.contains("Every 30 Minutes"), button(AccessibilityID.refreshIntervalPicker).label)
        XCTAssertTrue(button(AccessibilityID.retentionPicker).label.contains("30 Days"), button(AccessibilityID.retentionPicker).label)
        choose("Every Hour", in: AccessibilityID.refreshIntervalPicker)
        choose("90 Days", in: AccessibilityID.retentionPicker)
        relaunch()
        rotate(.portrait)
        openRefreshSettings()
        XCTAssertTrue(button(AccessibilityID.refreshIntervalPicker).label.contains("Every Hour"), button(AccessibilityID.refreshIntervalPicker).label)
        XCTAssertTrue(button(AccessibilityID.retentionPicker).label.contains("90 Days"), button(AccessibilityID.retentionPicker).label)
    }

    /// "Manual Only": a relaunch with the clock a day ahead does not
    /// refresh.
    func testManualOnlyDoesNotRefreshOnEntry() {
        launchAtFullWidth()
        openRefreshSettings()
        choose("Manual Only", in: AccessibilityID.refreshIntervalPicker)
        // Back to Settings: in the panes the back button has taken the
        // sidebar button's place.
        goBack()
        createCategory("World")
        addSource(Fixture.counting, to: "World")
        expand("World")
        waitForValue(sourceRow("Counting Feed"), "1 unread")
        app.terminate()
        launch(clockOffsetDays: 1)
        rotate(.portrait)
        showToday()
        let status = waitFor(element(AccessibilityID.todayStatus))
        // Long enough for an entry refresh of the fixture to have ended.
        sleep(4)
        XCTAssertNotEqual(status.label, "Updating…")
        expand("World")
        XCTAssertEqual(waitFor(sourceRow("Counting Feed")).value as? String, "1 unread")
    }

    // MARK: - Criterion 10: entry, end to end

    /// (a) Not due: a relaunch at once leaves the counting source at one.
    /// (b) Due: a relaunch with the clock a day ahead brings a second
    /// article without any action.
    func testEntryRefreshesWhenDue() {
        launchAtFullWidth()
        createCategory("World")
        addSource(Fixture.counting, to: "World")
        expand("World")
        waitForValue(sourceRow("Counting Feed"), "1 unread")

        relaunch()
        rotate(.portrait)
        showToday()
        let status = waitFor(element(AccessibilityID.todayStatus))
        sleep(4)
        XCTAssertNotEqual(status.label, "Updating…")
        expand("World")
        XCTAssertEqual(waitFor(sourceRow("Counting Feed")).value as? String, "1 unread", "not due: no refresh")

        app.terminate()
        launch(clockOffsetDays: 1)
        rotate(.portrait)
        expand("World")
        waitForValue(sourceRow("Counting Feed"), "2 unread")
    }

    /// (c) Clean-up and seen: with the clock 40 days ahead the entry
    /// removes every article, and its refresh collects the fixture feed's
    /// three items again without inserting them, while the counting source
    /// brings one new article.
    func testEntryCleansUpAndSeenItemsStayAway() {
        launchAtFullWidth()
        createCategory("World")
        addSource(Fixture.feed, to: "World")
        addSource(Fixture.counting, to: "World")
        expand("World")
        waitForValue(sourceRow("Fixture Feed"), "3 unread")
        waitForValue(sourceRow("Counting Feed"), "1 unread")

        app.terminate()
        launch(clockOffsetDays: 40)
        rotate(.portrait)
        showToday()
        // Recorded by the entry refresh, on the clock 40 days ahead.
        waitForLabel(element(AccessibilityID.todayStatus), "Updated just now")
        expand("World")
        waitForValue(sourceRow("Fixture Feed"), "0 unread")
        waitForValue(sourceRow("Counting Feed"), "1 unread")
        screenshot("after-clean-up")
        // The fixture feed was collected at the entry: its last update is
        // 40 days ahead of the real clock.
        openSourceSettings("Fixture Feed", in: "World")
        let status = scrollTo(element(AccessibilityID.sourceStatus))
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let day = formatter.string(from: Date().addingTimeInterval(40 * 86_400))
        XCTAssertTrue(status.label.hasPrefix("Working · last updated"), status.label)
        XCTAssertTrue(status.label.contains(day), "\(status.label) does not name \(day)")
        button(AccessibilityID.cancelButton).tap()
    }

    // MARK: - Criterion 11: menus and the row

    func testMenusAndRowIndicator() {
        launchAtFullWidth()
        createCategory("World")
        createCategory("Tech")
        createCategory("Pages")
        addSource(Fixture.counting, to: "World")
        addSource(Fixture.slow, to: "Tech")
        openAddSource()
        detect(Fixture.noFeed)
        waitFor(button(AccessibilityID.saveAsWebPageButton)).tap()
        chooseCategoryAndSave("Pages")
        expand("World")
        expand("Tech")
        expand("Pages")
        let counting = waitFor(sourceRow("Counting Feed"))
        let slow = waitFor(sourceRow("Slow Feed"))
        waitForValue(counting, "1 unread")
        waitForValue(slow, "1 unread")

        // A source's Refresh: the indicator, then the count again.
        slow.press(forDuration: 1.2)
        waitFor(menuButton("Refresh")).tap()
        waitForValue(slow, "Updating", timeout: 5)
        screenshot("row-updating")
        waitForValue(slow, "1 unread")

        // A category's Refresh collects that category's targets only.
        openMenu(ofCategory: "World")
        waitFor(menuButton("Refresh")).tap()
        waitForValue(counting, "2 unread")
        XCTAssertNotEqual(slow.value as? String, "Updating", "Tech was not refreshed")
        openMenu(ofCategory: "Tech")
        waitFor(menuButton("Refresh")).tap()
        waitForValue(slow, "Updating", timeout: 5)
        XCTAssertEqual(counting.value as? String, "2 unread", "World was not refreshed")
        waitForValue(slow, "1 unread")
        XCTAssertEqual(counting.value as? String, "2 unread")

        // Absent for a category with nothing to collect, a web page and a
        // paused source.
        openMenu(ofCategory: "Pages")
        waitFor(menuButton("Category Settings"))
        XCTAssertFalse(menuButton("Refresh").exists, "a category of web pages only")
        dismissMenu()
        sourceRow("Plain Page").press(forDuration: 1.2)
        waitFor(menuButton("Source Settings"))
        XCTAssertFalse(menuButton("Refresh").exists, "a web page")
        dismissMenu()
        counting.press(forDuration: 1.2)
        waitFor(menuButton("Pause")).tap()
        waitForValue(counting, "Paused")
        counting.press(forDuration: 1.2)
        waitFor(menuButton("Resume"))
        XCTAssertFalse(menuButton("Refresh").exists, "a paused source")
        dismissMenu()
        openMenu(ofCategory: "World")
        waitFor(menuButton("Category Settings"))
        XCTAssertFalse(menuButton("Refresh").exists, "a category whose only feed is paused")
        dismissMenu()
    }

    // MARK: - Criterion 16: the largest text size

    func testLargestTextSizeWrapsTheStatusLineAndSettings() {
        launch(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        rotate(.portrait)
        requireFullWidth()
        createCategory("World")
        addSource(Fixture.sequence, to: "World")
        showToday()
        let status = waitFor(element(AccessibilityID.todayStatus))
        pullToRefresh()
        let failures = waitFor(button(AccessibilityID.failedSourcesButton))
        for (name, item) in [("status", status), ("failures", failures)] {
            XCTAssertGreaterThanOrEqual(item.frame.minX, window.minX - 0.5, name)
            XCTAssertLessThanOrEqual(item.frame.maxX, window.maxX + 0.5, "\(name) \(item.frame) in \(window)")
        }
        // 44 pt at the default size: the text is taller than the minimum.
        XCTAssertGreaterThan(failures.frame.height, 50, "the failure count grows with the text")
        XCTAssertEqual(failures.label, "1 source failed")
        screenshot("largest-text-today")

        openRefreshSettings()
        for picker in [AccessibilityID.refreshIntervalPicker, AccessibilityID.retentionPicker] {
            let row = scrollTo(button(picker))
            XCTAssertLessThanOrEqual(row.frame.maxX, window.maxX + 0.5, "\(picker) \(row.frame)")
            XCTAssertGreaterThan(row.frame.height, 60, "\(picker) grows")
        }
        let footer = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Counted from when an article was first seen.'")).firstMatch
        scrollTo(footer)
        XCTAssertLessThanOrEqual(footer.frame.maxX, window.maxX + 0.5)
        XCTAssertGreaterThan(footer.frame.height, 200, "the footer wraps onto many lines")
        screenshot("largest-text-refresh-settings")
    }

    // MARK: - Helpers

    private func showToday() {
        if app.tabBars.firstMatch.exists {
            app.tabBars.buttons.element(boundBy: 0).tap()
        } else {
            openSidebarIfNeeded()
            waitFor(element(AccessibilityID.todayRow)).tap()
            waitForAbsence(element(AccessibilityID.slideOverPanel))
        }
    }

    /// Drags Today's content down far enough to start a refresh.
    private func pullToRefresh() {
        let anchor = [element(AccessibilityID.todayStatus), element(AccessibilityID.todayEmpty), element(AccessibilityID.interimUnread)]
            .first(where: \.exists) ?? app.scrollViews.firstMatch
        // 350 pt was enough on the iPhone but not on the iPads (measured).
        let start = anchor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let distance = min(600, window.maxY - anchor.frame.midY - 20)
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)), withVelocity: .slow, thenHoldForDuration: 1)
    }

    private func openRefreshSettings() {
        if app.tabBars.firstMatch.exists {
            app.tabBars.buttons.element(boundBy: 3).tap()
        } else {
            openSidebarIfNeeded()
            // Below the fold at the largest text size.
            scrollTo(element(AccessibilityID.settingsRow)).tap()
            waitForAbsence(element(AccessibilityID.slideOverPanel))
        }
        waitFor(element(AccessibilityID.refreshRow)).tap()
        waitFor(button(AccessibilityID.refreshIntervalPicker))
    }

    /// Chooses `option` in a menu picker.
    private func choose(_ option: String, in picker: String) {
        waitFor(button(picker)).tap()
        waitFor(app.buttons[option].firstMatch).tap()
        let chosen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", option), object: button(picker))
        XCTAssertEqual(XCTWaiter.wait(for: [chosen], timeout: timeout), .completed, "\(picker): \(button(picker).label)")
    }

    private func openMenu(ofCategory name: String) {
        showCategoryList()
        waitFor(element(AccessibilityID.categoryRow(name))).press(forDuration: 1.2)
    }

    /// A button of the open context menu.
    private func menuButton(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// Closes an open context menu without choosing.
    private func dismissMenu() {
        tapOutsideDialog()
        waitForAbsence(menuButton("Category Settings"))
        waitForAbsence(menuButton("Source Settings"))
    }

    /// After "N sources failed": Tech expanded with its failing row, where
    /// the category list is on this structure.
    private func assertFailingRowShown(structure: String, file: StaticString = #filePath, line: UInt = #line) {
        if app.tabBars.firstMatch.exists {
            XCTAssertTrue(app.tabBars.buttons.element(boundBy: 1).isSelected, "the Library tab", file: file, line: line)
            waitFor(button(AccessibilityID.addMenu), file: file, line: line)
        } else if window.width < 1100 {
            waitFor(element(AccessibilityID.slideOverPanel), file: file, line: line)
        } else {
            waitFor(element(AccessibilityID.sidebarPane), file: file, line: line)
        }
        let row = waitFor(sourceRow("Sequence Feed"), file: file, line: line)
        XCTAssertTrue((row.value as? String ?? "").hasPrefix("Could not update"), "\(String(describing: row.value))", file: file, line: line)
        XCTAssertEqual(button(AccessibilityID.disclosure("Tech")).value as? String, "Shown", file: file, line: line)
        XCTAssertEqual(button(AccessibilityID.disclosure("World")).value as? String, "Hidden", file: file, line: line)
        screenshot("failing-row-\(structure)")
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: timeout ?? self.timeout), .completed,
                       "label: \(element.exists ? element.label : "absent"), expected \(label)", file: file, line: line)
    }

    private func waitForValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: timeout ?? self.timeout), .completed,
                       "value: \(String(describing: element.value)), expected \(value)", file: file, line: line)
    }
}
