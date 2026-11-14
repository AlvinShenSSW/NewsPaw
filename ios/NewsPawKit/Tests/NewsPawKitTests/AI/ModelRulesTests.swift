import Foundation
@testable import NewsPawKit
import Testing

/// RD13 decisions 2, 4, 5 and 6; criteria 5 and 10 (the key rule).
@Suite("Model address, name and key rules")
struct ModelRulesTests {
    // MARK: - Address (criterion 5)

    @Test("addresses accepted in normal form, with the loopback flag off", arguments: [
        ("https://api.openai.com/v1", "https://api.openai.com/v1"),
        ("  https://api.openai.com/v1/  ", "https://api.openai.com/v1"),
        ("https://api.deepseek.com///", "https://api.deepseek.com"),
        ("HTTPS://api.x.ai/v1", "https://api.x.ai/v1"),
        ("https://example.invalid:8443/api/v1", "https://example.invalid:8443/api/v1"),
        ("https://[2001:db8::1]/v1", "https://[2001:db8::1]/v1"),
        ("https://127.0.0.1/v1", "https://127.0.0.1/v1"),
    ])
    func accepted(input: String, normal: String) {
        #expect(ModelAddress.normalise(input, allowsLoopbackHTTP: false) == .success(normal))
        #expect(ModelAddress.normalise(input, allowsLoopbackHTTP: true) == .success(normal))
    }

    @Test("addresses refused, whatever the flag", arguments: [
        ("", ModelAddressProblem.empty),
        ("   ", .empty),
        ("ftp://example.invalid/v1", .notHTTPS),
        ("http://api.openai.com/v1", .notHTTPS),
        ("http://192.168.1.10/v1", .notHTTPS),
        ("http://localhost.example.invalid/v1", .notHTTPS),
        ("https://", .noHost),
        ("https:///v1", .noHost),
        ("https://user:secret@example.invalid/v1", .credentials),
        ("https://user@example.invalid/v1", .credentials),
        ("https://example.invalid/v1?key=1", .queryOrFragment),
        ("https://example.invalid/v1?", .queryOrFragment),
        ("https://example.invalid/v1#part", .queryOrFragment),
        ("api.openai.com/v1", .invalid),
        ("https://exa mple.invalid/v1", .invalid),
        ("https://example.invalid/" + String(repeating: "a", count: 2_048), .tooLong),
    ])
    func refused(input: String, problem: ModelAddressProblem) {
        for flag in [false, true] {
            #expect(ModelAddress.normalise(input, allowsLoopbackHTTP: flag) == .failure(problem), "flag \(flag)")
        }
    }

    @Test("http to a loopback host is accepted only with the flag on", arguments: [
        ("http://localhost:8080/v1", "http://localhost:8080/v1"),
        ("http://127.0.0.1:11434/v1/", "http://127.0.0.1:11434/v1"),
        ("http://[::1]:8080/v1", "http://[::1]:8080/v1"),
        ("HTTP://LOCALHOST/v1", "http://LOCALHOST/v1"),
    ])
    func loopbackHTTP(input: String, normal: String) {
        #expect(ModelAddress.normalise(input, allowsLoopbackHTTP: false) == .failure(.notHTTPS))
        #expect(ModelAddress.normalise(input, allowsLoopbackHTTP: true) == .success(normal))
    }

    @Test("2,048 characters are accepted, 2,049 are not")
    func lengthLimit() {
        let prefix = "https://example.invalid/"
        let fits = prefix + String(repeating: "a", count: 2_048 - prefix.count)
        #expect(ModelAddress.normalise(fits, allowsLoopbackHTTP: false) == .success(fits))
        #expect(ModelAddress.normalise(fits + "a", allowsLoopbackHTTP: false) == .failure(.tooLong))
    }

    @Test("every preset's address is in normal form and accepted with the flag off; Custom is empty")
    func presets() {
        for preset in ModelPreset.allCases where preset != .custom {
            #expect(ModelAddress.normalise(preset.address, allowsLoopbackHTTP: false) == .success(preset.address), "\(preset)")
        }
        #expect(ModelPreset.custom.address.isEmpty)
        // The owner's instruction of 2026-11-14: MiMo's preset is the Token
        // Plan address.
        #expect(ModelPreset.miMo.address == "https://token-plan-cn.xiaomimimo.com/v1")
        #expect(ModelPreset.deepSeek.address == "https://api.deepseek.com")
    }

    @Test("the origin is scheme, host and port; the path does not count", arguments: [
        ("https://api.openai.com/v1", "https://api.openai.com/v2/other", true),
        ("https://api.openai.com/v1", "https://API.OPENAI.COM", true),
        ("https://api.openai.com/v1", "https://api.openai.com:443/v1", true),
        ("https://api.openai.com/v1", "https://api.openai.com:8443/v1", false),
        ("https://api.openai.com/v1", "http://api.openai.com/v1", false),
        ("https://api.openai.com/v1", "https://api.deepseek.com", false),
        ("https://api.openai.com/v1", "https://openai.com/v1", false),
        ("http://localhost/v1", "http://localhost:80/v1", true),
        ("https://api.openai.com/v1", "", false),
        ("", "", false),
    ])
    func origin(first: String, second: String, same: Bool) {
        #expect(ModelAddress.sameOrigin(first, second) == same)
        #expect(ModelAddress.sameOrigin(second, first) == same)
    }

    // MARK: - Model name

    @Test("model names: trimmed, 1 to 200 characters, no control character")
    func modelNames() {
        #expect(ModelName.validate("  gpt-5-mini \n") == .success("gpt-5-mini"))
        #expect(ModelName.validate("models/gemini-2.5-flash") == .success("models/gemini-2.5-flash"))
        #expect(ModelName.validate("模型") == .success("模型"))
        #expect(ModelName.validate(String(repeating: "m", count: 200)) == .success(String(repeating: "m", count: 200)))
        #expect(ModelName.validate(String(repeating: "m", count: 201)) == .failure(.tooLong))
        #expect(ModelName.validate("   ") == .failure(.empty))
        #expect(ModelName.validate("gpt\n5") == .failure(.controlCharacter))
        #expect(ModelName.validate("gpt\u{7}5") == .failure(.controlCharacter))
    }

    // MARK: - Key (criterion 10)

    @Test("a pasted key loses its surrounding white space and line breaks")
    func keyTrimmed() throws {
        let key = try SecretKey.validate("  sk-abc123XYZ\r\n").get()
        #expect(key.exposedValue == "sk-abc123XYZ")
    }

    @Test("a key with a line break, a control or a non-ASCII character is refused", arguments: [
        ("sk-abc\ndef", KeyProblem.invalidCharacter),
        ("sk-abc\r\nX-Other: 1", .invalidCharacter),
        ("sk-abc\tdef", .invalidCharacter),
        ("sk-abc\u{0}def", .invalidCharacter),
        ("sk-ключ", .invalidCharacter),
        ("sk-密钥", .invalidCharacter),
        ("sk-\u{00A0}abc", .invalidCharacter),
        ("", .empty),
        (" \n ", .empty),
    ])
    func keyRefused(text: String, problem: KeyProblem) {
        #expect(SecretKey.validate(text) == .failure(problem))
    }

    @Test("1 to 4,096 printable ASCII characters are accepted")
    func keyLength() {
        #expect((try? SecretKey.validate("k").get()) != nil)
        #expect((try? SecretKey.validate("sk or-v1 with a space~!").get()) != nil)
        #expect((try? SecretKey.validate(String(repeating: "k", count: 4_096)).get()) != nil)
        #expect(SecretKey.validate(String(repeating: "k", count: 4_097)) == .failure(.tooLong))
    }

    @Test("a key's description, debug description, interpolation, mirror and dump show only the placeholder")
    func keyDoesNotPrint() {
        let sentinel = "sk-SENTINEL-print-0123456789"
        let secret = key(sentinel)
        var dumped = ""
        dump(secret, to: &dumped)
        var dumpedOptional = ""
        dump(Optional(secret), to: &dumpedOptional)
        let renderings = [
            secret.description, secret.debugDescription, "\(secret)", String(describing: secret), String(reflecting: secret),
            "\(Mirror(reflecting: secret).children.map { "\($0.label ?? ""): \($0.value)" })", dumped, dumpedOptional,
        ]
        for rendering in renderings {
            #expect(!rendering.contains(sentinel))
            #expect(!rendering.contains("SENTINEL"))
        }
        #expect(Mirror(reflecting: secret).children.isEmpty)
    }

    @Test("the last four characters are shown only for a key of 12 characters or more")
    func lastFour() {
        #expect(key("sk-0123456789ab").lastFour == "89ab")
        #expect(key("012345678901").lastFour == "8901")
        #expect(key("01234567890").lastFour == nil)
    }

    // MARK: - Criterion 5: the flag's only `true` is inside `#if DEBUG`

    @Test("the loopback flag's only true is inside #if DEBUG, and no source passes true for it")
    func loopbackFlagOnlyInDebug() throws {
        let files = swiftSources(in: packageSourcesDirectory)
        #expect(files.count > 20, "found \(files.count) package sources")
        var definitions: [String] = []
        var literalTrue: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            // The stack of the enclosing #if blocks, each with whether this
            // line is in its DEBUG branch.
            var stack: [Bool] = []
            for (number, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#if ") {
                    stack.append(trimmed == "#if DEBUG")
                } else if trimmed.hasPrefix("#else") || trimmed.hasPrefix("#elseif") {
                    if !stack.isEmpty { stack[stack.count - 1] = false }
                } else if trimmed.hasPrefix("#endif") {
                    _ = stack.popLast()
                }
                let place = "\(file.lastPathComponent):\(number + 1)"
                if trimmed.contains("allowsLoopbackHTTPInThisBuild =") {
                    definitions.append(place)
                    if trimmed.hasSuffix("= true") {
                        #expect(stack.last == true, "\(place) sets the flag true outside #if DEBUG")
                    } else {
                        #expect(trimmed.hasSuffix("= false"), "\(place)")
                    }
                }
                if trimmed.contains("allowsLoopbackHTTP: true") {
                    literalTrue.append(place)
                }
            }
        }
        #expect(definitions.count == 2, "\(definitions)")
        #expect(literalTrue.isEmpty, "\(literalTrue)")
        // In this (debug) test build the constant is true.
        #expect(ModelAddress.allowsLoopbackHTTPInThisBuild)
    }

    @Test("the model fixture is compiled into debug builds only")
    func fixtureOnlyInDebug() throws {
        let text = try String(contentsOf: packageSourcesDirectory.appending(path: "AI/FixtureModelHTTP.swift"), encoding: .utf8)
        #expect(text.hasPrefix("#if DEBUG\n"))
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("#endif"))
    }
}
