import Foundation
import Testing

/// RD18 criterion 16 and decision 14, in RD06's badge-scan form: no Swift
/// source of the app or the package uses a notification, widget, Spotlight,
/// Handoff or state-restoration API, through which adult content could
/// leave the library; and criterion 17: the stand-in authenticator and the
/// debug launch options exist only inside `#if DEBUG`. Each scan fails when
/// it finds no source file.
@Suite("Adult partition source scans")
struct AdultScanTests {
    /// What would carry content out of the app's own storage.
    static let carrierPatterns = [
        // Notifications.
        #"\bUserNotifications\b"#,
        #"\bUNUserNotificationCenter\b"#,
        #"\bUN\w*NotificationContent\b"#,
        #"\bUNNotificationRequest\b"#,
        #"registerForRemoteNotifications"#,
        // Widgets and Live Activities.
        #"\bWidgetKit\b"#,
        #"\bWidgetCenter\b"#,
        #"\bActivityKit\b"#,
        // Spotlight.
        #"\bCoreSpotlight\b"#,
        #"\bCSSearchable\w*"#,
        // Handoff and user activities.
        #"\bNSUserActivity\b"#,
        #"\.userActivity\s*\("#,
        #"\bonContinueUserActivity\b"#,
        #"\.handlesExternalEvents\s*\("#,
        // Siri and Shortcuts donations.
        #"\bimport\s+(Intents|AppIntents)\b"#,
        // State restoration and stored view state.
        #"@AppStorage\b"#,
        #"@SceneStorage\b"#,
        #"\bAppStorage\s*\("#,
        #"\bSceneStorage\s*\("#,
        #"\brestorationIdentifier\b"#,
        #"\bstateRestorationActivity\b"#,
        #"\b(encode|decode)RestorableState\b"#,
        #"\bNSUbiquitousKeyValueStore\b"#,
    ]

    /// Names that may appear only inside `#if DEBUG`.
    static let debugOnlyNames = [
        "FixtureAuthenticator", "DebugLaunchOptions", "UITestLaunchKey", "NEWSPAW_UITEST_", "DebugAccessibilityID",
        "AdultDebugElement",
        // RD24 decision 9: the background refresh's debug seams.
        "RecordingBackgroundScheduler", "DebugClock", "adultOpensForUITests", "deliverBackgroundRefreshForUITests",
        "DeliverBackgroundRefreshButton", "lastBackgroundEnding",
    ]

    /// `ios/` in the repository.
    private static var iosDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Privacy
            .deletingLastPathComponent() // NewsPawKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // NewsPawKit
            .deletingLastPathComponent() // ios
    }

    private static func swiftFiles(in directory: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    /// The patterns as expressions. `\b` is the simple word boundary: by
    /// the default one `Center.shared` is a single word and
    /// `\bWidgetCenter\b` would not match it.
    static func carrierExpressions() throws -> [Regex<AnyRegexOutput>] {
        try carrierPatterns.map { try Regex($0).wordBoundaryKind(.simple) }
    }

    private static func appFiles() -> [URL] {
        swiftFiles(in: iosDirectory.appending(path: "NewsPaw"))
    }

    private static func packageFiles() -> [URL] {
        swiftFiles(in: iosDirectory.appending(path: "NewsPawKit/Sources"))
    }

    /// The lines of `text` that match one of `expressions`.
    static func carriers(in text: String, _ expressions: [Regex<AnyRegexOutput>]) -> [(line: Int, text: String)] {
        var found: [(Int, String)] = []
        for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if expressions.contains(where: { line.contains($0) }) {
                found.append((number + 1, line.trimmingCharacters(in: .whitespaces)))
            }
        }
        return found
    }

    /// The lines of `text` that name one of `names` outside every
    /// `#if DEBUG` block. The `#else` of a block is outside it; a condition
    /// other than exactly `DEBUG` (`!DEBUG`, `DEBUG || X`) counts as outside.
    static func outsideDebug(in text: String, names: [String]) -> [(line: Int, text: String)] {
        var found: [(Int, String)] = []
        // One entry per open `#if`: whether its current branch is debug-only.
        var blocks: [Bool] = []
        for (number, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#if") {
                let condition = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                blocks.append(condition == "DEBUG")
            } else if line.hasPrefix("#else") {
                if !blocks.isEmpty {
                    blocks[blocks.count - 1] = false
                }
            } else if line.hasPrefix("#endif") {
                _ = blocks.popLast()
            } else if !blocks.contains(true), names.contains(where: { line.contains($0) }) {
                found.append((number + 1, line))
            }
        }
        return found
    }

    @Test("criterion 16: no notification, widget, Spotlight, Handoff or state-restoration API in the app or the package")
    func noCarrier() throws {
        let app = Self.appFiles()
        let package = Self.packageFiles()
        #expect(app.count >= 10, "found \(app.count) app source files to scan")
        #expect(app.contains { $0.lastPathComponent == "AppModel.swift" }, "the app model was not among the scanned files")
        #expect(!package.isEmpty, "found no package source file to scan")
        let expressions = try Self.carrierExpressions()
        var findings: [String] = []
        for file in app + package {
            let text = try String(contentsOf: file, encoding: .utf8)
            findings += Self.carriers(in: text, expressions).map { "\(file.lastPathComponent):\($0.line): \($0.text)" }
        }
        #expect(findings.isEmpty, "content could leave the library: \(findings)")
    }

    @Test("criterion 16: the patterns find what they look for, and not the in-process notification centre")
    func carrierPatternsMatch() throws {
        let expressions = try Self.carrierExpressions()
        for line in [
            "import UserNotifications", "UNUserNotificationCenter.current().add(request)", "let content = UNMutableNotificationContent()",
            "import WidgetKit", "WidgetCenter.shared.reloadAllTimelines()", "import CoreSpotlight",
            "CSSearchableIndex.default().indexSearchableItems(items)", "let activity = NSUserActivity(activityType: type)",
            ".userActivity(\"io.newspaw.read\") { activity in", ".onContinueUserActivity(type) { _ in }",
            "@AppStorage(\"lastCategory\") private var last = \"\"", "@SceneStorage(\"path\") private var path: Data?",
            "view.restorationIdentifier = \"list\"", "scene.stateRestorationActivity", "import AppIntents", "import ActivityKit",
            "override func encodeRestorableState(with coder: NSCoder) {",
        ] {
            #expect(!Self.carriers(in: line, expressions).isEmpty, "\(line)")
        }
        for line in [
            "NotificationCenter.default.addObserver(forName: UIScene.willDeactivateNotification, object: nil, queue: nil)",
            "UIApplication.shared.beginBackgroundTask(withName: \"Refresh\")", "import LocalAuthentication",
            "private let preferences: Preferences", "let defaults = UserDefaults.standard", "var userActivityCount = 0",
        ] {
            #expect(Self.carriers(in: line, expressions).isEmpty, "\(line)")
        }
    }

    @Test("criterion 17: the stand-in authenticator and the debug options are named only inside #if DEBUG")
    func debugOnly() throws {
        let app = Self.appFiles()
        #expect(app.count >= 10, "found \(app.count) app source files to scan")
        var findings: [String] = []
        var named = Set<String>()
        for file in app + Self.packageFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            findings += Self.outsideDebug(in: text, names: Self.debugOnlyNames).map { "\(file.lastPathComponent):\($0.line): \($0.text)" }
            for name in Self.debugOnlyNames where text.contains(name) {
                named.insert(name)
            }
        }
        #expect(findings.isEmpty, "debug-only code outside #if DEBUG: \(findings)")
        // The scan looked at the real things: each name exists somewhere.
        #expect(named == Set(Self.debugOnlyNames), "not found anywhere: \(Set(Self.debugOnlyNames).subtracting(named))")
    }

    // MARK: - Decision 7: the accent follows the partition

    /// A view that names an accent token directly would keep the normal
    /// partition's colour in the adult partition.
    static let fixedAccentPatterns = [
        #"\bTheme\.(accent|adultAccent)\b(?!\s*\()"#,
        #"\bPalette\.(accent|adultAccent)\b"#,
    ]

    @Test("decision 7: outside the theme no view names an accent directly; each reads it from the environment")
    func accentComesFromTheEnvironment() throws {
        let expressions = try Self.fixedAccentPatterns.map { try Regex($0).wordBoundaryKind(.simple) }
        var findings: [String] = []
        var readers = 0
        for file in Self.appFiles() where file.lastPathComponent != "Theme.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            findings += Self.carriers(in: text, expressions).map { "\(file.lastPathComponent):\($0.line): \($0.text)" }
            if text.contains(#"@Environment(\.accent)"#) {
                readers += 1
            }
        }
        #expect(findings.isEmpty, "an accent is named directly: \(findings)")
        #expect(readers >= 5, "found \(readers) files that read the accent from the environment")
        for line in ["  .tint(Theme.accent)", ".fill(row.isRead ? Color.clear : Theme.accent)", "Color(Palette.adultAccent)"] {
            #expect(!Self.carriers(in: line, expressions).isEmpty, "\(line)")
        }
        for line in [".environment(\\.accent, Theme.accent(of: workspace.partition))", ".foregroundStyle(accent)", "Theme.onAccent"] {
            #expect(Self.carriers(in: line, expressions).isEmpty, "\(line)")
        }
    }

    @Test("criterion 17: the debug scan tells inside from outside")
    func debugScanWorks() {
        let names = ["FixtureAuthenticator"]
        let inside = """
        #if DEBUG
        let a = FixtureAuthenticator()
        #if os(iOS)
        let b = FixtureAuthenticator()
        #endif
        #endif
        """
        #expect(Self.outsideDebug(in: inside, names: names).isEmpty)
        let elseBranch = """
        #if DEBUG
        let a = 1
        #else
        let a = FixtureAuthenticator()
        #endif
        """
        #expect(Self.outsideDebug(in: elseBranch, names: names).map(\.line) == [4])
        let after = """
        #if DEBUG
        let a = 1
        #endif
        let b = FixtureAuthenticator()
        """
        #expect(Self.outsideDebug(in: after, names: names).map(\.line) == [4])
        let negated = """
        #if !DEBUG
        let a = FixtureAuthenticator()
        #endif
        #if os(iOS)
        let b = FixtureAuthenticator()
        #endif
        """
        #expect(Self.outsideDebug(in: negated, names: names).map(\.line) == [2, 5])
    }
}
