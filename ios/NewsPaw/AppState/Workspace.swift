import Foundation
import NewsPawKit
import UIKit
import WebKit

/// What every workspace of the app is built with: the transport, the clock,
/// the shared refresh, reading and translation settings and the normal
/// library's models, which Settings › Models & Translation shows in either
/// partition. Nothing of it holds a library's content (RD18 decision 3).
/// Each workspace is given its own library's models besides (RD19
/// decision 1).
@MainActor
struct WorkspaceParts {
    let transport: any Transport
    /// How long Add source waits for a candidate.
    let candidateLimit: Duration
    let now: @Sendable () -> Date
    let refreshSettings: RefreshSettings
    /// The reading settings (RD11 decision 10): device settings, one object
    /// for the app, so that a change made in one partition is the other's
    /// too.
    let readingSettings: ReadingSettings
    /// The model slots of the normal library: Settings › Models &
    /// Translation is the normal partition's in either partition (ux S8).
    /// Nothing of a workspace is translated through them but the normal
    /// workspace's own.
    let normalModels: LibraryModels
    /// The translation settings (RD14 decision 1): global, one object for
    /// the app.
    let translationSettings: TranslationSettings
    /// The requests page translation sends in one period (RD16 decision
    /// 11): `PageTranslator.standardCeiling`, lowered only by a UI test.
    let pageCeiling: Int
    /// Called after a slot of `normalModels` changed, from the Settings of
    /// any workspace: the normal library's translation resumes.
    let slotsChanged: @MainActor () -> Void
    /// The app's partition operation state (RD19 review round 4): one
    /// object for the app, so that each workspace's models see an
    /// operation whichever workspace began it.
    let operations: PartitionOperationState
}

/// How a workspace's embedded browser is set up.
@MainActor
struct BrowserSetup {
    /// The website data store of every session of the workspace.
    var dataStore: WKWebsiteDataStore
    var addressMap = BrowserAddressMap()
    var schemeHandlers: [String: any WKURLSchemeHandler] = [:]
    /// False in the adult workspace (RD18 decision 13).
    var allowsPictureInPicture = true
}

/// An operation that needs the adult library and began in the normal
/// partition (RD19 decision 9; RD20 decision 7): it is carried through
/// the partition switch's own unlock and handed to the adult workspace
/// once that is shown. It lives only in that call and then in the adult
/// workspace, so that a lock drops it.
enum PendingAdultOperation {
    /// Moving the normal category of this identifier to the adult
    /// partition.
    case move(categoryID: UUID)
    /// A configuration file with the adult partition, read in the normal
    /// partition: the adult workspace builds its preview.
    case importConfiguration(ConfigurationDocument)
}

/// What an unlock asked for by `AppModel.chooseAdult(pending:)` came to.
enum AdultUnlockOutcome: Equatable {
    /// The adult workspace is shown, and a pending operation was handed to
    /// it.
    case unlocked
    /// The authentication did not pass: cancelled, failed, interrupted, or
    /// no passcode.
    case notAuthenticated(AuthenticationAnswer)
    /// Not asked for: the gate is not locked, or another operation or
    /// authentication runs.
    case refused
    /// The background or a lock discarded it.
    case discarded
    /// The adult library could not be opened.
    case couldNotOpen
}

/// Everything the interface builds on one library (RD18 decision 3): the
/// category, source, refresh, reading and browser models, the library's own
/// models and translation (RD19 decision 1), the model-settings models, and
/// its own navigation. The root view shows exactly one workspace; a model
/// of a workspace reads and writes only that workspace's navigation, so a
/// model of the workspace that is not shown cannot close a screen or a
/// sheet of the other.
@MainActor
final class Workspace: Identifiable {
    let partition: Partition
    let navigation = NavigationModel()
    /// The library's own models: every translator of the workspace is made
    /// from them, and the library's text goes through no other.
    let models: LibraryModels
    let categories: CategoryModel
    let sources: SourceModel
    let refresh: RefreshModel
    let reading: ReadingModel
    let browser: BrowserModel
    /// Settings › Models & Translation: the normal library's slots, in
    /// either partition (ux S8).
    let modelSettings: ModelSettingsModel
    /// The adult library's slots in Settings › Adult Partition (ux S10;
    /// RD19 decision 2): the adult workspace's only.
    let partitionModelSettings: ModelSettingsModel?
    /// Settings › Usage (RD17 decision 1): built on this workspace's own
    /// library, never on `WorkspaceParts.normalModels` or another library.
    let usage: UsageModel
    /// The app's one reading settings object, shared by every workspace.
    let readingSettings: ReadingSettings
    /// The app's one translation settings object, shared by every workspace.
    let translationSettings: TranslationSettings
    /// Translation of this workspace's library (RD14 decision 12), through
    /// its own models (RD19 decision 1): with no slot of its own the
    /// library's rows show originals; nothing of it is ever sent through
    /// another library's models.
    let translation: TranslationModel
    /// The configuration file's export and import (RD20): only the adult
    /// workspace's may write the adult library.
    let configuration: ConfigurationModel

    /// - Parameters:
    ///   - models: the library's own models; another library's are a
    ///     programming error.
    ///   - configuration: what the configuration model is given (RD20
    ///     decision 7); an adult target outside the adult workspace is a
    ///     programming error.
    init(library: Library, models: LibraryModels, parts: WorkspaceParts, browser setup: BrowserSetup, configuration context: ConfigurationContext) {
        precondition(models.belong(to: library), "the models of another library")
        precondition(context.adult.map { $0.library === library } ?? true, "the adult target of another library")
        partition = library.partition
        self.models = models
        let navigation = navigation
        let categories = CategoryModel(library: library, navigation: navigation, operations: parts.operations)
        let refresh = RefreshModel(library: library, transport: parts.transport, settings: parts.refreshSettings, now: parts.now)
        let sources = SourceModel(
            library: library, transport: parts.transport, candidateLimit: parts.candidateLimit,
            navigation: navigation, categories: categories, refresh: refresh, operations: parts.operations
        )
        // The workspace's one extractor (RD12): its reading model and its
        // browser's reader mode share it, so that one extraction runs at a
        // time per workspace.
        let extractor = PageExtractor()
        let reading = ReadingModel(
            library: library, transport: parts.transport, extractor: extractor, now: parts.now,
            isInFront: { UIApplication.shared.applicationState == .active },
            navigation: navigation, sources: sources, refresh: refresh
        )
        // The browser's page translators (RD16 decision 13) are made, like
        // every translator of the workspace, from its own models (RD19
        // decision 1): the adult workspace's from the adult library's.
        let ceiling = parts.pageCeiling
        let sharedTranslationSettings = parts.translationSettings
        let pages = BrowserPageTranslation(
            makeTranslator: { PageTranslator(models: models, ceiling: ceiling) },
            readingLocale: { sharedTranslationSettings.readingLocale }
        )
        let browser = BrowserModel(
            dataStore: setup.dataStore, navigation: navigation, sources: sources,
            // Reader mode's images are fetched like a body's and not kept:
            // a temporary article writes nothing (RD12 decision 7).
            reader: BrowserReader(
                transport: parts.transport, extractor: extractor,
                images: BodyImageLoader(transport: parts.transport, cache: library.imageCache, stores: false)
            ),
            pages: pages, addressMap: setup.addressMap, schemeHandlers: setup.schemeHandlers,
            allowsPictureInPicture: setup.allowsPictureInPicture
        )
        let modelSettings = ModelSettingsModel(
            models: parts.normalModels, navigation: navigation, operations: parts.operations, formRoute: SettingsRoute.modelSlot
        )
        // The library this workspace is built on: the adult one in the
        // adult workspace. Not `parts.normalModels`' library, which is the
        // normal one in both.
        let usage = UsageModel(library: library, now: parts.now, calendar: .current)
        let partitionModelSettings = library.partition == .adult
            ? ModelSettingsModel(models: models, navigation: navigation, operations: parts.operations, formRoute: SettingsRoute.adultModelSlot)
            : nil
        let translation = TranslationModel(models: models, settings: parts.translationSettings, reading: reading, now: parts.now)
        reading.translationLocale = { [weak translation] in translation?.settings.readingLocale }
        translation.autoTranslateOfSource = { [weak sources] id in sources?.summary(id)?.autoTranslate }
        // The bodies the reading model settles and lets go (RD15).
        reading.onBodySettled = { [weak translation] id, content in translation?.body.bodySettled(id, content: content) }
        reading.onBodyDropped = { [weak translation] id in translation?.body.bodyDropped(id) }
        let sharedReadingSettings = parts.readingSettings
        translation.body.defaultMode = { sharedReadingSettings.defaultDisplayMode }
        // A change of the normal slots resumes the normal library's
        // translation, whichever workspace's Settings made it; a change of
        // the adult slots, the adult library's.
        modelSettings.onSlotsChanged = parts.slotsChanged
        partitionModelSettings?.onSlotsChanged = { [weak translation] in translation?.slotsChanged() }
        categories.onReload = { [weak sources] in await sources?.reload() }
        categories.sourcesOf = { [weak sources] id in Set(sources?.sources(in: id).map(\.id) ?? []) }
        refresh.onListsChanged = { [weak sources] in await sources?.reload() }
        refresh.onStorageError = { [weak sources] in sources?.isShowingSaveError = true }
        refresh.onRunEnded = { [weak reading, weak translation] in
            reading?.runEnded()
            translation?.refreshEnded()
        }
        sources.onSettingsSaved = { [weak reading] in reading?.sourceSettingsSaved() }
        navigation.onListEntered = { [weak reading] list in reading?.entered(list) }
        navigation.onSearchStarted = { [weak reading] in reading?.dropSearch() }
        navigation.isWebPageSource = { [weak sources] id in sources?.summary(id)?.kind == .webpage }
        navigation.onStacksChanged = { [weak browser] in browser?.stacksChanged() }
        browser.onTemporaryArticleEnded = { [weak translation] id in translation?.body.readerClosed(id) }
        navigation.onSettingsPathChanged = { [weak modelSettings, weak partitionModelSettings] path in
            modelSettings?.settingsPathChanged(path)
            partitionModelSettings?.settingsPathChanged(path)
        }
        navigation.sourceOfArticle = { [weak reading] id in reading?.source(ofArticle: id) }
        // "Open Settings" of a translation question opens this library's
        // own slots: the adult ones are in Settings › Adult Partition.
        navigation.modelSettingsRoute = library.partition == .adult ? .adultPartition : .models
        self.categories = categories
        self.sources = sources
        self.refresh = refresh
        self.reading = reading
        self.browser = browser
        self.modelSettings = modelSettings
        self.partitionModelSettings = partitionModelSettings
        self.usage = usage
        self.translation = translation
        configuration = ConfigurationModel(partition: library.partition, context: context, navigation: navigation, sources: sources)
        readingSettings = parts.readingSettings
        translationSettings = parts.translationSettings
    }

    /// Reads what the root screens show: the categories (and with them the
    /// sources), the recorded refresh time, the list settings and the model
    /// slots.
    func load() async {
        await categories.reload()
        await refresh.load()
        await reading.loadSettings()
        await modelSettings.reload()
        await partitionModelSettings?.reload()
        await translation.start()
    }

    /// The workspace was just shown with an operation that began in the
    /// other partition (RD19 decision 9): from here on it is this
    /// workspace's, and a lock drops it with the workspace.
    func begin(_ pending: PendingAdultOperation?) {
        switch pending {
        case .move(let id)?:
            categories.beginMove(id, from: .normal)
        case .importConfiguration(let document)?:
            configuration.receive(document)
        case nil:
            break
        }
    }

    /// A configuration import wrote this workspace's library, or the
    /// settings every workspace shares (RD20 decision 7): what the root
    /// screens show is read again, every living list too.
    func reloadAfterImport() async {
        await categories.reload()
        // A Replace deleted categories: a route or a sheet that showed one
        // closes as after an ordinary deletion (review round 1, G3). Source
        // routes are closed by the sources' reload.
        if categories.loadState == .loaded {
            let existing = Set(categories.summaries.map(\.category.id))
            for case .category(let id) in navigation.libraryPath where !existing.contains(id) {
                navigation.categoryDeleted(id, sources: [])
            }
            if case .categorySettings(let id)? = navigation.sheet, !existing.contains(id) {
                navigation.sheet = nil
            }
        }
        // Replace may have changed a source's options, as a save of its
        // settings does: the remembered page failures are forgotten the
        // same way, so that the next opening fetches again (review round 2).
        reading.sourceSettingsSaved()
        await refresh.load()
        await reading.loadSettings()
        await modelSettings.reload()
        await partitionModelSettings?.reload()
        await reading.reloadAllLists()
    }

    /// A category was moved out of this workspace's library (RD19 decision
    /// 11): every route that shows it, a moved source or an article of
    /// one is closed, and every living list is read again, before the
    /// library's image cache is cleared.
    func letGo(ofMoved sources: Set<UUID>, category: UUID) async {
        navigation.close(showing: sources, category: category)
        await reading.reloadAllLists()
    }

    /// The workspace is dropped (RD18 decision 4), before its library is
    /// closed: its refresh run and its source detection are cancelled, a
    /// running model test is cancelled, the reading model's body reads,
    /// conversions, page fetches and extractions are cancelled and it
    /// starts no new one, stores no extraction and asks for no body image,
    /// and its browser sessions are ended with their web views taken out
    /// of the view tree and their reader mode with them; its translation's
    /// request in flight is cancelled and none starts; its usage screen
    /// keeps no result of a read or a write in flight and starts none.
    /// Image loads belong to the rows' own
    /// tasks and end with the views. A save that is still
    /// queued is not cancelled: it runs into the closed library, fails,
    /// and says so nowhere, because a stopped model raises no alert. UIKit
    /// may keep the model objects for a while (assumption A4); they do
    /// nothing by themselves from here on.
    func stop() {
        categories.stop()
        sources.stop()
        refresh.stop()
        reading.stop()
        browser.stop()
        translation.stop()
        usage.stop()
        configuration.stop()
        // Closes the sheet and every pushed screen; the model form, if one
        // was pushed, cancels its running Test or list with its route.
        navigation.clear()
    }
}
