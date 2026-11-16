import Foundation
import WebKit

/// What the extractor found in a page (RD12 decision 1): the article's HTML,
/// cut to `PageExtractor.maximumOutputCharacters`, and its title. Both are
/// untrusted: the HTML is nothing but input for `ArticleBlocks.make`, as a
/// feed's HTML is.
public struct PageExtraction: Sendable, Hashable {
    public var html: String
    public var title: String

    public init(html: String, title: String) {
        self.html = html
        self.title = title
    }
}

/// Why an extraction gave nothing.
public enum ExtractionFailure: Error, Sendable, Hashable {
    /// The input had more than `PageExtractor.maximumInputCharacters`
    /// characters; no web view was made.
    case inputTooLarge
    /// The document had more than `PageExtractor.maximumElements`
    /// elements; it was not cloned.
    case tooManyElements
    /// The extraction's deadline passed.
    case timedOut
    /// The web content process ended.
    case processEnded
    /// The one load of the page failed.
    case loadFailed
    /// The evaluation raised an error, or gave something that is not the
    /// two strings it builds.
    case scriptFailed
    /// Readability found no article (a null result).
    case noArticle
    /// The block-everything rule list could not be compiled or looked up:
    /// no extraction runs without it.
    case ruleListUnavailable
}

/// Something that reduces a page's HTML to its article: `PageExtractor`, or
/// a stand-in in the tests of what uses it.
@MainActor
public protocol PageExtracting: AnyObject {
    /// The article of `html`, a page fetched from `address`.
    ///
    /// - Throws: an `ExtractionFailure`, or `CancellationError` when the
    ///   calling task is cancelled.
    func extract(html: String, address: URL) async throws -> PageExtraction
}

/// The one place a page's HTML is reduced to its article (spec N05, N12;
/// RD12 decision 1). Static by construction: for each extraction it makes a
/// web view of its own and discards it afterwards, with
///
/// - a non-persistent website data store made for this extraction;
/// - page JavaScript off;
/// - a content rule list that blocks every load (`url-filter` ".*"),
///   compiled once into the system's rule-list store and reused; it holds
///   nothing of any page;
/// - no message handler and no user script;
/// - exactly one navigation allowed, the load of the string with its
///   address as the base, and every other cancelled in any frame (a link,
///   a `meta` refresh, a form, a frame's content);
/// - when that load finishes, one evaluation in a content world of the
///   app's own: it counts the document's elements and stops above
///   `maximumElements`; else it evaluates the bundled Readability source
///   and calls it on a clone made with `Document.prototype.cloneNode`, and
///   returns the article's HTML and title, each built as a string.
///
/// The page's own scripts never run and nothing it names is requested. An
/// input over `maximumInputCharacters` is refused before a web view exists;
/// the whole extraction has `deadline`; one extraction runs at a time per
/// extractor, and the app makes one extractor per workspace.
@MainActor
public final class PageExtractor: PageExtracting {
    /// The longest input accepted, in characters (Unicode scalars).
    public static let maximumInputCharacters = 3_000_000
    /// The most elements a document may have to be cloned and read.
    public static let maximumElements = 50_000
    /// The returned HTML is cut to this many characters.
    public static let maximumOutputCharacters = 2_000_000
    /// The time an extraction has, from its web view's making to its
    /// result.
    public static let standardDeadline = Duration.seconds(10)

    /// The identifier of the compiled rule list in its store.
    static let ruleListIdentifier = "newspaw-extractor-block-all-v1"
    /// Blocks every load of every resource type.
    static let blockEverything = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
    /// The content world the evaluation runs in: the app's own, never the
    /// page's.
    static let contentWorld = "NewsPawExtractor"

    let deadline: Duration
    /// False only in the static-rule test's control run, which shows that
    /// the test can see a load. The app has no way to turn it off.
    let usesRuleList: Bool
    private let ruleListStore: WKContentRuleListStore?
    private var ruleList: WKContentRuleList?
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// How many web views this extractor has made, and how many of them
    /// have not been discarded yet; for the tests.
    private(set) var webViewsMade = 0
    private(set) var webViewsHeld = 0
    /// The most extractions that ran at the same moment; for the tests.
    private(set) var mostAtOnce = 0
    private var running = 0

    /// An extractor with the standard deadline, whose rule list is kept in
    /// the system's default rule-list store.
    public convenience init() {
        self.init(deadline: Self.standardDeadline, ruleListStore: WKContentRuleListStore.default())
    }

    init(deadline: Duration, ruleListStore: WKContentRuleListStore?, usesRuleList: Bool = true) {
        self.deadline = deadline
        self.ruleListStore = ruleListStore
        self.usesRuleList = usesRuleList
    }

    public func extract(html: String, address: URL) async throws -> PageExtraction {
        guard html.unicodeScalars.count <= Self.maximumInputCharacters else {
            throw ExtractionFailure.inputTooLarge
        }
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        var list: WKContentRuleList?
        if usesRuleList {
            list = try await compiledRuleList()
            try Task.checkCancellation()
        }
        let source = try readabilitySource()
        let configuration = Self.configuration(ruleList: list)
        running += 1
        mostAtOnce = max(mostAtOnce, running)
        defer { running -= 1 }
        let run = ExtractionRun(
            configuration: configuration, script: Self.script(readability: source), deadline: deadline,
            made: { [weak self] in
                self?.webViewsMade += 1
                self?.webViewsHeld += 1
            },
            discarded: { [weak self] in self?.webViewsHeld -= 1 }
        )
        let extraction = try await run.extract(html: html, address: address)
        return PageExtraction(
            html: String(String.UnicodeScalarView(extraction.html.unicodeScalars.prefix(Self.maximumOutputCharacters))),
            title: extraction.title
        )
    }

    // MARK: - One at a time

    private func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    // MARK: - Set-up

    /// The configuration of an extraction's web view: a store of its own,
    /// page scripts off, a fresh content controller with the rule list and
    /// nothing else (no message handler, no user script).
    static func configuration(ruleList: WKContentRuleList?) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = WKUserContentController()
        // The one `add` of the app: `BrowserScanTests` allows it here and
        // nowhere else.
        if let ruleList {
            configuration.userContentController.add(ruleList)
        }
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        return configuration
    }

    /// The compiled block-everything list: looked up in its store, and
    /// compiled there once when it is not.
    private func compiledRuleList() async throws -> WKContentRuleList {
        if let ruleList {
            return ruleList
        }
        guard let store = ruleListStore else {
            throw ExtractionFailure.ruleListUnavailable
        }
        var found: WKContentRuleList?
        if let stored = try? await store.contentRuleList(forIdentifier: Self.ruleListIdentifier) {
            found = stored
        } else {
            found = try? await store.compileContentRuleList(
                forIdentifier: Self.ruleListIdentifier, encodedContentRuleList: Self.blockEverything
            )
        }
        guard let found else {
            throw ExtractionFailure.ruleListUnavailable
        }
        ruleList = found
        return found
    }

    private func readabilitySource() throws -> String {
        do {
            return try ReadabilityScript.source()
        } catch {
            throw ExtractionFailure.scriptFailed
        }
    }

    /// The body of the one evaluation. Every call it makes on the document
    /// is taken from a prototype, so that a page cannot replace it by
    /// naming an element (`<img name="cloneNode">`).
    static func script(readability: String) -> String {
        """
        var all = Document.prototype.getElementsByTagName.call(document, "*");
        var count = Object.getOwnPropertyDescriptor(HTMLCollection.prototype, "length").get.call(all);
        all = null;
        if (count > \(maximumElements)) {
            return { refused: count };
        }
        \(readability)
        var clone = Document.prototype.cloneNode.call(document, true);
        var article = new Readability(clone).parse();
        if (!article || article.content == null) {
            return null;
        }
        return {
            html: String(article.content),
            title: article.title == null ? "" : String(article.title)
        };
        """
    }
}

/// One extraction: its web view, its one navigation, its deadline and its
/// result. The web view is discarded when the result is known, whatever it
/// is.
@MainActor
private final class ExtractionRun: NSObject, WKNavigationDelegate {
    private let configuration: WKWebViewConfiguration
    private let script: String
    private let deadline: Duration
    private let made: () -> Void
    private let discarded: () -> Void
    private var webView: WKWebView?
    private var navigation: WKNavigation?
    private var navigationsLeft = 1
    private var continuation: CheckedContinuation<PageExtraction, any Error>?
    private var timer: Task<Void, Never>?
    private var isOver = false

    init(
        configuration: WKWebViewConfiguration, script: String, deadline: Duration, made: @escaping () -> Void,
        discarded: @escaping () -> Void
    ) {
        self.configuration = configuration
        self.script = script
        self.deadline = deadline
        self.made = made
        self.discarded = discarded
    }

    func extract(html: String, address: URL) async throws -> PageExtraction {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(html: html, address: address, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func start(html: String, address: URL, continuation: CheckedContinuation<PageExtraction, any Error>) {
        // Cancelled before it started: nothing is made.
        guard !isOver, !Task.isCancelled else {
            isOver = true
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView
        made()
        let deadline = deadline
        timer = Task { [weak self] in
            try? await Task.sleep(for: deadline)
            guard !Task.isCancelled else { return }
            self?.finish(.failure(ExtractionFailure.timedOut))
        }
        navigation = webView.loadHTMLString(html, baseURL: address)
    }

    /// Ends the extraction with `result`, once: the timer stops and the web
    /// view is discarded before the caller hears of it.
    private func finish(_ result: Result<PageExtraction, any Error>) {
        guard !isOver else { return }
        isOver = true
        timer?.cancel()
        timer = nil
        if let webView {
            webView.stopLoading()
            webView.navigationDelegate = nil
            self.webView = nil
            discarded()
        }
        continuation?.resume(with: result)
        continuation = nil
    }

    private func evaluate() {
        guard let webView, !isOver else { return }
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .world(name: PageExtractor.contentWorld)) { [weak self] result in
            MainActor.assumeIsolated {
                self?.finish(Self.read(result))
            }
        }
    }

    /// The evaluation's answer: the two strings, the element bound, a null
    /// result, or anything else as a script failure.
    private static func read(_ result: Result<Any, any Error>) -> Result<PageExtraction, any Error> {
        switch result {
        case .failure:
            return .failure(ExtractionFailure.scriptFailed)
        case .success(let value):
            if value is NSNull {
                return .failure(ExtractionFailure.noArticle)
            }
            guard let object = value as? [String: Any] else {
                return .failure(ExtractionFailure.scriptFailed)
            }
            if object["refused"] != nil {
                return .failure(ExtractionFailure.tooManyElements)
            }
            guard let html = object["html"] as? String, let title = object["title"] as? String else {
                return .failure(ExtractionFailure.scriptFailed)
            }
            return .success(PageExtraction(html: html, title: title))
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        // The load of the string, and nothing after it, in any frame.
        guard navigationsLeft > 0, action.targetFrame?.isMainFrame == true, !isOver else {
            return .cancel
        }
        navigationsLeft -= 1
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === self.navigation else { return }
        evaluate()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        guard navigation === self.navigation else { return }
        finish(.failure(ExtractionFailure.loadFailed))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        guard navigation === self.navigation else { return }
        finish(.failure(ExtractionFailure.loadFailed))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(ExtractionFailure.processEnded))
    }
}
