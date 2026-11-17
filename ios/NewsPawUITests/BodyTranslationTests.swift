import XCTest

/// RD15 (ux S4, S5, S8; spec N05, N06, N11): the body translated when an
/// article opens, chunk by chunk; leaving and returning; stored failures,
/// the banner and its steps; no model set up; Translate with the setting
/// off; model text as plain text; reader mode; Article Info. Criteria 3, 5,
/// 8, 10, 11, 12, 14 and 16 (UI), on the translator fixture.
final class BodyTranslationTests: BodyTranslationTestCase {
    /// Criterion 3: leaving at "Translating 3 of 8" and returning resumes
    /// at chunk 4 without resending the first three; the body requests go
    /// 4 → 9 and stay at 9 on a third opening.
    func testLeavingAndResuming() {
        launchWithBodies()
        openBody(Body.long)
        // Chunk 4 stalls on its first request.
        waitForProgress("Translating 3 of 8")
        waitForBlock(0, startingWith: Translation.translated(Body.paragraph(1, of: Body.long)))
        XCTAssertFalse(banner.exists)
        _ = scrollArticle(to: block(at: 6))
        waitForBlock(5, startingWith: Translation.translated(Body.paragraph(6, of: Body.long)))
        XCTAssertTrue(block(at: 6).label.hasPrefix(Body.paragraph(7, of: Body.long)), block(at: 6).label)
        // Work runs: the mode menu, not Translate.
        XCTAssertTrue(modeMenu.exists)
        XCTAssertFalse(translateButton.exists)

        leaveArticle()
        // Chunk 4's cancelled request is a usage row of its own.
        expectBodyRequests(4, "left during chunk 4")

        openBody(Body.long)
        // The first three chunks are shown at once.
        waitForBlock(0, startingWith: Translation.translated(Body.paragraph(1, of: Body.long)))
        expectBodyRequests(9, "returned: chunks 4–8")
        waitForAbsence(progressLine)
        _ = scrollArticle(to: block(at: 15))
        waitForBlock(15, startingWith: Translation.translated(Body.paragraph(16, of: Body.long)))

        leaveArticle()
        openBody(Body.long)
        waitForBlock(0, startingWith: Translation.translated(Body.paragraph(1, of: Body.long)))
        expectBodyRequests(9, "a third opening sends nothing", settle: 3)
        XCTAssertFalse(progressLine.exists)
    }

    /// Review round 2 (G1): the app going to the background stops the
    /// shown body's work as leaving its screen does. At "Translating 3 of
    /// 8" chunk 4 is in flight (it stalls for 60 seconds); Home cancels it
    /// — a usage row of its own — and the return resumes at chunk 4: the
    /// body requests end at 9 (chunks 1–3, chunk 4 cancelled, chunks 4–8),
    /// and the first three are not sent again. Kept running in the
    /// background, the stalled request would have been answered after the
    /// return and the requests would end at 8.
    func testBackgroundStopsTheWork() {
        launchWithBodies()
        openBody(Body.long)
        waitForProgress("Translating 3 of 8")
        expectBodyRequests(3, "chunks 1–3 answered, chunk 4 stalled", settle: 0)

        XCUIDevice.shared.press(.home)
        let backgrounded = app.wait(for: .runningBackground, timeout: 10) || app.wait(for: .runningBackgroundSuspended, timeout: 5)
        XCTAssertTrue(backgrounded, "the app did not go to the background: \(app.state.rawValue)")
        Thread.sleep(forTimeInterval: 3)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: timeout))

        waitForBlock(0, startingWith: Translation.translated(Body.paragraph(1, of: Body.long)))
        expectBodyRequests(9, "returned: chunk 4 cancelled, chunks 4–8 sent once")
        waitForAbsence(progressLine)
        _ = scrollArticle(to: block(at: 15))
        waitForBlock(15, startingWith: Translation.translated(Body.paragraph(16, of: Body.long)))

        leaveArticle()
        openBody(Body.long)
        waitForBlock(0, startingWith: Translation.translated(Body.paragraph(1, of: Body.long)))
        expectBodyRequests(9, "opened again: nothing sent", settle: 3)
    }

    /// Review round 3 (K1): a plan that finishes while the app is in the
    /// background starts nothing there. The first plan is held until the
    /// app is in the background (a debug hold under the UI tests) and
    /// finishes there a second later; no job starts and no body request is
    /// sent until the app returns. Then the plan made in the background is
    /// used: the body is translated with each of its eight chunks sent once
    /// (chunk 4 stalls for 60 seconds on its first request).
    func testPlanFinishingInTheBackgroundStartsNothing() {
        launchWithBodies(environment: [UITestLaunchKey.holdFirstBodyPlan: "1"])
        openBody(Body.long)
        // Planning is held: nothing runs.
        expectBodyRequests(0, "planning held", settle: 1)
        XCTAssertFalse(progressLine.exists)

        XCUIDevice.shared.press(.home)
        let backgrounded = app.wait(for: .runningBackground, timeout: 10) || app.wait(for: .runningBackgroundSuspended, timeout: 5)
        XCTAssertTrue(backgrounded, "the app did not go to the background: \(app.state.rawValue)")
        // The plan finishes a second after the background is entered.
        Thread.sleep(forTimeInterval: 5)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: timeout))
        XCTAssertEqual(bodyStartsInBackground, 0, "a body job started while the app was in the background")

        waitForBlock(0, startingWith: Translation.translated(Body.paragraph(1, of: Body.long)))
        expectBodyRequests(8, "each chunk sent once", timeout: 150)
        waitForAbsence(progressLine)
        _ = scrollArticle(to: block(at: 15))
        waitForBlock(15, startingWith: Translation.translated(Body.paragraph(16, of: Body.long)))
        XCTAssertEqual(bodyStartsInBackground, 0)
    }

    /// Review round 4 (L1): a slot change while reader mode's temporary
    /// article is open keeps its translations (it has no rows to read them
    /// from again): nothing is sent again and the translated text stays.
    /// The article under it is planned again from its rows and sends
    /// nothing either. Settings cannot be reached with a temporary article
    /// open (every way there ends the browser's session), so the slot
    /// change is the debug stand-in for Settings' save, the same call.
    func testSlotChangeKeepsReaderModeTranslation() {
        launchTranslating()
        addFeed("https://fulltext.example.invalid/rss.xml", to: "World")
        openBody("Fetched story")
        waitFor(element(AccessibilityID.readingFullTextNote))
        waitForBlock(0, startingWith: "译[zh-Hans]：")
        waitFor(button(AccessibilityID.readingOriginalBarButton)).tap()
        waitForPage("The ferry at dawn")
        let reader = button(AccessibilityID.browserReaderButton)
        waitForEnabled(reader, true)
        reader.tap()
        let text = block(containing: "译[zh-Hans]：The harbour office posts the tide tables")
        waitFor(text)
        let translated = settledBodyRequests()
        XCTAssertGreaterThan(translated, 0)

        let slotsChanged = app.buttons[DebugAccessibilityID.slotsChangedButton]
        XCTAssertTrue(slotsChanged.waitForExistence(timeout: timeout))
        slotsChanged.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        expectBodyRequests(translated, "the slots changed: reader mode sends nothing again", settle: 4)
        XCTAssertTrue(text.exists, "the temporary article's translation is gone")

        // The article under it: its rows hold every text.
        button(AccessibilityID.readerCloseButton).tap()
        waitForAbsence(element(AccessibilityID.readerTitle))
        closeBrowser()
        waitForBlock(0, startingWith: "译[zh-Hans]：")
        expectBodyRequests(translated, "the article sends nothing again", settle: 3)
    }

    /// Review round 4 (L2): the only chunk is accepted and shown, but its
    /// rows cannot be written (the first write fails, a debug seam): the
    /// banner says so, with Retry. Retry writes the accepted texts — it
    /// sends nothing — and the banner goes; the next opening reads them
    /// and sends nothing either.
    func testRetryStoresWhatCouldNotBeWritten() {
        launchWithBodies(environment: [UITestLaunchKey.failFirstBodyWrite: "1"])
        openBody(Body.markup)
        let translated = Translation.translated(Body.markupParagraph)
        waitForBlock(0, translated)
        waitForBanner("Some text could not be translated · The change could not be saved.")
        expectBodyRequests(1, "one chunk, accepted, not stored")

        waitFor(button(AccessibilityID.bodyBannerRetry)).tap()
        waitForAbsence(banner)
        expectBodyRequests(1, "Retry writes the accepted texts and sends nothing", settle: 3)
        waitForBlock(0, translated)

        leaveArticle()
        openBody(Body.markup)
        waitForBlock(0, translated)
        expectBodyRequests(1, "stored: the next opening sends nothing", settle: 3)
        XCTAssertFalse(banner.exists)
    }

    /// The body requests once they stop growing (two readings 1.5 s apart).
    private func settledBodyRequests() -> Int {
        var last = -1
        for _ in 0..<40 {
            let now = bodyRequests
            if now == last, now > 0 {
                return now
            }
            last = now
            Thread.sleep(forTimeInterval: 1.5)
        }
        return last
    }

    /// Criteria 5 and 8: a refused paragraph is stored failed; the rest
    /// goes on; leaving during chunk 4 and returning sends chunks 4–8 and
    /// not chunk 2's failure; the banner stays while the failure is stored;
    /// Retry sends only the failed paragraph (twice: once more as itself);
    /// Retry with the Backup Model sends it once to the backup.
    func testStoredFailureAndRetry() {
        launchWithBodies(models: "primary,backup")
        openBody(Body.refused)
        // Chunks 1 and 3 are finished, chunk 2 half failed, chunk 4 stalls.
        waitForProgress("Translating 2 of 8")
        waitForBanner(BodySentence.refused)
        XCTAssertEqual(bannerSteps(), ["Retry", "Retry with the Backup Model"])
        // The failed paragraph keeps its original in place; its neighbour
        // in the same chunk is translated.
        XCTAssertTrue(block(at: 2).label.hasPrefix(Body.paragraph(3, of: Body.refused)), block(at: 2).label)
        waitForBlock(3, startingWith: Translation.translated(Body.paragraph(4, of: Body.refused)))
        // Chunk 1, chunk 2 and its two halves, chunk 3.
        leaveArticle()
        expectBodyRequests(6, "left during chunk 4")

        openBody(Body.refused)
        expectBodyRequests(11, "returned: chunks 4–8, not chunk 2's failure")
        waitForAbsence(progressLine)
        waitForBanner(BodySentence.refused)
        XCTAssertTrue(block(at: 2).label.hasPrefix(Body.paragraph(3, of: Body.refused)), block(at: 2).label)
        screenshot("RD15 banner after a refusal")

        // Retry: only the failed paragraph, refused again.
        waitFor(button(AccessibilityID.bodyBannerRetry)).tap()
        expectBodyRequests(13, "Retry sends the failed paragraph, and once more as itself")
        waitForBanner(BodySentence.refused)
        // Retry with the Backup Model: once, refused by the backup too.
        waitFor(button(AccessibilityID.bodyBannerRetryBackup)).tap()
        expectBodyRequests(14, "Retry with the Backup Model sends it once")
        waitForBanner(BodySentence.refused)
    }

    /// Criterion 5: the primary refuses a paragraph; Retry with the Backup
    /// Model translates it, and the banner goes.
    func testRetryWithTheBackupModel() {
        launchWithBodies(models: "primary,backup")
        openBody(Body.primaryRefuses)
        waitForBanner(BodySentence.refused)
        waitForBlock(1, startingWith: Translation.translated(Body.paragraph(2, of: Body.primaryRefuses)))
        XCTAssertTrue(block(at: 0).label.hasPrefix(Body.paragraph(1, of: Body.primaryRefuses)), block(at: 0).label)
        // Chunk 1 and its two halves, chunk 2.
        expectBodyRequests(4, "the first opening")
        waitFor(button(AccessibilityID.bodyBannerRetryBackup)).tap()
        waitForBlock(0, startingWith: Translation.translated(Body.paragraph(1, of: Body.primaryRefuses)))
        waitForAbsence(banner)
        expectBodyRequests(5, "one request to the backup")
    }

    /// Criterion 8: a service failure without a backup stops the work with
    /// nothing stored: the chunks already done are shown, the rest keeps
    /// its originals, the banner says why with Retry; Retry sends only the
    /// missing chunks.
    func testServiceFailureAndRetry() {
        launchWithBodies()
        openBody(Body.flaky)
        waitForBanner(BodySentence.unreachable)
        XCTAssertEqual(bannerSteps(), ["Retry"])
        waitForBlock(0, startingWith: Translation.translated(Body.paragraph(1, of: Body.flaky)))
        XCTAssertTrue(block(at: 2).label.hasPrefix(Body.paragraph(3, of: Body.flaky)), block(at: 2).label)
        expectBodyRequests(2, "chunk 1, then chunk 2's failure")
        XCTAssertFalse(progressLine.exists)
        button(AccessibilityID.bodyBannerRetry).tap()
        expectBodyRequests(4, "Retry: the two missing chunks only")
        waitForAbsence(banner)
        waitForBlock(2, startingWith: Translation.translated(Body.paragraph(3, of: Body.flaky)))
    }

    /// Criterion 10: with no model set up an English article shows its
    /// originals and the banner, whose Open Settings opens Models &
    /// Translation; a Chinese article (reading language Simplified Chinese)
    /// shows no banner.
    func testNoModelSetUp() {
        launchWithBodies(models: "")
        openBody(Body.chinese)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(banner.exists)
        XCTAssertFalse(translateButton.exists)
        XCTAssertFalse(modeMenu.exists)
        leaveArticle()

        openBody(Body.many)
        waitForBanner(BodySentence.noModel)
        XCTAssertEqual(bannerSteps(), ["Open Settings"])
        XCTAssertTrue(block(at: 0).label.hasPrefix("Short paragraph 1."), block(at: 0).label)
        XCTAssertEqual(bodyRequests, 0)
        button(AccessibilityID.bodyBannerOpenSettings).tap()
        waitFor(element(AccessibilityID.primaryModelRow))
    }

    /// Criterion 11: with "Translate Articles When Opened" off the bar
    /// shows Translate and nothing is sent until it is tapped; the tap
    /// translates the body and, for a source with automatic titles off,
    /// the title with one manual request.
    func testTranslateWhenTapped() {
        launchTranslating()
        openTranslationSettings()
        let onOpen = scrollTo(app.switches[AccessibilityID.translateBodyOnOpenToggle])
        XCTAssertEqual(onOpen.value as? String, "1")
        flip(onOpen)
        // The source follows the global switch: automatic titles off.
        flip(app.switches[AccessibilityID.autoTranslateToggle])
        addFeed(Body.feed, to: Body.category)
        openBody(Body.markup)
        waitFor(translateButton)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(bodyRequests, 0)
        let before = translatorRequests
        XCTAssertEqual(readingTitle.label, Body.markup)

        translateButton.tap()
        waitForTitle(Translation.translated(Body.markup))
        waitForBlock(0, Translation.translated(Body.markupParagraph))
        expectBodyRequests(1, "the body, one chunk")
        XCTAssertEqual(translatorRequests - before, 2, "the body's request and one title request")
        XCTAssertEqual(element(AccessibilityID.readingOriginalTitle).label, Body.markup)
        waitFor(modeMenu)
        XCTAssertFalse(translateButton.exists)
    }

    /// Criterion 12: a translation holding Markdown, an HTML link and a
    /// `javascript:` address is shown literally, with no link; Copy
    /// Translation is enabled once something is translated.
    func testModelTextIsPlainText() {
        launchWithBodies()
        openBody(Body.markup)
        let translated = Translation.translated(Body.markupParagraph)
        waitForBlock(0, translated)
        XCTAssertEqual(block(at: 0).links.count, 0, "a link was made of the model's text")
        XCTAssertEqual(app.links.matching(NSPredicate(format: "label CONTAINS %@", "link")).count, 0)

        // Side by Side: the original under it, with its text as it is.
        chooseMode("side_by_side")
        waitForBlock(0, translated)
        XCTAssertEqual(element(AccessibilityID.readingOriginalBlock(0)).label, Body.markupParagraph)
        XCTAssertEqual(block(at: 0).links.count, 0)

        // Copy Translation is enabled once something is translated (its
        // text, verbatim, is the package's `copyIsVerbatim`; the runner does
        // not read the pasteboard, which every booted simulator shares).
        waitFor(button(AccessibilityID.readingMoreMenu)).tap()
        let copy = waitFor(button(AccessibilityID.copyTranslationButton))
        XCTAssertTrue(copy.isEnabled)
        copy.tap()
        waitForAbsence(button(AccessibilityID.copyTranslationButton))
    }

    /// Criterion 16 (UI): Copy Translation is disabled with nothing
    /// translated; Article Info shows where the body came from and the
    /// title's and the body's translations.
    func testArticleInfo() {
        launchWithBodies(models: "")
        openBody(Body.long)
        waitForBanner(BodySentence.noModel)
        waitFor(button(AccessibilityID.readingMoreMenu)).tap()
        XCTAssertFalse(waitFor(button(AccessibilityID.copyTranslationButton)).isEnabled)
        waitFor(button(AccessibilityID.articleInfoButton)).tap()
        XCTAssertEqual(waitFor(element(AccessibilityID.articleInfoBody)).label, "From the feed")
        XCTAssertEqual(element(AccessibilityID.articleInfoTitle).label, "Not translated")
        XCTAssertEqual(element(AccessibilityID.articleInfoTranslation).label, "Not translated")
        waitFor(button(AccessibilityID.articleInfoDoneButton)).tap()
        waitForAbsence(element(AccessibilityID.articleInfoBody))

        // Translated: the models and the time. The same library, now with
        // the translator's model.
        launchTranslating()
        openCategoryList(Body.category)
        // A full text of four chunks.
        openBody(Body.many)
        waitForBlock(0, startingWith: Translation.translated("Short paragraph 1."))
        waitForAbsence(progressLine)
        waitForTitle(Translation.translated(Body.many))
        waitFor(button(AccessibilityID.readingMoreMenu)).tap()
        waitFor(button(AccessibilityID.articleInfoButton)).tap()
        XCTAssertEqual(waitFor(element(AccessibilityID.articleInfoBody)).label, "From the feed")
        waitForLabel(element(AccessibilityID.articleInfoTitle), containing: "Translated by fixture-translator · ")
        XCTAssertTrue(element(AccessibilityID.articleInfoTranslation).label.hasPrefix("Translated by fixture-translator · "),
                      element(AccessibilityID.articleInfoTranslation).label)
        screenshot("RD15 Article Info")
        waitFor(button(AccessibilityID.articleInfoDoneButton)).tap()

        // An excerpt: "Only an excerpt is available".
        backToList()
        openBody(Body.short)
        waitFor(button(AccessibilityID.readingMoreMenu)).tap()
        waitFor(button(AccessibilityID.articleInfoButton)).tap()
        XCTAssertEqual(waitFor(element(AccessibilityID.articleInfoBody)).label, "Only an excerpt is available")
        waitFor(button(AccessibilityID.articleInfoDoneButton)).tap()
    }

    /// Criterion 16 (UI): the full text from the page: its host and its
    /// fetch time.
    func testArticleInfoOfAFullText() {
        launchTranslating()
        addFeed("https://fulltext.example.invalid/rss.xml", to: "World")
        openBody("Fetched story")
        waitFor(element(AccessibilityID.readingFullTextNote))
        waitFor(button(AccessibilityID.readingMoreMenu)).tap()
        waitFor(button(AccessibilityID.articleInfoButton)).tap()
        XCTAssertEqual(waitFor(element(AccessibilityID.articleInfoBody)).label, "Full text from the original page")
        waitFor(app.staticTexts["fulltext.example.invalid"])
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Fetched '")).firstMatch.exists)
        waitFor(button(AccessibilityID.articleInfoDoneButton)).tap()
    }

    /// Criterion 14: reader mode's temporary article is translated under
    /// the same setting, title included; it is translated again when it
    /// is closed and opened again (the body requests grow).
    func testReaderModeIsTranslated() {
        launchTranslating()
        addFeed("https://fulltext.example.invalid/rss.xml", to: "World")
        openBody("Fetched story")
        waitFor(element(AccessibilityID.readingFullTextNote))
        // The article itself: an English full text, translated.
        waitForBlock(0, startingWith: "译[zh-Hans]：")
        let afterArticle = bodyRequests
        XCTAssertGreaterThan(afterArticle, 0)
        waitFor(button(AccessibilityID.readingOriginalBarButton)).tap()
        waitForPage("The ferry at dawn")
        let reader = button(AccessibilityID.browserReaderButton)
        waitForEnabled(reader, true)
        reader.tap()
        let title = element(AccessibilityID.readerTitle)
        // The extraction's title: "The ferry at dawn - Harbour News".
        let translatedTitle = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", Translation.translated("The ferry at dawn")), object: title
        )
        XCTAssertEqual(XCTWaiter.wait(for: [translatedTitle], timeout: 60), .completed, title.exists ? title.label : "no title")
        XCTAssertTrue(element(AccessibilityID.readingOriginalTitle).label.hasPrefix("The ferry at dawn"))
        waitFor(block(containing: "译[zh-Hans]：The harbour office posts the tide tables"))
        let firstOpening = bodyRequests
        XCTAssertGreaterThan(firstOpening, afterArticle, "reader mode's requests are usage rows")
        // The bar: Close, the mode menu, Share, "Aa".
        XCTAssertTrue(modeMenu.exists)
        screenshot("RD15 reader mode translated")

        button(AccessibilityID.readerCloseButton).tap()
        waitForAbsence(title)
        waitForEnabled(reader, true)
        reader.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", Translation.translated("The ferry at dawn")), object: title
        )], timeout: 60), .completed)
        expectBodyRequests(firstOpening + (firstOpening - afterArticle), "opened again: translated again")
    }

    /// Review R2 (fix round 1): an excerpt put in as the body is pre-filled
    /// from RD14's row of the opening's own language. After a change to
    /// Japanese the open article never shows the Chinese excerpt as its
    /// body; it shows the Japanese one, pre-filled or sent. (Which of the
    /// two depends on whether RD14's Japanese row is stored before the
    /// body is planned; the ordering the review describes cannot be held
    /// from a UI test.)
    func testExcerptBodyFollowsTheReadingLanguage() {
        launchWithBodies()
        openBody(Body.excerptOnly)
        waitForBlock(0, Translation.translated(Body.excerptOnlyText))
        // Pre-filled from RD14's row: nothing sent for the body.
        expectBodyRequests(0, "the excerpt is RD14's translation")
        openTranslationSettings()
        option("Japanese").tap()
        let chosen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: option("Japanese"))
        XCTAssertEqual(XCTWaiter.wait(for: [chosen], timeout: timeout), .completed)
        openCategoryList(Body.category)
        chooseFilter("All")
        openBody(Body.excerptOnly)
        waitForBlock(0, Translation.translated(Body.excerptOnlyText, "ja"))
        XCTAssertFalse(block(at: 0).label.contains("译[zh-Hans]"), block(at: 0).label)
        record("R2 body requests after the change", "\(bodyRequests)")
    }

    /// Criterion 17: changing the reading language shows nothing of the
    /// old one and translates the open article in the new one.
    func testReadingLanguageChange() {
        launchWithBodies()
        openBody(Body.markup)
        waitForBlock(0, Translation.translated(Body.markupParagraph))
        openTranslationSettings()
        option("Japanese").tap()
        let chosen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: option("Japanese"))
        XCTAssertEqual(XCTWaiter.wait(for: [chosen], timeout: timeout), .completed)
        openCategoryList(Body.category)
        chooseFilter("All")
        openBody(Body.markup)
        waitForBlock(0, Translation.translated(Body.markupParagraph, "ja"))
        XCTAssertFalse(block(at: 0).label.contains("译[zh-Hans]"))
        // Back to Simplified Chinese: the kept rows show, nothing is sent.
        let before = bodyRequests
        openTranslationSettings()
        option("Simplified Chinese").tap()
        openCategoryList(Body.category)
        chooseFilter("All")
        openBody(Body.markup)
        waitForBlock(0, Translation.translated(Body.markupParagraph))
        expectBodyRequests(before, "the Chinese rows were kept")
    }
}
