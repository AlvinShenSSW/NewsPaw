import XCTest

/// RD07 criteria 3, 7–10 and 12: a GitHub repository in Add source, against
/// the debug fixture transport only. The fixture repositories' addresses are
/// on GitHub's host because recognition is bound to it; the transport
/// answers them from its table and nothing reaches that host.
final class GitHubSourceTests: NewsPawUITestCase {
    enum Fixture {
        static let project = "https://github.com/NewsPaw-Fixture/Project"
        static let untagged = "https://github.com/NewsPaw-Fixture/Untagged"
        static let slow = "https://github.com/NewsPaw-Fixture/Slow"

        /// A feed address as detection builds it: lower case.
        static func feed(_ repository: String, _ feed: String) -> String {
            "https://github.com/newspaw-fixture/\(repository)/\(feed).atom"
        }
    }

    private func row(_ repository: String, _ feed: String) -> XCUIElement {
        button(AccessibilityID.candidateChoice(Fixture.feed(repository, feed)))
    }

    private var nameValue: String? {
        reveal(app.textFields[AccessibilityID.nameField]).value as? String
    }

    private var kindLabel: String {
        reveal(element(AccessibilityID.kindValue)).label
    }

    /// Criteria 9 and 12: the address as typed without www., .git or a
    /// deeper path; the three rows and the page row; the kind and the
    /// suggested name follow the choice; the page itself is saved as a web
    /// page named owner/repo.
    func testConfirmStepRowsNamesAndThePage() {
        launchAtFullWidth()
        createCategory("News")
        openAddSource()
        detect("www.github.com/NewsPaw-Fixture/Project.git")
        let address = waitFor(element(AccessibilityID.confirmAddress))
        XCTAssertEqual(address.label, Fixture.project)
        let releases = waitFor(row("project", "releases"))
        let tags = row("project", "tags")
        let commits = row("project", "commits")
        XCTAssertTrue(releases.label.hasPrefix("Releases"), releases.label)
        XCTAssertTrue(releases.label.contains("Latest item"), releases.label)
        XCTAssertTrue(tags.label.hasPrefix("Tags"), tags.label)
        XCTAssertTrue(commits.label.hasPrefix("Commits"), commits.label)
        XCTAssertTrue(releases.isSelected, "Releases is chosen when usable")
        XCTAssertFalse(tags.isSelected)
        let page = button(AccessibilityID.pageItselfChoice)
        XCTAssertTrue(page.label.contains("This page itself"), page.label)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Found '")).firstMatch.exists)
        XCTAssertEqual(nameValue, "NewsPaw-Fixture/Project")
        XCTAssertEqual(kindLabel, "GitHub · Releases")
        waitFor(element(AccessibilityID.previewItem))
        screenshot("github-confirm")

        reveal(tags).tap()
        XCTAssertTrue(tags.isSelected)
        XCTAssertEqual(nameValue, "NewsPaw-Fixture/Project · Tags")
        XCTAssertEqual(kindLabel, "GitHub · Tags")
        reveal(commits).tap()
        XCTAssertEqual(nameValue, "NewsPaw-Fixture/Project · Commits")
        XCTAssertEqual(kindLabel, "GitHub · Commits")
        reveal(page).tap()
        XCTAssertTrue(page.isSelected)
        XCTAssertEqual(nameValue, "NewsPaw-Fixture/Project")
        XCTAssertEqual(kindLabel, "Web page")
        XCTAssertFalse(element(AccessibilityID.previewItem).exists)
        reveal(releases).tap()
        XCTAssertEqual(nameValue, "NewsPaw-Fixture/Project")
        XCTAssertEqual(previewItemCount(), 3)

        // A deeper path shows the same repository address.
        goBack()
        detect("https://github.com/NewsPaw-Fixture/Project/tree/main/docs")
        waitFor(row("project", "releases"))
        XCTAssertEqual(element(AccessibilityID.confirmAddress).label, Fixture.project)
        reveal(button(AccessibilityID.pageItselfChoice)).tap()
        XCTAssertEqual(kindLabel, "Web page")
        revealAndSave("News")
        expand("News")
        XCTAssertEqual(waitFor(sourceRow("NewsPaw-Fixture/Project")).value as? String, "Web page")
    }

    /// Criterion 3: a repository with no tag: Releases is chosen and says it
    /// has no items; Commits shows its items and is saved as a source that
    /// lists them.
    func testRepositoryWithNoTag() {
        launchAtFullWidth()
        createCategory("News")
        openAddSource()
        detect(Fixture.untagged)
        let releases = waitFor(row("untagged", "releases"))
        XCTAssertTrue(releases.isSelected)
        XCTAssertTrue(releases.label.contains("No items yet"), releases.label)
        XCTAssertTrue(row("untagged", "tags").label.contains("No items yet"))
        XCTAssertTrue(row("untagged", "commits").label.contains("Latest item"))
        XCTAssertTrue(reveal(app.staticTexts["This feed has no items yet"]).exists)
        XCTAssertFalse(element(AccessibilityID.previewItem).exists)

        reveal(row("untagged", "commits")).tap()
        XCTAssertEqual(nameValue, "NewsPaw-Fixture/Untagged · Commits")
        XCTAssertEqual(kindLabel, "GitHub · Commits")
        XCTAssertEqual(previewItemCount(), 3)
        revealAndSave("News")
        expand("News")
        let source = waitFor(sourceRow("NewsPaw-Fixture/Untagged · Commits"))
        XCTAssertEqual(source.value as? String, "3 unread")
        source.tap()
        waitFor(articleRow("Polish the reading lamp"))
        waitFor(articleRow("Trim the wick"))
    }

    /// Criteria 7 and 10: Releases saved, refreshed from the row's menu
    /// (one new release); added again, its row says where it is, nothing is
    /// chosen and Save is disabled until Commits is chosen.
    func testReleasesAlreadyAddedAndRefresh() {
        launchAtFullWidth()
        createCategory("News")
        openAddSource()
        detect(Fixture.project)
        XCTAssertTrue(waitFor(row("project", "releases")).isSelected)
        revealAndSave("News")
        expand("News")
        let source = waitFor(sourceRow("NewsPaw-Fixture/Project"))
        waitForValue(source, "4 unread")

        // The row's menu offers Refresh, and one refresh brings the release
        // the feed adds at every answer.
        source.press(forDuration: 1.2)
        waitFor(app.buttons.matching(NSPredicate(format: "label == %@", "Refresh")).firstMatch).tap()
        waitForValue(source, "5 unread")

        openAddSource()
        detect(Fixture.project)
        let releases = waitFor(row("project", "releases"))
        XCTAssertTrue(releases.label.contains("Already in “News”"), releases.label)
        XCTAssertFalse(releases.isEnabled)
        for feed in ["releases", "tags", "commits"] {
            XCTAssertFalse(row("project", feed).isSelected, "\(feed) is not chosen")
        }
        XCTAssertFalse(button(AccessibilityID.pageItselfChoice).isSelected)
        let save = waitFor(button(AccessibilityID.saveButton))
        XCTAssertFalse(save.isEnabled, "nothing is chosen, so Save is disabled")
        screenshot("github-releases-added")
        reveal(row("project", "commits")).tap()
        XCTAssertTrue(row("project", "commits").isSelected)
        XCTAssertEqual(nameValue, "NewsPaw-Fixture/Project · Commits")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: timeout), .completed, "choosing Commits enables Save")
        goBack()
        button(AccessibilityID.cancelButton).tap()
    }

    /// Criterion 8: a feed not checked in time; choosing it detects the
    /// repository again with the address field unchanged, and the row is
    /// usable afterwards.
    func testUncheckedRowDetectsTheRepositoryAgain() {
        launchAtFullWidth()
        createCategory("News")
        openAddSource()
        detect(Fixture.slow)
        let tags = waitFor(row("slow", "tags"))
        XCTAssertTrue(tags.label.contains("Could not check in time"), tags.label)
        XCTAssertTrue(row("slow", "releases").isSelected)
        reveal(tags).tap()
        let usable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Latest item'"), object: row("slow", "tags"))
        XCTAssertEqual(XCTWaiter.wait(for: [usable], timeout: 15), .completed, "Tags is usable after the second detection")
        XCTAssertEqual(element(AccessibilityID.confirmAddress).label, Fixture.slow)
        // Decision 6 chooses again: Releases.
        XCTAssertTrue(row("slow", "releases").isSelected)
        goBack()
        XCTAssertEqual(app.textFields[AccessibilityID.addressField].value as? String, Fixture.slow, "the address field is unchanged")
        button(AccessibilityID.cancelButton).tap()
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
