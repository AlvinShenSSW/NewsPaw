import Darwin
import Foundation

enum SocketFailure: Error, Equatable {
    case disconnected
    case timeout
    case invalidPath
    case invalidFrame
    case wrongPeer
}

struct UnixSocketAddress {
    private var address: sockaddr_un

    init(_ path: String) throws {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard path.hasPrefix("/"), !bytes.contains(0),
              bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw SocketFailure.invalidPath
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        self.address = address
    }

    mutating func withPointer<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}

struct LocalSocket: Sendable {
    static let maxFrame = 8 * 1024 * 1024
    let path: String
    var timeoutMilliseconds: Int = 1_800

    /// The exchange blocks in `poll`, so it runs on a Dispatch thread: a blocked thread from
    /// Swift's small cooperative pool would stall every other task, including other requests.
    func request(_ body: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try exchange(body) })
            }
        }
    }

    private func exchange(_ body: Data) throws -> Data {
        guard !body.isEmpty, body.count < Self.maxFrame, !body.contains(10) else {
            throw SocketFailure.invalidFrame
        }
        var address = try UnixSocketAddress(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketFailure.disconnected }
        defer { Darwin.close(fd) }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(1, min(timeoutMilliseconds, 35_000))) * 1_000_000
        let flags = fcntl(fd, F_GETFL)
        var noSignal: Int32 = 1
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw SocketFailure.disconnected
        }
        if address.withPointer({ Darwin.connect(fd, $0, $1) }) != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { throw SocketFailure.disconnected }
            try wait(fd, for: Int16(POLLOUT), deadline: deadline)
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                throw SocketFailure.disconnected
            }
        }
        var peerUser: uid_t = 0
        var peerGroup: gid_t = 0
        guard getpeereid(fd, &peerUser, &peerGroup) == 0, peerUser == geteuid() else {
            throw SocketFailure.wrongPeer
        }
        var framed = body
        framed.append(10)
        try write(framed, to: fd, deadline: deadline)
        return try read(from: fd, deadline: deadline)
    }

    private func wait(_ fd: Int32, for event: Int16, deadline: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw SocketFailure.timeout }
            let milliseconds = Int32((deadline - now + 999_999) / 1_000_000)
            var descriptor = pollfd(fd: fd, events: event, revents: 0)
            let ready = Darwin.poll(&descriptor, 1, milliseconds)
            if ready > 0 {
                guard descriptor.revents & Int16(POLLNVAL) == 0 else {
                    throw SocketFailure.disconnected
                }
                return
            }
            if ready == 0 { throw SocketFailure.timeout }
            if errno != EINTR { throw SocketFailure.disconnected }
        }
    }

    private func write(_ data: Data, to fd: Int32, deadline: UInt64) throws {
        var offset = 0
        while offset < data.count {
            try wait(fd, for: Int16(POLLOUT), deadline: deadline)
            let sent = data.withUnsafeBytes {
                Darwin.send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, 0)
            }
            if sent > 0 {
                offset += sent
            } else if sent == 0 || ![EINTR, EAGAIN, EWOULDBLOCK].contains(errno) {
                throw SocketFailure.disconnected
            }
        }
    }

    private func read(from fd: Int32, deadline: UInt64) throws -> Data {
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            try wait(fd, for: Int16(POLLIN), deadline: deadline)
            let count = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!, $0.count, 0) }
            if count < 0, [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
            guard count > 0 else { throw SocketFailure.invalidFrame }
            let received = buffer.prefix(count)
            let newline = received.firstIndex(of: 10)
            let slice = newline.map { received.prefix(upTo: $0) } ?? received
            guard reply.count + slice.count < Self.maxFrame else { throw SocketFailure.invalidFrame }
            reply.append(contentsOf: slice)
            if newline != nil {
                guard !reply.isEmpty else { throw SocketFailure.invalidFrame }
                return reply
            }
        }
    }
}
