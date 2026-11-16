import XCTest

/// RD18: turning the adult partition on, entering it through device
/// authentication (the debug stand-in), its own content, and what a model
/// of the workspace that is not shown may not do. Against the fixture
/// transport only.
final class AdultPartitionTests: AdultTestCase {
    // MARK: - Criterion 1: a fresh install

    /// No partition switch on Today, Library and Starred (the sidebar on the
    /// panes), and no adult database file. The Settings row is there: the
    /// feature switch is on, the partition is off.
    func testFreshInstallHasNoSwitchAndNoAdultFile() {
        launchAtFullWidth()
        waitForReport("file=0", Self.closed, "library=released", "workspace=none")
        if app.tabBars.firstMatch.exists {
            for tab in 0..<3 {
                app.tabBars.buttons.element(boundBy: tab).tap()
                XCTAssertFalse(partitionSwitch.waitForExistence(timeout: 1), "the switch is on tab \(tab)")
                XCTAssertFalse(lockButton.exists)
            }
        } else {
            openSidebarIfNeeded()
            XCTAssertFalse(partitionSwitch.waitForExistence(timeout: 1))
            XCTAssertFalse(lockButton.exists)
        }
        // Looking at Settings › Adult Partition creates nothing either.
        tapAdultRow()
        waitFor(adultToggle)
        XCTAssertEqual(adultToggle.value as? String, "0")
        XCTAssertTrue(element(AccessibilityID.adultExplanation).exists)
        XCTAssertFalse(turnOffButton.exists)
        waitForReport("file=0", Self.closed, "library=released", "workspace=none")
    }

    // MARK: - Criterion 2: turning on

    /// A cancelled, a failed and an unavailable authentication change
    /// nothing and show their sentence; a passed one creates the file,
    /// shows the "on" contents and the switch, and leaves the app in the
    /// normal partition.
    func testTurningOn() {
        launchAtFullWidth(authentication: ["cancelled", "failed", "unavailable", "interrupted", "passed"])
        tapAdultRow()
        for sentence in [Wording.notTurnedOn, Wording.notTurnedOn, Wording.passcodeNeeded] {
            flipOn()
            answerAlert(sentence)
            XCTAssertEqual(adultToggle.value as? String, "0", "the switch turned on after \(sentence)")
            XCTAssertFalse(turnOffButton.exists)
            XCTAssertTrue(report.contains("file=0"), report)
        }
        // An interrupted authentication (the app was sent away) says nothing.
        flipOn()
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 2))
        XCTAssertEqual(adultToggle.value as? String, "0")
        XCTAssertTrue(report.contains("file=0"), report)

        flipOn()
        waitFor(turnOffButton)
        XCTAssertFalse(adultToggle.exists)
        waitFor(timing("Immediately"))
        XCTAssertTrue(timing("Immediately").isSelected)
        // The file exists, nothing holds it open, and no adult workspace
        // was built: the app is still in the normal partition.
        waitForReport("file=1", Self.closed, "library=released", "workspace=none")
        if app.tabBars.firstMatch.exists {
            for tab in 0..<3 {
                app.tabBars.buttons.element(boundBy: tab).tap()
                XCTAssertEqual(waitFor(partitionSwitch).label, Wording.normal, "tab \(tab)")
                XCTAssertFalse(lockButton.exists)
            }
            // Not on Settings, and not on a pushed screen.
            app.tabBars.buttons.element(boundBy: 3).tap()
            XCTAssertFalse(partitionSwitch.waitForExistence(timeout: 1))
        } else {
            XCTAssertEqual(partitionLabel(), Wording.normal)
            XCTAssertFalse(lockButton.exists)
        }
    }

    // MARK: - Criterion 3: choosing Adult

    /// A cancelled or failed authentication leaves the app in the normal
    /// partition with the sentence. A passed one whose answer arrives while
    /// the scene is still inactive, as the system's prompt answers, shows
    /// the adult partition at the root of the current tab, with the
    /// capsule reading "Adult" and the lock button.
    func testChoosingAdult() {
        launchAtFullWidth(authentication: ["passed", "cancelled", "failed", "unavailable", "passed@inactive"])
        createCategory("World")
        turnOnAdult()
        for sentence in [Wording.stillLocked, Wording.stillLocked, Wording.passcodeNeeded] {
            chooseAdult()
            answerAlert(sentence)
            XCTAssertEqual(partitionLabel(), Wording.normal)
            XCTAssertFalse(lockButton.exists)
            XCTAssertTrue(report.contains("workspace=none"), report)
        }
        // From the Library root (tabs) or with the category selected
        // (panes): the adult partition opens at the root of that tab.
        if usesTabs {
            showCategoryList()
        } else {
            openCategoryList("World")
        }
        chooseAdult()
        // The stand-in answers once the scene is inactive: Control Centre
        // stands for the system's prompt.
        XCTAssertFalse(lockButton.waitForExistence(timeout: 2), "the adult partition was shown before the answer")
        showControlCentre()
        hideControlCentre()
        waitForPartition(Wording.adult)
        XCTAssertTrue(lockButton.exists)
        XCTAssertEqual(lockButton.label, "Lock the adult partition")
        // The root of the current tab, with nothing of the normal partition.
        if usesTabs {
            XCTAssertTrue(app.tabBars.buttons.element(boundBy: 1).isSelected, "not on the Library tab")
            waitFor(button(AccessibilityID.addMenu))
        }
        XCTAssertFalse(element(AccessibilityID.categoryRow("World")).exists)
        waitForReport("file=1", "pool=open", "library=held", "workspace=held")
        // Criterion 18: both controls are at least 44 pt tall.
        // (The frames are reported as 43.999999999999986 at some scales.)
        XCTAssertGreaterThanOrEqual(partitionSwitch.frame.height, 43.99)
        XCTAssertGreaterThanOrEqual(lockButton.frame.height, 43.99)
        XCTAssertGreaterThanOrEqual(lockButton.frame.width, 43.99)

        // The lock button returns to the normal partition, same tab.
        tapLock()
        waitForPartition(Wording.normal)
        XCTAssertFalse(lockButton.exists)
        waitFor(element(AccessibilityID.categoryRow("World")))
        // Closed; and since no menu was used, no article opened and no row
        // swiped in the adult partition, nothing of it is held either.
        waitForReport(Self.closed, Self.dropped)
        expectObjectsReleased("the lock button, nothing else done")
    }

    /// The other stand-in order (decision 15): the answer comes only after
    /// the scene has been inactive and is active again.
    func testChoosingAdultAnsweredAfterTheSceneIsActiveAgain() {
        launchAtFullWidth(authentication: ["passed", "passed@reactivated"])
        turnOnAdult()
        chooseAdult()
        showControlCentre()
        hideControlCentre()
        waitForPartition(Wording.adult)
        XCTAssertTrue(lockButton.exists)
    }

    // MARK: - Criterion 14: an unlock during which the app was left

    /// The scene enters the background while the authentication is still
    /// unanswered: its result is discarded and the app stays in the normal
    /// partition, with nothing built.
    func testUnlockIsDiscardedWhenTheAppWasLeft() {
        launchAtFullWidth(authentication: ["passed", "passed@reactivated", "passed"])
        turnOnAdult()
        chooseAdult()
        leaveAndReturn()
        XCTAssertFalse(lockButton.waitForExistence(timeout: 3))
        XCTAssertEqual(partitionLabel(), Wording.normal)
        XCTAssertFalse(app.alerts.firstMatch.exists, "a discarded unlock says nothing")
        waitForReport(Self.closed, "library=released", "workspace=none")
        // And the gate is free for the next choice.
        enterAdult()
    }

    // MARK: - Criterion 4: the adult partition's own content

    /// In the adult partition a category and a source can be added and
    /// refreshed and an article starred; none of it is in the normal
    /// library, and the normal partition's content is not shown there.
    func testAdultContentIsItsOwn() {
        launchAtFullWidth(authentication: ["passed", "passed", "passed"])
        createCategory("World")
        addSource(Fixture.feed, to: "World")
        turnOnAdult()
        enterAdult()

        // Nothing of the normal partition.
        showCategoryList()
        XCTAssertFalse(element(AccessibilityID.categoryRow("World")).exists)
        assertNothingShown(of: ["World", "Fixture Feed", "Fixture story"], on: "the adult category list")
        // Its own category and source, refreshed.
        createCategory("Velvet")
        addSource(Fixture.articles, to: "Velvet")
        openSourceList("Articles Feed", in: "Velvet")
        waitFor(articleRow("Image story"))
        pullList()
        waitFor(articleRow("Plain story"))
        assertNothingShown(of: ["Fixture story"], on: "the adult source list")
        swipeAction(on: waitFor(articleRow("Linkless story")), leading: false, "Star")
        waitForLabel(articleRow("Linkless story"), containing: ", Starred")
        openStarred()
        waitFor(articleRow("Linkless story"))
        showToday()
        waitFor(element(AccessibilityID.todayCategoryRow("Velvet")))
        XCTAssertFalse(element(AccessibilityID.todayCategoryRow("World")).exists)

        // Back in the normal partition: none of it.
        tapLock()
        waitForPartition(Wording.normal)
        let adultNames = ["Velvet", "Articles Feed", "Image story", "Plain story", "Linkless story"]
        showToday()
        waitFor(element(AccessibilityID.todayCategoryRow("World")))
        assertNothingShown(of: adultNames, on: "Today")
        openStarred()
        waitFor(element(AccessibilityID.starredEmpty))
        assertNothingShown(of: adultNames, on: "Starred")
        expand("World")
        waitFor(sourceRow("Fixture Feed"))
        assertNothingShown(of: adultNames, on: "the category list")
        openAllUnread()
        waitFor(articleRow("Fixture story one"))
        assertNothingShown(of: adultNames, on: "All Unread")

        // And it is all still there in the adult partition.
        enterAdult()
        openStarred()
        waitFor(articleRow("Linkless story"))
        expand("Velvet")
        waitFor(sourceRow("Articles Feed"))
    }
}
