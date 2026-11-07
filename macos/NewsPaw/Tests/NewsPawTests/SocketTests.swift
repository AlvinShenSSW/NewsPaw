import Darwin
import Foundation
import Testing
@testable import NewsPaw

private final class FixtureSocket {
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

    func serve(_ replies: [String], holdMilliseconds: Int = 0) -> Task<[String], Error> {
        let listener = fd
        return Task.detached {
            var requests: [String] = []
            for reply in replies {
                var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard Darwin.poll(&ready, 1, 2_000) == 1 else { throw SocketFailure.timeout }
                let client = Darwin.accept(listener, nil, nil)
                guard client >= 0 else { throw SocketFailure.disconnected }
                defer { Darwin.close(client) }
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
                // Deliberately split a reply across writes.
                let split = reply.index(after: reply.startIndex)
                for fragment in [String(reply[..<split]), String(reply[split...])] {
                    let data = Data(fragment.utf8)
                    let count = data.withUnsafeBytes {
                        Darwin.send(client, $0.baseAddress, $0.count, 0)
                    }
                    guard count == data.count else { throw SocketFailure.disconnected }
                }
                if holdMilliseconds > 0 {
                    try await Task.sleep(for: .milliseconds(holdMilliseconds))
                }
            }
            return requests
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
    let rpc = BackendRPC(socket: socket)
    let name = "NewsPawTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let model = AppModel(socket: socket, defaults: defaults)
    await model.refresh()
    #expect(model.connection == .connected)
    await model.chooseNewsLanguage(.ja)
    await model.chooseDisplayLanguage(.en)
    let config: ConfigSnapshot = try BackendRPC.decode(await rpc.get("config.get"))
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
