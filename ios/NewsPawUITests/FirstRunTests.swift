import XCTest

/// RD21 (ux S12, S1; spec N01, N02): the first run's three steps, its
/// end on Today, the suggested categories, Today with no source, and when
/// it comes back. Criteria 1–8 and the first run's part of 9; assumptions
/// A2 and A3.
final class FirstRunTests: FirstRunTestCase {
    /// Criteria 1–4 and 6, assumptions A2 and A3: with the system language
    /// Japanese, step 1 preselects Japanese; step 2 pushes RD13's form,
    /// whose Save returns to step 2 with "Passed"; step 3 creates World at
    /// "Add a Source…", where BBC World is added into it; Done ends on
    /// Today, the library is refreshed and World's titles are translated
    /// into Japanese. Nothing names the adult partition, and its file is
    /// never made.
    func testCompletePath() {
        launchFirstRun(arguments: ["-AppleLanguages", "(ja)"])
        waitFor(firstRun)
        assertNoContainers()
        waitForStep(1)
        XCTAssertFalse(stepBackButton.exists, "step 1 has no Back")
        XCTAssertTrue(skipButton.exists)
        // A3: the system language reaches the preselection.
        XCTAssertTrue(waitFor(option("Japanese")).isSelected, "Japanese is not preselected")
        XCTAssertFalse(option("Simplified Chinese").isSelected)
        assertNothingNamesTheAdultPartition("step 1")
        continueButton.tap()

        waitForStep(2)
        XCTAssertTrue(waitFor(stepBackButton).exists)
        let note = element(AccessibilityID.firstRunText)
        XCTAssertTrue(note.label.contains("are sent to this service"), note.label)
        XCTAssertTrue(note.label.contains("The key stays on this device"), note.label)
        XCTAssertTrue(waitFor(primaryModelRow).label.contains("Not set up"), primaryModelRow.label)
        assertNothingNamesTheAdultPartition("step 2")
        // Criterion 3: Cancel on the untouched form returns to step 2.
        primaryModelRow.tap()
        waitFor(button(AccessibilityID.cancelButton)).tap()
        waitForStep(2)
        XCTAssertTrue(waitFor(primaryModelRow).label.contains("Not set up"), primaryModelRow.label)
        // A2: RD13's form, pushed from the first run's stack, saves and
        // pops back to step 2 with the new state.
        primaryModelRow.tap()
        setUpTranslatorInForm()
        waitForStep(2)
        waitLong(for: primaryModelRow, containing: "Passed")
        XCTAssertTrue(primaryModelRow.label.contains(Self.translatorModel), primaryModelRow.label)
        assertNoContainers()
        continueButton.tap()

        waitForStep(3)
        // ux S12's order: adding sources first, wholly above the bottom bar
        // without scrolling (fix round 1).
        XCTAssertLessThan(waitFor(addSourceButton).frame.minY, waitFor(categoryRow("world")).frame.minY)
        XCTAssertLessThanOrEqual(addSourceButton.frame.maxY, doneButton.frame.minY, "Add a Source… is under Done")
        for group in ["world", "japan", "australia", "china", "tech", "ai"] {
            XCTAssertFalse(isTicked(group), "\(group) starts ticked")
        }
        XCTAssertEqual(categoryRow("world").label, "World")
        XCTAssertEqual(categoryRow("tech").label, "Tech")
        assertNothingNamesTheAdultPartition("step 3")
        tick("world")
        XCTAssertTrue(isTicked("world"))
        // "Add a Source…" creates World first, so the picker offers it.
        addSourceButton.tap()
        waitFor(app.textFields[AccessibilityID.addressField])
        waitFor(button(AccessibilityID.suggestedSourcesRow)).tap()
        waitFor(button(AccessibilityID.suggestedSource("BBC News · World"))).tap()
        waitFor(element(AccessibilityID.confirmAddress))
        chooseCategoryAndSave("World")
        waitForAbsence(app.textFields[AccessibilityID.addressField])
        let world = waitFor(categoryRow("world"))
        waitLong(for: world, containing: "Added")
        XCTAssertFalse(world.isEnabled, "an added category can be unticked")
        doneButton.tap()

        waitForShellOnToday()
        waitForAdultFileAbsent()
        // The library was refreshed at the end, and World's titles are
        // translated into the language chosen in step 1.
        openCategoryList("World")
        let story = waitFor(articleRow("Fixture world story"))
        waitLong(for: story, containing: Translation.translated("Fixture world story", "ja"))
        openTranslationSettings()
        XCTAssertTrue(waitFor(option("Japanese")).isSelected, "the reading language was not stored")
    }

    /// Criteria 7 and 2 (Skip stores nothing): Skip on each step ends on
    /// Today with "No sources yet" and "Add a Source"; a feed added through
    /// it opens an article showing the original. The reading language
    /// stays the standard.
    func testSkipPath() {
        launchFirstRun(arguments: ["-AppleLanguages", "(ja)"])
        waitForStep(1)
        XCTAssertTrue(option("Japanese").isSelected)
        skipButton.tap()
        waitForStep(2)
        skipButton.tap()
        waitForStep(3)
        tick("japan")
        assertNothingNamesTheAdultPartition("step 3")
        skipButton.tap()

        waitForShellOnToday()
        let empty = waitFor(element(AccessibilityID.todayEmpty))
        XCTAssertEqual(empty.label, "No sources yet")
        assertNothingNamesTheAdultPartition("Today")
        // Skip created nothing: the ticked Japan is not a category.
        showCategoryList()
        waitFor(element(AccessibilityID.noCategories))
        showToday()
        waitFor(button(AccessibilityID.todayAddSourceButton)).tap()
        // Add source of the normal partition, with its suggested sources.
        waitFor(button(AccessibilityID.suggestedSourcesRow))
        detect(Fixture.articles)
        waitFor(element(AccessibilityID.confirmAddress))
        saveIntoNewCategory("News")
        waitForAbsence(app.textFields[AccessibilityID.addressField])
        openCategoryList("News")
        openArticle("Plain story")
        XCTAssertFalse(element(AccessibilityID.readingOriginalTitle).exists, "the article shows a translation")
        waitForAdultFileAbsent()
        // Skip stored no reading language: the standard stays.
        backToList()
        openTranslationSettings()
        XCTAssertTrue(waitFor(option("Simplified Chinese")).isSelected)
    }

    /// Criterion 1: Back returns to the step before; in landscape too
    /// there is no tab bar, sidebar or partition switch, and on iPad the
    /// content is at most 640 pt wide.
    func testBackAndBothOrientations() {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            launchFirstRun(orientation)
            waitForStep(1)
            assertNoContainers()
            continueButton.tap()
            waitForStep(2)
            stepBackButton.tap()
            waitForStep(1)
            continueButton.tap()
            waitForStep(2)
            continueButton.tap()
            waitForStep(3)
            assertNoContainers()
            if isPad {
                XCTAssertLessThanOrEqual(doneButton.frame.width, 640, "the content is wider than 640 pt")
                XCTAssertEqual(doneButton.frame.midX, window.midX, accuracy: 2, "the content is not centred")
            }
            stepBackButton.tap()
            waitForStep(2)
            stepBackButton.tap()
            waitForStep(1)
            app.terminate()
        }
    }

    /// Criterion 4: tick and untick; a failed creation shows the category
    /// model's alert and the first run stays; a ticked row becomes "Added"
    /// after "Add a Source…" and cannot be unticked; Done creates what is
    /// still ticked, and only that.
    func testSuggestedCategories() {
        launchFirstRun(failNextSave: true)
        waitForStep(1)
        skipButton.tap()
        waitForStep(2)
        skipButton.tap()
        waitForStep(3)
        tick("world")
        tick("japan")
        XCTAssertTrue(isTicked("world"))
        XCTAssertTrue(isTicked("japan"))
        tick("japan")
        XCTAssertFalse(isTicked("japan"))

        // The debug save failure: the alert, and the first run stays.
        doneButton.tap()
        waitFor(app.alerts["The change could not be saved."])
        app.alerts.buttons["OK"].tap()
        waitForAbsence(app.alerts.firstMatch)
        waitForStep(3)
        XCTAssertTrue(isTicked("world"), "World was unticked by the failure")
        XCTAssertFalse(categoryRow("world").label.contains("Added"))

        // "Add a Source…" creates World, then opens Add source.
        addSourceButton.tap()
        waitFor(button(AccessibilityID.cancelButton)).tap()
        waitForAbsence(app.textFields[AccessibilityID.addressField])
        let world = categoryRow("world")
        waitLong(for: world, containing: "Added")
        XCTAssertTrue(world.isSelected)
        XCTAssertFalse(world.isEnabled)
        tick("ai")
        doneButton.tap()

        waitForShellOnToday()
        showCategoryList()
        waitForOrder(["World", "AI"])
    }

    /// Fix round 2: "Show in Library" from Add source's duplicate message
    /// during the first run closes the sheet and leaves step 3 as it was —
    /// no slide-over or tab opens behind it, so every dialog stays on a
    /// mounted host — and the first run then ends on the category list
    /// where it is: the Library tab, the slide-over below 1100 pt, the
    /// sidebar pane from 1100 pt; the source's category expanded.
    func testShowInLibraryDuringTheFirstRun() {
        launchFirstRun()
        waitForStep(1)
        skipButton.tap()
        waitForStep(2)
        skipButton.tap()
        waitForStep(3)
        addSourceButton.tap()
        detect(Fixture.feed)
        waitFor(element(AccessibilityID.confirmAddress))
        saveIntoNewCategory("News")
        waitForAbsence(app.textFields[AccessibilityID.addressField])

        addSourceButton.tap()
        detect("feed.example.invalid/rss.xml")
        waitFor(element(AccessibilityID.duplicateMessage))
        button(AccessibilityID.showInLibraryButton).tap()
        waitForAbsence(app.textFields[AccessibilityID.addressField])
        waitForStep(3)
        assertNoContainers()
        XCTAssertFalse(element(AccessibilityID.slideOverPanel).exists)

        doneButton.tap()
        waitForAbsence(firstRun)
        waitFor(sourceRow("Fixture Feed"))
        if app.tabBars.firstMatch.exists {
            XCTAssertTrue(app.tabBars.buttons["Library"].isSelected)
        } else if window.width >= 1100 {
            XCTAssertTrue(element(AccessibilityID.sidebarPane).exists)
        } else {
            XCTAssertTrue(element(AccessibilityID.slideOverPanel).exists)
        }
    }

    /// Criterion 5 with RD08: "Import OPML…" in step 3 runs RD08's import —
    /// its preview, the category for the feeds outside any folder, the
    /// summary — and the first run stays; Done then ends on Today with the
    /// imported sources (no "No sources yet"), and a relaunch shows the
    /// shell.
    func testImportOPMLFromTheFirstRun() {
        launchFirstRun(opmlFixture: "folders")
        waitForStep(1)
        skipButton.tap()
        waitForStep(2)
        skipButton.tap()
        waitForStep(3)
        revealAboveTheBar(button(AccessibilityID.firstRunImportOPML)).tap()
        waitFor(element(AccessibilityID.opmlFeedsToAdd))
        XCTAssertFalse(button(AccessibilityID.opmlImportButton).isEnabled, "Import before a category was chosen")
        waitFor(button(AccessibilityID.opmlCategoryRow)).tap()
        waitFor(button(AccessibilityID.opmlNewCategoryButton)).tap()
        let field = waitFor(app.textFields[AccessibilityID.opmlNewCategoryField])
        field.tap()
        field.typeText("Other")
        let useName = waitFor(button(AccessibilityID.opmlUseNameButton))
        // The form sheet moves as the keyboard goes (measured by RD08).
        waitUntilStill(useName)
        useName.tap()
        waitForAbsence(field)
        let importButton = waitFor(button(AccessibilityID.opmlImportButton))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: importButton)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: timeout), .completed, "Import stayed disabled")
        importButton.tap()
        waitFor(element(AccessibilityID.opmlFeedsAdded))
        waitFor(button(AccessibilityID.opmlDoneButton)).tap()
        waitForAbsence(element(AccessibilityID.opmlFeedsAdded))
        // The first run stays on step 3, with nothing of the shell.
        waitForStep(3)
        assertNoContainers()
        assertNothingNamesTheAdultPartition("step 3 after an import")

        doneButton.tap()
        waitForShellOnToday()
        if element(AccessibilityID.todayEmpty).waitForExistence(timeout: 2) {
            XCTAssertNotEqual(element(AccessibilityID.todayEmpty).label, "No sources yet")
        }
        showCategoryList()
        for category in ["News", "Tech", "Other"] {
            waitFor(element(AccessibilityID.categoryRow(category)))
        }
        launchFirstRun(opmlFixture: "folders")
        waitForShellOnToday()
    }

    // MARK: - RD20 criterion 16 with RD21

    /// Merge from a configuration import begun at `start`, whose file holds
    /// both partitions: no question is asked, the preview covers the normal
    /// partition only and says the adult one was not imported; the summary
    /// says it again, and Done closes it.
    private func importNormalPartitionOnly(from start: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        start.tap()
        waitFor(element(AccessibilityID.configurationCounts("normal")), file: file, line: line)
        XCTAssertFalse(app.alerts.firstMatch.exists, "a question about the adult partition was asked", file: file, line: line)
        XCTAssertFalse(element(AccessibilityID.configurationCounts("adult")).exists, "the preview covers the adult partition", file: file, line: line)
        let note = "The file's adult partition was not imported. You can import it from Settings › Data."
        XCTAssertEqual(element(AccessibilityID.configurationAdultSkipped).label, note, file: file, line: line)
        let merge = scrollTo(button(AccessibilityID.configurationMergeButton), file: file, line: line)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: merge)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: timeout), .completed, "Merge stayed disabled", file: file, line: line)
        merge.tap()
        let done = waitFor(button(AccessibilityID.configurationDoneButton), file: file, line: line)
        XCTAssertEqual(element(AccessibilityID.configurationAdultSkipped).label, note, "the summary's line", file: file, line: line)
        XCTAssertFalse(element(AccessibilityID.configurationSummaryRow("added", "adult")).exists, "the summary lists the adult partition", file: file, line: line)
        done.tap()
        waitForAbsence(done, file: file, line: line)
    }

    /// "Import Configuration…" in step 3 with a file holding both
    /// partitions: the normal partition only, no question, the one line;
    /// the first run stays on step 3, names no adult partition and makes no
    /// adult library; Done shows the imported category, and the partition
    /// is still off.
    func testImportConfigurationFromTheFirstRun() {
        launchFirstRun(configurationFixture: "both")
        waitForStep(1)
        skipButton.tap()
        waitForStep(2)
        skipButton.tap()
        waitForStep(3)
        importNormalPartitionOnly(from: revealAboveTheBar(button(AccessibilityID.firstRunImportConfiguration)))
        waitForStep(3)
        assertNoContainers()
        assertNothingNamesTheAdultPartition("step 3 after a configuration import")
        waitForAdultFileAbsent()

        doneButton.tap()
        waitForShellOnToday()
        XCTAssertFalse(element(AccessibilityID.partitionSwitch).exists, "the adult partition was turned on")
        showCategoryList()
        waitFor(element(AccessibilityID.categoryRow("Imported News")))
        XCTAssertFalse(element(AccessibilityID.categoryRow("Imported Private")).exists)
    }

    /// Today's empty state with no source has "Import Configuration" too
    /// (ux S1): in the normal partition the same import, the normal
    /// partition only; afterwards Today is no longer empty of sources.
    func testImportConfigurationFromTodaysEmptyState() {
        launchFirstRun(configurationFixture: "both")
        waitForStep(1)
        skipButton.tap()
        waitForStep(2)
        skipButton.tap()
        waitForStep(3)
        skipButton.tap()
        waitForShellOnToday()
        XCTAssertEqual(waitFor(element(AccessibilityID.todayEmpty)).label, "No sources yet")
        importNormalPartitionOnly(from: waitFor(button(AccessibilityID.todayImportConfigurationButton)))
        waitForAdultFileAbsent()
        waitForAbsence(button(AccessibilityID.todayImportConfigurationButton))
        showCategoryList()
        waitFor(element(AccessibilityID.categoryRow("Imported News")))
        XCTAssertFalse(element(AccessibilityID.categoryRow("Imported Private")).exists)
    }

    // MARK: - When it shows (criterion 8)

    /// Done with nothing ticked writes the flag: the next launch shows the
    /// shell although no category exists.
    func testRelaunchAfterCompleting() {
        launchFirstRun()
        waitForStep(1)
        continueButton.tap()
        waitForStep(2)
        continueButton.tap()
        waitForStep(3)
        doneButton.tap()
        waitForShellOnToday()
        launchFirstRun()
        waitForShellOnToday()
    }

    /// Skip on the last step writes the flag too.
    func testRelaunchAfterSkipping() {
        launchFirstRun()
        waitForStep(1)
        skipButton.tap()
        waitForStep(2)
        skipButton.tap()
        waitForStep(3)
        skipButton.tap()
        waitForShellOnToday()
        launchFirstRun()
        waitForShellOnToday()
        waitFor(element(AccessibilityID.todayEmpty))
    }

    /// Interrupted before any category existed: the first run again.
    func testRelaunchAfterAnInterruptionBeforeACategory() {
        launchFirstRun()
        waitForStep(1)
        continueButton.tap()
        waitForStep(2)
        launchFirstRun()
        waitFor(firstRun)
        waitForStep(1)
        assertNoContainers()
    }

    /// Interrupted after "Add a Source…" created a category: the next
    /// launch finds the category, writes the flag and shows the shell; with
    /// that category deleted, a later launch still shows the shell.
    func testRelaunchAfterAnInterruptionWithACategory() {
        launchFirstRun()
        waitForStep(1)
        skipButton.tap()
        waitForStep(2)
        skipButton.tap()
        waitForStep(3)
        tick("world")
        addSourceButton.tap()
        waitFor(app.textFields[AccessibilityID.addressField])
        launchFirstRun()
        waitForShellOnToday()
        showCategoryList()
        waitFor(element(AccessibilityID.categoryRow("World")))
        deleteInEditMode("World")
        deletionDialogButton("Delete Category").tap()
        waitFor(element(AccessibilityID.noCategories))
        setEditing(false)
        launchFirstRun()
        waitForShellOnToday()
    }
}
