import Foundation

/// Why a card shows a failure and its step (RD23 decision 12): a stored
/// `failed` row, or a block of the writer.
public enum OverviewIssue: Hashable, Sendable {
    case stored(TranslationFailure)
    case blocked(OverviewBlock.Reason)
}

/// What a category's card shows (decision 12, first match wins).
public enum OverviewCardState: Equatable, Sendable {
    /// Overviews off: the compact row with the unread count.
    case off
    /// Today's `done` overview in the reading language; `working` while a
    /// Rewrite runs.
    case done(StoredOverview, working: Bool)
    /// "Writing overview…".
    case working
    /// A stored failure or a block of today and this language.
    case failed(OverviewIssue)
    /// No primary slot: "Set up a model to get overviews".
    case noModel
    /// "⟨N⟩ new articles, no overview for today yet" and Write Overview.
    case write(count: Int)
    /// The compact "Nothing new today" row.
    case nothingNew
}

/// The card's state from what the app holds (decision 12). Pure.
public enum OverviewCardRule {
    /// - Parameters:
    ///   - row: the category's row as last read; shown only when it is of
    ///     `day` and `locale` (review round 1, G2).
    ///   - day: today's key now.
    ///   - locale: the reading language now.
    public static func state(
        mode: OverviewMode, row: StoredOverview?, working: Bool, block: OverviewBlock?, hasPrimary: Bool, newCount: Int,
        day: String, locale: ReadingLocale
    ) -> OverviewCardState {
        if mode == .off {
            return .off
        }
        // A row read for another day or reading language, kept because the
        // read that replaces it failed, is not shown.
        let row = row.flatMap { $0.day == day && $0.locale == locale ? $0 : nil }
        if let row, row.state == .done {
            return .done(row, working: working)
        }
        if working {
            return .working
        }
        if let row, row.state == .failed {
            return .failed(.stored(row.failure ?? .malformed))
        }
        if let block, block.day == day, block.locale == locale {
            return .failed(.blocked(block.reason))
        }
        if !hasPrimary {
            return .noModel
        }
        if newCount > 0 {
            return .write(count: newCount)
        }
        return .nothingNew
    }
}
