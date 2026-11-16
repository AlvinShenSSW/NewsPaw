#if DEBUG
import Foundation
import NewsPawKit
import WebKit

/// The embedded browser's pages under the UI tests (RD10 "Fixtures"): a
/// scheme handler that serves a fixed table for one fixture scheme, made
/// only in a debug build and only under a UI-test library directory. Every
/// address outside the table fails without a request. Pages load nothing
/// from another host. Their links are relative, but for the links to the
/// table's other host: one `https` link, which Add source detects through
/// the fixture transport, and links in the fixture scheme itself, which the
/// policy alone decides (an `https` link is always loaded by the browser
/// under the fixtures, whatever the policy says).
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
    /// How long the other site's slow page takes: long enough for a UI test
    /// to read the bars and tap a second link while it is pending.
    static let slowSiteAnswer: TimeInterval = 8
    /// The query that marks an arrival page as loaded by the browser itself.
    static let loadedByBrowser = "by=browser"

    /// The addresses of the table, as the browser shows them.
    enum Address {
        static let home = "https://nofeed.example.invalid/"
    }

    /// The address WebKit loads for an `http` or `https` address, and back.
    static var map: BrowserAddressMap {
        BrowserAddressMap(
            toWebKit: { url in
                guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return url }
                let mapped = replacingScheme(of: url, with: Self.scheme)
                // Only the browser's own loads pass here, never a navigation
                // WebKit follows: the arrival page is marked, so that it can
                // say which of the two brought it.
                guard mapped.path(percentEncoded: false) == "/arrival", mapped.query(percentEncoded: false) == nil,
                      var components = URLComponents(url: mapped, resolvingAgainstBaseURL: false)
                else { return mapped }
                components.query = Self.loadedByBrowser
                return components.url ?? mapped
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
    /// The addresses under `/posted-once-` that have failed their first
    /// request.
    private var failedOnce = Set<String>()

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let id = ObjectIdentifier(task)
        // A new task can have the identifier of a stopped one that is gone:
        // it is not stopped.
        stopped.remove(id)
        let host = url.host(percentEncoded: false)?.lowercased() ?? ""
        let path = url.path(percentEncoded: false)
        switch (host, path) {
        case ("nofeed.example.invalid", "/"), ("nofeed.example.invalid", ""):
            send(task, html: Self.home)
        case ("nofeed.example.invalid", "/second"):
            send(task, html: Self.page("Second Page", "<p>The second page.</p><p><a href=\"/\">Home</a></p>"))
        case (_, "/count"):
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
        case ("onefeed.example.invalid", "/slow"):
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.slowSiteAnswer) { [weak self] in
                guard let self, !self.stopped.contains(id) else { return }
                self.send(task, html: Self.page("Slow Site", "<p>Another site, which answered slowly.</p>"))
            }
        case ("nofeed.example.invalid", "/hosts"):
            send(task, html: Self.hosts)
        case ("nofeed.example.invalid", "/redirect"):
            redirect(task, to: "\(Self.scheme)://onefeed.example.invalid/arrival")
        case (_, "/arrival"):
            send(task, html: Self.arrival(byBrowser: url.query(percentEncoded: false) == Self.loadedByBrowser))
        case ("nofeed.example.invalid", "/video.mp4"):
            send(task, body: String(repeating: "x", count: 2000), type: "video/mp4")
        case ("nofeed.example.invalid", "/dark"):
            let paragraphs = (1...60).map { "<p>Paragraph \($0) of the dark page, with enough words to wrap across the width of the screen.</p>" }
            send(task, html: Self.page("Dark Page", paragraphs.joined(), style: "body { background: #0b0b0f; color: #f2f2f7; }"))
        case (_, "/hidden-asker"):
            send(task, html: Self.page("Hidden Asker", """
                <p>A page that asks for another app whenever it is not on screen.</p>
                <script>
                function ask() { if (document.hidden) { location.href = 'newspaw-unknown-scheme://hidden'; } }
                document.addEventListener('visibilitychange', ask);
                setInterval(ask, 1500);
                </script>
                """))
        case (_, "/media"):
            send(task, html: Self.media)
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
        case ("nofeed.example.invalid", "/form-end"):
            send(task, html: Self.page("Form at the End", """
                <p>A long page with its field at the end.</p>
                <div style="height: 1700px"></div>
                <p><label for="field">Note</label></p>
                <p><input id="field" type="text" placeholder="Type here" oninput="document.title = 'Typed: ' + this.value"></p>
                """))
        case ("nofeed.example.invalid", "/post-form"):
            send(task, html: Self.page("Post Form", """
                <form method="post" action="/posted" target="_blank">
                <p><label for="note">Note</label> <input id="note" type="text" name="note" value="paw 42"></p>
                <p><button type="submit">Post to a new window</button></p>
                </form>
                <form method="post" action="/posted-once-window" target="_blank">
                <input type="hidden" name="note" value="paw 43">
                <p><button type="submit">Fail once in a new window</button></p>
                </form>
                <form method="post" action="/posted-once-here">
                <input type="hidden" name="note" value="paw 44">
                <p><button type="submit">Fail once in this window</button></p>
                </form>
                """))
        case ("nofeed.example.invalid", "/posted"):
            send(task, html: Self.posted(task.request))
        case ("nofeed.example.invalid", let path) where path.hasPrefix("/posted-once-"):
            // Fails its first request, whatever it asks, and answers the
            // ones after it.
            if failedOnce.insert(path).inserted {
                fail(task)
            } else {
                send(task, html: Self.posted(task.request))
            }
        case ("nofeed.example.invalid", "/handlers"):
            send(task, html: Self.handlers)
        case ("fulltext.example.invalid", "/pages/article"):
            send(task, html: Self.ferryArticle)
        case ("fulltext.example.invalid", "/pages/list"):
            let items = (1...30).map {
                "<li><h2><a href=\"/pages/story-\($0)\">Headline number \($0) from the harbour</a></h2>"
                    + "<p>A one-sentence summary of story \($0), as list pages have them.</p></li>"
            }
            send(task, html: Self.page("Latest stories", "<ul>\(items.joined())</ul>"))
        case ("example.invalid", let path) where path.hasPrefix("/articles/"):
            let slug = String(path.dropFirst("/articles/".count))
            send(task, html: Self.page("Original of \(slug)", """
                <p>The original page of the article \(slug).</p>
                <p><a href="/form">Form page</a></p>
                <p><a href="/count">Load counter</a></p>
                <p><a href="/hidden-asker">Hidden asker</a></p>
                <p><a href="/media">Media page</a></p>
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

    /// Answers as a server that redirects to `address`, and then with the
    /// arrival page as WebKit gets it when it follows the redirect. WebKit
    /// asks the policy about the redirect first and stops the task when the
    /// policy refuses, so that page is shown only if the redirect was
    /// followed. A scheme task has no public way to answer a redirect; this
    /// uses the task's own `_didPerformRedirection:newRequest:` (measured:
    /// the policy is asked again, as for a server's redirect), which exists
    /// here in debug builds only. Without it the address fails.
    private func redirect(_ task: any WKURLSchemeTask, to address: String) {
        let selector = NSSelectorFromString("_didPerformRedirection:newRequest:")
        let object = task as AnyObject
        guard !stopped.contains(ObjectIdentifier(task)), let from = task.request.url, let target = URL(string: address),
              object.responds(to: selector),
              let response = HTTPURLResponse(url: from, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": address])
        else {
            fail(task)
            return
        }
        _ = object.perform(selector, with: response, with: URLRequest(url: target))
        send(task, body: Self.arrival(byBrowser: false), type: "text/html; charset=utf-8", url: target)
    }

    private func send(_ task: any WKURLSchemeTask, body: String, type: String, url: URL? = nil) {
        guard !stopped.contains(ObjectIdentifier(task)), let url = url ?? task.request.url else { return }
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

    private static func page(_ title: String, _ body: String, style: String = "") -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <style>body { font: -apple-system-body; margin: 16px; } p { margin: 12px 0; } a { display: inline-block; padding: 8px 0; } \(style)</style>
        </head><body><h1>\(title)</h1>\(body)</body></html>
        """
    }

    /// The other site's arrival page; its title says whether the browser
    /// loaded it itself or WebKit followed a navigation to it.
    private static func arrival(byBrowser: Bool) -> String {
        page(byBrowser ? "Loaded by the Browser" : "Followed by WebKit", "<p>A page of another site.</p>")
    }

    /// The page a form is posted to; its title says how it was asked for:
    /// the method and the body, as `POST: note=paw+42`, or `GET: no body`.
    private static func posted(_ request: URLRequest) -> String {
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let type = request.value(forHTTPHeaderField: "Content-Type") ?? "none"
        return page("\(request.httpMethod ?? "GET"): \(body.isEmpty ? "no body" : body)", "<p>Content type: \(type)</p>")
    }

    /// Links from this host to the other one, in the fixture scheme, so
    /// that the policy decides what happens to each.
    private static let hosts = page("Host Links", """
        <p><a href="#" onclick="location.href = '\(scheme)://onefeed.example.invalid/slow'; return false;">Script to a slow site</a></p>
        <p><a href="\(scheme)://onefeed.example.invalid/slow">Slow site</a></p>
        <p><a href="\(scheme)://onefeed.example.invalid/arrival">Arrival page</a></p>
        <p><a href="/redirect">Redirecting link</a></p>
        """)

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
        <p><a href="/hosts">Host links</a></p>
        <p><a href="#" onclick="window.open(''); return false;">Empty window link</a></p>
        <p><a href="/video.mp4">Video link</a></p>
        <p><a id="blob" href="#" download="hello.txt">Blob download link</a></p>
        <p><a href="/dark">Dark page</a></p>
        <p><a href="/form-end">Form at the end</a></p>
        <p><a href="/hidden-asker">Hidden asker</a></p>
        <p><a href="/post-form">Post form</a></p>
        <script>document.getElementById('blob').href = URL.createObjectURL(new Blob(['hello'], { type: 'text/plain' }));</script>
        """)

    /// A page that plays and starts its sound again whenever it stops, as
    /// a page may (RD18 decision 13): after Play, two minutes of silence in
    /// an audio element and a tone too faint to hear (gain 0.0001) in an audio
    /// context. Every 200 ms it calls `play()` on the element when it is
    /// paused and `resume()` on the context when it is not running, and its
    /// title reports how many seconds each has played, the context's state
    /// and the states it has passed through:
    /// `Played <element> <context> <state> <states>`.
    private static let media = page("Media Page", """
        <p>A page that plays silence and starts it again whenever it stops.</p>
        <p><button type="button" onclick="start()">Play</button></p>
        <script>
        var context = null, audio = null, seen = [];
        function silence(seconds) {
            var rate = 8000, samples = rate * seconds, bytes = new ArrayBuffer(44 + samples * 2), view = new DataView(bytes);
            function text(offset, value) { for (var i = 0; i < value.length; i++) { view.setUint8(offset + i, value.charCodeAt(i)); } }
            text(0, 'RIFF'); view.setUint32(4, 36 + samples * 2, true); text(8, 'WAVE'); text(12, 'fmt ');
            view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
            view.setUint32(24, rate, true); view.setUint32(28, rate * 2, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true);
            text(36, 'data'); view.setUint32(40, samples * 2, true);
            return URL.createObjectURL(new Blob([bytes], { type: 'audio/wav' }));
        }
        function start() {
            if (audio) { return; }
            context = new AudioContext();
            context.onstatechange = function () { seen.push(context.state); };
            var gain = context.createGain();
            gain.gain.value = 0.0001;
            var tone = context.createOscillator();
            tone.connect(gain);
            gain.connect(context.destination);
            tone.start();
            audio = new Audio(silence(120));
            audio.play();
        }
        setInterval(function () {
            if (!audio) { return; }
            if (audio.paused) { audio.play().catch(function () {}); }
            if (context.state !== 'running') { context.resume().catch(function () {}); }
            document.title = 'Played ' + audio.currentTime.toFixed(1) + ' ' + context.currentTime.toFixed(1) + ' ' + context.state + ' ' + seen.join(',');
        }, 200);
        </script>
        """)

    /// The article page of the full-text feed as the browser shows it
    /// (RD12): the transport serves the same address to reader mode. It
    /// has a link to the list page and a Play button for a sound of silence
    /// that does not start again by itself; its title reports how long the
    /// sound has played and whether it is paused: `Ferry <seconds>
    /// <playing|paused>` once played.
    private static let ferryArticle = page("The ferry at dawn", """
        <p><button type="button" onclick="play()">Play</button></p>
        <p>\(FixtureTransport.fullTextParagraphs[0])</p>
        <p>\(FixtureTransport.fullTextParagraphs[1])</p>
        <p>\(FixtureTransport.fullTextParagraphs[2]) See also <a href="/pages/list">the latest stories</a> from the harbour.</p>
        <p>\(FixtureTransport.fullTextParagraphs[3])</p>
        <script>
        var audio = null;
        function silence(seconds) {
            var rate = 8000, samples = rate * seconds, bytes = new ArrayBuffer(44 + samples * 2), view = new DataView(bytes);
            function text(offset, value) { for (var i = 0; i < value.length; i++) { view.setUint8(offset + i, value.charCodeAt(i)); } }
            text(0, 'RIFF'); view.setUint32(4, 36 + samples * 2, true); text(8, 'WAVE'); text(12, 'fmt ');
            view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
            view.setUint32(24, rate, true); view.setUint32(28, rate * 2, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true);
            text(36, 'data'); view.setUint32(40, samples * 2, true);
            return URL.createObjectURL(new Blob([bytes], { type: 'audio/wav' }));
        }
        function play() { if (!audio) { audio = new Audio(silence(120)); } audio.play(); }
        setInterval(function () {
            if (audio) { document.title = 'Ferry ' + audio.currentTime.toFixed(1) + ' ' + (audio.paused ? 'paused' : 'playing'); }
        }, 200);
        </script>
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
