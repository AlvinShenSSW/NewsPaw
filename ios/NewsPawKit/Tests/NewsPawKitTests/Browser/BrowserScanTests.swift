import Foundation
import Testing

/// RD10 criteria 6 and 7 (spec N12), in RD06's badge-scan form: no Swift
/// source of the app or the package gives a page an interface to the app or
/// uses a download API. Each scan fails when it finds no source file.
@Suite("Browser source scans")
struct BrowserScanTests {
    /// What would give a page an interface to the app or run the app's
    /// script in it.
    static let interfacePatterns = [
        #"WKScriptMessageHandler"#,
        #"addScriptMessageHandler"#,
        #"addUserScript"#,
        #"WKUserScript"#,
        // `.add(` on a content controller: a message handler by another name.
        #"[Cc]ontentController\??\.add\w*\("#,
        #"callJavaScript"#,
        #"callAsyncJavaScript"#,
        #"evaluateJavaScript"#,
    ]

    /// What would download or save what a page serves.
    static let downloadPatterns = [
        #"WKDownload"#,
        #"startDownload"#,
        #"resumeDownload"#,
        #"didBecome\s+download"#,
        #"downloadTask"#,
        // A `.download` policy written as an implicit member, not a property
        // such as `action.download`.
        #"(^|[^\w)\].?])\.download\b"#,
    ]

    /// `ios/` in the repository.
    private static var iosDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Browser
            .deletingLastPathComponent() // NewsPawKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // NewsPawKit
            .deletingLastPathComponent() // ios
    }

    private static func swiftFiles(in directory: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    /// The lines of the app's and the package's sources that match one of
    /// `patterns`.
    private static func findings(_ patterns: [String]) throws -> [String] {
        let app = swiftFiles(in: iosDirectory.appending(path: "NewsPaw"))
        let package = swiftFiles(in: iosDirectory.appending(path: "NewsPawKit/Sources"))
        #expect(app.count >= 10, "found \(app.count) app source files to scan")
        #expect(app.contains { $0.lastPathComponent == "BrowserModel.swift" }, "the browser's model was not among the scanned files")
        #expect(!package.isEmpty, "found no package source file to scan")
        let expressions = try patterns.map { try Regex($0) }
        var findings: [String] = []
        for file in app + package {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if expressions.contains(where: { line.contains($0) }) {
                    findings.append("\(file.lastPathComponent):\(number + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return findings
    }

    @Test("criterion 7: no message handler, user script or script call in the app or the package")
    func noInterface() throws {
        let findings = try Self.findings(Self.interfacePatterns)
        #expect(findings.isEmpty, "a page could reach the app: \(findings)")
    }

    @Test("criterion 6: no download API in the app or the package")
    func noDownload() throws {
        let findings = try Self.findings(Self.downloadPatterns)
        #expect(findings.isEmpty, "a download API is used: \(findings)")
    }

    @Test("the patterns find what they look for")
    func patternsMatch() throws {
        let interface = try Self.interfacePatterns.map { try Regex($0) }
        for line in [
            "final class Handler: NSObject, WKScriptMessageHandler {",
            "configuration.userContentController.add(handler, name: \"app\")",
            "controller.addUserScript(script)",
            "try await page.callJavaScript(\"1\")",
            "webView.evaluateJavaScript(\"1\")",
        ] {
            #expect(interface.contains { line.contains($0) }, "\(line)")
        }
        let download = try Self.downloadPatterns.map { try Regex($0) }
        for line in ["decisionHandler(.download)", "return .download", "func webView(_ w: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload)"] {
            #expect(download.contains { line.contains($0) }, "\(line)")
        }
        for line in ["if action.download {", "download: action.shouldPerformDownload"] {
            #expect(!download.contains { line.contains($0) }, "\(line)")
        }
    }
}
