import Foundation
@testable import NewsPawKit
import Testing
import WebKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A web view in a window of its own, loaded with an HTML string at
/// `http://127.0.0.1/` (nothing is served; page scripts run), with the
/// page translation bridge and a way to run the page's own script for the
/// test's checks. Tests only: the sources' scans do not read this file.
@MainActor
final class ScriptPage: NSObject, WKNavigationDelegate {
    static let base = URL(string: "http://127.0.0.1/")!
    static let width: CGFloat = 390
    static let height: CGFloat = 700

    let webView: WKWebView
    let bridge: PageScriptBridge
    #if canImport(UIKit)
    private var window: UIWindow?
    #else
    private var window: NSWindow?
    #endif
    private var finished: [CheckedContinuation<Void, Never>] = []
    private var loads = 0

    init(deadline: Duration = .seconds(60)) {
        webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.height),
            configuration: BrowserConfiguration.make(dataStore: .nonPersistent())
        )
        bridge = PageScriptBridge(webView: webView, deadline: deadline)
        super.init()
        webView.navigationDelegate = self
        #if canImport(UIKit)
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
            let host = UIViewController()
            host.view.addSubview(webView)
            window.rootViewController = host
            window.isHidden = false
            self.window = window
        }
        #else
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height), styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = webView
        self.window = window
        #endif
    }

    /// Loads `html` and returns once it has finished loading.
    func load(_ html: String, address: URL = ScriptPage.base) async {
        loads += 1
        webView.loadHTMLString(html, baseURL: address)
        await withCheckedContinuation { finished.append($0) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let waiting = finished
        finished = []
        waiting.forEach { $0.resume() }
    }

    /// Runs `body` in the page's own world and returns its answer.
    @discardableResult
    func page(_ body: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
    }

    func pageString(_ body: String) async throws -> String {
        try #require(try await page(body) as? String)
    }

    func pageInt(_ body: String) async throws -> Int {
        try #require((try await page(body) as? NSNumber)?.intValue)
    }

    /// The document's markup as the page serialises it.
    func markup() async throws -> String {
        try await pageString("return document.documentElement.outerHTML")
    }

    /// The token of the script state the last `collect` answered from;
    /// `apply` carries it unless a request names one.
    private(set) var token: String?

    /// One `collect`, which must succeed.
    func collect(sourceLocation: SourceLocation = #_sourceLocation) async throws -> PageCollection {
        switch await bridge.collect() {
        case .success(let collection):
            token = collection.state
            return collection
        case .failure(let failure):
            Issue.record("collect failed: \(failure)", sourceLocation: sourceLocation)
            throw failure
        }
    }

    /// The runs of one `collect`; empty for an unchanged or held answer.
    func runs(sourceLocation: SourceLocation = #_sourceLocation) async throws -> [PageRun] {
        if case .runs(let runs, _, _, _) = try await collect(sourceLocation: sourceLocation) {
            return runs
        }
        return []
    }

    func apply(_ request: PageApplyRequest, sourceLocation: SourceLocation = #_sourceLocation) async throws -> PageApplied {
        var request = request
        if request.state == nil {
            request.state = token
        }
        switch await bridge.apply(request) {
        case .success(let applied): return applied
        case .failure(let failure):
            Issue.record("apply failed: \(failure)", sourceLocation: sourceLocation)
            throw failure
        }
    }

    func end(restore: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) async throws -> PageEnded {
        switch await bridge.end(restore: restore) {
        case .success(let ended): return ended
        case .failure(let failure):
            Issue.record("end failed: \(failure)", sourceLocation: sourceLocation)
            throw failure
        }
    }

    /// Writes "T:" before each run's text, as the model stand-ins do.
    func translateAll(_ runs: [PageRun]) async throws -> PageApplied {
        try await apply(PageApplyRequest(writes: runs.map { PageWrite(id: $0.id, text: "T:" + $0.text) }))
    }

    /// Waits until the page's rendering has settled after a change.
    func settle() async throws {
        // Not an animation frame: a web view in a window that is not on
        // screen may never draw one. Layout is forced by reading a size
        // (not through a function the probe page overrides).
        try await page("void document.documentElement.offsetHeight; await new Promise(resolve => setTimeout(resolve, 50))")
    }
}
