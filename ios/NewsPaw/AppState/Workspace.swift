import Foundation
import NewsPawKit
import UIKit
import WebKit

/// What every workspace of the app is built with: the transport, the clock,
/// the shared refresh, reading and translation settings and the normal
/// library's models. Nothing of it holds a library's content (RD18
/// decision 3).
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
    let models: LibraryModels
    /// The translation settings (RD14 decision 1): global, one object for
    /// the app.
    let translationSettings: TranslationSettings
    /// Called after a slot of `models` changed, from the Settings of any
    /// workspace: the translation of the models' library resumes.
    let slotsChanged: @MainActor () -> Void
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

/// Everything the interface builds on one library (RD18 decision 3): the
/// category, source, refresh, reading and browser models, a model-settings
/// model, and its own navigation. The root view shows exactly one
/// workspace; a model of a workspace reads and writes only that
/// workspace's navigation, so a model of the workspace that is not shown
/// cannot close a screen or a sheet of the other.
@MainActor
final class Workspace: Identifiable {
    let partition: Partition
    let navigation = NavigationModel()
    let categories: CategoryModel
    let sources: SourceModel
    let refresh: RefreshModel
    let reading: ReadingModel
    let browser: BrowserModel
    let modelSettings: ModelSettingsModel
    /// The app's one reading settings object, shared by every workspace.
    let readingSettings: ReadingSettings
    /// The app's one translation settings object, shared by every workspace.
    let translationSettings: TranslationSettings
    /// Translation of this workspace's library (RD14 decision 12): only when
    /// the library has its own models. The adult library has none until
    /// RD19, so its workspace has none and shows originals; nothing of it
    /// is ever sent through the normal library's models.
    let translation: TranslationModel?

    init(library: Library, parts: WorkspaceParts, browser setup: BrowserSetup) {
        partition = library.partition
        let navigation = navigation
        let categories = CategoryModel(library: library, navigation: navigation)
        let refresh = RefreshModel(library: library, transport: parts.transport, settings: parts.refreshSettings, now: parts.now)
        let sources = SourceModel(
            library: library, transport: parts.transport, candidateLimit: parts.candidateLimit,
            navigation: navigation, categories: categories, refresh: refresh
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
        let browser = BrowserModel(
            dataStore: setup.dataStore, navigation: navigation, sources: sources,
            // Reader mode's images are fetched like a body's and not kept:
            // a temporary article writes nothing (RD12 decision 7).
            reader: BrowserReader(
                transport: parts.transport, extractor: extractor,
                images: BodyImageLoader(transport: parts.transport, cache: library.imageCache, stores: false)
            ),
            addressMap: setup.addressMap, schemeHandlers: setup.schemeHandlers,
            allowsPictureInPicture: setup.allowsPictureInPicture
        )
        let modelSettings = ModelSettingsModel(models: parts.models, navigation: navigation)
        let translation = parts.models.belong(to: library)
            ? TranslationModel(models: parts.models, settings: parts.translationSettings, reading: reading, now: parts.now)
            : nil
        reading.translationLocale = { [weak translation] in translation?.settings.readingLocale }
        translation?.autoTranslateOfSource = { [weak sources] id in sources?.summary(id)?.autoTranslate }
        modelSettings.onSlotsChanged = parts.slotsChanged
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
        navigation.isWebPageSource = { [weak sources] id in sources?.summary(id)?.kind == .webpage }
        navigation.onStacksChanged = { [weak browser] in browser?.stacksChanged() }
        navigation.onSettingsPathChanged = { [weak modelSettings] path in modelSettings?.settingsPathChanged(path) }
        self.categories = categories
        self.sources = sources
        self.refresh = refresh
        self.reading = reading
        self.browser = browser
        self.modelSettings = modelSettings
        self.translation = translation
        readingSettings = parts.readingSettings
        translationSettings = parts.translationSettings
    }

    /// Reads what the root screens show: the categories (and with them the
    /// sources), the recorded refresh time and the model slots.
    func load() async {
        await categories.reload()
        await refresh.load()
        await modelSettings.reload()
        await translation?.start()
    }

    /// The workspace is dropped (RD18 decision 4), before its library is
    /// closed: its refresh run and its source detection are cancelled, a
    /// running model test is cancelled, the reading model's body reads,
    /// conversions, page fetches and extractions are cancelled and it
    /// starts no new one, stores no extraction and asks for no body image,
    /// and its browser sessions are ended with their web views taken out
    /// of the view tree and their reader mode with them; its translation's
    /// request in flight is cancelled and none starts. Image loads belong to the rows' own
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
        translation?.stop()
        // Closes the sheet and every pushed screen; the model form, if one
        // was pushed, cancels its running Test or list with its route.
        navigation.clear()
    }
}
