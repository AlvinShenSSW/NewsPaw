import Foundation

/// The only way to the adult library (spec N09, section 6; RD18 decision
/// 2): device authentication stands in front of every way in, and the
/// feature switch in front of everything.
///
/// One operation runs at a time: a call made while another is running
/// answers `busy` and does nothing. `lock()` is the exception: it always
/// locks, and an unlock that was running when it was called is discarded.
/// A lock closes the adult library's connections; the next unlock opens
/// new ones, and the store never has two pools open on the file.
///
/// Its answers are closed enumerations. No text of a keychain or file error
/// reaches the interface: only "could not be opened", with the
/// `LibraryError`, and "could not be deleted".
public actor AdultGate {
    public enum State: Sendable, Hashable {
        /// The feature switch is off: nothing of the partition is reachable.
        case unavailable
        /// The partition is not turned on.
        case off
        /// Turned on, and no adult library is given out.
        case locked
        /// The adult library was given out by `unlock` and not locked since.
        case unlocked
    }

    /// Why an operation did nothing.
    public enum Refusal: Sendable, Hashable {
        /// Another operation is running.
        case busy
        /// The gate's state does not allow the operation: the feature
        /// switch is off, or the partition is not on (or, for turning on,
        /// already on).
        case notAllowed
        /// The authentication did not pass; never `.passed`.
        case notAuthenticated(AuthenticationAnswer)
    }

    public enum TurnOnResult: Sendable, Hashable {
        case turnedOn
        case refused(Refusal)
        /// The adult library's file could not be created; the partition
        /// stays off.
        case couldNotCreate
    }

    public enum UnlockResult: Sendable {
        case unlocked(Library)
        case refused(Refusal)
        /// A lock arrived while the unlock ran: nothing is given out.
        case discarded
        /// The authentication passed and the library could not be opened;
        /// the gate stays locked.
        case couldNotOpen(LibraryError)
    }

    public enum SettingsResult: Sendable, Hashable {
        case passed
        case refused(Refusal)
    }

    public enum TurnOffResult: Sendable, Hashable {
        case turnedOff
        case refused(Refusal)
        /// A file, the keys, the browser's data or the image cache could not
        /// be removed. The partition stays on, so that deleting can be tried
        /// again; what was removed stays removed.
        case couldNotDelete
    }

    private let store: LibraryStore
    private let authenticator: any DeviceAuthenticator
    private let preferences: Preferences
    private let keys: any KeyStore
    /// The adult browser's own website data store, removed with the rest
    /// of the partition's data (RD19 decision 5).
    private let browserData: any AdultBrowserData
    private let isEnabled: Bool
    private var isBusy = false
    private var isUnlocked = false
    /// Raised by every lock, so that an unlock running across one knows.
    private var locks = 0

    /// - Parameters:
    ///   - keys: the adult partition's key store; a store of another
    ///     partition is a programming error.
    ///   - browserData: the adult browser's website data store.
    ///   - isEnabled: the feature switch. The app passes
    ///     `BuildFeatures.adultPartition`; a debug build under the UI tests
    ///     may pass `false` for one launch.
    public init(
        store: LibraryStore, authenticator: any DeviceAuthenticator, preferences: Preferences, keys: any KeyStore,
        browserData: any AdultBrowserData, isEnabled: Bool = BuildFeatures.adultPartition
    ) {
        precondition(keys.partition == .adult, "a key store of another partition")
        self.store = store
        self.authenticator = authenticator
        self.preferences = preferences
        self.keys = keys
        self.browserData = browserData
        self.isEnabled = isEnabled
    }

    public var state: State {
        if !isEnabled {
            .unavailable
        } else if !preferences.adultPartitionIsOn {
            .off
        } else if isUnlocked {
            .unlocked
        } else {
            .locked
        }
    }

    /// When the partition locks after the app is left.
    public var lockTiming: LockTiming {
        preferences.lockTiming
    }

    // MARK: - Operations

    /// Turns the partition on: authenticates, creates the adult library's
    /// file when it is missing (an existing file is not opened) and stores
    /// "on". The partition stays locked.
    public func turnOn(reason: String) async -> TurnOnResult {
        guard state == .off else { return .refused(.notAllowed) }
        guard begin() else { return .refused(.busy) }
        defer { isBusy = false }
        let answer = await authenticator.authenticate(reason: reason)
        guard answer == .passed else { return .refused(.notAuthenticated(answer)) }
        do {
            try await store.createAdultLibraryFileIfMissing()
        } catch {
            return .couldNotCreate
        }
        preferences.adultPartitionIsOn = true
        return .turnedOn
    }

    /// Unlocks the partition: authenticates, then opens the adult library,
    /// creating its file when it is missing (turning on authorised that).
    public func unlock(reason: String) async -> UnlockResult {
        guard state == .locked || state == .unlocked else { return .refused(.notAllowed) }
        guard begin() else { return .refused(.busy) }
        defer { isBusy = false }
        let locksBefore = locks
        let answer = await authenticator.authenticate(reason: reason)
        guard answer == .passed else { return .refused(.notAuthenticated(answer)) }
        guard locks == locksBefore else { return .discarded }
        let library: Library
        do {
            library = try await store.createAdultLibrary()
        } catch {
            return .couldNotOpen(error as? LibraryError ?? .storage(String(describing: type(of: error))))
        }
        guard locks == locksBefore else {
            // Locked while the library was being opened: closed again.
            try? await store.closeAdultLibrary()
            return .discarded
        }
        isUnlocked = true
        return .unlocked(library)
    }

    /// Locks the partition: the store closes the adult library's
    /// connections and forgets the object. It waits for the one read and
    /// the one write in flight, with no time limit of its own; every later
    /// use of a reference that something still holds fails. Never fails,
    /// and is never refused: an unlock running now is discarded.
    public func lock() async {
        locks += 1
        isUnlocked = false
        // A pool that could not be closed stays the store's, and the next
        // unlock gets that same object: `adultLibraryIsClosed` says so.
        try? await store.closeAdultLibrary()
    }

    /// Authenticates for Settings › Adult Partition and changes nothing: it
    /// does not unlock the partition.
    public func authenticateForSettings(reason: String) async -> SettingsResult {
        guard state == .locked || state == .unlocked else { return .refused(.notAllowed) }
        guard begin() else { return .refused(.busy) }
        defer { isBusy = false }
        let answer = await authenticator.authenticate(reason: reason)
        return answer == .passed ? .passed : .refused(.notAuthenticated(answer))
    }

    /// Stores the lock timing.
    ///
    /// - Returns: whether it was stored: not while another operation runs,
    ///   and not while the partition is off or unavailable.
    @discardableResult
    public func setLockTiming(_ timing: LockTiming) -> Bool {
        guard state == .locked || state == .unlocked, !isBusy else { return false }
        preferences.lockTiming = timing
        return true
    }

    /// Turns the partition off. It is locked first. Keeping the data stores
    /// "off" and removes nothing. Deleting removes the database with its
    /// side files, every key of the adult key store, the adult browser's
    /// website data store (RD19 decision 5) and, last, the image cache
    /// directory, and only then stores "off"; it opens no library. A
    /// failure stops there and leaves the partition on.
    public func turnOff(deletingData: Bool) async -> TurnOffResult {
        guard state == .locked || state == .unlocked else { return .refused(.notAllowed) }
        guard begin() else { return .refused(.busy) }
        defer { isBusy = false }
        await lock()
        if deletingData {
            do {
                try await store.deleteAdultLibraryFiles()
                try keys.removeAll()
                try await browserData.removeStore()
                try store.deleteAdultImageCache()
            } catch {
                return .couldNotDelete
            }
        }
        preferences.adultPartitionIsOn = false
        return .turnedOff
    }

    /// Takes the gate for one operation; false while another runs.
    private func begin() -> Bool {
        if isBusy {
            return false
        }
        isBusy = true
        return true
    }

    // MARK: - Reports

    /// Whether the adult library's file exists. It opens and creates
    /// nothing; for the debug element of the UI tests (RD18 criterion 1).
    public nonisolated var adultLibraryFileExists: Bool {
        store.adultLibraryExists
    }

    /// Whether no pool is open on the adult library's file (RD18 criterion
    /// 7): true after every lock, whatever still holds the object; for the
    /// debug element of the UI tests.
    public var adultLibraryIsClosed: Bool {
        get async { await store.adultLibraryIsClosed }
    }

    /// Whether the adult library object last given out is gone from
    /// memory; for the debug element of the UI tests.
    public var adultLibraryObjectIsReleased: Bool {
        get async { await store.adultLibraryObjectIsReleased }
    }
}
