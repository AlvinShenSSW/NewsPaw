import XCTest

/// Shared steps of the RD25 tests: the search fixture feeds, opening
/// Search where each structure has its button, typing into its field and
/// reading the rows it lists.
enum SearchFixture {
    static let feed = "https://search.example.invalid/rss.xml"
    static let privateFeed = "https://search.example.invalid/private.xml"
    static let category = "Birds"
    /// The feed's titles, newest first.
    static let tokyo = "東京で新型ＡＩ発表"
    static let apple = "苹果发布新款芯片"
    static let kestrel = "Kestrel sightings rise in spring"
    /// The private feed's one title.
    static let nightjar = "Nightjar observatory notes"
}

extension NewsPawUITestCase {
    /// The search field of the Search screen.
    var searchField: XCUIElement {
        app.searchFields.firstMatch
    }

    /// Opens Search with its button: the Library root's on the tab
    /// structure, the sidebar's on the panes.
    func openSearchWithButton() {
        if app.tabBars.firstMatch.exists {
            showCategoryList()
            waitFor(button(AccessibilityID.searchButton)).tap()
        } else {
            openSidebarIfNeeded()
            waitFor(button(AccessibilityID.sidebarSearchButton)).tap()
            waitForAbsence(element(AccessibilityID.slideOverPanel))
        }
        waitFor(element(AccessibilityID.searchList))
    }

    /// Waits until the search field has the keyboard focus.
    func waitForSearchFocus(file: StaticString = #filePath, line: UInt = #line) {
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: searchField)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: timeout), .completed, "the search field has no focus", file: file, line: line)
    }

    /// Replaces the search field's text with `text`, typed into the field
    /// that has the focus (no tap).
    func replaceSearchText(with text: String) {
        let current = searchField.value as? String ?? ""
        let placeholder = searchField.placeholderValue ?? ""
        let existing = current == placeholder ? 0 : current.count
        app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing) + text)
    }

    /// The fixture transport's requests so far, from the debug report
    /// (RD25 criterion 11): a refresh would make some.
    var transportRequests: Int {
        guard let match = element(DebugAccessibilityID.adultReport).label.firstMatch(of: /requests=(-?\d+)/) else { return -2 }
        return Int(match.1) ?? -2
    }

    /// Waits until the reading screen's title reads `title`.
    func waitForReadingTitle(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let readingTitle = element(AccessibilityID.readingTitle)
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", title), object: readingTitle)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: timeout), .completed,
                       "the reading screen shows \(readingTitle.exists ? readingTitle.label : "nothing")", file: file, line: line)
    }

    /// Hides the software keyboard, if it is shown, by a drag on the
    /// results (`scrollDismissesKeyboard`): on iPhone it covers the tab bar.
    func hideKeyboardByDragging() {
        guard app.keyboards.firstMatch.exists else { return }
        let list = element(AccessibilityID.searchList).frame
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: list.midX, dy: list.midY - 50))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 150)), withVelocity: 800, thenHoldForDuration: 0.2)
        waitForAbsence(app.keyboards.firstMatch)
    }

    /// Waits until the rows listed are exactly those of `titles`, in order.
    func waitForRows(_ titles: [String], file: StaticString = #filePath, line: UInt = #line) {
        let expected = titles.map { AccessibilityID.articleRow($0) }
        var shown: [String] = []
        let listed = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            shown = self.articleRowsShown().map(\.identifier)
            return shown == expected
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [listed], timeout: timeout), .completed, "rows \(shown), expected \(expected)", file: file, line: line)
    }
}

/// RD25 criterion 8 (ux section 7; spec N05): Search from the Library
/// root's button (tab structure) or the sidebar's (panes), its field
/// focused on arrival, original and translated titles found, a result
/// opened and returned from, the prompt and the no-results state. With
/// the translator fixture, translated titles read "译[zh-Hans]：…", which no
/// original contains.
final class SearchTests: TranslationTestCase {
    func testSearchFindsOriginalAndTranslatedTitles() {
        launchTranslating()
        addFeed(SearchFixture.feed, to: SearchFixture.category)
        // The Japanese and English rows are translated; the Chinese one is
        // Simplified Chinese already.
        waitForLabel(waitFor(articleRow(SearchFixture.kestrel)), containing: Translation.translated(SearchFixture.kestrel))
        waitForLabel(waitFor(articleRow(SearchFixture.tokyo)), containing: Translation.translated(SearchFixture.tokyo))

        openSearchWithButton()
        // Focused on arrival: typing needs no tap.
        waitForSearchFocus()
        waitFor(element(AccessibilityID.searchPrompt))
        app.typeText("芯片")
        waitForRows([SearchFixture.apple])

        replaceSearchText(with: "ai")
        waitForRows([SearchFixture.tokyo])

        // Only the translated title holds "zh-hans" (the fixture's mark).
        replaceSearchText(with: "zh-hans kestrel")
        waitForRows([SearchFixture.kestrel])

        // A result opens the reading screen; back, the query and rows stay.
        articleRow(SearchFixture.kestrel).tap()
        waitForTitle(Translation.translated(SearchFixture.kestrel))
        if usesTabs {
            goBack()
            waitFor(element(AccessibilityID.searchList))
        }
        XCTAssertEqual(searchField.value as? String, "zh-hans kestrel")
        waitForRows([SearchFixture.kestrel])

        // Cleared: the prompt. No match: "No Results".
        searchField.tap()
        replaceSearchText(with: "")
        waitFor(element(AccessibilityID.searchPrompt))
        XCTAssertTrue(articleRowsShown().isEmpty)
        app.typeText("osprey")
        let none = waitFor(element(AccessibilityID.searchNoResults))
        XCTAssertTrue(none.label.contains("“osprey”"), none.label)
        XCTAssertTrue(articleRowsShown().isEmpty)
    }

    /// The failure state: a failed read shows the lists' failed state, and
    /// Try Again reads the same query again.
    func testFailedSearchReadAndTryAgain() {
        app.terminate()
        let application = XCUIApplication()
        application.launchEnvironment[UITestLaunchKey.failNextSearch] = "1"
        launch(application)
        requireFullSize()
        addFeed(SearchFixture.feed, to: SearchFixture.category)
        openSearchWithButton()
        waitForSearchFocus()
        app.typeText("kestrel")
        let failed = waitFor(element(AccessibilityID.couldNotLoad))
        XCTAssertTrue(articleRowsShown().isEmpty)
        failed.buttons.firstMatch.tap()
        waitForRows([SearchFixture.kestrel])
        waitForAbsence(element(AccessibilityID.couldNotLoad))
    }
}

/// RD25: the Search screen's states — the prompt, results (with
/// translated rows), no results and a failed read — written when run with
/// `TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR` set (and, optionally,
/// `TEST_RUNNER_NEWSPAW_SCREENSHOT_VARIANT`: `default`, `zh`,
/// `largest-text`, or several separated by commas; dark appearance is set
/// on the simulator with `xcrun simctl ui`, and named by
/// `TEST_RUNNER_NEWSPAW_SCREENSHOT_APPEARANCE`). Skipped otherwise: it
/// asserts nothing beyond what `SearchTests` asserts.
final class SearchScreenshotTests: TranslationTestCase {
    func testCaptureSearchScreens() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["NEWSPAW_SCREENSHOT_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR to capture screenshots")
        }
        let variants = (environment["NEWSPAW_SCREENSHOT_VARIANT"] ?? "default").split(separator: ",").map(String.init)
        let appearance = environment["NEWSPAW_SCREENSHOT_APPEARANCE"].map { "-" + $0 } ?? ""
        let device = (environment["SIMULATOR_DEVICE_NAME"] ?? "device").replacingOccurrences(of: " ", with: "-")

        // Set up in English at the default size: the search feed, translated.
        launchTranslating()
        addFeed(SearchFixture.feed, to: SearchFixture.category)
        waitForLabel(waitFor(articleRow(SearchFixture.kestrel)), containing: Translation.translated(SearchFixture.kestrel))
        waitForLabel(waitFor(articleRow(SearchFixture.tokyo)), containing: Translation.translated(SearchFixture.tokyo))

        for variant in variants {
            var arguments: [String] = []
            switch variant {
            case "zh": arguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
            case "largest-text": arguments = Self.largestText
            default: break
            }
            var count = 0
            func capture(_ name: String) {
                count += 1
                let url = URL(fileURLWithPath: directory)
                    .appendingPathComponent(String(format: "%@-%@%@-search-%02d-%@.png", device, variant, appearance, count, name))
                try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
            }
            // The captures, with the first search read failing.
            app.terminate()
            let application = XCUIApplication()
            application.launchEnvironment[UITestLaunchKey.failNextSearch] = "1"
            launch(application, arguments: arguments)
            rotate(isPad ? .landscapeLeft : .portrait)
            requireFullSize()
            openSearchWithButton()
            waitForSearchFocus()
            waitFor(element(AccessibilityID.searchPrompt))
            capture("prompt")
            // "s" is in the Kestrel title and in the translated Tokyo title.
            app.typeText("s")
            waitFor(element(AccessibilityID.couldNotLoad))
            capture("failure")
            element(AccessibilityID.couldNotLoad).buttons.firstMatch.tap()
            // At the largest text size the second row may be below the fold.
            waitFor(articleRow(SearchFixture.tokyo))
            waitForAbsence(element(AccessibilityID.couldNotLoad))
            capture("results")
            replaceSearchText(with: "osprey")
            waitFor(element(AccessibilityID.searchNoResults))
            capture("no-results")
        }
    }
}

/// RD25 criterion 10 (spec N02, N09; ux section 1 principle 2): Search
/// finds only the shown partition's titles; after a lock the normal
/// partition's Search starts empty and finds nothing of the adult one.
/// Criterion 11's UI half: no search makes a request through the fixture
/// transport.
final class SearchPartitionTests: AdultTestCase {
    func testSearchStaysInItsPartition() throws {
        try XCTSkipIf(isPad, "the iPhone simulator (criterion 10)")
        launch(authentication: ["passed", "passed", "passed"])
        createCategory(SearchFixture.category)
        addSource(SearchFixture.feed, to: SearchFixture.category)
        // A search in the normal partition, left open.
        openSearchWithButton()
        waitForSearchFocus()
        app.typeText("kestrel")
        waitForRows([SearchFixture.kestrel])
        hideKeyboardByDragging()

        turnOnAdult()
        enterAdult()
        createCategory("Night")
        addSource(SearchFixture.privateFeed, to: "Night")
        let before = transportRequests
        XCTAssertGreaterThan(before, 0, report)
        openSearchWithButton()
        waitForSearchFocus()
        waitFor(element(AccessibilityID.searchPrompt))
        app.typeText("nightjar")
        waitForRows([SearchFixture.nightjar])
        replaceSearchText(with: "kestrel")
        waitFor(element(AccessibilityID.searchNoResults))
        XCTAssertTrue(articleRowsShown().isEmpty)
        replaceSearchText(with: "spring")
        waitFor(element(AccessibilityID.searchNoResults))
        XCTAssertEqual(transportRequests, before, "a search made a request: \(report)")

        // Locked: the normal partition at its root; its Search opens empty.
        hideKeyboardByDragging()
        tapLock()
        waitForPartition(Wording.normal)
        openSearchWithButton()
        waitForSearchFocus()
        waitFor(element(AccessibilityID.searchPrompt))
        let value = searchField.value as? String ?? ""
        XCTAssertTrue(value.isEmpty || value == searchField.placeholderValue, "the field holds \(value)")
        XCTAssertTrue(articleRowsShown().isEmpty)
        app.typeText("nightjar")
        waitFor(element(AccessibilityID.searchNoResults))
        XCTAssertTrue(articleRowsShown().isEmpty)
        replaceSearchText(with: "kestrel")
        waitForRows([SearchFixture.kestrel])
        XCTAssertEqual(transportRequests, before, "a search made a request: \(report)")
    }
}

/// RD25 criterion 9 (ux section 2's `⌘F`; assumption A3), on the iPad
/// simulators, up to its last step (see the note at the end). In `TypedKeyTests`, which runs last: `typeKey` attaches a
/// hardware keyboard to the simulator until it restarts.
extension TypedKeyTests {
    func testCommandFAndLettersInTheField() throws {
        try XCTSkipUnless(isPad, "a hardware keyboard on iPad")
        launch()
        rotate(.landscapeLeft)
        requireFullWidth()
        createCategory(SearchFixture.category)
        addSource(SearchFixture.feed, to: SearchFixture.category)
        openAllUnread()
        let kestrel = waitFor(articleRow(SearchFixture.kestrel))
        let labelBefore = kestrel.label
        waitFor(element(AccessibilityID.noArticleSelected))
        let requestsBefore = transportRequests
        XCTAssertGreaterThan(requestsBefore, 0)

        // With a hardware keyboard attached by an earlier test, the first
        // key event after a launch is dropped (measured: a first ⌘F did
        // nothing, a second opened Search). Escape, which does nothing on
        // All Unread, takes that place.
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        // ⌘F from All Unread: Search in the list pane, its field focused.
        app.typeKey("f", modifierFlags: .command)
        waitFor(element(AccessibilityID.searchList))
        waitForSearchFocus()
        XCTAssertTrue(element(AccessibilityID.listPane).exists)

        // Every letter reaches the field: k, s, e and r are list keys.
        for key in "kestrel" {
            app.typeKey(String(key), modifierFlags: [])
        }
        // The field capitalizes the first letter typed on a hardware
        // keyboard (the system's default); matching folds case.
        let typed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value ==[c] %@", "kestrel"), object: searchField)
        XCTAssertEqual(XCTWaiter.wait(for: [typed], timeout: timeout), .completed, "the field holds \(searchField.value ?? "nothing")")
        waitForRows([SearchFixture.kestrel])
        // Nothing opened, starred, marked or refreshed.
        XCTAssertTrue(element(AccessibilityID.noArticleSelected).exists, "an article was opened")
        XCTAssertEqual(articleRow(SearchFixture.kestrel).label, labelBefore)
        sleep(1)
        XCTAssertEqual(transportRequests, requestsBefore, "a refresh started")

        // Criterion 9's last step — a drag on the results ends the field's
        // focus, then J opens the first result — is not asserted: with a
        // hardware keyboard a drag leaves the focus in the field (measured
        // on the iPad mini; RD25 hand-back), so the list keys stay absent.
    }
}
