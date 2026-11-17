import Foundation
import NewsPawKit
import UniformTypeIdentifiers

/// Where a configuration import was started (RD20 decision 8).
enum ConfigurationImportOrigin: Hashable {
    /// Settings › Data.
    case settings
    /// The address step of Add source: it closes, and the import goes on
    /// from the root.
    case addSource
    /// The first run (RD21): the normal partition only, and no question.
    case firstRun
}

/// A list the preview pushes.
enum ConfigurationPreviewGroup: Hashable {
    case new
    case alreadyHere
    case conflicts
}

extension ConfigurationPreviewGroup {
    /// The group's name in accessibility identifiers.
    var identifier: String {
        switch self {
        case .new: "new"
        case .alreadyHere: "alreadyHere"
        case .conflicts: "conflicts"
        }
    }
}

/// A screen pushed inside the import sheet.
enum ConfigurationImportRoute: Hashable {
    case group(ConfigurationPreviewGroup, Partition)
    case settings
    case review
    case deletedSources(Partition)
}

extension UTType {
    /// The configuration file, declared as an exported type in the app's
    /// Info.plist (RD20 assumption A2).
    static let newsPawConfiguration = UTType(exportedAs: "io.newspaw.reader.configuration", conformingTo: .json)
}

/// What the app gives a workspace's configuration model (RD20 decision 7):
/// the libraries it may write — the adult one only in the adult workspace —
/// and the steps that belong to `AppModel`.
struct ConfigurationContext {
    let preferences: Preferences
    let normal: ConfigurationTarget
    /// The adult library and the adult key store: only the adult
    /// workspace's context has them.
    let adult: ConfigurationTarget?
    let appVersion: String
    let now: @Sendable () -> Date
    /// The adult partition's gate state now.
    let gateState: @MainActor () -> AdultGate.State
    /// Whether RD18's notice is up: the preview waits for it.
    let noticeIsShown: @MainActor () -> Bool
    /// "Unlock" or "Turn On and Unlock": the partition switch's own unlock
    /// carrying the document, which the adult workspace takes once shown.
    let unlock: @MainActor (ConfigurationDocument) async -> AdultUnlockOutcome
    /// Whether an import's write may not begin now: another import's
    /// write, a category move or turning the partition off runs.
    let writeIsHeldBack: @MainActor () -> Bool
    /// Whether an import's write may begin now; marks it begun.
    let beginWrite: @MainActor () -> Bool
    /// `AppModel`'s completion, run on the main actor once the write has
    /// ended, whether or not this workspace still exists. Returns whether
    /// the summary may be shown.
    let completion: @MainActor (ConfigurationImportResult) async -> Bool
    /// The summary was left, or the import ended without one: the ordinary
    /// refresh of each workspace whose library was written and that still
    /// exists. Started once per committed import (`ConfigurationModel.owedRefresh`).
    let summaryLeft: @MainActor (ConfigurationImportResult) -> Void
}

/// The configuration file of one workspace (spec N10; RD20 decisions 7 to
/// 9): the export's state, and one import from its file choice to its
/// summary — reading, the adult question, the preview, the review before
/// replacing, the write, the summary. The sheet and the alerts are
/// presented at the workspace's root. A result that arrives after the
/// import ended, or after the workspace was dropped, is not shown.
@MainActor @Observable
final class ConfigurationModel {
    enum Stage: Equatable {
        /// Nothing, or the file picker is up.
        case idle
        /// The file is being read, or the preview built.
        case reading
        /// The file has the adult partition: the question is asked.
        case asking
        /// The unlock runs.
        case unlocking
        case preview
        case importing(ConfigurationImportMode)
        case summary
    }

    /// What the alert at the root says.
    enum Alert: Equatable {
        case refused(ConfigurationRefusal)
        /// The preview could not read a library.
        case storage
    }

    let partition: Partition
    private let context: ConfigurationContext
    private let navigation: NavigationModel
    private let sources: SourceModel

    // MARK: Export

    /// "Include the Adult Partition": off each time Data opens.
    var includesAdult = false
    private(set) var isExporting = false
    /// The file the share sheet shows.
    var exportedFile: URL?
    var exportFailure: ConfigurationExportError?
    /// Whether Settings › Data is on screen: an export that ends after it
    /// went away is removed, not shown.
    var isDataShown = false

    // MARK: Import

    private(set) var origin: ConfigurationImportOrigin?
    var isPickingFile = false
    private(set) var stage = Stage.idle
    var alert: Alert?
    /// Whether the adult question is asked with "Turn On and Unlock".
    private(set) var gateIsOff = false
    /// The document: while the question is asked, the whole file; after
    /// it, in the normal workspace, never its adult part.
    private(set) var document: ConfigurationDocument?
    private(set) var preview: ConfigurationPreview?
    /// The file's adult part was dropped: declined, or no way to it.
    private(set) var adultSkipped = false
    /// The import began in the first run: the adult part is not imported.
    private(set) var adultNotImported = false
    var path: [ConfigurationImportRoute] = []
    /// "Replace now?" is asked.
    var isConfirmingReplace = false
    /// The last write changed nothing; the preview says so.
    private(set) var writeFailed = false
    private(set) var result: ConfigurationImportResult?
    /// The refresh a committed import owes while its summary is shown.
    ///
    /// The rule (review round 2): a committed import's refresh — each
    /// written workspace that still exists refreshes its library — starts
    /// exactly once, however its summary ends or whether it ever appears.
    /// Every way out, and the line that starts it:
    /// - the summary will not be shown (a lock or a partition switch took
    ///   the workspace away before the completion ended): `AppModel`'s
    ///   completion, `configurationImported`, at once;
    /// - the summary may be shown but this import is no longer the current
    ///   one, or this model is gone: `startWrite`, at once;
    /// - the summary is shown and then ends — Done, a swipe, a lock or any
    ///   other drop of the workspace (`stop`), the other partition entered
    ///   (`leftForOtherPartition`): `endImport`, which every one of them
    ///   runs, discharging this.
    private var owedRefresh: ConfigurationImportResult?
    /// The preview is ready and waits for RD18's notice to go.
    private(set) var waitsForNotice = false
    /// Add Source is closing; the picker is presented once it has.
    private(set) var waitsForSheetToClose = false
    private(set) var isStopped = false
    /// Whether this import's sheet was presented.
    private var presentsSheet = false

    /// Raised by every new import and every end, so that a result of an
    /// earlier one is dropped.
    private var token = 0
    private var task: Task<Void, Never>?

    #if DEBUG
    /// Set by the UI tests: "Import Configuration" reads this fixture
    /// instead of presenting the file picker (decision 10).
    var fixture: ConfigurationFixture?
    /// Set by the UI tests: how long the write waits between its end and
    /// its completion, so that a lock can come in between (criterion 13).
    var writePause: Duration?
    /// Set by the UI tests, in the adult workspace only: where its export
    /// waits (review round 2).
    var exportHold: ConfigurationExportHold?
    /// The bytes of the file the share sheet shows.
    private var exportedData: Data?
    /// The report's counts, for every workspace of the launch.
    static var debugExportsWritten = 0
    static var debugExportsEnded = 0
    static var debugExportsShown = 0
    /// At the last share sheet's end: whether its file was still the one
    /// written (`intact`), was overwritten (`replaced`) or was gone
    /// (`missing`), and how many export files had been written by then.
    static var debugShareEnded = "none"
    #endif

    init(partition: Partition, context: ConfigurationContext, navigation: NavigationModel, sources: SourceModel) {
        precondition(context.adult == nil || partition == .adult, "an adult target outside the adult workspace")
        self.partition = partition
        self.context = context
        self.navigation = navigation
        self.sources = sources
    }

    /// Whether the switch can be turned on: only inside the adult
    /// partition (decision 7).
    var canIncludeAdult: Bool {
        context.adult != nil
    }

    /// Whether an import is in progress, from the file choice to the
    /// summary.
    var isImporting: Bool {
        origin != nil
    }

    /// Whether an import can begin: none is in progress here, and no
    /// import's write, category move or turning off runs anywhere — a
    /// preview built meanwhile would be out of date when it ends (review
    /// round 1, R2).
    var canBeginImport: Bool {
        !isStopped && !isImporting && !context.writeIsHeldBack()
    }

    // MARK: - Export (decision 9)

    /// "Export Configuration": the file is built off the main actor,
    /// written as "NewsPaw Configuration <yyyy-MM-dd>.newspaw" into a
    /// directory of its own, and handed to the share sheet. An export that
    /// ends after the workspace was dropped or Data was left removes its
    /// own directory and nothing else (review round 2, P1).
    func export() {
        guard !isExporting, !isStopped else { return }
        isExporting = true
        exportFailure = nil
        let normal = context.normal.library
        let adult = includesAdult ? context.adult?.library : nil
        let preferences = context.preferences
        let appVersion = context.appVersion
        let now = context.now()
        Task {
            defer {
                isExporting = false
                #if DEBUG
                Self.debugExportsEnded += 1
                #endif
            }
            do {
                let data = try await ConfigurationTransfer.export(
                    normal: normal, adult: adult, preferences: preferences, appVersion: appVersion, now: now
                )
                #if DEBUG
                await hold(at: .bytes)
                #endif
                // Not written once the workspace was dropped or Data left
                // (review round 1, R3).
                guard !isStopped, isDataShown else { return }
                #if DEBUG
                await hold(at: .write)
                #endif
                let url = try await Task.detached { try ExportFolder.configuration.write(data, on: now) }.value
                #if DEBUG
                Self.debugExportsWritten += 1
                #endif
                guard !isStopped, isDataShown, exportedFile == nil else {
                    ExportFolder.configuration.remove(url)
                    return
                }
                exportedFile = url
                #if DEBUG
                exportedData = data
                Self.debugExportsShown += 1
                #endif
            } catch let failure as ConfigurationExportError {
                if !isStopped {
                    exportFailure = failure
                }
            } catch {
                // The failed write left nothing of its own.
                if !isStopped {
                    exportFailure = .failed
                }
            }
        }
    }

    /// The share sheet ended, by an activity or by being closed: its
    /// export's directory is removed.
    func exportEnded() {
        guard let url = exportedFile else { return }
        #if DEBUG
        let state: String
        if let shared = try? Data(contentsOf: url) {
            state = shared == exportedData ? "intact" : "replaced"
        } else {
            state = "missing"
        }
        Self.debugShareEnded = "\(state)@\(Self.debugExportsWritten)"
        exportedData = nil
        #endif
        exportedFile = nil
        ExportFolder.configuration.remove(url)
    }

    // MARK: - Import (decision 8)

    /// "Import Configuration" on `origin`. From Add source, the sheet
    /// closes first and the picker follows from the root.
    func beginImport(from origin: ConfigurationImportOrigin) {
        guard canBeginImport else { return }
        token += 1
        self.origin = origin
        stage = .idle
        resetDocument()
        if origin == .addSource, navigation.sheet == .addSource {
            waitsForSheetToClose = true
            sources.addSourceClosed()
            return
        }
        presentPicker()
    }

    /// The root's sheet closed: the picker of an import from Add source
    /// is presented now.
    func sheetDidClose() {
        guard waitsForSheetToClose else { return }
        waitsForSheetToClose = false
        presentPicker()
    }

    private func presentPicker() {
        #if DEBUG
        if let fixture, let url = try? fixture.writeToTemporaryFile() {
            fileChosen(url)
            return
        }
        #endif
        isPickingFile = true
    }

    /// The picker was closed without a file.
    func pickerCancelled() {
        endImport()
    }

    /// Reads the chosen file off the main actor, under its security scope.
    func fileChosen(_ url: URL) {
        guard isImporting else { return }
        isPickingFile = false
        stage = .reading
        let token = token
        task?.cancel()
        task = Task {
            let read = await Task.detached {
                let scoped = url.startAccessingSecurityScopedResource()
                defer {
                    if scoped {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                return ConfigurationFile.read(contentsOf: url)
            }.value
            guard isCurrent(token) else { return }
            switch read {
            case .success(let document):
                documentRead(document)
            case .failure(let refusal):
                stage = .idle
                alert = .refused(refusal)
            }
        }
    }

    /// The picker could not hand a file over.
    func fileCouldNotBeChosen() {
        guard isImporting else { return }
        isPickingFile = false
        alert = .refused(.unreadable)
    }

    /// Decision 7: the file was read in this workspace.
    private func documentRead(_ document: ConfigurationDocument) {
        guard document.includesAdult, partition == .normal else {
            buildPreview(document)
            return
        }
        if origin == .firstRun {
            adultNotImported = true
            buildPreview(document.withoutAdult)
            return
        }
        switch context.gateState() {
        case .unavailable:
            adultSkipped = true
            buildPreview(document.withoutAdult)
        case .off, .locked, .unlocked:
            gateIsOff = context.gateState() == .off
            self.document = document
            stage = .asking
        }
    }

    /// "Unlock" or "Turn On and Unlock". The whole document goes into the
    /// unlock; this model keeps only the normal part while it runs, and
    /// nothing at all once the adult workspace has taken it.
    func unlockChosen() {
        guard stage == .asking, let whole = document else { return }
        let normalPart = whole.withoutAdult
        document = nil
        stage = .unlocking
        let token = token
        task = Task {
            let outcome = await context.unlock(whole)
            guard isCurrent(token) else { return }
            if outcome == .unlocked {
                // The adult workspace has the import now.
                endImport()
                return
            }
            adultSkipped = true
            buildPreview(normalPart)
        }
    }

    /// "Normal Partition Only".
    func normalOnlyChosen() {
        guard stage == .asking, let whole = document else { return }
        adultSkipped = true
        buildPreview(whole.withoutAdult)
    }

    /// The adult workspace was shown with an import that began in the
    /// normal partition (`PendingAdultOperation.importConfiguration`).
    func receive(_ document: ConfigurationDocument) {
        guard !isStopped, partition == .adult else { return }
        token += 1
        origin = .settings
        resetDocument()
        buildPreview(document)
    }

    /// Plans the document against this workspace's libraries.
    private func buildPreview(_ document: ConfigurationDocument) {
        // The normal workspace never compares an adult part.
        let document = context.adult == nil ? document.withoutAdult : document
        self.document = document
        stage = .reading
        let token = token
        let normal = context.normal.library
        let adult = context.adult?.library
        let preferences = context.preferences
        task = Task {
            do {
                let preview = try await ConfigurationTransfer.preview(document, normal: normal, adult: adult, preferences: preferences)
                guard isCurrent(token) else { return }
                self.preview = preview
                stage = .preview
                presentSheet()
            } catch {
                guard isCurrent(token) else { return }
                stage = .idle
                alert = .storage
            }
        }
    }

    /// The sheet is presented once RD18's notice, if any, is gone.
    private func presentSheet() {
        guard stage == .preview || stage == .summary else { return }
        if context.noticeIsShown() {
            waitsForNotice = true
            return
        }
        waitsForNotice = false
        presentsSheet = true
        navigation.sheet = .configurationImport
    }

    /// RD18's notice was dismissed.
    func noticeDismissed() {
        guard waitsForNotice, !isStopped else { return }
        presentSheet()
    }

    /// Whether Merge would write anything.
    var canMerge: Bool {
        stage == .preview && (preview?.mergeWritesSomething ?? false) && !context.writeIsHeldBack()
    }

    var canReplace: Bool {
        stage == .preview && preview != nil && !context.writeIsHeldBack()
    }

    /// Merge: written at once.
    func mergeTapped() {
        guard canMerge else { return }
        startWrite(.merge)
    }

    /// "Replace" on the review: asks a second time.
    func replaceTapped() {
        guard canReplace else { return }
        isConfirmingReplace = true
    }

    /// "Replace" in "Replace now?".
    func replaceConfirmed() {
        isConfirmingReplace = false
        guard canReplace else { return }
        startWrite(.replace)
    }

    /// The write (decision 5): a task that a lock does not cancel. Its
    /// completion is `AppModel`'s; the summary is shown only when that says
    /// so and this import is still the current one.
    private func startWrite(_ mode: ConfigurationImportMode) {
        guard let document, !isStopped, context.beginWrite() else { return }
        let job = ConfigurationImport(document: document, normal: context.normal, adult: context.adult)
        let preferences = context.preferences
        let completion = context.completion
        let token = token
        writeFailed = false
        stage = .importing(mode)
        #if DEBUG
        let pause = writePause
        #endif
        let summaryLeft = context.summaryLeft
        Task { [weak self] in
            let result = await ConfigurationTransfer.run(job, mode: mode, preferences: preferences, completion: { _ in })
            #if DEBUG
            if let pause {
                try? await Task.sleep(for: pause)
            }
            #endif
            // When no summary will be shown, the completion has started the
            // refresh; when one may be, it is owed from here on.
            let showsSummary = await completion(result)
            guard let self, self.isCurrent(token) else {
                if showsSummary {
                    summaryLeft(result)
                }
                return
            }
            if result.changedNothing {
                // Nothing of either partition was written: the preview
                // stays, with the reason, and its buttons work again.
                self.writeFailed = true
                self.stage = .preview
                return
            }
            guard showsSummary else {
                self.endImport()
                return
            }
            self.result = result
            self.owedRefresh = result
            self.path = []
            self.stage = .summary
        }
    }

    /// The import sheet closed, by Cancel, Done or a swipe. Leaving the
    /// summary starts the refresh (in `endImport`).
    func sheetClosed() {
        guard isImporting, presentsSheet, navigation.sheet != .configurationImport else { return }
        if case .importing = stage {
            return
        }
        endImport()
    }

    /// The import ends, whichever way: the question or an alert answered,
    /// the sheet closed, the workspace left or dropped. A summary that was
    /// shown starts the refresh its import owes (`owedRefresh`).
    func endImport() {
        if let owed = owedRefresh {
            owedRefresh = nil
            context.summaryLeft(owed)
        }
        token += 1
        task?.cancel()
        task = nil
        origin = nil
        isPickingFile = false
        stage = .idle
        waitsForSheetToClose = false
        presentsSheet = false
        resetDocument()
        if navigation.sheet == .configurationImport {
            navigation.sheet = nil
        }
    }

    /// The workspace is no longer shown (the other partition was entered):
    /// the import's screens go, a write in flight runs on.
    func leftForOtherPartition() {
        if case .importing = stage {
            return
        }
        guard isImporting else { return }
        endImport()
    }

    private func resetDocument() {
        document = nil
        preview = nil
        result = nil
        adultSkipped = false
        adultNotImported = false
        gateIsOff = false
        path = []
        isConfirmingReplace = false
        writeFailed = false
        waitsForNotice = false
        alert = nil
    }

    private func isCurrent(_ token: Int) -> Bool {
        !isStopped && self.token == token
    }

    /// The workspace is dropped (RD18 decision 4): nothing of the import
    /// is shown from here on; a confirmed write runs to its end.
    func stop() {
        isStopped = true
        endImport()
        // The lock also empties the whole folder; any other drop removes
        // this workspace's own export.
        if let url = exportedFile {
            exportedFile = nil
            ExportFolder.configuration.remove(url)
        }
        exportFailure = nil
    }

    #if DEBUG
    /// Waits where `exportHold` says, at most a minute: after the bytes
    /// were built until this workspace is dropped, or before the file is
    /// written until another export has reached its share sheet.
    private func hold(at stage: ConfigurationExportHold) async {
        guard exportHold == stage else { return }
        let shown = Self.debugExportsShown
        for _ in 0..<600 {
            switch stage {
            case .bytes where isStopped: return
            case .write where Self.debugExportsShown > shown: return
            default: try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// What the UI tests' report says of the document this model holds:
    /// `none`, `normal` (no adult part) or `both`.
    var heldDocumentReport: String {
        guard let document else { return "none" }
        return document.includesAdult ? "both" : "normal"
    }
    #endif
}

#if DEBUG
/// Where the adult workspace's export waits under a UI test (review round
/// 2): `bytes`, after the file's bytes were built, until the workspace is
/// dropped — a lock in the middle of building; `write`, after the checks
/// before the write, until another export has reached its share sheet — a
/// lock in the middle of the write.
enum ConfigurationExportHold: String {
    case bytes
    case write
}
#endif
