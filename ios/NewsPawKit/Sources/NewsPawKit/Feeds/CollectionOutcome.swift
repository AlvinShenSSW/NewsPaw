/// How one collection of one source ended (spec N03, N04).
public enum CollectionOutcome: Sendable, Hashable {
    /// The server answered `304 Not Modified`. Counts as a success.
    case notModified
    /// A feed was read and stored. `complete` is false when the document
    /// stopped being well-formed part-way: the items completed before that
    /// point were stored and the validators cleared.
    case collected(newArticles: Int, complete: Bool)
    /// The collection failed; the reason was recorded on the source, whose
    /// articles and last success time are kept.
    case failed(CollectionFailure)
    /// Nothing was done: the source does not exist, is not a kind this
    /// collector handles, or was deleted or given another address while the
    /// fetch was in flight.
    case nothingDone
}
