#if DEBUG
import Foundation

/// What the UI tests ask of a debug build through the launch environment.
/// Release builds contain none of this.
struct DebugLaunchOptions {
    /// A directory inside the app's temporary directory, used instead of the
    /// real library directory.
    let libraryDirectory: URL?
    /// Synthetic sources to insert into the first category.
    let syntheticSources: Int?
    /// Whether the next category save fails.
    let failNextSave: Bool
    /// How long the next save waits before it runs.
    let slowNextSave: Duration?
    /// Whether the next source save fails.
    let failNextSourceSave: Bool
    /// Seconds added to the clock of the library and of Today's status line,
    /// from a whole number of days: it makes a refresh due and ages
    /// articles.
    let clockOffset: TimeInterval

    init(environment: [String: String]) {
        if let name = environment[UITestLaunchKey.libraryDirectory], Self.isSinglePathComponent(name) {
            libraryDirectory = FileManager.default.temporaryDirectory
                .appending(path: name, directoryHint: .isDirectory)
        } else {
            libraryDirectory = nil
        }
        if let text = environment[UITestLaunchKey.syntheticSources], let count = Int(text), count > 0 {
            syntheticSources = count
        } else {
            syntheticSources = nil
        }
        failNextSave = environment[UITestLaunchKey.failNextSave] == "1"
        failNextSourceSave = environment[UITestLaunchKey.failNextSourceSave] == "1"
        if let text = environment[UITestLaunchKey.slowNextSave], let seconds = Int(text), seconds > 0 {
            slowNextSave = .seconds(seconds)
        } else {
            slowNextSave = nil
        }
        if let text = environment[UITestLaunchKey.clockOffsetDays], let days = Int(text) {
            clockOffset = TimeInterval(days) * 86_400
        } else {
            clockOffset = 0
        }
    }

    /// Accepts only a name that stays inside the temporary directory.
    static func isSinglePathComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}
#endif
