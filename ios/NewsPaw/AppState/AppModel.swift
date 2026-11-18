import Foundation
import NewsPawKit
import SwiftUI
import UIKit
import WebKit

/// Why the library could not be opened, as the failure screen tells it.
enum LibraryFailure: Equatable {
    case newerSchema
    case damaged
    /// Anything else, with the underlying description shown as technical
    /// detail (SQLite's own English wording, not translated).
    case other(detail: String)

    init(_ error: any Error) {
        switch error {
        case LibraryError.newerSchema: self = .newerSchema
        case LibraryError.damaged: self = .damaged
        case LibraryError.storage(let description): self = .other(detail: description)
        default: self = .other(detail: String(describing: error))
        }
    }
}

/// One sentence the adult partition has to say (RD18 decision 11), shown
/// as an alert at the root with OK.
enum AdultNotice: Equatable {
    /// Unlocking did not pass.
    case stillLocked
    /// Turning on did not pass, or the library's file could not be made.
    case notTurnedOn
    /// Opening Settings › Adult Partition did not pass.
    case settingsNeedAuthentication
    /// The device has no passcode.
    case passcodeNeeded
    /// The authentication passed and the adult library could not be
    /// opened. Only the reason's sentence is shown, never the error's text.
    case couldNotOpen(LibraryFailure)
    /// Deleting the partition's data failed; the partition is still on.
    case couldNotDelete
}

/// The questions of turning the partition off (RD18 decision 9).
enum TurnOffQuestion {
    /// Keep Data Hidden, Delete Data or Cancel.
    case keepOrDelete
    /// Delete, once more, or Cancel.
    case confirmDelete
}

/// The app's startup state, the workspace on screen and the adult
/// partition's gate (RD18): the normal library's workspace, kept for the
/// life of the app, and the adult library's, kept only while unlocked. It
/// follows the scene through UIKit's notifications for the lock timing and
/// the cover (decisions 8 and 12).
@MainActor @Observable
final class AppModel {
    enum Status {
        case loading
        /// The normal library is open and `shown` is set.
        case ready
        case failed(LibraryFailure)
    }

    private(set) var status = Status.loading
    /// The normal library's workspace; set before `status` is ready.
    private(set) var normal: Workspace?
    /// The adult library's workspace: only while the partition is
    /// unlocked. Nothing else of the interface holds the adult library.
    private(set) var adult: Workspace?
    /// The gate's state, as the views read it. Unavailable until the
    /// library is open, and for good when the feature switch is off.
    private(set) var gateState = AdultGate.State.unavailable
    /// The stored lock timing.
    private(set) var lockTiming = LockTiming.immediately
    /// Whether the system's authentication is being asked for: the
    /// partition switch and the Settings switch wait for its answer.
    private(set) var isAuthenticating = false
    /// The sentence to show at the root; it outlives a swap of workspaces.
    var notice: AdultNotice?
    /// The question of turning off being asked at the root.
    var turnOffQuestion: TurnOffQuestion?

    /// The app's one store; it gives out one library per partition.
    @ObservationIgnored private var store: LibraryStore?
    @ObservationIgnored private var gate: AdultGate?
    @ObservationIgnored private var parts: WorkspaceParts?
    /// Makes the adult workspace's browser set-up: a new non-persistent
    /// website data store for each unlock (decision 13).
    @ObservationIgnored private var makeAdultBrowser: (@MainActor () -> BrowserSetup)?
    /// The app's clock.
    @ObservationIgnored private var now: @Sendable () -> Date = { Date() }
    @ObservationIgnored private let cover = CoverWindow()
    /// The adult workspace was dropped while the cover was shown: the
    /// cover stays until that swap is on screen (decision 12).
    @ObservationIgnored private var swapIsUnderCover = false
    /// The workspace whose shell is in the view hierarchy, as the root
    /// view reports it.
    @ObservationIgnored private var appearedShell: Workspace.ID?
    @ObservationIgnored private var coverRemoval: Task<Void, Never>?
    @ObservationIgnored private var sceneIsActive = false
    /// The scene's absence, as the lock rule counts it.
    @ObservationIgnored private var absence = Absence()
    /// Whether the scene has been in the background since it was last
    /// active: the next activation is an entry for the refresh rule.
    @ObservationIgnored private var wasInBackground = false
    /// The unlock that is running, so that the background can discard it.
    @ObservationIgnored private var unlockAttempt: UnlockAttempt?
    @ObservationIgnored private var sceneObservers: [any NSObjectProtocol] = []

    #if DEBUG
    /// Whether the UI tests' report element is shown: only under a UI-test
    /// library directory.
    private(set) var showsDebugReport = false
    /// The slow-save option, which the adult workspace's first category
    /// save takes too, so that a save can be overrun by a lock.
    @ObservationIgnored private var slowNextSave: Duration?
    /// The article page size of the UI tests, which every workspace's
    /// reading model takes.
    @ObservationIgnored private var articlePageSize: Int?
    @ObservationIgnored private var adultWasShown = false
    @ObservationIgnored private weak var lastAdultWorkspace: Workspace?
    @ObservationIgnored private weak var lastAdultBrowser: BrowserModel?
    #endif

    /// One unlock from the choice to its end.
    private final class UnlockAttempt {
        /// Whether the scene entered the background at any moment since
        /// the choice was made (decision 5).
        var enteredBackground = false
    }

    /// The workspace on screen: the adult one while unlocked, else the
    /// normal one.
    var shown: Workspace? {
        adult ?? normal
    }

    /// Whether the partition switch is offered: only while the partition is
    /// turned on (ux section 2).
    var showsPartitionSwitch: Bool {
        gateState == .locked || gateState == .unlocked
    }

    /// Opens the normal library, creating it on first launch. A failure is
    /// shown and left as it is: the file is never deleted, reset or replaced.
    /// The adult library is not opened here: a launch starts in the normal
    /// partition.
    func start() async {
        guard case .loading = status else { return }
        observeScene()
        // The one transport the app makes requests through. Under a UI-test
        // library directory it is the fixture transport, never the real one.
        // The one clock of the library and of Today's status line.
        #if DEBUG
        let options = DebugLaunchOptions(environment: ProcessInfo.processInfo.environment)
        let directory = options.libraryDirectory ?? LibraryStore.defaultDirectory()
        let transport: any Transport = options.libraryDirectory != nil ? FixtureTransport() : URLSessionTransport()
        let candidateLimit = options.libraryDirectory != nil ? FixtureTransport.candidateLimit : .seconds(20)
        // Under a UI-test library directory: the cache inside it, and a
        // preferences suite named after it, never the standard one.
        let cacheRoot = options.libraryDirectory.map { $0.appending(path: "Images", directoryHint: .isDirectory) }
            ?? LibraryStore.defaultCacheRoot()
        let defaults = options.libraryDirectory.flatMap { UserDefaults(suiteName: $0.lastPathComponent) } ?? .standard
        // The clock offset, like the fixture transport, applies only under a
        // UI-test library directory.
        let offset = options.libraryDirectory != nil ? options.clockOffset : 0
        let now: @Sendable () -> Date = { Date().addingTimeInterval(offset) }
        // Under a UI-test library directory: keys under a keychain service
        // named after the directory, never the owner's, and the model
        // fixture, which reaches no real service.
        let keyStore = options.libraryDirectory.map { KeychainKeyStore(partition: .normal, uiTestSuffix: $0.lastPathComponent) }
            ?? KeychainKeyStore(partition: .normal)
        let modelHTTP: any ModelHTTP = options.libraryDirectory != nil ? FixtureModelHTTP() : URLSessionModelHTTP()
        // The adult partition: under a UI-test library directory the
        // stand-in authenticator, never LocalAuthentication, and keys under
        // a service named after the directory; the feature switch can be
        // turned off there, never on.
        let authenticator: any DeviceAuthenticator = options.libraryDirectory != nil
            ? FixtureAuthenticator(options.authenticationSteps) : SystemDeviceAuthenticator()
        let adultKeys = options.libraryDirectory.map { KeychainKeyStore(partition: .adult, uiTestSuffix: $0.lastPathComponent) }
            ?? KeychainKeyStore(partition: .adult)
        let adultIsEnabled = BuildFeatures.adultPartition && !(options.libraryDirectory != nil && options.adultFeatureOff)
        showsDebugReport = options.libraryDirectory != nil
        slowNextSave = options.slowNextSave
        #else
        let directory = LibraryStore.defaultDirectory()
        let transport: any Transport = URLSessionTransport()
        let candidateLimit = Duration.seconds(20)
        let cacheRoot = LibraryStore.defaultCacheRoot()
        let defaults = UserDefaults.standard
        let now: @Sendable () -> Date = { Date() }
        let keyStore = KeychainKeyStore(partition: .normal)
        let modelHTTP: any ModelHTTP = URLSessionModelHTTP()
        let authenticator: any DeviceAuthenticator = SystemDeviceAuthenticator()
        let adultKeys = KeychainKeyStore(partition: .adult)
        let adultIsEnabled = BuildFeatures.adultPartition
        #endif
        self.now = now
        do {
            let store = LibraryStore(directory: directory, cacheRoot: cacheRoot, now: now)
            self.store = store
            let library = try await store.openNormal()
            let preferences = Preferences(defaults)
            let models = LibraryModels(library: library, keys: keyStore, http: modelHTTP)
            let parts = WorkspaceParts(
                transport: transport, candidateLimit: candidateLimit, now: now,
                refreshSettings: RefreshSettings(preferences),
                readingSettings: ReadingSettings(preferences: preferences),
                models: models,
                translationSettings: TranslationSettings(preferences: preferences),
                // The models are the normal library's: its workspace's
                // translation resumes, whichever workspace's Settings saved.
                slotsChanged: { [weak self] in self?.normal?.translation?.slotsChanged() }
            )
            self.parts = parts
            // The embedded browser: the system's default website data store
            // for the normal library, and a non-persistent one, new for each
            // unlock and without Picture in Picture, for the adult library
            // (decision 13); under a UI-test library directory a
            // non-persistent one and the fixture pages for both.
            #if DEBUG
            let fixtures = options.libraryDirectory != nil
            let browser = if fixtures {
                BrowserSetup(
                    dataStore: .nonPersistent(), addressMap: BrowserFixtures.map,
                    schemeHandlers: [BrowserFixtures.scheme: BrowserFixtures()]
                )
            } else {
                BrowserSetup(dataStore: .default())
            }
            makeAdultBrowser = {
                if fixtures {
                    BrowserSetup(
                        dataStore: .nonPersistent(), addressMap: BrowserFixtures.map,
                        schemeHandlers: [BrowserFixtures.scheme: BrowserFixtures()], allowsPictureInPicture: false
                    )
                } else {
                    BrowserSetup(dataStore: .nonPersistent(), allowsPictureInPicture: false)
                }
            }
            #else
            let browser = BrowserSetup(dataStore: .default())
            makeAdultBrowser = { BrowserSetup(dataStore: .nonPersistent(), allowsPictureInPicture: false) }
            #endif
            let workspace = Workspace(library: library, parts: parts, browser: browser)
            #if DEBUG
            if options.libraryDirectory != nil {
                articlePageSize = options.articlePageSize
                workspace.translation?.body.holdsFirstPlanUntilBackground = options.holdsFirstBodyPlan
                if options.failsFirstBodyWrite {
                    workspace.translation?.body.failNextWrites(1)
                }
                workspace.translation?.body.holdsRetryWrite = options.holdsRetryWrite
                if options.changesSlotsAfterReader {
                    // The same call as a save in Settings.
                    workspace.translation?.body.changesSlotsAfterReaderTranslated = true
                    workspace.translation?.body.slotsChangedForUITests = { [weak self] in self?.parts?.slotsChanged() }
                }
            }
            if let size = articlePageSize {
                workspace.reading.pageSize = size
            }
            if let count = options.syntheticSources {
                try await library.insertSyntheticSourcesForUITests(count: count)
            }
            // The translator fixture's models and the daily limit (RD14).
            if options.libraryDirectory != nil {
                try await Self.setUpTranslationForUITests(options, models: models, library: library)
            }
            workspace.categories.failNextSave = options.failNextSave
            workspace.categories.slowNextSave = options.slowNextSave
            workspace.sources.failNextSave = options.failNextSourceSave
            #endif
            await workspace.load()
            // The gate: the only way to the adult library from here on.
            let gate = AdultGate(
                store: store, authenticator: authenticator, preferences: preferences, keys: adultKeys,
                isEnabled: adultIsEnabled
            )
            self.gate = gate
            gateState = await gate.state
            lockTiming = await gate.lockTiming
            normal = workspace
            status = .ready
            // The launch is the first entry (RD06 decision 3).
            Task { await workspace.refresh.entered() }
        } catch is CancellationError {
            return
        } catch {
            status = .failed(LibraryFailure(error))
        }
    }

    // MARK: - Switching (decision 5)

    /// "Adult" in the partition switch: authenticates, builds and loads the
    /// adult workspace and shows it at the root of the current tab. An
    /// authentication that does not pass leaves everything as it was, with
    /// its sentence. An unlock during which the scene entered the
    /// background is discarded.
    func chooseAdult() async {
        guard let gate, let parts, let makeAdultBrowser, let normal, adult == nil, gateState == .locked,
              !isAuthenticating
        else { return }
        // Chosen in the slide-over: it closes, so that what follows is
        // shown at the root.
        normal.navigation.closeSlideOver()
        isAuthenticating = true
        defer { isAuthenticating = false }
        let attempt = UnlockAttempt()
        unlockAttempt = attempt
        defer {
            if unlockAttempt === attempt {
                unlockAttempt = nil
            }
        }
        switch await gate.unlock(reason: String(localized: "Unlock the adult partition")) {
        case .unlocked(let library):
            let workspace = Workspace(library: library, parts: parts, browser: makeAdultBrowser())
            #if DEBUG
            workspace.categories.slowNextSave = slowNextSave
            if let size = articlePageSize {
                workspace.reading.pageSize = size
            }
            #endif
            await workspace.load()
            // From here to the end of the case nothing suspends before the
            // workspace is shown: the check and the showing are one step.
            if attempt.enteredBackground {
                workspace.stop()
                await gate.lock()
            } else {
                show(workspace)
            }
        case .refused(.notAuthenticated(let answer)):
            notice = Self.notice(for: answer, otherwise: .stillLocked)
        case .couldNotOpen(let error):
            notice = .couldNotOpen(LibraryFailure(error))
        case .refused(.busy), .refused(.notAllowed), .discarded:
            break
        }
        gateState = await gate.state
    }

    /// Shows the adult workspace in place of the normal one, at the root of
    /// the current tab, in one step and without animation.
    private func show(_ workspace: Workspace) {
        guard let normal else { return }
        // The unlock has ended: from here on only the timing rule locks.
        // Left in place until `chooseAdult()` returns, a background event
        // in its last hop would close the library under a workspace that
        // a timed setting keeps on screen.
        unlockAttempt = nil
        cover.prepare()
        withoutAnimation {
            workspace.navigation.showAtRoot(of: normal.navigation.currentTab, layout: normal.navigation.layout)
            adult = workspace
        }
        gateState = .unlocked
        // The normal workspace is not shown from here on: nothing of it
        // stays pushed or presented, and its pages end. Its models go on
        // refreshing (decision 13).
        normal.navigation.clear()
        applyTint()
        #if DEBUG
        adultWasShown = true
        lastAdultWorkspace = workspace
        lastAdultBrowser = workspace.browser
        #endif
        swapIsUnderCover = false
        if !sceneIsActive {
            // Shown while the system's prompt still keeps the scene
            // inactive: the cover's rule applies at this moment (decision
            // 12), and the absence the lock rule counts begins here, not at
            // the prompt.
            applyCoverRule()
            restartAbsence()
        }
        // The refresh-on-entry rule of the partition entered.
        Task { await workspace.refresh.entered() }
    }

    // MARK: - Locking (decision 4)

    /// Locks the adult partition: "Normal" in the switch, the lock button,
    /// or the timing rule. In one step, with no suspension and without
    /// animation, the normal workspace is shown at the root of the current
    /// tab and the adult workspace is told to stop and dropped; then the
    /// gate locks, which closes the adult library's connections. What a
    /// kept reference of the dropped workspace does after that fails and
    /// is shown nowhere.
    func lock() {
        guard let workspace = adult, let normal else { return }
        withoutAnimation {
            normal.navigation.showAtRoot(of: workspace.navigation.currentTab, layout: workspace.navigation.layout)
            adult = nil
        }
        workspace.stop()
        gateState = .locked
        applyTint()
        // A cover that is shown stays until the scene is active again and
        // the swap is on screen (decision 12).
        if cover.isShown {
            swapIsUnderCover = true
        }
        let gate = gate
        Task {
            await gate?.lock()
            if let gate {
                gateState = await gate.state
            }
            // Returning to the normal partition is an entry for its refresh.
            await normal.refresh.entered()
        }
    }

    /// Swaps what is shown without any animation: no dismissal of a sheet
    /// or a pushed screen of the workspace left is played.
    private func withoutAnimation(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        UIView.performWithoutAnimation {
            withTransaction(transaction, change)
        }
    }

    /// The window's tint follows the partition: alerts take their tint
    /// from the window, not from SwiftUI (decision 7).
    private func applyTint() {
        let partition = shown?.partition ?? .normal
        for scene in UIApplication.shared.connectedScenes {
            for window in (scene as? UIWindowScene)?.windows ?? [] {
                window.tintColor = Theme.uiAccent(of: partition)
            }
        }
    }

    // MARK: - Settings › Adult Partition (decisions 9 and 10)

    /// The Settings row was chosen. While the partition is on and locked
    /// this authenticates first; inside the adult partition, which an
    /// authentication unlocked already, and while the partition is off, it
    /// opens at once. It never unlocks the partition.
    func openAdultSettings() async {
        guard let gate, let workspace = shown, !isAuthenticating else { return }
        switch gateState {
        case .off, .unlocked:
            pushAdultSettings(on: workspace)
        case .locked:
            isAuthenticating = true
            defer { isAuthenticating = false }
            switch await gate.authenticateForSettings(reason: String(localized: "Open the adult partition's settings")) {
            case .passed:
                guard shown === workspace else { return }
                if !sceneIsActive {
                    restartAbsence()
                }
                pushAdultSettings(on: workspace)
            case .refused(.notAuthenticated(let answer)):
                notice = Self.notice(for: answer, otherwise: .settingsNeedAuthentication)
            case .refused(.busy), .refused(.notAllowed):
                break
            }
        case .unavailable:
            break
        }
    }

    private func pushAdultSettings(on workspace: Workspace) {
        if !workspace.navigation.settingsPath.contains(.adultPartition) {
            workspace.navigation.settingsPath.append(.adultPartition)
        }
    }

    /// The screen opened from the normal partition does not stay open
    /// across an absence: it is popped by the rule that locks the
    /// partition (decision 10). While the partition is off the screen
    /// protects nothing and stays.
    private func closeAdultSettingsOfNormal() {
        guard gateState == .locked, let normal else { return }
        normal.navigation.settingsPath.removeAll { $0 == .adultPartition }
    }

    /// The switch on the screen was turned on: authenticates, creates the
    /// adult library's file and stores "on". The app stays in the normal
    /// partition.
    func turnOnAdult() async {
        guard let gate, gateState == .off, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        switch await gate.turnOn(reason: String(localized: "Turn on the adult partition")) {
        case .turnedOn:
            // The screen now shows what an authentication protects.
            if !sceneIsActive {
                restartAbsence()
            }
        case .refused(.notAuthenticated(let answer)):
            notice = Self.notice(for: answer, otherwise: .notTurnedOn)
        case .couldNotCreate:
            notice = .notTurnedOn
        case .refused(.busy), .refused(.notAllowed):
            break
        }
        gateState = await gate.state
    }

    func setLockTiming(_ timing: LockTiming) {
        guard let gate, timing != lockTiming else { return }
        lockTiming = timing
        Task {
            await gate.setLockTiming(timing)
            lockTiming = await gate.lockTiming
        }
    }

    /// "Turn Off the Adult Partition": asks at the root.
    func askToTurnOff() {
        guard showsPartitionSwitch else { return }
        turnOffQuestion = .keepOrDelete
    }

    /// The last answer was given: the app locks, then the gate turns the
    /// partition off, keeping its data hidden or deleting it. A deletion
    /// that fails says so and leaves the partition on.
    func turnOff(deletingData: Bool) async {
        turnOffQuestion = nil
        guard let gate else { return }
        lock()
        switch await gate.turnOff(deletingData: deletingData) {
        case .turnedOff, .refused:
            break
        case .couldNotDelete:
            notice = .couldNotDelete
        }
        gateState = await gate.state
    }

    /// The sentence for an authentication that did not pass: the device
    /// without a passcode has its own, an interrupted one shows nothing.
    private static func notice(for answer: AuthenticationAnswer, otherwise: AdultNotice) -> AdultNotice? {
        switch answer {
        case .unavailable: .passcodeNeeded
        case .cancelled, .failed: otherwise
        case .interrupted, .passed: nil
        }
    }

    // MARK: - The scene (decisions 8 and 12)

    /// Follows the scene through UIKit's notifications, not through
    /// `scenePhase`: will-deactivate, did-enter-background and
    /// did-activate. (Will-enter-foreground changes nothing here.) They are
    /// delivered on the main thread and handled before they return, so
    /// that the cover is up before the system takes its picture.
    private func observeScene() {
        guard sceneObservers.isEmpty else { return }
        sceneIsActive = UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ handler: @escaping @MainActor (AppModel) -> Void) {
            sceneObservers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self {
                        handler(self)
                    }
                }
            })
        }
        observe(UIScene.willDeactivateNotification) { $0.sceneWillDeactivate() }
        observe(UIScene.didEnterBackgroundNotification) { $0.sceneDidEnterBackground() }
        observe(UIScene.didActivateNotification) { $0.sceneDidActivate() }
    }

    private func sceneWillDeactivate() {
        sceneIsActive = false
        // A page load under way remembers no failure (RD12).
        normal?.reading.appLeftFront()
        adult?.reading.appLeftFront()
        absence.willDeactivate(at: now())
        applyCoverRule()
    }

    private func sceneDidEnterBackground() {
        sceneIsActive = false
        wasInBackground = true
        // The bodies' translation stops (RD15 N06: leaving stops the work);
        // a mere deactivation (Control Centre, an alert, the app switcher
        // glimpsed) does not, so that no chunk is cancelled and sent again
        // for nothing. `cameToFront` resumes what is still shown.
        normal?.translation?.appEnteredBackground()
        adult?.translation?.appEnteredBackground()
        // An unlock that is still running is discarded (decision 5).
        if let unlockAttempt {
            unlockAttempt.enteredBackground = true
            let gate = gate
            Task { await gate?.lock() }
        }
        let locks = absence.didEnterBackground(at: now(), timing: lockTiming)
        applyCoverRule()
        if locks {
            lockByRule()
        }
    }

    private func sceneDidActivate() {
        sceneIsActive = true
        // The 5-second fallback is on: the app switcher and Control Centre
        // deliver no did-enter-background (measured, assumption A7).
        let locks = absence.didActivate(at: now(), timing: lockTiming, fallback: true)
        let locksAdult = locks && adult != nil
        if locks {
            lockByRule()
        }
        // The adult workspace is still shown: its pages may play again. One
        // that the lock dropped stays suspended for good.
        adult?.browser.allowMedia()
        if wasInBackground {
            wasInBackground = false
            // Every return from the background is an entry (RD06 decision
            // 3); a lock of the adult partition has made the normal
            // partition's entry itself.
            if !locksAdult, let refresh = shown?.refresh {
                Task { await refresh.entered() }
            }
            // The app came to the front: a translation pause of the normal
            // library may end (RD14 decision 6), whichever partition is
            // shown, since the normal workspace goes on working.
            normal?.translation?.cameToFront()
            // The bodies' work, stopped in the background, may start again
            // in each workspace (none has a translation in the adult one
            // today).
            adult?.translation?.cameToFront()
        }
        removeCover()
    }

    /// The root view's shell of a workspace is in the view hierarchy.
    func shellDidAppear(of workspace: Workspace) {
        appearedShell = workspace.id
    }

    /// Hides the cover now that the scene is active (decision 12). While
    /// the adult workspace is still the one shown, one main-loop turn
    /// later. After a lock under the cover, only once the swap is on
    /// screen: SwiftUI draws the other shell a frame or two after the
    /// change, and UIKit takes a sheet of the dropped shell away about a
    /// quarter of a second later (measured with animations on, RD18
    /// criterion 9), so the cover waits until the normal shell has
    /// appeared and the app's window presents nothing, and then three
    /// frames more.
    private func removeCover() {
        coverRemoval?.cancel()
        coverRemoval = nil
        guard cover.isShown else { return }
        guard swapIsUnderCover else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sceneIsActive, !self.swapIsUnderCover else { return }
                self.cover.hide()
            }
            return
        }
        coverRemoval = Task { [weak self] in
            let frame = Duration.milliseconds(17)
            let deadline = ContinuousClock.now + CoverWindow.longestWait
            var framesDrawn = 0
            while framesDrawn < 3 {
                guard let self, !Task.isCancelled, self.sceneIsActive else { return }
                if self.swapIsDrawn {
                    framesDrawn += 1
                } else if ContinuousClock.now >= deadline {
                    // Never seen. The cover does not stay for good, and
                    // what is still presented goes with it.
                    self.cover.dismissPresentationsOfTheApp()
                    break
                } else {
                    framesDrawn = 0
                }
                try? await Task.sleep(for: frame)
            }
            guard let self, !Task.isCancelled, self.sceneIsActive else { return }
            self.swapIsUnderCover = false
            self.cover.hide()
        }
    }

    /// Whether the shell of the workspace shown is in the view hierarchy
    /// and nothing of another shell is still presented.
    private var swapIsDrawn: Bool {
        adult == nil && appearedShell == normal?.id && !cover.appPresentsSomething
    }

    /// The lock rule answered "lock": the adult partition when it is
    /// shown, else Settings › Adult Partition of the normal partition. A
    /// question of that screen closes with it: it is not answered after
    /// an absence without a new authentication (decision 10).
    private func lockByRule() {
        turnOffQuestion = nil
        if adult != nil {
            lock()
        } else {
            closeAdultSettingsOfNormal()
        }
    }

    /// The cover's one rule (decision 12), and with it decision 13's for
    /// media: while the adult workspace is shown and the scene is not
    /// active, the cover is up and the adult pages' media are paused and
    /// suspended, so that a page cannot start them again beneath the cover
    /// (under "After 1 Minute" or "After 5 Minutes" the workspace stays
    /// alive while the app is away). It only ever shows the cover and
    /// suspends here; the cover is hidden by `removeCover()` alone, and the
    /// media are allowed again at did-activate.
    private func applyCoverRule() {
        if CoverRule.isShown(adultIsShown: adult != nil, sceneIsActive: sceneIsActive) {
            cover.show()
            adult?.browser.suspendMedia()
        }
    }

    /// What is protected became shown while the scene is inactive (the
    /// system's prompt is still up): the absence is counted from now.
    private func restartAbsence() {
        absence = Absence()
        absence.willDeactivate(at: now())
    }

    #if DEBUG
    // MARK: - The UI tests' translation (RD14)

    /// Saves the translator fixture's primary model, and its backup when
    /// asked, with keys under the UI tests' keychain service, and stores
    /// the daily automatic limit when one is given.
    private static func setUpTranslationForUITests(_ options: DebugLaunchOptions, models: LibraryModels, library: Library) async throws {
        if let limit = options.dailyAutomaticLimit {
            try await library.setDailyAutomaticLimit(limit)
        }
        guard !options.translationModels.isEmpty, try await models.statuses().isEmpty else { return }
        for role in options.translationModels {
            let address = role == .primary ? FixtureModelHTTP.Address.translate : FixtureModelHTTP.Address.translateBackup
            guard case .success(let key) = SecretKey.validate("sk-fixture-translator-\(role.rawValue)-0123") else { continue }
            let draft = ModelSlotDraft(role: role, preset: .custom, address: address, model: "fixture-translator", newKey: key)
            try await models.save(draft, testedOutcome: .passed)
        }
    }

    // MARK: - The UI tests' report (decision 4)

    /// Whether the adult library's file exists, whether a pool is open on
    /// it, whether the library object, the adult workspace and its browser
    /// model are gone from memory, how many browser sessions the app has
    /// made, how many article pages the fixture transport was asked for
    /// (RD12), and how many requests the translator fixture has answered
    /// (RD14).
    func adultDebugReport() async -> String {
        guard let gate else { return "" }
        let file = gate.adultLibraryFileExists ? 1 : 0
        let pool = await gate.adultLibraryIsClosed ? "closed" : "open"
        let library = await gate.adultLibraryObjectIsReleased ? "released" : "held"
        func state(_ object: AnyObject?) -> String {
            !adultWasShown ? "none" : object == nil ? "released" : "held"
        }
        return "file=\(file) pool=\(pool) library=\(library) workspace=\(state(lastAdultWorkspace)) "
            + "browser=\(state(lastAdultBrowser)) sessions=\(BrowserModel.sessionsMade) "
            + "pages=\((parts?.transport as? FixtureTransport)?.pageRequests ?? -1) "
            + "translationRequests=\(FixtureModelHTTP.translationRequests) "
            + "bodyRequests=\((try? await normal?.reading.library.usageCount(purpose: .body)) ?? -1) "
            + "readerBlock=\(normal?.reading.lastReportedPosition.map(String.init) ?? "none") "
            + "bodyStartsInBackground=\(BodyTranslationModel.startsInBackground) "
            + "slotChanges=\(BodyTranslationModel.slotChanges)"
    }
    #endif
}
