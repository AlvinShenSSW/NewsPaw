import Foundation
import GRDB
@testable import NewsPawKit
import Testing

/// RD13 criterion 3 (spec N08): the key string appears in no thrown error,
/// in no printing of the stand-in's request, of a reply or of a slot, in no
/// row of any table and in no byte of the library's files; and nothing in
/// `AI/` or `Privacy/` logs.
@Suite("The key does not leak")
struct KeyLeakTests {
    static let sentinel = "sk-SENTINEL-7c1e9a-0123456789abcdef"

    /// Every way an error or value is turned into text.
    private static func renderings(_ value: Any) -> [String] {
        var dumped = ""
        dump(value, to: &dumped)
        var renderings = [String(describing: value), String(reflecting: value), dumped, "\(value)"]
        if let error = value as? any Error {
            renderings.append(error.localizedDescription)
            renderings.append((error as NSError).description)
            renderings.append("\((error as NSError).userInfo)")
        }
        return renderings
    }

    private static func expectNoSentinel(_ value: Any, _ note: String, sourceLocation: SourceLocation = #_sourceLocation) {
        for rendering in renderings(value) {
            #expect(!rendering.contains(sentinel), "\(note): \(rendering.prefix(200))", sourceLocation: sourceLocation)
        }
    }

    /// A stub that echoes the key it received in its error bodies and in
    /// the header fields of every answer, as a careless service might.
    private static func echoingHTTP(status: Int) -> StubModelHTTP {
        StubModelHTTP { request in
            let echoed = request.authorization?.exposedValue ?? ""
            let headers = ["X-Echo-Authorization": "Bearer " + echoed, "Content-Type": "application/json"]
            if status == 200 {
                if request.method == .get {
                    return ModelHTTPResponse(status: 200, headers: headers, body: Data(#"{"data":[{"id":"m"}]}"#.utf8))
                }
                return ModelHTTPResponse(status: 200, headers: headers, body: completionBody(#"{"texts":["fine"]}"#))
            }
            let body = #"{"error":{"message":"Incorrect API key provided: \#(echoed)","key":"\#(echoed)"}}"#
            return ModelHTTPResponse(status: status, headers: headers, body: Data(body.utf8))
        }
    }

    @Test("criterion 3: with a sentinel key, against stubs that echo it, the key is in no error, printing, row or file")
    func sentinelKey() async throws {
        let statuses = [200, 400, 401, 402, 403, 404, 413, 422, 429, 500, 503, 302, 418]
        for status in statuses {
            let http = Self.echoingHTTP(status: status)
            let fixture = try await ModelsFixture.make(http: http)
            defer { fixture.remove() }
            let note = "status \(status)"
            let saved = try await fixture.save(model: "test-model", key: Self.sentinel)
            Self.expectNoSentinel(saved, "\(note), saved status")
            let slot = try #require(try await fixture.slot())
            Self.expectNoSentinel(slot, "\(note), slot")
            Self.expectNoSentinel(try await fixture.models.statuses(), "\(note), statuses")

            // send, with the stored key
            do {
                let reply = try await fixture.models.send(texts: ["Hello"], instructions: "i", purpose: .titles, role: .primary)
                Self.expectNoSentinel(reply, "\(note), reply")
            } catch {
                Self.expectNoSentinel(error, "\(note), send error")
            }
            // Test and Load List, with the stored key and with a typed one
            for newKey in [nil, key(Self.sentinel)] {
                let draft = ModelSlotDraft(role: .primary, preset: .custom, address: "https://api.example.invalid/v1", model: "test-model", newKey: newKey)
                Self.expectNoSentinel(draft, "\(note), draft")
                do {
                    Self.expectNoSentinel(try await fixture.models.test(draft), "\(note), test outcome")
                } catch {
                    Self.expectNoSentinel(error, "\(note), test error")
                }
                do {
                    Self.expectNoSentinel(try await fixture.models.listModels(draft), "\(note), list")
                } catch {
                    Self.expectNoSentinel(error, "\(note), list error")
                }
            }
            // The stand-in's requests carried the key, and print without it.
            #expect(http.received.count == 5)
            for request in http.received {
                #expect(request.authorization == key(Self.sentinel))
                Self.expectNoSentinel(request, "\(note), request")
            }
            // Removing the key and the slot.
            try await fixture.models.removeKey(.primary)
            try await fixture.save(model: "test-model", key: Self.sentinel)
            try await fixture.models.removeSlot(.primary)
            try await fixture.save(model: "test-model", key: Self.sentinel)

            // No row of any table.
            let snapshot = try await fixture.library.pool.read { try DatabaseSnapshot.read($0) }
            #expect(snapshot.rows["usage"]?.isEmpty == false)
            for (table, rows) in snapshot.rows {
                for row in rows {
                    #expect(!row.contains { $0?.contains(Self.sentinel) == true }, "\(note): a row of \(table)")
                }
            }
            // No byte of the library's files, after a checkpoint and before.
            try Self.expectNoSentinelInFiles(fixture.directory, note)
            try await fixture.library.pool.writeWithoutTransaction { db in
                try db.checkpoint(.truncate)
            }
            try Self.expectNoSentinelInFiles(fixture.directory, note)
        }
    }

    @Test("errors of the transport and of the key store carry no service text")
    func closedErrors() async throws {
        for failure in [ModelHTTPFailure.unreachable, .timedOut, .redirected, .tooLarge, .declinedAuthentication(status: 401)] {
            let fixture = try await ModelsFixture.make(http: StubModelHTTP.failing(failure))
            defer { fixture.remove() }
            try await fixture.save(key: Self.sentinel)
            let error = await thrown { try await fixture.models.send(texts: ["a"], instructions: "i", purpose: .titles, role: .primary) }
            #expect(error is ModelFailure)
            Self.expectNoSentinel(error as Any, "\(failure)")
        }
        let fixture = try await ModelsFixture.make(http: StubModelHTTP.answering(500))
        defer { fixture.remove() }
        fixture.keys.refuseAdds = true
        let error = await thrown { try await fixture.save(key: Self.sentinel) }
        #expect(error as? ModelSettingsError == .keyNotSaved)
        Self.expectNoSentinel(error as Any, "refused add")
    }

    private static func expectNoSentinelInFiles(_ directory: URL, _ note: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        let files = (enumerator?.allObjects as? [URL] ?? []).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        #expect(files.contains { $0.lastPathComponent == "normal.sqlite" }, sourceLocation: sourceLocation)
        let needle = Data(sentinel.utf8)
        for file in files {
            let data = try Data(contentsOf: file)
            #expect(data.range(of: needle) == nil, "\(note): \(file.lastPathComponent) holds the key", sourceLocation: sourceLocation)
        }
    }

    // MARK: - No logging in AI/ and Privacy/

    @Test("no source in AI/ or Privacy/ logs, prints or dumps")
    func noLogging() throws {
        let files = swiftSources(in: packageSourcesDirectory.appending(path: "AI")) + swiftSources(in: packageSourcesDirectory.appending(path: "Privacy"))
        #expect(files.count >= 8, "found \(files.count) sources")
        let patterns = [
            #"\bprint\s*\("#, #"\bdebugPrint\s*\("#, #"\bdump\s*\("#, #"\bNSLog\b"#, #"\bos_log\b"#, #"\bLogger\b"#,
            #"\bOSLog\b"#, #"\bimport\s+os\b"#, #"\bFileHandle\.standard"#,
        ].map { try! Regex($0) }
        var findings: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                if patterns.contains(where: { code.contains($0) }) {
                    findings.append("\(file.lastPathComponent):\(number + 1): \(code)")
                }
            }
        }
        #expect(findings.isEmpty, "\(findings)")
    }

    @Test("the key's text is read only by the keychain store and the one line that writes the Authorization header")
    func exposedValueReaders() throws {
        var readers: [String] = []
        for file in swiftSources(in: packageSourcesDirectory) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("exposedValue") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                readers.append("\(file.lastPathComponent):\(number + 1)")
            }
        }
        let byFile = Dictionary(grouping: readers) { $0.split(separator: ":").first.map(String.init) ?? "" }
        #expect(Set(byFile.keys) == ["SecretKey.swift", "KeychainKeyStore.swift", "URLSessionModelHTTP.swift"], "\(readers)")
        #expect(byFile["URLSessionModelHTTP.swift"]?.count == 1)
        #expect(byFile["KeychainKeyStore.swift"]?.count == 1)
    }
}
