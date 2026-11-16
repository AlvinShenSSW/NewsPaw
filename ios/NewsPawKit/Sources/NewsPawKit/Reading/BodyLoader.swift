import Foundation

/// An article reduced from its page, ready to lay out: its blocks and the
/// address that answered.
public struct ExtractedBody: Sendable, Hashable {
    public let blocks: ArticleBlocks
    /// The extraction's title, as Readability read it; empty for a stored
    /// one, whose envelope does not keep it.
    public let title: String
    public let address: URL
}

/// Why a page gave no body (RD12 decision 6).
public enum PageFailure: Error, Sendable, Hashable {
    /// The transport produced no answer to use.
    case transport(TransportFailure)
    /// An answer that is not 2xx.
    case status(Int)
    /// A 2xx answer that is not HTML.
    case notHTML
    case extraction(ExtractionFailure)
    /// The extraction is not an article, or not more than the feed's own
    /// content.
    case notUsable

    /// Whether the failure says something about the page, and is therefore
    /// remembered for an hour: everything but no answer, the transport's
    /// deadline, a status of 408, 429 or 5xx, and a rule list that could
    /// not be compiled (which says nothing about any page).
    public var isLasting: Bool {
        switch self {
        case .transport(.unreachable), .transport(.timedOut):
            false
        case .transport:
            true
        case .status(let status):
            !(status == 408 || status == 429 || (500...599).contains(status))
        case .notHTML, .notUsable:
            true
        case .extraction(.ruleListUnavailable):
            false
        case .extraction:
            true
        }
    }
}

/// Loads an article's body from its page (spec N04, N05, N12; RD12
/// decisions 3 to 6): a library, a transport and an extractor in; a body or
/// a failure out. The workspace's reading model owns one.
///
/// The page is one request through the app's transport (the one collection
/// uses: no credentials, no cookies, the collection rules), made when the
/// article is opened, never at refresh. Only a 2xx answer that is HTML is
/// used; its whole body is decoded and handed to the extractor; what comes
/// back is converted by `ArticleBlocks` and kept only when it is usable
/// (`BodyPlan.isUsable`). A cancelled load stores nothing.
///
/// Failures are never stored. Those that say something about the page are
/// remembered for an hour in this object's memory, unless the app was not
/// in front when they happened or left the front at any moment of the load
/// (`appLeftFront()`); the memory is emptied by `forgetFailures()`
/// (a source's settings saved) and with the object (a relaunch).
@MainActor
public final class BodyLoader {
    /// How long a lasting failure is remembered.
    public static let memoryLifetime: TimeInterval = 60 * 60

    /// What a load came to.
    public enum Outcome: Sendable, Hashable {
        /// The page's article; `stored` is false when it could not be kept.
        case extracted(ExtractedBody, stored: Bool)
        /// No body: the fallback is shown. `remembered` says whether the
        /// next opening within the hour shows it without a request.
        case failed(PageFailure, remembered: Bool)
        /// The article no longer exists: the result was dropped.
        case articleGone
    }

    private let library: Library
    private let transport: any Transport
    private let extractor: any PageExtracting
    private let now: @Sendable () -> Date
    private let isInFront: @MainActor () -> Bool
    /// The lasting failures, by article, with the time each happened.
    private var failures: [UUID: Date] = [:]
    /// Set when the workspace is dropped: nothing starts from here on.
    private(set) var isStopped = false
    /// How many times the app has left the front: a load during which it
    /// did remembers no failure, since a deadline counts the time the app
    /// was suspended and a process may be ended meanwhile.
    private var departures = 0

    public init(
        library: Library, transport: any Transport, extractor: any PageExtracting,
        now: @escaping @Sendable () -> Date = { Date() }, isInFront: @escaping @MainActor () -> Bool = { true }
    ) {
        self.library = library
        self.transport = transport
        self.extractor = extractor
        self.now = now
        self.isInFront = isInFront
    }

    /// The extraction stored with the article, converted, when it is still
    /// usable against `feed`; `nil` otherwise or when it cannot be read.
    public func storedBody(ofArticle id: UUID, feed: [ArticleBlock]) async -> ExtractedBody? {
        guard !isStopped, let stored = try? await library.extraction(ofArticle: id), !Task.isCancelled else { return nil }
        let blocks = await Self.convert(html: stored.html, baseURL: stored.address)
        guard !isStopped, BodyPlan.isUsable(blocks.blocks, over: feed) else { return nil }
        return ExtractedBody(blocks: blocks, title: "", address: stored.address)
    }

    /// Whether a lasting failure of the article's page is remembered: the
    /// next opening then shows the fallback without a request.
    public func remembersFailure(ofArticle id: UUID) -> Bool {
        guard let at = failures[id] else { return false }
        let age = now().timeIntervalSince(at)
        if age < Self.memoryLifetime, age >= 0 {
            return true
        }
        failures[id] = nil
        return false
    }

    /// Fetches the article's page at `link`, extracts it, and stores the
    /// extraction when it is usable against `feed`.
    ///
    /// - Throws: only `CancellationError`, when the calling task was
    ///   cancelled or the loader stopped; then nothing was stored or
    ///   remembered.
    public func load(article id: UUID, link: URL, feed: [ArticleBlock]) async throws -> Outcome {
        guard !isStopped else { throw CancellationError() }
        let departuresAtStart = departures
        let body: ReadPage
        do {
            body = try await Self.readPage(at: link, transport: transport, extractor: extractor) { [weak self] in
                self.map { !$0.isStopped } ?? false
            }
            guard BodyPlan.isUsable(body.blocks.blocks, over: feed) else {
                throw PageFailure.notUsable
            }
        } catch let failure as PageFailure {
            try checkGoing()
            let remembered = failure.isLasting && isInFront() && departures == departuresAtStart
            if remembered {
                failures[id] = now()
            }
            return .failed(failure, remembered: remembered)
        }
        try checkGoing()
        do {
            try await library.storeExtraction(html: body.html, address: body.address, ofArticle: id)
            return .extracted(body.extracted, stored: true)
        } catch LibraryError.unknownArticle {
            return .articleGone
        } catch {
            return .extracted(body.extracted, stored: false)
        }
    }

    /// The app is leaving the front (the scene will deactivate): a load
    /// under way now remembers no failure.
    public func appLeftFront() {
        departures += 1
    }

    /// Empties the memory of failures: a source's settings were saved.
    public func forgetFailures() {
        failures = [:]
    }

    /// The workspace is dropped: no fetch, extraction or store starts from
    /// here on, and one in flight stores nothing.
    public func stop() {
        isStopped = true
        failures = [:]
    }

    private func checkGoing() throws {
        if isStopped || Task.isCancelled {
            throw CancellationError()
        }
    }

    // MARK: - Reader mode (decision 7)

    /// The article of the page at `url`, for reader mode: the same fetch
    /// and extraction as an article's, handed a transport and an extractor
    /// and no library, so that it cannot write one. Its result is an
    /// article (`ArticleBlocks.isArticle`) or a failure; nothing is
    /// remembered.
    ///
    /// - Throws: a `PageFailure`, or `CancellationError`.
    public static func readerArticle(at url: URL, transport: any Transport, extractor: any PageExtracting) async throws -> ExtractedBody {
        let page = try await readPage(at: url, transport: transport, extractor: extractor) { true }
        guard ArticleBlocks.isArticle(page.blocks.blocks) else {
            throw PageFailure.notUsable
        }
        return page.extracted
    }

    // MARK: - The fetch and the extraction

    /// A page read and reduced: what is stored and what is shown.
    struct ReadPage: Sendable {
        let html: String
        let title: String
        let address: URL
        let blocks: ArticleBlocks

        var extracted: ExtractedBody {
            ExtractedBody(blocks: blocks, title: title, address: address)
        }
    }

    /// One request through `transport` under its rules, a 2xx HTML answer
    /// decoded whole, the extractor, and the conversion.
    ///
    /// - Parameter going: false once the caller has stopped: then no
    ///   extraction starts.
    /// - Throws: a `PageFailure`, or `CancellationError`.
    static func readPage(
        at url: URL, transport: any Transport, extractor: any PageExtracting, going: @MainActor () -> Bool
    ) async throws -> ReadPage {
        guard url.isCollectableAddress else {
            throw PageFailure.transport(.unsupportedAddress)
        }
        let response: TransportResponse
        do {
            response = try await transport.fetch(TransportRequest(url: url))
        } catch let failure as TransportFailure {
            try Task.checkCancellation()
            throw PageFailure.transport(failure)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw PageFailure.transport(.unreachable)
        }
        try Task.checkCancellation()
        guard (200...299).contains(response.status) else {
            throw PageFailure.status(response.status)
        }
        guard let html = await decode(response) else {
            throw PageFailure.notHTML
        }
        guard going() else { throw CancellationError() }
        try Task.checkCancellation()
        let extraction: PageExtraction
        do {
            extraction = try await extractor.extract(html: html, address: response.finalURL)
        } catch let failure as ExtractionFailure {
            try Task.checkCancellation()
            throw PageFailure.extraction(failure)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw PageFailure.extraction(.scriptFailed)
        }
        try Task.checkCancellation()
        let blocks = await convert(html: extraction.html, baseURL: response.finalURL)
        return ReadPage(html: extraction.html, title: extraction.title, address: response.finalURL, blocks: blocks)
    }

    /// The answer's whole body as text when it is HTML (`FeedDiscovery`'s
    /// test and decoding: the charset of its `Content-Type`, else of its
    /// `meta` declaration, else UTF-8), off the main actor.
    @concurrent
    static func decode(_ response: TransportResponse) async -> String? {
        let bytes = [UInt8](response.body)
        let contentType = ContentType(response.header("Content-Type"))
        guard FeedDiscovery.isHTML(bytes, mediaType: contentType.mediaType) else { return nil }
        let label = contentType.charset ?? FeedDiscovery.scan(Array(bytes.prefix(FeedDiscovery.charsetBytes))).charset
        return FeedDiscovery.decode(bytes, label: label)
    }

    /// `ArticleBlocks.make`, off the main actor.
    @concurrent
    static func convert(html: String, baseURL: URL) async -> ArticleBlocks {
        ArticleBlocks.make(html: html, baseURL: baseURL)
    }
}
