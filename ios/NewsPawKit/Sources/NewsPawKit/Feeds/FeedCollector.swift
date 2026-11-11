import Foundation

/// Collects one feed source of one library (spec N03, N04): reads the
/// source, fetches its address under the transport's rules, and stores the
/// new articles and the source's status.
///
/// A feed-level failure is an outcome recorded on the source, never a thrown
/// error; only cancellation and a storage failure throw. The collector does
/// not look at `paused`: whether a paused source is collected is the
/// caller's rule.
public struct FeedCollector: Sendable {
    private let fetcher: FeedFetcher

    public init(transport: any Transport) {
        fetcher = FeedFetcher(transport: transport)
    }

    /// Collects the source `sourceID` of `library`.
    ///
    /// - Throws: `CancellationError` when the task is cancelled, after which
    ///   nothing has been recorded; a `LibraryError` when storage fails.
    public func collect(_ sourceID: UUID, in library: Library) async throws -> CollectionOutcome {
        guard let target = try await library.collectionTarget(sourceID) else {
            return .nothingDone
        }
        let result = try await fetcher.fetch(target.url, etag: target.etag, lastModified: target.lastModified)
        try Task.checkCancellation()
        return try await library.storeCollection(result, for: target, at: library.now())
    }
}
