import Foundation
import Testing

/// RD10 criteria 6 and 7 (spec N12), in RD06's badge-scan form: no Swift
/// source of the app or the package gives a page an interface to the app or
/// uses a download API. Each scan fails when it finds no source file.
///
/// Narrowed by RD12 (decision 1, criterion 11) for the extractor alone: in
/// `Reading/PageExtractor.swift` of the package, and in no other file, one
/// `add` of the rule list to its content controller and one evaluation are
/// allowed. Every other file, the browser's included, still fails.
@Suite("Browser source scans")
struct BrowserScanTests {
    /// The one file the allowances hold in, relative to `ios/`.
    static let extractorFile = "NewsPawKit/Sources/NewsPawKit/Reading/PageExtractor.swift"

    /// What the extractor may do, each once, in `extractorFile` only: add
    /// the block-everything rule list to its own content controller, and
    /// evaluate its one script in its own content world.
    static let extractorAllowances = [
        #"^\s*configuration\.userContentController\.add\(ruleList\)$"#,
        #"^\s*webView\.callAsyncJavaScript\(script, arguments: \[:\], in: nil, in: \.world\(name: PageExtractor\.contentWorld\)\)"#,
    ]

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
        // The same policy written with its type, as in
        // `WKNavigationResponsePolicy.download`.
        #"Policy\.download\b"#,
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

    /// The app's and the package's sources: each file's path relative to
    /// `ios/`, and its text.
    private static func sources() throws -> [(path: String, text: String)] {
        let app = swiftFiles(in: iosDirectory.appending(path: "NewsPaw"))
        let package = swiftFiles(in: iosDirectory.appending(path: "NewsPawKit/Sources"))
        #expect(app.count >= 10, "found \(app.count) app source files to scan")
        #expect(app.contains { $0.lastPathComponent == "BrowserModel.swift" }, "the browser's model was not among the scanned files")
        #expect(!package.isEmpty, "found no package source file to scan")
        let root = iosDirectory.standardizedFileURL.path(percentEncoded: false)
        return try (app + package).map { file in
            let path = file.standardizedFileURL.path(percentEncoded: false)
            let relative = path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
            return (relative.hasPrefix("/") ? String(relative.dropFirst()) : relative, try String(contentsOf: file, encoding: .utf8))
        }
    }

    /// The lines of the app's and the package's sources that match one of
    /// `patterns`.
    private static func findings(_ patterns: [String]) throws -> [String] {
        try findings(patterns, in: sources())
    }

    /// The lines of `files` that match one of `patterns`, but for the
    /// extractor's allowances: in `extractorFile` only, each at most once.
    static func findings(_ patterns: [String], in files: [(path: String, text: String)]) throws -> [String] {
        let expressions = try patterns.map { try Regex($0) }
        let allowances = try extractorAllowances.map { try Regex($0) }
        var findings: [String] = []
        for file in files {
            var used = Set<Int>()
            for (number, line) in file.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard expressions.contains(where: { line.contains($0) }) else { continue }
                if file.path == extractorFile,
                   let allowance = allowances.indices.first(where: { !used.contains($0) && line.contains(allowances[$0]) }) {
                    used.insert(allowance)
                    continue
                }
                findings.append("\(file.path):\(number + 1): \(line.trimmingCharacters(in: .whitespaces))")
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

    @Test("RD12 criterion 11: the extractor's two calls are allowed in its file only, once each")
    func extractorAllowancesHoldInOneFileOnly() throws {
        let files = try Self.sources()
        let extractor = try #require(files.first { $0.path == Self.extractorFile }, "the extractor was not among the scanned files")
        // The extractor's file has the two calls, and they are allowed there.
        #expect(try Self.findings(Self.interfacePatterns, in: [extractor]).isEmpty)
        #expect(!(try Self.findings(Self.interfacePatterns, in: [(path: "elsewhere", text: extractor.text)])).isEmpty)
        let calls = extractor.text.split(separator: "\n").filter { line in
            Self.interfacePatterns.contains { (try? Regex($0)).map { line.contains($0) } ?? false }
        }
        #expect(calls.count == 2, "the extractor's calls: \(calls)")
        let planted = calls.joined(separator: "\n")
        // A second file with the same calls fails: in the package, in the
        // browser's model, and as a second copy in the extractor's file.
        for path in [
            "NewsPawKit/Sources/NewsPawKit/Reading/OtherExtractor.swift", "NewsPaw/Browser/BrowserModel.swift",
            "NewsPawKit/Sources/NewsPawKit/Browser/BrowserConfiguration.swift",
        ] {
            #expect(try Self.findings(Self.interfacePatterns, in: [extractor, (path: path, text: planted)]).count == 2, "\(path)")
        }
        #expect(try Self.findings(Self.interfacePatterns, in: [(path: Self.extractorFile, text: extractor.text + "\n" + planted)]).count == 2)
        // Any other interface call in the extractor's file still fails.
        for line in [
            "        configuration.userContentController.add(handler, name: \"app\")",
            "        webView.evaluateJavaScript(\"1\")",
            "        configuration.userContentController.addUserScript(script)",
        ] {
            #expect(try Self.findings(Self.interfacePatterns, in: [(path: Self.extractorFile, text: line)]).count == 1, "\(line)")
        }
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
        for line in [
            "decisionHandler(.download)", "return .download",
            "return WKNavigationResponsePolicy.download", "decisionHandler(WKNavigationActionPolicy.download, preferences)",
            "func webView(_ w: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload)",
        ] {
            #expect(download.contains { line.contains($0) }, "\(line)")
        }
        for line in ["if action.download {", "download: action.shouldPerformDownload"] {
            #expect(!download.contains { line.contains($0) }, "\(line)")
        }
    }
}
