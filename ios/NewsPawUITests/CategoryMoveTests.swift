import XCTest

/// RD19 criteria 9 to 13 in the app: moving a category to the other
/// partition, in both directions, through the partition switch's own
/// unlock for a normal category; the confirmation and its messages; a
/// deletion that fails once; a lock during a run.
final class CategoryMoveTests: IsolationTestCase {
    enum Move {
        static let toAdultQuestion = "Move “World” to the adult partition?"
        static let toNormalQuestion = "Move “Velvet” to the normal partition?"
        static let stays = "Already in the adult partition, so they stay here in “World”: Articles Feed"
        static let copiedNotRemoved = "“Velvet” was copied to the normal partition but could not be removed here. Move it again to finish."
    }

    /// Launches with the move's debug options.
    func launchForMoves(authentication: [String], failDeletionOnce: Bool = false, pause: Int? = nil) {
        app.terminate()
        let application = XCUIApplication()
        if failDeletionOnce {
            application.launchEnvironment[UITestLaunchKey.failNextMoveDeletion] = "1"
        }
        if let pause {
            application.launchEnvironment[UITestLaunchKey.moveStepPause] = String(pause)
        }
        launch(application, authentication: authentication)
        rotate(.portrait)
        requireFullWidth()
    }

    // MARK: - Criteria 9 and 11: adult → normal with the row and the article open

    /// An adult category moves to the normal partition while its list is
    /// on screen and, on the panes, one of its articles with a body image
    /// is open beside it: afterwards the adult image cache reads zero and
    /// stays zero, nothing of the category is in the adult partition, and
    /// the normal partition holds it and collects its source at its entry.
    func testMoveAdultToNormalWithTheListAndTheArticleOpen() {
        launchForMoves(authentication: ["passed", "passed", "passed"])
        turnOnAdult()
        enterAdult()
        createCategory("Velvet")
        addSource(Isolation.readingFeed, to: "Velvet")
        openCategoryList("Velvet")
        openArticle("Picture story")
        waitFor(element(AccessibilityID.readingImage(1)))
        // The body's picture is in the adult cache.
        waitForImageCache(zero: false)
        openCategoryList("Velvet")
        // Read at its first opening: listed under All.
        chooseFilter("All")
        if !usesTabs {
            // The panes: the article open beside the list.
            openArticle("Picture story")
            waitFor(element(AccessibilityID.readingImage(1)))
        }
        // The category's settings from the list's own menu, over the list.
        openListSettings(source: false)
        waitFor(app.textFields[AccessibilityID.nameField])
        tapMove()
        let alert = waitForAlert()
        XCTAssertTrue(alert.staticTexts[Move.toNormalQuestion].exists, "\(alertTexts())")
        XCTAssertTrue(alertTexts().contains { $0.contains("are deleted with their translations and overviews") }, "\(alertTexts())")
        XCTAssertFalse(alertTexts().contains { $0.contains("so they stay here") }, "\(alertTexts())")
        capture("move-confirmation-to-normal")
        waitFor(button(AccessibilityID.confirmMoveButton)).tap()

        // Every route that showed it is closed, and the old cache emptied.
        waitForAbsence(app.textFields[AccessibilityID.nameField])
        waitForAbsence(element(AccessibilityID.readingTitle))
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 2), "a move that worked says nothing: \(alertTexts())")
        waitForImageCache(zero: true)
        XCTAssertFalse(categoriesShown().contains("Velvet"), "\(categoriesShown())")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(imageCacheSize(), zero, "something of the moved category was cached again")

        // The normal partition holds it, and collects it at its entry.
        tapLock()
        waitForPartition(Wording.normal)
        XCTAssertTrue(categoriesShown().contains("Velvet"))
        openSourceList("Reading Feed", in: "Velvet")
        waitFor(articleRow("Picture story"))
    }

    // MARK: - Criteria 10, 11 and 13: normal → adult through the unlock

    /// "Move to Adult Partition…" unlocks with the partition switch's own
    /// authentication: refused, it leaves the normal partition with the
    /// sentence and drops the move (a later plain unlock shows nothing);
    /// passed, the adult partition shows the confirmation, which lists the
    /// source that stays; Cancel stays there with nothing written; a lock
    /// while it is shown writes nothing; Move moves the other source.
    func testMoveNormalToAdultThroughTheUnlock() {
        launchForMoves(authentication: ["passed", "passed", "cancelled", "passed", "passed", "passed", "passed"])
        // The adult partition already has the articles feed.
        turnOnAdult()
        enterAdult()
        createCategory("Velvet")
        addSource(Fixture.articles, to: "Velvet")
        tapLock()
        waitForPartition(Wording.normal)
        createCategory("World")
        addSource(Fixture.articles, to: "World")
        addSource(Fixture.feed, to: "World")

        // Refused: the normal partition, the sentence, nothing written.
        openCategorySheet("World")
        tapMove()
        answerAlert(Wording.stillLocked)
        waitForPartition(Wording.normal)
        waitForReport(Self.closed)
        // A later plain unlock shows no confirmation.
        enterAdult()
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 3), "the dropped move asked: \(alertTexts())")
        XCTAssertEqual(categoriesShown(), ["Velvet"])
        tapLock()
        waitForPartition(Wording.normal)

        // Passed: the adult partition with the confirmation; Cancel.
        openCategorySheet("World")
        tapMove()
        let alert = waitForAlert()
        XCTAssertEqual(partitionSwitch.exists ? partitionSwitch.label : Wording.adult, Wording.adult)
        XCTAssertTrue(alert.staticTexts[Move.toAdultQuestion].exists, "\(alertTexts())")
        XCTAssertTrue(alertTexts().contains { $0.contains(Move.stays) }, "\(alertTexts())")
        capture("move-confirmation-to-adult")
        alert.buttons["Cancel"].tap()
        waitForAbsence(alert)
        waitForPartition(Wording.adult)
        XCTAssertEqual(categoriesShown(), ["Velvet"])

        // A lock while the confirmation is shown writes nothing.
        tapLock()
        waitForPartition(Wording.normal)
        openCategorySheet("World")
        tapMove()
        _ = waitForAlert()
        leaveAndReturn()
        waitForPartition(Wording.normal)
        XCTAssertFalse(app.alerts.firstMatch.exists, "the confirmation outlived the lock")
        waitForReport(Self.closed, Self.dropped)
        expand("World")
        waitFor(sourceRow("Fixture Feed"))
        waitFor(sourceRow("Articles Feed"))

        // Move.
        openCategorySheet("World")
        tapMove()
        _ = waitForAlert()
        waitFor(button(AccessibilityID.confirmMoveButton)).tap()
        waitForAbsence(app.alerts.firstMatch)
        // The adult partition collects the moved source at once.
        expand("World")
        waitFor(sourceRow("Fixture Feed"))
        XCTAssertFalse(sourceRow("Articles Feed").exists, "the source that stays was moved")
        openSourceList("Fixture Feed", in: "World")
        waitFor(articleRow("Fixture story one"))
        XCTAssertEqual(Set(categoriesShown()), ["Velvet", "World"])

        // The normal "World" holds exactly the source that stayed.
        tapLock()
        waitForPartition(Wording.normal)
        expand("World")
        waitFor(sourceRow("Articles Feed"))
        XCTAssertFalse(sourceRow("Fixture Feed").exists, "the moved source is still in the normal partition")
    }

    // MARK: - Criterion 12: a deletion that fails, and moving again

    /// The deletion fails once (debug option): the category was copied and
    /// is in both, the message says so; moving again finishes.
    func testADeletionThatFailsAndMovingAgain() {
        launchForMoves(authentication: ["passed", "passed", "passed"], failDeletionOnce: true)
        turnOnAdult()
        enterAdult()
        createCategory("Velvet")
        addSource(Fixture.feed, to: "Velvet")
        openCategorySheet("Velvet")
        tapMove()
        _ = waitForAlert()
        waitFor(button(AccessibilityID.confirmMoveButton)).tap()
        let message = waitForAlert()
        XCTAssertTrue(message.staticTexts[Move.copiedNotRemoved].exists, "\(alertTexts())")
        capture("move-copied-not-removed")
        message.buttons["OK"].tap()
        waitForAbsence(message)
        // The sheet stays open after a failure; it is closed by hand.
        waitFor(button(AccessibilityID.cancelButton)).tap()
        waitForAbsence(app.textFields[AccessibilityID.nameField])
        // Still here, with its source.
        expand("Velvet")
        waitFor(sourceRow("Fixture Feed"))

        openCategorySheet("Velvet")
        tapMove()
        let again = waitForAlert()
        XCTAssertTrue(again.staticTexts[Move.toNormalQuestion].exists, "\(alertTexts())")
        XCTAssertFalse(alertTexts().contains { $0.contains("so they stay here") }, "the copy counted as a source that stays: \(alertTexts())")
        waitFor(button(AccessibilityID.confirmMoveButton)).tap()
        waitForAbsence(app.textFields[AccessibilityID.nameField])
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 2), "\(alertTexts())")
        XCTAssertFalse(categoriesShown().contains("Velvet"))

        tapLock()
        waitForPartition(Wording.normal)
        XCTAssertEqual(categoriesShown().filter { $0 == "Velvet" }.count, 1)
        expand("Velvet")
        waitFor(sourceRow("Fixture Feed"))
    }

    // MARK: - Review round 2: the editor is locked while a move runs

    /// An adult → normal move held between its steps (debug option): the
    /// category's sheet stays on screen, and neither its name nor Save can
    /// be used until the move has ended.
    func testTheSheetIsLockedWhileAMoveRuns() {
        launchForMoves(authentication: ["passed", "passed"], pause: 6)
        turnOnAdult()
        enterAdult()
        createCategory("Velvet")
        addSource(Fixture.feed, to: "Velvet")
        openCategorySheet("Velvet")
        tapMove()
        _ = waitForAlert()
        waitFor(button(AccessibilityID.confirmMoveButton)).tap()
        waitForAbsence(app.alerts.firstMatch)
        // Held between the copy and the deletion.
        let field = app.textFields[AccessibilityID.nameField]
        XCTAssertTrue(field.exists, "the sheet closed before the move ended")
        XCTAssertFalse(field.isEnabled, "the name could be edited during the move")
        XCTAssertFalse(button(AccessibilityID.saveButton).isEnabled, "Save could be used during the move")
        // The move ends and takes the sheet with it.
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 60), .completed)
        XCTAssertFalse(categoriesShown().contains("Velvet"))
    }

    /// A normal → adult move held between its copy and its deletion:
    /// Turn Off stays dimmed until the move has ended, so Delete cannot
    /// remove the library the category was copied into before the move
    /// deletes it from the normal one.
    func testTurnOffWaitsForAMove() {
        launchForMoves(authentication: ["passed", "passed"], pause: 20)
        createCategory("World")
        addSource(Fixture.articles, to: "World")
        turnOnAdult()
        openCategorySheet("World")
        tapMove()
        _ = waitForAlert()
        waitFor(button(AccessibilityID.confirmMoveButton)).tap()
        waitForAbsence(app.alerts.firstMatch)
        openAdultSettings()
        XCTAssertFalse(scrollTo(turnOffButton).isEnabled, "Turn Off could be used during the move")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: turnOffButton)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 60), .completed, "Turn Off stayed dimmed after the move")
    }

    // MARK: - Review round 3: one move at a time across a lock

    /// A normal → adult move held between its copy and its deletion, then a
    /// lock and a new unlock: the new adult workspace shows the copy of
    /// “World”, and until the first move has ended Turn Off is dimmed and
    /// the copy's sheet can neither begin a second move nor be edited.
    func testNoSecondMoveAfterALockAndANewUnlock() {
        // Held 120 s: on the iPad the sheet is reached about 65 s after the
        // confirmation, past a 60 s hold.
        launchForMoves(authentication: ["passed", "passed", "passed"], pause: 120)
        createCategory("World")
        addSource(Fixture.articles, to: "World")
        turnOnAdult()
        openCategorySheet("World")
        tapMove()
        _ = waitForAlert()
        waitFor(button(AccessibilityID.confirmMoveButton)).tap()
        waitForAbsence(app.alerts.firstMatch)
        // Held between the copy and the deletion: lock, and unlock again.
        tapLock()
        waitForPartition(Wording.normal)
        enterAdult()
        openAdultSettings()
        XCTAssertFalse(scrollTo(turnOffButton).isEnabled, "Turn Off could be used while the first move ran")
        openCategorySheet("World")
        let move = scrollTo(moveButton)
        XCTAssertFalse(move.isEnabled, "a second move could be begun while the first ran")
        XCTAssertFalse(app.textFields[AccessibilityID.nameField].isEnabled, "the name could be edited while the first move ran")
        // Once the first move has ended a move can be begun again.
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: move)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 120), .completed, "the move button stayed disabled after the move")
    }

    // MARK: - Review round 4: the sources while a move runs (J1)

    /// A normal → adult move held between its copy and its deletion, then
    /// a lock back to the normal partition: until the move has ended the
    /// source's row has Pause and Delete dimmed, and its Source Settings
    /// cannot change its pause or category or be saved; then the category
    /// leaves the normal partition with the source as the move copied it.
    func testSourcesAreLockedWhileAMoveRuns() {
        launchForMoves(authentication: ["passed", "passed"], pause: 120)
        createCategory("World")
        addSource(Fixture.articles, to: "World")
        turnOnAdult()
        openCategorySheet("World")
        tapMove()
        _ = waitForAlert()
        waitFor(button(AccessibilityID.confirmMoveButton)).tap()
        waitForAbsence(app.alerts.firstMatch)
        // Held between the copy and the deletion: back to normal.
        tapLock()
        waitForPartition(Wording.normal)
        expand("World")
        waitFor(sourceRow("Articles Feed")).press(forDuration: 1.2)
        let pause = app.buttons.matching(NSPredicate(format: "label IN %@", ["Pause", "暂停"])).firstMatch
        XCTAssertFalse(waitFor(pause).isEnabled, "Pause could be used during the move")
        let delete = app.buttons.matching(NSPredicate(format: "label IN %@", ["Delete", "删除"])).firstMatch
        XCTAssertFalse(delete.isEnabled, "Delete could be used during the move")
        tapOutsideDialog()
        waitForAbsence(pause)

        openSourceSettings("Articles Feed", in: "World")
        XCTAssertFalse(app.switches[AccessibilityID.pausedToggle].isEnabled, "the pause could be changed during the move")
        XCTAssertFalse(element(AccessibilityID.sourceCategoryPicker).isEnabled, "the category could be changed during the move")
        XCTAssertFalse(button(AccessibilityID.saveButton).isEnabled, "Source Settings could be saved during the move")

        // The move ends: the category has left the normal partition.
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            !self.app.textFields[AccessibilityID.nameField].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 150), .completed, "the source's sheet stayed after the move")
        XCTAssertFalse(categoriesShown().contains("World"), "the move did not finish: \(categoriesShown())")
    }

    // MARK: - Batch 2: imports while a move runs

    /// A normal → adult move held between its copy and its deletion, then
    /// a lock back to the normal partition: Settings › Data's Import OPML
    /// is dimmed until the move has ended (an import writes categories and
    /// sources, which RD19's table refuses during a move).
    func testImportsAreRefusedWhileAMoveRuns() {
        launchForMoves(authentication: ["passed", "passed"], pause: 120)
        createCategory("World")
        addSource(Fixture.articles, to: "World")
        turnOnAdult()
        openCategorySheet("World")
        tapMove()
        _ = waitForAlert()
        waitFor(button(AccessibilityID.confirmMoveButton)).tap()
        waitForAbsence(app.alerts.firstMatch)
        // Held between the copy and the deletion: back to normal.
        tapLock()
        waitForPartition(Wording.normal)
        openSettings()
        waitFor(element(AccessibilityID.dataRow)).tap()
        let opml = waitFor(button(AccessibilityID.importOPMLButton))
        XCTAssertFalse(opml.isEnabled, "Import OPML could be used during the move")
        // The move ends: the import can begin again.
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: opml)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 150), .completed, "Import OPML stayed dimmed after the move")
    }

    // MARK: - Criterion 12: a lock during a normal → adult run

    /// A normal → adult move whose run a lock overtakes (the run waits
    /// between its steps, debug option) and that returns moved still
    /// leaves the normal image cache empty.
    func testALockDuringANormalToAdultRunStillEmptiesTheNormalCache() {
        launchForMoves(authentication: ["passed", "passed"], pause: 6)
        createCategory("World")
        addSource(Fixture.articles, to: "World")
        openCategoryList("World")
        waitFor(articleRow("Image story"))
        waitForImageCache(zero: false)
        turnOnAdult()
        openCategorySheet("World")
        tapMove()
        _ = waitForAlert()
        waitFor(button(AccessibilityID.confirmMoveButton)).tap()
        waitForAbsence(app.alerts.firstMatch)
        // The run waits between its steps: the lock comes now.
        tapLock()
        waitForPartition(Wording.normal)
        waitForReport(Self.closed, Self.dropped)
        waitForImageCache(zero: true, seconds: 40)
        XCTAssertFalse(categoriesShown().contains("World"), "the move did not finish: \(categoriesShown())")
    }
}
