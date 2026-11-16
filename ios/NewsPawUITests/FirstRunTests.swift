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
        for group in ["world", "japan", "australia", "china", "tech", "ai"] {
            XCTAssertFalse(isTicked(group), "\(group) starts ticked")
        }
        XCTAssertEqual(categoryRow("world").label, "World")
        XCTAssertEqual(categoryRow("tech").label, "Tech")
        assertNothingNamesTheAdultPartition("step 3")
        categoryRow("world").tap()
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
        categoryRow("japan").tap()
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
        categoryRow("world").tap()
        categoryRow("japan").tap()
        XCTAssertTrue(isTicked("world"))
        XCTAssertTrue(isTicked("japan"))
        categoryRow("japan").tap()
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
        categoryRow("ai").tap()
        doneButton.tap()

        waitForShellOnToday()
        showCategoryList()
        waitForOrder(["World", "AI"])
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
        categoryRow("world").tap()
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
