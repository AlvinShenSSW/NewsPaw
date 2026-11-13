import Foundation
import Testing

/// RD06 criterion 14 (spec N04): nothing in the app or the package sets the
/// application badge. In-app counts (`.badge(…)` on a tab or a row) are not
/// what it looks for.
@Suite("No badge")
struct NoBadgeTests {
    /// What sets the application badge.
    static let patterns = [
        #"applicationIconBadgeNumber"#,
        #"setBadgeCount"#,
        // A badge assigned to notification content: `content.badge = 1`.
        #"\.badge\s*=(?!=)"#,
        #"UNAuthorizationOptions\.badge"#,
        #"requestAuthorization\s*\(\s*options:[^)]*\.badge"#,
    ]

    /// `ios/` in the repository.
    private static var iosDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // NewsPawKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // NewsPawKit
            .deletingLastPathComponent() // ios
    }

    private static func swiftFiles(in directory: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    @Test("no Swift source of the app or the package sets the application badge")
    func noBadge() throws {
        let app = Self.swiftFiles(in: Self.iosDirectory.appending(path: "NewsPaw"))
        let package = Self.swiftFiles(in: Self.iosDirectory.appending(path: "NewsPawKit/Sources"))
        #expect(app.count >= 10, "found \(app.count) app source files to scan")
        #expect(!package.isEmpty, "found no package source file to scan")
        let expressions = try Self.patterns.map { try Regex($0) }
        var findings: [String] = []
        for file in app + package {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if expressions.contains(where: { line.contains($0) }) {
                    findings.append("\(file.lastPathComponent):\(number + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(findings.isEmpty, "the application badge is set: \(findings)")
    }
}
