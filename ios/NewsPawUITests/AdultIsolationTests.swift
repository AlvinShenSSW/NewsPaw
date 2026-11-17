import XCTest

/// RD19 criteria 3 to 8 in the app: each partition's own models and keys,
/// Settings › Adult Partition by entry point, the adult browser's own
/// website data with Clear and Delete, and the thumbnails switch.
final class AdultIsolationTests: IsolationTestCase {
    // MARK: - Criterion 5

    /// Opened from the normal partition, Settings › Adult Partition shows
    /// no slot, thumbnail or limit row and says where they are; inside the
    /// adult partition it shows the adult models with RD13's form, the
    /// thumbnails switch, lock timing, Clear Browsing Data and Turn Off.
    func testSettingsByEntryPoint() {
        launchAtFullWidth(authentication: ["passed", "passed", "passed"])
        turnOnAdult()
        // From the normal partition (just turned on; opened again it asks).
        XCTAssertFalse(adultPrimaryRow.exists)
        XCTAssertFalse(adultBackupRow.exists)
        XCTAssertFalse(thumbnailsToggle.exists)
        XCTAssertFalse(element(AccessibilityID.adultDailyLimitRow).exists, "the adult limit outside the adult partition")
        waitFor(element(AccessibilityID.lockTimingPicker))
        XCTAssertTrue(scrollTo(clearBrowsingButton).isEnabled)
        let elsewhere = scrollTo(element(AccessibilityID.adultSettingsElsewhere))
        XCTAssertEqual(elsewhere.label, Isolation.elsewhere)
        tapAdultRow()
        waitFor(turnOffButton)
        XCTAssertFalse(adultPrimaryRow.exists)
        XCTAssertFalse(thumbnailsToggle.exists)

        enterAdult()
        openAdultSettings()
        waitFor(adultPrimaryRow)
        XCTAssertTrue(adultPrimaryRow.label.contains("Not set up"), adultPrimaryRow.label)
        XCTAssertFalse(adultBackupRow.isEnabled, "the backup waits for a primary")
        XCTAssertEqual(scrollTo(thumbnailsToggle).value as? String, "1")
        // Decision 12: the adult library's limit, opening RD17's Usage.
        let limitRow = scrollTo(element(AccessibilityID.adultDailyLimitRow))
        XCTAssertTrue(limitRow.label.contains("200"), limitRow.label)
        limitRow.tap()
        waitFor(element(AccessibilityID.usagePeriodPicker))
        goBack()
        waitFor(element(AccessibilityID.adultDailyLimitRow))
        scrollTo(element(AccessibilityID.lockTimingPicker))
        scrollTo(clearBrowsingButton)
        scrollTo(turnOffButton)
        XCTAssertFalse(element(AccessibilityID.adultSettingsElsewhere).exists)

        // The S9 form on the adult library: Load List, Test, Save, Remove.
        app.swipeDown()
        waitFor(adultPrimaryRow).tap()
        waitFor(button(AccessibilityID.saveButton))
        fillForm(address: Isolation.translateAddress, model: "nothing-yet", key: "sk-adult-form-key-4567")
        reveal(button(AccessibilityID.loadListButton)).tap()
        waitFor(element(AccessibilityID.modelListRow(Isolation.translator))).tap()
        waitForAbsence(element(AccessibilityID.modelListRow(Isolation.translator)))
        runTest(expecting: "Passed")
        tapSave()
        waitForAbsence(button(AccessibilityID.saveButton))
        waitFor(adultPrimaryRow)
        XCTAssertTrue(adultPrimaryRow.label.contains(Isolation.translator), adultPrimaryRow.label)
        XCTAssertTrue(adultBackupRow.isEnabled)
        adultPrimaryRow.tap()
        reveal(button(AccessibilityID.removeModelButton)).tap()
        waitFor(dialogButton("Remove Model")).tap()
        waitForAbsence(button(AccessibilityID.saveButton))
        waitForLabel(waitFor(adultPrimaryRow), containing: "Not set up")
    }

    // MARK: - Criteria 3 and 4

    /// With a normal fixture slot and no adult slot, adult rows show
    /// originals and nothing is sent; with an adult slot set up in S10
    /// with the same address, model and key, the adult rows are
    /// translated; removing the adult key leaves the normal one, which
    /// still shows its dots and four characters.
    func testEachPartitionTranslatesWithItsOwnModels() {
        let application = XCUIApplication()
        application.launchEnvironment[UITestLaunchKey.translationModels] = "primary"
        launch(application, authentication: ["passed", "passed", "passed"])
        rotate(.portrait)
        requireFullWidth()
        turnOnAdult()
        enterAdult()
        createCategory("Velvet")
        addSource(Isolation.translationFeed, to: "Velvet")
        openCategoryList("Velvet")
        let row = waitFor(articleRow(Isolation.firstForeign))
        let before = translationRequests
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(row.label.contains("译["), "an adult row was translated without an adult slot: \(row.label)")
        XCTAssertEqual(translationRequests, before, "a request was sent from the adult partition: \(report)")

        // The adult slot, set up in S10 with the normal slot's own values.
        openAdultSettings()
        waitFor(adultPrimaryRow).tap()
        waitFor(button(AccessibilityID.saveButton))
        fillForm(address: Isolation.translateAddress, model: Isolation.translator, key: Isolation.normalFixtureKey)
        runTest(expecting: "Passed")
        tapSave()
        waitForAbsence(button(AccessibilityID.saveButton))
        openCategoryList("Velvet")
        waitForLabel(waitFor(articleRow(Isolation.firstForeign)), containing: "译[zh-Hans]：\(Isolation.firstForeign)")
        XCTAssertGreaterThan(translationRequests, before)

        // The adult key is removed: the slot stays at "Key needed".
        openAdultSettings()
        waitFor(adultPrimaryRow).tap()
        reveal(button(AccessibilityID.removeKeyButton)).tap()
        waitFor(dialogButton("Remove Key")).tap()
        reveal(element(AccessibilityID.keyNeeded))
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(button(AccessibilityID.saveButton))

        // A row the adult slot cannot translate now asks for a key; its
        // question's "Open Settings" opens the adult slots, in Settings ›
        // Adult Partition, not the normal ones (review round 1).
        addSource(Fixture.articles, to: "Velvet")
        openCategoryList("Velvet")
        let mark = scrollTo(button(AccessibilityID.translationWarning("Plain story")))
        mark.tap()
        let question = waitFor(app.alerts.firstMatch)
        question.buttons["Open Settings"].tap()
        waitFor(adultPrimaryRow)
        XCTAssertFalse(element(AccessibilityID.primaryModelRow).exists, "the normal slots were opened")
        waitFor(turnOffButton)

        // The normal key is still there, and still used.
        tapLock()
        waitForPartition(Wording.normal)
        openSettings()
        waitFor(element(AccessibilityID.modelsRow)).tap()
        waitFor(element(AccessibilityID.primaryModelRow)).tap()
        let stored = reveal(element(AccessibilityID.storedKey))
        XCTAssertEqual(stored.label, "Key ending in 0123")
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(button(AccessibilityID.saveButton))
        createCategory("World")
        addSource(Isolation.translationFeed, to: "World")
        openCategoryList("World")
        waitForLabel(waitFor(articleRow(Isolation.firstForeign)), containing: "译[zh-Hans]：\(Isolation.firstForeign)")
    }

    // MARK: - Criterion 6 and assumption A3

    /// Page data written in one partition's browser are absent from the
    /// other's in both directions; the adult data survive a lock and an
    /// unlock; Clear removes the adult data and leaves the normal data.
    func testEachBrowserKeepsItsOwnData() {
        launchAtFullWidth(authentication: ["passed", "passed", "passed", "passed"])
        createCategory("World")
        addSource(Fixture.articles, to: "World")
        let first = openStoragePage(of: "Plain story", in: "World")
        record("A3 normal storage page", first)
        XCTAssertEqual(first, "none")
        storeMark(adult: false)

        turnOnAdult()
        enterAdult()
        createCategory("Velvet")
        addSource(Fixture.articles, to: "Velvet")
        XCTAssertEqual(openStoragePage(of: "Plain story", in: "Velvet"), "none", "the normal mark is in the adult browser")
        storeMark(adult: true)
        capture("storage-adult")

        // A lock and an unlock: the adult data are kept.
        leaveBrowser()
        tapLock()
        waitForPartition(Wording.normal)
        waitForReport(Self.closed, Self.dropped)
        enterAdult()
        XCTAssertEqual(openStoragePage(of: "Plain story", in: "Velvet"), "adult", "the adult data did not survive the lock")

        // The normal browser does not have them.
        leaveBrowser()
        tapLock()
        waitForPartition(Wording.normal)
        XCTAssertEqual(openStoragePage(of: "Plain story", in: "World"), "normal")

        // Clear, inside the adult partition, with the page open on its stack.
        leaveBrowser()
        enterAdult()
        openStoragePage(of: "Plain story", in: "Velvet")
        leaveBrowser()
        openAdultSettings()
        clearBrowsingData()
        capture("clear-done")
        XCTAssertEqual(openStoragePage(of: "Plain story", in: "Velvet"), "none", "Clear left the adult data")
        leaveBrowser()
        tapLock()
        waitForPartition(Wording.normal)
        XCTAssertEqual(openStoragePage(of: "Plain story", in: "World"), "normal", "Clear removed the normal data")
    }

    // MARK: - Criterion 6: a page that will not stop writing (review round 1)

    /// A page that writes `localStorage` and a cookie every 200 ms was open
    /// in the adult browser and then left (its route closed; a view may
    /// keep its web view). Clear waits until every ended page's document is
    /// gone: well after Clear, the `/storage` page finds nothing.
    func testClearLeavesNothingOfAPageThatKeepsWriting() {
        launchAtFullWidth(authentication: ["passed", "passed"])
        turnOnAdult()
        enterAdult()
        createCategory("Velvet")
        addSource(Fixture.articles, to: "Velvet")
        openCategoryList("Velvet")
        openArticle("Plain story")
        waitFor(button(AccessibilityID.openOriginalButton)).tap()
        waitForPage("Original of plain-story")
        tapLink("Writer page")
        waitForPage("Writer: writing")
        // Left: on the tab structure the page is popped to reach Settings;
        // on the panes choosing Settings closes it.
        openAdultSettings()
        clearBrowsingData()
        // Many times the page's interval.
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(openStoragePage(of: "Plain story", in: "Velvet"), "none", "the page wrote again after Clear")
    }

    /// The same page open when the app is left: the lock ends it (its view
    /// may keep its web view, RD18 A4); Clear from the normal partition
    /// waits for its document to be gone; after the unlock the `/storage`
    /// page finds nothing.
    func testClearAfterALockLeavesNothingOfAPageThatKeepsWriting() {
        launchAtFullWidth(authentication: ["passed", "passed", "passed", "passed"])
        turnOnAdult()
        enterAdult()
        createCategory("Velvet")
        addSource(Fixture.articles, to: "Velvet")
        openCategoryList("Velvet")
        openArticle("Plain story")
        waitFor(button(AccessibilityID.openOriginalButton)).tap()
        waitForPage("Original of plain-story")
        tapLink("Writer page")
        waitForPage("Writer: writing")
        // Home with "Immediately": the lock comes with the page on screen.
        leaveAndReturn()
        waitForPartition(Wording.normal)
        waitForReport(Self.closed, Self.dropped)
        Thread.sleep(forTimeInterval: 2)
        // Clear from the normal partition (it asks first), then a wait of
        // many times the page's interval.
        openAdultSettings()
        clearBrowsingData()
        Thread.sleep(forTimeInterval: 3)
        enterAdult()
        XCTAssertEqual(openStoragePage(of: "Plain story", in: "Velvet"), "none", "the page wrote again after Clear")
    }

    // MARK: - Review round 2: no adult page while Clear runs

    /// While Clear runs (held 30 s by the debug option) an adult page asked
    /// for gets no session: its screen stays empty, and the page opens once
    /// the clear has ended.
    func testNoAdultPageOpensWhileClearRuns() {
        app.terminate()
        let application = XCUIApplication()
        application.launchEnvironment[UITestLaunchKey.clearPause] = "30"
        launch(application, authentication: ["passed", "passed"])
        rotate(.portrait)
        requireFullWidth()
        turnOnAdult()
        enterAdult()
        createCategory("Velvet")
        addSource(Fixture.articles, to: "Velvet")
        openAdultSettings()
        scrollTo(clearBrowsingButton).tap()
        waitFor(button(AccessibilityID.confirmClearBrowsingDataButton)).tap()
        let before = sessionsMade
        XCTAssertGreaterThanOrEqual(before, 0, report)

        openCategoryList("Velvet")
        openArticle("Plain story")
        waitFor(button(AccessibilityID.openOriginalButton)).tap()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(sessionsMade, before, "a session was made while Clear ran")
        XCTAssertFalse(barText("Original of plain-story").exists, "the page opened while Clear ran")

        // Once the clear has ended the page opens.
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            self.barText("Original of plain-story").exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 60), .completed, "the page did not open after Clear")
        XCTAssertEqual(sessionsMade, before + 1, report)
    }

    /// Cleared from the normal partition (held 30 s), the switch and Turn
    /// Off are dimmed while Clear runs, so no unlock and no Delete starts;
    /// once it has ended the adult partition opens again.
    func testNoUnlockWhileClearRuns() {
        app.terminate()
        let application = XCUIApplication()
        application.launchEnvironment[UITestLaunchKey.clearPause] = "30"
        launch(application, authentication: ["passed", "passed"])
        rotate(.portrait)
        requireFullWidth()
        turnOnAdult()
        scrollTo(clearBrowsingButton).tap()
        waitFor(button(AccessibilityID.confirmClearBrowsingDataButton)).tap()
        // Nor can Delete remove the store the clear is working on.
        XCTAssertFalse(scrollTo(turnOffButton).isEnabled, "Turn Off could be used while Clear ran")
        revealSwitchPlace()
        XCTAssertFalse(waitFor(partitionSwitch).isEnabled, "the switch could unlock while Clear ran")

        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: partitionSwitch)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 60), .completed, "the switch stayed dimmed after Clear")
        enterAdult()
    }

    // MARK: - Criterion 7

    /// Delete removes the adult browser's data with the rest: after
    /// turning on again the page finds nothing.
    func testDeleteRemovesTheAdultBrowserData() {
        launchAtFullWidth(authentication: ["passed", "passed", "passed", "passed"])
        turnOnAdult()
        enterAdult()
        createCategory("Velvet")
        addSource(Fixture.articles, to: "Velvet")
        openStoragePage(of: "Plain story", in: "Velvet")
        storeMark(adult: true)
        // The page stays open on the Library stack: Delete comes from
        // Settings.
        openAdultSettings()
        turnOffButton.tap()
        answerAlert(Wording.turnOffQuestion, with: "Delete Data")
        answerAlert(Wording.deleteQuestion, with: "Delete")
        waitFor(adultRow)
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 2), "the deletion said: \(alertTexts())")
        waitForReport("file=0", Self.closed, Self.dropped)
        // Assumption A2: whether WebKit removed the store, or refused it as
        // in use (its data removed); either counts as removed.
        record("A2 after Delete with an article and its page open", report)

        turnOnAdult()
        enterAdult()
        createCategory("Velvet")
        addSource(Fixture.articles, to: "Velvet")
        XCTAssertEqual(openStoragePage(of: "Plain story", in: "Velvet"), "none", "the adult browser's data outlived Delete")
    }

    // MARK: - Review round 4: one Turn Off at a time (J2)

    /// Delete asked for from the normal partition's Settings and held (the
    /// clear's debug option) before the gate removes the data: Settings ›
    /// Adult Partition opened again meanwhile has Turn Off and Clear
    /// Browsing Data dimmed, so no second Turn Off or Delete can be asked
    /// for, until the first has ended and the partition is off.
    func testTurnOffIsRefusedWhileDeleteRuns() {
        app.terminate()
        let application = XCUIApplication()
        application.launchEnvironment[UITestLaunchKey.clearPause] = "30"
        launch(application, authentication: ["passed", "passed"])
        rotate(.portrait)
        requireFullWidth()
        turnOnAdult()
        scrollTo(turnOffButton).tap()
        answerAlert(Wording.turnOffQuestion, with: "Delete Data")
        answerAlert(Wording.deleteQuestion, with: "Delete")
        waitFor(adultRow)
        // Held before the gate deletes: Settings › Adult Partition again.
        openAdultSettings()
        XCTAssertFalse(scrollTo(turnOffButton).isEnabled, "Turn Off could be asked for while Delete ran")
        XCTAssertFalse(scrollTo(clearBrowsingButton).isEnabled, "Clear could be asked for while Delete ran")

        // The first Delete ends: the partition is off.
        let off = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            !self.turnOffButton.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [off], timeout: 60), .completed, "the partition stayed on after Delete")
        waitFor(adultToggle)
    }

    // MARK: - Criterion 8

    /// With the switch off adult rows show no thumbnail and none is
    /// fetched (the adult Settings › Data reads zero after the row was on
    /// screen); turned on, the thumbnail is fetched; the normal partition is
    /// unaffected; the value survives a relaunch.
    func testThumbnailsSwitch() {
        launchAtFullWidth(authentication: ["passed", "passed", "passed"])
        turnOnAdult()
        enterAdult()
        openAdultSettings()
        setThumbnails(false)
        createCategory("Velvet")
        addSource(Fixture.articles, to: "Velvet")
        openCategoryList("Velvet")
        waitFor(articleRow("Image story"))
        capture("thumbnails-off")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(imageCacheSize(), zero, "a thumbnail was fetched with the switch off")

        // The normal partition shows its thumbnails.
        tapLock()
        waitForPartition(Wording.normal)
        createCategory("World")
        addSource(Fixture.articles, to: "World")
        openCategoryList("World")
        waitFor(articleRow("Image story"))
        waitForImageCache(zero: false)

        // On again in the adult partition: the thumbnail is fetched.
        enterAdult()
        XCTAssertEqual(imageCacheSize(), zero)
        openAdultSettings()
        setThumbnails(true)
        openCategoryList("Velvet")
        waitFor(articleRow("Image story"))
        waitForImageCache(zero: false)

        // Off survives a relaunch.
        openAdultSettings()
        setThumbnails(false)
        app.terminate()
        launchAtFullWidth(authentication: ["passed"])
        enterAdult()
        openAdultSettings()
        XCTAssertEqual(scrollTo(thumbnailsToggle).value as? String, "0")
    }
}
