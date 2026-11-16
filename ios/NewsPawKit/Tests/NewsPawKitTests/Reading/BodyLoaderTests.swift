import Foundation
import GRDB
@testable import NewsPawKit
import Synchronization
import Testing

/// RD12 decisions 3, 5, 6 and 7 with a stubbed transport and a stubbed
/// extractor: what is fetched, shown, stored and remembered (criteria 3, 7,
/// 9 and 10).
@Suite("Body loader")
@MainActor
struct BodyLoaderTests {
    nonisolated static let link = URL(string: "https://example.invalid/articles/one")!
    nonisolated static let html = "text/html; charset=utf-8"

    /// An article's HTML that is usable against a short feed excerpt.
    nonisolated static let articleHTML = "<article><h1>One</h1>\(BodyPlanTests.paragraphs(4))</article>"
    nonisolated static let page = "<!DOCTYPE html><html><head><title>One</title></head><body>\(articleHTML)</body></html>"
    nonisolated static let excerpt = BodyPlanTests.blocks("<p>A short excerpt of the story.</p>")

    /// A library with one article.
    struct Setup {
        let fixture: ArticleFixture
        let article: UUID
        var library: Library { fixture.library }
    }

    static func setup() async throws -> Setup {
        let fixture = try await ArticleFixture.make()
        let category = try await fixture.category("World")
        let source = try await fixture.source("Feed", in: category)
        let article = try await fixture.article("One", in: source, published: nil, firstSeen: fixture.at(0))
        return Setup(fixture: fixture, article: article)
    }

    static func answering(_ body: String = page, status: Int = 200, type: String = html, finalURL: URL = link) -> FakeTransport {
        FakeTransport.answering(status: status, body: Data(body.utf8), headers: ["Content-Type": type], finalURL: finalURL)
    }

    static func loader(
        _ setup: Setup, transport: any Transport, extractor: any PageExtracting = StubExtractor(),
        clock: TestClock? = nil, inFront: @escaping @MainActor () -> Bool = { true }
    ) -> BodyLoader {
        BodyLoader(
            library: setup.library, transport: transport, extractor: extractor, now: (clock ?? setup.fixture.clock).now,
            isInFront: inFront
        )
    }

    // MARK: - Success, the envelope and the store

    @Test("a usable extraction is stored in its envelope and read back at the next opening")
    func storesAndReadsBack() async throws {
        let setup = try await Self.setup()
        defer { setup.fixture.remove() }
        let extractor = StubExtractor()
        let final = try #require(URL(string: "https://www.example.invalid/articles/one?moved"))
        let loader = Self.loader(setup, transport: Self.answering(finalURL: final), extractor: extractor)

        let outcome = try await loader.load(article: setup.article, link: Self.link, feed: Self.excerpt)
        guard case .extracted(let body, stored: true) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        // The extractor was handed the decoded page and the address that answered.
        #expect(extractor.calls.map(\.address) == [final])
        #expect(extractor.calls.first?.html == Self.page)
        #expect(body.address == final)
        #expect(ArticleBlocks.isArticle(body.blocks.blocks))

        let stored = try #require(try await setup.library.extraction(ofArticle: setup.article))
        #expect(stored.address == final)
        #expect(stored.html == Self.articleHTML)
        #expect(stored.fetchedAt == setup.fixture.clock.now())
        let row = try await setup.library.pool.read { db -> [String] in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT origin, blocks FROM article_body WHERE article_id = ?", arguments: [setup.article.databaseKey]
            ) else { return [] }
            return [row["origin"], row["blocks"]]
        }
        #expect(row.first == "extracted")
        let envelope = try JSONDecoder().decode(ExtractionEnvelope.self, from: Data((row.last ?? "").utf8))
        #expect(envelope == ExtractionEnvelope(v: 1, html: Self.articleHTML, address: final.absoluteString))

        let again = await loader.storedBody(ofArticle: setup.article, feed: Self.excerpt)
        #expect(again?.blocks == body.blocks)
        #expect(again?.address == final)
    }

    @Test("an extraction the extractor cut is a cut body when fetched, when stored and when read back; one not cut is not")
    func extractorCutIsKept() async throws {
        let setup = try await Self.setup()
        defer { setup.fixture.remove() }
        let loader = Self.loader(setup, transport: Self.answering(), extractor: StubExtractor(cut: true))
        let outcome = try await loader.load(article: setup.article, link: Self.link, feed: Self.excerpt)
        guard case .extracted(let body, stored: true) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        // The HTML itself closes cleanly: only the extractor knows it cut.
        #expect(!ArticleBlocks.make(html: Self.articleHTML, baseURL: Self.link).isCut)
        #expect(body.blocks.isCut)
        #expect(try await setup.library.extraction(ofArticle: setup.article)?.isCut == true)
        #expect(await loader.storedBody(ofArticle: setup.article, feed: Self.excerpt)?.blocks.isCut == true)
        // Reader mode's call gives the same mark.
        let reader = try await BodyLoader.readerArticle(at: Self.link, transport: Self.answering(), extractor: StubExtractor(cut: true))
        #expect(reader.blocks.isCut)

        // Not cut: stored without the mark, read back whole.
        let whole = Self.loader(setup, transport: Self.answering(), extractor: StubExtractor())
        _ = try await whole.load(article: setup.article, link: Self.link, feed: Self.excerpt)
        #expect(try await setup.library.extraction(ofArticle: setup.article)?.isCut == false)
        #expect(await whole.storedBody(ofArticle: setup.article, feed: Self.excerpt)?.blocks.isCut == false)
    }

    @Test("criterion 10: an envelope of an unknown version, another origin or unreadable text reads as absent")
    func envelopeVersions() async throws {
        let setup = try await Self.setup()
        defer { setup.fixture.remove() }
        func store(origin: String, blocks: String) async throws {
            try await setup.library.pool.write { db in
                try db.execute(sql: """
                    INSERT INTO article_body (article_id, origin, blocks, fetched_at) VALUES (?, ?, ?, ?)
                    ON CONFLICT (article_id) DO UPDATE SET origin = excluded.origin, blocks = excluded.blocks
                    """, arguments: [setup.article.databaseKey, origin, blocks, Date()])
            }
        }
        let good = #"{"v":1,"html":"<p>x</p>","address":"https://example.invalid/a"}"#
        try await store(origin: "extracted", blocks: good)
        #expect(try await setup.library.extraction(ofArticle: setup.article)?.html == "<p>x</p>")
        #expect(try await setup.library.extraction(ofArticle: setup.article)?.isCut == false)
        try await store(origin: "extracted", blocks: #"{"v":1,"html":"<p>x</p>","address":"https://example.invalid/a","cut":true}"#)
        #expect(try await setup.library.extraction(ofArticle: setup.article)?.isCut == true)
        for (origin, blocks) in [
            ("extracted", #"{"v":2,"html":"<p>x</p>","address":"https://example.invalid/a"}"#),
            ("extracted", #"{"html":"<p>x</p>","address":"https://example.invalid/a"}"#),
            ("extracted", #"{"v":1,"html":"<p>x</p>","address":"file:///etc/hosts"}"#),
            ("extracted", "[]"),
            ("extracted", "not json"),
            ("feed", good),
        ] {
            try await store(origin: origin, blocks: blocks)
            #expect(try await setup.library.extraction(ofArticle: setup.article) == nil, "\(origin) \(blocks)")
        }
        // Absent: the loader fetches.
        let transport = Self.answering()
        let loader = Self.loader(setup, transport: transport)
        #expect(await loader.storedBody(ofArticle: setup.article, feed: Self.excerpt) == nil)
    }

    @Test("criterion 10: a stored extraction is checked again when read")
    func storedIsCheckedAgain() async throws {
        let setup = try await Self.setup()
        defer { setup.fixture.remove() }
        let loader = Self.loader(setup, transport: Self.answering())
        try await setup.library.storeExtraction(html: Self.articleHTML, address: Self.link, ofArticle: setup.article)
        #expect(await loader.storedBody(ofArticle: setup.article, feed: Self.excerpt) != nil)
        // Not more than the feed's content (the feed now carries more).
        let longer = BodyPlanTests.blocks(BodyPlanTests.paragraphs(10))
        #expect(await loader.storedBody(ofArticle: setup.article, feed: longer) == nil)
        // Not an article.
        try await setup.library.storeExtraction(html: BodyPlanTests.listPage, address: Self.link, ofArticle: setup.article)
        #expect(await loader.storedBody(ofArticle: setup.article, feed: []) == nil)
    }

    @Test("the extraction goes with its article")
    func cascade() async throws {
        let setup = try await Self.setup()
        defer { setup.fixture.remove() }
        try await setup.library.storeExtraction(html: Self.articleHTML, address: Self.link, ofArticle: setup.article)
        #expect(try await rowCounts(setup.library)["article_body"] == 1)
        let source = try await setup.library.article(setup.article).sourceID
        try await setup.library.deleteSource(source)
        #expect(try await rowCounts(setup.library)["article_body"] == 0)
    }

    @Test("the article deleted during its fetch: the result is dropped and nothing is written")
    func articleGone() async throws {
        let setup = try await Self.setup()
        defer { setup.fixture.remove() }
        let library = setup.library
        let article = setup.article
        let transport = FakeTransport { _ in
            let source = try await library.article(article).sourceID
            try await library.deleteSource(source)
            return TransportResponse(finalURL: Self.link, status: 200, headers: ["Content-Type": Self.html], body: Data(Self.page.utf8))
        }
        let outcome = try await Self.loader(setup, transport: transport).load(article: article, link: Self.link, feed: Self.excerpt)
        #expect(outcome == .articleGone)
        #expect(try await rowCounts(library)["article_body"] == 0)
    }

    @Test("an extraction that cannot be stored is shown for this opening")
    func storeFails() async throws {
        let setup = try await Self.setup()
        defer { setup.fixture.remove() }
        let loader = Self.loader(setup, transport: Self.answering())
        try setup.library.close()
        let outcome = try await loader.load(article: setup.article, link: Self.link, feed: Self.excerpt)
        guard case .extracted(_, stored: false) = outcome else {
            Issue.record("\(outcome)")
            return
        }
    }

    @Test("the page is decoded in the charset its meta declaration names")
    func charset() async throws {
        let setup = try await Self.setup()
        defer { setup.fixture.remove() }
        let body = try PageFixture.data("ja-shift_jis-meta.html")
        let transport = FakeTransport.answering(status: 200, body: body, headers: ["Content-Type": "text/html"], finalURL: Self.link)
        let extractor = StubExtractor()
        _ = try await Self.loader(setup, transport: transport, extractor: extractor)
            .load(article: setup.article, link: Self.link, feed: Self.excerpt)
        let decoded = try #require(extractor.calls.first?.html)
        #expect(decoded.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) })
        #expect(!decoded.contains("\u{FFFD}"))
    }

    // MARK: - Criterion 3: decision 6's table

    /// Loads once with `transport` and `extractor`, and says what came of it
    /// and whether the next opening would fetch.
    private func outcome(
        transport: any Transport, extractor: StubExtractor = StubExtractor(), inFront: Bool = true
    ) async throws -> (outcome: BodyLoader.Outcome, remembered: Bool, stored: Bool) {
        let setup = try await Self.setup()
        defer { setup.fixture.remove() }
        let loader = Self.loader(setup, transport: transport, extractor: extractor) { inFront }
        let outcome = try await loader.load(article: setup.article, link: Self.link, feed: Self.excerpt)
        let stored = try await setup.library.extraction(ofArticle: setup.article) != nil
        return (outcome, loader.remembersFailure(ofArticle: setup.article), stored)
    }

    @Test("criterion 3: no answer, the transport's deadline, 408, 429 and 5xx are not remembered")
    func transientFailures() async throws {
        for failure in [TransportFailure.unreachable, .timedOut] {
            let result = try await outcome(transport: FakeTransport.failing(failure))
            #expect(result.outcome == .failed(.transport(failure), remembered: false))
            #expect(!result.remembered)
            #expect(!result.stored)
        }
        for status in [408, 429, 500, 502, 503, 599] {
            let result = try await outcome(transport: Self.answering("", status: status))
            #expect(result.outcome == .failed(.status(status), remembered: false), "\(status)")
            #expect(!result.remembered)
        }
    }

    @Test("criterion 3: every other failure is remembered")
    func lastingFailures() async throws {
        for status in [301, 304, 400, 401, 403, 404, 410, 451] {
            let result = try await outcome(transport: Self.answering("", status: status))
            #expect(result.outcome == .failed(.status(status), remembered: true), "\(status)")
            #expect(result.remembered)
        }
        for failure in [TransportFailure.tooLarge, .tooManyRedirects, .unsupportedAddress, .declinedAuthentication(status: 401)] {
            let result = try await outcome(transport: FakeTransport.failing(failure))
            #expect(result.outcome == .failed(.transport(failure), remembered: true), "\(failure)")
        }
        // Not HTML.
        let notHTML = try await outcome(transport: Self.answering("plain text", type: "text/plain"))
        #expect(notHTML.outcome == .failed(.notHTML, remembered: true))
        // Over the extractor's bounds, its deadline, its process ended, a
        // null result, a script failure.
        for failure in [ExtractionFailure.inputTooLarge, .tooManyElements, .timedOut, .processEnded, .noArticle, .scriptFailed, .loadFailed] {
            let result = try await outcome(transport: Self.answering(), extractor: StubExtractor(failing: failure))
            #expect(result.outcome == .failed(.extraction(failure), remembered: true), "\(failure)")
            #expect(!result.stored)
        }
        // Not usable: a list page, and a page with less text than the feed.
        let list = try await outcome(transport: Self.answering(), extractor: StubExtractor(html: BodyPlanTests.listPage))
        #expect(list.outcome == .failed(.notUsable, remembered: true))
        #expect(!list.stored)
    }

    @Test("criterion 3: a rule list that cannot be compiled says nothing about the page")
    func ruleListFailure() async throws {
        let result = try await outcome(transport: Self.answering(), extractor: StubExtractor(failing: .ruleListUnavailable))
        #expect(result.outcome == .failed(.extraction(.ruleListUnavailable), remembered: false))
    }

    @Test("criterion 3: any failure while the app is not in front is not remembered")
    func notInFront() async throws {
        let result = try await outcome(transport: Self.answering("", status: 404), inFront: false)
        #expect(result.outcome == .failed(.status(404), remembered: false))
        #expect(!result.remembered)
        let extraction = try await outcome(transport: Self.answering(), extractor: StubExtractor(failing: .processEnded), inFront: false)
        #expect(extraction.outcome == .failed(.extraction(.processEnded), remembered: false))
    }

    @Test("criterion 3: a failure of a load during which the app left the front is not remembered, though the app is in front again")
    func leftTheFrontDuringTheLoad() async throws {
        let setup = try await Self.setup()
        defer { setup.fixture.remove() }
        let extractor = StubExtractor(failing: .timedOut, waits: true)
        let loader = Self.loader(setup, transport: Self.answering(), extractor: extractor)
        let task = Task { try await loader.load(article: setup.article, link: Self.link, feed: Self.excerpt) }
        await extractor.started.wait()
        loader.appLeftFront()
        extractor.finish()
        #expect(try await task.value == .failed(.extraction(.timedOut), remembered: false))
        #expect(!loader.remembersFailure(ofArticle: setup.article))

        // A load that starts after the absence remembers as before.
        let second = StubExtractor(failing: .timedOut)
        let again = Self.loader(setup, transport: Self.answering(), extractor: second)
        again.appLeftFront()
        #expect(try await again.load(article: setup.article, link: Self.link, feed: Self.excerpt) == .failed(.extraction(.timedOut), remembered: true))
    }

    @Test("criterion 3: the memory ends after an hour and when a source's settings are saved")
    func memoryEnds() async throws {
        let setup = try await Self.setup()
        defer { setup.fixture.remove() }
        let clock = TestClock()
        let loader = Self.loader(setup, transport: Self.answering("", status: 404), clock: clock)
        _ = try await loader.load(article: setup.article, link: Self.link, feed: Self.excerpt)
        #expect(loader.remembersFailure(ofArticle: setup.article))
        clock.advance(seconds: 59 * 60)
        #expect(loader.remembersFailure(ofArticle: setup.article))
        clock.advance(seconds: 60)
        #expect(!loader.remembersFailure(ofArticle: setup.article))

        _ = try await loader.load(article: setup.article, link: Self.link, feed: Self.excerpt)
        #expect(loader.remembersFailure(ofArticle: setup.article))
        loader.forgetFailures()
        #expect(!loader.remembersFailure(ofArticle: setup.article))
        // Remembered per article.
        _ = try await loader.load(article: setup.article, link: Self.link, feed: Self.excerpt)
        #expect(!loader.remembersFailure(ofArticle: UUID()))
    }

    // MARK: - Criterion 9: leaving, and the workspace stopped

    @Test("criterion 9: leaving the article during its fetch or its extraction stores nothing")
    func cancelledStoresNothing() async throws {
        let setup = try await Self.setup()
        defer { setup.fixture.remove() }
        // During the fetch.
        let fetching = Signal()
        let transport = FakeTransport { _ in
            fetching.fire()
            try await Task.sleep(for: .seconds(30))
            return TransportResponse(finalURL: Self.link, status: 200, headers: ["Content-Type": Self.html], body: Data(Self.page.utf8))
        }
        let loader = Self.loader(setup, transport: transport)
        let task = Task { try await loader.load(article: setup.article, link: Self.link, feed: Self.excerpt) }
        await fetching.wait()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!loader.remembersFailure(ofArticle: setup.article))

        // During the extraction, which ends with its answer just as the
        // article is left: the loader itself stores nothing.
        let extractor = StubExtractor(waits: true, answersWhenCancelled: true)
        let second = Self.loader(setup, transport: Self.answering(), extractor: extractor)
        let extracting = Task { try await second.load(article: setup.article, link: Self.link, feed: Self.excerpt) }
        await extractor.started.wait()
        extracting.cancel()
        await #expect(throws: CancellationError.self) { try await extracting.value }
        #expect(try await rowCounts(setup.library)["article_body"] == 0)
        #expect(!second.remembersFailure(ofArticle: setup.article))
    }

    @Test("a stopped loader starts no fetch, no extraction and no store")
    func stopped() async throws {
        let setup = try await Self.setup()
        defer { setup.fixture.remove() }
        // Stopped before: nothing is requested.
        let transport = Self.answering()
        let loader = Self.loader(setup, transport: transport)
        loader.stop()
        await #expect(throws: CancellationError.self) {
            try await loader.load(article: setup.article, link: Self.link, feed: Self.excerpt)
        }
        #expect(transport.received.isEmpty)
        try await setup.library.storeExtraction(html: Self.articleHTML, address: Self.link, ofArticle: setup.article)
        #expect(await loader.storedBody(ofArticle: setup.article, feed: Self.excerpt) == nil)
        try await setup.library.pool.write { db in try db.execute(sql: "DELETE FROM article_body") }

        // Stopped during the fetch: no extraction starts.
        let fetching = Signal()
        let release = Signal()
        let slow = FakeTransport { _ in
            fetching.fire()
            await release.wait()
            return TransportResponse(finalURL: Self.link, status: 200, headers: ["Content-Type": Self.html], body: Data(Self.page.utf8))
        }
        let extractor = StubExtractor()
        let second = Self.loader(setup, transport: slow, extractor: extractor)
        let task = Task { try await second.load(article: setup.article, link: Self.link, feed: Self.excerpt) }
        await fetching.wait()
        second.stop()
        release.fire()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(extractor.calls.isEmpty)

        // Stopped during the extraction: nothing is stored.
        let waiting = StubExtractor(waits: true)
        let third = Self.loader(setup, transport: Self.answering(), extractor: waiting)
        let extracting = Task { try await third.load(article: setup.article, link: Self.link, feed: Self.excerpt) }
        await waiting.started.wait()
        third.stop()
        waiting.finish()
        await #expect(throws: CancellationError.self) { try await extracting.value }
        #expect(try await rowCounts(setup.library)["article_body"] == 0)
    }

    // MARK: - Criterion 7: reader mode is handed no library

    @Test("criterion 7: the reader's call takes a transport and an extractor, and the library's rows are unchanged")
    func readerCallWritesNothing() async throws {
        let setup = try await Self.setup()
        defer { setup.fixture.remove() }
        let before = try await setup.fixture.articleTable()
        let counts = try await rowCounts(setup.library)
        // The call's signature: an address, a transport and an extractor.
        let call: (URL, any Transport, any PageExtracting) async throws -> ExtractedBody = BodyLoader.readerArticle(at:transport:extractor:)
        let article = try await call(Self.link, Self.answering(), StubExtractor())
        #expect(ArticleBlocks.isArticle(article.blocks.blocks))
        #expect(article.title == "One")
        // A list page: no readable article.
        await #expect(throws: PageFailure.notUsable) {
            try await call(Self.link, Self.answering(), StubExtractor(html: BodyPlanTests.listPage))
        }
        await #expect(throws: PageFailure.status(404)) {
            try await call(Self.link, Self.answering("", status: 404), StubExtractor())
        }
        #expect(try await setup.fixture.articleTable() == before)
        #expect(try await rowCounts(setup.library) == counts)
    }
}

/// An extractor that answers without a web view: the page's article, a
/// given HTML, a failure, or nothing until it is told to finish.
@MainActor
final class StubExtractor: PageExtracting {
    struct Call {
        var html: String
        var address: URL
    }

    private(set) var calls: [Call] = []
    let started = Signal()
    private let html: String?
    private let failure: ExtractionFailure?
    private let waits: Bool
    /// Whether the answer says the extractor cut it.
    private let cut: Bool
    /// Whether it answers rather than throws when its task is cancelled
    /// while it waits: an extraction that ended as the article was left.
    private let answersWhenCancelled: Bool
    private var release: CheckedContinuation<Void, Never>?
    private var released = false

    init(
        html: String? = nil, failing failure: ExtractionFailure? = nil, waits: Bool = false, answersWhenCancelled: Bool = false,
        cut: Bool = false
    ) {
        self.cut = cut
        self.html = html
        self.failure = failure
        self.waits = waits
        self.answersWhenCancelled = answersWhenCancelled
    }

    func extract(html page: String, address: URL) async throws -> PageExtraction {
        calls.append(Call(html: page, address: address))
        started.fire()
        if waits, !released {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if released {
                        continuation.resume()
                    } else {
                        release = continuation
                    }
                }
            } onCancel: {
                Task { @MainActor in self.finish() }
            }
        }
        if let failure {
            throw failure
        }
        if !answersWhenCancelled {
            try Task.checkCancellation()
        }
        return PageExtraction(html: html ?? BodyLoaderTests.articleHTML, title: "One", isCut: cut)
    }

    func finish() {
        released = true
        release?.resume()
        release = nil
    }
}
