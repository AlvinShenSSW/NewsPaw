/// The switches that decide what this build contains (spec 6.1).
public enum BuildFeatures {
    /// The adult partition's one feature switch (spec 6.1, item 3; RD18
    /// decision 1). Every entry point of the partition sits behind it: with
    /// it off the gate is unavailable whatever the preferences say, the
    /// interface shows no Settings row and no partition switch, and the
    /// adult library is neither opened nor created.
    public static let adultPartition = true
}
