import XCTest

/// RD18: locking — by the button, by choosing Normal, by the timing rule —
/// what is left of the adult partition afterwards (nothing on screen, and
/// nothing held), the lock timing, and what a model of the workspace that
/// is not shown may not do.
final class AdultLockTests: AdultTestCase {
    /// Every name that exists only in the adult partition of these tests.
    private static let adultNames = [
        "Velvet", "Articles Feed", "Image story", "Plain story", "Linkless story", "Plain Page", "Slow Feed", "Slow story",
    ]

    /// The normal partition: World with the fixture feed. The adult
    /// partition, turned on and entered (two passed answers): Velvet with
    /// the articles feed, a web page and the slow feed, and one starred
    /// article. Ends in the adult partition.
    private func buildBothPartitions() {
        createCategory("World")
        addSource(Fixture.feed, to: "World")
        turnOnAdult()
        enterAdult()
        createCategory("Velvet")
        addSource(Fixture.articles, to: "Velvet")
        addWebPageSource(to: "Velvet")
        addSource("https://slowfeeds.example.invalid/slow.xml", to: "Velvet")
        openSourceList("Articles Feed", in: "Velvet")
        swipeAction(on: waitFor(articleRow("Linkless story")), leading: false, "Star")
        waitForLabel(articleRow("Linkless story"), containing: ", Starred")
    }

    // MARK: - Criteria 6 and 7

    /// After each way of locking the app is at the root of the current tab
    /// of the normal partition, a walk over every screen finds none of the
    /// adult names, and the adult library, its workspace and its browser
    /// library's connections are closed and its workspace is gone: also
    /// when the lock came while a refresh was running, and while a sheet
    /// and the browser were open; and what the stopped workspace's tasks
    /// run into raises no alert. In this test an article was starred by a
    /// swipe and menus were used, after which UIKit keeps the views'
    /// models and the library object (assumption A4): whether those
    /// objects are gone is recorded here and asserted in the tests whose
    /// paths UIKit does not hold.
    func testNothingOfTheAdultPartitionIsLeftAfterALock() {
        // Turning on, three unlocks, and Settings › Adult Partition opened
        // from the normal partition in each of the three walks.
        launchAtFullWidth(authentication: Array(repeating: "passed", count: 7))
        buildBothPartitions()

        // 1. The lock button, while a refresh of the slow source runs.
        showCategoryList()
        waitFor(element(AccessibilityID.categoryRow("Velvet"))).press(forDuration: 1.2)
        waitFor(menuButton("Refresh")).tap()
        tapLock()
        waitForPartition(Wording.normal)
        XCTAssertFalse(lockButton.exists)
        waitForReport("file=1", Self.closed, Self.dropped)
        record("RD18 after the lock button", report)
        // The cancelled refresh's last reads fail against the closed
        // library; nothing says so.
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 4), "an alert after the lock")
        walkTheNormalPartition("after the lock button")

        // 2. Normal chosen in the switch, from the Starred tab: the normal
        // partition opens on Starred.
        enterAdult()
        openStarred()
        waitFor(articleRow("Linkless story"))
        chooseNormal()
        waitForPartition(Wording.normal)
        waitFor(element(AccessibilityID.starredEmpty))
        if usesTabs {
            XCTAssertTrue(app.tabBars.buttons.element(boundBy: 2).isSelected, "not on the Starred tab")
        }
        waitForReport(Self.closed, Self.dropped)
        record("RD18 after choosing Normal", report)
        walkTheNormalPartition("after choosing Normal")

        // 3. The timing rule ("immediately": leaving the app), with the
        // browser open on the adult web page and the Add source sheet open
        // above it.
        enterAdult()
        openWebPageSource(in: "Velvet")
        chooseInMore("Save This Page as a Source")
        waitFor(app.textFields[AccessibilityID.addressField])
        waitForReport("pool=open", "library=held", "workspace=held", "browser=held")
        leaveAndReturn()
        waitForAbsence(app.textFields[AccessibilityID.addressField])
        waitForAbsence(moreMenu)
        waitForPartition(Wording.normal)
        XCTAssertFalse(lockButton.exists)
        waitForReport(Self.closed, Self.dropped)
        record("RD18 after the timing rule", report)
        XCTAssertFalse(app.alerts.firstMatch.exists, "an alert after the lock")
        walkTheNormalPartition("after the timing rule")
    }

    /// Today, Library, All Unread, a category, Starred, the Add source
    /// sheet with its category picker, a category's settings and every
    /// Settings screen: none shows an adult name.
    private func walkTheNormalPartition(_ when: String) {
        let names = Self.adultNames
        showToday()
        assertNothingShown(of: names, on: "Today \(when)")
        expand("World")
        waitFor(sourceRow("Fixture Feed"))
        assertNothingShown(of: names, on: "the category list \(when)")
        openAllUnread()
        waitFor(articleRow("Fixture story one"))
        assertNothingShown(of: names, on: "All Unread \(when)")
        openCategoryList("World")
        waitFor(articleRow("Fixture story one"))
        assertNothingShown(of: names, on: "the category's list \(when)")
        openStarred()
        waitFor(element(AccessibilityID.starredEmpty))
        assertNothingShown(of: names, on: "Starred \(when)")

        // Add source, as far as its category picker.
        openAddSource()
        assertNothingShown(of: names, on: "Add source \(when)")
        detect("https://onefeed.example.invalid/")
        waitFor(element(AccessibilityID.confirmAddress))
        assertNothingShown(of: names, on: "Add source's confirm step \(when)")
        waitFor(button(AccessibilityID.categoryChoiceRow)).tap()
        waitFor(button(AccessibilityID.categoryChoice("World")))
        assertNothingShown(of: names, on: "Add source's category picker \(when)")
        // Back to the confirm step, then to the address step, which has
        // Cancel.
        goBack()
        waitFor(element(AccessibilityID.confirmAddress))
        goBack()
        waitFor(button(AccessibilityID.cancelButton)).tap()
        waitForAbsence(app.textFields[AccessibilityID.addressField])

        // A category's settings.
        openCategorySettings("World")
        assertNothingShown(of: names, on: "Category Settings \(when)")
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(app.textFields[AccessibilityID.nameField])

        // Every Settings screen.
        openSettings()
        assertNothingShown(of: names, on: "Settings \(when)")
        waitFor(element(AccessibilityID.modelsRow)).tap()
        waitFor(element(AccessibilityID.primaryModelRow))
        assertNothingShown(of: names, on: "Models & Translation \(when)")
        element(AccessibilityID.primaryModelRow).tap()
        waitFor(app.textFields[AccessibilityID.modelAddressField])
        assertNothingShown(of: names, on: "the model form \(when)")
        // The form has Cancel in place of the back button, and no tab bar.
        waitFor(button(AccessibilityID.cancelButton)).tap()
        waitFor(element(AccessibilityID.primaryModelRow))
        openSettings()
        waitFor(element(AccessibilityID.refreshRow)).tap()
        waitFor(app.buttons["Manual Only"].firstMatch)
        assertNothingShown(of: names, on: "Settings › Refresh \(when)")
        openSettings()
        waitFor(element(AccessibilityID.dataRow)).tap()
        waitFor(element(AccessibilityID.cacheSize))
        assertNothingShown(of: names, on: "Settings › Data \(when)")
        openSettings()
        waitFor(element(AccessibilityID.aboutRow)).tap()
        waitFor(element(AccessibilityID.versionValue))
        assertNothingShown(of: names, on: "About \(when)")
        // Settings › Adult Partition, which asks first (a passed answer).
        tapAdultRow()
        waitFor(turnOffButton)
        assertNothingShown(of: names, on: "Settings › Adult Partition \(when)")
        XCTAssertTrue(report.contains(Self.closed) && report.contains(Self.dropped), report)
        openSettings()
    }

    // MARK: - Criterion 5

    /// A collection of the normal partition that ends while the adult
    /// partition is shown leaves an adult source's list, and its settings
    /// sheet, open: the normal workspace's models do not reach the adult
    /// workspace's navigation.
    func testACollectionOfTheHiddenPartitionLeavesTheShownOneAlone() {
        launchAtFullWidth(authentication: ["passed", "passed", "passed"])
        createCategory("World")
        // Answers at once when added, and after 45 seconds from then on.
        addSource("https://stalling.example.invalid/rss.xml", to: "World")
        turnOnAdult()
        enterAdult()
        createCategory("Velvet")
        addSource(Fixture.articles, to: "Velvet")
        tapLock()
        waitForPartition(Wording.normal)

        // The normal category's refresh starts a collection that is still
        // running three quarters of a minute from now.
        showCategoryList()
        waitFor(element(AccessibilityID.categoryRow("World"))).press(forDuration: 1.2)
        waitFor(menuButton("Refresh")).tap()
        let started = Date()
        enterAdult()
        openSourceList("Articles Feed", in: "Velvet")
        waitFor(articleRow("Image story"))
        openListSettings(source: true)
        let name = waitFor(app.textFields[AccessibilityID.nameField])
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 43, "the normal collection may have ended before the sheet was open")

        // Until well after the collection has ended and the normal
        // partition's lists have been read again.
        Thread.sleep(forTimeInterval: max(0, 50 - Date().timeIntervalSince(started)))
        XCTAssertTrue(name.exists, "the adult source's settings sheet was closed")
        XCTAssertEqual(name.value as? String, "Articles Feed")
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(name)
        XCTAssertTrue(app.navigationBars["Articles Feed"].exists, "the adult source's list was closed")
        XCTAssertTrue(articleRow("Image story").exists)

        // The collection did run and end meanwhile: the normal source has
        // its second article.
        tapLock()
        waitForPartition(Wording.normal)
        openAllUnread()
        let rows = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            self.articleRowsShown().count == 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rows], timeout: timeout), .completed, "rows: \(articleRowsShown().map(\.identifier))")
    }

    // MARK: - Criterion 8: the lock timing

    /// A short absence under "After 1 Minute" does not lock; the setting
    /// survives a relaunch, and a relaunch starts in the normal partition;
    /// "Immediately" locks when the app is left.
    func testLockTiming() {
        launchAtFullWidth(authentication: ["passed", "passed"])
        createCategory("World")
        turnOnAdult()
        enterAdult()
        // Inside the adult partition its settings open without asking.
        tapAdultRow()
        waitFor(turnOffButton)
        XCTAssertTrue(timing("Immediately").isSelected)
        chooseTiming("After 1 Minute")
        leaveAndReturn(seconds: 3)
        // Still unlocked, and its settings still open.
        XCTAssertTrue(turnOffButton.waitForExistence(timeout: 3))
        XCTAssertEqual(partitionLabel(), Wording.adult)
        waitForReport("pool=open", "library=held", "workspace=held")

        // A relaunch starts in the normal partition, with nothing opened,
        // and keeps the setting.
        app.terminate()
        launchAtFullWidth(authentication: ["passed", "passed"])
        XCTAssertEqual(partitionLabel(), Wording.normal)
        XCTAssertFalse(lockButton.exists)
        waitForReport("file=1", Self.closed, "library=released", "workspace=none")
        showCategoryList()
        waitFor(element(AccessibilityID.categoryRow("World")))
        tapAdultRow()
        waitFor(turnOffButton)
        XCTAssertTrue(timing("After 1 Minute").isSelected)
        XCTAssertFalse(timing("Immediately").isSelected)

        // "Immediately" again: leaving locks.
        chooseTiming("Immediately")
        enterAdult()
        leaveAndReturn()
        waitForPartition(Wording.normal)
        XCTAssertFalse(lockButton.exists)
        // Closed; and no menu was used in the adult partition of this
        // launch, so nothing of it is held either.
        waitForReport(Self.closed, Self.dropped)
        expectObjectsReleased("the timing rule, nothing else done")
    }

    // MARK: - Assumption A5: what is presented goes with the workspace

    /// A lock while a context menu is open, and while a confirmation
    /// dialog is open above a sheet: both are gone with the adult
    /// workspace, nothing of them is left on screen, and nothing they
    /// offered was done.
    func testALockClosesAnOpenMenuAndAnOpenDialog() {
        launchAtFullWidth(authentication: ["passed", "passed", "passed", "passed"])
        createCategory("World")
        turnOnAdult()
        enterAdult()
        createCategory("Velvet")

        // A context menu open on the adult category.
        showCategoryList()
        waitFor(element(AccessibilityID.categoryRow("Velvet"))).press(forDuration: 1.2)
        waitFor(app.buttons["Category Settings"])
        leaveAndReturn()
        waitForAbsence(app.buttons["Category Settings"])
        waitForPartition(Wording.normal)
        waitForReport(Self.closed, Self.dropped)
        showCategoryList()
        waitFor(element(AccessibilityID.categoryRow("World")))
        assertNothingShown(of: ["Velvet"], on: "the category list after a lock with a menu open")

        // The deletion dialog, which names the category, above its
        // settings sheet.
        enterAdult()
        openCategorySettings("Velvet")
        waitFor(button(AccessibilityID.deleteCategoryButton)).tap()
        waitFor(deletionDialogButton("Delete Category"))
        leaveAndReturn()
        waitForAbsence(deletionDialogButton("Delete Category"))
        waitForAbsence(app.textFields[AccessibilityID.nameField])
        waitForPartition(Wording.normal)
        waitForReport(Self.closed, Self.dropped)
        assertNothingShown(of: ["Velvet"], on: "the normal partition after a lock with a dialog open")
        XCTAssertFalse(app.alerts.firstMatch.exists)

        // Nothing was deleted.
        enterAdult()
        showCategoryList()
        waitFor(element(AccessibilityID.categoryRow("Velvet")))
    }

    // MARK: - A kept reference fails quietly

    /// A category save of the adult partition that is still waiting when
    /// the partition locks runs into the closed library: it fails, nothing
    /// says so in the normal partition, and nothing was saved.
    func testASaveOverrunByALockFailsQuietly() {
        // The first category save of each workspace waits 6 seconds.
        launchAtFullWidth(slowNextSave: 6, authentication: ["passed", "passed", "passed"])
        turnOnAdult()
        enterAdult()
        openNewCategory()
        let field = app.textFields[AccessibilityID.nameField]
        field.tap()
        field.typeText("Velvet\n")
        tapSave()
        // The timing rule ("immediately") locks while the save waits.
        leaveAndReturn()
        waitForAbsence(field)
        waitForPartition(Wording.normal)
        waitForReport(Self.closed, Self.dropped)
        // Past the moment the save ran and failed.
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 8), "the failed save of the locked partition raised an alert")
        assertNothingShown(of: ["Velvet"], on: "the normal partition")
        XCTAssertTrue(report.contains(Self.closed), report)
        // Nothing was saved: the adult partition has no category.
        enterAdult()
        showCategoryList()
        waitFor(element(AccessibilityID.noCategories))
        XCTAssertFalse(element(AccessibilityID.categoryRow("Velvet")).exists)
    }

    // MARK: - Criterion 7, without a menu

    /// The timing rule locks while the browser is open on an adult web
    /// page and a sheet is open above it: the library is closed at once
    /// and the workspace is gone; on the panes, where nothing here uses a
    /// menu, the library object, the browser model and with it the web
    /// view are gone from memory too.
    func testALockWithTheBrowserAndASheetOpenReleasesEverything() {
        launchAtFullWidth(authentication: ["passed", "passed"])
        turnOnAdult()
        enterAdult()
        createCategory("Velvet")
        addWebPageSource(to: "Velvet")
        openWebPageSource(in: "Velvet")
        waitForReport("pool=open", "library=held", "workspace=held", "browser=held")
        if usesTabs {
            leaveAndReturn()
        } else {
            // The sidebar's New Category button, which is no menu.
            openNewCategory()
            leaveAndReturn()
            waitForAbsence(app.textFields[AccessibilityID.nameField])
        }
        waitForAbsence(moreMenu)
        waitForPartition(Wording.normal)
        waitForReport(Self.closed, Self.dropped)
        expectObjectsReleased("the timing rule, the browser and a sheet open")
    }

    /// Settings › Adult Partition opened from the normal partition is
    /// closed by the rule that locks: it stays across a short absence under
    /// "After 1 Minute" and is closed by one under "Immediately".
    func testSettingsScreenOfTheNormalPartitionClosesByTheLockRule() {
        launchAtFullWidth(authentication: ["passed", "passed"])
        turnOnAdult()
        chooseTiming("After 1 Minute")
        leaveAndReturn(seconds: 3)
        XCTAssertTrue(turnOffButton.waitForExistence(timeout: 3), "the screen closed under After 1 Minute")
        chooseTiming("Immediately")
        leaveAndReturn()
        waitForAbsence(turnOffButton)
        // Settings itself is still shown, and the partition is still on.
        waitFor(adultRow)
        XCTAssertEqual(partitionLabel(), Wording.normal)
        // Opening it again asks again.
        tapAdultRow()
        waitFor(turnOffButton)
    }

    // MARK: - Criterion 15

    /// The refresh settings are the app's, not a partition's: a retention
    /// chosen in the adult partition is the normal partition's too.
    func testARefreshSettingChangedInOnePartitionIsTheOthers() {
        launchAtFullWidth(authentication: ["passed", "passed"])
        turnOnAdult()
        enterAdult()
        openSettings()
        waitFor(element(AccessibilityID.refreshRow)).tap()
        XCTAssertTrue(waitFor(app.buttons["30 Days"].firstMatch).isSelected)
        let week = scrollTo(app.buttons["7 Days"].firstMatch)
        week.tap()
        let chosen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: week)
        XCTAssertEqual(XCTWaiter.wait(for: [chosen], timeout: timeout), .completed)
        scrollTo(app.buttons["Manual Only"].firstMatch).tap()

        tapLock()
        waitForPartition(Wording.normal)
        openSettings()
        waitFor(element(AccessibilityID.refreshRow)).tap()
        XCTAssertTrue(scrollTo(app.buttons["7 Days"].firstMatch).isSelected, "the normal partition kept its own retention")
        XCTAssertFalse(app.buttons["30 Days"].firstMatch.isSelected)
        XCTAssertTrue(scrollTo(app.buttons["Manual Only"].firstMatch).isSelected, "the normal partition kept its own interval")
    }
}
