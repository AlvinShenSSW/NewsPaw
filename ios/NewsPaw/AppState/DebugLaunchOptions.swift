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
    /// The configuration file "Import Configuration" reads instead of
    /// presenting the file picker (RD20 decision 10). Applied only
    /// together with `libraryDirectory`.
    let configurationFixture: ConfigurationFixture?
    /// How long a configuration import waits between its write and its
    /// completion (RD20 criterion 13). Applied only together with
    /// `libraryDirectory`.
    let configurationWritePause: Duration?
    /// Where the adult workspace's configuration export waits (RD20 review
    /// round 2). Applied only together with `libraryDirectory`.
    let configurationExportHold: ConfigurationExportHold?
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
    /// Whether the first body plan is held until the app is in the
    /// background (RD15 review round 3). Applied only together with
    /// `libraryDirectory`.
    let holdsFirstBodyPlan: Bool
    /// Whether the first write of body results fails (RD15 review round
    /// 4). Applied only together with `libraryDirectory`.
    let failsFirstBodyWrite: Bool
    /// Whether the slots are reported changed after the first temporary
    /// article is translated (RD15 review round 4). Applied only together
    /// with `libraryDirectory`.
    let changesSlotsAfterReader: Bool
    /// Whether Retry's write after a failed one is held for eight seconds
    /// (RD15 review round 5). Applied only together with
    /// `libraryDirectory`.
    let holdsRetryWrite: Bool
    /// The page translation ceiling per period (RD16 decision 11).
    /// Applied only together with `libraryDirectory`.
    let pageTranslationCeiling: Int?
    /// Whether three earlier `done` overviews are seeded for the first
    /// category at launch (RD23 decision 16). Applied only together with
    /// `libraryDirectory`.
    let seedOverviews: Bool
    /// Whether the live smoke run asked for the real services (#192): the
    /// real feed transport, the real model HTTP, the real clock and the
    /// real web pages, while the library, the keys, the preferences and the
    /// browser's website data stay the UI-test directory's own. Only
    /// together with `libraryDirectory`.
    let liveServices: Bool

    /// Whether the fixtures stand in for the network and the clock: under a
    /// UI-test library directory, unless the live services were asked for.
    var usesFixtures: Bool {
        libraryDirectory != nil && !liveServices
    }

    init(environment: [String: String]) {
        if let name = environment[UITestLaunchKey.libraryDirectory], Self.isSinglePathComponent(name) {
            libraryDirectory = FileManager.default.temporaryDirectory
                .appending(path: name, directoryHint: .isDirectory)
        } else {
            libraryDirectory = nil
        }
        liveServices = libraryDirectory != nil && environment[UITestLaunchKey.liveServices] == "1"
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
        configurationFixture = environment[UITestLaunchKey.configurationFixture].flatMap(ConfigurationFixture.init(rawValue:))
        if let text = environment[UITestLaunchKey.configurationWritePause], let seconds = Int(text), seconds > 0 {
            configurationWritePause = .seconds(seconds)
        } else {
            configurationWritePause = nil
        }
        configurationExportHold = environment[UITestLaunchKey.configurationExportHold].flatMap(ConfigurationExportHold.init(rawValue:))
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
        holdsFirstBodyPlan = environment[UITestLaunchKey.holdFirstBodyPlan] == "1"
        failsFirstBodyWrite = environment[UITestLaunchKey.failFirstBodyWrite] == "1"
        changesSlotsAfterReader = environment[UITestLaunchKey.slotsChangeAfterReader] == "1"
        holdsRetryWrite = environment[UITestLaunchKey.holdRetryWrite] == "1"
        if let text = environment[UITestLaunchKey.pageTranslationCeiling], let ceiling = Int(text), ceiling >= 1 {
            pageTranslationCeiling = ceiling
        } else {
            pageTranslationCeiling = nil
        }
        seedOverviews = environment[UITestLaunchKey.seedOverviews] == "1"
    }

    /// Accepts only a name that stays inside the temporary directory.
    static func isSinglePathComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}
#endif
