import Foundation
import Testing

/// RD19 decision 8 and criterion 14, in RD06's badge-scan form: no Swift
/// source of the app or the package logs, prints or dumps (RD18: "the app
/// writes no log"); and RD19 decision 4's invariant: no file but
/// `BrowserDataStores.swift`, and RD12's extractor for its own
/// non-persistent stores, makes a website data store. Each scan fails when
/// it finds no source file.
@Suite("Isolation source scans")
struct IsolationScanTests {
    /// What would write a log.
    static let loggingPatterns = [
        #"(^|[^\w.])print\("#,
        #"\bdebugPrint\("#,
        #"(^|[^\w.])dump\("#,
        #"\bNSLog\("#,
        #"\bos_log\("#,
        #"\bLogger\("#,
        #"\bimport\s+os\.log\b"#,
        #"\bimport\s+OSLog\b"#,
    ]

    /// The one file allowed a logging pattern, relative to `ios/`: a
    /// `print(` inside the fixture transport's page text, which is never
    /// run.
    static let loggingExempt = "NewsPawKit/Sources/NewsPawKit/Feeds/FixtureTransport.swift"

    /// What makes a website data store.
    static let storePatterns = [
        #"\.nonPersistent\(\)"#,
        #"\bnonPersistentDataStore\b"#,
        #"\bdefaultDataStore\b"#,
        #"WKWebsiteDataStore\s*\("#,
        #"WKWebsiteDataStore\.(default|nonPersistent)\("#,
        #"\bdataStoreForIdentifier\b"#,
        #"(dataStore|websiteDataStore)\s*[:=]\s*\.default\(\)"#,
    ]

    /// The files that make website data stores, relative to `ios/`.
    static let storeFiles = [
        "NewsPawKit/Sources/NewsPawKit/Browser/BrowserDataStores.swift",
        "NewsPawKit/Sources/NewsPawKit/Reading/PageExtractor.swift",
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

    /// The app's and the package's sources: each file's path relative to
    /// `ios/`, and its text.
    private static func sources() throws -> [(path: String, text: String)] {
        let app = swiftFiles(in: iosDirectory.appending(path: "NewsPaw"))
        let package = swiftFiles(in: iosDirectory.appending(path: "NewsPawKit/Sources"))
        #expect(app.count >= 10, "found \(app.count) app source files to scan")
        #expect(app.contains { $0.lastPathComponent == "AppModel.swift" }, "the app model was not among the scanned files")
        #expect(package.contains { $0.lastPathComponent == "LibraryModels.swift" }, "the package's models were not among the scanned files")
        let root = iosDirectory.standardizedFileURL.path(percentEncoded: false)
        return try (app + package).map { file in
            let path = file.standardizedFileURL.path(percentEncoded: false)
            let relative = path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
            return (relative.hasPrefix("/") ? String(relative.dropFirst()) : relative, try String(contentsOf: file, encoding: .utf8))
        }
    }

    /// The lines of `files` outside `exempt` that match one of `patterns`.
    static func findings(_ patterns: [String], in files: [(path: String, text: String)], exempt: [String]) throws -> [String] {
        let expressions = try patterns.map { try Regex($0) }
        var findings: [String] = []
        for file in files where !exempt.contains(file.path) {
            for (number, line) in file.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where expressions.contains(where: { line.contains($0) }) {
                findings.append("\(file.path):\(number + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        return findings
    }

    @Test("criterion 14: no Swift source of the app or the package logs, prints or dumps")
    func nothingIsLogged() throws {
        let findings = try Self.findings(Self.loggingPatterns, in: Self.sources(), exempt: [Self.loggingExempt])
        #expect(findings.isEmpty, "something is logged: \(findings)")
    }

    @Test("decision 4: no file but the stores' own and the extractor's makes a website data store")
    func storesAreMadeInOnePlace() throws {
        let files = try Self.sources()
        #expect(files.contains { $0.path == Self.storeFiles[0] }, "the stores' file was not found")
        let findings = try Self.findings(Self.storePatterns, in: files, exempt: Self.storeFiles)
        #expect(findings.isEmpty, "a website data store made elsewhere: \(findings)")
    }

    @Test("the scans see what they look for")
    func scansMatch() throws {
        let logging = try Self.findings(
            Self.loggingPatterns,
            in: [("x.swift", "    print(title)\n    debugPrint(x)\n    dump(x)\n    NSLog(\"%@\", x)\n    let log = Logger(subsystem: s, category: c)\n    import os.log\n    fingerprint(x)\n    model.dump(x)")],
            exempt: []
        )
        #expect(logging.count == 6)
        let stores = try Self.findings(
            Self.storePatterns,
            in: [("x.swift", "    BrowserSetup(dataStore: .nonPersistent())\n    BrowserSetup(dataStore: .default())\n    WKWebsiteDataStore(forIdentifier: id)\n    let s = WKWebsiteDataStore.default()\n    WKContentRuleListStore.default()")],
            exempt: []
        )
        #expect(stores.count == 4)
    }
}
