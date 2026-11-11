import Foundation
import NewsPawKit
import Synchronization
import Testing
import WebKit

/// Runs the bundled Readability script on `Fixtures/article.html` in a `WebPage`.
///
/// The fixture's inline script rewrites the first paragraph and the document title, and
/// its markup references a stylesheet and an image through the test-only scheme
/// `newspaw-test`, whose handler records every request it receives.
///
/// Subresources are blocked with a block-all content rule list, not with
/// `WebPage.Configuration.loadsSubresources = false`: on macOS 27.0.1 and the iOS 26.5
/// simulator that flag stops network loads but still lets loads through a custom scheme
/// handler, so this harness could not observe it. A rule list stops both.
///
/// The first test is the guarded case. The other two are positive controls that change
/// one setting each and show the harness can see what the first test says did not happen.
@Suite("Readability in a web view")
@MainActor
struct ReadabilityCheck {
    @Test("extracts the article with page JavaScript off and every subresource blocked")
    func extractsWithPageScriptOffAndSubresourcesBlocked() async throws {
        let result = try await ReadabilityHarness.extract(blockSubresources: true, allowPageJavaScript: false)

        // The app's script ran: Readability returned the article text.
        #expect(result.articleText.contains("ORIGINAL-MARKER"))
        #expect(result.articleText.contains("The third paragraph closes the synthetic story."))
        // The page's own script did not run.
        #expect(!result.articleText.contains("REWRITTEN-BY-PAGE-SCRIPT"))
        #expect(result.documentTitle == "Synthetic article")
        // No subresource was requested.
        #expect(result.schemeRequests.isEmpty)
    }

    @Test("control: with blocking off, both subresource requests are observed")
    func controlObservesSubresourcesWhenNotBlocked() async throws {
        let result = try await ReadabilityHarness.extract(blockSubresources: false, allowPageJavaScript: false)

        #expect(Set(result.schemeRequests.map(\.absoluteString)) == [
            "newspaw-test://fixture/style.css",
            "newspaw-test://fixture/image.png",
        ])
        #expect(result.articleText.contains("ORIGINAL-MARKER"))
    }

    @Test("control: with page JavaScript allowed, the article text is rewritten")
    func controlPageScriptRewritesWhenAllowed() async throws {
        let result = try await ReadabilityHarness.extract(blockSubresources: true, allowPageJavaScript: true)

        #expect(result.articleText.contains("REWRITTEN-BY-PAGE-SCRIPT"))
        #expect(!result.articleText.contains("ORIGINAL-MARKER"))
        #expect(result.documentTitle == "PAGE SCRIPT RAN")
        #expect(result.schemeRequests.isEmpty)
    }
}

@MainActor
enum ReadabilityHarness {
    struct Result {
        let articleText: String
        let documentTitle: String
        let schemeRequests: [URL]
    }

    static let testScheme = "newspaw-test"

    private static let blockAllRules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#

    private static let extraction = """
        const article = new Readability(document.cloneNode(true)).parse();
        return { text: article ? article.textContent : "", title: document.title };
        """

    static func extract(blockSubresources: Bool, allowPageJavaScript: Bool) async throws -> Result {
        let log = SchemeRequestLog()
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        var navigation = WebPage.NavigationPreferences()
        navigation.allowsContentJavaScript = allowPageJavaScript
        configuration.defaultNavigationPreferences = navigation
        configuration.urlSchemeHandlers[try #require(URLScheme(testScheme))] = RecordingSchemeHandler(log: log)

        // The rule list is compiled into a store in a temporary directory, not the default store.
        let storeDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        if blockSubresources {
            let store = try #require(WKContentRuleListStore(url: storeDirectory))
            let ruleList = try #require(
                await store.compileContentRuleList(forIdentifier: "block-all", encodedContentRuleList: blockAllRules)
            )
            configuration.userContentController.add(ruleList)
        }

        let page = WebPage(configuration: configuration)
        var finished = false
        for try await event in page.load(html: try Fixture.text("article", "html")) where event == .finished {
            finished = true
            break
        }
        #expect(finished, "The fixture page did not finish loading")

        let script = try ReadabilityScript.source()
        let value = try await page.callJavaScript(script + "\n" + extraction, contentWorld: .defaultClient)
        let object = try #require(value as? [String: Any], "Unexpected script result: \(String(describing: value))")
        return Result(
            articleText: try #require(object["text"] as? String),
            documentTitle: try #require(object["title"] as? String),
            schemeRequests: log.urls
        )
    }
}

/// Every URL the test scheme's handler was asked for.
final class SchemeRequestLog: Sendable {
    private let recorded = Mutex<[URL]>([])

    func record(_ url: URL) {
        recorded.withLock { $0.append(url) }
    }

    var urls: [URL] {
        recorded.withLock { $0 }
    }
}

/// Records each request and answers it with an empty body of the expected type.
struct RecordingSchemeHandler: URLSchemeHandler {
    let log: SchemeRequestLog

    func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
        AsyncThrowingStream { continuation in
            guard let url = request.url else {
                continuation.finish(throwing: URLError(.badURL))
                return
            }
            log.record(url)
            let mimeType = url.pathExtension == "css" ? "text/css" : "image/png"
            continuation.yield(.response(URLResponse(url: url, mimeType: mimeType, expectedContentLength: 0, textEncodingName: nil)))
            continuation.finish()
        }
    }
}
