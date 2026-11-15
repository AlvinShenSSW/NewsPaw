import XCTest

/// RD11 criteria 11 and 17: the screenshots, and the memory run. Each is
/// skipped unless its environment variable is set, as the other screenshot
/// tests are: they assert nothing beyond what `ReadingTests` asserts.
final class ReadingScreenshotTests: ReadingTestCase {
    /// An article with every block kind, an excerpt-only article, "Aa", the
    /// viewer and Settings › Reading, written with
    /// `TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR` set (and, optionally,
    /// `TEST_RUNNER_NEWSPAW_SCREENSHOT_VARIANT` = `zh` or `largest-text`;
    /// dark appearance is set on the simulator with `xcrun simctl ui`).
    func testCaptureReadingScreens() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NEWSPAW_SCREENSHOT_DIR"] != nil else {
            throw XCTSkip("set TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR to capture screenshots")
        }
        let variant = environment["NEWSPAW_SCREENSHOT_VARIANT"] ?? "default"
        var arguments: [String] = []
        switch variant {
        case "zh": arguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        case "largest-text": arguments = Self.largestText
        default: break
        }
        // Set up at the default text size, where the shared helpers find
        // the sidebar's buttons without scrolling.
        launchReading(arguments: variant == "largest-text" ? [] : arguments)
        let category = variant == "zh" ? "世界" : "World"
        createCategory(category)
        addSource(Reading.feed, to: category)
        launchReading(arguments: arguments)
        openCategoryList(category)

        openArticle("Every block")
        waitFor(block(at: 0))
        capture("01-every-block-headings-paragraph")
        scrollArticle(to: block("Third on the list"))
        capture("02-every-block-lists-quote")
        scrollArticle(to: block("Nested at 9,999"))
        capture("02b-every-block-long-numbers")
        let image = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'reading.image.'")).firstMatch
        scrollArticle(to: image)
        scrollArticle(to: block("A caption under the picture"))
        capture("03-every-block-image-caption-code")
        scrollArticle(to: block(containing: "これは日本語の段落です"))
        capture("04-every-block-table-chinese-japanese")
        scrollArticleToTop()

        openReadingSettings()
        capture("05-aa")
        closeReadingSettings()

        scrollArticle(to: image)
        image.tap()
        waitFor(element(AccessibilityID.imageViewerImage))
        capture("06-viewer")
        button(AccessibilityID.imageViewerCloseButton).tap()
        waitForAbsence(element(AccessibilityID.imageViewerImage))
        backToList()

        scrollList(to: "Short note")
        openArticle("Short note")
        waitFor(element(AccessibilityID.readingExcerptNote))
        capture("07-excerpt")
        backToList()

        scrollList(to: "Picture story")
        openArticle("Picture story")
        scrollArticle(to: element(AccessibilityID.readingImageFailed(9)))
        capture("08-pictures-small-and-failed")

        openSettings(row: AccessibilityID.readingSettingsRow)
        waitFor(button(AccessibilityID.textSizeLargerButton))
        capture("09-settings-reading")
    }

    /// Criterion 9, the part that is checked with animations on: the swipes
    /// beside vertical scrolling, the code block and the system's back
    /// swipe. Run with `TEST_RUNNER_NEWSPAW_ANIMATION_CHECK` = `1`; the app
    /// then keeps its animations. The touches are the harness's, not a
    /// finger's: a device check stays owed.
    func testSwipesWithAnimationsOn() throws {
        guard ProcessInfo.processInfo.environment["NEWSPAW_ANIMATION_CHECK"] == "1" else {
            throw XCTSkip("set TEST_RUNNER_NEWSPAW_ANIMATION_CHECK=1 to check the swipes with animations on")
        }
        keepsAnimations = true
        launchWithReadingFeed(isPad ? .landscapeLeft : .portrait)
        openArticle("Every block")
        sleep(1)
        let area = readingArea
        let origin = app.coordinate(withNormalizedOffset: .zero)
        func drag(from: CGPoint, by delta: CGVector, velocity: CGFloat, hold: TimeInterval = 0) {
            let start = origin.withOffset(CGVector(dx: from.x, dy: from.y))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(delta), withVelocity: XCUIGestureVelocity(velocity), thenHoldForDuration: hold)
        }
        func note(_ text: String) {
            record("animations-on", text)
        }
        let centre = CGPoint(x: area.midX, y: area.midY)
        let heading = block("The harbour at dusk")

        // Vertical scrolling is undisturbed.
        var before = heading.frame.minY
        drag(from: centre, by: CGVector(dx: 0, dy: -300), velocity: 400, hold: 0.3)
        sleep(1)
        let moved = heading.frame.minY - before
        note("vertical drag of 300 pt moved the text \(moved) pt")
        XCTAssertEqual(moved, -284, accuracy: 30)
        waitForTitle("Every block")
        before = heading.frame.minY
        drag(from: centre, by: CGVector(dx: -90, dy: -300), velocity: 900)
        sleep(2)
        note("fast diagonal drag (-90, -300) moved the text \(heading.exists ? heading.frame.minY - before : -9999) pt; open: \(readingTitle.label)")
        waitForTitle("Every block")
        scrollArticleToTop()

        // A swipe inside the code block scrolls the block.
        let box = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'reading.code.'")).firstMatch
        let code = block(containing: "let tide = Tide(turning: .now)")
        scrollArticle(to: code)
        // Clear of the bottom bar, where the block first shows.
        dragArticle(by: -180)
        sleep(1)
        if code.frame.width > box.frame.width {
            let codeX = code.frame.minX
            drag(from: CGPoint(x: box.frame.midX + 100, y: box.frame.midY), by: CGVector(dx: -200, dy: 0), velocity: 1_500)
            sleep(1)
            note("swipe inside the code block moved its text \(code.frame.minX - codeX) pt; open: \(readingTitle.label)")
            XCTAssertLessThan(code.frame.minX, codeX - 50, "the code block scrolled")
            waitForTitle("Every block")
        } else {
            note("the code block is not wider than its box at this width")
        }
        scrollArticleToTop()

        // Towards the leading edge: the next article, at its top.
        drag(from: CGPoint(x: area.midX + 120, y: area.midY), by: CGVector(dx: -240, dy: 0), velocity: 1_500)
        waitForTitle("Line heights")
        XCTAssertTrue(readingTitle.isHittable)
        note("swipe towards the leading edge opened \(readingTitle.label)")
        capture("animations-on-after-swipe")

        if usesTabs {
            // Towards the trailing edge from the middle: the system goes
            // back to the list.
            drag(from: CGPoint(x: area.midX - 120, y: area.midY), by: CGVector(dx: 240, dy: 0), velocity: 1_500)
            waitForAbsence(readingTitle)
            waitFor(articleRow("Every block"))
            note("swipe towards the trailing edge from the middle went back to the list")
            openArticle("Short note")
            // A slow drag past halfway, released: back too.
            drag(from: CGPoint(x: area.midX - 150, y: area.midY), by: CGVector(dx: 300, dy: 0), velocity: 250, hold: 0.1)
            waitForAbsence(readingTitle)
            note("slow drag towards the trailing edge went back to the list")
            openArticle("Short note")
            // From the screen's edge.
            drag(from: CGPoint(x: 2, y: area.midY), by: CGVector(dx: 300, dy: 0), velocity: 600, hold: 0.1)
            waitForAbsence(readingTitle)
            note("drag from the leading edge went back to the list")
            openArticle("Short note")
            // A short drag, let go: the article stays.
            drag(from: CGPoint(x: area.midX - 120, y: area.midY), by: CGVector(dx: 60, dy: 0), velocity: 100, hold: 0.5)
            sleep(1)
            waitForTitle("Short note")
            note("short drag towards the trailing edge left the article open")
        } else {
            drag(from: CGPoint(x: area.midX - 120, y: area.midY), by: CGVector(dx: 240, dy: 0), velocity: 1_500)
            waitForTitle("Every block")
            note("swipe towards the trailing edge opened \(readingTitle.label)")
            // At the first article the same swipe does nothing.
            drag(from: CGPoint(x: area.midX - 120, y: area.midY), by: CGVector(dx: 240, dy: 0), velocity: 1_500)
            sleep(1)
            waitForTitle("Every block")
        }
        // And a vertical drag still scrolls.
        let text = waitFor(block(at: 0))
        before = text.frame.minY
        drag(from: centre, by: CGVector(dx: 0, dy: -150), velocity: 400, hold: 0.3)
        sleep(1)
        note("vertical drag of 150 pt at the end moved the text \(text.frame.minY - before) pt")
    }

    /// Criterion 11: opens the article with 100 large images, waits where
    /// the run asks (`TEST_RUNNER_NEWSPAW_MEMORY_DIR`: a file `ready-<step>`
    /// is written there, and the test goes on when `go-<step>` appears), so
    /// that the app's memory can be read from outside at each step.
    func testHundredPicturesMemory() throws {
        guard let directory = ProcessInfo.processInfo.environment["NEWSPAW_MEMORY_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_NEWSPAW_MEMORY_DIR to measure memory")
        }
        func pause(_ step: String) {
            let folder = URL(fileURLWithPath: directory)
            try? Data().write(to: folder.appendingPathComponent("ready-\(step)"))
            let deadline = Date().addingTimeInterval(120)
            while !FileManager.default.fileExists(atPath: folder.appendingPathComponent("go-\(step)").path), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        launchWithReadingFeed()
        openArticle("Hundred pictures")
        waitFor(block("Picture 1 of a hundred."))
        // Time for the first images.
        sleep(5)
        pause("1-top")
        let last = block("After the hundred pictures.")
        let area = readingArea
        let from = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: area.midX, dy: area.midY + 250))
        var drags = 0
        // Slowly enough for every image to load and be drawn on the way.
        while !(last.exists && last.isHittable), drags < 400 {
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -500)), withVelocity: 1_200, thenHoldForDuration: 0.3)
            drags += 1
        }
        XCTAssertTrue(last.exists, "the end was not reached in \(drags) drags")
        record("memory-drags", "\(drags) drags to the end")
        sleep(3)
        pause("2-end")
        var back = 0
        while !(readingTitle.exists && readingTitle.isHittable), back < 400 {
            from.withOffset(CGVector(dx: 0, dy: -500))
                .press(forDuration: 0.05, thenDragTo: from, withVelocity: 3_000, thenHoldForDuration: 0.1)
            back += 1
        }
        sleep(5)
        pause("3-back-at-top")
    }
}
