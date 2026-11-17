import XCTest

/// RD09 criteria 4–11 and 17: article lists, read state, stars, the reading
/// screen's header and bars, Today's rows, navigation and refresh from a
/// list, against the debug fixture transport only. The reading screen's
/// body is RD11's (`ReadingTests`).
final class ArticleListTests: ArticleTestCase {
    // MARK: - Criterion 4: a list is a snapshot

    /// In a category's unread list an opened article stays, read, until the
    /// list is entered again; the filter chosen for a list is kept across a
    /// visit to another list; under All the read article is listed.
    func testUnreadListIsASnapshot() {
        launchAtFullWidth()
        createCategory("World")
        addSource(Fixture.articles, to: "World")
        openCategoryList("World")
        XCTAssertEqual(selectedFilter(), "Unread")
        let plain = waitFor(articleRow("Plain story"))
        XCTAssertTrue(isUnread(plain), plain.label)
        openArticle("Plain story")
        backToList()
        // Still there, read.
        waitForUnread(articleRow("Plain story"), false)
        XCTAssertTrue(isUnread(articleRow("Image story")))

        // Entered again: gone.
        openAllUnread()
        waitFor(articleRow("Image story"))
        openCategoryList("World")
        waitFor(articleRow("Image story"))
        XCTAssertFalse(articleRow("Plain story").exists, "a read article leaves the unread list when it is entered again")

        // The filter is kept per list; under All the read article shows.
        chooseFilter("All")
        waitForUnread(articleRow("Plain story"), false)
        openAllUnread()
        XCTAssertFalse(element(AccessibilityID.articleFilter).exists, "All Unread has no filter")
        waitFor(articleRow("Image story"))
        XCTAssertFalse(articleRow("Plain story").exists)
        openCategoryList("World")
        XCTAssertEqual(selectedFilter(), "All")
        waitForUnread(articleRow("Plain story"), false)
        chooseFilter("Unread")
        waitForAbsence(articleRow("Plain story"))
        screenshot("snapshot-unread")
    }

    // MARK: - Criterion 5: everything agrees at once

    /// Marking an article read from a source's list lowers the source's,
    /// the category's, All Unread's and Today's counts at once; a star made
    /// elsewhere shows in Starred, visited first while empty; both survive a
    /// relaunch.
    func testCountsAndStarsAgreeAndSurviveRelaunch() {
        launchAtFullWidth()
        createCategory("World")
        addSource(Fixture.articles, to: "World")
        openStarred()
        waitFor(element(AccessibilityID.starredEmpty))
        assertCounts(3)

        openSourceList("Articles Feed", in: "World")
        openArticle("Plain story")
        backToList()
        waitForUnread(articleRow("Plain story"), false)
        assertCounts(2)
        // Starred elsewhere: from the source's list, by the trailing swipe.
        openSourceList("Articles Feed", in: "World")
        swipeAction(on: waitFor(articleRow("Linkless story")), leading: false, "Star")
        waitForLabel(articleRow("Linkless story"), containing: ", Starred")
        openStarred()
        waitFor(articleRow("Linkless story"))
        XCTAssertEqual(articleRowsShown().count, 1)

        relaunch()
        rotate(.portrait)
        assertCounts(2)
        openSourceList("Articles Feed", in: "World")
        chooseFilter("All")
        waitForUnread(articleRow("Plain story"), false)
        XCTAssertTrue(articleRow("Linkless story").label.hasSuffix(", Starred"), articleRow("Linkless story").label)
        XCTAssertTrue(isUnread(articleRow("Image story")))
        openStarred()
        waitFor(articleRow("Linkless story"))
    }

    // MARK: - Criterion 6: swipes and the row's menu

    /// The leading swipe toggles read, the trailing swipe toggles the star;
    /// the menu holds the link actions for a linked article and not for the
    /// article without a link; Copy Link fills Add source through its Paste
    /// button. Two context-menu presentations.
    func testSwipesAndRowMenu() {
        launchAtFullWidth()
        createCategory("World")
        addSource(Fixture.articles, to: "World")
        openCategoryList("World")
        let plain = waitFor(articleRow("Plain story"))
        swipeAction(on: plain, leading: true, "Mark as Read")
        waitForUnread(plain, false)
        swipeAction(on: plain, leading: true, "Mark as Unread")
        waitForUnread(plain, true)
        swipeAction(on: plain, leading: false, "Star")
        waitForLabel(plain, containing: ", Starred")
        swipeAction(on: plain, leading: false, "Unstar")
        waitForLabel(plain, containing: ", Starred", false)

        // Presentation 1: a linked article.
        plain.press(forDuration: 1.2)
        for label in ["Open in Browser", "Share", "Copy Link", "Mark as Read", "Star"] {
            waitFor(menuButton(label))
        }
        screenshot("row-menu")
        menuButton("Copy Link").tap()
        waitForAbsence(menuButton("Open in Browser"))

        // Presentation 2: the article without a link; an action closes it.
        let linkless = articleRow("Linkless story")
        linkless.press(forDuration: 1.2)
        waitFor(menuButton("Mark as Read"))
        waitFor(menuButton("Star"))
        for label in ["Open in Browser", "Share", "Copy Link"] {
            XCTAssertFalse(menuButton(label).exists, "\(label) for an article without a link")
        }
        menuButton("Star").tap()
        waitForLabel(linkless, containing: ", Starred")

        // Copy Link, checked through the app.
        openAddSource()
        let paste = waitFor(button(AccessibilityID.pasteButton))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: paste)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: timeout), .completed, "the paste button stayed disabled")
        paste.tap()
        let field = app.textFields[AccessibilityID.addressField]
        let pasted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", Fixture.articlesLink), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [pasted], timeout: timeout), .completed, "pasted: \(String(describing: field.value))")
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists, "no prompt")
        button(AccessibilityID.cancelButton).tap()
    }

    // MARK: - Criterion 7: mark all as read

    /// The question names the number; Cancel changes nothing; confirming
    /// leaves no unread row and the scope's counts at zero; the same from a
    /// category's menu in Library.
    func testMarkAllAsRead() {
        launchAtFullWidth()
        createCategory("World")
        createCategory("Tech")
        addSource(Fixture.articles, to: "World")
        addSource(Fixture.feed, to: "Tech")
        openCategoryList("World")
        waitFor(articleRow("Image story"))
        let markAll = waitFor(button(AccessibilityID.markAllReadButton))
        markAll.tap()
        let alert = waitFor(app.alerts["Mark 3 articles as read?"])
        screenshot("mark-all-question")
        alert.buttons["Cancel"].tap()
        waitForAbsence(alert)
        for title in ["Image story", "Plain story", "Linkless story"] {
            XCTAssertTrue(isUnread(articleRow(title)), title)
        }
        markAll.tap()
        waitFor(app.alerts["Mark 3 articles as read?"]).buttons["Mark as Read"].tap()
        for title in ["Image story", "Plain story", "Linkless story"] {
            waitForUnread(articleRow(title), false)
        }
        XCTAssertEqual(articleRowsShown().count, 3, "the rows keep their places")
        let disabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == false"), object: markAll)
        XCTAssertEqual(XCTWaiter.wait(for: [disabled], timeout: timeout), .completed)
        showCategoryList()
        waitForValue(element(AccessibilityID.categoryRow("World")), "0 unread")
        waitForValue(element(AccessibilityID.allUnreadRow), "3 unread")

        // From the category's menu in Library.
        waitFor(element(AccessibilityID.categoryRow("Tech"))).press(forDuration: 1.2)
        waitFor(menuButton("Mark All as Read")).tap()
        waitFor(app.alerts["Mark 3 articles as read?"]).buttons["Mark as Read"].tap()
        waitForValue(element(AccessibilityID.categoryRow("Tech")), "0 unread")
        waitForValue(element(AccessibilityID.allUnreadRow), "0 unread")
        openCategoryList("Tech")
        XCTAssertEqual(waitFor(element(AccessibilityID.categoryEmpty)).label, "All caught up")
    }

    // MARK: - Criterion 8: the reading screen's header, star and read state

    /// The header, the feed's short text as the body, and the star and the
    /// read state from the reading screen (Mark as Unread is in the More
    /// menu since RD11).
    func testReadingScreenHeaderStarAndReadState() {
        launchAtFullWidth()
        createCategory("World")
        addSource(Fixture.articles, to: "World")
        openCategoryList("World")
        openArticle("Image story")
        XCTAssertTrue(element(AccessibilityID.readingByline).label.hasPrefix("Articles Feed · Fixture Writer · "),
                      element(AccessibilityID.readingByline).label)
        XCTAssertEqual(waitFor(element(AccessibilityID.readingBlock(0))).label, "The harbour at dusk, with the lights coming on along the quay.")
        XCTAssertEqual(waitFor(element(AccessibilityID.readingExcerptNote)).label, "Only an excerpt is available")
        XCTAssertEqual(waitFor(button(AccessibilityID.openOriginalButton)).label, "Open Original Page")
        let star = waitFor(button(AccessibilityID.readingStarButton))
        XCTAssertTrue(button(AccessibilityID.readingShareButton).exists)
        screenshot("reading-excerpt")
        star.tap()
        waitForLabel(star, containing: "Unstar")
        waitFor(button(AccessibilityID.readingMoreMenu)).tap()
        // Opening marked it read.
        waitFor(menuButton("Mark as Unread")).tap()
        waitFor(button(AccessibilityID.readingMoreMenu)).tap()
        waitFor(menuButton("Mark as Read"))
        // Closes the menu without choosing: a tap on the byline, which
        // does nothing of its own. (A tap on a bar's button would both
        // close the menu and press the button.)
        element(AccessibilityID.readingByline).tap()
        waitForAbsence(menuButton("Mark as Read"))
        backToList()
        let row = articleRow("Image story")
        waitForUnread(row, true)
        waitForLabel(row, containing: ", Starred")

        openArticle("Linkless story")
        XCTAssertFalse(button(AccessibilityID.openOriginalButton).exists, "no link, no Open Original Page")
        XCTAssertFalse(button(AccessibilityID.readingShareButton).exists)
        XCTAssertFalse(button(AccessibilityID.readingOriginalBarButton).exists)
        backToList()
        waitForUnread(articleRow("Linkless story"), false)
    }

    // MARK: - Criterion 9: Today (as RD23 changed it)

    /// Today with categories: one card or row per category in the owner's
    /// order, each with its unread count, under the status line — also a
    /// category without unread articles (RD23 replaced RD09's interim rows,
    /// which listed only categories with unread articles). Its header opens
    /// the category's list; after Mark All as Read the row stays at 0.
    func testTodayRows() {
        launchAtFullWidth()
        showToday()
        XCTAssertFalse(element(AccessibilityID.todayDate).label.isEmpty)
        waitFor(element(AccessibilityID.todayEmpty))
        createCategory("World")
        createCategory("Tech")
        createCategory("Quiet")
        addSource(Fixture.articles, to: "World")
        addSource(Fixture.feed, to: "Tech")
        showToday()
        let world = waitFor(element(AccessibilityID.todayCategoryRow("World")))
        let tech = waitFor(element(AccessibilityID.todayCategoryRow("Tech")))
        XCTAssertEqual(world.value as? String, "3 unread")
        XCTAssertEqual(tech.value as? String, "3 unread")
        XCTAssertFalse(element(AccessibilityID.todayEmpty).exists)
        // The owner's order: above, or, in two columns on an iPad, to the
        // left on the same line.
        let sameLine = abs(world.frame.minY - tech.frame.minY) < 1
        XCTAssertTrue(world.frame.minY < tech.frame.minY || (sameLine && world.frame.minX < tech.frame.minX),
                      "the owner's order: \(world.frame) \(tech.frame)")
        let status = waitFor(element(AccessibilityID.todayStatus))
        XCTAssertLessThanOrEqual(element(AccessibilityID.todayDate).frame.maxY, status.frame.minY + 0.5)
        XCTAssertLessThanOrEqual(status.frame.maxY, world.frame.minY + 0.5, "the status line stays above the cards")
        screenshot("today-rows")

        world.tap()
        waitFor(app.navigationBars["World"])
        waitFor(articleRow("Image story"))
        if usesTabs {
            XCTAssertTrue(app.tabBars.buttons.element(boundBy: 1).isSelected, "the Library tab")
        }
        button(AccessibilityID.markAllReadButton).tap()
        waitFor(app.alerts.firstMatch).buttons["Mark as Read"].tap()
        showToday()
        waitForValue(waitFor(element(AccessibilityID.todayCategoryRow("World"))), "0 unread")
        XCTAssertEqual(element(AccessibilityID.todayCategoryRow("Tech")).value as? String, "3 unread")
        let quiet = scrollTo(element(AccessibilityID.todayCategoryRow("Quiet")))
        XCTAssertEqual(quiet.value as? String, "0 unread")
    }

    /// Today scrolls past one screen: with six long-named categories at
    /// the largest text size in landscape, the last row lies below the fold;
    /// it can be scrolled to and opens its category's list.
    func testTodayScrollsToItsLastRow() {
        let names = (1...6).map { "Morning reading from the harbour districts \($0)" }
        let feeds = [
            Fixture.articles, Fixture.feed, Fixture.longCounting, "https://counting.example.invalid/rss.xml",
            "https://onefeed.example.invalid/feed.xml", "https://twofeeds.example.invalid/news.xml",
        ]
        launchAtFullWidth()
        for (name, feed) in zip(names, feeds) {
            // Not the shared helper: it waits for the new row, which in the
            // category list lies below the fold by the fifth category.
            openNewCategory()
            let field = app.textFields[AccessibilityID.nameField]
            field.tap()
            field.typeText(name + "\n")
            tapSave()
            waitForAbsence(field)
            addSource(feed, to: name)
            // Saving expanded it; collapsed, the sidebar's buttons stay above
            // the fold for the next category.
            collapse(name)
        }
        app.terminate()
        launch(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        rotate(.landscapeLeft)
        requireFullWidth()
        if !usesTabs, element(AccessibilityID.slideOverPanel).exists {
            button(AccessibilityID.closeSidebarButton).tap()
        }
        showToday()
        let last = element(AccessibilityID.todayCategoryRow(names[5]))
        waitFor(element(AccessibilityID.todayCategoryRow(names[0])))
        XCTAssertFalse(last.exists && last.isHittable, "the last row starts below the fold: \(last.frame) in \(window)")
        screenshot("today-before-scrolling")
        // Today's own scroll view: a swipe on the application element did not
        // scroll in landscape.
        let today = app.scrollViews.containing(.any, identifier: AccessibilityID.todayDate).firstMatch
        var swipes = 0
        while !(last.exists && last.isHittable), swipes < 8 {
            today.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(last.isHittable, "the last row could not be scrolled to")
        screenshot("today-scrolled-to-the-last-row")
        last.tap()
        waitFor(app.navigationBars[names[5]])
    }

    // MARK: - Criterion 10: navigation

    /// A feed's row opens its list, a web page's row the browser (RD10);
    /// deleting the source from its list's Source Settings returns to the
    /// category list.
    func testSourceTapsAndDeletingFromTheList() {
        launchAtFullWidth()
        createCategory("World")
        addSource(Fixture.articles, to: "World")
        openAddSource()
        detect(Fixture.noFeed)
        waitFor(button(AccessibilityID.saveAsWebPageButton)).tap()
        chooseCategoryAndSave("World")
        expand("World")
        waitFor(sourceRow("Plain Page")).tap()
        waitFor(button(AccessibilityID.browserMoreMenu))
        XCTAssertFalse(app.textFields[AccessibilityID.nameField].exists, "a web page's row opens the browser, not its settings")
        if usesTabs {
            // Back to the Library root, where the tab bar shows again.
            goBack()
            waitFor(app.tabBars.firstMatch)
        }

        openSourceList("Articles Feed", in: "World")
        waitFor(articleRow("Image story"))
        if !usesTabs {
            XCTAssertTrue(element(AccessibilityID.listPane).frame.contains(articleRow("Image story").frame), "the list is in the list pane")
        }
        openListSettings(source: true)
        scrollTo(button(AccessibilityID.deleteSourceButton)).tap()
        waitFor(app.buttons.matching(NSPredicate(
            format: "label == 'Delete Source' AND identifier != %@", AccessibilityID.deleteSourceButton
        )).firstMatch).tap()
        waitForAbsence(app.textFields[AccessibilityID.nameField])
        if usesTabs {
            waitFor(button(AccessibilityID.addMenu))
            XCTAssertTrue(app.navigationBars["Library"].exists, "back at the Library root")
        } else {
            waitFor(app.navigationBars["All Unread"])
            XCTAssertFalse(app.navigationBars["Articles Feed"].exists)
        }
        screenshot("after-deleting-from-the-list")
    }

    /// On iPad the list is in the list pane and the open article in the
    /// reading pane; crossing 700 pt in both directions keeps the list, its
    /// filter and the open article.
    func testCrossing700KeepsListFilterAndArticle() throws {
        try XCTSkipUnless(isPad, "iPad window resizing")
        launch()
        rotate(.landscapeLeft)
        requireFullWidth()
        createCategory("World")
        addSource(Fixture.articles, to: "World")
        openSourceList("Articles Feed", in: "World")
        chooseFilter("All")
        openArticle("Plain story")
        let readingPane = element(AccessibilityID.readingPane).frame
        XCTAssertTrue(readingPane.contains(element(AccessibilityID.readingTitle).frame), "the article is in the reading pane")
        XCTAssertTrue(element(AccessibilityID.listPane).frame.contains(articleRow("Image story").frame))

        resize(below: true)
        // Tabs: the article is pushed on the list (the tab bar is hidden
        // while it is open).
        XCTAssertEqual(waitFor(element(AccessibilityID.readingTitle)).label, "Plain story")
        XCTAssertFalse(element(AccessibilityID.listPane).exists)
        XCTAssertTrue(app.buttons.matching(identifier: "BackButton").firstMatch.exists, "pushed on its list")
        resize(below: false)
        waitFor(element(AccessibilityID.listPane))
        XCTAssertEqual(waitFor(element(AccessibilityID.readingTitle)).label, "Plain story")
        XCTAssertTrue(app.navigationBars["Articles Feed"].exists)
        XCTAssertEqual(selectedFilter(), "All")
        screenshot("after-crossing-back")
        resize(below: true)
        goBack()
        waitFor(app.navigationBars["Articles Feed"])
        XCTAssertEqual(selectedFilter(), "All")
        waitForUnread(articleRow("Plain story"), false)
        resize(below: false)
        requireFullWidth()
    }

    // MARK: - Criterion 11: refresh from a list

    /// In the long counting source's list a pull adds a row at the top, and
    /// so does the menu's Refresh. A run the list did not start (Update Now)
    /// shows when the list is at its top, and not when it is scrolled down
    /// until the list is pulled.
    func testRefreshFromTheList() {
        launchAtFullWidth()
        createCategory("World")
        addSource(Fixture.longCounting, to: "World")
        openSourceList("Long Counting Feed", in: "World")
        waitFor(articleRow("Long story 01"))
        let first = topRowTitle()
        XCTAssertTrue(first?.hasPrefix("Fresh story") == true, "\(String(describing: first))")
        pullList()
        let second = waitForNewTopRow(after: first)

        waitFor(button(AccessibilityID.listMenu)).tap()
        waitFor(menuButton("Refresh")).tap()
        let third = waitForNewTopRow(after: second)

        // Update Now with the list at its top.
        updateNowFromTheList()
        let fourth = waitForNewTopRow(after: third)
        XCTAssertEqual(articleRowsShown().first.map { String($0.identifier.dropFirst(AccessibilityID.articleRowPrefix.count)) }, fourth)

        // Scrolled down: the run does not touch the list.
        let anchor = waitFor(articleRow("Long story 05"))
        let distance = 300.0
        let point = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: anchor.frame.midX, dy: window.midY + 150))
        for _ in 0..<3 {
            point.press(forDuration: 0.1, thenDragTo: point.withOffset(CGVector(dx: 0, dy: -distance)), withVelocity: .slow, thenHoldForDuration: 0.5)
        }
        XCTAssertFalse(articleRow(fourth ?? "").isHittable, "the first row is off screen")
        updateNowFromTheList()
        for _ in 0..<3 {
            point.withOffset(CGVector(dx: 0, dy: -distance))
                .press(forDuration: 0.1, thenDragTo: point, withVelocity: .slow, thenHoldForDuration: 0.5)
        }
        waitFor(articleRow(fourth ?? ""))
        XCTAssertEqual(topRowTitle(), fourth, "no new row until the list is pulled")
        screenshot("scrolled-back-no-new-row")
        pullList()
        let fifth = waitForNewTopRow(after: fourth)
        // Two new rows: the Update Now's and the pull's.
        let titles = articleRowsShown().prefix(3).map { String($0.identifier.dropFirst(AccessibilityID.articleRowPrefix.count)) }
        XCTAssertEqual(titles.first, fifth)
        XCTAssertEqual(titles.last, fourth, "\(titles)")
    }

    /// RD11 criterion 15: the list's top is its scroll position. Scrolled by
    /// less than its first row it is at its top, and a run it did not start
    /// shows; scrolled just past its first row it is not, and the run does
    /// not touch it.
    func testTopOfTheListIsItsScrollPosition() {
        launchAtFullWidth()
        createCategory("World")
        addSource(Fixture.longCounting, to: "World")
        openSourceList("Long Counting Feed", in: "World")
        waitFor(articleRow("Long story 01"))
        let first = topRowTitle()
        let anchor = waitFor(articleRow("Long story 05"))
        let point = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: anchor.frame.midX, dy: window.midY + 150))
        func drag(by distance: CGFloat) {
            point.press(forDuration: 0.1, thenDragTo: point.withOffset(CGVector(dx: 0, dy: distance)), withVelocity: .slow, thenHoldForDuration: 0.5)
        }

        // A third of a row: the first row is still on screen.
        let rowHeight = waitFor(articleRow(first ?? "")).frame.height
        drag(by: -rowHeight / 3)
        updateNowFromTheList()
        let second = waitForNewTopRow(after: first)

        // Two rows and a half: the first row is off screen, though rows
        // near it are still in the list's hierarchy.
        drag(by: -rowHeight * 2.5)
        XCTAssertFalse(articleRow(second ?? "").isHittable, "the first row is off screen")
        updateNowFromTheList()
        drag(by: rowHeight * 4)
        waitFor(articleRow(second ?? ""))
        sleep(1)
        XCTAssertEqual(topRowTitle(), second, "no new row while the list is scrolled past its first row")
        record("list-top", "first row \(rowHeight) pt; at its top when scrolled \(rowHeight / 3) pt, not when scrolled \(rowHeight * 2.5) pt")
    }

    /// RD23 review round 1 (G3): the overview card scrolled off the screen
    /// — its row taken out of the list's hierarchy — while the first article
    /// row is still on screen: the list counts as at its top, and a refresh
    /// run it did not start reads it again. Before the fix the card's
    /// disappearing zeroed its height. At the largest text size, where an
    /// article row is taller than the bars above the list, so that the card
    /// can leave the screen with the first row on it. In the tab structure
    /// only: the run is started from Today's tab while the list stays.
    func testOverviewCardOffScreenKeepsTheListAtItsTop() throws {
        let application = XCUIApplication()
        application.launchEnvironment[UITestLaunchKey.translationModels] = "primary"
        launch(application)
        rotate(.portrait)
        requireFullWidth()
        guard usesTabs else {
            throw XCTSkip("in the panes Today replaces the list; the tab structure keeps it while a run starts elsewhere")
        }
        createCategory("World")
        addSource(Fixture.longCounting, to: "World")
        openCategoryList("World")
        // The list's own run writes the overview: the done card.
        waitFor(button(AccessibilityID.listMenu)).tap()
        waitFor(app.buttons.matching(NSPredicate(format: "label == %@", "Refresh")).firstMatch).tap()
        let summary = element(AccessibilityID.overview("summary", "World"))
        let written = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: summary)
        XCTAssertEqual(XCTWaiter.wait(for: [written], timeout: 30), .completed, "no overview was written")

        app.terminate()
        let large = XCUIApplication()
        large.launchEnvironment[UITestLaunchKey.translationModels] = "primary"
        launch(large, arguments: BrowserLayoutTests.largestText)
        rotate(.portrait)
        openCategoryList("World")
        let card = waitFor(element(AccessibilityID.overview("card", "World")))
        let first = try XCTUnwrap(topRowTitle())
        let row = waitFor(articleRow(first))

        // Up in small steps until the card's row has left the list's
        // hierarchy, the first article row still on screen.
        let point = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.midX, dy: window.maxY - 250))
        var steps = 0
        while card.exists, steps < 60 {
            point.press(forDuration: 0.1, thenDragTo: point.withOffset(CGVector(dx: 0, dy: -30)), withVelocity: .slow, thenHoldForDuration: 0.3)
            steps += 1
        }
        XCTAssertFalse(card.exists, "the card is still in the list after \(steps) steps")
        XCTAssertTrue(row.exists && row.isHittable, "the first row left the screen with the card: \(row.frame), bars \(app.navigationBars.firstMatch.frame)")
        sleep(1)

        // A run the list did not start: a pull on Today.
        app.tabBars.buttons.element(boundBy: 0).tap()
        let date = waitFor(element(AccessibilityID.todayDate))
        let start = date.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 400)), withVelocity: .slow, thenHoldForDuration: 1)
        let status = waitFor(element(AccessibilityID.todayStatus))
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Updated just now"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 30), .completed, "the run did not end: \(status.label)")
        app.tabBars.buttons.element(boundBy: 1).tap()
        _ = waitForNewTopRow(after: first)
        record("list-top-card-off-screen", "row \(row.frame.height) pt; the card left after \(steps) steps of 30 pt; the list was read again")
    }

    /// A list that was scrolled far down, left and entered again starts at
    /// its top and counts as at its top without a scroll: a refresh it did
    /// not start reads it again (RD11, review round 1).
    func testReenteredListIsAtItsTop() {
        launchAtFullWidth()
        createCategory("World")
        addSource(Fixture.longCounting, to: "World")
        openSourceList("Long Counting Feed", in: "World")
        waitFor(articleRow("Long story 01"))
        let anchor = waitFor(articleRow("Long story 05"))
        let point = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: anchor.frame.midX, dy: window.midY + 150))
        for _ in 0..<3 {
            point.press(forDuration: 0.1, thenDragTo: point.withOffset(CGVector(dx: 0, dy: -400)), withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        XCTAssertFalse(articleRow("Long story 01").exists && articleRow("Long story 01").isHittable, "the list is scrolled far from its top")

        // Leave it and enter it again: popped and pushed in the tab
        // structure, another list selected between in the panes.
        if usesTabs {
            goBack()
        } else {
            openStarred()
            waitFor(element(AccessibilityID.starredEmpty))
        }
        openSourceList("Long Counting Feed", in: "World")
        XCTAssertTrue(waitFor(articleRow("Long story 01")).isHittable, "the list entered again is at its top")
        let first = topRowTitle()
        updateNowFromTheList()
        let second = waitForNewTopRow(after: first)
        record("list-re-entered", "top row \(first ?? "none") on entering again, \(second ?? "none") after a refresh the list did not start")
    }

    // MARK: - Helpers

    /// The counts of the source "Articles Feed", its category "World", All
    /// Unread and Today's row for World.
    private func assertCounts(_ unread: Int, file: StaticString = #filePath, line: UInt = #line) {
        let value = "\(unread) unread"
        expand("World")
        waitForValue(waitFor(sourceRow("Articles Feed"), file: file, line: line), value, file: file, line: line)
        waitForValue(element(AccessibilityID.categoryRow("World")), value, file: file, line: line)
        waitForValue(element(AccessibilityID.allUnreadRow), value, file: file, line: line)
        if element(AccessibilityID.slideOverPanel).exists {
            button(AccessibilityID.closeSidebarButton).tap()
            waitForAbsence(element(AccessibilityID.slideOverPanel))
        }
        showToday()
        waitForValue(waitFor(element(AccessibilityID.todayCategoryRow("World")), file: file, line: line), value, file: file, line: line)
    }

    /// Opens Source Settings from the list's menu, runs Update Now, waits
    /// for it to end and closes the sheet.
    private func updateNowFromTheList() {
        openListSettings(source: true)
        let update = scrollTo(button(AccessibilityID.updateNowButton))
        update.tap()
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: update)
        sleep(1)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: timeout), .completed)
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(app.textFields[AccessibilityID.nameField])
    }

    private func waitForNewTopRow(after previous: String?, file: StaticString = #filePath, line: UInt = #line) -> String? {
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            let top = self.topRowTitle()
            return top != nil && top != previous && top?.hasPrefix("Fresh story") == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: timeout), .completed,
                       "the top row stayed \(String(describing: previous))", file: file, line: line)
        return topRowTitle()
    }

    /// Resizes the window across 700 pt.
    private func resize(below: Bool) {
        var attempts = 0
        while (below ? window.width >= 700 : window.width < 700), attempts < 10 {
            resizeWindow(by: below ? -120 : 120)
            attempts += 1
        }
        XCTAssertEqual(window.width < 700, below, "the window could not be resized across 700 pt")
    }
}
