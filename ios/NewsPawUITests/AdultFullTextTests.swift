import XCTest

/// RD12 decision 8 with RD18: in the adult partition the full text of an
/// article is fetched, extracted and kept in the adult library, by the
/// adult workspace's own loader; after a lock and an unlock it is read
/// from there, and the normal library has none of it.
final class AdultFullTextTests: AdultTestCase {
    private let feed = "https://fulltext.example.invalid/rss.xml"
    private var fullTextNote: XCUIElement { element(AccessibilityID.readingFullTextNote) }

    private var pagesRequested: Int {
        guard let match = report.firstMatch(of: /pages=(-?\d+)/) else { return -2 }
        return Int(match.1) ?? -2
    }

    private func edition() -> String {
        let paragraph = waitFor(app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", AccessibilityID.readingBlockPrefix, "Edition "
        )).firstMatch)
        return paragraph.label.firstMatch(of: /Edition (\d+)/).map { String($0.1) } ?? ""
    }

    func testAnAdultArticlesFullTextIsTheAdultLibrarys() {
        launchAtFullWidth(authentication: ["passed", "passed", "passed"])
        turnOnAdult()
        enterAdult()
        createCategory("Velvet")
        addSource(feed, to: "Velvet")
        openSourceList("Full Text Feed", in: "Velvet")
        chooseFilter("All")
        openArticle("Fetched story")
        waitFor(fullTextNote)
        let first = edition()
        XCTAssertFalse(first.isEmpty)
        waitForReport("pages=1")

        // Locked and unlocked: the adult library's stored extraction, no
        // second request.
        backToList()
        tapLock()
        waitForPartition(Wording.normal)
        waitForReport(Self.closed, Self.dropped)
        assertNothingShown(of: ["Velvet", "Full Text Feed", "Fetched story"], on: "the normal partition after the lock")
        enterAdult()
        openSourceList("Full Text Feed", in: "Velvet")
        chooseFilter("All")
        openArticle("Fetched story")
        waitFor(fullTextNote)
        XCTAssertEqual(edition(), first)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(pagesRequested, 1, report)

        // The normal partition: the same feed has no extraction of its own;
        // its first opening asks for the page again.
        backToList()
        tapLock()
        waitForPartition(Wording.normal)
        createCategory("World")
        addSource(feed, to: "World")
        openSourceList("Full Text Feed", in: "World")
        openArticle("Fetched story")
        waitFor(fullTextNote)
        XCTAssertNotEqual(edition(), first)
        waitForReport("pages=2")
    }
}
