#if DEBUG
import Foundation
import WebKit

/// The embedded browser's pages under the UI tests (RD10 "Fixtures"): a
/// scheme handler that serves a fixed table for one fixture scheme, made
/// only in a debug build and only under a UI-test library directory. Every
/// address outside the table fails without a request. Pages use relative
/// links and load nothing from another host; the one absolute link leads
/// to a page of the table on another host, which Add source detects through
/// the fixture transport.
///
/// No page is answered as an attachment: WebKit hands a scheme handler's
/// response to the response policy without its headers (measured), so a
/// `Content-Disposition` cannot be served here. The attachment case is in
/// the policy's table and on the device list.
@MainActor
final class BrowserFixtures: NSObject, WKURLSchemeHandler {
    /// The scheme the fixture pages are served under.
    static let scheme = "newspaw-fixture"
    /// How long the slow page takes to answer.
    static let slowAnswer: TimeInterval = 3

    /// The addresses of the table, as the browser shows them.
    enum Address {
        static let home = "https://nofeed.example.invalid/"
    }

    /// The address WebKit loads for an `http` or `https` address, and back.
    static var map: BrowserAddressMap {
        BrowserAddressMap(
            toWebKit: { url in
                guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return url }
                return replacingScheme(of: url, with: Self.scheme)
            },
            toShown: { url in
                guard url.scheme?.lowercased() == Self.scheme else { return url }
                return replacingScheme(of: url, with: "https")
            },
            reachesNetwork: { url in
                let scheme = url.scheme?.lowercased()
                return scheme == "http" || scheme == "https"
            }
        )
    }

    private static func replacingScheme(of url: URL, with scheme: String) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.scheme = scheme
        return components.url ?? url
    }

    private var stopped = Set<ObjectIdentifier>()
    private var loads = 0
    private var flakyFailed = false

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let id = ObjectIdentifier(task)
        let host = url.host(percentEncoded: false)?.lowercased() ?? ""
        let path = url.path(percentEncoded: false)
        switch (host, path) {
        case ("nofeed.example.invalid", "/"), ("nofeed.example.invalid", ""):
            send(task, html: Self.home)
        case ("nofeed.example.invalid", "/second"):
            send(task, html: Self.page("Second Page", "<p>The second page.</p><p><a href=\"/\">Home</a></p>"))
        case ("nofeed.example.invalid", "/count"):
            loads += 1
            send(task, html: Self.page("Loads \(loads)", """
                <p>This page was loaded \(loads) times.</p>
                <p><a href="#bottom">Jump to the end</a></p>
                <div style="height: 1600px"></div>
                <p id="bottom">The end of the counter page.</p>
                """))
        case ("nofeed.example.invalid", "/slow"):
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.slowAnswer) { [weak self] in
                guard let self, !self.stopped.contains(id) else { return }
                self.send(task, html: Self.page("Slow Page", "<p>This page answered slowly.</p>"))
            }
        case ("nofeed.example.invalid", "/long"):
            let paragraphs = (1...60).map { "<p>Paragraph \($0) of the long page, with enough words to wrap across the width of the screen.</p>" }
            send(task, html: Self.page("Long Page", paragraphs.joined() + "<p id=\"end\">End of the long page</p>"))
        case ("nofeed.example.invalid", "/opened"):
            send(task, html: Self.page("Opened Page", "<p>A page asked for in a new window.</p>"))
        case ("nofeed.example.invalid", "/frames"):
            send(task, html: Self.page("Framed Page", """
                <p>A page with two frames.</p>
                <iframe src="about:blank" title="Blank frame"></iframe>
                <iframe src="/frame-other-app" title="Other app frame"></iframe>
                """))
        case ("nofeed.example.invalid", "/frame-other-app"):
            send(task, html: "<html><body><script>location.href = 'newspaw-unknown-scheme://frame';</script></body></html>")
        case ("nofeed.example.invalid", "/binary"):
            send(task, body: "binary", type: "application/x-newspaw-unshowable")
        case ("nofeed.example.invalid", "/report.txt"):
            send(task, body: "A report", type: "text/plain")
        case ("nofeed.example.invalid", "/flaky") where !flakyFailed:
            flakyFailed = true
            fail(task)
        case ("nofeed.example.invalid", "/flaky"):
            send(task, html: Self.page("Flaky Page", "<p>This page failed once.</p>"))
        case ("onefeed.example.invalid", "/"):
            send(task, html: Self.page("One Feed Site", "<p>Another site, which declares a feed.</p>"))
        case (_, "/form"):
            send(task, html: Self.page("Form Page", """
                <p><label for="field">Note</label></p>
                <p><input id="field" type="text" placeholder="Type here" oninput="document.title = 'Typed: ' + this.value"></p>
                """))
        case ("nofeed.example.invalid", "/handlers"):
            send(task, html: Self.handlers)
        case ("example.invalid", let path) where path.hasPrefix("/articles/"):
            let slug = String(path.dropFirst("/articles/".count))
            send(task, html: Self.page("Original of \(slug)", """
                <p>The original page of the article \(slug).</p>
                <p><a href="/form">Form page</a></p>
                """))
        default:
            fail(task)
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }

    // MARK: - Answers

    private func send(_ task: any WKURLSchemeTask, html: String) {
        send(task, body: html, type: "text/html; charset=utf-8")
    }

    private func send(_ task: any WKURLSchemeTask, body: String, type: String) {
        guard !stopped.contains(ObjectIdentifier(task)), let url = task.request.url else { return }
        let fields = ["Content-Type": type]
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: fields) else { return }
        task.didReceive(response)
        task.didReceive(Data(body.utf8))
        task.didFinish()
    }

    /// Fails as an unknown host does, with the system's own wording.
    private func fail(_ task: any WKURLSchemeTask) {
        guard !stopped.contains(ObjectIdentifier(task)) else { return }
        task.didFailWithError(URLError(.cannotFindHost, userInfo: [
            NSLocalizedDescriptionKey: "A server with the specified hostname could not be found.",
        ]))
    }

    // MARK: - Pages

    private static func page(_ title: String, _ body: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <style>body { font: -apple-system-body; margin: 16px; } p { margin: 12px 0; } a { display: inline-block; padding: 8px 0; }</style>
        </head><body><h1>\(title)</h1>\(body)</body></html>
        """
    }

    private static let home = page("Fixture Home", """
        <p>A page served to the embedded browser under the UI tests.</p>
        <p><a href="/second">Second page</a></p>
        <p><a href="/count">Load counter</a></p>
        <p><a href="/slow">Slow page</a></p>
        <p><a href="/long">Long page</a></p>
        <p><a href="/opened" target="_blank">New window link</a></p>
        <p><a href="#" onclick="window.open('/opened'); return false;">Script window link</a></p>
        <p><a href="mailto:someone@example.invalid">Mail link</a></p>
        <p><a href="newspaw-unknown-scheme://open">Other app link</a></p>
        <p><a href="/report.txt" download>Download link</a></p>
        <p><a href="/binary">Unshowable link</a></p>
        <p><a href="/frames">Framed page</a></p>
        <p><a href="/missing">Missing page</a></p>
        <p><a href="/flaky">Flaky page</a></p>
        <p><a href="/form">Form page</a></p>
        <p><a href="/handlers">Handler probe</a></p>
        <p><a href="https://onefeed.example.invalid/">Another site</a></p>
        """)

    /// Posts to a fixed list of message-handler names; the title says
    /// whether every post threw.
    private static let handlers = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Handler Probe</title></head><body>
        <h1>Handler Probe</h1><p id="result">Not run</p>
        <script>
        var names = ['newsPaw', 'app', 'native', 'bridge', 'reader', 'browser', 'translate', 'readability'];
        var reached = [];
        names.forEach(function (name) {
            try { window.webkit.messageHandlers[name].postMessage('probe'); reached.push(name); } catch (error) {}
        });
        var text = reached.length === 0 ? 'Every post threw' : 'Reached: ' + reached.join(', ');
        document.getElementById('result').textContent = text;
        document.title = text;
        </script></body></html>
        """
}
#endif
