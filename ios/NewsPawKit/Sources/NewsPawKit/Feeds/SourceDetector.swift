import Foundation

/// One item of a feed's preview.
public struct PreviewItem: Sendable, Hashable {
    public let title: String?
    public let publishedAt: Date?
}

/// A feed that was fetched and parsed and can be saved as it is: Save
/// stores the articles parsed here and makes no request (RD05 decision 7).
public struct FeedCandidate: Sendable, Hashable {
    /// The address to store: the requested normal form, or its https twin
    /// when the fetch ended there (RD05 decision 3).
    public let address: String
    /// The kind of source Save stores: `github` for one of a repository's
    /// built feeds (RD07 decision 9), else `feed`.
    public let kind: SourceKind
    public let format: ParsedFeed.Format
    /// The feed's own title.
    public let title: String?
    /// The feed's site link, else the page the feed was declared on.
    public let siteURL: String?
    /// Up to three items: dated ones newest first, then undated ones in
    /// feed order.
    public let latestItems: [PreviewItem]
    /// The newest published time among the items.
    public let newestItemAt: Date?
    public let itemCount: Int
    /// What Save stores.
    let fetched: FetchedFeed

    init(address: String, fetched: FetchedFeed, pageAddress: String?, kind: SourceKind = .feed) {
        self.address = address
        self.kind = kind
        self.fetched = fetched
        let feed = fetched.feed
        format = feed.format
        title = feed.title
        siteURL = feed.siteURL ?? pageAddress
        itemCount = feed.items.count
        let dated = feed.items.filter { $0.publishedAt != nil }
            .enumerated()
            .sorted { first, second in
                // Newest first; equal times keep feed order.
                first.element.publishedAt! != second.element.publishedAt!
                    ? first.element.publishedAt! > second.element.publishedAt!
                    : first.offset < second.offset
            }
            .map(\.element)
        let undated = feed.items.filter { $0.publishedAt == nil }
        latestItems = (dated + undated).prefix(3).map { PreviewItem(title: $0.title, publishedAt: $0.publishedAt) }
        newestItemAt = dated.first?.publishedAt
    }
}

/// A feed a page declares, as detection left it.
public struct DeclaredCandidate: Sendable, Hashable, Identifiable {
    public enum State: Sendable, Hashable {
        /// Fetched and parsed: it can be chosen.
        case usable(FeedCandidate)
        /// Already in this library: it was not fetched (or, after an https
        /// upgrade, is not saved again) and cannot be chosen.
        case alreadyAdded(ExistingSource)
        /// Its fetch failed: it cannot be chosen.
        case failed(CollectionFailure)
        /// Not answered within the candidate limit. Choosing it runs an
        /// ordinary detection on its address.
        case notChecked
    }

    /// The declared address in normal form.
    public let address: String
    /// The `title` the page gave its `<link>`.
    public let declaredTitle: String?
    public let state: State

    public var id: String { address }
}

/// A document that is not a feed.
public struct PageDetection: Sendable, Hashable {
    /// The address to store for a web-page source (decision 3 applied).
    public let address: String
    /// The page's title, when it is HTML and has one.
    public let title: String?
    /// The declared feeds, at most five, in document order.
    public let candidates: [DeclaredCandidate]
    /// How many distinct feeds the page declares, before the cap.
    public let declaredCount: Int
}

/// A GitHub repository whose feeds were checked (RD07 decision 6).
public struct GitHubDetection: Sendable, Hashable {
    public let repository: GitHubRepository
    /// The typed address's normal form: what "This page itself" saves.
    public let address: String
    /// Releases, Tags and Commits, in that order, each at its built address.
    public let candidates: [DeclaredCandidate]

    /// Which of the repository's feeds `candidate` is.
    public func feed(of candidate: DeclaredCandidate) -> GitHubFeed? {
        GitHubFeed.allCases.first { repository.feedAddress($0) == candidate.address }
    }
}

/// Why the typed address could not be read.
public struct DetectionFailure: Sendable, Hashable {
    /// The requested normal form.
    public let address: String
    public let reason: CollectionFailure
    /// Whether the site answered but the app's fetch could not use the
    /// answer, so the address may still be saved as a web page (RD05
    /// decision 9).
    public let offersWebPage: Bool
    /// Whether the app put `https://` in front of what was typed.
    public let addedScheme: Bool
}

/// What one detection found (spec N03, ux S6).
public enum Detection: Sendable, Hashable {
    /// The address is refused before any request.
    case invalidAddress(SourceAddressProblem)
    /// The address is already in this library.
    case duplicate(ExistingSource)
    /// The address is a feed.
    case feed(FeedCandidate)
    /// The address is a document that is not a feed.
    case page(PageDetection)
    /// The address is a GitHub repository with at least one feed that can
    /// be offered (RD07).
    case github(GitHubDetection)
    /// The address could not be read.
    case failed(DetectionFailure)
}

/// Turns a typed address into a `Detection` (spec N03; RD05 decisions 1–9).
/// It only reads the library: nothing is written until Save.
///
/// The address is looked up in the library before anything is fetched; the
/// page is requested once; each feed the page declares is looked up, then
/// fetched once, at most `maximumConcurrentCandidates` at a time, the whole
/// phase within `candidateLimit`. Nothing else the page mentions is
/// requested.
///
/// A GitHub repository address (RD07) is not looked up and its page is not
/// fetched: its three built feed addresses go through the same candidate
/// phase instead. When all three are gone, the address takes the path
/// above.
public struct SourceDetector: Sendable {
    /// Candidate fetches in flight at once.
    public static let maximumConcurrentCandidates = 4

    private let fetcher: FeedFetcher
    private let candidateLimit: Duration

    /// - Parameter candidateLimit: the overall limit of the candidate phase,
    ///   20 seconds; tests and the UI-test fixtures inject a shorter one.
    public init(transport: any Transport, candidateLimit: Duration = .seconds(20)) {
        fetcher = FeedFetcher(transport: transport)
        self.candidateLimit = candidateLimit
    }

    /// Detects what `text` is, against `library`.
    ///
    /// - Throws: `CancellationError` when cancelled; a `LibraryError` when a
    ///   lookup fails. Every network failure is a result.
    public func detect(_ text: String, in library: Library) async throws -> Detection {
        let parsed: SourceAddress
        switch SourceAddress.parse(text) {
        case .failure(let problem): return .invalidAddress(problem)
        case .success(let address): parsed = address
        }
        let requested = parsed.normalForm
        if let repository = GitHubRepository(normalForm: requested) {
            if let detection = try await detectRepository(repository, typed: requested, in: library) {
                return detection
            }
            // All three gone: not a public repository. The ordinary path
            // runs on the typed address (RD07 decision 4).
            try Task.checkCancellation()
        }
        if let existing = try await library.existingSource(atAddress: requested) {
            return .duplicate(existing)
        }
        let result = try await fetcher.fetch(requested)
        try Task.checkCancellation()

        let finalURL: URL? = switch result {
        case .feed(let fetched): fetched.finalURL
        case .notAFeed(let document): document.finalURL
        case .failed, .notModified: nil
        }
        var stored = requested
        if let finalURL, let upgraded = SourceAddress.upgrade(requested: requested, finalURL: finalURL) {
            if let existing = try await library.existingSource(atAddress: upgraded) {
                return .duplicate(existing)
            }
            stored = upgraded
        }

        switch result {
        case .feed(let fetched):
            return .feed(FeedCandidate(address: stored, fetched: fetched, pageAddress: nil))
        case .notAFeed(let document):
            let page = FeedDiscovery.read(document, requested: requested)
            let candidates = try await check(page.feeds, declaredOn: stored, in: library)
            return .page(PageDetection(
                address: stored, title: page.title, candidates: candidates, declaredCount: page.declaredCount
            ))
        case .failed(let reason):
            return .failed(failure(reason, address: requested, addedScheme: parsed.addedScheme))
        case .notModified:
            // No validators are sent, so a 304 is an answer the app cannot use.
            return .failed(failure(.httpStatus(304), address: requested, addedScheme: parsed.addedScheme))
        }
    }

    /// Checks the repository's three feeds, built and never read from a
    /// page, looked up ignoring ASCII case (RD07 decisions 2–6). `nil` when
    /// all three are gone.
    private func detectRepository(_ repository: GitHubRepository, typed: String, in library: Library) async throws -> Detection? {
        let feeds = GitHubFeed.allCases.map { DeclaredFeed(address: repository.feedAddress($0), title: nil) }
        let candidates = try await check(
            feeds, declaredOn: repository.pageAddress, kind: .github, ignoringCase: true, in: library
        )
        if candidates.allSatisfy({ $0.state == .failed(.gone) }) {
            return nil
        }
        let offerable = candidates.contains { candidate in
            if case .failed = candidate.state { false } else { true }
        }
        guard offerable else {
            // The built addresses are https: the hint about http does not
            // apply.
            guard case .failed(let reason) = candidates[0].state else { return nil }
            return .failed(failure(reason, address: typed, addedScheme: false))
        }
        return .github(GitHubDetection(repository: repository, address: typed, candidates: candidates))
    }

    private func failure(_ reason: CollectionFailure, address: String, addedScheme: Bool) -> DetectionFailure {
        let offersWebPage = switch reason {
        case .httpStatus, .tooLarge, .tooManyRedirects: true
        case .unreachable, .timedOut, .gone, .notAFeed, .unsupportedAddress: false
        }
        return DetectionFailure(address: address, reason: reason, offersWebPage: offersWebPage, addedScheme: addedScheme)
    }

    // MARK: - Candidates

    /// Looks each declared feed up, then fetches the ones not in the
    /// library, within the overall limit.
    ///
    /// - Parameters:
    ///   - kind: the kind a usable candidate is saved as.
    ///   - ignoringCase: whether the lookup ignores ASCII case (a
    ///     repository's built feeds); a declared feed is looked up exactly.
    private func check(
        _ feeds: [DeclaredFeed], declaredOn page: String, kind: SourceKind = .feed, ignoringCase: Bool = false,
        in library: Library
    ) async throws -> [DeclaredCandidate] {
        var states: [DeclaredCandidate.State?] = Array(repeating: nil, count: feeds.count)
        var pending: [Int] = []
        for (index, feed) in feeds.enumerated() {
            if let existing = try await library.existingSource(atAddress: feed.address, ignoringCase: ignoringCase) {
                states[index] = .alreadyAdded(existing)
            } else {
                pending.append(index)
            }
        }

        if !pending.isEmpty {
            let fetcher = fetcher
            let limit = candidateLimit
            // An index of -1 is the limit's timer.
            await withTaskGroup(of: (Int, DeclaredCandidate.State?).self) { group in
                group.addTask {
                    try? await Task.sleep(for: limit)
                    return (-1, nil)
                }
                var next = 0
                var running = 0
                func launch() {
                    let index = pending[next]
                    let address = feeds[index].address
                    next += 1
                    running += 1
                    group.addTask {
                        let state = try? await Self.fetchCandidate(
                            address, declaredOn: page, kind: kind, with: fetcher, in: library
                        )
                        return (index, state)
                    }
                }
                while running < Self.maximumConcurrentCandidates, next < pending.count {
                    launch()
                }
                for await (index, state) in group {
                    guard index >= 0 else {
                        // The limit: what has not answered is not checked.
                        group.cancelAll()
                        break
                    }
                    states[index] = state
                    running -= 1
                    if next < pending.count {
                        launch()
                    } else if running == 0 {
                        group.cancelAll()
                        break
                    }
                }
            }
            try Task.checkCancellation()
        }

        return feeds.enumerated().map { index, feed in
            DeclaredCandidate(address: feed.address, declaredTitle: feed.title, state: states[index] ?? .notChecked)
        }
    }

    /// Fetches one declared feed. `nil` when cancelled: by the limit, it is
    /// not checked.
    private static func fetchCandidate(
        _ address: String, declaredOn page: String, kind: SourceKind, with fetcher: FeedFetcher, in library: Library
    ) async throws -> DeclaredCandidate.State {
        let result = try await fetcher.fetch(address)
        try Task.checkCancellation()
        switch result {
        case .feed(let fetched):
            var stored = address
            if let upgraded = SourceAddress.upgrade(requested: address, finalURL: fetched.finalURL) {
                if let existing = try await library.existingSource(atAddress: upgraded) {
                    return .alreadyAdded(existing)
                }
                stored = upgraded
            }
            return .usable(FeedCandidate(address: stored, fetched: fetched, pageAddress: page, kind: kind))
        case .notAFeed:
            return .failed(.notAFeed)
        case .failed(let reason):
            return .failed(reason)
        case .notModified:
            return .failed(.httpStatus(304))
        }
    }
}
