import XCTest

/// RD13 (ux S8, S9): Models & Translation and the model form, on the model
/// fixture. Criteria 1, 2, 4, 6, 9, 11, 12 and 13 (the interface side).
final class ModelSettingsTests: ModelSettingsTestCase {
    static let key = "sk-uitest-passed-key-1a2b"

    /// Criteria 1, 2, 9, 11 and 13: create a primary with Load List, Test
    /// and Save; after a relaunch the key is dots and its last four
    /// characters and in no field; editing the model shows "Not tested";
    /// another preset shows "Key needed".
    func testCreatePrimaryAndRelaunch() throws {
        launchAtFullWidth()
        openModelSettings()
        XCTAssertTrue(rowLabel().contains("Not set up"), rowLabel())
        XCTAssertFalse(element(AccessibilityID.backupModelRow).isEnabled)
        waitFor(element(AccessibilityID.backupNeedsPrimary))

        openForm()
        // A new model starts on the OpenAI preset's address.
        XCTAssertEqual(app.textFields[AccessibilityID.modelAddressField].value as? String, "https://api.openai.com/v1")
        XCTAssertFalse(reveal(button(AccessibilityID.testButton)).isEnabled)
        fill(address: Fixture.passed, model: nil, key: Self.key)

        // Load List fills the model field from the service's answer.
        let loadList = reveal(button(AccessibilityID.loadListButton))
        waitUntilEnabled(loadList)
        loadList.tap()
        for model in Fixture.models {
            waitFor(button(AccessibilityID.modelListRow(model)))
        }
        button(AccessibilityID.modelListRow("fixture-model-b")).tap()
        waitForAbsence(button(AccessibilityID.modelListRow("fixture-model-a")))
        XCTAssertEqual(reveal(app.textFields[AccessibilityID.modelNameField]).value as? String, "fixture-model-b")

        runTest(expecting: "Passed")
        XCTAssertFalse(element(AccessibilityID.testSentence).exists)
        saveForm()
        XCTAssertTrue(rowLabel().contains("fixture-model-b"), rowLabel())
        XCTAssertTrue(rowLabel().contains("Passed"), rowLabel())
        XCTAssertTrue(element(AccessibilityID.backupModelRow).isEnabled)

        // After a relaunch: the slot, its result and its key are kept.
        relaunch()
        openModelSettings()
        XCTAssertTrue(rowLabel().contains("Passed"), rowLabel())
        openForm()
        let stored = reveal(element(AccessibilityID.storedKey))
        XCTAssertEqual(stored.label, "Key ending in 1a2b")
        XCTAssertFalse(app.secureTextFields[AccessibilityID.keyField].exists)
        XCTAssertFalse(app.debugDescription.contains(Self.key), "the key is in the accessibility tree")
        XCTAssertFalse(app.debugDescription.contains("passed-key"), "part of the key is in the accessibility tree")
        XCTAssertEqual(testLineText(), "Passed")

        // Criterion 11: an edited model is "Not tested".
        replaceText(of: AccessibilityID.modelNameField, with: "fixture-model-c")
        XCTAssertEqual(testLineText(), "Not tested")
        replaceText(of: AccessibilityID.modelNameField, with: "fixture-model-b")
        XCTAssertEqual(testLineText(), "Passed")

        // Criterion 13: another service's preset sets the stored key aside.
        choosePreset("DeepSeek")
        XCTAssertEqual(reveal(app.textFields[AccessibilityID.modelAddressField]).value as? String, "https://api.deepseek.com")
        reveal(element(AccessibilityID.keyNeeded))
        XCTAssertFalse(element(AccessibilityID.storedKey).exists)
        XCTAssertFalse(reveal(button(AccessibilityID.testButton)).isEnabled)
        XCTAssertFalse(reveal(button(AccessibilityID.loadListButton)).isEnabled)
        XCTAssertEqual(testLineText(), "Not tested")

        // Leaving with these changes asks first; discarding keeps the slot.
        button(AccessibilityID.cancelButton).tap()
        waitFor(dialogButton("Discard Changes")).tap()
        waitFor(element(AccessibilityID.primaryModelRow))
        XCTAssertTrue(rowLabel().contains("Passed"), rowLabel())
    }

    /// Criterion 13 on save: after the host changes, Save drops the stored
    /// key and the model needs a key.
    func testSaveAfterHostChangeDropsKey() throws {
        launchAtFullWidth()
        openModelSettings()
        createModel(key: Self.key)
        openForm()
        replaceText(of: AccessibilityID.modelAddressField, with: Fixture.limited)
        reveal(element(AccessibilityID.keyNeeded))
        // A key typed for the other host stays the form's key when the
        // address returns to the saved host: the stored key is not shown
        // over it, and Cancel goes back to the stored key.
        typeKey("sk-uitest-other-host-key-5t4r")
        replaceText(of: AccessibilityID.modelAddressField, with: Fixture.passed)
        XCTAssertTrue(reveal(app.secureTextFields[AccessibilityID.keyField]).exists)
        XCTAssertFalse(element(AccessibilityID.storedKey).exists, "the stored key is shown while a typed key would be saved")
        reveal(button(AccessibilityID.cancelReplaceKeyButton)).tap()
        XCTAssertEqual(reveal(element(AccessibilityID.storedKey)).label, "Key ending in 1a2b")
        replaceText(of: AccessibilityID.modelAddressField, with: Fixture.limited)
        reveal(element(AccessibilityID.keyNeeded))
        saveForm()
        XCTAssertTrue(rowLabel().contains("Key needed"), rowLabel())
        openForm()
        reveal(element(AccessibilityID.keyNeeded))
        XCTAssertFalse(element(AccessibilityID.storedKey).exists)
        XCTAssertTrue(reveal(app.secureTextFields[AccessibilityID.keyField]).exists)
    }

    /// Criteria 4 and 6: each failure line with its sentence, in English;
    /// a redirect reads as "Could not connect"; Load List shows its line.
    func testFailureLines() throws {
        launchAtFullWidth()
        openModelSettings()
        openForm()
        fill(address: Fixture.rejected, model: "fixture-model-a", key: Self.key)
        let cases: [(String, String, String)] = [
            (Fixture.rejected, "Key rejected", "The service rejected the key"),
            (Fixture.noModel, "Model not found", "The service does not have this model"),
            (Fixture.limited, "Quota or rate limit", "The service is limiting requests. Try again later"),
            (Fixture.down, "Could not connect", "Could not reach the service"),
            (Fixture.redirect, "Could not connect", "Could not reach the service"),
        ]
        for (address, line, sentence) in cases {
            replaceText(of: AccessibilityID.modelAddressField, with: address)
            // The typed key stays with the form: the origin rule concerns
            // the stored key only.
            runTest(expecting: line)
            XCTAssertEqual(waitFor(element(AccessibilityID.testSentence)).label, sentence, address)
        }
        // Load List shows the same line for its failure.
        replaceText(of: AccessibilityID.modelAddressField, with: Fixture.rejected)
        let loadList = reveal(button(AccessibilityID.loadListButton))
        waitUntilEnabled(loadList)
        loadList.tap()
        XCTAssertEqual(waitFor(element(AccessibilityID.loadListLine)).label, "Key rejected")
        // Nothing was saved.
        button(AccessibilityID.cancelButton).tap()
        waitFor(dialogButton("Discard Changes")).tap()
        XCTAssertTrue(rowLabel().contains("Not set up"), rowLabel())
    }

    /// Criterion 1 and decision 14: the backup needs a primary, and the
    /// primary is removed only after the backup.
    func testBackupRules() throws {
        launchAtFullWidth()
        openModelSettings()
        XCTAssertFalse(element(AccessibilityID.backupModelRow).isEnabled)
        createModel(key: Self.key)

        openForm(backup: true)
        reveal(element(AccessibilityID.backupIntro))
        fill(address: Fixture.passed, model: "fixture-model-c", key: "sk-uitest-backup-key-9z8y")
        runTest(expecting: "Passed")
        saveForm()
        XCTAssertTrue(rowLabel(backup: true).contains("fixture-model-c"), rowLabel(backup: true))
        XCTAssertTrue(rowLabel(backup: true).contains("Passed"), rowLabel(backup: true))

        // The primary cannot be removed while the backup exists.
        openForm()
        let remove = reveal(button(AccessibilityID.removeModelButton))
        XCTAssertFalse(remove.isEnabled)
        reveal(element(AccessibilityID.removeBackupFirst))
        button(AccessibilityID.cancelButton).tap()
        waitFor(element(AccessibilityID.primaryModelRow))

        // Remove the backup, then the primary.
        openForm(backup: true)
        reveal(button(AccessibilityID.removeModelButton)).tap()
        waitFor(dialogButton("Remove Model")).tap()
        waitFor(element(AccessibilityID.primaryModelRow))
        XCTAssertTrue(rowLabel(backup: true).contains("Not set up"), rowLabel(backup: true))
        openForm()
        let removePrimary = reveal(button(AccessibilityID.removeModelButton))
        XCTAssertTrue(removePrimary.isEnabled)
        XCTAssertFalse(element(AccessibilityID.removeBackupFirst).exists)
        removePrimary.tap()
        waitFor(dialogButton("Remove Model")).tap()
        waitFor(element(AccessibilityID.primaryModelRow))
        XCTAssertTrue(rowLabel().contains("Not set up"), rowLabel())
        XCTAssertFalse(element(AccessibilityID.backupModelRow).isEnabled)
    }

    /// Criterion 12 and decision 14: Replace, its Cancel, a replaced key,
    /// and Remove leaving the model at "Key needed".
    func testReplaceAndRemoveKey() throws {
        launchAtFullWidth()
        openModelSettings()
        createModel(key: Self.key)
        openForm()
        reveal(button(AccessibilityID.replaceKeyButton)).tap()
        let field = waitFor(app.secureTextFields[AccessibilityID.keyField])
        XCTAssertFalse(element(AccessibilityID.storedKey).exists)
        XCTAssertFalse(button(AccessibilityID.saveButton).isEnabled, "Save while the new key is empty")
        XCTAssertEqual(field.value as? String ?? "", field.placeholderValue ?? "", "the stored key is in the field")
        reveal(button(AccessibilityID.cancelReplaceKeyButton)).tap()
        XCTAssertEqual(reveal(element(AccessibilityID.storedKey)).label, "Key ending in 1a2b")

        // Replace with a new key and save.
        reveal(button(AccessibilityID.replaceKeyButton)).tap()
        typeKey("sk-uitest-replacing-key-7q6w")
        saveForm()
        XCTAssertTrue(rowLabel().contains("Not tested"), rowLabel())
        openForm()
        XCTAssertEqual(reveal(element(AccessibilityID.storedKey)).label, "Key ending in 7q6w")

        // Remove asks first; Cancel keeps the key.
        reveal(button(AccessibilityID.removeKeyButton)).tap()
        waitFor(app.alerts.buttons["Cancel"]).tap()
        XCTAssertEqual(reveal(element(AccessibilityID.storedKey)).label, "Key ending in 7q6w")
        // Remove the key: the model stays, at "Key needed".
        reveal(button(AccessibilityID.removeKeyButton)).tap()
        waitFor(dialogButton("Remove Key")).tap()
        reveal(element(AccessibilityID.keyNeeded))
        XCTAssertTrue(app.secureTextFields[AccessibilityID.keyField].exists)
        XCTAssertFalse(reveal(button(AccessibilityID.testButton)).isEnabled)
        // Nothing else changed: leaving asks nothing.
        button(AccessibilityID.cancelButton).tap()
        waitFor(element(AccessibilityID.primaryModelRow))
        XCTAssertTrue(rowLabel().contains("Key needed"), rowLabel())
        XCTAssertTrue(rowLabel().contains("fixture-model-a"), rowLabel())
    }

    /// Decision 14: leaving with unsaved changes asks before discarding;
    /// closing the question keeps them.
    func testUnsavedChangesQuestion() throws {
        launchAtFullWidth()
        openModelSettings()
        let hasTabBar = app.tabBars.firstMatch.exists
        openForm()
        // Unchanged: Cancel leaves at once.
        button(AccessibilityID.cancelButton).tap()
        waitFor(element(AccessibilityID.primaryModelRow))
        if hasTabBar {
            waitFor(app.tabBars.firstMatch)
        }
        openForm()
        // In the tab structure the tab bar is not there while the form is
        // open: a second tap on Settings would pop the form without the
        // question.
        let tabBar = app.tabBars.firstMatch
        XCTAssertFalse(tabBar.exists && tabBar.isHittable, "the tab bar is over the form")
        replaceText(of: AccessibilityID.modelNameField, with: "typed-model")
        // The form has no back button, and a swipe from the leading edge
        // does not leave it either: only Cancel and Save do.
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: window.minX + 1, dy: window.midY))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: window.minX + 320, dy: window.midY)))
        XCTAssertFalse(element(AccessibilityID.primaryModelRow).waitForExistence(timeout: 2), "a swipe left the form")
        XCTAssertTrue(button(AccessibilityID.saveButton).exists)
        button(AccessibilityID.cancelButton).tap()
        waitFor(dialogButton("Discard Changes"))
        // Closing the question without choosing keeps the form and what
        // was typed.
        dismissDialog()
        waitForAbsence(dialogButton("Discard Changes"))
        XCTAssertTrue(button(AccessibilityID.saveButton).exists)
        XCTAssertEqual(reveal(app.textFields[AccessibilityID.modelNameField]).value as? String, "typed-model")
        button(AccessibilityID.cancelButton).tap()
        waitFor(dialogButton("Discard Changes")).tap()
        waitFor(element(AccessibilityID.primaryModelRow))
        XCTAssertTrue(rowLabel().contains("Not set up"), rowLabel())
    }
}
