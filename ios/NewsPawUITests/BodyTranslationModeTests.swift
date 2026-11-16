import XCTest

/// RD15 decision 11 (ux S4, section 2): the display modes from the bottom
/// bar's menu and from `T`, the header in every mode, Side by Side, the
/// default mode of Settings › Reading, and the block at the top kept at the
/// top across a switch and while translations arrive. Criterion 7,
/// assumptions A3 and A6.
final class BodyTranslationModeTests: BodyTranslationTestCase {
    /// Criterion 7 and A6: the bar's menu holds an inline picker of the
    /// three modes that XCUITest can choose from; the header shows both
    /// titles in every mode; Side by Side shows each translated block
    /// followed by its original and an untranslated block once; a new
    /// opening starts in Settings › Reading's default.
    func testDisplayModes() {
        launchWithBodies()
        openBody(Body.primaryRefuses)
        // Paragraph 1 refused (no backup): it stays untranslated.
        waitForBanner(BodySentence.refused)
        waitForBlock(1, startingWith: Translation.translated(Body.paragraph(2, of: Body.primaryRefuses)))
        waitForTitle(Translation.translated(Body.primaryRefuses))
        XCTAssertEqual(modeValue, "Translation")

        chooseMode("original")
        XCTAssertEqual(modeValue, "Original")
        waitForBlock(1, startingWith: Body.paragraph(2, of: Body.primaryRefuses))
        XCTAssertEqual(readingTitle.label, Translation.translated(Body.primaryRefuses), "the header in Original")
        XCTAssertEqual(element(AccessibilityID.readingOriginalTitle).label, Body.primaryRefuses)
        XCTAssertFalse(element(AccessibilityID.readingOriginalBlock(1)).exists)

        chooseMode("side_by_side")
        XCTAssertEqual(modeValue, "Side by Side")
        waitForBlock(1, startingWith: Translation.translated(Body.paragraph(2, of: Body.primaryRefuses)))
        let original = waitFor(element(AccessibilityID.readingOriginalBlock(1)))
        XCTAssertTrue(original.label.hasPrefix(Body.paragraph(2, of: Body.primaryRefuses)), original.label)
        XCTAssertGreaterThan(original.frame.minY, block(at: 1).frame.minY, "the original follows its translation")
        // The untranslated block once.
        XCTAssertTrue(block(at: 0).label.hasPrefix(Body.paragraph(1, of: Body.primaryRefuses)), block(at: 0).label)
        XCTAssertFalse(element(AccessibilityID.readingOriginalBlock(0)).exists)
        XCTAssertEqual(element(AccessibilityID.readingOriginalTitle).label, Body.primaryRefuses)
        screenshot("RD15 Side by Side")

        chooseMode("translation")
        waitForAbsence(element(AccessibilityID.readingOriginalBlock(1)))

        // Settings › Reading's default applies to the next opening.
        openSettings(row: AccessibilityID.readingSettingsRow)
        let sideBySide = scrollTo(option("Side by Side"))
        sideBySide.tap()
        let chosen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: sideBySide)
        XCTAssertEqual(XCTWaiter.wait(for: [chosen], timeout: timeout), .completed)
        openCategoryList(Body.category)
        chooseFilter("All")
        openBody(Body.markup)
        waitForBlock(0, Translation.translated(Body.markupParagraph))
        waitFor(element(AccessibilityID.readingOriginalBlock(0)))
        XCTAssertEqual(modeValue, "Side by Side")
    }

    /// Assumption A3: the block at the top stays at the top across each
    /// switch, and while translations arrive above and at it.
    func testTheTopBlockStaysAcrossSwitches() {
        launchTranslating()
        // Translation waits for Translate, so that it can arrive while the
        // article is scrolled.
        openTranslationSettings()
        flip(scrollTo(app.switches[AccessibilityID.translateBodyOnOpenToggle]))
        addFeed(Body.feed, to: Body.category)
        openBody(Body.many)
        waitFor(translateButton)
        _ = scrollArticle(to: block(at: 24))
        let before = topBlock()
        XCTAssertNotNil(before.index, "no block at the top")
        record("A3 before", "block \(before.index ?? -1) at \(before.minY), the scroll view's top at \(scrollTop)")

        // Translations arrive above the reader and at it.
        translateButton.tap()
        waitForBlock(before.index ?? 0, startingWith: Translation.translated("Short paragraph"))
        waitForAbsence(progressLine)
        let arrived = settledPosition(of: before.index ?? 0)
        record("A3 after the arrivals", "block \(before.index ?? -1) at \(arrived), top block \(topBlock().index ?? -1)")
        XCTAssertEqual(arrived, before.minY, accuracy: lineHeight, "the arrivals moved the block at the top")

        // Each switch: the block at the top stays at the top. Its first
        // line — in Side by Side, its translation — is at the top after the
        // switch: not under the bar, and within one line of its edge.
        for mode in ["original", "translation", "side_by_side", "translation", "side_by_side", "original"] {
            let top = topBlock()
            let index = top.index ?? 0
            let reported = reportedBlock
            chooseMode(mode)
            let first = settledPosition(of: index)
            let (translation, original) = positions(of: index)
            record("A3 switch to \(mode)", "block \(index) at \(top.minY) before; its first line at \(first) after "
                + "(translation \(translation), original \(original)); the scroll view's top at \(scrollTop); top block now "
                + "\(topBlock().index ?? -1); the screen's stored position \(reported) before, \(reportedBlock) after")
            XCTAssertGreaterThanOrEqual(first, scrollTop - 2, "the switch to \(mode) left block \(index)'s first line under the bar")
            XCTAssertLessThanOrEqual(first, scrollTop + lineHeight, "the switch to \(mode) moved block \(index) down from the top")
            XCTAssertEqual(topBlock().index, index, "the switch to \(mode) changed the block at the top")
        }
    }

    /// Criterion 7: `T` cycles the modes in ux's order (a hardware
    /// keyboard: iPad).
    func testTKeyCyclesTheModes() throws {
        guard isPad else { throw XCTSkip("the key is checked on the iPad") }
        launchWithBodies()
        openBody(Body.markup)
        waitForBlock(0, Translation.translated(Body.markupParagraph))
        XCTAssertEqual(modeValue, "Translation")
        for expected in ["Original", "Side by Side", "Translation"] {
            app.typeKey("t", modifierFlags: [])
            // What each mode shows of block 0, waited for; then the menu.
            switch expected {
            case "Original": waitForBlock(0, Body.markupParagraph)
            case "Side by Side": waitFor(element(AccessibilityID.readingOriginalBlock(0)))
            default: waitForAbsence(element(AccessibilityID.readingOriginalBlock(0)))
            }
            XCTAssertEqual(modeValue, expected)
        }
    }

    // MARK: - Positions

    /// One line of body text at the default size, with its spacing.
    let lineHeight: CGFloat = 30

    /// Where the scroll view's content starts: under the navigation bar.
    var scrollTop: CGFloat {
        let bars = app.navigationBars.allElementsBoundByIndex.filter { $0.exists && $0.frame.intersects(readingArea) }
        return bars.map(\.frame.maxY).max() ?? readingArea.minY
    }

    /// The block at the top: the first whose text (or, in Side by Side, its
    /// original) ends below the scroll view's top, and the top of that text.
    func topBlock() -> (index: Int?, minY: CGFloat) {
        let top = scrollTop
        let prefixes = [AccessibilityID.readingBlockPrefix, "reading.original."]
        let texts = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@", prefixes[0], prefixes[1]))
            .allElementsBoundByIndex
            .filter { $0.exists && !$0.frame.isEmpty && $0.frame.maxY - selectionInset > top + 1 }
            .sorted { $0.frame.minY < $1.frame.minY }
        guard let first = texts.first, let number = first.identifier.split(separator: ".").last, let index = Int(number) else {
            return (nil, 0)
        }
        return (index, first.frame.minY + selectionInset)
    }

    /// The top of block `index`'s first line once it has stopped moving
    /// (two equal readings in a row; ten seconds at most).
    func settledPosition(of index: Int) -> CGFloat {
        var last = position(of: index)
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            let now = self.position(of: index)
            defer { last = now }
            return now == last && now.isFinite
        }, object: nil)
        _ = XCTWaiter.wait(for: [settled], timeout: timeout)
        return position(of: index)
    }

    func position(of index: Int) -> CGFloat {
        let target = block(at: index)
        return target.exists ? target.frame.minY + selectionInset : .infinity
    }

    /// How far a selectable text's reported frame reaches beyond its text,
    /// above and below: half of the 32 pt measured at the default size
    /// (RD11, `ReadingTestCase.latinPitch`). Measured here: block 18 set at
    /// the top edge (116) reported its frame from 115.3.
    let selectionInset: CGFloat = 16

    /// The top of a block's text and of its original under it (Side by
    /// Side); `infinity` for one that is not there.
    func positions(of index: Int) -> (CGFloat, CGFloat) {
        let original = element(AccessibilityID.readingOriginalBlock(index))
        return (position(of: index), original.exists ? original.frame.minY + selectionInset : .infinity)
    }
}
