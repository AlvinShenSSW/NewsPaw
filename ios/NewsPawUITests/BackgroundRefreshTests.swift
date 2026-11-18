import XCTest

/// RD24 criteria 2–5 and 9 in the app, on the simulator. The simulator's
/// task scheduler is unavailable (assumption A2), so a run is delivered by
/// the debug control "Deliver background refresh": with a request pending
/// in the recording scheduler, it moves the debug clock to the request's
/// earliest start and makes one background run while the app is in front.
/// What a run did is read from the debug report: `scheduled`, `background`,
/// `runs`, `adultOpens`.
final class BackgroundRefreshTests: AdultTestCase {
    private enum Fixture {
        static let counting = "https://counting.example.invalid/rss.xml"
        static let countingSource = "Counting Feed"
        static let feed = "https://feed.example.invalid/rss.xml"
        static let footer = "When NewsPaw is not open, the system may let it collect your sources and translate new titles. "
            + "The system decides when and how often. Nothing is refreshed in the background with Manual Only, and no notification is sent."
        static let notRunYet = "Has not run in the background yet."
    }

    /// How long a wait on the report may take: a bound a stalled runner
    /// does not reach; a passing test returns as soon as the report holds.
    private static let reportBound: TimeInterval = 60

    private var deliverButton: XCUIElement { element(DebugAccessibilityID.deliverBackgroundRefresh) }
    private var backgroundToggle: XCUIElement { app.switches[AccessibilityID.backgroundRefreshToggle] }
    private var runsLine: XCUIElement { element(AccessibilityID.backgroundRuns) }

    /// A number the report holds after `name=`.
    private func reported(_ name: String) -> Int {
        let report = self.report
        guard let range = report.range(of: "\(name)=") else { return -1 }
        return Int(report[range.upperBound...].prefix { $0.isNumber }) ?? -1
    }

    private func deliver() {
        waitFor(deliverButton).tap()
    }

    /// Launches with the delivery control shown (its own launch key, review
    /// R3), at full width in portrait.
    private func launchDelivering(_ application: XCUIApplication = XCUIApplication(), arguments: [String] = [], authentication: [String] = []) {
        application.launchEnvironment[UITestLaunchKey.backgroundDelivery] = "1"
        launch(application, arguments: arguments, authentication: authentication)
        rotate(.portrait)
        requireFullWidth()
    }

    /// Settings › Refresh, with the background section in view.
    private func openRefreshSettings() {
        openSettings()
        waitFor(element(AccessibilityID.refreshRow)).tap()
        scrollTo(backgroundToggle)
    }

    // MARK: - Test 1: a run collects, translates and leaves the adult partition alone

    /// The counting source has one unread article, translated; the adult
    /// partition is on, has a source, and is locked. A delivered run
    /// collects the normal library once and translates the new title; the
    /// adult library is asked for not once more, its pool stays closed, and
    /// nothing of it is shown in the normal partition.
    func testARunCollectsTranslatesAndLeavesTheAdultPartitionAlone() {
        let application = XCUIApplication()
        application.launchEnvironment[UITestLaunchKey.translationModels] = "primary"
        launchDelivering(application, authentication: ["passed", "passed", "passed"])

        createCategory("World")
        addSource(Fixture.counting, to: "World")
        expand("World")
        waitForValue(waitFor(sourceRow(Fixture.countingSource)), "1 unread")
        openCategoryList("World")
        waitFor(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "译[zh-Hans]：Counting story")).firstMatch)
        XCTAssertEqual(articleRowsShown().count, 1)

        // The adult partition: on, a source of its own, locked.
        turnOnAdult()
        enterAdult()
        createCategory("Velvet")
        addSource(Fixture.feed, to: "Velvet")
        tapLock()
        waitForPartition(Wording.normal)
        waitForReport(Self.closed)
        let adultOpens = reported("adultOpens")
        XCTAssertGreaterThan(adultOpens, 0, report)

        // The scene enters the background and returns: the schedule is
        // reconciled with an earliest start after the launch's refresh.
        leaveAndReturn()
        waitForReport("scheduled=yes", "runs=0", "background=none")

        // Today, with no slide-over panel open: on the iPad a tap outside
        // the panel closes it and reaches nothing else.
        showToday()
        deliver()
        waitForReport("background=collected", "runs=1", seconds: Self.reportBound)

        // One more article, both translated.
        expand("World")
        waitForValue(waitFor(sourceRow(Fixture.countingSource)), "2 unread")
        openCategoryList("World")
        let translated = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            let rows = self.articleRowsShown()
            return rows.count == 2 && rows.allSatisfy { $0.label.contains("译[zh-Hans]：Counting story") }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [translated], timeout: Self.reportBound), .completed,
                       "rows: \(articleRowsShown().map(\.label))")

        // The adult partition was not touched.
        XCTAssertEqual(reported("adultOpens"), adultOpens, "the run asked for the adult library: \(report)")
        waitForReport(Self.closed)
        let adultNames = ["Velvet", "Fixture Feed", "Fixture story"]
        showToday()
        assertNothingShown(of: adultNames, on: "Today")
        expand("World")
        waitFor(sourceRow(Fixture.countingSource))
        assertNothingShown(of: adultNames, on: "the category list")
        openAllUnread()
        assertNothingShown(of: adultNames, on: "All Unread")
        XCTAssertEqual(reported("adultOpens"), adultOpens, report)
    }

    // MARK: - Overviews (RD23 with RD24's handoff; batch 4)

    /// A background run collects but writes no overview (RD24: no
    /// overviews in the background); the next entry into the app, with no
    /// refresh due, writes it without a pull (RD24's handoff to RD23).
    /// World is Manual while its source is added and the schedule is made,
    /// so that no entry before the run writes its overview first.
    func testABackgroundRunWritesNoOverviewAndTheNextEntryDoes() {
        let application = XCUIApplication()
        application.launchEnvironment[UITestLaunchKey.translationModels] = "primary"
        launchDelivering(application)
        createCategory("World")
        setOverviews(of: "World", to: "Manual")
        addSource(Fixture.counting, to: "World")
        leaveAndReturn()
        waitForReport("scheduled=yes", "runs=0", "background=none")
        setOverviews(of: "World", to: "Automatic")

        showToday()
        deliver()
        waitForReport("background=collected", "runs=1", seconds: Self.reportBound)
        let summary = element(AccessibilityID.overview("summary", "World"))
        // The run's articles are counted on the card; nothing was written.
        waitFor(element(AccessibilityID.overview("newCount", "World")))
        XCTAssertFalse(summary.exists, "a background run wrote an overview")

        // The next entry: the run has just collected, so no refresh is due;
        // the entry's due check writes the overview.
        leaveAndReturn()
        showToday()
        let written = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            summary.exists && summary.label.contains("概览[zh-Hans]：")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [written], timeout: Self.reportBound), .completed, summary.exists ? summary.label : "no summary")
    }

    /// Batch 4, gate run 2: one overview due check per entry. With no
    /// refresh recorded, the entry's refresh runs and its end makes the
    /// check; the category's job fails at once (the fixture answers 429 to
    /// "fixture:limit"), and no second check sends it again in that entry.
    /// An entry with no refresh due makes one check of its own.
    func testAnEntryMakesOneOverviewDueCheck() {
        let application = XCUIApplication()
        application.launchEnvironment[UITestLaunchKey.translationModels] = "primary"
        launchDelivering(application)
        createCategory("Limited")
        addSource("https://translationwords.example.invalid/limit.xml", to: "Limited")
        let checks = reported("overviewDueChecks")
        let requests = reported("overviewRequests")
        XCTAssertGreaterThanOrEqual(checks, 0, report)

        // The entry's refresh runs (none is recorded yet); its end checks.
        leaveAndReturn()
        showToday()
        let issue = element(AccessibilityID.overview("issue", "Limited"))
        XCTAssertTrue(issue.waitForExistence(timeout: Self.reportBound), "no failure shown")
        // Time for a second check, were one sent.
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(reported("overviewDueChecks"), checks + 1, report)
        XCTAssertEqual(reported("overviewRequests"), requests + 1, "a second request in one entry: \(report)")

        // An entry with no refresh due: its own one check.
        leaveAndReturn()
        let one = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            self.reported("overviewDueChecks") >= checks + 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [one], timeout: Self.reportBound), .completed, report)
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(reported("overviewDueChecks"), checks + 2, report)
    }

    /// Category Settings › Overviews of `category`: Automatic, Manual or
    /// Off, saved.
    private func setOverviews(of category: String, to label: String) {
        openCategoryList(category)
        openListSettings(source: false)
        waitFor(app.textFields[AccessibilityID.nameField])
        let picker = scrollTo(button(AccessibilityID.overviewModePicker))
        picker.tap()
        waitFor(app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch).tap()
        let chosen = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            picker.exists && ((picker.value as? String)?.contains(label) == true || picker.label.contains(label))
        }, object: nil)
        _ = XCTWaiter.wait(for: [chosen], timeout: timeout)
        tapSave()
        waitForAbsence(app.textFields[AccessibilityID.nameField])
    }

    // MARK: - Test 2: the switch

    /// Settings › Refresh: Background Refresh is on, with its footer and
    /// "Has not run in the background yet."; off, no request is pending and
    /// a delivery does nothing; on again, a request is pending and a
    /// delivered run is counted in the line; after a relaunch the switch
    /// and the line are as left.
    func testTheSwitch() {
        launchDelivering()
        openRefreshSettings()
        XCTAssertEqual(backgroundToggle.value as? String, "1")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", Fixture.footer)).firstMatch.exists, "the footer")
        XCTAssertEqual(waitFor(runsLine).label, Fixture.notRunYet)
        waitForReport("scheduled=yes", "runs=0", "background=none")

        flip(backgroundToggle)
        XCTAssertEqual(backgroundToggle.value as? String, "0")
        waitForReport("scheduled=no")
        deliver()
        // The delivery was handled, and with no request pending it ran
        // nothing and recorded nothing.
        waitForReport("deliveries=1", seconds: Self.reportBound)
        waitForReport("scheduled=no", "runs=0", "background=none")

        flip(backgroundToggle)
        waitForReport("scheduled=yes")
        deliver()
        waitForReport("runs=1", seconds: Self.reportBound)
        let result = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            !self.report.contains("background=none")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [result], timeout: Self.reportBound), .completed, report)
        XCTAssertTrue(report.contains("background=collected"), report)
        // The line is read when the screen appears.
        goBack()
        openRefreshSettings()
        XCTAssertTrue(waitFor(runsLine).label.hasPrefix("Ran in the background 1 time in the last 7 days, most recently "),
                      runsLine.label)

        // As left, after a relaunch: off, with the run still counted.
        flip(backgroundToggle)
        relaunch()
        rotate(.portrait)
        openRefreshSettings()
        XCTAssertEqual(backgroundToggle.value as? String, "0")
        XCTAssertTrue(waitFor(runsLine).label.hasPrefix("Ran in the background 1 time"), runsLine.label)
        waitForReport("scheduled=no", "runs=1")
    }

    // MARK: - Screenshots

    /// Settings › Refresh with the background section, before and after a
    /// run, in light and dark appearance, in English, in Simplified
    /// Chinese and at the largest text size. Written when run with
    /// `TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR` set; skipped otherwise.
    func testCaptureBackgroundSettings() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["NEWSPAW_SCREENSHOT_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_NEWSPAW_SCREENSHOT_DIR to capture screenshots")
        }
        let device = (environment["SIMULATOR_DEVICE_NAME"] ?? "device").replacingOccurrences(of: " ", with: "-")
        let variants: [(String, [String])] = [
            ("en", []),
            ("zh", ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]),
            ("largest-text", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]),
        ]
        defer { XCUIDevice.shared.appearance = .light }
        for (appearanceName, appearance) in [("light", XCUIDevice.Appearance.light), ("dark", .dark)] {
            XCUIDevice.shared.appearance = appearance
            for (variant, arguments) in variants {
                func capture(_ name: String) {
                    let url = URL(fileURLWithPath: directory)
                        .appendingPathComponent("\(device)-\(appearanceName)-\(variant)-background-\(name).png")
                    try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
                }
                // A library of its own for each variant: "not run yet" first.
                setUpLibraryName()
                app.terminate()
                launchDelivering(arguments: arguments)
                openRefreshSettings()
                capture("1-not-run")
                deliver()
                waitForReport("runs=1", seconds: Self.reportBound)
                goBack()
                openRefreshSettings()
                scrollTo(runsLine)
                if variant == "largest-text" {
                    // The whole line above the tab bar.
                    app.swipeUp()
                }
                capture("2-ran-once")
            }
        }
    }
}
