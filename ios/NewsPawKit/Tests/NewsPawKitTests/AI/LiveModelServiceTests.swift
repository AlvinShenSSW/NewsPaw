import Foundation
@testable import NewsPawKit
import Synchronization
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
///
/// RD14 adds a fifth step per service: 20 fixed articles with full
/// 500-character excerpts through `TitleTranslator` into Simplified
/// Chinese, in a library of its own made for the step, reporting how many
/// requests it took, their outcomes, and how many articles were translated
/// or, for the failed ones, which check failed. It prints counts and
/// reasons only, never a text.
///
/// RD15 adds a sixth step per service (decision 16, assumption A5): one
/// fixed English article of eight chunks through `BodyTranslator` into
/// Simplified Chinese, on a library of its own, reporting the requests,
/// the chunks accepted, the failed check if any, and the seconds to the
/// first chunk. Counts, reasons and times only, never a text.
///
/// RD16 adds a seventh step per service: three fixed page requests through
/// `PageTranslator` (40 short Japanese titles; a paragraph split into five
/// runs by links; a block with a number and a name), reporting the
/// requests, their outcomes and tokens, and the runs accepted or the
/// failed check. Never a text or the key.
///
/// RD23 adds an eighth step per service (decision 16, assumptions A1 and
/// A2): 40 fixed articles of one category through `OverviewWriter` into
/// Simplified Chinese, reporting the time, the token counts, the summary's
/// length, the highlights kept and dropped, whether the reply was one text,
/// or the check that failed. Counts and reasons only, never a text.
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
        "each service in the owner's key file: list, translate, wrong key, missing model, 20 articles and an 8-chunk body through the translators, an overview of 40",
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

            // 5. Twenty articles through the translator (RD14).
            try await Self.translateArticles(name, preset: preset, address: address, model: model, key: realKey, http: http)

            // 6. An eight-chunk body through the body translator (RD15).
            try await Self.translateBody(name, preset: preset, address: address, model: model, key: realKey, http: http)

            // 7. Three page requests through the page translator (RD16).
            try await Self.translatePage(name, preset: preset, address: address, model: model, key: realKey, http: http)

            // 8. Forty articles through the overview writer (RD23).
            try await Self.writeOverview(name, preset: preset, address: address, model: model, key: realKey, http: http)
        }
    }

    /// The 40 articles of step 8: distinct titles and full excerpts, which
    /// the request cuts to 300 characters.
    static let overviewTitles = (1...40).map { "City council report \($0): the harbour, the ferries and the new quay" }

    /// A model HTTP that passes every request to the real session and keeps
    /// the last chat answer's body in memory, so that the step can count
    /// the reply's texts. Nothing of it is printed.
    final class Recording: ModelHTTP {
        private let http: URLSessionModelHTTP
        private let last = Mutex<Data?>(nil)

        init(_ http: URLSessionModelHTTP) {
            self.http = http
        }

        var lastBody: Data? {
            last.withLock { $0 }
        }

        func send(_ request: ModelHTTPRequest) async throws -> ModelHTTPResponse {
            let response = try await http.send(request)
            last.withLock { $0 = response.body }
            return response
        }
    }

    private static func writeOverview(
        _ name: String, preset: ModelPreset, address: String, model: String, key: SecretKey, http: URLSessionModelHTTP
    ) async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try await LibraryStore(directory: directory, cacheRoot: directory.appending(path: "Images")).openNormal()
        let recording = Recording(http)
        let models = LibraryModels(library: library, keys: InMemoryKeyStore(), http: recording)
        try await models.save(ModelSlotDraft(role: .primary, preset: preset, address: address, model: model, newKey: key), testedOutcome: nil)
        let category = try await library.createCategory(name: "Live", icon: .newspaper)
        let source = Sample.source(in: category.id, url: "https://live-overview.example.invalid/feed", name: "Live", at: Date())
        try await library.insert(source)
        for (index, title) in overviewTitles.enumerated() {
            var article = Sample.article(in: source.id, externalID: "live-overview-\(index)", title: title, at: Date().addingTimeInterval(Double(-index)))
            article.excerpt = String(articleExcerpt)
            try await library.insert(article)
        }
        let writer = OverviewWriter(models: models, front: AppFront(isInFront: true))
        await writer.configure(locale: .simplifiedChinese)
        let started = ContinuousClock.now
        let outcome = await writer.write(category: category.id)
        let elapsed = ContinuousClock.now - started
        let usage = try await library.usageRecords()
        let tokens = usage.map { "\($0.inputTokens.map(String.init) ?? "-")/\($0.outputTokens.map(String.init) ?? "-")" }.joined(separator: ", ")
        let texts = recording.lastBody.flatMap(ChatWire.decodeCompletion).flatMap(\.content).flatMap(ChatWire.texts(in:))
        let shape: String = switch texts?.count {
        case nil: "reply not readable"
        case 1?: "one text"
        case let count?: "\(count) texts"
        }
        let day = OverviewDay.key(for: Date(), calendar: .autoupdatingCurrent)
        let stored = try await library.overviews(on: day, locale: .simplifiedChinese)[category.id]
        var line = "\(usage.count) requests (\(usage.map(\.outcome.rawValue).joined(separator: ", "))), "
            + "\(Int(elapsed.components.seconds)) s, tokens \(tokens), \(shape), outcome \(outcome)"
        if let stored, stored.state == .done {
            let offered = texts.map { $0.count == 1 ? $0[0].split(whereSeparator: \.isNewline).filter { $0.contains("[") }.count : $0.count - 1 } ?? 0
            line += ", summary \(stored.text?.count ?? 0) characters, highlights kept \(stored.highlights.count), dropped \(max(0, offered - stored.highlights.count))"
        } else if let stored {
            line += ", failed: \(stored.failure?.rawValue ?? "?")"
         }
        Self.report(name, "overview", line)
        #expect(outcome == .stored, "\(name) overview: \(outcome)")
    }

    /// The page requests of step 7: 40 short Japanese titles, each its own
    /// block; a paragraph split into five runs by links; a block with a
    /// number and a name.
    static let pageGroups: [(String, [PageGroup])] = [
        ("40 titles", (1...40).map { number in
            PageGroup(block: number, runs: [PageRun(id: number, block: number, text: "新しい製品が発表されました、その \(number)", whole: true, inView: true)])
        }),
        ("paragraph in five runs", [PageGroup(block: 100, runs: [
            "The harbour council published", "its new plan", "for the coming year, and", "the ferry timetable", "changes in March.",
        ].enumerated().map { PageRun(id: 100 + $0.offset, block: 100, text: $0.element, whole: false, inView: true) })]),
        ("mixed block", [PageGroup(block: 200, runs: [
            PageRun(id: 200, block: 200, text: "Tim Cook", whole: false, inView: true),
            PageRun(id: 201, block: 200, text: "announced 3 new products on 12 March", whole: false, inView: true),
        ])]),
    ]

    private static func translatePage(
        _ name: String, preset: ModelPreset, address: String, model: String, key: SecretKey, http: URLSessionModelHTTP
    ) async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try await LibraryStore(directory: directory, cacheRoot: directory.appending(path: "Images")).openNormal()
        let models = LibraryModels(library: library, keys: InMemoryKeyStore(), http: http)
        try await models.save(ModelSlotDraft(role: .primary, preset: preset, address: address, model: model, newKey: key), testedOutcome: nil)
        let translator = PageTranslator(models: models)
        for (label, groups) in pageGroups {
            let before = try await library.usageRecords().count
            var accepted = 0
            var failed: [String] = []
            for unit in PageBatcher.units(groups) {
                let outcome = await translator.send(unit, host: "live.example.invalid", locale: .simplifiedChinese, route: .primary)
                accepted += outcome.writes.count
                failed += outcome.failed.map { "\($0.reason)" }
            }
            let usage = try await library.usageRecords().dropFirst(before)
            let runs = groups.reduce(0) { $0 + $1.runs.count }
            let tokens = usage.map { "\($0.inputTokens.map(String.init) ?? "-")/\($0.outputTokens.map(String.init) ?? "-")" }.joined(separator: ", ")
            Self.report(name, "page: \(label)", "\(usage.count) requests (\(usage.map(\.outcome.rawValue).joined(separator: ", "))), "
                + "\(accepted) of \(runs) runs accepted, tokens \(tokens)\(failed.isEmpty ? "" : ", failed: \(Set(failed).sorted().joined(separator: ", "))")")
            #expect(accepted == runs, "\(name) page \(label): \(accepted) of \(runs) runs accepted")
        }
    }

    /// The article of step 6: 16 paragraphs of about 700 characters.
    static let bodyParagraphs = (1...16).map { FixtureTransport.bodyParagraph($0, of: "The harbour council's report") }

    private static func translateBody(
        _ name: String, preset: ModelPreset, address: String, model: String, key: SecretKey, http: URLSessionModelHTTP
    ) async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try await LibraryStore(directory: directory, cacheRoot: directory.appending(path: "Images")).openNormal()
        let models = LibraryModels(library: library, keys: InMemoryKeyStore(), http: http)
        try await models.save(ModelSlotDraft(role: .primary, preset: preset, address: address, model: model, newKey: key), testedOutcome: nil)
        let category = try await library.createCategory(name: "Live", icon: .newspaper)
        let source = Sample.source(in: category.id, url: "https://live.example.invalid/body", name: "Live", at: Date())
        try await library.insert(source)
        let article = Sample.article(in: source.id, externalID: "live-body", title: "The harbour council's report", at: Date())
        try await library.insert(article)
        let plan = BodySegments.plan(bodyParagraphs.map { ArticleBlock(.paragraph([InlineRun($0)])) }, locale: .simplifiedChinese)
        let translator = BodyTranslator(models: models)
        let start = ContinuousClock.now
        let firstChunk = Mutex<Duration?>(nil)
        let failures = Mutex<[String]>([])
        let ends = Mutex<[BodyTranslationEnd]>([])
        await translator.setObserver { event in
            switch event {
            case .translated:
                firstChunk.withLock { $0 = $0 ?? (ContinuousClock.now - start) }
            case .failed(_, let failed):
                failures.withLock { $0 += failed.values.map(\.rawValue) }
            case .ended(_, let end):
                ends.withLock { $0.append(end) }
            }
        }
        await translator.start(BodyTranslationJob(article: article.id, locale: .simplifiedChinese, chunks: plan.chunks, route: .primary))
        await translator.settled()
        let usage = try await library.usageRecords()
        let stored = try await library.bodyTranslations(ofArticle: article.id, locale: .simplifiedChinese)
        let done = plan.finishedChunks(done: stored.compactMapValues(\.text))
        let seconds = firstChunk.withLock { $0 }.map { String(format: "%.1f s", Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18) } ?? "none"
        let failed = Set(failures.withLock { $0 }).sorted()
        Self.report(name, "body", "\(usage.count) requests (\(usage.map(\.outcome.rawValue).joined(separator: ", "))), "
            + "\(done) of \(plan.chunks.count) chunks accepted, first chunk after \(seconds)"
            + "\(failed.isEmpty ? "" : ", failed: \(failed.joined(separator: ", "))"), end: \(ends.withLock { $0 }.map { "\($0)" }.joined())")
        #expect(done == plan.chunks.count, "\(name) body: \(done) of \(plan.chunks.count) chunks accepted")
    }

    /// The 20 articles of step 5: short English titles and full excerpts.
    static let articleTitles = (1...20).map { "Harbour authority publishes its plan for the coming year, part \($0)" }
    static let articleExcerpt = String(
        repeating: "The harbour authority said the new quay will open in the spring, and that ferries will run every hour. ",
        count: 5
    ).prefix(500)

    private static func translateArticles(
        _ name: String, preset: ModelPreset, address: String, model: String, key: SecretKey, http: URLSessionModelHTTP
    ) async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try await LibraryStore(directory: directory, cacheRoot: directory.appending(path: "Images")).openNormal()
        let models = LibraryModels(library: library, keys: InMemoryKeyStore(), http: http)
        try await models.save(ModelSlotDraft(role: .primary, preset: preset, address: address, model: model, newKey: key), testedOutcome: nil)
        let category = try await library.createCategory(name: "Live", icon: .newspaper)
        let source = Sample.source(in: category.id, url: "https://live.example.invalid/feed", name: "Live", at: Date())
        try await library.insert(source)
        var ids: [UUID] = []
        for (index, title) in articleTitles.enumerated() {
            var article = Sample.article(in: source.id, externalID: "live-\(index)", title: title, at: Date().addingTimeInterval(Double(-index)))
            article.excerpt = String(articleExcerpt)
            try await library.insert(article)
            ids.append(article.id)
        }
        let translator = TitleTranslator(models: models)
        await translator.configure(TranslationConfiguration(locale: .simplifiedChinese, automatic: true))
        await translator.settled()
        let usage = try await library.usageRecords()
        let stored = try await library.translations(of: ids, locale: .simplifiedChinese)
        let done = stored.values.filter { $0.state == .done }.count
        let failures = stored.values.compactMap(\.failure).map(\.rawValue).sorted()
        let paused = await translator.pausedBy
        Self.report(name, "translator", "\(usage.count) requests (\(usage.map(\.outcome.rawValue).joined(separator: ", "))), "
            + "\(done) of 20 translated\(failures.isEmpty ? "" : ", failed: \(failures.joined(separator: ", "))")"
            + "\(paused.map { ", paused: \($0)" } ?? "")")
        #expect(done == 20, "\(name) translator: \(done) of 20 translated")
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
