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
    /// Which partition operation runs, if any, and what it refuses
    /// meanwhile (review round 4): one state for the app, shared by both
    /// workspaces through their parts. `PartitionOperations` holds the
    /// table.
    let operations = PartitionOperationState()
    /// Whether a category move runs, from the reading of its plan to its
    /// end.
    var isMovingCategory: Bool { operations.running == .categoryMove }
    /// The sentence to show at the root; it outlives a swap of workspaces.
    var notice: AdultNotice?
    /// The question of turning off being asked at the root.
    var turnOffQuestion: TurnOffQuestion?
    /// Whether the first run (ux S12; RD21) is shown in place of the
    /// shell's containers: decided once, when the normal library has
    /// loaded.
    private(set) var showsFirstRun = false

    /// The app's one store; it gives out one library per partition.
    @ObservationIgnored private var store: LibraryStore?
    @ObservationIgnored private var gate: AdultGate?
    /// The device's preferences, where the first-run flag (RD21) and the
    /// record of background runs (RD24) are kept, and which the
    /// configuration file reads and writes (RD20); made before the opening
    /// (RD24 review G2).
    @ObservationIgnored private var preferences: Preferences?
    @ObservationIgnored private var parts: WorkspaceParts?
    /// Makes the adult workspace's browser set-up for each unlock: the
    /// adult partition's own persistent website data store, without Picture
    /// in Picture (RD18 decision 13; RD19 decision 4).
    @ObservationIgnored private var makeAdultBrowser: (@MainActor () -> BrowserSetup)?
    /// The adult browser's data: Clear Browsing Data (RD19 decision 5).
    @ObservationIgnored private var adultBrowserData: (any AdultBrowserData)?
    /// The adult partition's key store, for the adult library's models.
    @ObservationIgnored private var adultKeys: (any KeyStore)?
    /// The normal partition's key store: a configuration import removes
    /// the items of the references it cleared (RD20 decision 7).
    @ObservationIgnored private var normalKeys: (any KeyStore)?
    /// Makes the adult library's models' own HTTP stand-in for each unlock
    /// (RD19 decision 3): no connection is shared with the normal one.
    @ObservationIgnored private var makeAdultModelHTTP: (@Sendable () -> any ModelHTTP)?
    /// The normal library, which a move holds beside the adult one (RD19
    /// decision 11).
    @ObservationIgnored private var normalLibrary: Library?
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
    /// The opening of the normal library, which the scene's start and a
    /// background run share (RD24 approach 7).
    @ObservationIgnored private let preparation = SharedPreparation()
    /// A background run ran since the scene was last active: the next
    /// activation ends the translator's pause (review R1).
    @ObservationIgnored private var ranInBackground = false
    /// Whether the scene's start has been asked for: a start that failed in
    /// the background is tried again at the next activation.
    @ObservationIgnored private var startWasAsked = false
    /// Whether the launch entry has been made or put off (RD24 decision 3).
    @ObservationIgnored private var launchEntryDecided = false
    /// The launch was made in the background: its entry is made at the
    /// scene's first activation.
    @ObservationIgnored private var launchEntryOwed = false
    /// The background schedule (RD24 approach 3).
    @ObservationIgnored private var scheduler: (any BackgroundScheduler)?
    /// The background run in progress, told when the app comes to the
    /// front.
    @ObservationIgnored private var currentRun: BackgroundRun?
    /// The control of the last background run: an entry into the normal
    /// partition waits for its collection (RD24 approach 7).
    @ObservationIgnored private var backgroundControl: BackgroundPassControl?

    #if DEBUG
    /// Whether the UI tests' report element is shown: only under a UI-test
    /// library directory.
    private(set) var showsDebugReport = false
    /// Whether the "Deliver background refresh" control is shown: only
    /// under a UI-test library directory and its own launch key (RD24
    /// review R3).
    private(set) var showsDeliveryControl = false
    /// How many taps of the control were handled, for the report.
    @ObservationIgnored private var deliveriesHandled = 0
    /// The slow-save option, which the adult workspace's first category
    /// save takes too, so that a save can be overrun by a lock.
    @ObservationIgnored private var slowNextSave: Duration?
    /// The article page size of the UI tests, which every workspace's
    /// reading model takes.
    @ObservationIgnored private var articlePageSize: Int?
    /// The OPML fixture of the UI tests, which every workspace's source
    /// model takes (RD08 decision 8).
    @ObservationIgnored private var opmlFixture: OPMLFixture?
    /// Whether the usage seeding runs on each library opened (RD17).
    @ObservationIgnored private var seedsUsage = false
    /// The configuration fixture of the UI tests (RD20 decision 10), and
    /// the pause between an import's write and its completion.
    @ObservationIgnored private var configurationFixture: ConfigurationFixture?
    @ObservationIgnored private var configurationWritePause: Duration?
    @ObservationIgnored private var configurationExportHold: ConfigurationExportHold?
    @ObservationIgnored private var adultWasShown = false
    @ObservationIgnored private weak var lastAdultWorkspace: Workspace?
    @ObservationIgnored private weak var lastAdultBrowser: BrowserModel?
    /// How long Clear Browsing Data waits before it clears, so that a UI
    /// test can ask for an adult page meanwhile (review round 2).
    @ObservationIgnored private var clearPause: Duration?
    /// What the UI tests ask of the next move (RD19): its deletion failing
    /// once, and a pause between its steps.
    @ObservationIgnored private var failNextMoveDeletion = false
    @ObservationIgnored private var moveStepPause: Duration?
    /// The adult browser's store under this UI-test library directory.
    @ObservationIgnored private var uiTestAdultStore: UUID?
    /// The UI tests' clock (RD24 decision 9).
    @ObservationIgnored private var debugClock: DebugClock?
    /// How the last background run ended, for the report.
    @ObservationIgnored private var lastBackgroundEnding: BackgroundRun.Ending?
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

    /// Whether the shell shows the first run: only on the normal
    /// workspace.
    var isShowingFirstRun: Bool {
        showsFirstRun && adult == nil
    }

    /// Whether the partition switch is offered: only while the partition is
    /// turned on (ux section 2).
    var showsPartitionSwitch: Bool {
        gateState == .locked || gateState == .unlocked
    }

    /// The scene's start (RD24 approach 7): the preparation, then the
    /// launch entry — at once when the app is not in the background, else
    /// at the scene's first activation, and once. A launch made for a
    /// background run is not an entry (decision 3).
    func start() async {
        startWasAsked = true
        guard await prepare(inBackground: UIApplication.shared.applicationState == .background) else { return }
        // Rechecked after the wait: another start has decided already.
        guard !launchEntryDecided, let normal else { return }
        launchEntryDecided = true
        if UIApplication.shared.applicationState == .background {
            launchEntryOwed = true
        } else {
            // The launch is the first entry (RD06 decision 3).
            enter(normal)
        }
    }

    /// Opens the normal library and builds its workspace and the gate, once
    /// for the scene's start and a background run together: one task that
    /// both wait for, each rechecking `status` after it. A failure in the
    /// foreground is shown and left as it is: the file is never deleted,
    /// reset or replaced. A failure in the background shows nothing and is
    /// forgotten, so that the foreground start tries again (criterion 8).
    ///
    /// The background action stops waiting when its task is cancelled (the
    /// system's time ran out, review G1); the opening goes on for a scene
    /// that may connect.
    ///
    /// - Parameters:
    ///   - inBackground: whether the caller is in the background, asked
    ///     when the opening has failed.
    ///   - stopsOnCancellation: whether the wait ends with the caller's
    ///     task.
    /// - Returns: whether the normal library is open.
    private func prepare(inBackground: @autoclosure () -> Bool, stopsOnCancellation: Bool = false) async -> Bool {
        switch status {
        case .ready: return true
        case .failed: return false
        case .loading: break
        }
        let outcome = await preparation.wait(stopsOnCancellation: stopsOnCancellation) { [weak self] in
            await self?.openNormalLibrary() ?? CancellationError()
        }
        // Rechecked after the wait: the opening succeeded, or another
        // caller has shown its failure.
        switch status {
        case .ready: return true
        case .failed: return false
        case .loading: break
        }
        if case .finished(let error?) = outcome, !inBackground(), !(error is CancellationError) {
            status = .failed(LibraryFailure(error))
        }
        return false
    }

    /// The clock, the preferences store and the background scheduler: what
    /// the schedule needs, which needs no library (review G2). Made once,
    /// so that a start tried again keeps them.
    private func makeScheduleParts() {
        guard scheduler == nil else { return }
        #if DEBUG
        let options = DebugLaunchOptions(environment: ProcessInfo.processInfo.environment)
        // Under a UI-test library directory: a preferences suite named
        // after it, never the standard one.
        let defaults = options.libraryDirectory.flatMap { UserDefaults(suiteName: $0.lastPathComponent) } ?? .standard
        // The clock offset, like the fixture transport, applies only under a
        // UI-test library directory.
        let clock = DebugClock(offset: options.libraryDirectory != nil ? options.clockOffset : 0)
        if options.libraryDirectory != nil {
            debugClock = clock
        }
        now = { clock.now() }
        // Under a UI-test library directory the recording scheduler, never
        // the system's (RD24 decision 9).
        scheduler = options.libraryDirectory != nil ? RecordingBackgroundScheduler() : SystemBackgroundScheduler()
        #else
        let defaults = UserDefaults.standard
        now = { Date() }
        scheduler = SystemBackgroundScheduler()
        #endif
        preferences = Preferences(defaults)
    }

    /// Opens the normal library, creating it on first launch, builds the
    /// normal workspace (models only) and the gate, and reconciles the
    /// background schedule. The adult library is not opened here: a launch
    /// starts in the normal partition.
    ///
    /// - Returns: the error that stopped it, or `nil` when the library is
    ///   open and `status` is ready.
    private func openNormalLibrary() async -> (any Error)? {
        observeScene()
        // OPML and configuration exports left by a session that ended with
        // a share sheet open (RD08 decision 7; RD20 decision 9).
        ExportFolder.opml.emptyAll()
        ExportFolder.configuration.emptyAll()
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
        // Under a UI-test library directory: keys under a keychain service
        // named after the directory, never the owner's, and the model
        // fixture, which reaches no real service.
        let keyStore = options.libraryDirectory.map { KeychainKeyStore(partition: .normal, uiTestSuffix: $0.lastPathComponent) }
            ?? KeychainKeyStore(partition: .normal)
        let modelHTTP: any ModelHTTP = options.libraryDirectory != nil ? FixtureModelHTTP() : URLSessionModelHTTP()
        let usesModelFixture = options.libraryDirectory != nil
        makeAdultModelHTTP = { () -> any ModelHTTP in usesModelFixture ? FixtureModelHTTP() : URLSessionModelHTTP() }
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
        showsDeliveryControl = options.libraryDirectory != nil && options.backgroundDelivery
        slowNextSave = options.slowNextSave
        if options.libraryDirectory != nil {
            failNextMoveDeletion = options.failNextMoveDeletion
            moveStepPause = options.moveStepPause
            clearPause = options.clearPause
        }
        #else
        let directory = LibraryStore.defaultDirectory()
        let transport: any Transport = URLSessionTransport()
        let candidateLimit = Duration.seconds(20)
        let cacheRoot = LibraryStore.defaultCacheRoot()
        let keyStore = KeychainKeyStore(partition: .normal)
        let modelHTTP: any ModelHTTP = URLSessionModelHTTP()
        makeAdultModelHTTP = { URLSessionModelHTTP() }
        let authenticator: any DeviceAuthenticator = SystemDeviceAuthenticator()
        let adultKeys = KeychainKeyStore(partition: .adult)
        let adultIsEnabled = BuildFeatures.adultPartition
        #endif
        makeScheduleParts()
        let now = self.now
        self.adultKeys = adultKeys
        do {
            // The app's one store: a start tried again keeps it.
            let store = self.store ?? LibraryStore(directory: directory, cacheRoot: cacheRoot, now: now)
            self.store = store
            let library = try await store.openNormal()
            normalLibrary = library
            guard let preferences else { return LibraryError.storage("No preferences store") }
            normalKeys = keyStore
            let models = LibraryModels(library: library, keys: keyStore, http: modelHTTP)
            let parts = WorkspaceParts(
                transport: transport, candidateLimit: candidateLimit, now: now,
                refreshSettings: RefreshSettings(preferences),
                readingSettings: ReadingSettings(preferences: preferences),
                normalModels: models,
                translationSettings: TranslationSettings(preferences: preferences),
                // The normal library's models: its workspace's translation
                // resumes, whichever workspace's Settings saved.
                slotsChanged: { [weak self] in self?.normal?.translation.slotsChanged() },
                operations: operations
            )
            self.parts = parts
            parts.refreshSettings.onScheduleChanged = { [weak self] in self?.reconcileSchedule() }
            // The embedded browser (RD19 decision 4): the system's default
            // website data store for the normal library, and the adult
            // partition's own persistent one, without Picture in Picture,
            // for the adult library (RD18 decision 13). Under a UI-test
            // library directory the fixture pages for both, a store that
            // lasts the process for the normal library, and for the adult
            // library a persistent store of the directory's own, never the
            // real one; the stores of earlier tests are removed.
            #if DEBUG
            let browser: BrowserSetup
            let adultBrowserData: any AdultBrowserData
            if let name = options.libraryDirectory?.lastPathComponent {
                let identifier = BrowserDataStores.uiTestAdultIdentifier(directoryName: name)
                uiTestAdultStore = identifier
                await BrowserDataStores.removeUITestStores(keeping: identifier)
                browser = BrowserSetup(
                    dataStore: BrowserDataStores.uiTestStore(for: .normal, directoryName: name), addressMap: BrowserFixtures.map,
                    schemeHandlers: [BrowserFixtures.scheme: BrowserFixtures()]
                )
                makeAdultBrowser = {
                    BrowserSetup(
                        dataStore: BrowserDataStores.uiTestStore(for: .adult, directoryName: name), addressMap: BrowserFixtures.map,
                        schemeHandlers: [BrowserFixtures.scheme: BrowserFixtures()], allowsPictureInPicture: false
                    )
                }
                adultBrowserData = WebKitAdultBrowserData(identifier: identifier)
            } else {
                browser = BrowserSetup(dataStore: BrowserDataStores.store(for: .normal))
                makeAdultBrowser = { BrowserSetup(dataStore: BrowserDataStores.store(for: .adult), allowsPictureInPicture: false) }
                adultBrowserData = WebKitAdultBrowserData(identifier: BrowserDataStores.adultIdentifier)
            }
            #else
            let browser = BrowserSetup(dataStore: BrowserDataStores.store(for: .normal))
            makeAdultBrowser = { BrowserSetup(dataStore: BrowserDataStores.store(for: .adult), allowsPictureInPicture: false) }
            let adultBrowserData: any AdultBrowserData = WebKitAdultBrowserData(identifier: BrowserDataStores.adultIdentifier)
            #endif
            self.adultBrowserData = adultBrowserData
            let normalBox = WeakWorkspace(partition: .normal)
            let workspace = Workspace(
                library: library, models: models, parts: parts, browser: browser,
                configuration: configurationContext(adult: nil, workspace: normalBox)
            )
            normalBox.value = workspace
            #if DEBUG
            if options.libraryDirectory != nil {
                articlePageSize = options.articlePageSize
                opmlFixture = options.opmlFixture
                seedsUsage = options.seedsUsage
                configurationFixture = options.configurationFixture
                configurationWritePause = options.configurationWritePause
                configurationExportHold = options.configurationExportHold
                workspace.translation.body.holdsFirstPlanUntilBackground = options.holdsFirstBodyPlan
                if options.failsFirstBodyWrite {
                    workspace.translation.body.failNextWrites(1)
                }
                workspace.translation.body.holdsRetryWrite = options.holdsRetryWrite
                if options.changesSlotsAfterReader {
                    // The same call as a save in Settings.
                    workspace.translation.body.changesSlotsAfterReaderTranslated = true
                    workspace.translation.body.slotsChangedForUITests = { [weak self] in self?.parts?.slotsChanged() }
                }
            }
            workspace.sources.opmlFixture = opmlFixture
            workspace.configuration.fixture = configurationFixture
            workspace.configuration.writePause = configurationWritePause
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
            if seedsUsage {
                try await library.insertUsageForUITests(calendar: .current)
            }
            workspace.categories.failNextSave = options.failNextSave
            workspace.categories.slowNextSave = options.slowNextSave
            workspace.sources.failNextSave = options.failNextSourceSave
            // Only under a UI-test library: never on the owner's library.
            workspace.reading.failNextSearch = options.libraryDirectory != nil && options.failNextSearch
            #endif
            await workspace.load()
            // The first run (RD21 decisions 1 and 2). Under a UI-test
            // library directory only when asked for.
            #if DEBUG
            let decidesFirstRun = options.libraryDirectory == nil || options.firstRun
            #else
            let decidesFirstRun = true
            #endif
            if decidesFirstRun {
                showsFirstRun = Self.startsFirstRun(preferences: preferences, categories: workspace.categories)
                workspace.navigation.isShowingFirstRun = showsFirstRun
            }
            // The gate: the only way to the adult library from here on.
            let gate = AdultGate(
                store: store, authenticator: authenticator, preferences: preferences, keys: adultKeys,
                browserData: adultBrowserData, isEnabled: adultIsEnabled
            )
            self.gate = gate
            gateState = await gate.state
            // A Delete that met "in use" left the adult store, emptied; with
            // the partition off and its library gone, nothing holds it now
            // (review round 1). "Keep Data Hidden" keeps the library file,
            // and with it the store.
            if gateState == .off, !gate.adultLibraryFileExists {
                Task { await adultBrowserData.removeLeftoverStore() }
            }
            lockTiming = await gate.lockTiming
            normal = workspace
            status = .ready
            reconcileSchedule()
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Background refresh (RD24)

    /// The background task's action (RD24 approach 7): the shared
    /// preparation, then one run over the normal library. A run that cannot
    /// prepare returns, leaving the foreground start to try again; a run
    /// made while the app is in front does nothing (the entry refreshes).
    /// The system completes the task when this returns; when its time runs
    /// out it cancels this task, and the run cancels the refresher first.
    ///
    /// Every delivery first reconciles the schedule from the stored
    /// settings, so that a failed or abandoned preparation still leaves the
    /// next request (review G2). A failure of the opening while the app is
    /// in front is shown, as the scene's start shows it (review R2).
    func backgroundRefresh() async {
        makeScheduleParts()
        guard let preferences, let scheduler else { return }
        await BackgroundAction.perform(
            settings: preferences, now: now(), scheduler: scheduler,
            prepare: {
                await self.prepare(inBackground: UIApplication.shared.applicationState == .background, stopsOnCancellation: true)
            },
            isInFront: { self.sceneIsActive },
            run: { await self.refreshInBackground() }
        )
    }

    /// One background run: the schedule is reconciled; with background
    /// refresh off or "Manual Only" nothing is collected or recorded and
    /// the run waits for the translator; otherwise the run is recorded and
    /// the pass runs. Nothing of the other partition is reachable from the
    /// work (`BackgroundRefreshWork`).
    private func refreshInBackground() async {
        guard let normal, let normalLibrary, let parts, let preferences, currentRun == nil else { return }
        reconcileSchedule()
        let settings = parts.refreshSettings
        guard settings.backgroundRefresh, settings.interval != .manualOnly else {
            await normal.translation.translator.untilSettled()
            return
        }
        preferences.recordBackgroundRun(at: now())
        ranInBackground = true
        let control = BackgroundPassControl(refresher: normal.refresh.engine)
        let work = BackgroundRefreshWork(workspace: normal, library: normalLibrary, settings: settings, control: control)
        let run = BackgroundRun(control: control) { await work.run() }
        currentRun = run
        backgroundControl = control
        let ending = await run.run()
        // Rechecked after the wait: only this run is forgotten.
        if currentRun === run {
            currentRun = nil
        }
        #if DEBUG
        lastBackgroundEnding = ending
        #else
        _ = ending
        #endif
    }

    /// The collection of a run handed to the front holds the ordinary
    /// refresh's background time, with its expiry, until it ends (review
    /// G3): if the app leaves again meanwhile, the collection is not
    /// suspended halfway without the refresher being cancelled.
    private func holdBackgroundTimeForCollection() {
        guard let control = backgroundControl, control.isCollecting, let refresh = normal?.refresh else { return }
        refresh.beginBackgroundTime()
        Task {
            await control.untilCollectionEnds()
            refresh.endBackgroundTimeIfIdle()
        }
    }

    /// Applies the schedule's rule with the settings now (criterion 2).
    private func reconcileSchedule() {
        guard let parts, let scheduler else { return }
        BackgroundSchedule.reconcile(
            enabled: parts.refreshSettings.backgroundRefresh, interval: parts.refreshSettings.interval, now: now(), scheduler: scheduler
        )
    }

    /// An entry into a partition's workspace (RD06 decision 3): clean up,
    /// then refresh when due. An entry into the normal partition first
    /// waits for a background run's collection that is under way, so that
    /// the library is not collected twice and the refresh time is written
    /// once (RD24 criterion 7).
    private func enter(_ workspace: Workspace) {
        let control = workspace === normal ? backgroundControl : nil
        Task {
            await control?.untilCollectionEnds()
            // `entered()` rechecks whether its workspace was dropped.
            await workspace.refresh.entered()
        }
    }

    // MARK: - The first run (RD21)

    /// Whether a launch shows the first run (decisions 1 and 2): only when
    /// its flag is absent and the normal library's categories were read and
    /// are none. A library with a category (an upgrade, a restore, or a
    /// first run interrupted after one was created) writes the flag and
    /// shows the shell; a failed read shows the shell and writes nothing,
    /// so that the next launch decides again.
    private static func startsFirstRun(preferences: Preferences, categories: CategoryModel) -> Bool {
        guard !preferences.firstRunIsDone, categories.loadState == .loaded else { return false }
        if categories.summaries.isEmpty {
            return true
        }
        preferences.firstRunIsDone = true
        return false
    }

    /// The first run ended, by Done or by Skip on its last step (decision
    /// 8): the flag is written, the shell shows Today with nothing pushed
    /// or presented — or the category list where it is, when "Show in
    /// Library" was chosen during the first run — and a library with a
    /// feed-like source is refreshed at once, since the launch's entry
    /// refresh ran on the empty library.
    func finishFirstRun() {
        guard showsFirstRun, let normal else { return }
        preferences?.firstRunIsDone = true
        normal.navigation.firstRunEnded()
        showsFirstRun = false
        if normal.sources.hasFeedLikeSource {
            let refresh = normal.refresh
            Task { await refresh.refresh(.library) }
        }
    }

    // MARK: - Switching (decision 5)

    /// "Adult" in the partition switch: authenticates, builds and loads the
    /// adult workspace and shows it at the root of the current tab. An
    /// authentication that does not pass leaves everything as it was, with
    /// its sentence. An unlock during which the scene entered the
    /// background is discarded.
    ///
    /// The same unlock carries an operation that began in the normal
    /// partition and needs the adult library (RD19 decision 9): `pending`
    /// is handed to the adult workspace in the step that shows it, and
    /// this model keeps nothing of it. On every other outcome it is
    /// dropped, with nothing read or written.
    ///
    /// - Returns: what the unlock came to.
    @discardableResult
    func chooseAdult(pending: PendingAdultOperation? = nil) async -> AdultUnlockOutcome {
        guard let gate, let parts, let makeAdultBrowser, let adultKeys, let makeAdultModelHTTP, let normal, adult == nil,
              gateState == .locked, !isAuthenticating, !operations.refusesUnlock
        else { return .refused }
        // An unlock that would carry a move across does not begin while a
        // partition operation runs: the move could not begin (round 4).
        if case .move? = pending, operations.refusesUnlockCarryingMove {
            return .refused
        }
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
        let outcome: AdultUnlockOutcome
        switch await gate.unlock(reason: String(localized: "Unlock the adult partition")) {
        case .unlocked(let library):
            // The adult library's own models (RD19 decisions 1 and 3): the
            // adult key store and an HTTP stand-in of their own. They go
            // with the workspace at the lock.
            let models = LibraryModels(library: library, keys: adultKeys, http: makeAdultModelHTTP())
            // The adult target is the pair the adult models were made from
            // (RD20 decision 7): only this workspace's context has it.
            let shown = WeakWorkspace(partition: .adult)
            let workspace = Workspace(
                library: library, models: models, parts: parts, browser: makeAdultBrowser(),
                configuration: configurationContext(adult: ConfigurationTarget(library: library, keys: adultKeys), workspace: shown)
            )
            shown.value = workspace
            workspace.categories.mover = mover(adult: library, workspace: workspace)
            // No adult page opens while its data are cleared or removed.
            workspace.browser.mayMakeSessions = { [weak self] in
                guard let self else { return false }
                return !self.operations.refusesAdultSessions
            }
            #if DEBUG
            workspace.categories.slowNextSave = slowNextSave
            if let size = articlePageSize {
                workspace.reading.pageSize = size
            }
            workspace.sources.opmlFixture = opmlFixture
            if seedsUsage {
                // The adult library's own rows, so that a lock has
                // something to hide (RD17 criterion 7).
                try? await library.insertUsageForUITests(calendar: .current)
            }
            workspace.configuration.fixture = configurationFixture
            workspace.configuration.writePause = configurationWritePause
            workspace.configuration.exportHold = configurationExportHold
            #endif
            await workspace.load()
            // From here to the end of the case nothing suspends before the
            // workspace is shown: the check, the showing and the hand-over
            // are one step.
            if attempt.enteredBackground {
                workspace.stop()
                await gate.lock()
                outcome = .discarded
            } else {
                show(workspace)
                workspace.begin(pending)
                outcome = .unlocked
            }
        case .refused(.notAuthenticated(let answer)):
            notice = Self.notice(for: answer, otherwise: .stillLocked)
            outcome = .notAuthenticated(answer)
        case .couldNotOpen(let error):
            notice = .couldNotOpen(LibraryFailure(error))
            outcome = .couldNotOpen
        case .refused(.busy), .refused(.notAllowed):
            outcome = .refused
        case .discarded:
            outcome = .discarded
        }
        gateState = await gate.state
        return outcome
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
        // refreshing (decision 13). An OPML import of it that is still
        // being read ends, so that its result is not shown on return (RD08
        // criterion 8).
        normal.navigation.clear()
        normal.sources.endOPMLImport()
        normal.configuration.leftForOtherPartition()
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
        // An adult export whose share sheet the swap took away is not
        // dismissed through the sheet: every export file goes now (RD08,
        // RD20).
        ExportFolder.opml.emptyAll()
        ExportFolder.configuration.emptyAll()
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
            // Returning to the normal partition is an entry for its
            // refresh, after a background collection under way (RD24).
            await self.backgroundControl?.untilCollectionEnds()
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

    // MARK: - Clear Browsing Data (RD19 decision 5)

    /// Whether Clear Browsing Data can be asked for now: not while the
    /// system's authentication is asked for or a partition operation runs.
    var canClearBrowsingData: Bool {
        showsPartitionSwitch && !isAuthenticating && operations.running == nil
    }

    /// How long Clear and Delete wait for the pages' documents to unload.
    static let unloadBound = Duration.seconds(10)

    /// Removes every kind of website data of the adult browser's own store;
    /// the normal partition's are kept. An adult page open now is closed
    /// first, on both stacks, and the clear waits until every ended page's
    /// document has been replaced by an empty one, so that no page's script
    /// writes during or after the clear (review round 1). A page whose
    /// document is not replaced within the bound still has its data
    /// cleared, and the clear does not report success.
    ///
    /// - Returns: whether the clear ended with no page left running.
    @discardableResult
    func clearAdultBrowsingData() async -> Bool {
        guard canClearBrowsingData, let adultBrowserData, let token = operations.begin(.clearBrowsingData) else { return false }
        // From here until the clear has ended no adult page opens, by a tap
        // or by an unlock (review round 2); a page asked for meanwhile opens
        // after it.
        defer {
            operations.end(token)
            adult?.browser.stacksChanged()
        }
        adult?.navigation.closeBrowsers()
        let unloaded = await DocumentUnloader.allCommitted(within: Self.unloadBound)
        #if DEBUG
        if let clearPause {
            try? await Task.sleep(for: clearPause)
        }
        #endif
        await adultBrowserData.clear()
        return unloaded
    }

    // MARK: - Moving a category (RD19 decisions 9 to 11)

    /// What the adult workspace's category model moves with: the normal
    /// library, opened at start, and the adult one of this unlock. Moves
    /// run inside the adult partition, in both directions.
    /// Waits for the category and source changes queued in either
    /// workspace before a move's operation began (review round 4); none is
    /// queued meanwhile (`PartitionOperations.refusesLibraryEdits`).
    private func settleLibraryEdits() async {
        for workspace in [normal, adult].compactMap({ $0 }) {
            await workspace.categories.settle()
            await workspace.sources.settle()
        }
    }

    private func mover(adult library: Library, workspace: Workspace) -> CategoryMover {
        CategoryMover(
            plan: { [weak self] id, from in
                guard let self, let normalLibrary = self.normalLibrary else { return nil }
                // The move's operation runs (the category model began it):
                // no change of either library is queued from here on, and
                // one queued before it ends before the plan is read.
                await self.settleLibraryEdits()
                let (old, new) = from == .normal ? (normalLibrary, library) : (library, normalLibrary)
                return try? await CategoryMove.plan(category: id, from: old, to: new)
            },
            run: { [weak self, weak workspace] plan in
                guard let self, let workspace else { return .notMoved }
                return await self.runMove(plan, adultLibrary: library, workspace: workspace)
            }
        )
    }

    /// Runs a move (decision 11): copy, then deletion; then the old
    /// partition's workspace closes every route that shows the category, a
    /// moved source or an article of one, and reads every living list
    /// again; only then is the old image cache cleared. When the old
    /// partition is the normal one its cache is cleared after a `moved`
    /// run whatever became of the adult workspace meanwhile; an adult cache
    /// is cleared only while the adult workspace is still the one shown (a
    /// lock closed it, and what it keeps stays in the adult partition).
    /// Both workspaces then read their categories and recorded refresh
    /// time, and a destination on screen refreshes the new category.
    private func runMove(_ plan: CategoryMove.Plan, adultLibrary: Library, workspace: Workspace) async -> CategoryMove.Outcome {
        // The category model that runs it holds the move's operation, from
        // the reading of the plan to the end of this run (review round 4).
        guard let normalLibrary, let normal, isMovingCategory else { return .notMoved }
        let toAdult = plan.from == .normal
        let (old, new) = toAdult ? (normalLibrary, adultLibrary) : (adultLibrary, normalLibrary)
        #if DEBUG
        let failing: CategoryMove.Step? = failNextMoveDeletion ? .deletion : nil
        failNextMoveDeletion = false
        let outcome = await CategoryMove.run(
            plan, from: old, to: new, debug: CategoryMove.DebugOptions(failing: failing, pauseBetweenSteps: moveStepPause)
        )
        #else
        let outcome = await CategoryMove.run(plan, from: old, to: new)
        #endif
        let moved = Set(plan.moving.map(\.id))
        switch outcome {
        case .moved:
            if toAdult {
                // The normal workspace is not shown: its navigation was
                // cleared when the adult one was shown (RD18).
                await normal.letGo(ofMoved: moved, category: plan.category.id)
                await CategoryMove.clearOldCache(from: normalLibrary)
            } else if adult === workspace {
                await workspace.letGo(ofMoved: moved, category: plan.category.id)
                if adult === workspace {
                    await CategoryMove.clearOldCache(from: adultLibrary)
                }
            }
        case .copiedNotRemoved:
            break
        case .nothingToMove, .notMoved:
            return outcome
        }
        var readAgain = [normal]
        if adult === workspace {
            readAgain.append(workspace)
        }
        for each in readAgain {
            await each.categories.reload()
            await each.refresh.load()
        }
        // A destination on screen collects the moved sources at once; the
        // normal partition collects them at its next entry (gap 5).
        if toAdult, case .moved = outcome, adult === workspace {
            let id = plan.category.id
            Task { await workspace.refresh.refresh(.category(id)) }
        }
        return outcome
    }

    // MARK: - The configuration file (RD20 decision 7)

    /// The token of the configuration import whose write runs: the import
    /// is the fourth partition operation (`PartitionOperation
    /// .configurationImport`, batch 2). One import writes at a time, so one
    /// token is held, from `beginWrite` to the end of the completion.
    @ObservationIgnored private var importToken: PartitionOperations.Token?

    /// What a workspace's configuration model is given. The adult target
    /// only for the adult workspace; `workspace` names the workspace the
    /// context is for, weakly, so that the write's completion never keeps
    /// it.
    private func configurationContext(adult: ConfigurationTarget?, workspace: WeakWorkspace) -> ConfigurationContext {
        guard let preferences, let normalLibrary, let normalKeys else {
            preconditionFailure("the configuration context before the normal library is open")
        }
        return ConfigurationContext(
            preferences: preferences,
            normal: ConfigurationTarget(library: normalLibrary, keys: normalKeys),
            adult: adult,
            appVersion: AboutView.version,
            now: now,
            gateState: { [weak self] in self?.gateState ?? .unavailable },
            noticeIsShown: { [weak self] in self?.notice != nil },
            unlock: { [weak self] document in
                guard let self else { return .refused }
                return await self.unlockForImport(document)
            },
            writeIsHeldBack: { [weak self] in self.map { $0.operations.running != nil } ?? true },
            beginWrite: { [weak self] in
                guard let self, let token = self.operations.begin(.configurationImport) else { return false }
                self.importToken = token
                return true
            },
            // Like a move's plan: the token is held, so nothing new is
            // queued, and what was queued before ends first.
            settle: { [weak self] in await self?.settleLibraryEdits() },
            // The box is held; it holds the workspace weakly.
            completion: { [weak self] result in
                guard let self else { return false }
                return await self.configurationImported(result, by: workspace)
            },
            summaryLeft: { [weak self] result in
                self?.configurationSummaryLeft(result)
            }
        )
    }

    /// "Unlock" or "Turn On and Unlock" of an import begun in the normal
    /// partition: the partition switch's own unlock, after turning the
    /// partition on when it is off (two prompts, decision 11), carrying
    /// the document. Every outcome but `.unlocked` drops it here.
    private func unlockForImport(_ document: ConfigurationDocument) async -> AdultUnlockOutcome {
        if gateState == .off {
            await turnOnAdult()
            guard gateState == .locked else { return .refused }
        }
        return await chooseAdult(pending: .importConfiguration(document))
    }

    /// The completion of every import's write (decision 7), whether or not
    /// the workspace that began it still exists: the normal workspace is
    /// read again, the shared settings objects read the preferences again
    /// and the normal library's translation resumes; the adult workspace
    /// is read again only while it is the one shown.
    ///
    /// - Returns: whether the summary may be shown: the workspace that
    ///   began the import is the one shown.
    private func configurationImported(_ result: ConfigurationImportResult, by began: WeakWorkspace) async -> Bool {
        defer {
            if let importToken {
                operations.end(importToken)
                self.importToken = nil
            }
        }
        guard let normal, let parts else { return false }
        await normal.reloadAfterImport()
        parts.refreshSettings.reload()
        parts.translationSettings.reload()
        parts.slotsChanged()
        // The partition the import began in is the box's, not the
        // workspace's: a lock releases the adult workspace before this runs
        // (review round 1).
        let showsSummary: Bool
        switch began.partition {
        case .adult:
            if let workspace = began.value, adult === workspace {
                await workspace.reloadAfterImport()
                workspace.translation.slotsChanged()
            }
            showsSummary = began.value.map { adult === $0 } ?? false
        case .normal:
            showsSummary = adult == nil
        }
        // No summary will be left (a lock or a switch took its workspace
        // away): the refresh that leaving it starts begins now, for each
        // workspace whose library was written and that still exists
        // (review round 1, G2). One way out of the rule stated at
        // `ConfigurationModel.owedRefresh`: the refresh starts once.
        if !showsSummary, !result.changedNothing {
            configurationSummaryLeft(result)
        }
        return showsSummary
    }

    /// The summary was left: each workspace whose library was written and
    /// that still exists refreshes (decision 8).
    private func configurationSummaryLeft(_ result: ConfigurationImportResult) {
        if case .imported = result.normal, let refresh = normal?.refresh {
            Task { await refresh.refresh(.library) }
        }
        if case .imported? = result.adult, let refresh = adult?.refresh {
            Task { await refresh.refresh(.library) }
        }
    }

    /// Whether the partition can be turned off now: not while a partition
    /// operation runs (reviews rounds 2 and 4): Delete would remove a store
    /// a clear then makes again, or the library a move is copying into,
    /// and a second Turn Off would overlap the first.
    var canTurnOff: Bool {
        showsPartitionSwitch && operations.running == nil
    }

    /// "Turn Off the Adult Partition": asks at the root.

    func askToTurnOff() {
        guard canTurnOff else { return }
        turnOffQuestion = .keepOrDelete
    }

    /// The last answer was given: the app locks, then the gate turns the
    /// partition off, keeping its data hidden or deleting it. A deletion
    /// that fails says so and leaves the partition on.
    func turnOff(deletingData: Bool) async {
        turnOffQuestion = nil
        guard let gate, canTurnOff, let token = operations.begin(.turnOff) else { return }
        defer { operations.end(token) }
        lock()
        // The lock ended the adult pages; Delete removes their store only
        // once their documents are gone, so that none writes again after
        // it (review round 1). Not in time: nothing is deleted, and the
        // owner can try again.
        if deletingData, await !DocumentUnloader.allCommitted(within: Self.unloadBound) {
            notice = .couldNotDelete
            gateState = await gate.state
            return
        }
        #if DEBUG
        // The UI tests hold Delete here, as they hold Clear (round 4).
        if deletingData, let clearPause {
            try? await Task.sleep(for: clearPause)
        }
        #endif
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
        normal?.translation.appEnteredBackground()
        adult?.translation.appEnteredBackground()
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
        reconcileSchedule()
    }

    private func sceneDidActivate() {
        sceneIsActive = true
        // A background run ends its task; its collection goes on as the
        // ordinary refresh (RD24 criterion 7), with the ordinary refresh's
        // background time until it ends (review G3).
        if let run = currentRun {
            run.cameToFront()
            holdBackgroundTimeForCollection()
        }
        // A start that failed in the background is tried again (criterion
        // 8).
        if startWasAsked, case .loading = status, !preparation.isRunning {
            Task { await start() }
        }
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
        if wasInBackground || launchEntryOwed {
            wasInBackground = false
            launchEntryOwed = false
            // Every return from the background is an entry (RD06 decision
            // 3), and so is the first activation of a launch made in the
            // background (RD24 decision 3); a lock of the adult partition
            // has made the normal partition's entry itself.
            if !locksAdult, let shown {
                enter(shown)
            }
            // The app came to the front: a translation pause of the normal
            // library may end (RD14 decision 6), whichever partition is
            // shown, since the normal workspace goes on working; and the
            // adult library's, while it is shown. Each one's body work,
            // stopped in the background, may start again (RD15).
            normal?.translation.cameToFront()
            adult?.translation.cameToFront()
        } else if ranInBackground {
            // The first activation after a launch made for a background run
            // (no scene was in the background): a pause the run left ends
            // (review R1). No entry: the scene's start makes it.
            normal?.translation.cameToFront()
        }
        ranInBackground = false
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
    /// (RD12), how many requests it was asked for in all (RD25), how
    /// many requests the translator fixture has answered (RD14),
    /// whether WebKit lists the adult browser's own store (RD19
    /// assumption A2); and for RD24 whether a background request is
    /// pending, how the last background run ended, how many runs the
    /// record holds for the last 7 days, and how many times the adult
    /// library was asked of the store.
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
            + "requests=\((parts?.transport as? FixtureTransport)?.requests ?? -1) "
            + "translationRequests=\(FixtureModelHTTP.translationRequests) "
            + "adultStore=\(await adultStoreIsListed() ? "listed" : "absent") "
            + "scheduled=\((scheduler as? RecordingBackgroundScheduler)?.pending != nil ? "yes" : "no") "
            + "background=\(Self.reportName(of: lastBackgroundEnding)) "
            + "runs=\(preferences?.backgroundRuns(before: now()).count ?? 0) "
            + "adultOpens=\(await store?.adultOpensForUITests ?? -1) "
            + "deliveries=\(deliveriesHandled) "
            + "configuration=\(normal?.configuration.heldDocumentReport ?? "none") "
            + "exportsWritten=\(ConfigurationModel.debugExportsWritten) exportsEnded=\(ConfigurationModel.debugExportsEnded) "
            + "shareEnded=\(ConfigurationModel.debugShareEnded) "
            + "bodyRequests=\((try? await normal?.reading.library.usageCount(purpose: .body)) ?? -1) "
            + "adultBodyRequests=\((try? await adult?.reading.library.usageCount(purpose: .body)) ?? -1) "
            + "readerBlock=\(normal?.reading.lastReportedPosition.map(String.init) ?? "none") "
            + "bodyStartsInBackground=\(BodyTranslationModel.startsInBackground) "
            + "slotChanges=\(BodyTranslationModel.slotChanges)"
    }

    private static func reportName(of ending: BackgroundRun.Ending?) -> String {
        switch ending {
        case .ended(let result)?: "\(result)"
        case .expired?: "expired"
        case .cameToFront?: "released"
        case nil: "none"
        }
    }

    // MARK: - The UI tests' background delivery (RD24 decision 9)

    /// "Deliver background refresh": only when the recording scheduler
    /// holds a pending request, the clock moves to that request's earliest
    /// start and one background run is made while the app is in front.
    /// Nothing else delivers a run on the simulator (assumption A2).
    func deliverBackgroundRefreshForUITests() async {
        defer { deliveriesHandled += 1 }
        guard let scheduler = scheduler as? RecordingBackgroundScheduler, let earliest = scheduler.pending, let debugClock else { return }
        debugClock.move(to: earliest)
        await refreshInBackground()
    }

    private func adultStoreIsListed() async -> Bool {
        guard let uiTestAdultStore else { return false }
        return await WKWebsiteDataStore.allDataStoreIdentifiers.contains(uiTestAdultStore)
    }
    #endif
}

/// A workspace held weakly: what a configuration context names as its own
/// before and after the workspace exists (RD20).
@MainActor
final class WeakWorkspace {
    /// The partition of the workspace named, known also once it is gone.
    let partition: Partition
    weak var value: Workspace?

    init(partition: Partition) {
        self.partition = partition
    }
}
