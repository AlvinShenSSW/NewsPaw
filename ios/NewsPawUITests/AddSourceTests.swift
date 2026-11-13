import XCTest

/// RD05 criteria 2–9, 17 and 20: the Add source sheet, against the debug
/// fixture transport only (criterion 19). The fixture addresses are under
/// `example.invalid`, except the one suggested address the table answers.
final class AddSourceTests: NewsPawUITestCase {
    enum Fixture {
        static let feed = "https://feed.example.invalid/rss.xml"
        static let twoFeeds = "https://twofeeds.example.invalid/"
        static let oneFeed = "https://onefeed.example.invalid/"
        static let noFeed = "https://nofeed.example.invalid/"
        static let forbidden = "https://forbidden.example.invalid/"
        static let slowFeeds = "https://slowfeeds.example.invalid/"
        static let slowFeed = "https://slowfeeds.example.invalid/slow.xml"
        static let sequence = "https://sequence.example.invalid/rss.xml"
    }

    /// Criteria 2 and 17: a feed by address; its row with its count; the
    /// destinations before and after.
    func testAddAFeedByAddress() {
        launchAtFullWidth()
        createCategory("News")
        assertDestinations(articles: nil)

        openAddSource()
        detect(Fixture.feed)
        waitFor(element(AccessibilityID.confirmAddress))
        XCTAssertEqual(app.textFields[AccessibilityID.nameField].value as? String, "Fixture Feed")
        XCTAssertEqual(scrollTo(element(AccessibilityID.kindValue)).label, "Feed · RSS")
        scrollTo(element(AccessibilityID.previewItem))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: AccessibilityID.previewItem).count, 3)
        chooseCategoryAndSave("News")

        // Save expands the category.
        showCategoryList()
        let row = waitFor(sourceRow("Fixture Feed"))
        XCTAssertEqual(row.value as? String, "3 unread")
        assertDestinations(articles: ["Fixture story one", "Fixture story two", "Fixture story three"])
    }

    /// Criterion 3: a page with two feeds; both rows with their second
    /// lines; the second chosen and saved.
    func testPageWithTwoFeeds() {
        launchAtFullWidth()
        createCategory("News")
        openAddSource()
        detect(Fixture.twoFeeds)
        let first = waitFor(button(AccessibilityID.candidateChoice("https://twofeeds.example.invalid/news.xml")))
        let second = button(AccessibilityID.candidateChoice("https://twofeeds.example.invalid/atom.xml"))
        XCTAssertTrue(first.label.contains("Two Feeds News"), first.label)
        XCTAssertTrue(first.label.contains("RSS · latest item"), first.label)
        XCTAssertTrue(second.label.contains("Atom · latest item"), second.label)
        XCTAssertTrue(first.isSelected)
        waitFor(element(AccessibilityID.pageItselfChoice))
        XCTAssertTrue(app.staticTexts["Found 2 feeds on this page"].exists)
        second.tap()
        XCTAssertTrue(second.isSelected)
        XCTAssertEqual(app.textFields[AccessibilityID.nameField].value as? String, "Two Feeds Updates")
        XCTAssertEqual(scrollTo(element(AccessibilityID.kindValue)).label, "Feed · Atom")
        chooseCategoryAndSave("News")
        showCategoryList()
        XCTAssertEqual(waitFor(sourceRow("Two Feeds Updates")).value as? String, "2 unread")
        XCTAssertFalse(sourceRow("Two Feeds News").exists)
    }

    /// Criterion 4: a page with one feed saved as itself: a globe and no
    /// count.
    func testPageSavedAsItself() {
        launchAtFullWidth()
        createCategory("News")
        openAddSource()
        detect(Fixture.oneFeed)
        waitFor(button(AccessibilityID.pageItselfChoice)).tap()
        XCTAssertEqual(app.textFields[AccessibilityID.nameField].value as? String, "One Feed Site")
        XCTAssertEqual(scrollTo(element(AccessibilityID.kindValue)).label, "Web page")
        chooseCategoryAndSave("News")
        showCategoryList()
        XCTAssertEqual(waitFor(sourceRow("One Feed Site")).value as? String, "Web page")
        // A web page holds no unread articles.
        assertDestinations(articles: nil)
    }

    /// Criterion 4: no feed found, both ways out.
    func testNoFeedBothWaysOut() {
        launchAtFullWidth()
        createCategory("News")
        openAddSource()
        detect(Fixture.noFeed)
        waitFor(element(AccessibilityID.noFeedMessage))
        button(AccessibilityID.tryAnotherAddressButton).tap()
        waitForAbsence(element(AccessibilityID.noFeedMessage))
        let field = app.textFields[AccessibilityID.addressField]
        XCTAssertNotEqual(field.value as? String, Fixture.noFeed)

        detect(Fixture.noFeed)
        waitFor(button(AccessibilityID.saveAsWebPageButton)).tap()
        XCTAssertEqual(waitFor(app.textFields[AccessibilityID.nameField]).value as? String, "Plain Page")
        chooseCategoryAndSave("News")
        showCategoryList()
        XCTAssertEqual(waitFor(sourceRow("Plain Page")).value as? String, "Web page")
    }

    /// Criterion 5: a duplicate names where it is filed; "Show in Library"
    /// closes the sheet and shows the category expanded where the category
    /// list is: the Library root (tabs), the sidebar pane (from 1100 pt) or
    /// the slide-over (below 1100 pt).
    func testDuplicateShowsWhereItIs() {
        launchAtFullWidth()
        createCategory("Other")
        createCategory("News")
        addSource(Fixture.feed, to: "News")
        let orientations: [UIDeviceOrientation] = isPad ? [.portrait, .landscapeLeft] : [.portrait]
        for orientation in orientations {
            rotate(orientation)
            requireFullWidth()
            collapse("News")
            if !app.tabBars.firstMatch.exists, element(AccessibilityID.slideOverPanel).exists {
                button(AccessibilityID.closeSidebarButton).tap()
                waitForAbsence(element(AccessibilityID.slideOverPanel))
            }
            if app.tabBars.firstMatch.exists {
                // Leave the Library tab so that showing it is visible.
                app.tabBars.buttons.element(boundBy: 0).tap()
            }
            openAddSource()
            detect("feed.example.invalid/rss.xml")
            let message = waitFor(element(AccessibilityID.duplicateMessage))
            XCTAssertEqual(message.label, "This address is already in “News” as “Fixture Feed”.")
            button(AccessibilityID.showInLibraryButton).tap()
            waitForAbsence(app.textFields[AccessibilityID.addressField])
            waitFor(sourceRow("Fixture Feed"))
            if app.tabBars.firstMatch.exists {
                XCTAssertTrue(app.tabBars.buttons["Library"].isSelected)
                XCTAssertTrue(app.navigationBars["Library"].exists)
            } else if window.width >= 1100 {
                XCTAssertTrue(element(AccessibilityID.sidebarPane).exists)
            } else {
                XCTAssertTrue(element(AccessibilityID.slideOverPanel).exists)
            }
            screenshot("show-in-library-\(Int(window.width))")
        }
    }

    /// Criterion 7: a failure, then "Try Again" succeeding; a timeout after
    /// the app put https:// in front adds the http hint.
    func testFailureThenTryAgain() {
        launchAtFullWidth()
        createCategory("News")
        openAddSource()
        detect("timeout.example.invalid")
        let failure = waitFor(element(AccessibilityID.failureMessage))
        XCTAssertTrue(failure.label.contains("Could not read this address · timed out"), failure.label)
        XCTAssertTrue(failure.label.contains("If this site only supports http, type http:// in front of the address."), failure.label)
        XCTAssertFalse(button(AccessibilityID.saveAsWebPageButton).exists)

        // The sequenced address: a feed, then a failure, then a feed.
        detect(Fixture.sequence)
        waitFor(element(AccessibilityID.confirmAddress))
        goBack()
        detect(" " + Fixture.sequence)
        let second = waitFor(element(AccessibilityID.failureMessage))
        XCTAssertEqual(second.label, "Could not read this address · the server answered with error 500")
        XCTAssertTrue(button(AccessibilityID.saveAsWebPageButton).exists)
        button(AccessibilityID.tryAgainButton).tap()
        waitFor(element(AccessibilityID.confirmAddress))
        chooseCategoryAndSave("News")
        showCategoryList()
        waitFor(sourceRow("Sequence Feed"))
    }

    /// Criterion 7: a 403 offers the web-page route.
    func testForbiddenOffersTheWebPageRoute() {
        launchAtFullWidth()
        createCategory("News")
        openAddSource()
        detect(Fixture.forbidden)
        let failure = waitFor(element(AccessibilityID.failureMessage))
        XCTAssertEqual(failure.label, "Could not read this address · the server answered with error 403")
        button(AccessibilityID.saveAsWebPageButton).tap()
        XCTAssertEqual(waitFor(app.textFields[AccessibilityID.nameField]).value as? String, "forbidden.example.invalid")
        chooseCategoryAndSave("News")
        showCategoryList()
        XCTAssertEqual(waitFor(sourceRow("forbidden.example.invalid")).value as? String, "Web page")
    }

    /// Criterion 3: a declared feed that does not answer within the limit
    /// is "Could not check in time"; choosing it returns to the address step
    /// with its address and a detection running, and the earlier list is
    /// gone.
    func testUncheckedCandidateRunsADetection() {
        launchAtFullWidth()
        createCategory("News")
        openAddSource()
        detect(Fixture.slowFeeds)
        let slow = waitFor(button(AccessibilityID.candidateChoice(Fixture.slowFeed)))
        XCTAssertTrue(slow.label.contains("Could not check in time"), slow.label)
        XCTAssertTrue(button(AccessibilityID.candidateChoice("https://slowfeeds.example.invalid/fast.xml")).label.contains("RSS · latest item"))
        slow.tap()
        waitFor(element(AccessibilityID.detecting))
        XCTAssertEqual(app.textFields[AccessibilityID.addressField].value as? String, Fixture.slowFeed)
        XCTAssertFalse(element(AccessibilityID.pageItselfChoice).exists, "the earlier list is gone")
        // The ordinary detection's outcome: the slow feed itself.
        let name = app.textFields[AccessibilityID.nameField]
        XCTAssertTrue(name.waitForExistence(timeout: 15))
        XCTAssertEqual(name.value as? String, "Slow Feed")
        XCTAssertFalse(element(AccessibilityID.pageItselfChoice).exists)
        chooseCategoryAndSave("News")
        showCategoryList()
        waitFor(sourceRow("Slow Feed"))
    }

    /// Criterion 9: the suggested entry the fixtures answer is added, then
    /// marked "Added".
    func testSuggestedSource() {
        launchAtFullWidth()
        createCategory("World")
        openAddSource()
        waitFor(button(AccessibilityID.suggestedSourcesRow)).tap()
        let bbc = waitFor(button(AccessibilityID.suggestedSource("BBC News · World")))
        XCTAssertTrue(app.staticTexts["Japan"].exists)
        bbc.tap()
        waitFor(element(AccessibilityID.confirmAddress))
        XCTAssertEqual(element(AccessibilityID.confirmAddress).label, "https://feeds.bbci.co.uk/news/world/rss.xml")
        chooseCategoryAndSave("World")
        showCategoryList()
        waitFor(sourceRow("BBC News (fixture)"))

        openAddSource()
        button(AccessibilityID.suggestedSourcesRow).tap()
        let added = waitFor(button(AccessibilityID.suggestedSource("BBC News · World")))
        XCTAssertTrue(added.label.contains("Added"), added.label)
        XCTAssertFalse(added.isEnabled)
        XCTAssertFalse(button(AccessibilityID.suggestedSource("NHK News")).label.contains("Added"))
        goBack()
        button(AccessibilityID.cancelButton).tap()
    }

    /// Decision 24: a category created inside the sheet is selected, and
    /// stays when the sheet is cancelled; no source is saved.
    func testNewCategoryInsideTheSheet() {
        launchAtFullWidth()
        openAddSource()
        detect(Fixture.feed)
        waitFor(button(AccessibilityID.categoryChoiceRow)).tap()
        waitFor(button(AccessibilityID.newCategoryInSheetButton)).tap()
        let field = waitFor(app.textFields[AccessibilityID.newCategoryNameField])
        field.tap()
        field.typeText("Inline\n")
        button(AccessibilityID.createCategoryButton).tap()
        let row = waitFor(button(AccessibilityID.categoryChoiceRow))
        XCTAssertTrue(row.label.contains("Inline"), row.label)
        goBack()
        waitFor(button(AccessibilityID.cancelButton)).tap()
        waitForAbsence(app.textFields[AccessibilityID.addressField])
        expand("Inline")
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.sourceRowPrefix)).firstMatch.exists)
    }

    /// Criterion 7: Cancel during detection closes the sheet and stores
    /// nothing.
    func testCancelDuringDetection() {
        launchAtFullWidth()
        createCategory("News")
        openAddSource()
        detect(Fixture.slowFeed)
        waitFor(element(AccessibilityID.detecting))
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(app.textFields[AccessibilityID.addressField])
        expand("News")
        // Longer than the slow feed takes to answer.
        sleep(4)
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.sourceRowPrefix)).firstMatch.exists)
        relaunch()
        expand("News")
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.sourceRowPrefix)).firstMatch.exists)
    }

    /// Criterion 20: the system paste button pastes without a prompt; its
    /// height is recorded, not required to be 44 pt.
    func testPasteButton() {
        launchAtFullWidth()
        UIPasteboard.general.string = Fixture.feed
        openAddSource()
        let paste = waitFor(button(AccessibilityID.pasteButton))
        // The system enables its paste button once it has seen text on the
        // pasteboard.
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: paste)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: timeout), .completed, "the paste button stayed disabled")
        let frame = paste.frame
        paste.tap()
        let field = app.textFields[AccessibilityID.addressField]
        func pasted(within seconds: TimeInterval) -> Bool {
            let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", Fixture.feed), object: field)
            return XCTWaiter.wait(for: [done], timeout: seconds) == .completed
        }
        // One retry of the tap; whether it was needed is recorded.
        var retried = false
        if !pasted(within: 5) {
            retried = true
            paste.tap()
        }
        let note = XCTAttachment(string: "paste retry needed: \(retried)")
        note.name = "paste-retry"
        note.lifetime = .keepAlways
        add(note)
        print("PASTE_RETRY_NEEDED \(retried)")
        XCTAssertTrue(pasted(within: timeout), "pasted: \(String(describing: field.value))")
        XCTAssertFalse(app.alerts.firstMatch.exists, "no prompt")
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists, "no prompt")
        let record = XCTAttachment(string: "Paste button frame: \(frame); height \(frame.height) pt")
        record.name = "paste-button-height"
        record.lifetime = .keepAlways
        add(record)
        print("PASTE_BUTTON_HEIGHT \(frame.height)")
        screenshot("paste-button")
        button(AccessibilityID.cancelButton).tap()
    }

    /// The Continue button: disabled while the field is empty; a tap runs
    /// the detection.
    func testContinueButton() {
        launchAtFullWidth()
        openAddSource()
        let next = button(AccessibilityID.continueButton)
        XCTAssertFalse(waitFor(next).isEnabled, "Continue is disabled while the field is empty")
        let field = app.textFields[AccessibilityID.addressField]
        field.tap()
        field.typeText(Fixture.noFeed)
        // The layout settles (the keyboard is up) before the tap.
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true AND isHittable == true"), object: next)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed, "Continue stayed disabled")
        next.tap()
        waitFor(element(AccessibilityID.noFeedMessage))
        button(AccessibilityID.cancelButton).tap()
    }

    /// An outcome belongs to the text it was detected for: editing the
    /// field takes it away, and the new text gets its own outcome.
    func testOutcomeGoesWhenTheAddressChanges() {
        launchAtFullWidth()
        openAddSource()
        detect(Fixture.noFeed)
        waitFor(element(AccessibilityID.noFeedMessage))
        let field = app.textFields[AccessibilityID.addressField]
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        field.typeText("x")
        waitForAbsence(element(AccessibilityID.noFeedMessage))
        XCTAssertFalse(button(AccessibilityID.saveAsWebPageButton).exists)
        detect(Fixture.forbidden)
        let failure = waitFor(element(AccessibilityID.failureMessage))
        XCTAssertEqual(failure.label, "Could not read this address · the server answered with error 403")
        XCTAssertFalse(element(AccessibilityID.noFeedMessage).exists)
        button(AccessibilityID.cancelButton).tap()
    }

    /// A Save in Add source that fails shows the alert on the sheet, which
    /// stays open with its values and stores nothing; a second Save works.
    func testFailedSaveKeepsTheSheet() {
        launchAtFullWidth(failNextSourceSave: true)
        createCategory("News")
        openAddSource()
        detect(Fixture.feed)
        waitFor(button(AccessibilityID.categoryChoiceRow)).tap()
        waitFor(button(AccessibilityID.categoryChoice("News"))).tap()
        let name = waitFor(app.textFields[AccessibilityID.nameField])
        tapSave()
        let alert = waitFor(app.alerts["The change could not be saved."])
        alert.buttons["OK"].tap()
        waitForAbsence(alert)
        XCTAssertEqual(name.value as? String, "Fixture Feed", "the sheet stays open with its values")
        XCTAssertTrue(button(AccessibilityID.categoryChoiceRow).label.contains("News"))
        // Had the first Save stored the source, this one would be refused
        // as a duplicate.
        tapSave()
        waitForAbsence(name)
        expand("News")
        waitFor(sourceRow("Fixture Feed"))
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.sourceRowPrefix))
        XCTAssertEqual(rows.count, 1)
    }

    /// Criterion 18: what is typed and the detection's result survive the
    /// 700 pt switch.
    func testSheetSurvivesThe700Switch() throws {
        try XCTSkipUnless(isPad, "iPad window resizing")
        launch()
        rotate(.landscapeLeft)
        requireFullWidth()
        createCategory("News")
        openAddSource()
        detect(Fixture.feed)
        let name = waitFor(app.textFields[AccessibilityID.nameField])
        name.tap()
        name.typeText(" edited\n")
        var attempts = 0
        while window.width >= 700, attempts < 10 {
            resizeWindow(by: -120)
            attempts += 1
        }
        XCTAssertLessThan(window.width, 700, "the window could not be made narrower than 700 pt")
        XCTAssertEqual(name.value as? String, "Fixture Feed edited")
        goBack()
        XCTAssertEqual(app.textFields[AccessibilityID.addressField].value as? String, Fixture.feed)
        attempts = 0
        while window.width < 700, attempts < 10 {
            resizeWindow(by: 120)
            attempts += 1
        }
        XCTAssertGreaterThanOrEqual(window.width, 700)
        XCTAssertEqual(app.textFields[AccessibilityID.addressField].value as? String, Fixture.feed)
        button(AccessibilityID.cancelButton).tap()
        requireFullWidth()
    }

    // MARK: - Helpers

    /// Today, All Unread and the category "News" say what they said after
    /// RD03 (their empty states), or, with `articles`, show them: Today's
    /// row for "News" with its count, and the articles' rows in the lists
    /// (RD09 replaced the interim sentence).
    private func assertDestinations(articles: [String]?, file: StaticString = #filePath, line: UInt = #line) {
        func check(_ empty: String) {
            if let articles {
                for title in articles {
                    waitFor(element(AccessibilityID.articleRow(title)), file: file, line: line)
                }
                XCTAssertFalse(element(empty).exists, file: file, line: line)
            } else {
                waitFor(element(empty), file: file, line: line)
                XCTAssertFalse(app.descendants(matching: .any)
                    .matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.articleRowPrefix)).firstMatch.exists,
                    file: file, line: line)
            }
        }
        func checkToday() {
            if let articles {
                let row = waitFor(element(AccessibilityID.todayCategoryRow("News")), file: file, line: line)
                XCTAssertEqual(row.value as? String, "\(articles.count) unread", file: file, line: line)
                XCTAssertFalse(element(AccessibilityID.todayEmpty).exists, file: file, line: line)
            } else {
                waitFor(element(AccessibilityID.todayEmpty), file: file, line: line)
            }
        }
        if app.tabBars.firstMatch.exists {
            app.tabBars.buttons["Today"].tap()
            checkToday()
            app.tabBars.buttons["Library"].tap()
            waitFor(element(AccessibilityID.allUnreadRow)).tap()
            check(AccessibilityID.allUnreadEmpty)
            goBack()
            waitFor(element(AccessibilityID.categoryRow("News"))).tap()
            check(AccessibilityID.categoryEmpty)
            goBack()
        } else {
            openSidebarIfNeeded()
            element(AccessibilityID.todayRow).tap()
            checkToday()
            openSidebarIfNeeded()
            element(AccessibilityID.allUnreadRow).tap()
            check(AccessibilityID.allUnreadEmpty)
            openSidebarIfNeeded()
            element(AccessibilityID.categoryRow("News")).tap()
            check(AccessibilityID.categoryEmpty)
        }
    }
}
