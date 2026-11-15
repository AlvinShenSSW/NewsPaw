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
