import XCTest

/// RD10 criteria 1–11 and 14: the embedded browser against the debug
/// fixture pages only.
final class BrowserTests: BrowserTestCase {
    // MARK: - Criterion 1: a web-page source opens the browser

    /// The row opens the browser at the source's address: pushed in Library
    /// (tabs), as one pane from the sidebar (panes), where below 1100 pt the
    /// pane carries Show Sidebar. The settings open from the row's menu and
    /// from More → Source Settings, not from the tap.
    func testWebPageSourceOpensTheBrowser() {
        launchAtFullWidth()
        createCategory("World")
        addWebPageSource(to: "World")
        openWebPageSource(in: "World")
        waitFor(barText(Page.host))
        XCTAssertFalse(app.textFields[AccessibilityID.nameField].exists, "the tap opens the browser, not the settings")
        XCTAssertTrue(app.webViews.staticTexts["A page served to the embedded browser under the UI tests."].exists)
        if usesTabs {
            XCTAssertTrue(app.buttons.matching(identifier: "BackButton").firstMatch.exists, "pushed on Library")
            let tabBar = app.tabBars.firstMatch
            XCTAssertFalse(tabBar.exists && tabBar.isHittable, "the tab bar is hidden")
        } else {
            let pane = element(AccessibilityID.fullPane)
            XCTAssertTrue(pane.exists, "one pane")
            XCTAssertTrue(pane.frame.contains(app.webViews.firstMatch.frame.insetBy(dx: 1, dy: 1)), "the page fills the pane")
            XCTAssertFalse(element(AccessibilityID.listPane).exists, "no list pane")
            // Portrait, 700 to 1099 pt: Show Sidebar opens the slide-over.
            waitFor(button(AccessibilityID.showSidebarButton)).tap()
            waitFor(element(AccessibilityID.slideOverPanel))
            waitFor(button(AccessibilityID.closeSidebarButton)).tap()
            waitForAbsence(element(AccessibilityID.slideOverPanel))
            waitForPage(Page.home)
        }

        // More → Source Settings.
        chooseInMore("Source Settings")
        let name = waitFor(app.textFields[AccessibilityID.nameField])
        XCTAssertEqual(name.value as? String, Page.sourceName)
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(name)
        waitForPage(Page.home)

        // The row's menu still has Source Settings.
        expand("World")
        waitFor(sourceRow(Page.sourceName)).press(forDuration: 1.2)
        waitFor(app.buttons["Source Settings"]).tap()
        waitFor(app.textFields[AccessibilityID.nameField])
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(app.textFields[AccessibilityID.nameField])

        if isPad {
            // From 1100 pt the sidebar is a pane beside the browser, with no
            // Show Sidebar button.
            openWebPageSource(in: "World")
            rotate(.landscapeLeft)
            requireFullWidth()
            waitFor(element(AccessibilityID.sidebarPane))
            waitForPage(Page.home)
            XCTAssertTrue(element(AccessibilityID.fullPane).exists)
            XCTAssertFalse(button(AccessibilityID.showSidebarButton).exists)
        }
    }

    // MARK: - Criterion 2: an article's page

    /// "Open Original Page" and the row menu's "Open in Browser" open the
    /// article's link; the row is read after "Open in Browser"; closing
    /// returns to the article in both structures.
    func testArticlePageOpensAndCloses() {
        launchAtFullWidth()
        createCategory("World")
        addSource(Fixture.articles, to: "World")
        openCategoryList("World")
        openArticle("Plain story")
        waitFor(button(AccessibilityID.openOriginalButton)).tap()
        waitForPage("Original of plain-story")
        waitFor(barText("example.invalid"))
        if !usesTabs {
            XCTAssertTrue(element(AccessibilityID.readingPane).frame.contains(app.webViews.firstMatch.frame.insetBy(dx: 1, dy: 1)),
                          "the page takes the reading pane")
            XCTAssertTrue(element(AccessibilityID.listPane).exists, "the list stays beside it")
        }
        closeBrowser()
        waitForLabel(element(AccessibilityID.readingTitle), containing: "Plain story")

        backToList()
        let image = waitFor(articleRow("Image story"))
        XCTAssertTrue(isUnread(image), image.label)
        image.press(forDuration: 1.2)
        waitFor(menuButton("Open in Browser")).tap()
        waitForPage("Original of image-story")
        closeBrowser()
        waitForLabel(element(AccessibilityID.readingTitle), containing: "Image story")
        backToList()
        waitForUnread(articleRow("Image story"), false)
    }

    // MARK: - Criteria 3 and 4: history, reload, progress, new windows

    /// A link enables Back; Back and Forward move between the two pages;
    /// Reload loads the shown page again and a same-page anchor does not;
    /// the progress line is shown while the slow page loads; a link with
    /// `target="_blank"` and one calling `window.open` show their page in
    /// the same browser, and Back returns.
    func testHistoryReloadProgressAndNewWindows() {
        launchAtFullWidth()
        createCategory("World")
        addWebPageSource(to: "World")
        openWebPageSource(in: "World")
        waitForEnabled(backButton, false)
        waitForEnabled(forwardButton, false)

        tapLink("Second page")
        waitForPage("Second Page")
        waitFor(barText(Page.host))
        waitForEnabled(backButton, true)
        backButton.tap()
        waitForPage(Page.home)
        waitForEnabled(forwardButton, true)
        forwardButton.tap()
        waitForPage("Second Page")
        waitForEnabled(forwardButton, false)
        backButton.tap()
        waitForPage(Page.home)

        tapLink("Load counter")
        waitForPage("Loads 1")
        chooseInMore("Reload")
        waitForPage("Loads 2")
        tapLink("Jump to the end")
        sleep(2)
        XCTAssertTrue(barText("Loads 2").exists, "the anchor did not reload the page: \(barTexts())")
        backButton.tap()
        // The anchor is a history entry of its own.
        waitForPage("Loads 2")
        backButton.tap()
        waitForPage(Page.home)

        tapLink("Slow page")
        waitFor(element(AccessibilityID.browserProgress))
        waitForPage("Slow Page")
        waitForAbsence(element(AccessibilityID.browserProgress))
        backButton.tap()
        waitForPage(Page.home)

        tapLink("New window link")
        waitForPage("Opened Page")
        backButton.tap()
        waitForPage(Page.home)
        tapLink("Script window link")
        waitForPage("Opened Page")
        backButton.tap()
        waitForPage(Page.home)
    }

    // MARK: - Criteria 5, 6 and 7: other schemes, files, no interface

    /// `mailto:` and an unknown scheme ask and load nothing; Cancel leaves
    /// the page; "Open" on the unknown scheme says no app can open it; a
    /// page's frames ask nothing. A download link and an unshowable type
    /// show the file notice and leave the page, without the failure state.
    /// A page posting to message-handler names finds that each post throws.
    func testOtherSchemesFilesAndNoInterface() {
        launchAtFullWidth()
        createCategory("World")
        addWebPageSource(to: "World")
        openWebPageSource(in: "World")

        tapLink("Mail link")
        let question = waitFor(alert(Wording.question))
        XCTAssertTrue(question.staticTexts["This is a “mailto” link."].exists, "the question names the scheme")
        answer(Wording.question, "Cancel")
        waitForPage(Page.home)
        waitForEnabled(backButton, false)

        tapLink("Other app link")
        waitFor(alert(Wording.question).staticTexts["This is a “newspaw-unknown-scheme” link."])
        answer(Wording.question, "Open")
        answer(Wording.noApp, "OK")
        waitForPage(Page.home)
        waitForEnabled(backButton, false)

        tapLink("Framed page")
        waitForPage("Framed Page")
        sleep(2)
        XCTAssertFalse(app.alerts.firstMatch.exists, "a frame asked: \(app.alerts.firstMatch.label)")
        backButton.tap()
        waitForPage(Page.home)

        for link in ["Download link", "Unshowable link"] {
            tapLink(link)
            let notice = waitFor(alert(Wording.fileNotice))
            XCTAssertTrue(notice.buttons["Open in Safari"].exists)
            answer(Wording.fileNotice, "OK")
            waitForPage(Page.home)
            XCTAssertFalse(element(AccessibilityID.browserFailure).exists, "\(link) showed the failure state")
            waitForEnabled(backButton, false)
        }

        tapLink("Handler probe")
        waitForPage("Every post threw")
    }

    // MARK: - Criterion 8: failures

    /// A failed address shows the failure state with its host and its two
    /// buttons, and Copy Link gives it; Try Again loads again; Back returns
    /// to the page behind; a page that fails once shows after Try Again; a
    /// link tapped while the slow page loads shows its page, not a failure.
    func testFailures() {
        launchAtFullWidth()
        createCategory("World")
        addWebPageSource(to: "World")
        openWebPageSource(in: "World")

        tapLink("Missing page")
        let failure = waitFor(element(AccessibilityID.browserFailure))
        waitFor(button(AccessibilityID.browserTryAgainButton))
        waitFor(button(AccessibilityID.browserFailureSafariButton))
        XCTAssertEqual(element(AccessibilityID.browserFailureReason).label, "A server with the specified hostname could not be found.")
        waitFor(barText(Page.host))
        screenshot("failure")
        // Copy Link gives the failed address.
        chooseInMore("Copy Link")
        chooseInMore("Save This Page as a Source")
        waitForValue(app.textFields[AccessibilityID.addressField], Page.missingAddress)
        clearAddressField()
        paste(expecting: Page.missingAddress)
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(app.textFields[AccessibilityID.addressField])
        // Try Again fails again; Back returns to the page behind.
        button(AccessibilityID.browserTryAgainButton).tap()
        waitFor(failure)
        waitForEnabled(backButton, true)
        backButton.tap()
        waitForAbsence(failure)
        waitForPage(Page.home)

        tapLink("Flaky page")
        waitFor(failure)
        button(AccessibilityID.browserTryAgainButton).tap()
        waitForPage("Flaky Page")
        waitForAbsence(failure)
        backButton.tap()
        waitForPage(Page.home)

        // A newer load replaces the slow one: not a failure.
        tapLink("Slow page")
        tapLink("Second page")
        waitForPage("Second Page")
        sleep(4)
        XCTAssertFalse(failure.exists, "a replaced load showed the failure state")
        XCTAssertTrue(barText("Second Page").exists)
    }

    // MARK: - Criteria 9 and 10: Save This Page as a Source, Copy Link

    /// Save This Page as a Source fills Add source with the shown address;
    /// for the source being viewed detection finds the duplicate; another
    /// site is saved and the browser stays. Copy Link fills Add source
    /// through its Paste button; Share and Open in Safari are in the menu.
    func testSaveAsSourceAndCopyLink() {
        launchAtFullWidth()
        createCategory("World")
        addWebPageSource(to: "World")
        openWebPageSource(in: "World")

        tapLink("Second page")
        waitForPage("Second Page")
        chooseInMore("Save This Page as a Source")
        waitForValue(app.textFields[AccessibilityID.addressField], Page.secondAddress)
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(app.textFields[AccessibilityID.addressField])

        backButton.tap()
        waitForPage(Page.home)
        chooseInMore("Save This Page as a Source")
        waitForValue(app.textFields[AccessibilityID.addressField], Page.homeAddress)
        app.textFields[AccessibilityID.addressField].tap()
        app.textFields[AccessibilityID.addressField].typeText("\n")
        waitFor(element(AccessibilityID.duplicateMessage))
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(app.textFields[AccessibilityID.addressField])

        // Copy Link, Share, Open in Safari.
        waitFor(moreMenu).tap()
        for label in ["Reload", "Share", "Open in Safari", "Save This Page as a Source", "Copy Link", "Source Settings"] {
            waitFor(menuButton(label))
        }
        screenshot("browser-more-menu")
        menuButton("Copy Link").tap()
        waitForAbsence(menuButton("Open in Safari"))
        chooseInMore("Save This Page as a Source")
        clearAddressField()
        paste(expecting: Page.homeAddress)
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(app.textFields[AccessibilityID.addressField])

        // Another site, reached by a link to another host, is saved; the
        // browser stays.
        tapLink("Another site")
        waitForPage("One Feed Site")
        waitFor(barText("onefeed.example.invalid"))
        waitForEnabled(backButton, true)
        chooseInMore("Save This Page as a Source")
        waitForValue(app.textFields[AccessibilityID.addressField], "https://onefeed.example.invalid/")
        app.textFields[AccessibilityID.addressField].tap()
        app.textFields[AccessibilityID.addressField].typeText("\n")
        waitFor(element(AccessibilityID.confirmAddress))
        chooseCategoryAndSave("World")
        waitForPage("One Feed Site")
        waitFor(moreMenu)
    }

    // MARK: - Criterion 11: the session survives the crossings

    /// With a second page shown after a link, crossing 700 pt both ways and
    /// rotating across 1100 pt keep the page, with Back still enabled.
    func testSessionSurvivesTheCrossings() throws {
        try XCTSkipUnless(isPad, "window widths on iPad")
        launchAtFullWidth()
        createCategory("World")
        addWebPageSource(to: "World")
        openWebPageSource(in: "World")
        tapLink("Second page")
        waitForPage("Second Page")

        cross700(below: true)
        XCTAssertTrue(usesTabs)
        waitForPage("Second Page")
        waitForEnabled(backButton, true)
        cross700(below: false)
        XCTAssertFalse(usesTabs)
        waitForPage("Second Page")
        waitForEnabled(backButton, true)

        requireFullWidth()
        rotate(.landscapeLeft)
        requireFullWidth()
        waitFor(element(AccessibilityID.sidebarPane))
        waitForPage("Second Page")
        waitForEnabled(backButton, true)
        rotate(.portrait)
        waitForAbsence(element(AccessibilityID.sidebarPane))
        waitForPage("Second Page")
        waitForEnabled(backButton, true)
        backButton.tap()
        waitForPage(Page.home)
    }

    // MARK: - Criterion 14: the list under the browser is a snapshot

    /// In the tab structure a refresh that ends while the browser is pushed
    /// over an article does not read the list under it again; entering the
    /// list again shows what the refresh brought. The refresh is the entry
    /// refresh of a return from the background, the one refresh that can
    /// start while the tab bar is hidden. iPhone only: on iPad a window
    /// narrow enough for the tab structure stays in the foreground when Home
    /// is pressed (measured: `runningForeground`), so there is no entry.
    func testRefreshUnderTheBrowserKeepsTheList() throws {
        try XCTSkipIf(isPad, "Home does not send a narrow iPad window to the background")
        // A day ahead, so that the last whole-library refresh lies in the
        // future of the next launch, and the next entry is due.
        launch(clockOffsetDays: 1)
        createCategory("World")
        addSource(Fixture.articles, to: "World")
        addSource("https://counting.example.invalid/rss.xml", to: "World")
        showToday()
        pullToday()
        chooseRefreshInterval("Manual Only")

        app.terminate()
        launch()
        chooseRefreshInterval("Every 30 Minutes")
        openCategoryList("World")
        waitFor(articleRow("Plain story"))
        let before = countingRows()
        XCTAssertGreaterThan(before, 0)
        openArticle("Plain story")
        waitFor(button(AccessibilityID.openOriginalButton)).tap()
        waitForPage("Original of plain-story")

        // The return to the app is an entry; the refresh is due.
        XCUIDevice.shared.press(.home)
        let backgrounded = app.wait(for: .runningBackground, timeout: 10) || app.wait(for: .runningBackgroundSuspended, timeout: 5)
        XCTAssertTrue(backgrounded, "the app did not go to the background: \(app.state.rawValue)")
        app.activate()
        waitForPage("Original of plain-story")
        sleep(4)
        goBack()
        waitForLabel(element(AccessibilityID.readingTitle), containing: "Plain story")
        backToList()
        waitFor(articleRow("Plain story"))
        XCTAssertEqual(countingRows(), before, "the list under the browser was read again")

        openAllUnread()
        openCategoryList("World")
        let grew = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in self.countingRows() > before }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [grew], timeout: timeout), .completed, "the refresh brought no row: \(countingRows())")
    }

    private func countingRows() -> Int {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.articleRow("Counting story")))
            .count
    }

    private func pullToday() {
        let anchor = [element(AccessibilityID.todayStatus), element(AccessibilityID.todayDate)].first(where: \.exists) ?? app.scrollViews.firstMatch
        let start = anchor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let distance = min(600, window.maxY - anchor.frame.midY - 20)
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)), withVelocity: .slow, thenHoldForDuration: 1)
        waitForLabel(waitFor(element(AccessibilityID.todayStatus)), containing: "Updated just now")
    }

    private func chooseRefreshInterval(_ option: String) {
        if app.tabBars.firstMatch.exists {
            app.tabBars.buttons.element(boundBy: 3).tap()
        } else {
            openSidebarIfNeeded()
            scrollTo(element(AccessibilityID.settingsRow)).tap()
            waitForAbsence(element(AccessibilityID.slideOverPanel))
        }
        waitFor(element(AccessibilityID.refreshRow)).tap()
        let row = scrollTo(app.buttons[option].firstMatch)
        row.tap()
        let chosen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [chosen], timeout: timeout), .completed, "\(option) was not selected")
        goBack()
    }
}
