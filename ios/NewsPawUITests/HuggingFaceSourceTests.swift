import XCTest

/// RD26 criteria 7, 9, 10 and 12: a Hugging Face account in Add source,
/// against the debug fixture transport only. The fixture accounts'
/// addresses are on the Hub's host because recognition is bound to it; the
/// transport answers them from its table and nothing reaches that host. The
/// models' links are built on the Hub's host, so no test opens one.
final class HuggingFaceSourceTests: NewsPawUITestCase {
    enum Fixture {
        /// Typed in another letter case than the Hub's `newspaw-fixture`.
        static let organization = "huggingface.co/NewsPaw-Fixture"
        static let empty = "hf.co/newspaw-empty"
        static let missing = "huggingface.co/newspaw-missing"
    }

    private var nameValue: String? {
        reveal(app.textFields[AccessibilityID.nameField]).value as? String
    }

    private var kindLabel: String {
        reveal(element(AccessibilityID.kindValue)).label
    }

    /// Criteria 9, 10 and 12: the page in the Hub's spelling, kind "Hugging
    /// Face", the Hub's name, a preview of the newest three models and no
    /// choice list; saved, the source lists its models, its row's menu
    /// offers Refresh, and one refresh brings the model the list adds.
    func testAddPreviewSaveAndRefresh() {
        launchAtFullWidth()
        createCategory("Models")
        openAddSource()
        detect(Fixture.organization)
        let address = waitFor(element(AccessibilityID.confirmAddress))
        XCTAssertEqual(address.label, "https://huggingface.co/newspaw-fixture")
        XCTAssertEqual(kindLabel, "Hugging Face")
        XCTAssertEqual(nameValue, "newspaw-fixture")
        XCTAssertFalse(button(AccessibilityID.pageItselfChoice).exists, "no \"This page itself\" for an account")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Found '")).firstMatch.exists)
        let first = waitFor(element(AccessibilityID.previewItem))
        XCTAssertTrue(first.label.hasPrefix("newspaw-fixture/Nightly-"), first.label)
        XCTAssertEqual(previewItemCount(), 3)
        revealAndSave("Models")
        expand("Models")
        let source = waitFor(sourceRow("newspaw-fixture"))
        waitForValue(source, "4 unread")

        source.press(forDuration: 1.2)
        waitFor(app.buttons.matching(NSPredicate(format: "label == %@", "Refresh")).firstMatch).tap()
        waitForValue(source, "5 unread")

        source.tap()
        waitFor(articleRow("newspaw-fixture/Lantern-7B"))
        waitFor(articleRow("newspaw-fixture/Harbour-Vision"))

        // Added again: already in Models.
        openAddSource()
        detect(Fixture.organization)
        let duplicate = waitFor(element(AccessibilityID.duplicateMessage))
        XCTAssertTrue(duplicate.label.contains("“Models”"), duplicate.label)
        button(AccessibilityID.cancelButton).tap()
    }

    /// Criterion 7: an account with no models says so and can be saved; a
    /// missing account says there is none, with no web-page route.
    func testEmptyAndMissingAccounts() {
        launchAtFullWidth()
        createCategory("Models")
        openAddSource()
        detect(Fixture.missing)
        let failure = waitFor(element(AccessibilityID.failureMessage))
        XCTAssertTrue(failure.label.contains("Could not read this address · the address is gone"), failure.label)
        XCTAssertTrue(failure.label.contains("There is no Hugging Face account with this name."), failure.label)
        XCTAssertFalse(button(AccessibilityID.saveAsWebPageButton).exists)

        detect(Fixture.empty)
        XCTAssertEqual(waitFor(element(AccessibilityID.confirmAddress)).label, "https://huggingface.co/newspaw-empty")
        XCTAssertEqual(kindLabel, "Hugging Face")
        XCTAssertEqual(nameValue, "newspaw-empty")
        XCTAssertTrue(reveal(app.staticTexts["This account has no public models yet"]).exists)
        XCTAssertFalse(element(AccessibilityID.previewItem).exists)
        revealAndSave("Models")
        expand("Models")
        let source = waitFor(sourceRow("newspaw-empty"))
        waitForValue(source, "0 unread")
    }

    // MARK: - Helpers

    /// Brings `target` on screen in the confirm step, whose rows below or
    /// above the fold are not in the hierarchy (the iPad's sheet is short):
    /// up with short slow drags, which never start at the top of the form
    /// and so never pull the sheet down, then down with the shared helper.
    @discardableResult
    private func reveal(_ target: XCUIElement, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let top = element(AccessibilityID.confirmAddress)
        var drags = 0
        while !(target.waitForExistence(timeout: 1) && target.isHittable), !(top.exists && top.isHittable), drags < 6 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 220)), withVelocity: .slow, thenHoldForDuration: 0.2)
            drags += 1
        }
        if target.exists, target.isHittable {
            return target
        }
        return scrollTo(target, file: file, line: line)
    }

    /// Chooses the category, below the fold on the iPad, and saves.
    private func revealAndSave(_ category: String) {
        reveal(button(AccessibilityID.categoryChoiceRow))
        chooseCategoryAndSave(category)
    }

    /// The preview's rows, after one swipe up: rows below the fold are not
    /// in the hierarchy.
    private func previewItemCount() -> Int {
        reveal(element(AccessibilityID.previewItem))
        app.swipeUp()
        return app.descendants(matching: .any).matching(identifier: AccessibilityID.previewItem).count
    }

    private func waitForValue(_ element: XCUIElement, _ value: String, file: StaticString = #filePath, line: UInt = #line) {
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: timeout), .completed,
                       "value: \(String(describing: element.value)), expected \(value)", file: file, line: line)
    }
}
