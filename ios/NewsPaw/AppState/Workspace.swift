import Foundation
import NewsPawKit
import WebKit

/// What every workspace of the app is built with: the transport, the clock,
/// the shared refresh settings and the normal library's models. Nothing of
/// it holds a library's content (RD18 decision 3).
@MainActor
struct WorkspaceParts {
    let transport: any Transport
    /// How long Add source waits for a candidate.
    let candidateLimit: Duration
    let now: @Sendable () -> Date
    let refreshSettings: RefreshSettings
    /// The model slots of the normal library: Settings › Models &
    /// Translation is the normal partition's in either partition (ux S8).
    let models: LibraryModels
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

    init(library: Library, parts: WorkspaceParts, browser setup: BrowserSetup) {
        partition = library.partition
        let navigation = navigation
        let categories = CategoryModel(library: library, navigation: navigation)
        let refresh = RefreshModel(library: library, transport: parts.transport, settings: parts.refreshSettings, now: parts.now)
        let sources = SourceModel(
            library: library, transport: parts.transport, candidateLimit: parts.candidateLimit,
            navigation: navigation, categories: categories, refresh: refresh
        )
        let reading = ReadingModel(
            library: library, transport: parts.transport, navigation: navigation, sources: sources, refresh: refresh
        )
        let browser = BrowserModel(
            dataStore: setup.dataStore, navigation: navigation, sources: sources,
            addressMap: setup.addressMap, schemeHandlers: setup.schemeHandlers,
            allowsPictureInPicture: setup.allowsPictureInPicture
        )
        let modelSettings = ModelSettingsModel(models: parts.models, navigation: navigation)
        categories.onReload = { [weak sources] in await sources?.reload() }
        categories.sourcesOf = { [weak sources] id in Set(sources?.sources(in: id).map(\.id) ?? []) }
        refresh.onListsChanged = { [weak sources] in await sources?.reload() }
        refresh.onStorageError = { [weak sources] in sources?.isShowingSaveError = true }
        refresh.onRunEnded = { [weak reading] in reading?.runEnded() }
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
    }

    /// Reads what the root screens show: the categories (and with them the
    /// sources), the recorded refresh time and the model slots.
    func load() async {
        await categories.reload()
        await refresh.load()
        await modelSettings.reload()
    }

    /// The workspace is dropped (RD18 decision 4): its refresh run and its
    /// source detection are cancelled, a running model test is cancelled,
    /// and its browser sessions are ended with their web views taken out of
    /// the view tree. Image loads belong to the rows' own tasks and end
    /// with the views. After this the workspace does nothing by itself, and
    /// it is released, with its library, once the last task that was
    /// running in it has ended.
    func stop() {
        refresh.stop()
        sources.stop()
        browser.stop()
        // Closes the sheet and every pushed screen; the model form, if one
        // was pushed, cancels its running Test or list with its route.
        navigation.clear()
    }
}
