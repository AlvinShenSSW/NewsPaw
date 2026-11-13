import Foundation
import NewsPawKit
import UIKit
import WebKit

/// How the browser turns addresses into what WebKit loads and back. The
/// identity, except under the UI tests' fixtures, where `http` and `https`
/// are served by the fixture scheme: the policy and the bars still see
/// `https` (RD10 "Fixtures").
struct BrowserAddressMap {
    /// The address WebKit loads for one the app or a page names.
    var toWebKit: (URL) -> URL = { $0 }
    /// The address shown and decided on, for one WebKit reports.
    var toShown: (URL) -> URL = { $0 }
    /// Whether WebKit asked for this address would make a real request
    /// while the fixtures are on; never true without them.
    var reachesNetwork: (URL) -> Bool = { _ in false }
}

/// Another app's link waiting for the owner's answer (decision 5).
struct BrowserQuestion: Identifiable {
    let url: URL
    let id = UUID()

    /// The scheme the question names, as in `mailto`.
    var scheme: String {
        url.scheme ?? ""
    }
}

/// A file the browser refused (decision 5): its address, which Open in
/// Safari opens.
struct BrowserFileNotice: Identifiable {
    let url: URL?
    let id = UUID()
}

/// The page the browser could not show (decision 7).
struct BrowserFailure: Equatable {
    enum Kind: Equatable {
        /// The page could not be loaded; the page shown before is still
        /// there behind the failure.
        case load
        /// The web content process ended.
        case processEnded
    }

    let kind: Kind
    /// The failed address.
    let url: URL?
    /// The system's reason, in one line.
    let reason: String
}

/// The embedded browser of the app (spec N12; RD10): the live session of the
/// Library stack and of the Starred stack, the question and the notice the
/// pages raise, and the website data store every session uses. At app
/// level beside the reading model, so a container switch keeps each session
/// and its history.
@MainActor @Observable
final class BrowserModel {
    private(set) var librarySession: BrowserSession?
    private(set) var starredSession: BrowserSession?
    /// Another app's link waiting for "Open" or "Cancel".
    var question: BrowserQuestion?
    /// The file notice shown.
    var fileNotice: BrowserFileNotice?
    /// Whether "No app on this device can open this link." is shown.
    var isShowingNoApp = false

    /// The one store of every session: the system's default persistent
    /// store for the normal library, a non-persistent one under the UI
    /// tests. The browser never chooses between stores (RD19 hands the
    /// adult library's model its own).
    @ObservationIgnored let dataStore: WKWebsiteDataStore
    @ObservationIgnored let addressMap: BrowserAddressMap
    @ObservationIgnored private let schemeHandlers: [String: any WKURLSchemeHandler]
    @ObservationIgnored private let navigation: NavigationModel
    @ObservationIgnored private let sources: SourceModel

    init(
        dataStore: WKWebsiteDataStore, navigation: NavigationModel, sources: SourceModel,
        addressMap: BrowserAddressMap = BrowserAddressMap(), schemeHandlers: [String: any WKURLSchemeHandler] = [:]
    ) {
        self.dataStore = dataStore
        self.navigation = navigation
        self.sources = sources
        self.addressMap = addressMap
        self.schemeHandlers = schemeHandlers
    }

    func session(_ stack: BrowserStack) -> BrowserSession? {
        stack == .starred ? starredSession : librarySession
    }

    // MARK: - Sessions

    /// A stack changed: the browser route on top of each stack has its
    /// session, started at the route's address; a session whose route left
    /// its stack ends (decision 3).
    func stacksChanged() {
        sync(.library)
        sync(.starred)
    }

    private func sync(_ stack: BrowserStack) {
        let route = navigation.browserRoute(of: stack)
        let current = session(stack)
        guard current?.route != route else { return }
        current?.end()
        var next: BrowserSession?
        if let route, let start = address(of: route) {
            var sourceID: UUID?
            if case .source(let id) = route {
                sourceID = id
            }
            next = BrowserSession(route: route, sourceID: sourceID, model: self, configuration: configuration())
            next?.load(start)
        }
        if stack == .starred {
            starredSession = next
        } else {
            librarySession = next
        }
    }

    /// Where a browser route starts: the article's page, or the web-page
    /// source's address.
    private func address(of route: LibraryRoute) -> URL? {
        switch route {
        case .page(let url):
            return url
        case .source(let id):
            return sources.summary(id).flatMap { URL(string: $0.address) }
        case .allUnread, .category, .article:
            return nil
        }
    }

    private func configuration() -> WKWebViewConfiguration {
        BrowserConfiguration.make(dataStore: dataStore, schemeHandlers: schemeHandlers)
    }

    // MARK: - Questions and notices

    /// Whether a question or a notice may be raised now: only while no
    /// sheet (nor the slide-over's cover) is open and nothing else of the
    /// browser is shown. One raised otherwise is dropped.
    private var mayRaise: Bool {
        navigation.sheet == nil && !navigation.isSlideOverOpen && question == nil && fileNotice == nil && !isShowingNoApp
    }

    /// Another scheme from the main frame or a new-window request: asks.
    func ask(_ url: URL) {
        guard mayRaise else { return }
        question = BrowserQuestion(url: url)
    }

    /// A file, an attachment or a download link: says so.
    func refuseFile(_ url: URL?) {
        guard mayRaise else { return }
        fileNotice = BrowserFileNotice(url: url)
    }

    /// "Open": hands the link to the system; says so when no app opens it.
    func open(_ question: BrowserQuestion) {
        self.question = nil
        Task {
            let opened = await UIApplication.shared.open(question.url)
            if !opened, navigation.sheet == nil {
                isShowingNoApp = true
            }
        }
    }
}

/// One page session of a stack (decision 3): a web view kept here, not in
/// a view, so crossing 700 or 1100 pt re-hosts it with its page and its
/// history. Applies the policy function to every navigation and response
/// and reports title, address, progress and failure to the bars.
@MainActor @Observable
final class BrowserSession: NSObject {
    /// The route the session belongs to; it ends when the route leaves its
    /// stack.
    let route: LibraryRoute
    /// The web-page source the browser was opened from, if any.
    let sourceID: UUID?
    @ObservationIgnored let webView: WKWebView

    private(set) var title = ""
    /// The page's address as WebKit reports it: the address being loaded
    /// from the start of a navigation, the committed page's otherwise.
    private(set) var pageURL: URL?
    /// An address the browser decided to load whose navigation has not
    /// started yet.
    private(set) var pendingURL: URL?
    private(set) var failure: BrowserFailure?
    private(set) var isLoading = false
    private(set) var progress = 0.0
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    @ObservationIgnored private weak var model: BrowserModel?
    @ObservationIgnored private let map: BrowserAddressMap
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// The main-frame navigation in progress and the address it started at.
    @ObservationIgnored private var provisional: (navigation: WKNavigation, url: URL?)?

    init(route: LibraryRoute, sourceID: UUID?, model: BrowserModel, configuration: WKWebViewConfiguration) {
        self.route = route
        self.sourceID = sourceID
        self.model = model
        map = model.addressMap
        webView = WKWebView(frame: .zero, configuration: configuration)
        // No link previews and no swipes: the page's back and forward are
        // the bar's buttons.
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observe()
    }

    private func observe() {
        observations = [
            webView.observe(\.title, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.title = webView.title ?? "" }
            },
            // WebKit reports the address being loaded from the start of a
            // navigation, the committed one again when it fails, and a
            // same-document change (an anchor) that never commits: each
            // replaces an address the browser was still waiting for.
            webView.observe(\.url, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pageURL = webView.url.map(self.map.toShown)
                    self.pendingURL = nil
                }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.isLoading = webView.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.progress = webView.estimatedProgress }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.canGoBack = webView.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.canGoForward = webView.canGoForward }
            },
        ]
    }

    /// The session's route left its stack: the page stops and lets go of
    /// the app.
    func end() {
        observations = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    // MARK: - What the bars show (decision 10)

    /// The address shown: the failed one while the failure state is shown,
    /// the one being loaded until a page commits, else the page's own.
    var shownURL: URL? {
        BrowserAddress.shown(failed: failure?.url, loading: pendingURL, committed: pageURL)
    }

    /// The host under the title, always shown.
    var host: String {
        BrowserAddress.host(of: shownURL)
    }

    /// The page's title in one line; the host while there is none.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return failure == nil && !trimmed.isEmpty ? trimmed : host
    }

    /// Whether the page shown before a load failure is behind the failure
    /// state, so Back returns to it.
    private var failureHidesAPage: Bool {
        failure?.kind == .load && webView.backForwardList.currentItem != nil
    }

    var backEnabled: Bool {
        failureHidesAPage || canGoBack
    }

    var forwardEnabled: Bool {
        canGoForward
    }

    // MARK: - Actions

    /// Loads `url` in the page; it becomes the shown address at once.
    func load(_ url: URL) {
        failure = nil
        pendingURL = url
        webView.load(URLRequest(url: map.toWebKit(url)))
    }

    /// Back: from the failure state, the page behind it; else the page
    /// before.
    func goBack() {
        if failureHidesAPage {
            failure = nil
            return
        }
        failure = nil
        webView.goBack()
    }

    func goForward() {
        failure = nil
        webView.goForward()
    }

    /// Reload: the shown page again; in the failure state, Try Again.
    func reload() {
        if failure != nil {
            tryAgain()
        } else {
            webView.reload()
        }
    }

    /// "Try Again": loads the failed address.
    func tryAgain() {
        guard let url = failure?.url ?? shownURL else { return }
        load(url)
    }

    // MARK: - Policy

    /// Applies the policy function to a navigation; `nil` target means a
    /// new-window request. Returns whether WebKit may go ahead.
    private func decide(
        _ request: URLRequest, kind: BrowserPolicy.NavigationKind, target: BrowserPolicy.TargetFrame, download: Bool
    ) -> Bool {
        guard let raw = request.url else { return false }
        let url = map.toShown(raw)
        let action = BrowserPolicy.Action(
            scheme: BrowserPolicy.SchemeClass(url), kind: kind, target: target,
            sameHost: BrowserPolicy.sameHost(url, shownURL), download: download
        )
        var decision = BrowserPolicy.decide(action)
        // Under the fixtures, a navigation that would reach a real host is
        // loaded through the fixture table instead (or dropped in a frame).
        if decision.allows, map.reachesNetwork(raw) {
            decision = target == .sub ? .cancelSilently : .loadInPlace
        }
        switch decision {
        case .follow, .allowSilently:
            if target == .main {
                pendingURL = url
            }
            return true
        case .loadInPlace:
            // After `.cancel` has been returned.
            Task { @MainActor in self.load(url) }
            return false
        case .cancelSilently:
            return false
        case .ask:
            model?.ask(url)
            return false
        case .refuseAsFile:
            model?.refuseFile(url)
            return false
        }
    }

    /// A failure of the main-frame navigation `navigation`. A navigation the
    /// browser refused (WebKit's 102) or a newer load replaced (-999) is not
    /// a failure.
    private func navigationFailed(_ navigation: WKNavigation?, _ error: any Error) {
        let started = provisional
        // An older navigation ending after a newer one started says nothing
        // about the page shown.
        guard started == nil || started?.navigation === navigation else { return }
        provisional = nil
        pendingURL = nil
        let ns = error as NSError
        // "Frame load interrupted", reported in WebKit's own domain (measured:
        // `WebKitErrorDomain`, not `WKErrorDomain`).
        let refused = ns.domain == "WebKitErrorDomain" && ns.code == 102
        let replaced = ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
        guard !refused, !replaced else { return }
        let failing = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL).map(map.toShown)
        failure = BrowserFailure(kind: .load, url: failing ?? started?.url ?? shownURL, reason: ns.localizedDescription)
    }
}

extension BrowserSession: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        let target: BrowserPolicy.TargetFrame = action.targetFrame.map { $0.isMainFrame ? .main : .sub } ?? .none
        let allowed = decide(
            action.request, kind: action.navigationType == .linkActivated ? .linkActivated : .other,
            target: target, download: action.shouldPerformDownload
        )
        return (allowed ? .allow : .cancel, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
        switch BrowserPolicy.decide(canShowType: response.canShowMIMEType, contentDisposition: disposition) {
        case .allow:
            return .allow
        case .refuseAsFile:
            model?.refuseFile(response.response.url.map(map.toShown))
            return .cancel
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        provisional = (navigation, webView.url.map(map.toShown))
        pendingURL = nil
        failure = nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if provisional?.navigation === navigation {
            provisional = nil
        }
        pendingURL = nil
        failure = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        navigationFailed(navigation, error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        navigationFailed(navigation, error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        provisional = nil
        pendingURL = nil
        failure = BrowserFailure(
            kind: .processEnded, url: shownURL, reason: String(localized: "The page stopped working.")
        )
    }
}

extension BrowserSession: WKUIDelegate {
    /// A new window or tab asked for by a script (`window.open`): the same
    /// policy as a navigation with no target frame; no window is made.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        _ = decide(action.request, kind: action.navigationType == .linkActivated ? .linkActivated : .other, target: .none, download: false)
        return nil
    }

    /// File inputs are answered with cancel: the app offers no file, photo
    /// or camera to a page.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        nil
    }

    /// Camera, microphone and motion sensors are denied: the app declares
    /// no such use, and a page is granted none.
    func webView(
        _ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo,
        type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        .deny
    }

    func webView(
        _ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo
    ) async -> WKPermissionDecision {
        .deny
    }
}
