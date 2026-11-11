/// The two partitions of the reader (spec N02). The raw values are the ones the
/// configuration file uses (spec section 5), so they must not change.
public enum Partition: String, Sendable, CaseIterable {
    case normal
    case adult
}
