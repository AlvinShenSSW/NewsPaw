import XCTest

/// The live smoke run (#192): the M1 path of spec section 7 walked in the
/// simulator against real public feeds, real web pages and a real model
/// service, as far as a simulator can. Off by default: every test skips
/// unless the test runner's environment names an output directory
/// (`TEST_RUNNER_NEWSPAW_LIVE_DIR`) and, when the model step is among the
/// steps, the model service (`TEST_RUNNER_NEWSPAW_LIVE_MODEL_URL`,
/// `TEST_RUNNER_NEWSPAW_LIVE_MODEL_NAME`, `TEST_RUNNER_NEWSPAW_LIVE_MODEL_KEY`).
/// `TEST_RUNNER_NEWSPAW_LIVE_STEPS` limits the steps: a comma-separated list
/// of step numbers (1–7), `feeds` (steps 2 and 3, no model) or `all` (the
/// default). Enabled, it makes real requests and costs model tokens.
///
/// The app keeps its UI-test library directory (a fresh, empty library and
/// keychain service of this test's own) and its animations off, but uses
/// the real feed transport, the real model HTTP, the real clock and the
/// real web pages (`UITestLaunchKey.liveServices`). The test itself makes
/// no request. The key reaches the app only through the model form, typed
/// into its secure field; it is never printed, attached, written or put
/// into a failure message.
///
/// Each step writes one line to `<NEWSPAW_LIVE_DIR>/steps.txt` — step,
/// `pass`, `fail` or `not run`, seconds, a neutral reason — and a
/// screenshot named after the device and the step. A failed step does not
/// stop the independent steps after it: the app is launched again on the
/// same library and the run goes on. Assertions are about shape, not
/// content: rows exist, a translated text differs from its original, the
/// reading screen has body blocks, the page line reads "Translated…", the
/// overview card has text, Usage lists requests, no error state. A network
/// wait is bounded at two minutes.
final class LiveSmokeTests: BodyTranslationTestCase {
    /// A source the run adds: well-known public feeds in English,
    /// Simplified Chinese and Japanese, a GitHub repository's releases and
    /// one site saved as a web page. Never the owner's list.
    struct Source {
        enum Kind { case feed, github, page }

        let name: String
        let address: String
        let category: String
        let kind: Kind
        /// Whether its titles are translated into Simplified Chinese.
        let translated: Bool
    }

    static let newsCategory = "Live News"
    static let pageCategory = "Live Pages"
    static let sources = [
        Source(name: "BBC World", address: "https://feeds.bbci.co.uk/news/world/rss.xml", category: newsCategory, kind: .feed, translated: true),
        Source(name: "BBC Chinese", address: "https://feeds.bbci.co.uk/zhongwen/simp/rss.xml", category: newsCategory, kind: .feed, translated: false),
        Source(name: "ITmedia", address: "https://rss.itmedia.co.jp/rss/2.0/itmedia_all.xml", category: newsCategory, kind: .feed, translated: true),
        Source(name: "Swift Releases", address: "https://github.com/swiftlang/swift", category: newsCategory, kind: .github, translated: true),
        Source(name: "Example Page", address: "https://example.com/", category: pageCategory, kind: .page, translated: true),
    ]
    /// The excerpt-only feed of step 4: its items carry a one-line
    /// description, so the app extracts the article from its page.
    static let excerptSource = "BBC World"
    static let pageSource = "Example Page"

    /// The bound of a wait for the network or a model.
    static let networkWait: TimeInterval = 120

    enum Step: String, CaseIterable {
        case model = "1-model"
        case sources = "2-sources"
        case refresh = "3-refresh"
        case titles = "3-titles"
        case fullText = "4-fulltext"
        case body = "4-body"
        case page = "5-page"
        case overview = "6-overview"
        case usage = "7-usage"

        /// The number of spec section 7's walk it belongs to.
        var number: Int {
            Int(rawValue.prefix(1)) ?? 0
        }
    }

    enum Outcome: String {
        case pass
        case fail
        case notRun = "not run"
    }

    /// Why a step stopped, in neutral words: never a key, a request or a
    /// model's reply.
    struct StepFailure: Error {
        let reason: String
    }

    private var directory: URL!
    private var selected: Set<Int> = []
    private var outcomes: [Step: Outcome] = [:]
    /// The sources added in step 2, by name.
    private var added: Set<String> = []
    /// Whether step 3's refresh run was started.
    private var refreshRan = false
    /// Issues recorded while a step runs, and what the step was doing.
    private var stepIsRunning = false
    private var issuesInStep = 0
    private var doing = ""

    override func setUp() async throws {
        try await super.setUp()
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["NEWSPAW_LIVE_DIR"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_NEWSPAW_LIVE_DIR (and the model's TEST_RUNNER_NEWSPAW_LIVE_MODEL_*) to run the live smoke test")
        }
        guard let steps = Self.steps(environment["NEWSPAW_LIVE_STEPS"]) else {
            throw XCTSkip("TEST_RUNNER_NEWSPAW_LIVE_STEPS lists no known step")
        }
        if steps.contains(1) {
            for name in ["NEWSPAW_LIVE_MODEL_URL", "NEWSPAW_LIVE_MODEL_NAME", "NEWSPAW_LIVE_MODEL_KEY"]
            where (environment[name] ?? "").isEmpty {
                throw XCTSkip("set TEST_RUNNER_\(name) for the model step, or limit the steps with TEST_RUNNER_NEWSPAW_LIVE_STEPS=feeds")
            }
        }
        selected = steps
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A failed check is a failed step, not the end of the run.
        continueAfterFailure = true
    }

    /// The step numbers `text` selects: all of them when it is absent;
    /// `nil` when it names an unknown step.
    static func steps(_ text: String?) -> Set<Int>? {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return Set(1...7) }
        var steps: Set<Int> = []
        for token in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
            switch token {
            case "all": steps.formUnion(1...7)
            case "feeds": steps.formUnion([2, 3])
            default:
                guard let number = Int(token), (1...7).contains(number) else { return nil }
                steps.insert(number)
            }
        }
        return steps.isEmpty ? nil : steps
    }

    // MARK: - The run

    func testLiveSmoke() {
        let device = deviceName
        appendLine("# \(ISO8601DateFormatter().string(from: Date())) \(device) steps=\(selected.sorted().map(String.init).joined(separator: ","))")
        launchLive()

        run(.model) { try stepModel() }
        run(.sources) { try stepSources() }
        run(.refresh, needs: refreshNeeds) { try stepRefresh() }
        run(.titles, needs: modelNeeds ?? (outcomes[.refresh] == .pass ? nil : "the refresh step did not pass")) { try stepTitles() }
        run(.fullText, needs: added.contains(Self.excerptSource) ? nil : "\(Self.excerptSource) was not added") { try stepFullText() }
        run(.body, needs: modelNeeds ?? (outcomes[.fullText] == .pass ? nil : "the full-text step did not pass")) { try stepBody() }
        run(.page, needs: modelNeeds ?? (added.contains(Self.pageSource) ? nil : "\(Self.pageSource) was not added")) { try stepPage() }
        run(.overview, needs: modelNeeds ?? (refreshRan ? nil : "no refresh run")) { try stepOverview() }
        run(.usage, needs: modelNeeds) { try stepUsage() }

        let failed = Step.allCases.filter { outcomes[$0] == .fail }.map(\.rawValue)
        XCTAssertTrue(failed.isEmpty, "live steps failed: \(failed.joined(separator: ", ")) (see steps.txt)")
    }

    /// Why the model's steps cannot run, or `nil`.
    private var modelNeeds: String? {
        switch outcomes[.model] {
        case .pass: nil
        case .fail: "the model step failed"
        default: "the model step did not run"
        }
    }

    private var refreshNeeds: String? {
        added.contains(where: { name in Self.sources.contains { $0.name == name && $0.kind != .page } }) ? nil : "no feed was added"
    }

    /// Runs `step` when it is selected and nothing it needs is missing,
    /// and records its line and its screenshot. A failed step is followed
    /// by a new launch on the same library, so that the next one starts
    /// from the shell.
    private func run(_ step: Step, needs missing: String? = nil, _ body: () throws -> String) {
        guard selected.contains(step.number) else {
            writeResult(step, .notRun, "not selected", seconds: 0)
            return
        }
        if let missing {
            writeResult(step, .notRun, missing, seconds: 0)
            return
        }
        let start = Date()
        issuesInStep = 0
        doing = "starting"
        stepIsRunning = true
        var outcome = Outcome.pass
        var reason: String
        do {
            reason = try body()
            try checkIssues()
        } catch let failure as StepFailure {
            outcome = .fail
            reason = failure.reason
        } catch {
            outcome = .fail
            reason = "\(doing): an unexpected error"
        }
        stepIsRunning = false
        saveScreenshot(step.rawValue)
        writeResult(step, outcome, reason, seconds: Date().timeIntervalSince(start))
        if outcome == .fail {
            launchLive()
        }
    }

    private func writeResult(_ step: Step, _ outcome: Outcome, _ reason: String, seconds: TimeInterval) {
        outcomes[step] = outcome
        appendLine("\(step.rawValue)\t\(outcome.rawValue)\t\(String(format: "%.0f", seconds))s\t\(reason)")
    }

    /// Counts the issues recorded while a step runs; they stay issues of
    /// the test.
    nonisolated override func record(_ issue: XCTIssue) {
        // A UI test records its issues on the main thread.
        MainActor.assumeIsolated {
            if stepIsRunning {
                issuesInStep += 1
            }
        }
        super.record(issue)
    }

    /// Names what the step does next, after checking that nothing failed
    /// so far.
    private func phase(_ text: String) throws {
        try checkIssues()
        doing = text
    }

    private func checkIssues() throws {
        if issuesInStep > 0 {
            throw StepFailure(reason: "\(doing): the screen did not respond as expected (see the test log)")
        }
    }

    /// The reason is read only when the condition fails: it may name an
    /// element that is there only then.
    private func require(_ condition: Bool, _ reason: @autoclosure () -> String) throws {
        try checkIssues()
        guard condition else { throw StepFailure(reason: reason()) }
    }

    /// On the tab structure, back out of a pushed reading screen or
    /// browser until the tab bar shows again, so that the next step starts
    /// from the shell. Nothing on the panes.
    private func returnToShell() {
        guard usesTabs else { return }
        var backs = 0
        while !app.tabBars.firstMatch.waitForExistence(timeout: 2), backs < 3, app.buttons["BackButton"].exists {
            goBack()
            backs += 1
        }
    }

    /// Launches the app on this test's library with the real services.
    private func launchLive() {
        app.terminate()
        let application = XCUIApplication()
        application.launchEnvironment[UITestLaunchKey.liveServices] = "1"
        launch(application)
        rotate(.portrait)
        requireFullSize()
    }

    // MARK: - Step 1: the model

    /// Settings › Models & Translation: the reading language is Simplified
    /// Chinese; the primary model is set up on the Custom service with the
    /// environment's address, model and key, passes Test and is saved.
    private func stepModel() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        try phase("opening Models & Translation")
        openTranslationSettings()
        try phase("choosing Simplified Chinese")
        let chinese = revealInForm(option("Simplified Chinese"))
        if !chinese.isSelected {
            chinese.tap()
        }
        try require(waitUntil(timeout) { chinese.isSelected }, "Simplified Chinese could not be chosen")
        try phase("filling the model form")
        revealInForm(element(AccessibilityID.primaryModelRow)).tap()
        waitFor(button(AccessibilityID.saveButton))
        revealInForm(app.buttons.matching(NSPredicate(format: "label == 'Custom'")).firstMatch).tap()
        typeIntoForm(AccessibilityID.modelAddressField, environment["NEWSPAW_LIVE_MODEL_URL"] ?? "")
        typeIntoForm(AccessibilityID.modelNameField, environment["NEWSPAW_LIVE_MODEL_NAME"] ?? "")
        try phase("typing the key")
        // Typed into the secure field; read from the environment here and
        // nowhere kept.
        typeIntoForm(AccessibilityID.keyField, environment["NEWSPAW_LIVE_MODEL_KEY"] ?? "", secure: true)
        try phase("running Test")
        let test = revealInForm(button(AccessibilityID.testButton))
        try require(waitUntil(timeout) { test.isEnabled }, "Test stayed disabled")
        test.tap()
        let line = revealInForm(element(AccessibilityID.testLine))
        let settled = waitUntil(Self.networkWait) { line.exists && !["Testing…", "Not tested"].contains(line.label) }
        try require(settled, "Test gave no result in \(Int(Self.networkWait)) s")
        // The line is the app's own wording ("Passed", "Key rejected", …).
        try require(line.label == "Passed", "Test line reads \"\(line.label)\"")
        try phase("saving the model")
        tapSave()
        waitForAbsence(button(AccessibilityID.saveButton))
        let row = waitFor(element(AccessibilityID.primaryModelRow))
        try require(row.label.contains("Passed"), "the saved model's row does not read Passed")
        return "Test passed; the model is saved; reading language Simplified Chinese"
    }

    // MARK: - Step 2: the sources

    /// Two categories; the feeds, the GitHub repository's releases and the
    /// web page added by address through Add source, each under its own
    /// name.
    private func stepSources() throws -> String {
        try phase("creating the categories")
        createCategory(Self.newsCategory)
        createCategory(Self.pageCategory)
        var problems: [String] = []
        for source in Self.sources {
            try phase("adding \(source.name)")
            if let problem = add(source) {
                problems.append("\(source.name): \(problem)")
                // Back to the shell for the next source.
                if button(AccessibilityID.cancelButton).exists {
                    button(AccessibilityID.cancelButton).tap()
                }
            } else {
                added.insert(source.name)
            }
        }
        try require(problems.isEmpty, "not added: " + problems.joined(separator: "; "))
        return "\(added.count) sources added"
    }

    /// Adds `source`; returns what went wrong, or `nil`.
    private func add(_ source: Source) -> String? {
        openAddSource()
        detect(source.address)
        let confirm = element(AccessibilityID.confirmAddress)
        let noFeed = element(AccessibilityID.noFeedMessage)
        let failure = element(AccessibilityID.failureMessage)
        let duplicate = element(AccessibilityID.duplicateMessage)
        guard waitUntil(Self.networkWait, { confirm.exists || noFeed.exists || failure.exists || duplicate.exists }) else {
            return "detection gave no outcome in \(Int(Self.networkWait)) s"
        }
        if failure.exists {
            return "Add source says \"\(failure.label)\""
        }
        if duplicate.exists {
            return "Add source says it is already added"
        }
        switch source.kind {
        case .page:
            if noFeed.exists {
                waitFor(button(AccessibilityID.saveAsWebPageButton)).tap()
            } else {
                scrollTo(button(AccessibilityID.pageItselfChoice)).tap()
            }
        case .feed, .github:
            guard confirm.exists else { return "no feed was found at the address" }
        }
        let name = app.textFields[AccessibilityID.nameField]
        guard name.waitForExistence(timeout: timeout) else { return "the confirm step has no name field" }
        rename(name, to: source.name)
        chooseCategoryAndSave(source.category)
        expand(source.category)
        guard scrollTo(sourceRow(source.name)).exists else { return "its row is not in its category" }
        return nil
    }

    /// Replaces the text of the confirm step's name field.
    private func rename(_ field: XCUIElement, to name: String) {
        scrollTo(field)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let current = field.value as? String ?? ""
        let existing = current == (field.placeholderValue ?? "") ? 0 : current.count
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing) + name + "\n")
    }

    // MARK: - Step 3: refresh, rows and titles

    /// A refresh run from the news category's menu; Today's line reads
    /// "Updated" and names no failed source; every feed's list has rows.
    private func stepRefresh() throws -> String {
        try phase("refreshing \(Self.newsCategory)")
        openCategoryList(Self.newsCategory)
        waitFor(button(AccessibilityID.listMenu)).tap()
        waitFor(app.buttons.matching(NSPredicate(format: "label IN %@", ["Refresh", "刷新"])).firstMatch).tap()
        refreshRan = true
        showToday()
        let status = element(AccessibilityID.todayStatus)
        let updated = waitUntil(Self.networkWait) { status.exists && status.label.hasPrefix("Updated ") }
        try require(updated, "Today's status line did not read Updated within \(Int(Self.networkWait)) s")
        let failures = button(AccessibilityID.failedSourcesButton)
        try require(!failures.exists, "Today says \"\(failures.label)\"")
        var counts: [String] = []
        for source in Self.sources where source.kind != .page && added.contains(source.name) {
            try phase("opening \(source.name)'s list")
            openSourceList(source.name, in: source.category)
            let rows = waitUntil(60) { !self.articleRowsShown().isEmpty }
            try require(rows, "\(source.name)'s list shows no rows")
            counts.append("\(source.name) \(articleRowsShown().count)")
        }
        return "refreshed; rows on screen: " + counts.joined(separator: ", ")
    }

    /// In each list whose titles are foreign, a row shows a title that
    /// differs from its original (the row is named by its original).
    private func stepTitles() throws -> String {
        var found: [String] = []
        for source in Self.sources where source.kind != .page && source.translated && added.contains(source.name) {
            try phase("reading \(source.name)'s titles")
            openSourceList(source.name, in: source.category)
            var shown = (translated: 0, rows: 0)
            let translated = waitUntil(Self.networkWait) {
                let rows = self.articleRowsShown()
                shown = (rows.filter(self.showsTranslation).count, rows.count)
                return shown.translated > 0
            }
            try require(translated, "\(source.name): no title on screen differs from its original within \(Int(Self.networkWait)) s")
            found.append("\(source.name) \(shown.translated) of \(shown.rows)")
        }
        return "translated titles on screen: " + found.joined(separator: ", ")
    }

    /// Whether the row shows something other than its original title.
    private func showsTranslation(_ row: XCUIElement) -> Bool {
        let original = String(row.identifier.dropFirst(AccessibilityID.articleRowPrefix.count))
        return !original.isEmpty && !row.label.contains(original)
    }

    // MARK: - Step 4: full text and body

    /// An article of the excerpt-only feed shows "Full text from the
    /// original page" and body blocks; up to three articles are tried, as
    /// one may be a page with no readable article.
    private func stepFullText() throws -> String {
        returnToShell()
        try phase("opening \(Self.excerptSource)'s list")
        openSourceList(Self.excerptSource, in: Self.newsCategory)
        chooseFilter("All")
        let candidates = articleRowsShown().prefix(3).map(\.identifier)
        try require(!candidates.isEmpty, "\(Self.excerptSource)'s list shows no rows")
        var tried: [String] = []
        for (index, identifier) in candidates.enumerated() {
            try phase("opening article \(index + 1)")
            if index > 0 {
                backToList()
            }
            let row = element(identifier)
            guard row.waitForExistence(timeout: timeout) else { continue }
            row.tap()
            try require(readingTitle.waitForExistence(timeout: 30), "the reading screen did not open")
            let fullText = fullTextNoteElement
            let excerpt = element(AccessibilityID.readingExcerptNote)
            let failed = element(AccessibilityID.readingBodyFailed)
            let settled = waitUntil(Self.networkWait) { fullText.exists || excerpt.exists || failed.exists }
            if settled, fullText.exists {
                try require(block(at: 0).waitForExistence(timeout: timeout), "the full text has no body block")
                return "article \(index + 1): full text from its page, body blocks shown"
                    + (tried.isEmpty ? "" : " (before: " + tried.joined(separator: "; ") + ")")
            }
            tried.append(settled ? (excerpt.exists ? "article \(index + 1) kept its excerpt" : "article \(index + 1)'s body failed")
                : "article \(index + 1) settled on nothing")
        }
        throw StepFailure(reason: "no full text: " + tried.joined(separator: "; "))
    }

    private var fullTextNoteElement: XCUIElement {
        element(AccessibilityID.readingFullTextNote)
    }

    /// The open article's body is translated: no progress line and no
    /// banner once done, and the first blocks in Translation differ from
    /// them in Original.
    private func stepBody() throws -> String {
        try phase("translating the body")
        if translateButton.exists {
            translateButton.tap()
        }
        let done = waitUntil(Self.networkWait) {
            self.modeMenu.exists && !self.progressLine.exists && self.block(at: 0).exists
        }
        if banner.exists {
            let sentence = banner.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " · ")
            throw StepFailure(reason: "the body shows its banner: \"\(sentence)\"")
        }
        try require(done, "the body translation did not finish within \(Int(Self.networkWait)) s")
        try phase("comparing Translation with Original")
        chooseMode("original")
        let original = firstBlocks()
        chooseMode("translation")
        var translation = ""
        let differs = waitUntil(timeout) {
            translation = self.firstBlocks()
            return !translation.isEmpty && translation != original
        }
        try require(differs, "the translated body reads the same as the original")
        return "body translated; Translation differs from Original"
    }

    /// The labels of the body's first three blocks.
    private func firstBlocks() -> String {
        (0..<3).map { block(at: $0) }.filter(\.exists).map(\.label).joined(separator: "\n")
    }

    // MARK: - Step 5: the web page

    /// The web-page source: Translate once; the line reads "Translated to
    /// Simplified Chinese" and Chinese text shows; a link followed shows the
    /// next page translated; Show Original restores it.
    private func stepPage() throws -> String {
        returnToShell()
        try phase("opening \(Self.pageSource)")
        expand(Self.pageCategory)
        scrollTo(sourceRow(Self.pageSource)).tap()
        waitForAbsence(element(AccessibilityID.slideOverPanel))
        let page = app.webViews.firstMatch
        let loaded = waitUntil(Self.networkWait) { page.exists && page.staticTexts.count > 0 }
        try require(!element(AccessibilityID.browserFailure).exists, "the browser shows its failure page")
        try require(loaded, "the page did not load within \(Int(Self.networkWait)) s")
        try phase("translating the page")
        waitFor(button(AccessibilityID.browserTranslateButton)).tap()
        try require(waitForTranslatedPage(), "the page was not shown translated within \(Int(Self.networkWait)) s")
        try phase("following a link")
        let before = barTexts()
        let link = page.links.firstMatch
        try require(link.waitForExistence(timeout: timeout), "the page has no link")
        link.tap()
        try require(waitUntil(Self.networkWait) { self.barTexts() != before }, "the link did not open another page")
        try require(waitForTranslatedPage(), "the next page was not shown translated within \(Int(Self.networkWait)) s")
        try phase("showing the original")
        waitFor(button(AccessibilityID.pageTranslationShowOriginal)).tap()
        let line = element(AccessibilityID.pageTranslationLine)
        let restored = waitUntil(30) { !line.exists && !self.pageShowsChinese() }
        try require(restored, "Show Original did not restore the page")
        leaveBrowser()
        return "translated with one tap; the followed page translated; the original shown again"
    }

    /// The line reads "Translated to Simplified Chinese" and the page shows
    /// Chinese text.
    private func waitForTranslatedPage() -> Bool {
        let line = element(AccessibilityID.pageTranslationLine)
        return waitUntil(Self.networkWait) {
            line.exists && line.label == "Translated to Simplified Chinese" && self.pageShowsChinese()
        }
    }

    private func pageShowsChinese() -> Bool {
        app.webViews.firstMatch.staticTexts.allElementsBoundByIndex.contains { Self.hasHan($0.label) }
    }

    static func hasHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    // MARK: - Step 6: the overview

    /// Today's card of the news category has its overview's text, and no
    /// problem line.
    private func stepOverview() throws -> String {
        returnToShell()
        try phase("showing Today")
        showToday()
        let card = element(AccessibilityID.overview("card", Self.newsCategory))
        let summary = element(AccessibilityID.overview("summary", Self.newsCategory))
        let issue = element(AccessibilityID.overview("issue", Self.newsCategory))
        let today = app.scrollViews.containing(.any, identifier: AccessibilityID.todayDate).firstMatch
        // Down to the card: Today lists the categories in order.
        var swipes = 0
        while !(card.waitForExistence(timeout: 2) && card.isHittable), swipes < 6, today.exists {
            today.swipeUp()
            swipes += 1
        }
        let written = waitUntil(Self.networkWait) { (summary.exists && !summary.label.isEmpty) || issue.exists }
        try require(!issue.exists, "the overview card says \"\(issue.label)\"")
        try require(written, "no overview was written within \(Int(Self.networkWait)) s")
        return "the overview card has text (\(summary.label.count) characters)"
    }

    // MARK: - Step 7: usage

    /// Settings › Usage lists the requests made: rows by purpose, and no
    /// failure to read.
    private func stepUsage() throws -> String {
        returnToShell()
        try phase("opening Usage")
        openSettings(row: AccessibilityID.usageRow)
        waitFor(element(AccessibilityID.usagePeriodPicker))
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'usage.total.'"))
        let listed = waitUntil(60) { rows.count > 0 }
        try require(!element(AccessibilityID.usageReadFailed).exists, "Usage could not be read")
        try require(listed, "Usage lists no requests")
        let purposes = Set(rows.allElementsBoundByIndex.compactMap { $0.identifier.split(separator: ".").last.map(String.init) })
        return "Usage lists requests: " + purposes.sorted().joined(separator: ", ")
    }

    // MARK: - Output

    private var deviceName: String {
        (ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? "device").replacingOccurrences(of: " ", with: "-")
    }

    private func saveScreenshot(_ step: String) {
        let url = directory.appendingPathComponent("\(deviceName)-\(step).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }

    private func appendLine(_ line: String) {
        let url = directory.appendingPathComponent("steps.txt")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: - Waiting

    /// Waits until `condition` holds, up to `seconds`; no assertion.
    private func waitUntil(_ seconds: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: seconds) == .completed
    }
}
