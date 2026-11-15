import Foundation
@testable import NewsPawKit
import Testing

/// RD18: the gate in front of the adult library (decision 2), over a
/// temporary directory, with the stub authenticator and the in-memory key
/// store. LocalAuthentication and the keychain are never called.
@Suite("Adult gate")
struct AdultGateTests {
    static let refusals: [AuthenticationAnswer] = [.cancelled, .interrupted, .failed, .unavailable]

    // MARK: - Criterion 1: a fresh install

    @Test("a fresh install: the gate is off and there is no adult file")
    func freshInstall() async throws {
        let fixture = try GateFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.store.openNormal()

        #expect(await fixture.gate.state == .off)
        #expect(!fixture.gate.adultLibraryFileExists)
        #expect(fixture.adultFiles().isEmpty)
        #expect(await fixture.gate.lockTiming == .immediately)
        #expect(await fixture.store.adultLibraryIsClosed)
        // Nothing asked the owner to authenticate.
        #expect(fixture.authenticator.reasons.isEmpty)
    }

    // MARK: - Criterion 2: turning on

    @Test("turning on: an authentication that does not pass changes nothing", arguments: refusals)
    func turnOnRefused(answer: AuthenticationAnswer) async throws {
        let fixture = try GateFixture([answer])
        defer { fixture.cleanUp() }

        #expect(await fixture.gate.turnOn(reason: "Turn on") == .refused(.notAuthenticated(answer)))

        #expect(await fixture.gate.state == .off)
        #expect(!Preferences(fixture.defaults).adultPartitionIsOn)
        #expect(fixture.adultFiles().isEmpty)
        #expect(fixture.authenticator.reasons == ["Turn on"])
    }

    @Test("turning on: a passed authentication creates the file and leaves the partition locked")
    func turnOnPassed() async throws {
        let fixture = try GateFixture([.passed])
        defer { fixture.cleanUp() }

        #expect(await fixture.gate.turnOn(reason: "Turn on the adult partition") == .turnedOn)

        #expect(await fixture.gate.state == .locked)
        #expect(Preferences(fixture.defaults).adultPartitionIsOn)
        #expect(fixture.gate.adultLibraryFileExists)
        // Created, then released: nothing holds the file open.
        #expect(await fixture.store.adultLibraryIsClosed)
        #expect(fixture.authenticator.reasons == ["Turn on the adult partition"])
        // Turning on twice is not an operation.
        #expect(await fixture.gate.turnOn(reason: "again") == .refused(.notAllowed))
        #expect(fixture.authenticator.reasons.count == 1)
    }

    @Test("criterion 11: turning on does not open an existing file, even a damaged one")
    func turnOnDoesNotOpenAnExistingFile() async throws {
        let fixture = try GateFixture([.passed])
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let garbage = Data(repeating: 0x41, count: 8192)
        try garbage.write(to: fixture.databaseURL)

        #expect(await fixture.gate.turnOn(reason: "on") == .turnedOn)

        #expect(await fixture.gate.state == .locked)
        #expect(try Data(contentsOf: fixture.databaseURL) == garbage)
        // An opened database would have its side files beside it.
        #expect(fixture.adultFiles() == ["adult.sqlite"])
        #expect(await fixture.store.adultLibraryIsClosed)
    }

    @Test("turning on: a file that cannot be created leaves the partition off")
    func turnOnCannotCreate() async throws {
        let fixture = try GateFixture([.passed])
        defer { fixture.cleanUp() }
        // The libraries directory's place is taken by a file.
        try Data().write(to: fixture.root.appending(path: "Libraries"))

        #expect(await fixture.gate.turnOn(reason: "on") == .couldNotCreate)

        #expect(await fixture.gate.state == .off)
        #expect(!Preferences(fixture.defaults).adultPartitionIsOn)
    }

    // MARK: - Criterion 3: unlocking

    @Test("unlocking: an authentication that does not pass opens nothing", arguments: refusals)
    func unlockRefused(answer: AuthenticationAnswer) async throws {
        let fixture = try GateFixture([.passed, answer])
        defer { fixture.cleanUp() }
        #expect(await fixture.gate.turnOn(reason: "on") == .turnedOn)

        let result = await fixture.gate.unlock(reason: "Unlock")

        #expect(result.summary == "refused(notAuthenticated(\(answer)))")
        #expect(await fixture.gate.state == .locked)
        #expect(await fixture.store.adultLibraryIsClosed)
        #expect(fixture.authenticator.reasons == ["on", "Unlock"])
    }

    @Test("unlocking: a passed authentication gives out the adult library, and each unlock authenticates anew")
    func unlockPassed() async throws {
        let fixture = try GateFixture()
        defer { fixture.cleanUp() }
        let normal = try await fixture.store.openNormal()
        _ = try await normal.createCategory(name: "Normal only", icon: .globe)

        let adult = try await fixture.turnOnAndUnlock()

        #expect(adult.partition == .adult)
        #expect(adult !== normal)
        #expect(await fixture.gate.state == .unlocked)
        #expect(try await adult.categories().isEmpty)
        #expect(!(await fixture.store.adultLibraryIsClosed))
        // A second unlock asks again: one success is not reused. With no
        // answer left the stub says "unavailable".
        let second = await fixture.gate.unlock(reason: "again")
        #expect(second.summary == "refused(notAuthenticated(unavailable))")
        #expect(fixture.authenticator.reasons == ["on", "unlock", "again"])
    }

    @Test("unlocking while the partition is off is refused without asking")
    func unlockWhileOff() async throws {
        let fixture = try GateFixture([.passed])
        defer { fixture.cleanUp() }

        #expect(await fixture.gate.unlock(reason: "unlock").summary == "refused(notAllowed)")
        #expect(await fixture.gate.authenticateForSettings(reason: "settings") == .refused(.notAllowed))
        #expect(await fixture.gate.turnOff(deletingData: true) == .refused(.notAllowed))
        #expect(await !fixture.gate.setLockTiming(.afterOneMinute))

        #expect(fixture.authenticator.reasons.isEmpty)
        #expect(fixture.adultFiles().isEmpty)
        #expect(await fixture.gate.lockTiming == .immediately)
    }

    @Test("failure table: on, and the file is missing — unlocking creates an empty library")
    func unlockCreatesAMissingFile() async throws {
        let fixture = try GateFixture()
        defer { fixture.cleanUp() }
        let adult = try await fixture.turnOnAndUnlock()
        _ = try await adult.createCategory(name: "Before", icon: .heart)
        await fixture.gate.lock()
        // The next launch, with the file gone.
        let next = fixture.relaunched([.passed])
        for name in fixture.adultFiles() {
            try FileManager.default.removeItem(at: fixture.directory.appending(path: name))
        }

        guard case .unlocked(let library) = await next.gate.unlock(reason: "unlock") else {
            Issue.record("not unlocked")
            return
        }

        #expect(try await library.categories().isEmpty)
        #expect(fixture.gate.adultLibraryFileExists)
    }

    @Test("a damaged adult library: unlocking says so and stays locked; deleting still works")
    func damagedLibrary() async throws {
        let fixture = try GateFixture([.passed, .passed, .passed, .passed])
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 8192).write(to: fixture.databaseURL)
        #expect(await fixture.gate.turnOn(reason: "on") == .turnedOn)

        let result = await fixture.gate.unlock(reason: "unlock")

        #expect(result.summary == "couldNotOpen(damaged)")
        #expect(await fixture.gate.state == .locked)
        #expect(await fixture.store.adultLibraryIsClosed)
        // Delete opens nothing, so it works on the damaged file.
        #expect(await fixture.gate.turnOff(deletingData: true) == .turnedOff)
        #expect(fixture.adultFiles().isEmpty)
        #expect(await fixture.gate.state == .off)
        // Turning on afterwards gives an empty partition.
        #expect(await fixture.gate.turnOn(reason: "on") == .turnedOn)
        let library = try await fixture.unlock()
        #expect(try await library.categories().isEmpty)
    }

    // MARK: - Criterion 7: locking closes the library

    @Test("criterion 7: a lock closes the pool although the library is still held; the next unlock is a new pool with the data")
    func lockCloses() async throws {
        let fixture = try GateFixture()
        defer { fixture.cleanUp() }
        let held = try await fixture.turnOnAndUnlock()
        _ = try await held.createCategory(name: "Kept", icon: .heart)

        await fixture.gate.lock()

        #expect(await fixture.gate.state == .locked)
        // Closed at once, although this test still holds the object, as
        // UIKit holds the views' models after a lock.
        #expect(await fixture.gate.adultLibraryIsClosed)
        #expect(held.isClosed)
        #expect(!(await fixture.gate.adultLibraryObjectIsReleased))
        // The next unlock opens the file anew; the old object stays closed.
        fixture.authenticator.add(.passed)
        let again = try await fixture.unlock()
        #expect(again !== held)
        #expect(held.isClosed)
        #expect(try await again.categories().map(\.name) == ["Kept"])
        #expect(!(await fixture.gate.adultLibraryIsClosed))
        await fixture.gate.lock()
        #expect(again.isClosed)
        #expect(await fixture.gate.adultLibraryIsClosed)
    }

    @Test("a reference kept across a lock fails quietly: the library's own error, nothing written, nothing created")
    func keptReferenceFailsQuietly() async throws {
        let fixture = try GateFixture()
        defer { fixture.cleanUp() }
        let kept = try await fixture.turnOnAndUnlock()
        let category = try await kept.createCategory(name: "Kept", icon: .heart)
        try await kept.pool.writeWithoutTransaction { db in _ = try db.checkpoint(.truncate) }
        await fixture.gate.lock()
        let filesBefore = fixture.adultFiles()
        let bytesBefore = try Data(contentsOf: fixture.databaseURL)

        // Everything a stopped workspace's model might still ask of it.
        await #expect(throws: LibraryError.self) { try await kept.categories() }
        await #expect(throws: LibraryError.self) { try await kept.categorySummaries() }
        await #expect(throws: LibraryError.self) { try await kept.sourceSummaries() }
        await #expect(throws: LibraryError.self) { try await kept.createCategory(name: "Late", icon: .heart) }
        await #expect(throws: LibraryError.self) { try await kept.renameCategory(category.id, to: "Renamed") }
        await #expect(throws: LibraryError.self) { try await kept.lastRefreshAt() }
        do {
            _ = try await kept.categories()
        } catch let error as LibraryError {
            // A storage error with SQLite's own words: no row, no name.
            guard case .storage(let text) = error else {
                Issue.record("\(error)")
                return
            }
            #expect(!text.contains("Kept"), "the error carries content: \(text)")
        }

        #expect(fixture.adultFiles() == filesBefore)
        #expect(try Data(contentsOf: fixture.databaseURL) == bytesBefore)
        #expect(await fixture.gate.adultLibraryIsClosed)
        // And the data is as it was for the next unlock.
        fixture.authenticator.add(.passed)
        let again = try await fixture.unlock()
        #expect(try await again.categories().map(\.name) == ["Kept"])
    }

    @Test("criterion 7: a lock while a task writes waits for the write in flight; the task's later writes fail and nothing is half written")
    func lockDuringUse() async throws {
        let fixture = try GateFixture()
        defer { fixture.cleanUp() }
        let adult = try await fixture.turnOnAndUnlock()
        // A task that writes across the lock, as a save or a refresh does.
        let running = Task { [adult] () -> Int in
            var written = 0
            for index in 0..<200 {
                do {
                    _ = try await adult.createCategory(name: "Category \(index)", icon: .heart)
                    written += 1
                } catch {
                    break
                }
            }
            return written
        }
        try await Task.sleep(for: .milliseconds(20))

        await fixture.gate.lock()

        #expect(await fixture.gate.state == .locked)
        #expect(await fixture.gate.adultLibraryIsClosed)
        let written = await running.value
        // Every write that reported success is in the file, and no other.
        fixture.authenticator.add(.passed)
        let again = try await fixture.unlock()
        #expect(try await again.categories().count == written)
    }

    // MARK: - Criterion 14: one operation at a time; an unlock discarded

    @Test("criterion 14: an operation requested while another runs does nothing")
    func oneOperationAtATime() async throws {
        let fixture = try GateFixture([.passed])
        defer { fixture.cleanUp() }
        #expect(await fixture.gate.turnOn(reason: "on") == .turnedOn)
        fixture.authenticator.add(.passed)
        fixture.authenticator.hold()
        let gate = fixture.gate
        let unlocking = Task { await gate.unlock(reason: "first").summary }
        await fixture.authenticator.waitForRequests(2)

        #expect(await gate.unlock(reason: "second").summary == "refused(busy)")
        #expect(await gate.authenticateForSettings(reason: "settings") == .refused(.busy))
        #expect(await gate.turnOff(deletingData: true) == .refused(.busy))
        #expect(await gate.turnOff(deletingData: false) == .refused(.busy))
        #expect(await !gate.setLockTiming(.afterFiveMinutes))

        // Nothing of them happened: no further request, the file and the
        // settings as they were.
        #expect(fixture.authenticator.reasons == ["on", "first"])
        #expect(await gate.state == .locked)
        #expect(fixture.gate.adultLibraryFileExists)
        #expect(await gate.lockTiming == .immediately)
        fixture.authenticator.release()
        #expect(await unlocking.value == "unlocked")
        #expect(await gate.state == .unlocked)
        // And the gate is free again.
        #expect(await gate.setLockTiming(.afterFiveMinutes))
    }

    @Test("criterion 14: turning on twice at once authenticates once")
    func turnOnTwiceAtOnce() async throws {
        let fixture = try GateFixture([.passed, .passed])
        defer { fixture.cleanUp() }
        fixture.authenticator.hold()
        let gate = fixture.gate
        let first = Task { await gate.turnOn(reason: "first") }
        await fixture.authenticator.waitForRequests(1)

        #expect(await gate.turnOn(reason: "second") == .refused(.busy))

        fixture.authenticator.release()
        #expect(await first.value == .turnedOn)
        #expect(fixture.authenticator.reasons == ["first"])
    }

    @Test("criterion 14: an unlock during which the gate was locked is discarded")
    func unlockDiscardedByALock() async throws {
        let fixture = try GateFixture([.passed, .passed])
        defer { fixture.cleanUp() }
        #expect(await fixture.gate.turnOn(reason: "on") == .turnedOn)
        fixture.authenticator.hold()
        let gate = fixture.gate
        let unlocking = Task { await gate.unlock(reason: "unlock").summary }
        await fixture.authenticator.waitForRequests(2)

        // The scene entered the background while the prompt was shown.
        await gate.lock()
        fixture.authenticator.release()

        #expect(await unlocking.value == "discarded")
        #expect(await gate.state == .locked)
        #expect(await fixture.store.adultLibraryIsClosed)
        #expect(await fixture.store.adultLibraryObjectIsReleased)
    }

    @Test("an unlock and a lock at the same moment: locked means closed, unlocked means open, in every order")
    func unlockRacingALock() async throws {
        for round in 0..<300 {
            let fixture = try GateFixture([.passed, .passed])
            defer { fixture.cleanUp() }
            #expect(await fixture.gate.turnOn(reason: "on") == .turnedOn)
            let gate = fixture.gate
            let unlocking = Task { await gate.unlock(reason: "unlock").summary }
            let locking = Task { await gate.lock() }
            let result = await unlocking.value
            await locking.value

            switch await gate.state {
            case .locked:
                #expect(await gate.adultLibraryIsClosed, "round \(round): locked with an open pool after \(result)")
            case .unlocked:
                #expect(result == "unlocked", "round \(round)")
                #expect(!(await gate.adultLibraryIsClosed), "round \(round): unlocked with a closed pool")
            case .off, .unavailable:
                Issue.record("round \(round): \(await gate.state)")
            }
        }
    }

    // MARK: - Criterion 10: authenticating for the settings

    @Test("criterion 10: authenticating for the settings unlocks nothing")
    func authenticateForSettings() async throws {
        let fixture = try GateFixture([.passed, .passed, .cancelled])
        defer { fixture.cleanUp() }
        #expect(await fixture.gate.turnOn(reason: "on") == .turnedOn)

        #expect(await fixture.gate.authenticateForSettings(reason: "Open the settings") == .passed)
        #expect(await fixture.gate.state == .locked)
        #expect(await fixture.store.adultLibraryIsClosed)

        #expect(await fixture.gate.authenticateForSettings(reason: "Open the settings") == .refused(.notAuthenticated(.cancelled)))
        #expect(await fixture.gate.state == .locked)
        #expect(fixture.authenticator.reasons == ["on", "Open the settings", "Open the settings"])
    }

    // MARK: - Criterion 8: the lock timing is kept

    @Test("criterion 8: the lock timing survives a relaunch, and a relaunch starts locked")
    func lockTimingSurvives() async throws {
        let fixture = try GateFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.turnOnAndUnlock()
        #expect(await fixture.gate.setLockTiming(.afterOneMinute))
        #expect(await fixture.gate.state == .unlocked)

        // The app is ended while unlocked: nothing about that is stored.
        let next = fixture.relaunched()

        #expect(await next.gate.state == .locked)
        #expect(await next.gate.lockTiming == .afterOneMinute)
        #expect(await next.store.adultLibraryIsClosed)
        #expect(next.authenticator.reasons.isEmpty)
    }

    // MARK: - Criterion 11: keep data hidden

    @Test("criterion 11: Keep Data Hidden turns the partition off and keeps the database, the keys and the images")
    func keepDataHidden() async throws {
        let fixture = try GateFixture()
        defer { fixture.cleanUp() }
        let adult = try await fixture.turnOnAndUnlock()
        _ = try await adult.createCategory(name: "Hidden", icon: .heart)
        let reference = try fixture.keys.add(#require(try? SecretKey.validate("sk-adult-key-1234").get()))
        #expect(await adult.imageCache.store(Data([1, 2, 3]), for: "https://example.invalid/a.png"))
        _ = consume adult

        #expect(await fixture.gate.turnOff(deletingData: false) == .turnedOff)

        #expect(await fixture.gate.state == .off)
        #expect(!Preferences(fixture.defaults).adultPartitionIsOn)
        #expect(fixture.gate.adultLibraryFileExists)
        #expect(fixture.keys.references == [reference])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.adultCacheDirectory.path).count == 1)
        #expect(await fixture.store.adultLibraryIsClosed)
        // While off, nothing is reachable.
        fixture.authenticator.add(.passed)
        #expect(await fixture.gate.unlock(reason: "unlock").summary == "refused(notAllowed)")
        // Turning on again shows the data again.
        #expect(await fixture.gate.turnOn(reason: "on") == .turnedOn)
        fixture.authenticator.add(.passed)
        let again = try await fixture.unlock()
        #expect(try await again.categories().map(\.name) == ["Hidden"])
    }

    // MARK: - Criterion 12: delete

    /// An unlocked partition with a category, a key and a cached image, and
    /// a normal library with the same.
    private func filled(_ fixture: GateFixture) async throws -> (adult: Library, normal: Library) {
        let normal = try await fixture.store.openNormal()
        _ = try await normal.createCategory(name: "Normal", icon: .globe)
        #expect(await normal.imageCache.store(Data([9]), for: "https://example.invalid/n.png"))
        let adult = try await fixture.turnOnAndUnlock()
        _ = try await adult.createCategory(name: "Adult", icon: .heart)
        _ = try fixture.keys.add(#require(try? SecretKey.validate("sk-adult-key-1234").get()))
        #expect(await adult.imageCache.store(Data([1, 2, 3]), for: "https://example.invalid/a.png"))
        return (adult, normal)
    }

    @Test("criterion 12: Delete removes the database with its side files, the keys and the image cache, and nothing of the normal partition")
    func deleteRemovesEverything() async throws {
        let fixture = try GateFixture()
        defer { fixture.cleanUp() }
        let (adult, normal) = try await filled(fixture)
        #expect(Set(fixture.adultFiles()).isSuperset(of: ["adult.sqlite", "adult.sqlite-wal"]))
        _ = consume adult

        #expect(await fixture.gate.turnOff(deletingData: true) == .turnedOff)

        #expect(await fixture.gate.state == .off)
        #expect(fixture.adultFiles().isEmpty)
        #expect(fixture.keys.references.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.adultCacheDirectory.path))
        #expect(await fixture.store.adultLibraryIsClosed)
        // The normal partition is untouched.
        #expect(try await normal.categories().map(\.name) == ["Normal"])
        #expect(await normal.imageCache.size() == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.directory.appending(path: "normal.sqlite").path))
        // Turning on afterwards shows an empty partition.
        fixture.authenticator.add(.passed, .passed)
        #expect(await fixture.gate.turnOn(reason: "on") == .turnedOn)
        let fresh = try await fixture.unlock()
        #expect(try await fresh.categories().isEmpty)
        #expect(await fresh.imageCache.size() == 0)
    }

    @Test("criterion 12: Delete while a reference to the library is still held closes it: the reference fails and creates nothing")
    func deleteWithAHeldReference() async throws {
        let fixture = try GateFixture()
        defer { fixture.cleanUp() }
        let (held, _) = try await filled(fixture)

        #expect(await fixture.gate.turnOff(deletingData: true) == .turnedOff)

        #expect(fixture.adultFiles().isEmpty)
        // The store forgot the object although it is still alive here.
        #expect(await fixture.store.adultLibraryIsClosed)
        await #expect(throws: LibraryError.self) { try await held.categories() }
        await #expect(throws: LibraryError.self) { try await held.createCategory(name: "Late", icon: .heart) }
        #expect(fixture.adultFiles().isEmpty)
        // A new partition does not get the closed object.
        fixture.authenticator.add(.passed, .passed)
        #expect(await fixture.gate.turnOn(reason: "on") == .turnedOn)
        let fresh = try await fixture.unlock()
        #expect(fresh !== held)
        #expect(try await fresh.categories().isEmpty)
    }

    @Test("criterion 12: Delete with parts already missing is not a failure")
    func deleteWithMissingParts() async throws {
        let fixture = try GateFixture([.passed])
        defer { fixture.cleanUp() }
        #expect(await fixture.gate.turnOn(reason: "on") == .turnedOn)
        // No cache directory, no key, and the database removed by hand.
        for name in fixture.adultFiles() {
            try FileManager.default.removeItem(at: fixture.directory.appending(path: name))
        }

        #expect(await fixture.gate.turnOff(deletingData: true) == .turnedOff)

        #expect(await fixture.gate.state == .off)
        #expect(fixture.adultFiles().isEmpty)
    }

    @Test("criterion 12: keys that cannot be removed leave the partition on, and Delete can be tried again")
    func deleteFailsOnKeys() async throws {
        let fixture = try GateFixture()
        defer { fixture.cleanUp() }
        let (adult, _) = try await filled(fixture)
        _ = consume adult
        fixture.keys.refuseRemovals = true

        #expect(await fixture.gate.turnOff(deletingData: true) == .couldNotDelete)

        #expect(await fixture.gate.state == .locked)
        #expect(Preferences(fixture.defaults).adultPartitionIsOn)
        #expect(fixture.keys.references.count == 1)
        // The image cache comes last, so it is still there.
        #expect(FileManager.default.fileExists(atPath: fixture.adultCacheDirectory.path))
        // What was removed stays removed; a later unlock creates an empty file.
        #expect(fixture.adultFiles().isEmpty)
        fixture.keys.refuseRemovals = false
        #expect(await fixture.gate.turnOff(deletingData: true) == .turnedOff)
        #expect(fixture.keys.references.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.adultCacheDirectory.path))
        #expect(await fixture.gate.state == .off)
    }

    @Test("criterion 12: a database file that cannot be removed leaves the partition on")
    func deleteFailsOnTheFile() async throws {
        let fixture = try GateFixture()
        defer { fixture.cleanUp() }
        let (adult, _) = try await filled(fixture)
        _ = consume adult
        // Nothing can be removed from a directory that cannot be written.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.directory.path)

        #expect(await fixture.gate.turnOff(deletingData: true) == .couldNotDelete)

        #expect(await fixture.gate.state == .locked)
        #expect(fixture.gate.adultLibraryFileExists)
        #expect(fixture.keys.references.count == 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.directory.path)
        #expect(await fixture.gate.turnOff(deletingData: true) == .turnedOff)
        #expect(fixture.adultFiles().isEmpty)
    }

    @Test("criterion 12: an image cache that cannot be removed leaves the partition on")
    func deleteFailsOnTheCache() async throws {
        let fixture = try GateFixture()
        defer { fixture.cleanUp() }
        let (adult, _) = try await filled(fixture)
        _ = consume adult
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.cacheRoot.path)

        #expect(await fixture.gate.turnOff(deletingData: true) == .couldNotDelete)

        #expect(await fixture.gate.state == .locked)
        #expect(FileManager.default.fileExists(atPath: fixture.adultCacheDirectory.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.cacheRoot.path)
        #expect(await fixture.gate.turnOff(deletingData: true) == .turnedOff)
        #expect(!FileManager.default.fileExists(atPath: fixture.adultCacheDirectory.path))
    }

    // MARK: - Criterion 13: the feature switch

    @Test("criterion 13: with the feature switch off the gate is unavailable and opens nothing, whatever is stored")
    func featureSwitchOff() async throws {
        let fixture = try GateFixture()
        defer { fixture.cleanUp() }
        // The partition was on, with data, in a launch with the switch on.
        let adult = try await fixture.turnOnAndUnlock()
        _ = try await adult.createCategory(name: "Adult", icon: .heart)
        try await adult.pool.writeWithoutTransaction { db in _ = try db.checkpoint(.truncate) }
        _ = consume adult
        await fixture.gate.lock()
        #expect(await fixture.store.adultLibraryIsClosed)
        let before = try Data(contentsOf: fixture.databaseURL)
        let filesBefore = fixture.adultFiles()

        let off = fixture.relaunched([.passed, .passed, .passed, .passed], isEnabled: false)

        #expect(await off.gate.state == .unavailable)
        #expect(await off.gate.turnOn(reason: "on") == .refused(.notAllowed))
        #expect(await off.gate.unlock(reason: "unlock").summary == "refused(notAllowed)")
        #expect(await off.gate.authenticateForSettings(reason: "settings") == .refused(.notAllowed))
        #expect(await off.gate.turnOff(deletingData: true) == .refused(.notAllowed))
        #expect(await off.gate.turnOff(deletingData: false) == .refused(.notAllowed))
        #expect(await !off.gate.setLockTiming(.afterFiveMinutes))
        await off.gate.lock()
        // Nobody was asked, nothing was opened, written or removed.
        #expect(off.authenticator.reasons.isEmpty)
        #expect(await off.store.adultLibraryIsClosed)
        #expect(try Data(contentsOf: fixture.databaseURL) == before)
        #expect(fixture.adultFiles() == filesBefore)
        #expect(Preferences(fixture.defaults).adultPartitionIsOn)
        #expect(Preferences(fixture.defaults).lockTiming == .immediately)
    }

    @Test("criterion 13: with the feature switch off and nothing stored, no adult file is created")
    func featureSwitchOffOnAFreshInstall() async throws {
        let fixture = try GateFixture([.passed, .passed], isEnabled: false)
        defer { fixture.cleanUp() }
        _ = try await fixture.store.openNormal()

        #expect(await fixture.gate.state == .unavailable)
        #expect(await fixture.gate.turnOn(reason: "on") == .refused(.notAllowed))
        #expect(await fixture.gate.unlock(reason: "unlock").summary == "refused(notAllowed)")

        #expect(fixture.adultFiles().isEmpty)
        #expect(!Preferences(fixture.defaults).adultPartitionIsOn)
        #expect(fixture.authenticator.reasons.isEmpty)
    }

    @Test("the build's feature switch is on")
    func buildFeature() {
        #expect(BuildFeatures.adultPartition)
    }

    // MARK: - Invariant: nothing about content in the preferences

    @Test("the preferences store holds the two device settings and nothing about the partition's content")
    func preferencesHoldNoContent() async throws {
        let fixture = try GateFixture()
        defer { fixture.cleanUp() }
        let adult = try await fixture.turnOnAndUnlock()
        let category = try await adult.createCategory(name: "Secret category", icon: .heart)
        try await adult.insert(Sample.source(in: category.id, url: "https://secret.example.invalid/feed", at: Date()))
        #expect(await fixture.gate.setLockTiming(.afterFiveMinutes))
        await fixture.gate.lock()

        let stored = try #require(fixture.defaults.persistentDomain(forName: fixture.suiteName))

        #expect(Set(stored.keys) == ["adult_partition_on", "adult_lock_timing"])
        #expect(stored["adult_partition_on"] as? Bool == true)
        #expect(stored["adult_lock_timing"] as? Int == 300)
    }
}

/// RD18 decision 2: what LocalAuthentication's errors become. The mapping
/// is tested by itself; no test asks LocalAuthentication for anything.
@Suite("System device authenticator")
struct SystemDeviceAuthenticatorTests {
    private func error(_ code: Int, domain: String = "com.apple.LocalAuthentication") -> NSError {
        NSError(domain: domain, code: code)
    }

    @Test("passcode not set is unavailable, the owner's cancel is cancelled, the system's and the app's are interrupted, the rest failed")
    func mapping() {
        // LAError: authenticationFailed -1, userCancel -2, userFallback -3,
        // systemCancel -4, passcodeNotSet -5, biometryNotAvailable -6,
        // biometryNotEnrolled -7, biometryLockout -8, appCancel -9,
        // invalidContext -10, notInteractive -1004.
        let expected: [Int: AuthenticationAnswer] = [
            -1: .failed, -2: .cancelled, -3: .failed, -4: .interrupted, -5: .unavailable, -6: .failed, -7: .failed,
            -8: .failed, -9: .interrupted, -10: .failed, -1004: .failed, 12345: .failed,
        ]
        for (code, answer) in expected {
            #expect(SystemDeviceAuthenticator.answer(forRefusal: error(code)) == answer, "\(code)")
        }
        #expect(SystemDeviceAuthenticator.answer(forRefusal: nil) == .failed)
        // The same number in another domain is not LocalAuthentication's.
        #expect(SystemDeviceAuthenticator.answer(forRefusal: error(-5, domain: "other")) == .failed)
        #expect(SystemDeviceAuthenticator.answer(forRefusal: error(-2, domain: "other")) == .failed)
    }
}
