import XCTest

/// Helpers for the model screens (RD13): Settings → Models & Translation
/// and the model form, on the model fixture, whose hosts end in
/// `models.example.invalid`.
@MainActor
class ModelSettingsTestCase: NewsPawUITestCase {
    /// The fixture's addresses (`FixtureModelHTTP.Address`).
    enum Fixture {
        static let passed = "https://passed.models.example.invalid/v1"
        static let rejected = "https://rejected.models.example.invalid/v1"
        static let noModel = "https://nomodel.models.example.invalid/v1"
        static let limited = "https://limited.models.example.invalid/v1"
        static let down = "https://down.models.example.invalid/v1"
        static let redirect = "https://redirect.models.example.invalid/v1"
        /// The models `passed` lists.
        static let models = ["fixture-model-a", "fixture-model-b", "fixture-model-c"]
    }

    /// Keeps a screenshot with every failure, to see what the screen
    /// showed.
    nonisolated override func record(_ issue: XCTIssue) {
        var issue = issue
        let screenshot = MainActor.assumeIsolated { XCUIScreen.main.screenshot().pngRepresentation }
        let attachment = XCTAttachment(data: screenshot, uniformTypeIdentifier: "public.png")
        attachment.lifetime = .keepAlways
        issue.add(attachment)
        super.record(issue)
    }

    /// Shows Settings → Models & Translation.
    func openModelSettings() {
        if app.tabBars.firstMatch.exists {
            app.tabBars.buttons.element(boundBy: 3).tap()
            // A screen pushed on the Settings tab: a second tap returns to
            // its root.
            if !element(AccessibilityID.modelsRow).waitForExistence(timeout: 3) {
                app.tabBars.buttons.element(boundBy: 3).tap()
            }
        } else {
            openSidebarIfNeeded()
            scrollTo(element(AccessibilityID.settingsRow)).tap()
            waitForAbsence(element(AccessibilityID.slideOverPanel))
            if !element(AccessibilityID.modelsRow).waitForExistence(timeout: 3) {
                // The sidebar's Settings row selects Settings; a second
                // selection does not pop, so pop by Cancel or Back.
                while !element(AccessibilityID.modelsRow).exists, button(AccessibilityID.cancelButton).exists || app.buttons["BackButton"].exists {
                    if button(AccessibilityID.cancelButton).exists {
                        button(AccessibilityID.cancelButton).tap()
                    } else {
                        goBack()
                    }
                }
            }
        }
        waitFor(element(AccessibilityID.modelsRow)).tap()
        waitFor(element(AccessibilityID.primaryModelRow))
    }

    /// Scrolls the form, up and then down, until `element` is on screen;
    /// rows off screen are not in the hierarchy. Eight swipes cross the
    /// form at the largest text size, where it is six screens long.
    @discardableResult
    func reveal(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        var swipes = 0
        while !(element.waitForExistence(timeout: 1) && element.isHittable), swipes < 16 {
            if swipes < 8 {
                app.swipeUp()
            } else {
                app.swipeDown()
            }
            swipes += 1
        }
        return waitFor(element, file: file, line: line)
    }

    /// Opens the form of the primary or the backup model.
    func openForm(backup: Bool = false) {
        waitFor(element(backup ? AccessibilityID.backupModelRow : AccessibilityID.primaryModelRow)).tap()
        waitFor(button(AccessibilityID.saveButton))
    }

    /// A preset's row in the inline service picker, by its name.
    func preset(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
    }

    func choosePreset(_ name: String) {
        reveal(preset(name)).tap()
    }

    /// Replaces a text field's whole text with `text`, ending with Return,
    /// which closes the keyboard.
    func replaceText(of identifier: String, with text: String, secure: Bool = false) {
        let field = secure ? app.secureTextFields[identifier] : app.textFields[identifier]
        reveal(field)
        // At the trailing end, so that the cursor follows the text and the
        // deletes below remove all of it.
        // A tap while the form still scrolls only stops it: tap again until
        // the field has the keyboard.
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        var taps = 0
        repeat {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
            taps += 1
        } while XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: focused, object: field)], timeout: 3) != .completed && taps < 3
        // The field being typed in stays above the keyboard, in a pane
        // too, where screens otherwise ignore the keyboard.
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            XCTAssertLessThan(field.frame.midY, keyboard.frame.minY, "\(identifier) is under the keyboard")
        }
        let current = field.value as? String ?? ""
        let placeholder = field.placeholderValue ?? ""
        let existing = current == placeholder || secure ? 0 : current.count
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing) + text + "\n")
    }

    func typeKey(_ key: String) {
        replaceText(of: AccessibilityID.keyField, with: key, secure: true)
    }

    /// The text of the line under Test, once it is not "Testing…".
    func testLineText() -> String {
        let line = reveal(element(AccessibilityID.testLine))
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != 'Testing…'"), object: line)
        _ = XCTWaiter.wait(for: [settled], timeout: timeout)
        return line.label
    }

    /// Taps Test once it is enabled and waits for its line.
    @discardableResult
    func runTest(expecting expected: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let test = reveal(button(AccessibilityID.testButton), file: file, line: line)
        waitUntilEnabled(test, file: file, line: line)
        test.tap()
        // The line is the row under the button: below the fold when the
        // button is the last row on screen (the backup's form on iPad).
        let label = reveal(element(AccessibilityID.testLine), file: file, line: line)
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: label)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: timeout), .completed,
                       "Test line: \(label.exists ? label.label : "none")", file: file, line: line)
        return label
    }

    func waitUntilEnabled(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: timeout), .completed, "\(element) stayed disabled", file: file, line: line)
    }

    /// Sets up the open form with `address`, `model` and `key` (any of them
    /// `nil` to leave as it is).
    func fill(preset: String? = "Custom", address: String?, model: String?, key: String?) {
        if let preset {
            choosePreset(preset)
        }
        if let address {
            replaceText(of: AccessibilityID.modelAddressField, with: address)
        }
        if let model {
            replaceText(of: AccessibilityID.modelNameField, with: model)
        }
        if let key {
            typeKey(key)
        }
    }

    /// Saves the open form and waits for Models & Translation.
    func saveForm(file: StaticString = #filePath, line: UInt = #line) {
        tapSave(file: file, line: line)
        waitForAbsence(button(AccessibilityID.saveButton))
        waitFor(element(AccessibilityID.primaryModelRow), file: file, line: line)
    }

    /// Creates a model on the `passed` fixture and returns to Models &
    /// Translation.
    func createModel(backup: Bool = false, model: String = "fixture-model-a", key: String) {
        openForm(backup: backup)
        fill(address: Fixture.passed, model: model, key: key)
        saveForm()
    }

    /// The label of a model row on Models & Translation.
    func rowLabel(backup: Bool = false) -> String {
        waitFor(element(backup ? AccessibilityID.backupModelRow : AccessibilityID.primaryModelRow)).label
    }

    /// Closes a confirmation dialog without choosing. On iOS 26 and later
    /// the dialog is a popover on its button, on iPhone as on iPad: its
    /// cancel button is not drawn, and a tap outside it is "cancel". The
    /// tap is in the lower half of the window, away from a popover on a
    /// button of the top bar, and it is not passed on to what is under it.
    func dismissDialog(file: StaticString = #filePath, line: UInt = #line) {
        let region = element("PopoverDismissRegion")
        XCTAssertTrue(region.waitForExistence(timeout: timeout), "the dialog is not a popover", file: file, line: line)
        region.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        waitForAbsence(region, file: file, line: line)
    }

    /// A button of a confirmation dialog by its label, not one of the
    /// form's own buttons.
    func dialogButton(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ AND NOT (identifier BEGINSWITH 'slot.') AND NOT (identifier BEGINSWITH 'editor.')", label)).firstMatch
    }
}
