#if DEBUG
import Foundation
import NewsPawKit

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
    /// The next search read fails (RD25).
    let failNextSearch: Bool
    /// How long the next save waits before it runs.
    let slowNextSave: Duration?
    /// Whether the next source save fails.
    let failNextSourceSave: Bool
    /// Seconds added to the clock of the library and of Today's status line,
    /// from a whole number of days: it makes a refresh due and ages
    /// articles. Applied only together with `libraryDirectory`, like the
    /// fixture transport; without it the clock is `Date()`.
    let clockOffset: TimeInterval
    /// What the stand-in authenticator answers, in order (RD18 decision
    /// 15); with none it answers "unavailable". Used only together with
    /// `libraryDirectory`.
    let authenticationSteps: [FixtureAuthenticator.Step]
    /// Whether the adult partition's feature switch is off for this launch
    /// (RD18 decision 1). It can only turn the feature off, and only
    /// together with `libraryDirectory`.
    let adultFeatureOff: Bool
    /// The rows a list page holds, so that a UI test reaches the next page
    /// after a few rows. Applied only together with `libraryDirectory`.
    let articlePageSize: Int?
    /// The OPML document "Import OPML" reads instead of presenting the file
    /// picker (RD08 decision 8). Applied only together with
    /// `libraryDirectory`.
    let opmlFixture: OPMLFixture?
    /// The translator fixture's models to set up in the normal library
    /// (RD14): the primary, and the backup after it. Applied only together
    /// with `libraryDirectory`, and only to a library with no model yet.
    let translationModels: [ModelRole]
    /// The daily automatic limit to store (RD14 decision 8). Applied only
    /// together with `libraryDirectory`.
    let dailyAutomaticLimit: Int?
    /// Whether the first run may be shown (RD21 decision 1): under a UI-test
    /// library directory it is shown, and its flag kept, only when asked
    /// for, so that the other suites start on the shell.
    let firstRun: Bool
    /// Whether the deletion of the next category move fails (RD19
    /// criterion 12). Applied only together with `libraryDirectory`.
    let failNextMoveDeletion: Bool
    /// How long a category move waits between its copy and its deletion,
    /// so that a lock can come during the run (RD19 criterion 12). Applied
    /// only together with `libraryDirectory`.
    let moveStepPause: Duration?
    /// How long Clear Browsing Data waits before it clears (review round
    /// 2). Applied only together with `libraryDirectory`.
    let clearPause: Duration?
    /// Whether five usage rows of `seed-<partition>` are inserted into the
    /// normal library at launch and into the adult library at each unlock
    /// (RD17 decision 8). Applied only together with `libraryDirectory`.
    let seedsUsage: Bool
    /// Whether the "Deliver background refresh" control is shown (RD24
    /// review R3). Applied only together with `libraryDirectory`.
    let backgroundDelivery: Bool

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
        failNextSearch = environment[UITestLaunchKey.failNextSearch] == "1"
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
        authenticationSteps = (environment[UITestLaunchKey.authenticationAnswers] ?? "")
            .split(separator: ",")
            .compactMap { FixtureAuthenticator.Step(String($0)) }
        adultFeatureOff = environment[UITestLaunchKey.adultFeatureOff] == "1"
        if let text = environment[UITestLaunchKey.articlePageSize], let size = Int(text), size > 0 {
            articlePageSize = size
        } else {
            articlePageSize = nil
        }
        opmlFixture = environment[UITestLaunchKey.opmlFixture].flatMap(OPMLFixture.init(rawValue:))
        translationModels = switch environment[UITestLaunchKey.translationModels] {
        case "primary": [.primary]
        case "primary,backup": [.primary, .backup]
        default: []
        }
        if let text = environment[UITestLaunchKey.dailyAutomaticLimit], let limit = Int(text), limit >= 0 {
            dailyAutomaticLimit = limit
        } else {
            dailyAutomaticLimit = nil
        }
        firstRun = environment[UITestLaunchKey.firstRun] == "1"
        failNextMoveDeletion = environment[UITestLaunchKey.failNextMoveDeletion] == "1"
        if let text = environment[UITestLaunchKey.moveStepPause], let seconds = Int(text), seconds > 0 {
            moveStepPause = .seconds(seconds)
        } else {
            moveStepPause = nil
        }
        if let text = environment[UITestLaunchKey.clearPause], let seconds = Int(text), seconds > 0 {
            clearPause = .seconds(seconds)
        } else {
            clearPause = nil
        }
        seedsUsage = environment[UITestLaunchKey.seedUsage] == "1"
        backgroundDelivery = environment[UITestLaunchKey.backgroundDelivery] == "1"
    }

    /// Accepts only a name that stays inside the temporary directory.
    static func isSinglePathComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}
#endif
