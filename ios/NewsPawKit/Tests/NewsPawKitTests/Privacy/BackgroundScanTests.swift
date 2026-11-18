import Foundation
import Testing

/// RD24 criterion 4 in RD06's badge-scan form: the background work is built
/// without the store, the gate or anything of the other partition. The
/// app's `AppState/BackgroundRefresh.swift` and the package's `Background/`
/// name none of them, in code or in comments. The scan fails when it finds
/// none of those files.
@Suite("Background source scan")
struct BackgroundScanTests {
    /// What the background files never name. `gate` as a word (the simple
    /// word boundary, so that `gate.unlock` matches), so that "navigate" or
    /// "delegate" do not count; the partition's name in any case.
    static let forbiddenPatterns = [
        #"AdultGate"#,
        #"\b[Gg]ate\b"#,
        #"LibraryStore"#,
        #"\.adult\b"#,
        #"(?i)adult"#,
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

    /// The files the scan reads.
    static func backgroundFiles() -> [URL] {
        let package = iosDirectory.appending(path: "NewsPawKit/Sources/NewsPawKit/Background")
        let enumerator = FileManager.default.enumerator(at: package, includingPropertiesForKeys: nil)
        let packageFiles = (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        let app = iosDirectory.appending(path: "NewsPaw/AppState/BackgroundRefresh.swift")
        return packageFiles + (FileManager.default.fileExists(atPath: app.path) ? [app] : [])
    }

    static func expressions() throws -> [Regex<AnyRegexOutput>] {
        try forbiddenPatterns.map { try Regex($0).wordBoundaryKind(.simple) }
    }

    @Test("criterion 4: the background files name no store, gate or other partition")
    func nothingOfTheOtherPartition() throws {
        let files = Self.backgroundFiles()
        let names = Set(files.map(\.lastPathComponent))
        #expect(names.isSuperset(of: ["BackgroundRefresh.swift", "BackgroundRun.swift", "BackgroundPass.swift", "BackgroundSchedule.swift"]),
                "scanned \(names.sorted())")
        let expressions = try Self.expressions()
        var findings: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                where expressions.contains(where: { line.contains($0) }) {
                findings.append("\(file.lastPathComponent):\(number + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(findings.isEmpty, "the background work names what it must not: \(findings)")
    }

    @Test("criterion 4: the patterns find what they look for, and not words that only contain them")
    func patternsMatch() throws {
        let expressions = try Self.expressions()
        func found(_ line: String) -> Bool {
            expressions.contains { line.contains($0) }
        }
        for line in ["let gate: AdultGate", "await gate.unlock()", "store.openNormal() // LibraryStore", "partition == .adult",
                     "/// the Adult partition", "let g = Gate()"] {
            #expect(found(line), "\(line)")
        }
        for line in ["navigation.navigate()", "let delegate = self", "aggregate", "library.partition == .normal"] {
            #expect(!found(line), "\(line)")
        }
    }
}
