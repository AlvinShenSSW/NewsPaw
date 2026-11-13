import XCTest

/// RD09 criteria 12, 14, 15 and 17: thumbnails and Settings → Data,
/// accessibility and the empty states, against the debug fixture transport
/// only. Criterion 16 (the keyboard) is in `TypedKeyTests`.
final class ArticleDetailTests: ArticleTestCase {
    private static let largest = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    private static let thumbnailSide = 72.0

    // MARK: - Criteria 12 and 14: thumbnails and Settings → Data

    /// After the article with an image has been on screen, Settings → Data
    /// shows a size above zero; Clear makes it zero and disables itself.
    func testThumbnailFillsTheCacheAndClearEmptiesIt() {
        launchAtFullWidth()
        createCategory("World")
        addSource(Fixture.articles, to: "World")
        openDataSettings()
        let zero = Int64(0).formatted(.byteCount(style: .file))
        XCTAssertEqual(waitFor(element(AccessibilityID.cacheSize)).label, zero)
        XCTAssertFalse(button(AccessibilityID.clearCacheButton).isEnabled)
        // Back to Settings' root, where the panes' sidebar button is.
        goBack()

        openCategoryList("World")
        waitFor(articleRow("Image story"))
        screenshot("list-with-thumbnail")
        // The screen reads the size each time it is shown.
        var size = ""
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            openDataSettings()
            size = waitFor(element(AccessibilityID.cacheSize)).label
        } while size == zero && Date() < deadline
        XCTAssertNotEqual(size, zero, "the thumbnail was cached")
        record("data-size", "Settings → Data after the list: \(size)")
        screenshot("data-with-size")
        let clear = button(AccessibilityID.clearCacheButton)
        XCTAssertTrue(clear.isEnabled)
        clear.tap()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", zero), object: element(AccessibilityID.cacheSize))
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: timeout), .completed)
        let disabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == false"), object: clear)
        XCTAssertEqual(XCTWaiter.wait(for: [disabled], timeout: timeout), .completed)
    }

    /// At the largest text size the row with an image is taller than the
    /// row without one by at least the thumbnail's height (the thumbnail
    /// sits below the text); at the default size it is not.
    func testThumbnailBelowTheTextAtTheLargestSize() {
        launchAtFullWidth()
        createCategory("World")
        addSource(Fixture.articles, to: "World")
        app.terminate()
        launch(arguments: Self.largest)
        rotate(.portrait)
        requireFullWidth()
        openCategoryList("World")
        let image = waitFor(articleRow("Image story"))
        let plain = scrollTo(articleRow("Plain story"))
        let taller = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            image.frame.height - plain.frame.height >= Self.thumbnailSide
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [taller], timeout: 20), .completed,
                       "image row \(image.frame.height), plain row \(plain.frame.height)")
        record("largest-heights", "largest size: image row \(image.frame.height) pt, plain row \(plain.frame.height) pt")
        XCTAssertLessThanOrEqual(image.frame.maxX, window.maxX + 0.5)
        app.swipeDown()
        screenshot("largest-text-thumbnail-row")

        app.terminate()
        launch()
        rotate(.portrait)
        openCategoryList("World")
        let imageRow = waitFor(articleRow("Image story"))
        let plainRow = waitFor(articleRow("Plain story"))
        // The thumbnail is in the cache; give it time to show.
        sleep(3)
        record("default-heights", "default size: image row \(imageRow.frame.height) pt, plain row \(plainRow.frame.height) pt")
        XCTAssertLessThan(imageRow.frame.height - plainRow.frame.height, Self.thumbnailSide)
        screenshot("default-thumbnail-row-and-row-without")
    }

    // MARK: - Criterion 15: accessibility

    func testRowLabelsCountsAndControls() {
        launchAtFullWidth()
        createCategory("World")
        addSource(Fixture.articles, to: "World")
        showCategoryList()
        waitForValue(element(AccessibilityID.categoryRow("World")), "3 unread")
        waitForValue(element(AccessibilityID.allUnreadRow), "3 unread")
        openCategoryList("World")
        let row = waitFor(articleRow("Plain story"))
        XCTAssertTrue(row.label.hasPrefix("Unread, Plain story, Articles Feed, "), row.label)
        XCTAssertTrue(row.label.hasSuffix(" ago"), row.label)
        XCTAssertFalse(row.label.contains("Starred"))
        XCTAssertEqual(articleRowsShown().filter { $0.identifier == row.identifier }.count, 1, "one element per row")
        swipeAction(on: row, leading: false, "Star")
        waitForLabel(row, containing: ", Starred")
        XCTAssertTrue(row.label.hasSuffix(", Starred"), row.label)

        // Icon-only controls: labels, and their tap targets.
        let markAll = waitFor(button(AccessibilityID.markAllReadButton))
        XCTAssertEqual(markAll.label, "Mark All as Read")
        XCTAssertEqual(waitFor(button(AccessibilityID.listMenu)).label, "More")
        assertTapTarget(markAll, "Mark All as Read", activated: { [unowned self] in app.alerts.firstMatch.exists }, reset: { [unowned self] in
            app.alerts.firstMatch.buttons["Cancel"].tap()
            waitForAbsence(app.alerts.firstMatch)
        })
        openArticle("Image story")
        let star = waitFor(button(AccessibilityID.readingStarButton))
        XCTAssertEqual(star.label, "Star")
        XCTAssertEqual(button(AccessibilityID.readingShareButton).label, "Share")
        XCTAssertEqual(button(AccessibilityID.readingReadButton).label, "Mark as Unread")
        assertTapTarget(star, "Star", activated: { star.label == "Unstar" }, reset: {
            star.tap()
            let back = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Star'"), object: star)
            _ = XCTWaiter.wait(for: [back], timeout: 5)
        })
    }

    /// The bar's icon buttons are the system's 36 pt glass shapes with a
    /// larger touch region (RD03): the edges of a 44 × 44 pt square centred
    /// on the control must each activate it.
    private func assertTapTarget(_ control: XCUIElement, _ name: String, activated: @escaping () -> Bool, reset: () -> Void) {
        let frame = control.frame
        let half = 21.5
        var points: [CGVector] = []
        if frame.height < 44 {
            points += [CGVector(dx: frame.midX, dy: frame.midY - half), CGVector(dx: frame.midX, dy: frame.midY + half)]
        }
        if frame.width < 44 {
            points += [CGVector(dx: frame.midX - half, dy: frame.midY), CGVector(dx: frame.midX + half, dy: frame.midY)]
        }
        record("tap-target-\(name)", "drawn frame \(frame); edge taps \(points.count)")
        for point in points {
            app.coordinate(withNormalizedOffset: .zero).withOffset(point).tap()
            let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in activated() }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 5), .completed, "\(name): a tap at \(point) (drawn \(frame)) did not activate it")
            reset()
        }
    }

    // MARK: - Criterion 17: empty states

    func testEmptyStates() {
        assertEmptyStates(arguments: [], words: Words.english)
    }

    func testEmptyStatesInSimplifiedChinese() {
        assertEmptyStates(arguments: ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"], words: Words.chinese)
    }

    private struct Words {
        var category: String
        var noArticles: String
        var caughtUp: String
        var noStarred: String
        var noArticleSelected: String
        var showAll: String
        var all: String
        var markAsRead: String
        var working: String

        static let english = Words(
            category: "World", noArticles: "No articles yet", caughtUp: "All caught up", noStarred: "No starred articles",
            noArticleSelected: "No article selected", showAll: "Show All", all: "All", markAsRead: "Mark as Read",
            working: "Working · last updated"
        )
        static let chinese = Words(
            category: "世界", noArticles: "还没有文章", caughtUp: "都读完了", noStarred: "还没有收藏的文章",
            noArticleSelected: "未选择文章", showAll: "显示全部", all: "全部", markAsRead: "标为已读",
            working: "正常 · 上次更新"
        )
    }

    private func assertEmptyStates(arguments: [String], words: Words) {
        launch(arguments: arguments)
        rotate(.portrait)
        requireFullWidth()
        createCategory(words.category)
        openCategoryList(words.category)
        XCTAssertEqual(waitFor(element(AccessibilityID.categoryEmpty)).label, words.noArticles)
        if !usesTabs {
            XCTAssertEqual(waitFor(element(AccessibilityID.noArticleSelected)).label, words.noArticleSelected)
        }
        openAllUnread()
        XCTAssertEqual(waitFor(element(AccessibilityID.allUnreadEmpty)).label, words.noArticles)
        openStarred()
        XCTAssertEqual(waitFor(element(AccessibilityID.starredEmpty)).label, words.noStarred)
        screenshot("empty-starred")

        addSource(Fixture.feed, to: words.category)
        openCategoryList(words.category)
        waitFor(articleRow("Fixture story one"))
        waitFor(button(AccessibilityID.markAllReadButton)).tap()
        waitFor(app.alerts.firstMatch).buttons[words.markAsRead].tap()
        waitForUnread(articleRow("Fixture story one"), false)
        openAllUnread()
        XCTAssertEqual(waitFor(element(AccessibilityID.allUnreadEmpty)).label, words.caughtUp)
        XCTAssertFalse(button(AccessibilityID.showAllButton).exists, "All Unread has no Show All")
        openCategoryList(words.category)
        XCTAssertEqual(waitFor(element(AccessibilityID.categoryEmpty)).label, words.caughtUp)
        screenshot("empty-caught-up")
        let showAll = waitFor(button(AccessibilityID.showAllButton))
        XCTAssertEqual(showAll.label, words.showAll)
        showAll.tap()
        waitFor(articleRow("Fixture story one"))
        XCTAssertEqual(selectedFilter(), words.all)

        // A source that holds no article: 40 days later clean-up has removed
        // them and the feed's items stay away.
        app.terminate()
        launch(clockOffsetDays: 40, arguments: arguments)
        rotate(.portrait)
        openSourceList("Fixture Feed", in: words.category)
        let empty = waitFor(element(AccessibilityID.sourceEmpty))
        XCTAssertTrue(empty.label.hasPrefix(words.noArticles), empty.label)
        XCTAssertTrue(empty.label.contains(words.working), empty.label)
        screenshot("empty-source")
    }

    // MARK: - Helpers

    /// Shows Settings → Data afresh, so that it reads the size again.
    private func openDataSettings() {
        if element(AccessibilityID.cacheSize).exists {
            goBack()
        } else if usesTabs {
            app.tabBars.buttons.element(boundBy: 3).tap()
            if !element(AccessibilityID.dataRow).waitForExistence(timeout: 3) {
                app.tabBars.buttons.element(boundBy: 3).tap()
            }
        } else {
            openSidebarIfNeeded()
            scrollTo(element(AccessibilityID.settingsRow)).tap()
            waitForAbsence(element(AccessibilityID.slideOverPanel))
            if !element(AccessibilityID.dataRow).waitForExistence(timeout: 3) {
                goBack()
            }
        }
        waitFor(element(AccessibilityID.dataRow)).tap()
        waitFor(element(AccessibilityID.cacheSize))
    }
}
