import XCTest

/// RD11 criteria 2 (the UI part), 5 to 10, 12, 13 and 14: the reading
/// screen against the fixture transport's reading feed. No test reaches a
/// real host. The keys while the list is hidden are in `TypedKeyTests`.
final class ReadingTests: ReadingTestCase {
    // MARK: - Criterion 5: every block kind, natively

    /// Each kind is on screen with its text, the image is shown, and the
    /// link opens the embedded browser at its address; Close returns to the
    /// article.
    func testEveryBlockKindIsLaidOut() {
        launchWithReadingFeed(isPad ? .landscapeLeft : .portrait)
        openArticle("Every block")
        waitFor(block("The harbour at dusk"))
        let first = waitFor(block(containing: "A paragraph with bold words, italic words, inline code and a link to another page."))
        XCTAssertTrue(first.label.hasSuffix("before the first ferry leaves."), first.label)
        let link = waitFor(app.links["a link to another page"])
        XCTAssertFalse(element(AccessibilityID.readingExcerptNote).exists, "a full text is no excerpt")
        capture("every-block-top")

        for text in [
            "What the boats carry", "Bread from the mainland", "Letters and parcels", "Sorted on the quay",
            "Third on the list", "Fourth on the list", "The lights come on along the quay.",
            "And the boats ride at their moorings.",
        ] {
            scrollArticle(to: block(text))
        }
        // The markers: bullets, and numbers from the list's start.
        let markers = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'reading.marker.'")).allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(markers.contains("•"), "\(markers)")
        XCTAssertTrue(markers.contains("3.") && markers.contains("4."), "\(markers)")
        // A nested item stands further in than its parent: by the indent
        // of a level, 20 pt at the default size, where a bullet fits.
        XCTAssertEqual(block("Sorted on the quay").frame.minX, block("Letters and parcels").frame.minX + 20, accuracy: 0.5)
        // A quote inside a quote too.
        XCTAssertGreaterThan(block("And the boats ride at their moorings.").frame.minX, block("The lights come on along the quay.").frame.minX + 5)

        let image = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'reading.image.' AND label == %@", "The harbour, drawn as a blue disc"
        )).firstMatch
        scrollArticle(to: image)
        XCTAssertGreaterThan(image.frame.height, 100, "the image is shown: \(image.frame)")
        scrollArticle(to: block("A caption under the picture"))
        capture("every-block-image-and-code")
        let code = scrollArticle(to: block(containing: "let tide = Tide(turning: .now)"))
        XCTAssertTrue(code.label.contains("\n"), "the code keeps its line break: \(code.label)")
        for text in ["Boat · Leaves", "Ferry · 07:10", "A smaller heading", "First line of a paragraph\nand its second line."] {
            scrollArticle(to: block(text))
        }
        scrollArticle(to: block(containing: "这是一段中文正文"))
        scrollArticle(to: block(containing: "これは日本語の段落です"))
        capture("every-block-chinese-and-japanese")
        scrollArticle(to: block("The last paragraph of the article."))
        XCTAssertFalse(element(AccessibilityID.readingExcerptNote).exists)
        XCTAssertFalse(element(AccessibilityID.readingCutNote).exists)

        // The link: the embedded browser at its address, above the article.
        scrollArticleToTop()
        link.tap()
        waitForPage("Original of linked-page")
        closeBrowser()
        waitForTitle("Every block")
        waitFor(block("The harbour at dusk"))
    }

    // MARK: - Review round 2: list markers at every text size

    /// At the largest text size and the largest step of the reading
    /// settings, in both faces: every marker stands inside the page's
    /// leading margin and before its item's text, also numbers of three and
    /// four digits in a nested list; an item's further block has its text
    /// at the item's first line's edge, and the items of a list share one.
    func testListMarkersFitAtTheLargestTextSize() {
        launchWithReadingFeed()
        launchReading(arguments: Self.largestText)
        openReadingListUnderAll()
        openArticle("Every block")
        waitFor(block("The harbour at dusk"))
        openReadingSettings()
        while button(AccessibilityID.textSizeLargerButton).isEnabled {
            button(AccessibilityID.textSizeLargerButton).tap()
        }
        XCTAssertEqual(element(AccessibilityID.textSizeValue).value as? String, "5 / 5")
        closeReadingSettings()
        assertListMarkersFit(face: "system face")
        scrollArticleToTop()
        openReadingSettings()
        chooseReadingOption("Serif")
        closeReadingSettings()
        assertListMarkersFit(face: "serif")
    }

    private func assertListMarkersFit(face: String, file: StaticString = #filePath, line: UInt = #line) {
        // The page's leading edge is the byline's; a text block's frame
        // stands around its text by a constant, measured here.
        let page = waitFor(element(AccessibilityID.readingByline)).frame.minX
        let inset = page - waitFor(block(containing: "A paragraph with bold words")).frame.minX
        func marker(_ label: String) -> XCUIElement {
            app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'reading.marker.' AND label == %@", label)).firstMatch
        }
        /// The marker `label` of the item whose first block is `text`, now
        /// on screen: inside the margin, before the text. Returns the
        /// text's leading edge.
        @discardableResult
        func check(_ label: String, before text: String) -> CGFloat {
            let item = scrollArticle(to: block(text), file: file, line: line)
            let edge = item.frame.minX + inset
            let frame = waitFor(marker(label), file: file, line: line).frame
            record("list-markers", "\(face) | \(label) at \(frame) | text edge \(edge) | page edge \(page)")
            XCTAssertGreaterThanOrEqual(frame.minX, page - 0.5, "\(face): \(label) stands past the page's leading margin \(page): \(frame)", file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, edge + 0.5, "\(face): \(label) runs into its text at \(edge): \(frame)", file: file, line: line)
            XCTAssertGreaterThan(frame.width, 5, "\(face): \(label) is drawn", file: file, line: line)
            return edge
        }
        check("•", before: "Bread from the mainland")
        let third = check("3.", before: "Third on the list")
        XCTAssertEqual(check("4.", before: "Fourth on the list"), third, accuracy: 0.5, "\(face): the items of a list share one edge", file: file, line: line)
        let ninetyNinth = check("99.", before: "Ninety-ninth on the list")
        let further = scrollArticle(to: block("A second paragraph of the ninety-ninth item"), file: file, line: line).frame.minX + inset
        XCTAssertEqual(further, ninetyNinth, accuracy: 0.5, "\(face): an item's further block is at its first line's edge", file: file, line: line)
        let hundredth = check("100.", before: "The hundredth on the list")
        XCTAssertEqual(hundredth, ninetyNinth, accuracy: 0.5, "\(face): the items of a list share one edge", file: file, line: line)
        let nested = check("9998.", before: "Nested at 9,998")
        XCTAssertEqual(check("9999.", before: "Nested at 9,999"), nested, accuracy: 0.5, "\(face): the nested items share one edge", file: file, line: line)
        XCTAssertGreaterThan(nested, hundredth + 10, "\(face): the nested list stands further in", file: file, line: line)
        capture("list-markers-\(face == "serif" ? "serif" : "system")")
    }

    // MARK: - Criteria 2 and 6: a hostile body, an excerpt, cut bodies

    /// The hostile article shows its text; the `javascript:` link is text
    /// and a tap on it does nothing; nothing of its script, frame or form is
    /// on screen; its lazy image is shown and its pixel is not.
    func testHostileBodyShowsItsTextAndRunsNothing() {
        launchWithReadingFeed()
        openArticle("Hostile story")
        waitFor(block("Before the links."))
        let paragraph = waitFor(block("A script link and a data link and a safe link."))
        let area = readingArea
        let links = app.links.allElementsBoundByIndex.filter { area.intersects($0.frame) }.map(\.label)
        XCTAssertEqual(links, ["a safe link"], "only the web address is a link")
        // The words of the script link, at the start of the paragraph: a
        // tap on its one line, at the height of the safe link in it. (Not
        // at the top of the paragraph's frame, which is taller than its
        // text.)
        let safe = app.links["a safe link"].frame
        XCTAssertLessThan(paragraph.frame.height, 70, "the paragraph is one line: \(paragraph.frame)")
        XCTAssertTrue(paragraph.frame.contains(CGPoint(x: safe.midX, y: safe.midY)), "the safe link is on that line: \(safe)")
        XCTAssertGreaterThan(safe.minX, paragraph.frame.minX + 200, "the script link's words come well before it")
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: paragraph.frame.minX + 40, dy: safe.midY)).tap()
        sleep(2)
        XCTAssertFalse(button(AccessibilityID.browserMoreMenu).exists, "a tap on the script link's text opened the browser")
        XCTAssertFalse(app.alerts.firstMatch.exists, "a script ran")
        waitForTitle("Hostile story")
        waitFor(block("After the links."))
        let lazy = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'reading.image.' AND label == %@", "A lazy picture"
        )).firstMatch
        waitFor(lazy)
        for gone in ["Frame text", "Input text", "Button text", "script ran", "A tracker", "clicked"] {
            let found = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", gone, gone)).firstMatch
            XCTAssertFalse(found.exists, "\(gone) is on screen")
        }
        XCTAssertFalse(app.webViews.firstMatch.exists, "there is no web view on the reading screen")
        XCTAssertEqual(app.textFields.count, 0, "no control of the article's form")
        capture("hostile")

        // The safe link is a link.
        app.links["a safe link"].tap()
        waitForPage("Original of safe-page")
        closeBrowser()
        waitForTitle("Hostile story")
    }

    /// An excerpt shows its line and "Open Original Page", which opens the
    /// browser; a body with nothing to show is the row's excerpt; a cut body
    /// shows its line and the button, or its own line without a link.
    func testExcerptAndCutBodies() {
        launchWithReadingFeed()
        openArticle("Short note")
        waitFor(block("A short note with one bold word and nothing more."))
        XCTAssertEqual(waitFor(element(AccessibilityID.readingExcerptNote)).label, "Only an excerpt is available")
        capture("excerpt")
        let open = waitFor(button(AccessibilityID.openOriginalButton))
        XCTAssertEqual(open.label, "Open Original Page")
        XCTAssertGreaterThanOrEqual(open.frame.height, 44)
        open.tap()
        waitForPage("Original of short-note")
        closeBrowser()
        waitForTitle("Short note")
        backToList()

        openArticle("Empty body")
        XCTAssertEqual(waitFor(block(at: 0)).label, "Only the feed's summary is left of this one.")
        XCTAssertEqual(waitFor(element(AccessibilityID.readingExcerptNote)).label, "Only an excerpt is available")
        XCTAssertFalse(block(at: 1).exists)
        backToList()

        // Cut by the input limit, and no link.
        openArticle("Cut linkless story")
        waitFor(block("The start of a story too long to read whole."))
        XCTAssertEqual(waitFor(element(AccessibilityID.readingCutNote)).label, "The rest of this article is not shown.")
        XCTAssertFalse(button(AccessibilityID.openOriginalButton).exists)
        XCTAssertFalse(block("Never read.").exists)
        XCTAssertFalse(element(AccessibilityID.readingExcerptNote).exists)
        backToList()

        // Cut by the block limit: 3,000 paragraphs, then the line.
        openArticle("Cut story")
        waitFor(block("Paragraph 1 of a very long story."))
        // The line stands after the last block: in the hierarchy from the
        // start, on screen only at the end.
        let note = element(AccessibilityID.readingCutNote)
        let start = Date()
        var flicks = 0
        let area = readingArea
        let from = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: area.midX, dy: area.midY + 250))
        while !(note.exists && area.intersects(note.frame)), flicks < 400 {
            from.press(forDuration: 0.02, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -500)), withVelocity: 8_000, thenHoldForDuration: 0)
            flicks += 1
        }
        record("a5-scroll", "3,000 blocks scrolled to the end in \(flicks) flicks and \(Int(Date().timeIntervalSince(start))) s")
        XCTAssertEqual(waitFor(note).label, "The rest of this article is on the original page.")
        XCTAssertTrue(area.intersects(note.frame), "the end was not reached in \(flicks) flicks")
        XCTAssertTrue(waitFor(block("Paragraph 3000 of a very long story.")).exists, "the 3,000th block is shown")
        XCTAssertFalse(block("Paragraph 3001 of a very long story.").exists, "the 3,001st is not")
        capture("cut")
        scrollArticle(to: button(AccessibilityID.openOriginalButton)).tap()
        waitForPage("Original of cut-story")
        closeBrowser()
        waitForTitle("Cut story")
    }

    // MARK: - Criterion 7: reading settings

    /// Each setting applies at once to the article behind "Aa", persists
    /// across a relaunch, and is the same in Settings › Reading. Measured as
    /// the line pitch of the same Latin lines.
    func testReadingSettingsApplyAndPersist() {
        launchWithReadingFeed()
        openArticle("Line heights")
        waitFor(block(at: 1))
        let standard: CGFloat = 17 * 1.5
        waitForLatinPitch(standard, "the default size and spacing")
        let titleHeight = readingTitle.frame.height

        openReadingSettings()
        capture("aa")
        XCTAssertEqual(element(AccessibilityID.textSizeValue).value as? String, "3 / 5")
        button(AccessibilityID.textSizeLargerButton).tap()
        waitForLatinPitch(standard * 1.15, "one step larger is 1.15 times, at once")
        XCTAssertEqual(element(AccessibilityID.textSizeValue).value as? String, "4 / 5")
        option("Relaxed").tap()
        waitForLatinPitch(standard * 1.15 * 1.15, "relaxed is 1.15 times, at once")
        option("Serif").tap()
        let serif = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: option("Serif"))
        XCTAssertEqual(XCTWaiter.wait(for: [serif], timeout: timeout), .completed, "Serif was not chosen")
        // The exact line height does not depend on the face.
        waitForLatinPitch(standard * 1.15 * 1.15, "serif keeps the line height")
        closeReadingSettings()
        capture("larger-relaxed-serif")

        // After a relaunch the article is laid out as it was left.
        launchReading()
        openReadingListUnderAll()
        openArticle("Line heights")
        waitFor(block(at: 1))
        waitForLatinPitch(standard * 1.15 * 1.15, "the settings survive a relaunch")

        // Settings › Reading shows what was chosen, and changes it.
        openSettings(row: AccessibilityID.readingSettingsRow)
        waitFor(button(AccessibilityID.textSizeLargerButton))
        XCTAssertEqual(element(AccessibilityID.textSizeValue).value as? String, "4 / 5")
        XCTAssertTrue(option("Relaxed").isSelected, "Relaxed is the chosen spacing")
        XCTAssertTrue(option("Serif").isSelected, "Serif is the chosen face")
        XCTAssertFalse(option("Standard").isSelected)
        capture("settings-reading")
        button(AccessibilityID.textSizeSmallerButton).tap()
        button(AccessibilityID.textSizeSmallerButton).tap()
        XCTAssertEqual(element(AccessibilityID.textSizeValue).value as? String, "2 / 5")
        option("Compact").tap()
        option("Sans Serif").tap()
        goBack()
        openReadingListUnderAll()
        openArticle("Line heights")
        waitFor(block(at: 1))
        waitForLatinPitch(standard * 0.92 * 0.9, "smaller and compact from Settings")
        // The smallest and the largest step end the buttons.
        openReadingSettings()
        button(AccessibilityID.textSizeSmallerButton).tap()
        XCTAssertFalse(button(AccessibilityID.textSizeSmallerButton).isEnabled, "the smallest step")
        waitForLatinPitch(standard * 0.85 * 0.9, "the smallest step")
        for _ in 0..<4 {
            button(AccessibilityID.textSizeLargerButton).tap()
        }
        XCTAssertFalse(button(AccessibilityID.textSizeLargerButton).isEnabled, "the largest step")
        XCTAssertEqual(element(AccessibilityID.textSizeValue).value as? String, "5 / 5")
        waitForLatinPitch(standard * 1.3 * 0.9, "the largest step")
        // The title follows the step as the body does: one line of 22 pt
        // at the default step, of 1.3 times that at the largest.
        let grown = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            abs(self.readingTitle.frame.height / titleHeight - 1.3) < 0.06
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [grown], timeout: timeout), .completed,
                       "the title is \(readingTitle.frame.height) pt high at the largest step and was \(titleHeight) pt at the default")
        closeReadingSettings()
    }

    /// "Aa" on iPhone in landscape, where the screen is lower than the
    /// three sections are high: Close and the first control are on screen,
    /// and every option is reached by scrolling the settings themselves.
    func testReadingSettingsInLandscapeOnPhone() throws {
        try XCTSkipIf(isPad, "the iPhone's landscape: its screen is about 440 pt high")
        launchWithReadingFeed()
        openArticle("Line heights")
        waitFor(block(at: 1))
        rotate(.landscapeLeft)
        addTeardownBlock { @MainActor in
            XCUIDevice.shared.orientation = .portrait
        }
        openReadingSettings()
        capture("aa-landscape")
        let close = button(AccessibilityID.readingSettingsCloseButton)
        XCTAssertTrue(close.isHittable, "Close can be tapped: \(close.frame) in \(window)")
        XCTAssertTrue(window.contains(close.frame), "Close is on screen: \(close.frame) in \(window)")
        let larger = button(AccessibilityID.textSizeLargerButton)
        XCTAssertTrue(larger.isHittable, "the text size can be changed: \(larger.frame)")
        larger.tap()
        XCTAssertEqual(element(AccessibilityID.textSizeValue).value as? String, "4 / 5")
        chooseReadingOption("Relaxed")
        chooseReadingOption("Serif")
        capture("aa-landscape-scrolled")
        XCTAssertTrue(close.isHittable, "Close is still there after scrolling")
        closeReadingSettings()
        waitForTitle("Line heights")
    }

    /// The body scales with Dynamic Type: the same lines stand further
    /// apart in a launch with a larger text size.
    func testBodyScalesWithDynamicType() {
        launchWithReadingFeed()
        openArticle("Line heights")
        waitFor(block(at: 1))
        let standard = latinPitch()
        XCTAssertEqual(standard, 17 * 1.5, accuracy: 1)
        launchReading(arguments: Self.largestText)
        openReadingListUnderAll()
        scrollList(to: "Line heights")
        openArticle("Line heights")
        waitFor(block(at: 1))
        let larger = latinPitch()
        record("dynamic-type", "line pitch \(standard) pt at the default size, \(larger) pt at the largest accessibility size")
        // 17 pt body is 48 pt at the largest accessibility size (measured).
        XCTAssertEqual(larger, 48 * 1.5, accuracy: 2.5)
    }

    // MARK: - Review round 1: the reader's place while an article stays open

    /// In the reading pane the article's page takes the article's place;
    /// when it is closed the article is where it was left, not at its top.
    /// The same after the window changed from panes to tabs and back.
    func testPlaceIsKeptWhileTheArticleStaysOpen() throws {
        try XCTSkipUnless(isPad, "the reading pane and the change of structure are on iPad")
        launchWithReadingFeed()
        openArticle("Cut story")
        waitFor(block("Paragraph 1 of a very long story."))
        for _ in 0..<4 {
            dragArticle(by: -readingArea.height * 0.45)
        }
        let (label, before) = try XCTUnwrap(blockNearTheMiddle(), "no block on screen")
        XCTAssertFalse(block("Paragraph 1 of a very long story.").isHittable, "the article is scrolled from its top")

        // The page in the browser, then Close.
        button(AccessibilityID.readingOriginalBarButton).tap()
        waitForPage("Original of cut-story")
        closeBrowser()
        var after = waitFor(block(label)).frame
        record("place", "\(label): at y \(before.minY) before the browser, \(after.minY) after it was closed")
        XCTAssertEqual(after.minY, before.minY, accuracy: 60, "\(label) is where it was, to a block: \(before) → \(after)")
        XCTAssertFalse(block("Paragraph 1 of a very long story.").isHittable, "the article did not return to its top")
        capture("place-after-browser")

        // Below 700 pt the article is pushed on its list; back above, it
        // is in the reading pane again. Each is a screen built anew.
        resize(below700: true)
        after = waitFor(block(label)).frame
        XCTAssertTrue(window.insetBy(dx: 0, dy: 60).intersects(after), "\(label) is on screen in the tab structure: \(after)")
        XCTAssertFalse(block("Paragraph 1 of a very long story.").isHittable)
        resize(below700: false)
        requireFullSize()
        after = waitFor(block(label)).frame
        XCTAssertTrue(readingArea.insetBy(dx: 0, dy: 60).intersects(after), "\(label) is on screen in the reading pane again: \(after)")
        XCTAssertFalse(block("Paragraph 1 of a very long story.").isHittable)

        // At its very top an article comes back with its header.
        scrollArticleToTop()
        button(AccessibilityID.readingOriginalBarButton).tap()
        waitForPage("Original of cut-story")
        closeBrowser()
        waitForTitle("Cut story")
        XCTAssertTrue(readingTitle.isHittable, "an article left at its top shows its title again")
    }

    /// The text block nearest the middle of the reading area, with its
    /// frame.
    private func blockNearTheMiddle() -> (label: String, frame: CGRect)? {
        let area = readingArea
        let shown = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", AccessibilityID.readingBlockPrefix
        )).allElementsBoundByIndex.map { (label: $0.label, frame: $0.frame) }
        return shown.filter { area.contains($0.frame) }.min { abs($0.frame.midY - area.midY) < abs($1.frame.midY - area.midY) }
    }

    /// Resizes the window across 700 pt, where the structure changes.
    private func resize(below700 below: Bool) {
        var attempts = 0
        while (below ? window.width >= 700 : window.width < 700), attempts < 10 {
            resizeWindow(by: below ? -120 : 120)
            attempts += 1
        }
        XCTAssertEqual(window.width < 700, below, "the window could not be resized across 700 pt")
    }

    // MARK: - Criterion 8: line height

    /// 1.5 times the size for Latin text and 1.7 for Chinese and Japanese,
    /// within 3 %, in the system face and in serif, at the default and the
    /// largest text size: the difference between the same lines at two and
    /// at three lines. (A difference: the frame the system reports for a
    /// text that can be selected is taller than the text by a constant.)
    func testLineHeight() {
        launchWithReadingFeed()
        openArticle("Line heights")
        assertLineHeights(bodySize: 17, face: "system, default size")
        openReadingSettings()
        chooseReadingOption("Serif")
        closeReadingSettings()
        assertLineHeights(bodySize: 17, face: "serif, default size")

        launchReading(arguments: Self.largestText)
        openReadingListUnderAll()
        scrollList(to: "Line heights")
        openArticle("Line heights")
        // 17 pt body is 48 pt at the largest accessibility size (measured).
        assertLineHeights(bodySize: 48, face: "serif, largest size")
        scrollArticleToTop()
        openReadingSettings()
        chooseReadingOption("Sans Serif")
        closeReadingSettings()
        assertLineHeights(bodySize: 48, face: "system, largest size")
        capture("line-heights-largest")
    }

    private func assertLineHeights(bodySize: Double, face: String, file: StaticString = #filePath, line: UInt = #line) {
        for (name, two, factor) in [("Latin", 0, 1.5), ("Chinese", 2, 1.7), ("Japanese", 4, 1.7)] {
            let shorter = scrollArticle(to: block(at: two), file: file, line: line).frame.height
            let taller = scrollArticle(to: block(at: two + 1), file: file, line: line).frame.height
            let pitch = taller - shorter
            let asked = bodySize * factor
            record("line-height", String(format: "%@ | %@ | asked %.2f | two lines %.2f | three lines %.2f | pitch %.2f | off %.1f%%",
                                         face, name, asked, shorter, taller, pitch, (pitch - asked) / asked * 100))
            XCTAssertEqual(pitch, asked, accuracy: asked * 0.03, "\(face), \(name)", file: file, line: line)
        }
    }

    // MARK: - Criterion 9: previous and next

    /// Next from the bottom bar, Previous from the More menu and the swipes
    /// follow the list's order; the new article starts at its top; each is
    /// disabled where the list ends; at the end of the loaded rows the next
    /// page is read.
    func testPreviousAndNext() {
        launchWithReadingFeed(isPad ? .landscapeLeft : .portrait, pageSize: 20)
        addSource(Fixture.longCounting, to: Reading.category)
        openSourceList(Reading.source, in: Reading.category)
        openArticle("Every block")
        let next = waitFor(button(AccessibilityID.readingNextButton))
        let more = waitFor(button(AccessibilityID.readingMoreMenu))
        XCTAssertTrue(next.isEnabled)
        more.tap()
        XCTAssertFalse(waitFor(moreItem("Previous Article")).isEnabled, "nothing before the first row")
        dismissMoreMenu()
        waitForAbsence(moreItem("Previous Article"))

        next.tap()
        waitForTitle("Line heights")
        next.tap()
        waitForTitle("Short note")
        more.tap()
        waitFor(moreItem("Previous Article")).tap()
        waitForTitle("Line heights")
        more.tap()
        waitFor(moreItem("Previous Article")).tap()
        waitForTitle("Every block")

        // Scrolled down, then on: the next article starts at its top.
        dragArticle(by: -400)
        dragArticle(by: -400)
        XCTAssertFalse(readingTitle.exists && readingTitle.isHittable, "the title is scrolled away")
        next.tap()
        waitForTitle("Line heights")
        XCTAssertTrue(readingTitle.isHittable, "the next article starts at its top")
        waitFor(block(at: 0))

        // The swipe towards the leading edge: the next article.
        swipeArticle(towardsLeading: true)
        waitForTitle("Short note")
        if !usesTabs {
            // In the reading pane the other direction is the previous one.
            swipeArticle(towardsLeading: false)
            waitForTitle("Line heights")
            swipeArticle(towardsLeading: true)
            waitForTitle("Short note")
        }
        // A vertical drag is no swipe.
        dragArticle(by: -200)
        dragArticle(by: 200)
        sleep(1)
        waitForTitle("Short note")
        backToList()

        // The last row: nothing after it.
        openArticle("Empty body")
        XCTAssertFalse(waitFor(button(AccessibilityID.readingNextButton)).isEnabled, "nothing after the last row")
        swipeArticle(towardsLeading: true)
        sleep(1)
        waitForTitle("Empty body")
        backToList()

        // 20 rows of the long list are loaded; from the 20th the next page
        // is read and its first row opens.
        openSourceList("Long Counting Feed", in: Reading.category)
        // A row above the fold: scrolling to a later one would show the
        // list's end and read the next page from there.
        openArticle("Long story 06")
        let forward = waitFor(button(AccessibilityID.readingNextButton))
        for number in 7...19 {
            forward.tap()
            waitForTitle(String(format: "Long story %02d", number))
        }
        XCTAssertTrue(forward.isEnabled, "a further page follows the last loaded row")
        forward.tap()
        waitForTitle("Long story 20")
        forward.tap()
        waitForTitle("Long story 21")
    }

    /// A quick horizontal drag in the middle of the article.
    private func swipeArticle(towardsLeading: Bool) {
        let area = readingArea
        let direction: CGFloat = towardsLeading ? -1 : 1
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: area.midX - direction * 120, dy: area.midY))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: direction * 240, dy: 0)), withVelocity: 1_500, thenHoldForDuration: 0)
    }

    // MARK: - Criterion 10: images

    /// An image opens the viewer and Close returns; a small image is not
    /// enlarged and a pixel is not drawn; a failed image shows its
    /// alternative text and is asked for again when the article is opened
    /// again; the images are in the image cache, which Clear empties.
    func testImages() {
        launchWithReadingFeed()
        openArticle("Picture story")
        func image(_ index: Int) -> XCUIElement { element(AccessibilityID.readingImage(index)) }
        func failed(_ index: Int) -> XCUIElement { element(AccessibilityID.readingImageFailed(index)) }
        func placeholder(_ index: Int) -> XCUIElement { element(AccessibilityID.readingImagePlaceholder(index)) }

        let photo = waitFor(image(1))
        XCTAssertEqual(photo.label, "A photograph")
        // 600 pixels wide: the column's width, and never more than 600 pt.
        XCTAssertEqual(photo.frame.width, min(readingArea.width - 32, 600), accuracy: 1, "\(photo.frame)")
        XCTAssertEqual(photo.frame.width / photo.frame.height, 1.5, accuracy: 0.02)

        // 60 × 40 pixels: not drawn larger.
        let small = scrollArticle(to: image(3))
        XCTAssertEqual(small.label, "A small picture")
        XCTAssertEqual(small.frame.width, 60, accuracy: 0.5)
        XCTAssertEqual(small.frame.height, 40, accuracy: 0.5)

        // One pixel: not drawn at all.
        scrollArticle(to: block("A picture that fails once:"))
        waitForAbsence(placeholder(5))
        XCTAssertFalse(image(5).exists)
        XCTAssertFalse(failed(5).exists)
        // Its neighbours stand one line and one gap apart, not two gaps.
        let step = block("A picture that fails once:").frame.minY - block("A pixel:").frame.minY
        XCTAssertEqual(step, 17 * 1.5 + 17 * 0.9, accuracy: 3, "the undrawn image leaves no second gap")

        XCTAssertEqual(scrollArticle(to: failed(7)).label, "A flaky picture", "the alternative text of an image that failed")
        XCTAssertEqual(scrollArticle(to: failed(9)).label, "A vector drawing", "an image the system cannot decode")
        XCTAssertEqual(scrollArticle(to: failed(11)).label, "Image not available", "no alternative text")
        capture("pictures-failed")

        // A long picture (1,080 × 6,000 pixels, lines of text): at the
        // column's width and as tall as its shape asks; in the viewer it
        // zooms until the lines are read.
        let long = scrollArticle(to: image(13), swipes: 40)
        XCTAssertEqual(long.label, "A long picture")
        XCTAssertEqual(long.frame.width, min(readingArea.width - 32, 680), accuracy: 1, "\(long.frame)")
        XCTAssertEqual(long.frame.width / long.frame.height, 1_080.0 / 6_000, accuracy: 0.004, "\(long.frame)")
        // It is taller than the screen, and reached when its top comes in
        // under the bottom bar: brought up until it covers the middle of
        // the screen, which is where it is tapped.
        dragArticle(by: -readingArea.height * 0.45)
        dragArticle(by: -readingArea.height * 0.45)
        let middle = CGPoint(x: readingArea.midX, y: readingArea.midY)
        XCTAssertTrue(long.frame.contains(middle), "the picture covers the middle of the screen: \(long.frame)")
        capture("pictures-long")
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: middle.x, dy: middle.y)).tap()
        let longViewed = waitFor(element(AccessibilityID.imageViewerImage))
        XCTAssertEqual(longViewed.label, "A long picture")
        capture("viewer-long")
        longViewed.pinch(withScale: 6, velocity: 6)
        sleep(1)
        capture("viewer-long-zoomed")
        record("long-picture", "drawn \(long.frame.size) in the body; \(longViewed.frame.size) in the viewer after the pinch, in a window of \(window.size)")
        // How far a pinch of the harness goes differs between devices
        // (5 times on iPhone, 2.8 on iPad): it zoomed, is what is asked.
        XCTAssertGreaterThan(longViewed.frame.height, window.height * 2, "the viewer zooms in: \(longViewed.frame)")
        button(AccessibilityID.imageViewerCloseButton).tap()
        waitForAbsence(longViewed)

        // The viewer.
        scrollArticleToTop()
        capture("pictures")
        photo.tap()
        let viewed = waitFor(element(AccessibilityID.imageViewerImage))
        XCTAssertEqual(viewed.label, "A photograph")
        XCTAssertEqual(viewed.frame.width, window.width, accuracy: 1, "the viewer is full screen")
        capture("viewer")
        let close = waitFor(button(AccessibilityID.imageViewerCloseButton))
        XCTAssertEqual(close.label, "Close")
        XCTAssertGreaterThanOrEqual(close.frame.width, 44)
        close.tap()
        waitForAbsence(viewed)
        waitForTitle("Picture story")

        // Opened again, the image that failed is asked for again. (The
        // fixture's image fails for four seconds from its first request;
        // the viewer alone took longer.)
        sleep(4)
        backToList()
        openArticle("Empty body")
        backToList()
        openArticle("Picture story")
        XCTAssertEqual(scrollArticle(to: image(7)).label, "A flaky picture", "the image that failed is shown at the next opening")
        XCTAssertTrue(scrollArticle(to: failed(9)).exists, "what cannot be decoded still is not")

        // The body's images are in the library's image cache.
        let zero = Int64(0).formatted(.byteCount(style: .file))
        openSettings(row: AccessibilityID.dataRow)
        let size = waitFor(element(AccessibilityID.cacheSize))
        XCTAssertNotEqual(size.label, zero, "the body images are in the image cache")
        record("image-cache", "Settings → Data after the pictures: \(size.label)")
        button(AccessibilityID.clearCacheButton).tap()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", zero), object: size)
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: timeout), .completed, "Clear Image Cache removes them")
    }

    // MARK: - Criterion 12: bars

    func testBars() {
        launchWithReadingFeed()
        openArticle("Every block")
        let star = waitFor(button(AccessibilityID.readingStarButton))
        let share = waitFor(button(AccessibilityID.readingShareButton))
        let original = waitFor(button(AccessibilityID.readingOriginalBarButton))
        let next = waitFor(button(AccessibilityID.readingNextButton))
        let aa = waitFor(button(AccessibilityID.readingSettingsButton))
        let more = waitFor(button(AccessibilityID.readingMoreMenu))
        XCTAssertEqual(star.label, "Star")
        XCTAssertEqual(share.label, "Share")
        XCTAssertEqual(original.label, "Open Original Page")
        XCTAssertEqual(next.label, "Next Article")
        XCTAssertEqual(aa.label, "Reading Settings")
        XCTAssertEqual(more.label, "More")
        // The bottom bar's order: Star, Share, Open Original Page, Next.
        XCTAssertLessThan(star.frame.midX, share.frame.midX)
        XCTAssertLessThan(share.frame.midX, original.frame.midX)
        XCTAssertLessThan(original.frame.midX, next.frame.midX)
        XCTAssertFalse(button(AccessibilityID.hideListButton).exists && usesTabs, "no list to hide in the tab structure")

        more.tap()
        waitFor(moreItem("Previous Article"))
        waitFor(moreItem("Mark as Unread")).tap()
        waitForAbsence(moreItem("Previous Article"))
        more.tap()
        waitFor(moreItem("Mark as Read")).tap()
        waitForAbsence(moreItem("Previous Article"))

        // Each takes a tap anywhere in a 44 pt square around it.
        assertTapTarget(star, "Star", activated: { star.label == "Unstar" }, reset: {
            star.tap()
            let back = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Star'"), object: star)
            _ = XCTWaiter.wait(for: [back], timeout: 5)
        })
        assertTapTarget(aa, "Reading Settings", activated: { [unowned self] in
            button(AccessibilityID.textSizeLargerButton).exists
        }, reset: { [unowned self] in
            closeReadingSettings()
        })
        assertTapTarget(more, "More", activated: { [unowned self] in moreItem("Previous Article").exists }, reset: { [unowned self] in
            dismissMoreMenu()
            waitForAbsence(moreItem("Previous Article"))
        })
        assertTapTarget(original, "Open Original Page", activated: { [unowned self] in
            button(AccessibilityID.browserMoreMenu).exists
        }, reset: { [unowned self] in
            closeBrowser()
            waitForTitle("Every block")
        })
        assertTapTarget(next, "Next Article", activated: { [unowned self] in readingTitle.exists && readingTitle.label == "Line heights" }, reset: { [unowned self] in
            more.tap()
            waitFor(moreItem("Previous Article")).tap()
            waitForTitle("Every block")
        })
        capture("bars")
        backToList()

        // An article without a link has no link actions.
        openArticle("Cut linkless story")
        waitFor(button(AccessibilityID.readingStarButton))
        waitFor(button(AccessibilityID.readingNextButton))
        XCTAssertFalse(button(AccessibilityID.readingShareButton).exists)
        XCTAssertFalse(button(AccessibilityID.readingOriginalBarButton).exists)
        XCTAssertFalse(button(AccessibilityID.openOriginalButton).exists)
    }

    // MARK: - Criterion 13: hiding the list

    /// At a two-column width the list can be hidden and shown again, the
    /// sidebar opens from the reading pane while it is hidden, the list is
    /// where it was, and the state resets with the selection and the layout.
    func testHidingTheList() throws {
        try XCTSkipUnless(isPad, "two columns on iPad")
        // Portrait: 834 pt, panes with the sidebar sliding over.
        launchWithReadingFeed(.portrait)
        addSource(Fixture.longCounting, to: Reading.category)
        openSourceList("Long Counting Feed", in: Reading.category)
        waitFor(articleRow("Long story 01"))
        // No article open: nothing to hide the list for.
        XCTAssertFalse(button(AccessibilityID.hideListButton).exists)
        // Scrolled, so that "where it was" is not the top.
        let anchor = waitFor(articleRow("Long story 05"))
        let point = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: anchor.frame.midX, dy: window.midY + 150))
        point.press(forDuration: 0.1, thenDragTo: point.withOffset(CGVector(dx: 0, dy: -300)), withVelocity: .slow, thenHoldForDuration: 0.5)
        let top = try XCTUnwrap(articleRowsShown().first { $0.isHittable })
        let topTitle = top.identifier
        let topY = top.frame.minY
        waitFor(articleRow("Long story 09")).tap()
        waitForTitle("Long story 09")
        let listWidth = element(AccessibilityID.listPane).frame.width
        XCTAssertGreaterThan(listWidth, 250)
        let titleX = readingTitle.frame.minX

        let hide = waitFor(button(AccessibilityID.hideListButton))
        XCTAssertEqual(hide.label, "Hide Article List")
        XCTAssertGreaterThanOrEqual(max(hide.frame.width, hide.frame.height), 36)
        capture("list-shown")
        hide.tap()
        waitForLabel(hide, containing: "Show Article List")
        // The article is read at full width.
        XCTAssertEqual(element(AccessibilityID.readingPane).frame.width, window.width, accuracy: 1)
        XCTAssertLessThan(readingTitle.frame.minX, titleX - 100)
        XCTAssertFalse(articleRow("Long story 09").isHittable, "the list is hidden")
        capture("list-hidden")
        // The sidebar is reachable from the reading pane.
        let sidebar = waitFor(button(AccessibilityID.showSidebarButton))
        XCTAssertTrue(sidebar.isHittable)
        sidebar.tap()
        waitFor(element(AccessibilityID.slideOverPanel))
        waitFor(button(AccessibilityID.closeSidebarButton)).tap()
        waitForAbsence(element(AccessibilityID.slideOverPanel))
        waitForLabel(hide, containing: "Show Article List")
        // The bottom bar's Next still opens the next article.
        button(AccessibilityID.readingNextButton).tap()
        waitForTitle("Long story 10")
        waitForLabel(hide, containing: "Show Article List")

        // Shown again, the list is where it was.
        hide.tap()
        waitForLabel(hide, containing: "Hide Article List")
        XCTAssertEqual(element(AccessibilityID.listPane).frame.width, listWidth, accuracy: 1)
        let shownAgain = try XCTUnwrap(articleRowsShown().first { $0.isHittable })
        XCTAssertEqual(shownAgain.identifier, topTitle, "the same row is at the top")
        XCTAssertEqual(shownAgain.frame.minY, topY, accuracy: 1)

        // Another sidebar selection shows its list, also one that has an
        // article open: Starred, with the article starred here.
        button(AccessibilityID.readingStarButton).tap()
        waitForLabel(button(AccessibilityID.readingStarButton), containing: "Unstar")
        openStarred()
        openArticle("Long story 10")
        openSourceList("Long Counting Feed", in: Reading.category)
        waitFor(articleRow("Long story 11")).tap()
        waitForTitle("Long story 11")
        waitFor(button(AccessibilityID.hideListButton)).tap()
        waitForLabel(button(AccessibilityID.hideListButton), containing: "Show Article List")
        openStarred()
        waitForTitle("Long story 10")
        XCTAssertEqual(waitFor(button(AccessibilityID.hideListButton)).label, "Hide Article List", "Starred shows its list")
        XCTAssertTrue(waitFor(articleRow("Long story 10")).isHittable)

        // And a selection with nothing open.
        openSourceList("Long Counting Feed", in: Reading.category)
        waitFor(articleRow("Long story 12")).tap()
        waitForTitle("Long story 12")
        waitFor(button(AccessibilityID.hideListButton)).tap()
        waitForLabel(button(AccessibilityID.hideListButton), containing: "Show Article List")
        openSourceList(Reading.source, in: Reading.category)
        waitFor(articleRow("Every block"))
        XCTAssertTrue(articleRow("Every block").isHittable, "a new selection shows its list")
        XCTAssertFalse(button(AccessibilityID.hideListButton).exists, "no article open")

        // Leaving two columns shows the list, and the button is absent at
        // three columns.
        openArticle("Short note")
        waitFor(button(AccessibilityID.hideListButton)).tap()
        waitForLabel(button(AccessibilityID.hideListButton), containing: "Show Article List")
        rotate(.landscapeLeft)
        waitFor(element(AccessibilityID.sidebarPane))
        waitForAbsence(button(AccessibilityID.hideListButton))
        XCTAssertTrue(waitFor(articleRow("Short note")).isHittable, "three columns show the list")
        waitForTitle("Short note")
        rotate(.portrait)
        waitForAbsence(element(AccessibilityID.sidebarPane))
        XCTAssertEqual(waitFor(button(AccessibilityID.hideListButton)).label, "Hide Article List", "back at two columns the list is shown")
        XCTAssertTrue(waitFor(articleRow("Short note")).isHittable)
    }

    // MARK: - Criterion 14: an open article that no longer exists

    /// The retention clean-up removes the open article when the app is
    /// entered again: the reading pane says so; the reading screen pushed on
    /// its list is popped.
    func testOpenArticleRemovedByCleanUp() {
        launchWithReadingFeed()
        openSettings(row: AccessibilityID.refreshRow)
        scrollTo(option("Forever")).tap()
        // 20 days later, kept so far.
        app.terminate()
        launch(clockOffsetDays: 20)
        rotate(.portrait)
        requireFullSize()
        openSettings(row: AccessibilityID.refreshRow)
        // Takes effect when the app is next entered.
        scrollTo(option("7 Days")).tap()
        goBack()
        openCategoryList(Reading.category)
        chooseFilter("All")
        openArticle("Short note")
        waitFor(block("A short note with one bold word and nothing more."))
        let tabs = usesTabs

        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        if tabs {
            // Popped: the list it was pushed on.
            waitForAbsence(readingTitle)
            waitFor(app.navigationBars[Reading.category])
            XCTAssertFalse(button(AccessibilityID.readingNextButton).exists)
            XCTAssertFalse(element(AccessibilityID.articleUnavailable).exists)
        } else {
            XCTAssertEqual(waitFor(element(AccessibilityID.articleUnavailable)).label, "This article is no longer available.")
            XCTAssertFalse(readingTitle.exists)
        }
        waitForAbsence(articleRow("Short note"))
        screenshot("article-gone-after-clean-up")
    }

    /// Deleting the open article's source: the reading pane says that the
    /// article is no longer available. (With the reading screen pushed on
    /// its list no source can be reached, so the tab structure has no such
    /// path; `testOpenArticleRemovedByCleanUp` is its case.)
    func testDeletingTheOpenArticlesSource() throws {
        try XCTSkipUnless(isPad, "a source cannot be deleted from a pushed reading screen")
        launchWithReadingFeed(.landscapeLeft)
        openCategoryList(Reading.category)
        openArticle("Short note")
        waitFor(block("A short note with one bold word and nothing more."))
        expand(Reading.category)
        waitFor(sourceRow(Reading.source)).press(forDuration: 1.2)
        waitFor(menuButton("Source Settings")).tap()
        waitFor(app.textFields[AccessibilityID.nameField])
        scrollTo(button(AccessibilityID.deleteSourceButton)).tap()
        waitFor(app.buttons.matching(NSPredicate(
            format: "label == 'Delete Source' AND identifier != %@", AccessibilityID.deleteSourceButton
        )).firstMatch).tap()
        waitForAbsence(app.textFields[AccessibilityID.nameField])
        XCTAssertEqual(waitFor(element(AccessibilityID.articleUnavailable)).label, "This article is no longer available.")
        XCTAssertFalse(readingTitle.exists)
        XCTAssertFalse(articleRow("Short note").exists, "its row left the list")
        capture("article-no-longer-available")
    }
}
