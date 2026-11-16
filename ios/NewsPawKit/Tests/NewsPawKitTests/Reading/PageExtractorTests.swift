import Foundation
@testable import NewsPawKit
import Testing
import WebKit

/// RD12 decision 1 and criteria 4, 5, 9 and 11: the extractor runs no
/// script of the page, requests nothing, navigates once, and keeps to its
/// bounds. Each test makes its own rule-list store in a temporary
/// directory, never the system's default one.
@Suite("Page extractor", .serialized)
@MainActor
struct PageExtractorTests {
    /// The deadline of the tests that are not about the deadline. The
    /// first extraction of a run starts a web content process, which took
    /// more than 10 seconds on the iOS 26.5 simulator with the whole suite
    /// running beside it; the deadline itself is tested with an injected
    /// one.
    static let roomyDeadline = Duration.seconds(60)

    /// An extractor whose rule list is compiled into a store of its own,
    /// removed with `directory`.
    static func extractor(
        deadline: Duration = roomyDeadline, usesRuleList: Bool = true
    ) throws -> (extractor: PageExtractor, directory: URL) {
        let directory = try makeTemporaryDirectory()
        let store = try #require(WKContentRuleListStore(url: directory))
        return (PageExtractor(deadline: deadline, ruleListStore: store, usesRuleList: usesRuleList), directory)
    }

    static func paragraphs(_ count: Int, prefix: String = "Paragraph") -> String {
        let sentence = "The harbour pilots read the tide tables each morning, and the ferry leaves when the water is deep enough for her keel."
        return (1...count).map { "<p>\(prefix) \($0). \(sentence) \(sentence)</p>" }.joined(separator: "\n")
    }

    /// The article page of the static-rule test (criterion 4): about 2,000
    /// characters of text, a script that would rewrite it, a `meta`
    /// refresh, an image, a style sheet, a font, a frame, `prefetch` and
    /// `preconnect` links, an event attribute and a `javascript:` link.
    static func hostilePage(origin: String, preconnect: String) -> String {
        """
        <!DOCTYPE html><html><head><title>Original title</title>
        <meta http-equiv="refresh" content="0; url=\(origin)/refresh-target.html">
        <link rel="stylesheet" href="\(origin)/style.css">
        <link rel="prefetch" href="\(origin)/prefetch.html">
        <link rel="preconnect" href="\(preconnect)">
        <style>@font-face { font-family: f; src: url("\(origin)/font.woff"); } body { font-family: f; }</style>
        <script src="\(origin)/external.js"></script>
        <script>document.addEventListener('DOMContentLoaded', function () {
          document.getElementById('first').textContent = 'REWRITTEN-BY-PAGE-SCRIPT';
          document.title = 'PAGE SCRIPT RAN';
        });</script>
        </head><body onload="document.title = 'ONLOAD RAN'">
        <article><h1>Original heading</h1>
        <p id="first">ORIGINAL-MARKER The first paragraph of the page as its markup has it, long enough to count as running text \
        of an article, with commas, clauses, and a full stop at its end.</p>
        <img src="\(origin)/image.png" alt="An image" onerror="document.title = 'ONERROR RAN'">
        <iframe src="\(origin)/frame.html"></iframe>
        <p onclick="alert('clicked')">A paragraph with an event attribute, and <a href="javascript:alert('ran')">a script link</a> \
        and <a href="/safe">a safe link</a>, long enough to be counted as a paragraph of running text in its own right.</p>
        \(paragraphs(8))
        </article></body></html>
        """
    }

    // MARK: - Criterion 4: the static rule

    @Test("criterion 4: the page is extracted from its markup, without navigating, and the listener receives nothing")
    func staticRule() async throws {
        let server = try LoopbackServer { _, _ in LoopbackServer.Reply(headers: ["Content-Type: text/plain"], body: Data("ok".utf8)) }
        let preconnect = try LoopbackServer { _, _ in LoopbackServer.Reply() }
        let (extractor, directory) = try Self.extractor()
        defer { try? FileManager.default.removeItem(at: directory) }

        let page = Self.hostilePage(origin: server.base, preconnect: preconnect.base)
        #expect(page.count > 2_000)
        let extraction = try await extractor.extract(html: page, address: try #require(URL(string: server.base + "/article/page.html")))
        // Late loads (a delayed refresh, a preconnect) would arrive now.
        try await Task.sleep(for: .seconds(1.5))

        let blocks = ArticleBlocks.make(html: extraction.html, baseURL: URL(string: server.base + "/article/page.html"))
        let text = blocks.blocks.compactMap(\.plainText).joined(separator: "\n")
        #expect(text.contains("ORIGINAL-MARKER"))
        #expect(!text.contains("REWRITTEN-BY-PAGE-SCRIPT"))
        #expect(!extraction.title.contains("RAN"))
        #expect(server.requests.isEmpty, "requests reached the listener: \(server.requests.map(\.path))")
        #expect(server.connections == 0)
        #expect(preconnect.connections == 0)
        #expect(extractor.webViewsHeld == 0)
        print("RD12 static rule, rule list on: \(server.requests.count) requests, \(server.connections) connections, preconnect \(preconnect.connections)")
    }

    @Test("criterion 4, control: with the rule list left out, the listener receives requests")
    func staticRuleControl() async throws {
        let server = try LoopbackServer { _, _ in LoopbackServer.Reply(headers: ["Content-Type: text/plain"], body: Data("ok".utf8)) }
        let preconnect = try LoopbackServer { _, _ in LoopbackServer.Reply() }
        let (extractor, directory) = try Self.extractor(usesRuleList: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let page = Self.hostilePage(origin: server.base, preconnect: preconnect.base)
        let extraction = try await extractor.extract(html: page, address: try #require(URL(string: server.base + "/article/page.html")))
        try await Task.sleep(for: .seconds(1.5))

        #expect(!server.requests.isEmpty)
        #expect(extraction.html.contains("ORIGINAL-MARKER"))
        // Still no navigation and no script: only the rule list was left out.
        #expect(!server.requests.map(\.path).contains("/refresh-target.html"))
        #expect(!server.requests.map(\.path).contains("/frame.html"))
        print("RD12 static rule, rule list off: \(server.requests.count) requests \(server.requests.map(\.path).sorted()), "
            + "\(server.connections) connections, preconnect \(preconnect.connections)")
    }

    @Test("criterion 4: the extraction navigates once: the load of the string, and nothing after it in any frame")
    func oneNavigation() {
        #expect(PageExtractor.mayNavigate(isMainFrame: true, navigationsBefore: 0))
        // A frame's content, a `meta` refresh, a link, a form: anything after.
        #expect(!PageExtractor.mayNavigate(isMainFrame: false, navigationsBefore: 0))
        for before in [1, 2, 17] {
            #expect(!PageExtractor.mayNavigate(isMainFrame: true, navigationsBefore: before))
            #expect(!PageExtractor.mayNavigate(isMainFrame: false, navigationsBefore: before))
        }
    }

    // MARK: - Criterion 5: what comes out

    @Test("criterion 5: a page whose text only its script would build is not an article")
    func scriptBuiltPage() async throws {
        let (extractor, directory) = try Self.extractor()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = """
            <!DOCTYPE html><html><head><title>Built by script</title></head><body>
            <div id="root"></div>
            <script>
            var html = '';
            for (var i = 0; i < 12; i++) { html += '<p>' + 'A paragraph that only the page script writes, long enough to be an article. '.repeat(4) + '</p>'; }
            document.getElementById('root').innerHTML = html;
            </script>
            <noscript><p>Turn on JavaScript.</p></noscript>
            </body></html>
            """
        let address = try #require(URL(string: "https://example.invalid/built"))
        do {
            let extraction = try await extractor.extract(html: page, address: address)
            let blocks = ArticleBlocks.make(html: extraction.html, baseURL: address)
            #expect(!ArticleBlocks.isArticle(blocks.blocks))
            #expect(!BodyPlan.isUsable(blocks.blocks, over: []))
        } catch let failure as ExtractionFailure {
            #expect(failure == .noArticle)
        }
    }

    @Test("criterion 5: a script, an event attribute and a javascript: link come out of ArticleBlocks as RD11 says")
    func hostileMarkupInTheExtraction() async throws {
        let (extractor, directory) = try Self.extractor()
        defer { try? FileManager.default.removeItem(at: directory) }
        let address = try #require(URL(string: "https://example.invalid/articles/hostile"))
        let page = Self.hostilePage(origin: "https://assets.example.invalid", preconnect: "https://other.example.invalid")
        let extraction = try await extractor.extract(html: page, address: address)
        let blocks = ArticleBlocks.make(html: extraction.html, baseURL: address)
        let text = blocks.blocks.compactMap(\.plainText).joined(separator: "\n")
        #expect(ArticleBlocks.isArticle(blocks.blocks))
        #expect(!text.contains("REWRITTEN"))
        #expect(!text.contains("alert("))
        #expect(!text.contains("addEventListener"))
        let links = blocks.blocks.flatMap { block -> [URL] in
            if case .paragraph(let runs) = block.kind { runs.compactMap(\.link) } else { [] }
        }
        #expect(links.allSatisfy { ["http", "https"].contains($0.scheme ?? "") })
        #expect(links.contains(URL(string: "https://example.invalid/safe")!))
        // The script link is text without a link.
        #expect(text.contains("a script link"))
    }

    // MARK: - Criterion 9: bounds

    @Test("criterion 9: an input over 3,000,000 characters is refused before a web view exists")
    func inputBound() async throws {
        let (extractor, directory) = try Self.extractor()
        defer { try? FileManager.default.removeItem(at: directory) }
        let address = try #require(URL(string: "https://example.invalid/big"))
        let over = "<p>" + String(repeating: "a", count: PageExtractor.maximumInputCharacters) + "</p>"
        await #expect(throws: ExtractionFailure.inputTooLarge) {
            try await extractor.extract(html: over, address: address)
        }
        #expect(extractor.webViewsMade == 0)
        // Characters, not bytes: three-byte characters count one each.
        let wide = "<p>" + String(repeating: "中", count: PageExtractor.maximumInputCharacters - 10) + "</p>"
        #expect(wide.utf8.count > PageExtractor.maximumInputCharacters)
        _ = try? await extractor.extract(html: wide, address: address)
        #expect(extractor.webViewsMade == 1)
    }

    @Test("criterion 9: a document over 50,000 elements is refused without a clone")
    func elementBound() async throws {
        let (extractor, directory) = try Self.extractor()
        defer { try? FileManager.default.removeItem(at: directory) }
        let address = try #require(URL(string: "https://example.invalid/many"))
        let many = "<html><body><article>" + String(repeating: "<b>x</b>", count: PageExtractor.maximumElements) + "</article></body></html>"
        await #expect(throws: ExtractionFailure.tooManyElements) {
            try await extractor.extract(html: many, address: address)
        }
        #expect(extractor.webViewsHeld == 0)
        // Just under the bound: read (html, head, body, article and the rest).
        let under = "<html><body><article>" + String(repeating: "<b>x</b>", count: PageExtractor.maximumElements - 10)
            + Self.paragraphs(3) + "</article></body></html>"
        let extraction = try await extractor.extract(html: under, address: address)
        #expect(extraction.html.contains("Paragraph 3."))
    }

    @Test("criterion 9: the injected deadline ends an extraction and discards its web view")
    func deadline() async throws {
        let (extractor, directory) = try Self.extractor(deadline: .milliseconds(1))
        defer { try? FileManager.default.removeItem(at: directory) }
        let address = try #require(URL(string: "https://example.invalid/slow"))
        await #expect(throws: ExtractionFailure.timedOut) {
            try await extractor.extract(html: "<html><body>" + Self.paragraphs(40) + "</body></html>", address: address)
        }
        #expect(extractor.webViewsMade == 1)
        #expect(extractor.webViewsHeld == 0)
    }

    @Test("criterion 9: one extraction runs at a time")
    func oneAtATime() async throws {
        let (extractor, directory) = try Self.extractor()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = "<html><head><title>One</title></head><body><article>" + Self.paragraphs(6) + "</article></body></html>"
        let address = try #require(URL(string: "https://example.invalid/one"))
        async let first = extractor.extract(html: page, address: address)
        async let second = extractor.extract(html: page, address: address)
        async let third = extractor.extract(html: page, address: address)
        let results = try await [first, second, third]
        #expect(results.allSatisfy { $0.html.contains("Paragraph 6.") })
        #expect(extractor.webViewsMade == 3)
        #expect(extractor.mostAtOnce == 1)
        #expect(extractor.webViewsHeld == 0)
    }

    @Test("an extraction cancelled in flight ends at once and discards its web view")
    func cancellation() async throws {
        let (extractor, directory) = try Self.extractor()
        defer { try? FileManager.default.removeItem(at: directory) }
        let address = try #require(URL(string: "https://example.invalid/cancelled"))
        // Long enough that the extraction is still running when cancelled.
        let page = "<html><body><article>" + String(repeating: "<b>x</b>", count: 40_000) + Self.paragraphs(40) + "</article></body></html>"
        let task = Task { try await extractor.extract(html: page, address: address) }
        for _ in 0..<1_000 where extractor.webViewsMade == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(extractor.webViewsMade == 1, "no web view was made before the cancellation")
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(extractor.webViewsMade == 1)
        #expect(extractor.webViewsHeld == 0)
    }

    @Test("a page with no content gives a null result")
    func nullResult() async throws {
        let (extractor, directory) = try Self.extractor()
        defer { try? FileManager.default.removeItem(at: directory) }
        let address = try #require(URL(string: "https://example.invalid/empty"))
        await #expect(throws: ExtractionFailure.noArticle) {
            try await extractor.extract(html: "<html><head><title>Empty</title></head><body></body></html>", address: address)
        }
    }

    @Test("the extraction is cut to 2,000,000 characters")
    func outputBound() async throws {
        let (extractor, directory) = try Self.extractor()
        defer { try? FileManager.default.removeItem(at: directory) }
        let address = try #require(URL(string: "https://example.invalid/long"))
        let word = "word, "
        let paragraph = "<p>" + String(repeating: word, count: 50_000) + "</p>"
        let page = "<html><body><article>" + String(repeating: paragraph, count: 9) + "</article></body></html>"
        #expect(page.unicodeScalars.count < PageExtractor.maximumInputCharacters)
        let extraction = try await extractor.extract(html: page, address: address)
        #expect(extraction.html.unicodeScalars.count == PageExtractor.maximumOutputCharacters)
        // Said to be cut: what is left may close cleanly, and the converter,
        // whose limit is the same, would then see nothing cut.
        #expect(extraction.isCut)
        // A page within the limit is not.
        let short = try await extractor.extract(html: "<html><body><article>" + Self.paragraphs(4) + "</article></body></html>", address: address)
        #expect(!short.isCut)
    }

    @Test("a page that names the document's methods does not change the calls the evaluation makes itself")
    func clobberedDocument() async throws {
        let (extractor, directory) = try Self.extractor()
        defer { try? FileManager.default.removeItem(at: directory) }
        let address = try #require(URL(string: "https://example.invalid/clobber"))
        func page(naming names: [String]) -> String {
            let traps = names.map { "<img name=\"\($0)\"><form name=\"\($0)\"></form>" }.joined()
            return "<html><head><title>Clobber</title></head><body>\(traps)<article><h1>Heading</h1>\(Self.paragraphs(6))</article></body></html>"
        }
        // The clone and the count are taken from the prototypes.
        let extraction = try await extractor.extract(html: page(naming: ["cloneNode", "documentElement", "body"]), address: address)
        #expect(extraction.html.contains("Paragraph 6."))
        // Readability's own calls on the clone are the page's to break: a
        // failure (decision 1), never a call into the page.
        await #expect(throws: ExtractionFailure.scriptFailed) {
            try await extractor.extract(html: page(naming: ["getElementsByTagName"]), address: address)
        }
        #expect(extractor.webViewsHeld == 0)
    }

    // MARK: - Criterion 11: the settings

    @Test("criterion 11: page scripts off, a non-persistent store, no user script and no message handler")
    func settings() async throws {
        let configuration = PageExtractor.configuration(ruleList: nil)
        #expect(configuration.defaultWebpagePreferences.allowsContentJavaScript == false)
        #expect(configuration.websiteDataStore.isPersistent == false)
        #expect(configuration.userContentController.userScripts.isEmpty)
        #expect(configuration.preferences.javaScriptCanOpenWindowsAutomatically == false)
        // A web view of this configuration: no message handler is visible
        // to a script, in the page's world or in the extractor's.
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let loaded = LoadWaiter()
        webView.navigationDelegate = loaded
        webView.loadHTMLString("<p>probe</p>", baseURL: nil)
        try await loaded.wait()
        let probe = "typeof window.webkit === 'undefined' || typeof window.webkit.messageHandlers === 'undefined' ? 'none' : 'some'"
        let page = try await webView.evaluateJavaScript(probe, in: nil, contentWorld: .page) as? String
        let own = try await webView.evaluateJavaScript(probe, in: nil, contentWorld: .world(name: PageExtractor.contentWorld)) as? String
        #expect(page == "none")
        #expect(own == "none")
        // Two configurations do not share a store.
        #expect(PageExtractor.configuration(ruleList: nil).websiteDataStore !== configuration.websiteDataStore)
        // The rule list's part of this criterion is the static-rule test:
        // the same factory with the list, and the control without it.
    }

    @Test("the rule list is compiled once into its store and looked up after that")
    func ruleListCompiledOnce() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(WKContentRuleListStore(url: directory))
        let address = try #require(URL(string: "https://example.invalid/one"))
        let page = "<html><body><article>" + Self.paragraphs(4) + "</article></body></html>"
        _ = try await PageExtractor(deadline: Self.roomyDeadline, ruleListStore: store).extract(html: page, address: address)
        let identifiers = await store.availableIdentifiers()
        #expect(identifiers == [PageExtractor.ruleListIdentifier])
        _ = try await PageExtractor(deadline: Self.roomyDeadline, ruleListStore: store).extract(html: page, address: address)
        #expect(await store.availableIdentifiers() == [PageExtractor.ruleListIdentifier])
    }

    @Test("without a rule list the extractor runs nothing")
    func noRuleListNoExtraction() async throws {
        let extractor = PageExtractor(deadline: .seconds(10), ruleListStore: nil)
        await #expect(throws: ExtractionFailure.ruleListUnavailable) {
            try await extractor.extract(html: "<p>x</p>", address: URL(string: "https://example.invalid/")!)
        }
        #expect(extractor.webViewsMade == 0)
    }
}

/// Waits for a web view's load to finish.
@MainActor
final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var done = false

    func wait() async throws {
        if done { return }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        done = true
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        done = true
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
