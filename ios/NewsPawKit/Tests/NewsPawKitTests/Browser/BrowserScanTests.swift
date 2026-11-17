import Foundation
@testable import NewsPawKit
import Testing

/// RD10 criteria 6 and 7 (spec N12), in RD06's badge-scan form: no Swift
/// source of the app or the package gives a page an interface to the app or
/// uses a download API. Each scan fails when it finds no source file.
///
/// Narrowed by RD12 (decision 1, criterion 11) for the extractor and by
/// RD16 (decision 2, criterion 16) for the page translation bridge: a table
/// of files and the exact lines allowed in each, each line at most once.
/// Every other file, the browser's included, still fails, as does any
/// other line in an allowed file.
@Suite("Browser source scans")
struct BrowserScanTests {
    /// The files the allowances hold in, relative to `ios/`.
    static let extractorFile = "NewsPawKit/Sources/NewsPawKit/Reading/PageExtractor.swift"
    static let bridgeFile = "NewsPawKit/Sources/NewsPawKit/Reading/PageScriptBridge.swift"
    static let fixtureTransportFile = "NewsPawKit/Sources/NewsPawKit/Feeds/FixtureTransport.swift"

    /// What the extractor may do, each once: add the block-everything rule
    /// list to its own content controller, and evaluate its one script in
    /// its own content world.
    static let extractorAllowances = [
        #"^\s*configuration\.userContentController\.add\(ruleList\)$"#,
        #"^\s*webView\.callAsyncJavaScript\(script, arguments: \[:\], in: nil, in: \.world\(name: PageExtractor\.contentWorld\)\) \{ \[weak self\] result in$"#,
    ]

    /// The page translation bridge's one call (RD16 decision 2): the fixed
    /// body, data as arguments only, the main frame, the app's own world.
    static let bridgeAllowance =
        #"^\s*webView\.callAsyncJavaScript\(PageTranslationScript\.source, arguments: \["command": command, "input": input\], in: nil, in: \.world\(name: PageScriptBridge\.worldName\)\) \{ result in finish\(result\) \}$"#

    /// The fixture transport's two article texts that hold a `javascript:`
    /// address as markup and as text: input for the reading screen's
    /// converter, never loaded into a web view.
    static let fixtureAllowances = [
        #"^\s*<p><a href="javascript:alert\('ran'\)">A script link</a> and <a href="data:text/html,<b>x</b>">a data link</a> \\$"#,
        #"^\s*\+ "\[a Markdown link\]\(https://example\.invalid/markdown\) and javascript:alert\(1\) here\."$"#,
    ]

    /// Each allowed file and its allowed lines.
    static var allowances: [String: [String]] {
        [extractorFile: extractorAllowances, bridgeFile: [bridgeAllowance], fixtureTransportFile: fixtureAllowances]
    }

    /// What would give a page an interface to the app or run the app's
    /// script in it. `WKWebView.load` of a `javascript:` address runs code
    /// in the page's world (RD16 critic, K3; measured on iOS too).
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
        #"(?i)javascript:"#,
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
    /// allowances: in their own file only, each at most once.
    static func findings(_ patterns: [String], in files: [(path: String, text: String)]) throws -> [String] {
        let expressions = try patterns.map { try Regex($0) }
        let allowed = try allowances.mapValues { try $0.map { try Regex($0) } }
        var findings: [String] = []
        for file in files {
            var used = Set<Int>()
            let allowances = allowed[file.path] ?? []
            for (number, line) in file.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard expressions.contains(where: { line.contains($0) }) else { continue }
                if let allowance = allowances.indices.first(where: { !used.contains($0) && line.contains(allowances[$0]) }) {
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
        // A second call written on the line of an allowed one fails too.
        for line in calls {
            let doubled = String(line) + " webView.evaluateJavaScript(\"1\")"
            #expect(try Self.findings(Self.interfacePatterns, in: [(path: Self.extractorFile, text: doubled)]).count == 1, "\(doubled)")
        }
        // Any other interface call in the extractor's file still fails.
        for line in [
            "        configuration.userContentController.add(handler, name: \"app\")",
            "        webView.evaluateJavaScript(\"1\")",
            "        configuration.userContentController.addUserScript(script)",
        ] {
            #expect(try Self.findings(Self.interfacePatterns, in: [(path: Self.extractorFile, text: line)]).count == 1, "\(line)")
        }
    }

    @Test("RD16 criterion 16: the bridge's one call passes in its file; planted copies fail")
    func bridgeAllowanceHoldsInOneFileOnly() throws {
        let files = try Self.sources()
        let bridge = try #require(files.first { $0.path == Self.bridgeFile }, "the bridge was not among the scanned files")
        #expect(try Self.findings(Self.interfacePatterns, in: [bridge]).isEmpty)
        let calls = bridge.text.split(separator: "\n").filter { line in
            Self.interfacePatterns.contains { (try? Regex($0)).map { line.contains($0) } ?? false }
        }
        #expect(calls.count == 1, "the bridge's calls: \(calls)")
        let call = try #require(calls.first.map(String.init))
        // The same line elsewhere: in the browser's model, in another
        // package file, in the extractor's file.
        for path in [
            "NewsPaw/Browser/BrowserModel.swift", "NewsPawKit/Sources/NewsPawKit/Translation/PageTranslationSession.swift",
            "NewsPawKit/Sources/NewsPawKit/Reading/OtherBridge.swift", Self.extractorFile,
        ] {
            #expect(try Self.findings(Self.interfacePatterns, in: [(path: path, text: call)]).count == 1, "\(path)")
        }
        // Twice in its own file.
        #expect(try Self.findings(Self.interfacePatterns, in: [(path: Self.bridgeFile, text: bridge.text + "\n" + call)]).count == 1)
        // With another body, another world, another frame, or wrapped.
        for variant in [
            call.replacingOccurrences(of: "PageTranslationScript.source", with: "script"),
            call.replacingOccurrences(of: "PageTranslationScript.source", with: #""document.title""#),
            call.replacingOccurrences(of: ".world(name: PageScriptBridge.worldName)", with: ".page"),
            call.replacingOccurrences(of: ".world(name: PageScriptBridge.worldName)", with: ".defaultClient"),
            call.replacingOccurrences(of: "PageScriptBridge.worldName", with: #""Other""#),
            call.replacingOccurrences(of: "PageScriptBridge.worldName", with: "PageExtractor.contentWorld"),
            call.replacingOccurrences(of: "in: nil", with: "in: frame"),
            call.replacingOccurrences(of: #"["command": command, "input": input]"#, with: #"["command": command, "input": input, "extra": page]"#),
            call + " webView.evaluateJavaScript(\"1\")",
            call.replacingOccurrences(of: "arguments:", with: "\n            arguments:"),
        ] {
            let findings = try Self.findings(Self.interfacePatterns, in: [(path: Self.bridgeFile, text: variant)])
            #expect(!findings.isEmpty, "\(variant)")
        }
        // Any other interface call in the bridge's file fails.
        for line in [
            "        webView.evaluateJavaScript(\"1\")",
            "        configuration.userContentController.addUserScript(script)",
            "        configuration.userContentController.add(handler, name: \"app\")",
            "        webView.callAsyncJavaScript(PageTranslationScript.source, arguments: [:], in: nil, in: .page)",
        ] {
            #expect(try Self.findings(Self.interfacePatterns, in: [(path: Self.bridgeFile, text: line)]).count == 1, "\(line)")
        }
        // The extractor's allowances hold in the extractor's file only.
        let extractor = try #require(files.first { $0.path == Self.extractorFile })
        #expect(try Self.findings(Self.interfacePatterns, in: [(path: Self.bridgeFile, text: extractor.text)]).count == 2)
    }

    @Test("RD16 criterion 16: a javascript: address is found anywhere but the fixture transport's two article texts")
    func javascriptAddresses() throws {
        let files = try Self.sources()
        let fixture = try #require(files.first { $0.path == Self.fixtureTransportFile })
        #expect(try Self.findings(Self.interfacePatterns, in: [fixture]).isEmpty)
        let lines = fixture.text.split(separator: "\n").filter { $0.localizedCaseInsensitiveContains("javascript:") }
        #expect(lines.count == 2, "\(lines)")
        for line in [
            #"        webView.load(URLRequest(url: URL(string: "javascript:1")!))"#,
            #"        session.load(URL(string: "JavaScript:void(0)")!)"#,
        ] {
            for path in ["NewsPaw/Browser/BrowserModel.swift", Self.fixtureTransportFile, Self.bridgeFile] {
                #expect(try Self.findings(Self.interfacePatterns, in: [(path: path, text: line)]).count == 1, "\(path): \(line)")
            }
        }
        // The fixture's lines elsewhere fail.
        #expect(try Self.findings(Self.interfacePatterns, in: [(path: "NewsPaw/Browser/BrowserFixtures.swift", text: lines.joined(separator: "\n"))]).count == 2)
    }

    @Test("RD16: the bridge's world is not the extractor's")
    @MainActor
    func worlds() {
        #expect(PageScriptBridge.worldName != PageExtractor.contentWorld)
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
