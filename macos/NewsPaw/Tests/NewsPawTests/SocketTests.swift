import Darwin
import Dispatch
import Foundation
import Testing
@testable import NewsPaw

final class FixtureSocket {
    private let directory: URL
    let path: String
    private var fd: Int32

    init() throws {
        directory = URL(fileURLWithPath: "/tmp/np-swift-\(UUID().uuidString.prefix(10))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        path = directory.appendingPathComponent("control.sock").path
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try UnixSocketAddress(path)
        guard fd >= 0, address.withPointer({ Darwin.bind(fd, $0, $1) }) == 0,
              Darwin.listen(fd, 1) == 0 else {
            close()
            throw SocketFailure.disconnected
        }
    }

    deinit { close() }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        try? FileManager.default.removeItem(at: directory)
    }

    struct HeldReply: Sendable {
        let index: Int
        let received: AsyncStream<Void>.Continuation
        let release: DispatchSemaphore
    }

    func serve(
        _ replies: [String], holdMilliseconds: Int = 0, heldReply: HeldReply? = nil
    ) -> Task<[String], Error> {
        let listener = fd
        return Task.detached { @Sendable in
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(with: Result {
                        try FixtureSocket.serveReplies(
                            replies, on: listener, holdMilliseconds: holdMilliseconds, heldReply: heldReply
                        )
                    })
                }
            }
        }
    }

    private static func serveReplies(
        _ replies: [String], on listener: Int32, holdMilliseconds: Int, heldReply: HeldReply?
    ) throws -> [String] {
        var requests: [String] = []
        var pending: (client: Int32, reply: String)?
        defer {
            if let pending { Darwin.close(pending.client) }
            heldReply?.received.finish()
        }
        for (index, reply) in replies.enumerated() {
            var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&ready, 1, 2_000) == 1 else { throw SocketFailure.timeout }
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { throw SocketFailure.disconnected }
            defer { if pending?.client != client { Darwin.close(client) } }
            var noSignal: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var receiveTimeout = timeval(tv_sec: 2, tv_usec: 0)
            _ = setsockopt(
                client, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size)
            )
            var request = Data()
            while !request.contains(10) {
                var buffer = [UInt8](repeating: 0, count: 128)
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.recv(client, $0.baseAddress!, $0.count, 0)
                }
                guard count > 0, request.count + count < 4_096 else {
                    throw SocketFailure.invalidFrame
                }
                request.append(contentsOf: buffer.prefix(count))
            }
            requests.append(String(decoding: request.dropLast(), as: UTF8.self))
            if let heldReply, heldReply.index == index {
                pending = (client, reply)
                heldReply.received.finish()
                continue
            }
            try Self.send(reply, to: client)
            if holdMilliseconds > 0 {
                Thread.sleep(forTimeInterval: Double(holdMilliseconds) / 1_000)
            }
        }
        if let pending, let heldReply {
            guard heldReply.release.wait(timeout: .now() + .seconds(2)) == .success else {
                throw SocketFailure.timeout
            }
            try Self.send(pending.reply, to: pending.client)
        }
        return requests
    }

    private static func send(_ reply: String, to client: Int32) throws {
        // Deliberately split a reply across writes.
        let split = reply.index(after: reply.startIndex)
        for fragment in [String(reply[..<split]), String(reply[split...])] {
            let data = Data(fragment.utf8)
            let count = data.withUnsafeBytes {
                Darwin.send(client, $0.baseAddress, $0.count, 0)
            }
            guard count == data.count else { throw SocketFailure.disconnected }
        }
    }
}

@Test func readsAFragmentedReplyFromActualUnixSocket() async throws {
    let fixture = try FixtureSocket()
    let replies = fixture.serve([#"{"ok":true,"result":12}"# + "\n"])
    let client = LocalSocket(path: fixture.path)
    let request = #"{"op":"service.status"}"#
    let result = try await client.request(Data(request.utf8))
    #expect(String(decoding: result, as: UTF8.self) == #"{"ok":true,"result":12}"#)
    #expect(try await replies.value == [request])
}

@Test func frameDeadlineAlsoBoundsAnUnfinishedReply() async throws {
    let fixture = try FixtureSocket()
    let replies = fixture.serve([#"{"ok":true"#], holdMilliseconds: 180)
    let client = LocalSocket(path: fixture.path, timeoutMilliseconds: 60)
    await #expect(throws: SocketFailure.timeout) {
        _ = try await client.request(Data(#"{"op":"service.status"}"#.utf8))
    }
    _ = try await replies.value
}

@Test @MainActor func refreshingAnOfflineModelClearsActualBackendData() async throws {
    let fixture = try FixtureSocket()
    let config = #"{"revision":2,"document":{"ui_locale":"en","news_output_locale":"ja","categories":[],"subscriptions":[],"sources":[],"accounts":[],"model_profiles":[]}}"#
    let bots = #"[{"id":"bot1","name":"Fixture","verified":true,"paired":false,"paused":false}]"#
    let replies = fixture.serve([
        #"{"ok":true,"result":{"protocol_version":1,"state":"running"}}"# + "\n",
        "{\"ok\":true,\"result\":" + config + "}\n",
        "{\"ok\":true,\"result\":" + bots + "}\n",
    ])
    let name = "NewsPawTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let model = AppModel(socket: LocalSocket(path: fixture.path), defaults: defaults)
    await model.refresh()
    #expect(model.connection == .connected)
    #expect(model.uiLanguage == .en)
    #expect(model.config?.newsOutputLocale == .ja)
    #expect(model.bots.first?.paired == false)
    #expect(try await replies.value.count == 3)
    fixture.close()
    await model.refresh()
    #expect(model.connection == .offline)
    #expect(model.config == nil && model.bots.isEmpty)
    await model.chooseDisplayLanguage(.zhHans)
    #expect(model.uiLanguage == .zhHans)
    #expect(model.config == nil)
}

@Test(arguments: [0, 1, 2])
@MainActor func languageSaveMergesABackgroundRevisionAndReportsOnlyARepeatedConflict(conflicts: Int) async throws {
    let fixture = try FixtureSocket()
    let running = #"{"ok":true,"result":{"protocol_version":1,"state":"running"}}"# + "\n"
    let stopping = #"{"ok":true,"result":{"protocol_version":1,"state":"stopping"}}"# + "\n"
    let emptyBots = #"{"ok":true,"result":[]}"# + "\n"
    let conflict = #"{"ok":false,"error":"config_conflict","error_detail":{"code":"config_conflict","domain":"config","retryable":false}}"# + "\n"
    let saved = #"{"ok":true,"result":{}}"# + "\n"
    func config(_ locale: AppLanguage, revision: Int) -> String {
        #"{"ok":true,"result":{"revision":\#(revision),"document":{"ui_locale":"en","news_output_locale":"\#(locale.rawValue)","categories":[],"subscriptions":[],"sources":[],"accounts":[],"model_profiles":[]}}}"# + "\n"
    }
    // Each save attempt reads the newest document first; only a second conflict in a row
    // is reported (interaction-spec §2.3).
    var attempts: [String] = []
    for attempt in 0..<min(conflicts + 1, 2) {
        attempts += [config(.zhHans, revision: 1 + attempt), attempt < conflicts ? conflict : saved]
    }
    let newLocale: AppLanguage = conflicts >= 2 ? .zhHans : .ja
    let (received, markReceived) = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    let script = [running, config(.zhHans, revision: 1), emptyBots, stopping]
        + attempts + [running, config(newLocale, revision: 3), emptyBots]
    let replies = fixture.serve(script, heldReply: .init(index: 3, received: markReceived, release: release))
    let name = "NewsPawTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    // The held poll stays open for the whole save (up to four more round trips); on a slow
    // runner that outlasts the 1.8 s default deadline, the poll gives up and its reply
    // has nowhere to go. A longer deadline keeps the test about ordering, not speed.
    let model = AppModel(socket: LocalSocket(path: fixture.path, timeoutMilliseconds: 10_000), defaults: defaults)
    await model.refresh()
    let stale = Task { await model.refresh() }
    for await _ in received {}
    await model.chooseNewsLanguage(.ja)
    #expect(model.config?.newsOutputLocale == newLocale)
    #expect(model.error == (conflicts >= 2 ? .conflict : nil))
    release.signal()
    await stale.value
    #expect(model.connection == .connected)
    #expect(model.config?.newsOutputLocale == newLocale)
    #expect(try await replies.value.count == script.count)
}

@Test @MainActor func modelProbeRetainsReceiptIdentityWhenStatusRefreshDisconnects() async throws {
    let fixture = try FixtureSocket()
    let running = #"{"ok":true,"result":{"protocol_version":1,"state":"running"}}"# + "\n"
    let configuration = #"""
    {"ok":true,"result":{"revision":2,"document":{"ui_locale":"en","news_output_locale":"ja","categories":[],"subscriptions":[],"sources":[],"accounts":[],"model_profiles":[{"id":"normal_primary","partition":"normal","role":"primary","provider":"openai","base_url":"https://example.com/v1","model":"fixture","capabilities":["text"]}]}}}
    """# + "\n"
    let emptyBots = #"{"ok":true,"result":[]}"# + "\n"
    let verified = #"{"ok":true,"result":{"status":"verified"}}"# + "\n"
    let statuses = #"{"ok":true,"result":{"text":{"state":"verified"}}}"# + "\n"
    let replies = fixture.serve([
        running, configuration, emptyBots,
        verified, configuration, #"{"ok":true"#,
        verified, configuration, statuses,
    ])
    let name = "NewsPawTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let model = AppModel(socket: LocalSocket(path: fixture.path), defaults: defaults)
    await model.refresh()
    #expect(model.connection == .connected)
    let profile = "normal_primary"
    let identity = ["openai", "https://example.com/v1", "fixture"]
    let request = ModelProbeRequest(revision: 1, capability: "text", units: 25)
    model.pendingModelProbes[profile] = request
    await #expect(throws: SocketFailure.invalidFrame) {
        _ = try await model.resolveModelProbe(request, profileId: profile, identity: identity)
    }
    let retry = try #require(model.pendingModelProbes[profile])
    #expect(retry.id == request.id)
    let result = try await model.resolveModelProbe(retry, profileId: profile, identity: identity)
    #expect(result.revision == 2)
    #expect(result.result.status == "verified")
    #expect(result.statuses["text"]?.state == "verified")
    #expect(model.pendingModelProbes[profile] == nil)
    let requests = try await replies.value
    let first = try JSONSerialization.jsonObject(with: Data(requests[3].utf8)) as? NSDictionary
    let second = try JSONSerialization.jsonObject(with: Data(requests[6].utf8)) as? NSDictionary
    #expect(first != nil && first == second)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NEWSPAW_UI_TEST_SOCKET"] != nil))
@MainActor func realIsolatedBackendLanguageAndStop() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["NEWSPAW_UI_TEST_SOCKET"])
    // This integration test mutates and stops only a newly created development fixture.
    let fixture = URL(fileURLWithPath: path)
    guard fixture.lastPathComponent == "control.sock",
          fixture.deletingLastPathComponent().lastPathComponent.hasPrefix("np-ui."),
          fixture.deletingLastPathComponent().deletingLastPathComponent().path == "/tmp" else {
        throw SocketFailure.invalidPath
    }
    let socket = LocalSocket(path: path)
    let client = BackendClient(socket: socket)
    let name = "NewsPawTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let model = AppModel(socket: socket, defaults: defaults)
    await model.refresh()
    #expect(model.connection == .connected)
    await model.chooseNewsLanguage(.ja)
    await model.chooseDisplayLanguage(.en)
    let config = try await client.config()
    #expect(config.document.newsOutputLocale == .ja)
    #expect(config.document.uiLocale == .en)
    #expect(model.uiLanguage == .en)
    await model.stopBackend()
    #expect(model.connection == .stopping)
    for _ in 0..<10 {
        await model.refresh()
        if model.connection == .offline { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(model.connection == .offline)
    #expect(model.config == nil)
}
