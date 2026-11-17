import XCTest

/// RD23 criteria 19 and 20: the card states on Today and in a category's
/// list — done (collapsed and expanded), writing, failed, daily limit,
/// write, nothing new, off — Earlier Overviews, and the card above "All
/// caught up"; the no-model state from a library without a model.
/// Written when run with `TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR` set (and,
/// optionally, `TEST_RUNNER_NEWSPAW_SCREENSHOT_VARIANT` = `zh` or
/// `largest-text`; dark appearance is set on the simulator with `xcrun
/// simctl ui`). Skipped otherwise: it asserts nothing beyond what
/// `OverviewTests` asserts.
final class OverviewScreenshotTests: OverviewTestCase {
    private struct Capture {
        let directory: String
        let variant: String
        let device: String
        let arguments: [String]
    }

    private func capture() throws -> Capture {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["NEWSPAW_SCREENSHOT_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR to capture screenshots")
        }
        let variant = environment["NEWSPAW_SCREENSHOT_VARIANT"] ?? "default"
        let device = (environment["SIMULATOR_DEVICE_NAME"] ?? "device").replacingOccurrences(of: " ", with: "-")
        let arguments: [String] = switch variant {
        case "zh": ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        case "largest-text": BrowserLayoutTests.largestText
        default: []
        }
        return Capture(directory: directory, variant: variant, device: device, arguments: arguments)
    }

    private var count = 0

    private func shoot(_ capture: Capture, _ name: String) {
        count += 1
        let url = URL(fileURLWithPath: capture.directory)
            .appendingPathComponent(String(format: "%@-%@-overview-%02d-%@.png", capture.device, capture.variant, count, name))
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }

    func testCaptureOverviewScreens() throws {
        let capture = try capture()
        let landscape: UIDeviceOrientation = isPad ? .landscapeLeft : .portrait
        // Set up in English at the default size: a done overview with
        // seeded earlier ones, a refused one, a manual category with new
        // articles, a slow manual one, a category with no source, and one
        // with overviews off.
        launchOverviews()
        addFeed(Translation.feed, to: Translation.category)
        addFeed(Translation.wordFeed("refuse"), to: "Refused")
        createCategory("Manual")
        setOverviews(of: "Manual", to: "Manual")
        addSource(Fixture.articles, to: "Manual")
        createCategory("Slow")
        setOverviews(of: "Slow", to: "Manual")
        addSource(Translation.wordFeed("slow"), to: "Slow")
        createCategory("Quiet")
        createCategory("Paused")
        addSource(Fixture.feed, to: "Paused")
        setOverviews(of: "Paused", to: "Off")
        launchOverviews(seed: true)
        refreshToday()
        waitForText(summary(Translation.category), Overview.summary(40, Translation.markup))
        waitForText(part("issue", "Refused"), Overview.refused)

        // The captures, at a limit of 0 so that nothing is written by
        // itself; "Limited" is added then, and its card says why.
        launchOverviews(limit: 0, arguments: capture.arguments, landscape)
        addFeed(Fixture.longCounting, to: "Limited")
        refreshToday()
        waitFor(summary(Translation.category))
        shoot(capture, "today-top")
        // Each card in turn, scrolled to.
        for (name, part) in [("Refused", "issue"), ("Manual", "newCount"), ("Slow", "newCount"), ("Limited", "issue")] {
            revealOnToday(self.part(part, name))
            shoot(capture, "today-\(name.lowercased())")
        }
        revealOnToday(todayRow("Quiet"))
        revealOnToday(todayRow("Paused"))
        shoot(capture, "today-nothing-new-and-off")
        // Writing: the slow word keeps the request two seconds.
        revealOnToday(button(AccessibilityID.overview("write", "Slow"))).tap()
        waitFor(part("working", "Slow"))
        shoot(capture, "today-writing")
        waitFor(summary("Slow"))
        // The done card on Today, with More.
        app.swipeDown()
        app.swipeDown()
        let more = button(AccessibilityID.overview("more", Translation.category))
        if more.waitForExistence(timeout: 3) {
            revealOnToday(more).tap()
            shoot(capture, "today-done-more")
        }

        // The list's card: collapsed, expanded, Earlier Overviews.
        openCategoryList(Translation.category)
        waitFor(card(Translation.category))
        shoot(capture, "list-collapsed")
        button(AccessibilityID.overview("expand", Translation.category)).tap()
        waitFor(part("note", Translation.category))
        shoot(capture, "list-expanded")
        scrollTo(button(AccessibilityID.overview("earlier", Translation.category))).tap()
        waitFor(element(AccessibilityID.earlierOverviewsList))
        shoot(capture, "earlier")
        button(AccessibilityID.earlierOverviewsDoneButton).tap()
        waitForAbsence(element(AccessibilityID.earlierOverviewsList))
        for name in ["Refused", "Limited", "Manual", "Quiet"] {
            openCategoryList(name)
            waitFor(card(name))
            shoot(capture, "list-\(name.lowercased())")
        }
        // Criterion 19: the card above "All caught up".
        openCategoryList("Manual")
        button(AccessibilityID.markAllReadButton).tap()
        waitFor(app.alerts.firstMatch).buttons.element(boundBy: app.alerts.firstMatch.buttons.count - 1).tap()
        waitForAbsence(app.alerts.firstMatch)
        showToday()
        openCategoryList("Manual")
        waitFor(element(AccessibilityID.categoryEmpty))
        shoot(capture, "list-card-and-all-caught-up")
    }

    func testCaptureNoModel() throws {
        let capture = try capture()
        launchOverviews(models: nil)
        addFeed(Translation.feed, to: Translation.category)
        launchOverviews(models: nil, arguments: capture.arguments, isPad ? .landscapeLeft : .portrait)
        showToday()
        waitFor(part("noModel", Translation.category))
        shoot(capture, "today-no-model")
        openCategoryList(Translation.category)
        waitFor(part("noModel", Translation.category))
        shoot(capture, "list-no-model")
    }
}
