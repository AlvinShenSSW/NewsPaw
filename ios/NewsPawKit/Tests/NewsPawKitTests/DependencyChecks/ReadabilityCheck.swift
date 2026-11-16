import Foundation
@testable import NewsPawKit
import Testing
import WebKit

/// Runs the bundled Readability script on `Fixtures/article.html` through
/// the app's own extractor (RD12 decision 10; RD01's check, rewritten on
/// `PageExtractor`).
///
/// The fixture's inline script rewrites the first paragraph and the
/// document title, and its markup names a stylesheet and an image. The
/// extractor runs the app's script with page JavaScript off and every load
/// blocked; that nothing is requested is the static-rule test's
/// (`PageExtractorTests`), whose control run shows that a load would be
/// seen.
@Suite("Readability in a web view")
@MainActor
struct ReadabilityCheck {
    @Test("extracts the article with page JavaScript off")
    func extractsWithPageScriptOff() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(WKContentRuleListStore(url: directory))
        let extractor = PageExtractor(deadline: PageExtractorTests.roomyDeadline, ruleListStore: store)
        let address = try #require(URL(string: "https://example.invalid/articles/synthetic"))

        let extraction = try await extractor.extract(html: try Fixture.text("article", "html"), address: address)
        let text = ArticleBlocks.make(html: extraction.html, baseURL: address).blocks.compactMap(\.plainText).joined(separator: "\n")

        // The app's script ran: Readability returned the article.
        #expect(text.contains("ORIGINAL-MARKER"))
        #expect(text.contains("The third paragraph closes the synthetic story."))
        // The page's own script did not run.
        #expect(!text.contains("REWRITTEN-BY-PAGE-SCRIPT"))
        #expect(extraction.title == "Synthetic article")
    }
}
