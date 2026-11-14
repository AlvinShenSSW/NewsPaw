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
        leaveBrowser()
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

    /// The Starred stack has its own browser: "Open Original Page" on an
    /// article opened from Starred shows the page (pushed on the article in
    /// the tab structure, in the reading pane beside Starred on the panes),
    /// and leaving it returns to the article, still in Starred.
    func testStarredArticlePageOpensAndCloses() {
        launchAtFullWidth()
        createCategory("World")
        addSource(Fixture.articles, to: "World")
        openCategoryList("World")
        swipeAction(on: waitFor(articleRow("Plain story")), leading: false, "Star")
        waitForLabel(articleRow("Plain story"), containing: "Starred")
        openStarred()
        openArticle("Plain story")
        waitFor(button(AccessibilityID.openOriginalButton)).tap()
        waitForPage("Original of plain-story")
        waitFor(barText("example.invalid"))
        if usesTabs {
            XCTAssertTrue(app.buttons.matching(identifier: "BackButton").firstMatch.exists, "pushed on the article")
        } else {
            XCTAssertTrue(element(AccessibilityID.readingPane).frame.contains(app.webViews.firstMatch.frame.insetBy(dx: 1, dy: 1)),
                          "the page takes the reading pane")
            XCTAssertTrue(articleRow("Plain story").exists, "Starred stays beside it")
        }
        closeBrowser()
        waitForLabel(element(AccessibilityID.readingTitle), containing: "Plain story")
        backToList()
        waitFor(articleRow("Plain story"))
        XCTAssertFalse(articleRow("Image story").exists, "the list is Starred")
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

    /// A form a page posts to a new window (`method="post"` with
    /// `target="_blank"`) is shown in the same browser as the page sent it:
    /// the page that answers says it was asked for by POST, with the field's
    /// value and the form's content type, not by a GET of the same address.
    /// Back returns to the form.
    func testFormPostedToANewWindow() {
        launchAtFullWidth()
        createCategory("World")
        addWebPageSource(to: "World")
        openWebPageSource(in: "World")
        tapLink("Post form")
        waitForPage("Post Form")

        waitFor(app.webViews.buttons["Post to a new window"]).tap()
        waitForPosted("note=paw+42", "the form")
        waitFor(barText(Page.host))
        waitForEnabled(backButton, true)
        backButton.tap()
        waitForPage("Post Form")
    }

    /// A form post that fails shows the failure state, and Try Again, like
    /// Reload in that state, sends the same request again, with its method,
    /// its body and its content type, not a GET of the address: for a form
    /// posted to a new window, which the browser loads itself, and for one
    /// posted in the same window, which WebKit follows. Each address fails
    /// its first request and answers the next.
    func testTryAgainSendsAFailedFormPostAgain() {
        launchAtFullWidth()
        createCategory("World")
        addWebPageSource(to: "World")
        openWebPageSource(in: "World")
        tapLink("Post form")
        waitForPage("Post Form")
        let failure = element(AccessibilityID.browserFailure)

        waitFor(app.webViews.buttons["Fail once in a new window"]).tap()
        waitFor(failure)
        waitFor(barText(Page.host))
        waitFor(button(AccessibilityID.browserTryAgainButton)).tap()
        waitForPosted("note=paw+43", "Try Again after a form posted to a new window failed")
        waitForAbsence(failure)
        backButton.tap()
        waitForPage("Post Form")

        waitFor(app.webViews.buttons["Fail once in this window"]).tap()
        waitFor(failure)
        waitFor(barText(Page.host))
        chooseInMore("Reload")
        waitForPosted("note=paw+44", "Reload after a form posted in the same window failed")
        waitForAbsence(failure)
        backButton.tap()
        waitForPage("Post Form")
    }

    /// Waits for the page a fixture form is posted to and fails unless it
    /// was asked for by POST with `body` and the form's content type.
    private func waitForPosted(_ body: String, _ note: String, file: StaticString = #filePath, line: UInt = #line) {
        let answered = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            self.barTexts().contains { $0.hasPrefix("POST: ") || $0.hasPrefix("GET: ") }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [answered], timeout: timeout), .completed, "\(note): the form's page was not shown, \(barTexts())", file: file, line: line)
        XCTAssertTrue(barText("POST: \(body)").exists, "\(note): not sent as the page sent it, \(barTexts())", file: file, line: line)
        XCTAssertTrue(app.webViews.staticTexts["Content type: application/x-www-form-urlencoded"].exists,
                      "\(note): the form's content type was not sent", file: file, line: line)
    }

    // MARK: - Decisions 5 and 10: another host, and the host shown

    /// While another site's slow page is being loaded over a page, the bar
    /// keeps that page's title and host until the new page commits. A link
    /// tapped while a load to another host is pending, and a tapped link of
    /// this host that its server redirects to another host, are loaded by
    /// the browser itself: the arrival page says whether the browser loaded
    /// it or WebKit followed a navigation to it.
    func testAnotherHostIsLoadedByTheBrowserAndShownOnceCommitted() {
        launchAtFullWidth()
        createCategory("World")
        addWebPageSource(to: "World")
        openWebPageSource(in: "World")
        tapLink("Host links")
        waitForPage("Host Links")

        // A page's script starts the load: WebKit names the new address at
        // once, the bar does not.
        tapLink("Script to a slow site")
        waitFor(element(AccessibilityID.browserProgress))
        assertBars(title: "Host Links", host: Page.host, not: Page.otherHost, "while a script's load is pending")
        waitForPage("Slow Site")
        waitFor(barText(Page.otherHost))
        waitForAbsence(element(AccessibilityID.browserProgress))
        backButton.tap()
        waitForPage("Host Links")
        waitFor(barText(Page.host))

        // The browser's own load of a tapped link to another host is
        // pending: the bar still names this page, and a second link to that
        // host is still a link to another host.
        tapLink("Slow site")
        waitFor(element(AccessibilityID.browserProgress))
        assertBars(title: "Host Links", host: Page.host, not: Page.otherHost, "while the browser's load is pending")
        tapLink("Arrival page")
        waitForArrival("a second tap while a load to that host was pending")
        waitFor(barText(Page.otherHost))
        backButton.tap()
        waitForPage("Host Links")

        // A link of this host that redirects to the other one.
        tapLink("Redirecting link")
        waitForArrival("a tapped link redirected to another host")
        waitFor(barText(Page.otherHost))
        backButton.tap()
        waitForPage("Host Links")
        waitFor(barText(Page.host))
    }

    private func assertBars(title: String, host: String, not other: String, _ note: String, file: StaticString = #filePath, line: UInt = #line) {
        let texts = barTexts()
        XCTAssertTrue(texts.contains(title), "\(note), the bar's title is not the page's: \(texts)", file: file, line: line)
        XCTAssertTrue(texts.contains(host), "\(note), the bar's host is not the page's: \(texts)", file: file, line: line)
        XCTAssertFalse(texts.contains(other), "\(note), the bar names a site whose page is not shown: \(texts)", file: file, line: line)
    }

    /// Waits for the other site's arrival page and fails unless the browser
    /// loaded it itself.
    private func waitForArrival(_ note: String, file: StaticString = #filePath, line: UInt = #line) {
        let arrived = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            self.barText("Loaded by the Browser").exists || self.barText("Followed by WebKit").exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [arrived], timeout: timeout), .completed, "\(note): no arrival page, \(barTexts())", file: file, line: line)
        XCTAssertTrue(barText("Loaded by the Browser").exists, "\(note): WebKit followed it, \(barTexts())", file: file, line: line)
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

    /// `window.open('')` has nothing to load and asks nothing. A file link
    /// whose address Safari cannot open (a `blob:` address) shows the file
    /// notice without Open in Safari. A direct link to a video file, which
    /// WebKit plays in a document of its own, is not a failure.
    func testEmptyWindowBlobFileAndMediaFile() {
        launchAtFullWidth()
        createCategory("World")
        addWebPageSource(to: "World")
        openWebPageSource(in: "World")

        tapLink("Empty window link")
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 4), "window.open('') raised \(app.alerts.firstMatch.label)")
        XCTAssertTrue(barText(Page.home).exists, "the page stays: \(barTexts())")
        waitForEnabled(backButton, false)

        tapLink("Blob download link")
        let notice = waitFor(alert(Wording.fileNotice))
        XCTAssertTrue(notice.buttons["OK"].exists)
        XCTAssertFalse(notice.buttons["Open in Safari"].exists, "Safari cannot open a blob: address")
        answer(Wording.fileNotice, "OK")
        waitForPage(Page.home)
        waitForEnabled(backButton, false)

        tapLink("Video link")
        waitForEnabled(backButton, true)
        XCTAssertFalse(element(AccessibilityID.browserFailure).waitForExistence(timeout: 8), "a video file showed the failure state")
        waitFor(barText(Page.host))
        backButton.tap()
        waitForPage(Page.home)
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

    /// With a page shown after a link, crossing 700 pt both ways and
    /// rotating across 1100 pt keep the same page, not a reload of it: the
    /// page shows the count of its loads. Once for a web-page source (one
    /// pane or pushed) and once for an article's page (the reading pane or
    /// pushed on the article).
    func testSessionSurvivesTheCrossings() throws {
        try XCTSkipUnless(isPad, "window widths on iPad")
        launchAtFullWidth()
        createCategory("World")
        addWebPageSource(to: "World")
        addSource(Fixture.articles, to: "World")
        openWebPageSource(in: "World")
        tapLink("Load counter")
        waitForPage("Loads 1")
        crossBothWays(keeping: "Loads 1")
        backButton.tap()
        waitForPage(Page.home)

        openCategoryList("World")
        openArticle("Plain story")
        waitFor(button(AccessibilityID.openOriginalButton)).tap()
        waitForPage("Original of plain-story")
        tapLink("Load counter")
        waitForPage("Loads 2")
        XCTAssertTrue(element(AccessibilityID.readingPane).frame.contains(app.webViews.firstMatch.frame.insetBy(dx: 1, dy: 1)),
                      "the page is in the reading pane")
        crossBothWays(keeping: "Loads 2") {
            XCTAssertTrue(self.app.buttons.matching(identifier: "BackButton").firstMatch.exists, "pushed on the article")
        }
        XCTAssertTrue(element(AccessibilityID.readingPane).frame.contains(app.webViews.firstMatch.frame.insetBy(dx: 1, dy: 1)),
                      "the page is in the reading pane again")
        backButton.tap()
        waitForPage("Original of plain-story")
    }

    /// Crosses 700 pt down and up, then 1100 pt up and down. After each
    /// crossing the page titled `title` is still shown, was not loaded
    /// again (its title would count one more load) and Back is enabled.
    private func crossBothWays(keeping title: String, whilePushed: () -> Void = {}) {
        func kept(_ note: String, file: StaticString = #filePath, line: UInt = #line) {
            waitForPage(title, file: file, line: line)
            // A reload would have answered by now.
            sleep(2)
            XCTAssertTrue(barText(title).exists, "\(note): the page was loaded again, \(barTexts())", file: file, line: line)
            waitForEnabled(backButton, true, file: file, line: line)
        }
        cross700(below: true)
        XCTAssertTrue(usesTabs)
        kept("below 700 pt")
        whilePushed()
        cross700(below: false)
        XCTAssertFalse(usesTabs)
        kept("back above 700 pt")

        requireFullWidth()
        rotate(.landscapeLeft)
        requireFullWidth()
        waitFor(element(AccessibilityID.sidebarPane))
        kept("at 1100 pt and wider")
        rotate(.portrait)
        waitForAbsence(element(AccessibilityID.sidebarPane))
        kept("back below 1100 pt")
    }

    // MARK: - Decision 3: a session ends with its selection, and asks nothing while hidden

    /// On the panes another sidebar selection ends the session: a page that
    /// asks for another app whenever it is not on screen raises nothing
    /// over Today, and selecting the source again starts at its address.
    /// For an article's page opened from Starred the article stays and is
    /// shown without its page.
    func testAnotherSelectionEndsTheSession() throws {
        try XCTSkipUnless(isPad, "the sidebar on iPad")
        launchAtFullWidth()
        createCategory("World")
        addWebPageSource(to: "World")
        addSource(Fixture.articles, to: "World")
        openWebPageSource(in: "World")
        tapLink("Hidden asker")
        waitForPage("Hidden Asker")
        showToday()
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 8), "a page that is not on screen raised \(app.alerts.firstMatch.label)")
        openWebPageSource(in: "World")
        waitForEnabled(backButton, false)
        XCTAssertFalse(app.alerts.firstMatch.exists)

        openCategoryList("World")
        swipeAction(on: waitFor(articleRow("Plain story")), leading: false, "Star")
        waitForLabel(articleRow("Plain story"), containing: "Starred")
        openStarred()
        openArticle("Plain story")
        waitFor(button(AccessibilityID.openOriginalButton)).tap()
        waitForPage("Original of plain-story")
        tapLink("Hidden asker")
        waitForPage("Hidden Asker")
        showToday()
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 8), "a page that is not on screen raised \(app.alerts.firstMatch.label)")
        openStarred()
        waitForLabel(element(AccessibilityID.readingTitle), containing: "Plain story")
        XCTAssertFalse(moreMenu.exists, "the article is shown without its page")
    }

    /// In the tab structure a stack stays alive behind another tab, and its
    /// session with it: "Show in Library" moves from the browser pushed in
    /// Starred to the Library tab. The page left behind, which asks for
    /// another app whenever it is not on screen, raises nothing over
    /// Library, and is still there when Starred is selected again.
    func testHiddenSessionAsksNothing() throws {
        try XCTSkipIf(isPad, "\"Show in Library\" changes the tab in the tab structure; iPhone")
        launch()
        createCategory("World")
        addSource(Fixture.articles, to: "World")
        openCategoryList("World")
        swipeAction(on: waitFor(articleRow("Plain story")), leading: false, "Star")
        waitForLabel(articleRow("Plain story"), containing: "Starred")
        openStarred()
        openArticle("Plain story")
        waitFor(button(AccessibilityID.openOriginalButton)).tap()
        waitForPage("Original of plain-story")
        tapLink("Hidden asker")
        waitForPage("Hidden Asker")

        chooseInMore("Save This Page as a Source")
        detect(Fixture.articles)
        scrollTo(element(AccessibilityID.duplicateMessage))
        scrollTo(button(AccessibilityID.showInLibraryButton)).tap()
        waitFor(button(AccessibilityID.addMenu))
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 8), "a page behind another tab raised \(app.alerts.firstMatch.label)")

        app.tabBars.buttons.element(boundBy: 2).tap()
        waitForPage("Hidden Asker")
        waitForEnabled(backButton, true)
        XCTAssertFalse(app.alerts.firstMatch.exists)
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
