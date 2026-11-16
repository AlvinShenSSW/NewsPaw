import XCTest

/// RD12 criteria 1, 2, 3, 7 and 8: the full text of an article from its
/// page, the body options, the failures remembered and not, and reader
/// mode with its temporary article. Against the fixture transport and the
/// browser's fixture pages only.
final class FullTextTests: FullTextTestCase {
    // MARK: - Criterion 1

    /// An excerpt-only item whose page is the fixture article shows the
    /// extracted text under "Full text from the original page"; reopened,
    /// and opened again after a relaunch, it shows the same edition number
    /// without a second request.
    func testFullTextFromItsPage() {
        launchWithFullTextFeed()
        XCTAssertEqual(pagesRequested, 0)
        // The excerpt under the loading line, until the page answers.
        openArticle("Fetched story")
        waitFor(loadingNote)
        waitFor(block(containing: "The excerpt of fetched story"))
        waitFor(fullTextNote)
        waitForAbsence(loadingNote)
        // The replaced body starts at the top: the header and the line are
        // on screen.
        XCTAssertTrue(readingTitle.isHittable, "the title scrolled away when the body was replaced")
        XCTAssertTrue(fullTextNote.isHittable, "the full-text line scrolled away when the body was replaced")
        let first = edition()
        XCTAssertFalse(first.isEmpty)
        XCTAssertFalse(excerptNote.exists)
        // The extraction's body, with its link and its picture; the page's
        // script did not run and its furniture is gone.
        waitFor(block(containing: "The harbour office posts the tide tables"))
        XCTAssertFalse(block(containing: "Rewritten by the page script").exists)
        XCTAssertFalse(block(containing: "Most read").exists)
        expectPages(1, "the first opening")

        // Reopened.
        leaveArticle()
        openArticle("Fetched story")
        waitFor(fullTextNote)
        XCTAssertEqual(edition(), first)
        expectPages(1, "the second opening")

        // After a relaunch: read from the library.
        launchReading()
        openSourceList(FullText.source, in: FullText.category)
        chooseFilter("All")
        openArticle("Fetched story")
        waitFor(fullTextNote)
        XCTAssertEqual(edition(), first)
        expectPages(0, "the opening after the relaunch")
    }

    // MARK: - Criterion 2

    /// "Feed Content Only" never requests; "Always Fetch the Page" requests
    /// for an item whose feed has the full text, and shows the feed's
    /// content when the fetch fails.
    func testBodyOptions() {
        launchWithFullTextFeed()
        chooseBody("Feed Content Only")
        openAndSettle("Fetched story", fullText: false)
        backToList()
        openAndSettle("List story", fullText: false)
        expectPages(0, "feed content only")

        backToList()
        chooseBody("Always Fetch the Page")
        openAndSettle("Full feed story", fullText: true)
        XCTAssertFalse(edition().isEmpty)
        expectPages(1, "always fetch, a feed with its full text")

        backToList()
        scrollList(to: "Failing full story")
        openArticle("Failing full story")
        // The feed's own full text, as RD11 shows it: neither line.
        waitFor(block(containing: "Feed text. The harbour office posts"))
        waitForAbsence(loadingNote)
        XCTAssertFalse(fullTextNote.exists)
        XCTAssertFalse(excerptNote.exists)
        expectPages(2, "always fetch, a page that does not answer")
    }

    // MARK: - Criterion 3

    /// A page over the limit, a page without an article, one that only its
    /// script would build and one that is not HTML end in the excerpt state
    /// and are not asked for again within the hour; a saved source setting
    /// ends that. A fetch left before its answer is asked for again.
    func testFailuresRemembered() {
        launchWithFullTextFeed()
        var requests = 0
        for title in ["Huge story", "List story", "Scripted story", "Plain text story"] {
            openAndSettle(title, fullText: false)
            requests += 1
            expectPages(requests, "\(title), first opening")
            leaveArticle()
            openAndSettle(title, fullText: false)
            expectPages(requests, "\(title), opened again")
            leaveArticle()
        }

        saveSourceSettingsUnchanged()
        openAndSettle("List story", fullText: false)
        requests += 1
        expectPages(requests, "after the source's settings were saved")
        backToList()

        // A page that never answers: the loading line, under the excerpt.
        scrollList(to: "Stalled story")
        openArticle("Stalled story")
        waitFor(loadingNote)
        waitFor(block(containing: "The excerpt of stalled story"))
        XCTAssertFalse(excerptNote.exists)
        requests += 1
        expectPages(requests, "a page that does not answer")
        // Left before the answer: not remembered.
        leaveArticle()
        scrollList(to: "Stalled story")
        openArticle("Stalled story")
        waitFor(loadingNote)
        requests += 1
        expectPages(requests, "the page that did not answer, opened again")
    }

    // MARK: - Criteria 7 and 8

    /// Reader mode on the browser's article page shows the temporary
    /// article with Close, Share and "Aa" and no star; on the list page it
    /// says there is no readable article. Close shows the page again with
    /// its history; a change of width keeps the temporary article; a link
    /// tapped in it is loaded by the browser. Opening it pauses the page's
    /// media, and the page stays alive beneath it (assumption A4).
    func testReaderMode() {
        launchWithFullTextFeed()
        openAndSettle("Fetched story", fullText: true)
        openOriginalPage()
        let afterArticleOpen = pagesRequested

        // The list page: no readable article.
        tapLink("the latest stories")
        waitForPage(FullText.listTitle)
        openReaderModeExpectingAlert()
        expectPages(afterArticleOpen + 1, "reader mode on the list page")
        XCTAssertFalse(readerTitle.exists)
        waitForEnabled(backButton, true)
        backButton.tap()
        waitForPage(FullText.articleTitle)

        // The article page, playing.
        waitFor(app.webViews.buttons["Play"]).tap()
        waitForTitle(prefix: "Ferry", containing: "playing")

        openReaderMode()
        expectPages(afterArticleOpen + 2, "reader mode on the article page")
        XCTAssertTrue(readerTitle.label.contains(FullText.articleTitle), readerTitle.label)
        XCTAssertEqual(element(AccessibilityID.readerHost).label, FullText.host)
        XCTAssertFalse(edition().isEmpty)
        waitFor(block(containing: "The harbour office posts the tide tables"))
        XCTAssertTrue(button(AccessibilityID.readerCloseButton).exists)
        XCTAssertTrue(element(AccessibilityID.readerShareButton).exists)
        XCTAssertTrue(button(AccessibilityID.readerSettingsButton).exists)
        XCTAssertFalse(button(AccessibilityID.readingStarButton).exists)
        XCTAssertFalse(button(AccessibilityID.readingNextButton).exists)
        XCTAssertFalse(backButton.exists)
        XCTAssertFalse(readerButton.exists)
        // The page beneath is alive and its media paused (A4): its title,
        // which its script writes every 200 ms, says so.
        waitForTitle(prefix: "Ferry", containing: "paused")
        let paused = barTexts().first { $0.hasPrefix("Ferry") } ?? ""
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(barTexts().first { $0.hasPrefix("Ferry") }, paused, "the page's media played on beneath the temporary article")
        record("RD12 A4 page title under the temporary article", paused)

        // "Aa".
        button(AccessibilityID.readerSettingsButton).tap()
        waitFor(button(AccessibilityID.textSizeLargerButton))
        closeReadingSettings()

        // A change of width keeps it.
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1.5)
        waitFor(readerTitle)
        XCTAssertTrue(readerTitle.label.contains(FullText.articleTitle))
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 1.5)
        waitFor(readerTitle)

        // Close: the page again, with its history.
        button(AccessibilityID.readerCloseButton).tap()
        waitForAbsence(readerTitle)
        waitFor(app.webViews.buttons["Play"])
        waitForTitle(prefix: "Ferry", containing: "paused")
        waitForEnabled(forwardButton, true)
        forwardButton.tap()
        waitForPage(FullText.listTitle)
        backButton.tap()
        waitForTitle(prefix: "", containing: "erry")

        // A link in the temporary article is loaded by the browser.
        openReaderMode()
        // The temporary article's link, not the page's beneath it.
        let link = element(AccessibilityID.readerArticle).links["The latest stories"]
        scrollArticle(to: link)
        link.tap()
        waitForAbsence(readerTitle)
        waitForPage(FullText.listTitle)
        waitFor(readerButton)
    }

    /// Reader mode while its page is being fetched shows activity, and Back
    /// cancels it: nothing is shown afterwards, and the button is ready
    /// again.
    func testReaderModeCancelledByANavigation() {
        launchWithFullTextFeed()
        openAndSettle("Fetched story", fullText: true)
        openOriginalPage()
        tapLink("a story that never loads")
        waitForPage("Stalled page")
        let before = pagesRequested
        waitForEnabled(readerButton, true)
        readerButton.tap()
        waitForValue(readerButton, "Loading")
        XCTAssertFalse(readerButton.isEnabled)
        expectPages(before + 1, "reader mode on a page that does not answer")
        backButton.tap()
        waitForPage(FullText.articleTitle)
        waitForEnabled(readerButton, true)
        XCTAssertFalse(readerTitle.waitForExistence(timeout: 3))
        XCTAssertFalse(alert(FullText.noArticle).exists)
    }

    // MARK: - Helpers

    /// Leaves the open article: back to the list (tab structure), or
    /// another article in the reading pane, one whose feed carries its
    /// full text, so that it asks for no page.
    private func leaveArticle() {
        if usesTabs {
            backToList()
        } else {
            scrollList(to: "Full feed story")
            openArticle("Full feed story")
        }
    }

    private func openReaderModeExpectingAlert() {
        waitForEnabled(readerButton, true)
        readerButton.tap()
        let shown = waitFor(alert(FullText.noArticle))
        shown.buttons["OK"].tap()
        waitForAbsence(alert(FullText.noArticle))
    }

    /// Waits until the browser's title starts with `prefix` and holds
    /// `text`.
    private func waitForTitle(prefix: String, containing text: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            self.barTexts().contains { $0.hasPrefix(prefix) && $0.contains(text) }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: timeout), .completed,
                       "the title is not \(prefix)… \(text): \(barTexts())", file: file, line: line)
    }

}
