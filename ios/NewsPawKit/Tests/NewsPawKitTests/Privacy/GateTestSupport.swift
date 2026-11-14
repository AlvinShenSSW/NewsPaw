import Foundation
@testable import NewsPawKit
import Synchronization
import Testing

/// The device authenticator of the package tests (RD18 decision 2): it
/// answers from a list, in order, and "unavailable" once the list is used
/// up. It can be told to hold every request until it is released, to stand
/// for a prompt that is still on screen. It never calls LocalAuthentication.
final class StubAuthenticator: DeviceAuthenticator {
    private struct State {
        var answers: [AuthenticationAnswer]
        var reasons: [String] = []
        var holds = false
        var held: [CheckedContinuation<Void, Never>] = []
    }

    private let state: Mutex<State>

    init(_ answers: [AuthenticationAnswer] = []) {
        state = Mutex(State(answers: answers))
    }

    /// The reason of every request made, in order.
    var reasons: [String] {
        state.withLock { $0.reasons }
    }

    func add(_ answers: AuthenticationAnswer...) {
        state.withLock { $0.answers += answers }
    }

    /// From now on a request waits until `release()`.
    func hold() {
        state.withLock { $0.holds = true }
    }

    /// Lets every held request answer, and later ones answer at once.
    func release() {
        let held = state.withLock { state in
            state.holds = false
            defer { state.held = [] }
            return state.held
        }
        for continuation in held {
            continuation.resume()
        }
    }

    /// Waits until `count` requests have been made.
    func waitForRequests(_ count: Int) async {
        while reasons.count < count {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    func authenticate(reason: String) async -> AuthenticationAnswer {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let holds = state.withLock { state in
                state.reasons.append(reason)
                if state.holds {
                    state.held.append(continuation)
                }
                return state.holds
            }
            if !holds {
                continuation.resume()
            }
        }
        return state.withLock { $0.answers.isEmpty ? .unavailable : $0.answers.removeFirst() }
    }
}

/// A gate over a temporary directory, with everything a test looks at.
struct GateFixture {
    let root: URL
    let directory: URL
    let cacheRoot: URL
    let suiteName: String
    let defaults: UserDefaults
    let store: LibraryStore
    let authenticator: StubAuthenticator
    let keys: InMemoryKeyStore
    let gate: AdultGate

    init(_ answers: [AuthenticationAnswer] = [], isEnabled: Bool = true) throws {
        root = try makeTemporaryDirectory()
        directory = root.appending(path: "Libraries", directoryHint: .isDirectory)
        cacheRoot = root.appending(path: "Images", directoryHint: .isDirectory)
        suiteName = "NewsPawKitTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        store = LibraryStore(directory: directory, cacheRoot: cacheRoot)
        authenticator = StubAuthenticator(answers)
        keys = InMemoryKeyStore(partition: .adult)
        gate = AdultGate(
            store: store, authenticator: authenticator, preferences: Preferences(defaults), keys: keys, isEnabled: isEnabled
        )
    }

    /// A second gate on the same directory, preferences and keys, as the
    /// next launch of the app makes one.
    func relaunched(_ answers: [AuthenticationAnswer] = [], isEnabled: Bool = true) -> (gate: AdultGate, store: LibraryStore, authenticator: StubAuthenticator) {
        let store = LibraryStore(directory: directory, cacheRoot: cacheRoot)
        let authenticator = StubAuthenticator(answers)
        let gate = AdultGate(
            store: store, authenticator: authenticator, preferences: Preferences(defaults), keys: keys, isEnabled: isEnabled
        )
        return (gate, store, authenticator)
    }

    func cleanUp() {
        // A test may have made a directory read-only.
        for url in [root, directory, cacheRoot] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }

    var databaseURL: URL {
        directory.appending(path: "adult.sqlite")
    }

    var adultCacheDirectory: URL {
        cacheRoot.appending(path: "adult", directoryHint: .isDirectory)
    }

    /// The names in the libraries directory that belong to the adult library.
    func adultFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix("adult") }.sorted()
    }

    /// Turns the partition on and unlocks it, with two passed answers.
    func turnOnAndUnlock() async throws -> Library {
        authenticator.add(.passed, .passed)
        #expect(await gate.turnOn(reason: "on") == .turnedOn)
        return try await unlock()
    }

    /// Unlocks with whatever answer is next.
    func unlock() async throws -> Library {
        guard case .unlocked(let library) = await gate.unlock(reason: "unlock") else {
            throw GateFixtureError.notUnlocked
        }
        return library
    }
}

enum GateFixtureError: Error {
    case notUnlocked
}

extension AdultGate.UnlockResult {
    /// The result without its library, for comparing.
    var summary: String {
        switch self {
        case .unlocked: "unlocked"
        case .refused(.busy): "refused(busy)"
        case .refused(.notAllowed): "refused(notAllowed)"
        case .refused(.notAuthenticated(let answer)): "refused(notAuthenticated(\(answer)))"
        case .discarded: "discarded"
        case .couldNotOpen(let error): "couldNotOpen(\(error))"
        }
    }
}

/// Waits until the store reports the adult library released, for a short
/// while: a task that held it may still be ending.
func waitForRelease(_ store: LibraryStore) async -> Bool {
    for _ in 0..<500 {
        if await store.adultLibraryIsReleased {
            return true
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return false
}
