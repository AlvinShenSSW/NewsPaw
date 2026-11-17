import Foundation
@testable import NewsPawKit
import Synchronization
import Testing
import WebKit

/// RD16 review round 3 (N1, N2): a session over a real web view, its pages
/// served from the loopback, and the real back-forward cache: a page shown
/// again on Back keeps the script's state (A4). What the state recorded for
/// an older document generation, or wrote for another reading language, is
/// collected again; a reading-language change under a page on screen
/// follows the same rule.
@Suite("Page translation, a page shown again", .serialized)
@MainActor
struct PageTranslationRestoreTests {
    nonisolated static let first = "今日の天気は晴れです"
    nonisolated static let second = "株価が上がりました"

    nonisolated static let pages: [String: String] = [
        "/a.html": """
            <!doctype html><html lang="ja"><head><meta name="viewport" content="width=device-width"></head><body>
            <p id="one">\(first)</p><p id="two">\(second)</p>
            <script>window.shows = []; addEventListener("pageshow", e => shows.push(e.persisted));</script>
            </body></html>
            """,
        // No letters: nothing to collect or send on the page between.
        "/b.html": "<!doctype html><html><body><p>12345</p></body></html>",
    ]

    /// A server, a page in a window, a translator over stubbed HTTP, and a
    /// session over the page's real bridge, seen, with a fast poll.
    @MainActor
    final class Rig {
        let server: LoopbackServer
        let page = ScriptPage()
        let fixture: TranslatorFixture
        var locale = ReadingLocale.simplifiedChinese
        private(set) var session: PageTranslationSession!

        init(service: TranslationService) async throws {
            server = try LoopbackServer { request, _ in
                guard let html = PageTranslationRestoreTests.pages[request.path] else { return LoopbackServer.Reply("404 Not Found") }
                return LoopbackServer.Reply(headers: ["Content-Type: text/html; charset=utf-8"], body: Data(html.utf8))
            }
            fixture = try await TranslatorFixture.make(service: service)
            var timing = PageTranslationSession.Timing()
            timing.poll = .milliseconds(50)
            timing.afterScroll = .milliseconds(1)
            timing.decideAfter = .seconds(600)
            session = PageTranslationSession(
                scripting: page.bridge, translator: PageTranslator(models: fixture.models), readingLocale: { [weak self] in
                    self?.locale ?? .simplifiedChinese
                }, isSeen: { true }, timing: timing
            )
        }

        func url(_ name: String) -> URL {
            URL(string: server.base + "/" + name)!
        }

        /// Opens `name` and tells the session, as the browser's `didCommit`
        /// does.
        func open(_ name: String) async {
            await page.open(url(name))
            session.documentCommitted(url(name))
        }

        func back() async {
            await page.back()
            session.documentCommitted(page.webView.url)
        }

        /// Whether both paragraphs read `mark` before their original.
        func reads(_ mark: String) async throws -> Bool {
            let one = try await text("one")
            let two = try await text("two")
            return one == mark + PageTranslationRestoreTests.first && two == mark + PageTranslationRestoreTests.second
        }

        func text(_ id: String) async throws -> String {
            try await page.pageString("return document.getElementById('\(id)').firstChild.data")
        }

        /// Whether the page was shown again from the back-forward cache.
        func restoredFromCache() async throws -> Bool {
            try await page.pageString("return JSON.stringify(window.shows)") == "[false,true]"
        }

        func end() {
            session.close()
            fixture.remove()
        }

        func eventually(_ condition: () async throws -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            let deadline = ContinuousClock.now + .seconds(30)
            while try await !condition() {
                guard ContinuousClock.now < deadline else {
                    Issue.record("the condition did not hold within 30 s", sourceLocation: sourceLocation)
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    @Test("N1: a page left while its runs were being translated, shown again on Back, is translated")
    func leftWhileTranslating() async throws {
        let service = TranslationService()
        service.hold(request: 1)
        let rig = try await Rig(service: service)
        defer { rig.end() }
        await rig.open("a.html")
        rig.session.turnOn()
        // The page's runs are collected and their request is in flight.
        try await rig.eventually { service.requests.count == 1 }
        await rig.open("b.html")
        await rig.back()
        #expect(try await rig.restoredFromCache(), "the back-forward cache showed the page again")
        #expect(try await rig.text("one") == Self.first)
        try await rig.eventually { try await rig.reads("T:") }
        try await rig.eventually { rig.session.line == .translated(.simplifiedChinese) }
        #expect(service.requests.count == 2)
    }

    @Test("N2: a page translated into one language, shown again on Back after the reading language changed, is translated into the new one")
    func restoredAfterLanguageChange() async throws {
        let prefix = Mutex("ZH:")
        let service = TranslationService { _, _, _ in
            let mark = prefix.withLock { $0 }
            return .texts({ texts in texts.map { mark + $0 } })
        }
        let rig = try await Rig(service: service)
        defer { rig.end() }
        await rig.open("a.html")
        rig.session.turnOn()
        try await rig.eventually { try await rig.reads("ZH:") }
        await rig.open("b.html")
        rig.locale = .english
        prefix.withLock { $0 = "EN:" }
        await rig.back()
        #expect(try await rig.restoredFromCache(), "the back-forward cache showed the page again")
        try await rig.eventually { try await rig.reads("EN:") }
        try await rig.eventually { rig.session.line == .translated(.english) }
        #expect(service.requests.last?.system.contains("English") == true)
    }

    @Test("N2: the reading language changed while a translated page is on screen: the page is translated into the new language, and the line says so")
    func languageChangeOnScreen() async throws {
        let prefix = Mutex("ZH:")
        let service = TranslationService { _, _, _ in
            let mark = prefix.withLock { $0 }
            return .texts({ texts in texts.map { mark + $0 } })
        }
        let rig = try await Rig(service: service)
        defer { rig.end() }
        await rig.open("a.html")
        rig.session.turnOn()
        try await rig.eventually { try await rig.reads("ZH:") }
        try await rig.eventually { rig.session.line == .translated(.simplifiedChinese) }
        prefix.withLock { $0 = "EN:" }
        rig.locale = .english
        try await rig.eventually { try await rig.reads("EN:") }
        try await rig.eventually { rig.session.line == .translated(.english) }
        #expect(service.requests.last?.system.contains("English") == true)
    }
}
