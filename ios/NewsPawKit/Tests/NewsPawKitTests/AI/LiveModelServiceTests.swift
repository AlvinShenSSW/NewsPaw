import Foundation
@testable import NewsPawKit
import Testing

/// RD13 decision 13 (criterion 14): the real-service check. Disabled unless
/// `NEWSPAW_LIVE_MODEL_KEYS` names the owner's key file, which lives outside
/// the repository (`~/.config/newspaw/model-keys.env`) and holds, per
/// service to check, `<NAME>_API_KEY`, `<NAME>_MODEL` and optionally
/// `<NAME>_BASE_URL`.
///
/// For each service in the file it makes four requests through the real
/// session: the model list; a chat translating two short English sentences
/// into Simplified Chinese, expecting two non-empty texts; Test's request
/// with a made-up wrong key; Test's request with a model name that does not
/// exist. It prints, per service and step, the HTTP status and the outcome
/// only — never a body, never a key — and "not run" for a service the file
/// does not name. No `#expect` here names a key, so a failure cannot print
/// one either.
@Suite("Real model services (enabled by NEWSPAW_LIVE_MODEL_KEYS)")
struct LiveModelServiceTests {
    static let variable = "NEWSPAW_LIVE_MODEL_KEYS"

    static let services: [(name: String, preset: ModelPreset)] = [
        ("OPENAI", .openAI), ("DEEPSEEK", .deepSeek), ("XAI", .xAI), ("MIMO", .miMo), ("OPENROUTER", .openRouter), ("GEMINI", .gemini),
    ]

    /// A made-up key that no service issued.
    static let wrongKey = "sk-newspaw-made-up-wrong-key-00000000000000000000"
    /// A model name that no service has.
    static let missingModel = "newspaw-no-such-model-2026"

    static let translateInstructions =
        "Translate each text into Simplified Chinese. Return exactly one translation per input text, in the same order."
    static let translateTexts = ["The weather is fine today.", "The library opens at nine in the morning."]

    @Test(
        "each service in the owner's key file: list, translate, wrong key, missing model",
        .enabled(if: ProcessInfo.processInfo.environment[variable] != nil, "set NEWSPAW_LIVE_MODEL_KEYS to the owner's key file")
    )
    func realServices() async throws {
        guard let path = ProcessInfo.processInfo.environment[Self.variable] else { return }
        let values = try Self.read(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        let http = URLSessionModelHTTP()
        for (name, preset) in Self.services {
            guard let keyText = values["\(name)_API_KEY"], let modelText = values["\(name)_MODEL"] else {
                Self.report(name, "all steps", "not run")
                continue
            }
            guard case .success(let address) = ModelAddress.normalise(values["\(name)_BASE_URL"] ?? preset.address, allowsLoopbackHTTP: false) else {
                Self.report(name, "all steps", "not run: the address is refused by the address rule")
                Issue.record("\(name): the address is refused by the address rule")
                continue
            }
            guard case .success(let realKey) = SecretKey.validate(keyText), case .success(let wrongKey) = SecretKey.validate(Self.wrongKey) else {
                Self.report(name, "all steps", "not run: the key is refused by the key rule")
                Issue.record("\(name): the key is refused by the key rule")
                continue
            }
            guard case .success(let model) = ModelName.validate(modelText) else {
                Self.report(name, "all steps", "not run: the model name is refused")
                Issue.record("\(name): the model name is refused")
                continue
            }

            // 1. The model list.
            let list = await Self.exchange(http, ChatWire.listRequest(address: address, key: realKey))
            switch list.response.map(ChatWire.classifyList) {
            case .success(let models)?:
                Self.report(name, "list", "HTTP \(list.status) → ok, \(models.count) models")
            case .failure(let failure)?:
                Self.report(name, "list", "HTTP \(list.status) → \(failure)")
                Issue.record("\(name) list: \(failure)")
            default:
                Self.report(name, "list", "no answer → \(list.failure.map { "\($0)" } ?? "?")")
                Issue.record("\(name) list: no answer")
            }

            // 2. A translation of two sentences.
            let chat = await Self.exchange(http, ChatWire.chatRequest(
                address: address, model: model, instructions: Self.translateInstructions, texts: Self.translateTexts, key: realKey
            ))
            switch chat.response.map(ChatWire.classifyChat) {
            case .success(let completion)?:
                switch ChatWire.interpret(completion) {
                case .success(let reply):
                    let usable = reply.texts.count == 2 && reply.texts.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    Self.report(name, "translate", "HTTP \(chat.status) → ok, \(reply.texts.count) texts\(usable ? "" : " (not two non-empty texts)")\(reply.isCutOff ? ", cut off" : ""), tokens \(reply.inputTokens.map(String.init) ?? "-")/\(reply.outputTokens.map(String.init) ?? "-")")
                    #expect(usable, "\(name) translate: expected two non-empty texts")
                case .failure(let failure):
                    Self.report(name, "translate", "HTTP \(chat.status) → \(failure)")
                    Issue.record("\(name) translate: \(failure)")
                }
            case .failure(let failure)?:
                Self.report(name, "translate", "HTTP \(chat.status) → \(failure)")
                Issue.record("\(name) translate: \(failure)")
            default:
                Self.report(name, "translate", "no answer → \(chat.failure.map { "\($0)" } ?? "?")")
                Issue.record("\(name) translate: no answer")
            }

            // 3. Test with a wrong key; 4. Test with a missing model.
            for (step, stepKey, stepModel, expected) in [
                ("wrong key", wrongKey, model, TestOutcome.keyRejected), ("missing model", realKey, Self.missingModel, .modelNotFound),
            ] {
                let test = await Self.exchange(http, ChatWire.chatRequest(
                    address: address, model: stepModel, instructions: LibraryModels.testInstructions, texts: LibraryModels.testTexts, key: stepKey
                ))
                let line: TestOutcome = switch test.response.map(ChatWire.classifyChat) {
                case .success?: .passed
                case .failure(let failure)?: TestOutcome(failure)
                default: TestOutcome(test.failure.map(ChatWire.failure) ?? .unreachable)
                }
                Self.report(name, step, "\(test.status == 0 ? "no answer" : "HTTP \(test.status)") → Test line \(line)")
                #expect(line == expected, "\(name) \(step): HTTP \(test.status)")
            }
        }
    }

    /// One exchange: the response, or the transport failure; `status` is 0
    /// without an answer (or the status of a declined challenge).
    private static func exchange(_ http: URLSessionModelHTTP, _ request: ModelHTTPRequest?) async -> (response: ModelHTTPResponse?, status: Int, failure: ModelHTTPFailure?) {
        guard let request else { return (nil, 0, .unreachable) }
        do {
            let response = try await http.send(request)
            return (response, response.status, nil)
        } catch let failure as ModelHTTPFailure {
            if case .declinedAuthentication(let status) = failure {
                return (nil, status, failure)
            }
            return (nil, 0, failure)
        } catch {
            return (nil, 0, .unreachable)
        }
    }

    /// Prints one line: the service, the step and its result. Nothing else
    /// is ever printed.
    private static func report(_ service: String, _ step: String, _ result: String) {
        print("LIVE \(service) \(step): \(result)")
    }

    /// `NAME=value` lines; blank lines and `#` comments are skipped, an
    /// `export ` prefix and surrounding quotes are removed.
    static func read(_ url: URL) throws -> [String: String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var values: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            if !value.isEmpty {
                values[name] = value
            }
        }
        return values
    }

    @Test("the key file reader skips comments and removes quotes and export")
    func keyFileReader() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "keys.env")
        try "# comment\nexport OPENAI_API_KEY=\"sk-a\"\nOPENAI_MODEL = gpt-x\n\nMIMO_BASE_URL='https://example.invalid/v1'\nEMPTY=\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(try Self.read(file) == ["OPENAI_API_KEY": "sk-a", "OPENAI_MODEL": "gpt-x", "MIMO_BASE_URL": "https://example.invalid/v1"])
    }
}
