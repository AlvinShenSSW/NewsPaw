import XCTest

/// RD23 in the app (criteria 2, 6, 8, 10, 11, 15, 17, 18, 19): Today's
/// cards and the list's card written through the translator fixture, a
/// highlight opening its article, Earlier Overviews, the Overviews
/// setting, the reading language, and the states of a card.
final class OverviewTests: OverviewTestCase {
    /// Criteria 15, 18 and 19: written after the collection that brings
    /// the articles; on Today with two highlights (the out-of-range one
    /// dropped), the footnote and the not-verification line, the HTML and
    /// Markdown of a title shown literally; a highlight opens its article,
    /// which reads as read; the list's card collapsed, expanded, Earlier
    /// Overviews; after Mark All as Read the card and "All caught up" both.
    func testAutomatic() {
        launchOverviews()
        addFeed(Translation.feed, to: Translation.category)
        // Seeded once the category exists: the earlier overviews.
        launchOverviews(seed: true)
        refreshRun(in: Translation.category)
        let world = Translation.category
        waitForText(summary(world), Overview.summary(40, Translation.markup))
        XCTAssertTrue(summary(world).label.contains("<b>bold</b> **stars** [a link](https://example.invalid)"), summary(world).label)
        waitForText(highlight(1, world), Overview.highlight(Translation.markup))
        waitForText(highlight(2, world), Overview.highlight(Translation.simplified))
        XCTAssertFalse(highlight(3, world).exists, "the highlight out of range is dropped")
        waitForText(part("footnote", world), Overview.footnote(40))
        XCTAssertEqual(part("note", world).label, Overview.note)

        // A highlight opens its article through the reading model.
        highlight(2, world).tap()
        waitForTitle(Translation.simplified)
        backToList()
        waitFor(app.navigationBars[world])
        chooseFilter("All")
        waitForUnread(scrollList(to: Translation.simplified), false)

        // The list's card: collapsed, expanded, Earlier Overviews.
        openCategoryList(world)
        let listCard = waitFor(card(world))
        waitForText(summary(world), Overview.summary(40, Translation.markup))
        XCTAssertFalse(part("note", world).exists, "collapsed: two lines and Expand")
        button(AccessibilityID.overview("expand", world)).tap()
        waitFor(part("note", world))
        waitFor(highlight(2, world))
        button(AccessibilityID.overview("earlier", world)).tap()
        waitFor(element(AccessibilityID.earlierOverviewsList))
        for days in 1...3 {
            waitFor(element(AccessibilityID.earlierOverview(dayKey(daysBefore: days))))
        }
        XCTAssertTrue(app.staticTexts["Earlier overview 1 day(s) ago."].exists)
        XCTAssertGreaterThanOrEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", Overview.note)).count, 1)
        button(AccessibilityID.earlierOverviewsDoneButton).tap()
        waitForAbsence(element(AccessibilityID.earlierOverviewsList))
        XCTAssertTrue(listCard.exists)

        // Criterion 19: every article read, under Unread: the card and "All caught up".
        chooseFilter("Unread")
        button(AccessibilityID.markAllReadButton).tap()
        waitFor(app.alerts.firstMatch).buttons["Mark as Read"].tap()
        waitForAbsence(app.alerts.firstMatch)
        // The rows keep their places until the list is entered again.
        showToday()
        openCategoryList(world)
        let empty = waitFor(element(AccessibilityID.categoryEmpty))
        XCTAssertTrue(empty.label.contains(Overview.caughtUp), empty.label)
        waitFor(button(AccessibilityID.showAllButton))
        XCTAssertTrue(card(world).isHittable, "the card is visible above the empty state")
        XCTAssertTrue(empty.isHittable || button(AccessibilityID.showAllButton).isHittable, "the empty state is visible")
        XCTAssertLessThan(card(world).frame.maxY, empty.frame.minY + 1, "the empty state is below the card")
        screenshot("rd23-card-and-all-caught-up")
    }

    /// Criteria 2, 10, 11 and 17: Manual offers the count and Write
    /// Overview; Rewrite; Off shows the "Overviews off" row and writes
    /// nothing; back to Automatic; after the reading language changes, the
    /// old overview is not shown and Write Overview writes one in the new
    /// language.
    func testManualAndLanguage() {
        launchOverviews()
        createCategory("World")
        setOverviews(of: "World", to: "Manual")
        addSource(Translation.feed, to: "World")
        showToday()
        let world = "World"
        waitForText(part("newCount", world), "63 new articles, no overview for today yet")
        XCTAssertFalse(summary(world).exists, "manual: nothing written by the collection")
        button(AccessibilityID.overview("write", world)).tap()
        waitForText(summary(world), Overview.summary(40, Translation.markup))

        // Rewrite: written again, still shown.
        revealOnToday(button(AccessibilityID.overview("rewrite", world))).tap()
        waitForText(summary(world), Overview.summary(40, Translation.markup))

        // Off: the compact row, and nothing is written.
        setOverviews(of: world, to: "Off")
        showToday()
        waitForText(todayRow(world), "Overviews off")
        XCTAssertFalse(card(world).exists)
        setOverviews(of: world, to: "Automatic")
        refreshRun(in: world)
        waitForText(summary(world), Overview.summary(40, Translation.markup))

        // English: the Chinese overview is kept and not shown.
        openTranslationSettings()
        option("English").tap()
        showToday()
        waitForText(part("newCount", world), "new articles, no overview for today yet")
        XCTAssertFalse(summary(world).exists)
        button(AccessibilityID.overview("write", world)).tap()
        waitForText(summary(world), Overview.summary(40, Translation.markup, "en"))
    }

    /// Criteria 6 and 8 and the set-up state: no model → the prompt that
    /// opens Settings; a refusal → the failed card with Retry; a slow
    /// answer → "Writing overview…"; the daily limit → its sentence, and
    /// Write Overview writes.
    func testStates() {
        // No model.
        launchOverviews(models: nil)
        addFeed(Translation.feed, to: "World")
        showToday()
        waitForText(part("noModel", "World"), Overview.noModel)
        button(AccessibilityID.overview("step", "World")).tap()
        waitFor(element(AccessibilityID.primaryModelRow))

        // A refusal: retried once, stored, shown with Retry.
        launchOverviews()
        addFeed(Translation.wordFeed("refuse"), to: "Refused")
        refreshRun(in: "Refused")
        waitForText(part("issue", "Refused"), Overview.refused)
        XCTAssertTrue(button(AccessibilityID.overview("step", "Refused")).label.contains("Retry"))

        // A slow answer: "Writing overview…" while it is written.
        createCategory("Slow")
        setOverviews(of: "Slow", to: "Manual")
        addSource(Translation.wordFeed("slow"), to: "Slow")
        showToday()
        revealOnToday(button(AccessibilityID.overview("write", "Slow"))).tap()
        waitFor(part("working", "Slow"))
        waitForText(summary("Slow"), Overview.summary(1, Translation.slow))

        // The daily limit: nothing automatic; Write Overview is not limited.
        launchOverviews(limit: 0)
        addFeed(Fixture.articles, to: "Limited")
        refreshRun(in: "Limited")
        let issue = revealOnToday(part("issue", "Limited"))
        waitForText(issue, Overview.dailyLimit)
        button(AccessibilityID.overview("write", "Limited")).tap()
        waitForText(summary("Limited"), "概览[zh-Hans]：")
    }

    /// Review round 2: with nothing new today, the list's card still
    /// offers Earlier Overviews, and it opens the earlier ones.
    func testEarlierOverviewsWithNothingNew() {
        launchOverviews()
        createCategory("Quiet")
        // Seeded once the category exists: the earlier overviews.
        launchOverviews(seed: true)
        openCategoryList("Quiet")
        waitForText(part("nothingNew", "Quiet"), Overview.nothingNew)
        XCTAssertFalse(summary("Quiet").exists, "no overview today")
        waitFor(button(AccessibilityID.overview("earlier", "Quiet"))).tap()
        waitFor(element(AccessibilityID.earlierOverviewsList))
        for days in 1...3 {
            waitFor(element(AccessibilityID.earlierOverview(dayKey(daysBefore: days))))
        }
        XCTAssertTrue(app.staticTexts["Earlier overview 1 day(s) ago."].exists)
        button(AccessibilityID.earlierOverviewsDoneButton).tap()
        waitForAbsence(element(AccessibilityID.earlierOverviewsList))
        XCTAssertTrue(card("Quiet").exists)
    }

    /// Batch 4 (RD17): a written overview's request is counted in
    /// Settings › Usage under "Overviews".
    func testUsageCountsOverviews() {
        launchOverviews()
        createCategory("World")
        setOverviews(of: "World", to: "Manual")
        addSource(Translation.feed, to: "World")
        showToday()
        waitFor(button(AccessibilityID.overview("write", "World"))).tap()
        waitForText(summary("World"), Overview.summary(40, Translation.markup))
        openSettings(row: AccessibilityID.usageRow)
        scrollTo(element(AccessibilityID.usageRow)).tap()
        let row = waitFor(element(AccessibilityID.usageTotal(model: "fixture-translator", purpose: "overview")))
        XCTAssertTrue(row.label.hasPrefix("Overviews, 1 request"), row.label)
    }

    private func dayKey(daysBefore days: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = calendar.startOfDay(for: Date())
        let noon = calendar.date(byAdding: .hour, value: 12, to: start) ?? start
        let date = calendar.date(byAdding: .day, value: -days, to: noon) ?? noon
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// RD23 criterion 13 in the app: an adult overview is written through the
/// adult library's own slot; locked, the normal Today shows nothing of it.
final class OverviewAdultTests: IsolationTestCase {
    func testAdultOverviewStaysInTheAdultPartition() {
        let application = XCUIApplication()
        launch(application, authentication: ["passed", "passed", "passed"])
        rotate(.portrait)
        requireFullWidth()
        turnOnAdult()
        enterAdult()
        openAdultSettings()
        waitFor(adultPrimaryRow).tap()
        waitFor(button(AccessibilityID.saveButton))
        fillForm(address: Isolation.translateAddress, model: Isolation.translator, key: "sk-adult-overview-key-4567")
        tapSave()
        waitForAbsence(button(AccessibilityID.saveButton))
        createCategory("Velvet")
        addSource(Isolation.translationFeed, to: "Velvet")
        // A refresh run: its end writes the due categories.
        openCategoryList("Velvet")
        pullList()
        showToday()
        let summary = element(AccessibilityID.overview("summary", "Velvet"))
        let written = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in summary.exists && summary.label.contains("概览[zh-Hans]：40") }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [written], timeout: 30), .completed, summary.exists ? summary.label : "no adult card")

        tapLock()
        waitForPartition(Wording.normal)
        showToday()
        XCTAssertFalse(element(AccessibilityID.todayCategoryRow("Velvet")).exists)
        XCTAssertFalse(element(AccessibilityID.overview("card", "Velvet")).exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "概览[")).firstMatch.exists)
    }

    /// Batch 4 (gate run 1): an adult Manual category's set-up failure
    /// (the adult key rejected) is shown with Open Settings; a Replace
    /// made inside the adult partition writes the file's adult slot; the
    /// card no longer shows the old slot's failure and offers Write
    /// Overview, without a relaunch. The reading language is the file's
    /// beforehand, so that the import does not hide the old block by a
    /// change of language; the category and its source are the file's, so
    /// that Replace keeps them.
    func testAnImportedAdultSlotClearsTheOldSetUpFailure() {
        let application = XCUIApplication()
        application.launchEnvironment[UITestLaunchKey.configurationFixture] = "both"
        launch(application, authentication: ["passed", "passed", "passed"])
        rotate(.portrait)
        requireFullWidth()
        openSettings()
        waitFor(element(AccessibilityID.modelsRow)).tap()
        scrollTo(app.buttons.matching(NSPredicate(format: "label == %@", "Japanese")).firstMatch).tap()
        turnOnAdult()
        enterAdult()
        openAdultSettings()
        waitFor(adultPrimaryRow).tap()
        waitFor(button(AccessibilityID.saveButton))
        fillForm(address: "https://rejected.models.example.invalid/v1", model: "fixture-adult-model", key: "sk-adult-rejected-key-4567")
        tapSave()
        waitForAbsence(button(AccessibilityID.saveButton))
        let name = "Imported Private"
        createCategory(name)
        addSource("https://articles.example.invalid/rss.xml", to: name)
        setOverviewsToManual(name)
        showToday()
        waitFor(button(AccessibilityID.overview("write", name))).tap()
        // The shell's question for a manual job that stored nothing.
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: timeout))
        alert.buttons["Cancel"].tap()
        let issue = waitFor(element(AccessibilityID.overview("issue", name)))
        XCTAssertTrue(issue.label.contains("The service rejected the key"), issue.label)

        // Replace inside the adult partition, with the file of both.
        openSettings()
        waitFor(element(AccessibilityID.dataRow)).tap()
        waitFor(button(AccessibilityID.importConfigurationButton)).tap()
        let replaceAll = scrollTo(button(AccessibilityID.configurationReplaceEverythingButton))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: replaceAll)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: timeout), .completed)
        replaceAll.tap()
        waitFor(app.navigationBars["Before Replacing"])
        scrollTo(button(AccessibilityID.configurationReplaceButton)).tap()
        let confirm = app.alerts.firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout))
        confirm.buttons.matching(NSPredicate(format: "label == %@", "Replace")).firstMatch.tap()
        waitFor(button(AccessibilityID.configurationDoneButton)).tap()
        waitForAbsence(button(AccessibilityID.configurationDoneButton))

        showToday()
        waitFor(button(AccessibilityID.overview("write", name)))
        XCTAssertFalse(element(AccessibilityID.overview("issue", name)).exists, "the old slot's failure is still shown")
    }

    /// Category Settings › Overviews of `category` set to Manual, saved.
    private func setOverviewsToManual(_ category: String) {
        openCategoryList(category)
        openListSettings(source: false)
        waitFor(app.textFields[AccessibilityID.nameField])
        let picker = scrollTo(button(AccessibilityID.overviewModePicker))
        picker.tap()
        waitFor(app.buttons.matching(NSPredicate(format: "label == %@", "Manual")).firstMatch).tap()
        let chosen = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            picker.exists && ((picker.value as? String)?.contains("Manual") == true || picker.label.contains("Manual"))
        }, object: nil)
        _ = XCTWaiter.wait(for: [chosen], timeout: timeout)
        tapSave()
        waitForAbsence(app.textFields[AccessibilityID.nameField])
    }

    /// Batch 4 (RD19): with slots in the normal library and none in the
    /// adult one, the adult card says no model is set up, and its step
    /// opens the adult slots in Settings › Adult Partition — never the
    /// normal partition's Models & Translation.
    func testAdultWithoutSlotsLinksToTheAdultSlots() {
        let application = XCUIApplication()
        application.launchEnvironment[UITestLaunchKey.translationModels] = "primary"
        launch(application, authentication: ["passed", "passed", "passed"])
        rotate(.portrait)
        requireFullWidth()
        turnOnAdult()
        enterAdult()
        createCategory("Velvet")
        addSource(Isolation.translationFeed, to: "Velvet")
        showToday()
        let noModel = waitFor(element(AccessibilityID.overview("noModel", "Velvet")))
        XCTAssertTrue(noModel.label.contains("Set up a model to get overviews"), noModel.label)
        XCTAssertFalse(element(AccessibilityID.overview("summary", "Velvet")).exists)
        waitFor(button(AccessibilityID.overview("step", "Velvet"))).tap()
        waitFor(adultPrimaryRow)
        XCTAssertFalse(element(AccessibilityID.primaryModelRow).exists, "the normal partition's model settings were opened")
    }
}
