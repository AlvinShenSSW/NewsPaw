import XCTest

/// RD18 criterion 9: the cover in the app switcher, with a sheet open; and
/// no cover in the normal partition. The pictures are attached, and also
/// written to `TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR` when it is set. What the
/// simulator's switcher shows is what `XCUIScreen` sees; the system's real
/// snapshot on a device is a device check.
final class AdultCoverTests: AdultTestCase {
    private var cover: XCUIElement { element(AccessibilityID.cover) }

    private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let environment = ProcessInfo.processInfo.environment
        if let directory = environment["NEWSPAW_SCREENSHOT_DIR"] {
            let device = (environment["SIMULATOR_DEVICE_NAME"] ?? "device").replacingOccurrences(of: " ", with: "-")
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(device)-cover-\(name).png")
            try? screenshot.pngRepresentation.write(to: url)
        }
    }

    /// The app switcher, opened from wherever the device is.
    private func openSwitcher() {
        let bottom = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.999))
        let middle = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        bottom.press(forDuration: 0.05, thenDragTo: middle, withVelocity: .slow, thenHoldForDuration: 1.0)
        Thread.sleep(forTimeInterval: 1.5)
    }

    private func returnToTheApp() {
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: timeout))
    }

    /// The media page's title: `Played <element> <context> <state> <states
    /// seen>`, the seconds its sound element and its audio context have
    /// played.
    private func mediaTitle() -> String {
        barTexts().first { $0.hasPrefix("Played ") } ?? ""
    }

    private func played() -> (element: Double, context: Double) {
        let numbers = mediaTitle().split(separator: " ").dropFirst().prefix(2).compactMap { Double($0) }
        return numbers.count == 2 ? (numbers[0], numbers[1]) : (-1, -1)
    }

    private func waitForElementPlaying(beyond seconds: Double, _ note: String, file: StaticString = #filePath, line: UInt = #line) {
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            self.played().element > seconds
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: timeout), .completed,
                       "the page's sound element does not play \(note): \(barTexts())", file: file, line: line)
    }

    /// RD18 decision 13, refined in round 2: while the adult workspace is
    /// shown and the scene is not active — here Control Centre over the
    /// app under "After 1 Minute", so that the workspace stays — a page
    /// that calls `play()` on its paused sound element every 200 ms plays
    /// nothing; back in the app it may play again, also after Home and
    /// back within the minute. The page's audio
    /// context, which it resumes as often, is only recorded: WebKit lets
    /// a page's `resume()` end the suspension (measured).
    func testAnAdultPageCannotPlayAgainWhileTheAppIsNotActive() {
        launchAtFullWidth(authentication: ["passed", "passed"])
        turnOnAdult()
        chooseTiming("After 1 Minute")
        enterAdult()
        createCategory("Velvet")
        addSource(Fixture.articles, to: "Velvet")
        openCategoryList("Velvet")
        openArticle("Plain story")
        waitFor(button(AccessibilityID.openOriginalButton)).tap()
        waitForPage("Original of plain-story")
        tapLink("Media page")
        waitForPage("Media Page")
        waitFor(app.webViews.buttons["Play"]).tap()
        waitForElementPlaying(beyond: 0.5, "after Play")

        let before = played()
        let asked = Date()
        showControlCentre()
        XCTAssertTrue(cover.waitForExistence(timeout: 3), "no cover while the adult partition is inactive")
        // The title can be read beneath the cover.
        for second in 1...8 {
            Thread.sleep(forTimeInterval: 1)
            print("RD18 media beneath the cover, \(second) s: \(mediaTitle())")
        }
        hideControlCentre()
        let after = played()
        let elapsed = Date().timeIntervalSince(asked)
        let line = "before \(before), after \(after), \(String(format: "%.1f", elapsed)) s between the readings"
        print("RD18 media: \(line)")
        record("RD18 media", line)

        // About eight of the seconds between the two readings were spent
        // away; an element that played again meanwhile played nearly all
        // of them.
        XCTAssertGreaterThanOrEqual(after.element, 0, "no reading after the return: \(barTexts())")
        XCTAssertLessThan(after.element - before.element, elapsed - 4, "the sound element played while the app was not active")
        // Still the adult partition (its library open, nothing locked), and
        // its page may play again.
        XCTAssertTrue(report.contains("pool=open"), "the partition locked: \(report)")
        waitForElementPlaying(beyond: after.element + 1, "after the return")

        // Home and back within the minute: will-deactivate and then
        // did-enter-background suspend once, and one return allows again.
        let beforeHome = played()
        leaveAndReturn()
        XCTAssertTrue(report.contains("pool=open"), "the partition locked: \(report)")
        waitForElementPlaying(beyond: beforeHome.element + 1, "after Home and back")
    }

    func testTheCoverHidesTheAdultPartitionInTheAppSwitcher() {
        launchAtFullWidth(authentication: ["passed", "passed"])
        turnOnAdult()
        // So that an absence in this test does not lock.
        chooseTiming("After 5 Minutes")

        // The normal partition, a sheet open: no cover, there or back.
        openNewCategory()
        let field = app.textFields[AccessibilityID.nameField]
        field.tap()
        field.typeText("Shown in the switcher\n")
        openSwitcher()
        XCTAssertFalse(cover.exists, "the cover is shown in the normal partition")
        capture("1-normal-sheet-switcher")
        returnToTheApp()
        XCTAssertFalse(cover.exists)
        XCTAssertEqual(field.value as? String, "Shown in the switcher")
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(field)

        // The adult partition: a category's list, whose title is its name,
        // and its settings sheet above it, with the name in its field.
        enterAdult()
        createCategory("Velvet")
        openCategoryList("Velvet")
        openListSettings(source: false)
        waitFor(field)
        XCTAssertEqual(field.value as? String, "Velvet")
        capture("2-adult-sheet-before")
        // The switcher from the app: the scene is inactive, not in the
        // background, and the cover is up.
        openSwitcher()
        XCTAssertTrue(cover.waitForExistence(timeout: 3), "no cover while the adult partition is inactive")
        capture("3-adult-sheet-switcher-live")
        returnToTheApp()
        waitForAbsence(cover)
        XCTAssertEqual(field.value as? String, "Velvet", "the sheet did not survive the cover")
        // Home, then the switcher: the picture the system stored.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        openSwitcher()
        capture("4-adult-sheet-switcher-after-home")
        returnToTheApp()
        waitForAbsence(cover)
        XCTAssertEqual(field.value as? String, "Velvet")
        capture("5-adult-sheet-after")
        button(AccessibilityID.cancelButton).tap()
        waitForAbsence(field)
        XCTAssertEqual(partitionLabel(), Wording.adult)
    }
}
