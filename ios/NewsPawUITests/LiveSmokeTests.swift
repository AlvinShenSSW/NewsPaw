import os
import XCTest

/// The live smoke run (#192): the M1 path of spec section 7 walked in the
/// simulator against real public feeds, real web pages and a real model
/// service, as far as a simulator can. Off by default: every test skips
/// unless the test runner's environment names an output directory
/// (`TEST_RUNNER_NEWSPAW_LIVE_DIR`) and, when the model step is among the
/// steps, the model service (`TEST_RUNNER_NEWSPAW_LIVE_MODEL_URL`,
/// `TEST_RUNNER_NEWSPAW_LIVE_MODEL_NAME`, `TEST_RUNNER_NEWSPAW_LIVE_MODEL_KEY_FILE`).
/// `TEST_RUNNER_NEWSPAW_LIVE_STEPS` limits the steps: a comma-separated list
/// of step numbers (1–7), `feeds` (steps 2 and 3) or `all` (the default); a
/// list without step 1 needs only the directory. Enabled, it makes real
/// requests and costs model tokens.
///
/// One output directory per run of one device and one service: its
/// `steps.txt`, screenshots and state file are written without regard to
/// another run in the same directory. The run uses the default attachment
/// lifetime: never "keep attachments always" in a test plan or Xcode, nor
/// `-collect-test-diagnostics always`, which would keep what XCTest
/// recorded of the typed key (below).
///
/// The app keeps its UI-test library directory (a fresh, empty library and
/// keychain service of this test's own) and its animations off, but uses
/// the real feed transport, the real model HTTP, the real clock and the
/// real web pages (`UITestLaunchKey.liveServices`). The test itself makes
/// no request. The key reaches the app only through the model form, typed
/// into its secure field; it is never printed, attached, written or put
/// into a failure message. Measured with a fake key (#192):
/// - xcodebuild writes the test runner's environment into the result
///   bundle's log, so the key is not in the environment: the environment
///   names a file that holds it (`…_KEY_FILE`), read when it is typed;
/// - XCTest's "Type '…'" line shows the first 18 characters typed, also
///   into a secure field, so the key is typed after 40 deletes, which an
///   empty field ignores and the line shows as nothing;
/// - XCTest keeps each typing's "Synthesized Event" (the text whole) and a
///   screen recording with a failed test only (the default lifetime), so
///   the model's test never fails as an XCTest test: its issues are
///   counted, not recorded, on whatever thread they come, and
///   `test1ModelResult` fails in its place when step 1 failed.
///
/// Each step is a test of its own, run in name order on one library (a
/// state file in the output directory carries the library's name and the
/// outcomes from test to test, since the runner starts again after a
/// failed test). Each step writes one line to `<NEWSPAW_LIVE_DIR>/steps.txt`
/// — step, `pass`, `fail` or `not run`, seconds, a neutral reason — and a
/// screenshot named after the device and the step. A failed step stops
/// only the steps that need it: a failed Test of the model stops the
/// translation steps, not the feed steps. Assertions are about shape, not
/// content: rows exist, a translated text differs from its original, the
/// reading screen has text blocks, the page line reads "Translated…", the
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
        /// Whether step 3 expects its titles to show a translation.
        let translated: Bool
    }

    static let newsCategory = "Live News"
    static let pageCategory = "Live Pages"
    static let sources = [
        Source(name: "BBC World", address: "https://feeds.bbci.co.uk/news/world/rss.xml", category: newsCategory, kind: .feed, translated: true),
        Source(name: "BBC Chinese", address: "https://feeds.bbci.co.uk/zhongwen/simp/rss.xml", category: newsCategory, kind: .feed, translated: false),
        Source(name: "ITmedia", address: "https://rss.itmedia.co.jp/rss/2.0/itmedia_all.xml", category: newsCategory, kind: .feed, translated: true),
        // Its titles are mostly snapshot names, which a translation keeps.
        Source(name: "Swift Releases", address: "https://github.com/swiftlang/swift", category: newsCategory, kind: .github, translated: false),
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

    /// What the run's tests share. The runner starts again after a failed
    /// test, so it lives in a file of the output directory, one per device;
    /// the first test of the class starts it afresh.
    struct RunState: Codable {
        /// The UI-test library directory every test of the run launches on.
        var library: String
        var outcomes: [String: String] = [:]
        /// The sources added in step 2, by name.
        var added: [String] = []
        /// Whether step 3's refresh run was started.
        var refreshRan = false
    }

    private var directory: URL!
    private var selected: Set<Int> = []
    private var state = RunState(library: "")
    /// The step running now, and this test's steps not written yet: a
    /// test stopped by a failed interaction writes them in `tearDown`.
    private var current: Step?
    private var queued: [Step] = []
    private var launched = false
    /// When the running step started, for the line `tearDown` writes.
    private var stepStart = Date()
    /// What the step was doing.
    private var doing = ""

    /// What `record(_:)` needs, behind a lock: it may be called off the
    /// main thread, where the main actor's state must not be touched.
    struct IssueGate {
        /// Whether a step runs, and the failures recorded while it ran.
        var stepIsRunning = false
        var failures = 0
        /// Whether this test's issues are only counted (`test1Model`).
        var keepsIssuesOut = false
    }

    private nonisolated let gate = OSAllocatedUnfairLock(initialState: IssueGate())

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
            for name in ["NEWSPAW_LIVE_MODEL_URL", "NEWSPAW_LIVE_MODEL_NAME", "NEWSPAW_LIVE_MODEL_KEY_FILE"]
            where (environment[name] ?? "").isEmpty {
                throw XCTSkip("set TEST_RUNNER_\(name) for the model step, or limit the steps with TEST_RUNNER_NEWSPAW_LIVE_STEPS=feeds")
            }
        }
        selected = steps
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A failed check is a failed step; the step ends at its next
        // checkpoint. (A failed tap still ends the test: `tearDown` writes
        // its step.)
        continueAfterFailure = true
    }

    override func tearDown() async throws {
        if let current {
            writeResult(current, .fail, unresponsiveReason, seconds: Date().timeIntervalSince(stepStart))
            saveScreenshot(current.rawValue)
            for step in queued {
                writeResult(step, .notRun, "\(current.rawValue) failed", seconds: 0)
            }
            self.current = nil
            queued = []
        }
        try await super.tearDown()
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

    // MARK: - The run: one test per step of spec section 7, in name order

    func test1Model() {
        begin([.model], fresh: true)
        // The key is typed in this test: it must not fail as an XCTest
        // test, or XCTest keeps what it typed (see the class comment).
        gate.withLock { $0.keepsIssuesOut = true }
        run(.model, failsTheTest: false) { try stepModel() }
    }

    /// Fails when step 1 failed, in place of `test1Model`.
    func test1ModelResult() {
        begin([])
        if outcome(.model) == .fail {
            XCTFail("live step \(Step.model.rawValue) failed (see steps.txt)")
        }
    }

    func test2Sources() {
        begin([.sources])
        run(.sources) { try stepSources() }
    }

    func test3Refresh() {
        begin([.refresh, .titles])
        run(.refresh, needs: refreshNeeds) { try stepRefresh() }
        run(.titles, needs: modelNeeds ?? (outcome(.refresh) == .pass ? nil : "the refresh step did not pass")) { try stepTitles() }
    }

    func test4FullText() {
        begin([.fullText, .body])
        run(.fullText, needs: state.added.contains(Self.excerptSource) ? nil : "\(Self.excerptSource) was not added") { try stepFullText() }
        run(.body, needs: modelNeeds ?? (outcome(.fullText) == .pass ? nil : "the full-text step did not pass")) { try stepBody() }
    }

    func test5Page() {
        begin([.page])
        run(.page, needs: modelNeeds ?? (state.added.contains(Self.pageSource) ? nil : "\(Self.pageSource) was not added")) { try stepPage() }
    }

    func test6Overview() {
        begin([.overview])
        run(.overview, needs: modelNeeds ?? (state.refreshRan ? nil : "no refresh run")) { try stepOverview() }
    }

    func test7Usage() {
        begin([.usage])
        run(.usage, needs: modelNeeds) { try stepUsage() }
    }

    private func outcome(_ step: Step) -> Outcome? {
        state.outcomes[step.rawValue].flatMap(Outcome.init(rawValue:))
    }

    /// Why the model's steps cannot run, or `nil`.
    private var modelNeeds: String? {
        switch outcome(.model) {
        case .pass: nil
        case .fail: "the model step failed"
        default: "the model step did not run"
        }
    }

    private var refreshNeeds: String? {
        Self.sources.contains { $0.kind != .page && state.added.contains($0.name) } ? nil : "no feed was added"
    }

    /// Starts a test of the run: a new run for the first test (a new
    /// library and a header line), else the run so far, read back.
    private func begin(_ steps: [Step], fresh: Bool = false) {
        if !fresh, let data = try? Data(contentsOf: stateURL), let saved = try? JSONDecoder().decode(RunState.self, from: data) {
            state = saved
        } else {
            state = RunState(library: libraryName)
            appendLine("# \(ISO8601DateFormatter().string(from: Date())) \(deviceName) steps=\(selected.sorted().map(String.init).joined(separator: ","))")
            saveState()
        }
        libraryName = state.library
        queued = steps
    }

    /// Runs `step` when it is selected and nothing it needs is missing,
    /// and writes its line and its screenshot. The app is launched on the
    /// run's library for the first step of the test that runs.
    private func run(_ step: Step, needs missing: String? = nil, failsTheTest: Bool = true, _ body: () throws -> String) {
        queued.removeAll { $0 == step }
        guard selected.contains(step.number) else {
            writeResult(step, .notRun, "not selected", seconds: 0)
            return
        }
        if let missing {
            writeResult(step, .notRun, missing, seconds: 0)
            return
        }
        let start = Date()
        stepStart = start
        current = step
        doing = "launching"
        gate.withLock { gate in
            gate.failures = 0
            gate.stepIsRunning = true
        }
        if !launched {
            launchLive()
            launched = true
        }
        var result = Outcome.pass
        var reason: String
        do {
            reason = try body()
            try checkIssues()
        } catch let failure as StepFailure {
            result = .fail
            reason = failure.reason
        } catch {
            result = .fail
            reason = "\(doing): an unexpected error"
        }
        gate.withLock { $0.stepIsRunning = false }
        current = nil
        saveScreenshot(step.rawValue)
        writeResult(step, result, reason, seconds: Date().timeIntervalSince(start))
        if result == .fail, failsTheTest {
            XCTFail("live step \(step.rawValue) failed (see steps.txt)")
        }
    }

    private func writeResult(_ step: Step, _ outcome: Outcome, _ reason: String, seconds: TimeInterval) {
        state.outcomes[step.rawValue] = outcome.rawValue
        saveState()
        appendLine("\(step.rawValue)\t\(outcome.rawValue)\t\(String(format: "%.0f", seconds))s\t\(reason)")
    }

    /// Counts the failures recorded while a step runs; they stay issues of
    /// the test, except in `test1Model`. A system issue (the runner's
    /// priority-inversion warning at launch) is not a failure of the step.
    /// Safe on any thread: it touches only the locked gate.
    nonisolated override func record(_ issue: XCTIssue) {
        let fails = [.assertionFailure, .thrownError, .uncaughtException].contains(issue.type)
        let keptOut = gate.withLock { gate in
            if gate.stepIsRunning, fails {
                gate.failures += 1
            }
            return gate.keepsIssuesOut
        }
        if !keptOut {
            super.record(issue)
        }
    }

    /// Why a step stopped on a check of the screen. In `test1Model` the
    /// issues are kept out of the test log, so the reason does not point
    /// to it.
    private var unresponsiveReason: String {
        let keptOut = gate.withLock { $0.keepsIssuesOut }
        return "\(doing): the screen did not respond as expected" + (keptOut ? "" : " (see the test log)")
    }

    /// Names what the step does next, after checking that nothing failed
    /// so far.
    private func phase(_ text: String) throws {
        try checkIssues()
        doing = text
    }

    private func checkIssues() throws {
        if gate.withLock({ $0.failures }) > 0 {
            throw StepFailure(reason: unresponsiveReason)
        }
    }

    /// The reason is read only when the condition fails: it may name an
    /// element that is there only then.
    private func require(_ condition: Bool, _ reason: @autoclosure () -> String) throws {
        try checkIssues()
        guard condition else { throw StepFailure(reason: reason()) }
    }

    /// On the tab structure, back out of a pushed reading screen or
    /// browser until the tab bar shows again. Nothing on the panes.
    private func returnToShell() {
        guard usesTabs else { return }
        var backs = 0
        while !app.tabBars.firstMatch.waitForExistence(timeout: 2), backs < 3, app.buttons["BackButton"].exists {
            goBack()
            backs += 1
        }
    }

    /// Launches the app on the run's library with the real services.
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
        try typeKey(fromFile: environment["NEWSPAW_LIVE_MODEL_KEY_FILE"] ?? "")
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

    /// Types the key held in the file at `path` into the form's secure
    /// field, after 40 deletes, so that XCTest's "Type '…'" line, which
    /// shows the first 18 characters, shows none of it. The key is read
    /// here and kept nowhere.
    private func typeKey(fromFile path: String) throws {
        let text = (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try require(!text.isEmpty, "the key file could not be read or is empty")
        try require(!text.contains(where: \.isNewline), "the key file holds more than one line")
        let field = app.secureTextFields[AccessibilityID.keyField]
        revealInForm(field)
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        var taps = 0
        repeat {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
            taps += 1
        } while XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: focused, object: field)], timeout: 3) != .completed && taps < 3
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40) + text + "\n")
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
                state.added.append(source.name)
            }
        }
        try require(problems.isEmpty, "not added: " + problems.joined(separator: "; "))
        return "\(state.added.count) sources added"
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
        // Below the fold under a GitHub repository's rows on the iPad: rows
        // off screen are not in the hierarchy.
        scrollTo(button(AccessibilityID.categoryChoiceRow))
        chooseCategoryAndSave(source.category)
        expand(source.category)
        guard scrollTo(sourceRow(source.name)).exists else { return "its row is not in its category" }
        return nil
    }

    /// Replaces the text of the confirm step's name field.
    private func rename(_ field: XCUIElement, to name: String) {
        scrollTo(field)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let text = field.value as? String ?? ""
        let existing = text == (field.placeholderValue ?? "") ? 0 : text.count
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing) + name + "\n")
    }

    // MARK: - Step 3: refresh, rows and titles

    /// A refresh of the whole library by a pull on Today: only a library
    /// run records the time Today's line reads, so its "Updated just now"
    /// after the pull, where it did not read so before, is this step's
    /// run. Then the line names no failed source, and every feed's list
    /// has rows.
    private func stepRefresh() throws -> String {
        returnToShell()
        try phase("showing Today")
        showToday()
        let status = element(AccessibilityID.todayStatus)
        let justNow = "Updated just now"
        // An earlier library run (the launch's entry refresh) may still be
        // running, and once it ends it leaves "just now" until the first
        // minute boundary at least 60 s later (the line's timeline ticks
        // every minute): up to about 120 s. Wait for each in turn.
        let ended = waitUntil(Self.networkWait) { status.exists && status.label != "Updating…" }
        try require(ended, "Today's earlier refresh did not end within \(Int(Self.networkWait)) s")
        let clear = waitUntil(125) { status.exists && status.label != justNow && status.label != "Updating…" }
        try require(clear, "Today's status line still read \"\(justNow)\" 125 s after the earlier refresh")
        try phase("pulling Today to refresh")
        var pulls = 0
        var refreshed = false
        while !refreshed, pulls < 2 {
            pullToday()
            pulls += 1
            refreshed = waitUntil(Self.networkWait) { status.exists && status.label == justNow }
        }
        state.refreshRan = true
        saveState()
        try require(refreshed, "Today's status line did not read \"\(justNow)\" within \(Int(Self.networkWait)) s of a pull")
        let failures = button(AccessibilityID.failedSourcesButton)
        try require(!failures.exists, "Today says \"\(failures.label)\"")
        var counts: [String] = []
        for source in Self.sources where source.kind != .page && state.added.contains(source.name) {
            try phase("opening \(source.name)'s list")
            openSourceList(source.name, in: source.category)
            let rows = waitUntil(60) { !self.articleRowsShown().isEmpty }
            try require(rows, "\(source.name)'s list shows no rows")
            counts.append("\(source.name) \(articleRowsShown().count)")
        }
        return "refreshed the library (\(pulls) pull\(pulls == 1 ? "" : "s")); rows on screen: " + counts.joined(separator: ", ")
    }

    /// Pulls Today down far enough to refresh, as `RefreshTests` does; the
    /// harness waits while the refresh indicator runs.
    private func pullToday() {
        let anchor = [element(AccessibilityID.todayStatus), element(AccessibilityID.todayDate)].first(where: \.exists) ?? app.scrollViews.firstMatch
        let start = anchor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let distance = min(600, window.maxY - anchor.frame.midY - 20)
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)), withVelocity: .slow, thenHoldForDuration: 1)
    }

    /// In each list whose titles are foreign, a row shows a title that
    /// differs from its original (the row is named by its original).
    private func stepTitles() throws -> String {
        var found: [String] = []
        for source in Self.sources where source.kind != .page && source.translated && state.added.contains(source.name) {
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
        // The app was launched again for this test: rows come with the list.
        _ = waitUntil(60) { !self.articleRowsShown().isEmpty }
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
                try require(waitUntil(timeout) { !self.textBlocks().isEmpty }, "the full text has no text block")
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
        // Done, or stopped with the banner of a failure.
        let done = waitUntil(Self.networkWait) {
            self.banner.exists || (self.modeMenu.exists && !self.progressLine.exists && !self.textBlocks().isEmpty)
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

    /// The body's text blocks on screen, top to bottom: paragraphs,
    /// headings and code carry `reading.block.<index>`; an image (a lead
    /// picture often comes first) carries `reading.image…` instead.
    private func textBlocks() -> [XCUIElement] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.readingBlockPrefix))
            .allElementsBoundByIndex
            .filter { $0.exists && !$0.frame.isEmpty }
            .sorted { $0.frame.minY < $1.frame.minY }
    }

    /// The labels of the body's first three text blocks.
    private func firstBlocks() -> String {
        textBlocks().prefix(3).map(\.label).joined(separator: "\n")
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

    private var stateURL: URL {
        directory.appendingPathComponent(".live-state-\(deviceName).json")
    }

    private func saveState() {
        try? JSONEncoder().encode(state).write(to: stateURL)
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
