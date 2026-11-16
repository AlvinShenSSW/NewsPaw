import CryptoKit
import Foundation
import WebKit

/// The website data store of each partition's embedded browser (spec N09;
/// RD19 decision 4): the one place that makes a store for a partition. The
/// normal partition's browser uses the system's default store; the adult
/// partition's uses a persistent store of its own, identified by a fixed
/// identifier, so that its cookies, sign-ins and caches are never the normal
/// partition's and survive a lock until Clear Browsing Data or Delete.
///
/// RD12's page extractor makes its own non-persistent stores; no other file
/// makes a website data store (a package scan guards it).
@MainActor
public enum BrowserDataStores {
    /// The adult partition's own store. Fixed for good: a new identifier
    /// would leave the old store's data on the device, out of Clear's reach.
    public static let adultIdentifier = UUID(uuidString: "6A3C1E52-9B47-4F0D-8E21-3D5B7C9A0F14")!

    /// The store of `partition`'s browser: the default store for the normal
    /// partition, the adult partition's own persistent store for the adult.
    public static func store(for partition: Partition) -> WKWebsiteDataStore {
        switch partition {
        case .normal: .default()
        case .adult: WKWebsiteDataStore(forIdentifier: adultIdentifier)
        }
    }

    #if DEBUG
    // MARK: - Under the UI tests (debug builds only)

    /// The adult store's identifier under the UI-test library directory
    /// named `directoryName`: the first 16 bytes of SHA-256 of
    /// `"<name>/adult"`, so that each test's launch has a persistent adult
    /// store of its own and never touches the real one.
    public static func uiTestAdultIdentifier(directoryName: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data("\(directoryName)/adult".utf8)))
        var bytes = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &bytes) { buffer in
            for index in 0..<16 {
                buffer[index] = digest[index]
            }
        }
        // Never the real identifier, and never the all-zero one WebKit
        // refuses (both are as likely as a collision of SHA-256).
        return UUID(uuid: bytes)
    }

    /// The store of `partition`'s browser under the UI-test library
    /// directory named `directoryName`: a non-persistent store for the
    /// normal partition (RD10; it lasts the process), and the adult
    /// partition's persistent store of that directory.
    public static func uiTestStore(for partition: Partition, directoryName: String) -> WKWebsiteDataStore {
        switch partition {
        case .normal: .nonPersistent()
        case .adult: WKWebsiteDataStore(forIdentifier: uiTestAdultIdentifier(directoryName: directoryName))
        }
    }

    /// Removes every identified store but `kept` and the real adult
    /// store's: the UI tests' stores of earlier launches. A store that
    /// cannot be removed now is left for a later launch.
    public static func removeUITestStores(keeping kept: UUID) async {
        // WebKit sets itself up with its first store: asked for the
        // identifiers before that, a new process crashed (iOS 27.0
        // simulator, `fetchAllDataStoreIdentifiers` on a null run loop).
        _ = WKWebsiteDataStore(forIdentifier: kept)
        for identifier in await WKWebsiteDataStore.allDataStoreIdentifiers
        where identifier != kept && identifier != adultIdentifier {
            try? await WKWebsiteDataStore.remove(forIdentifier: identifier)
        }
    }
    #endif
}

/// Why the adult browser's store could not be removed.
public enum AdultBrowserDataError: Error, Sendable, Hashable {
    case couldNotRemove
}

/// The adult partition's browser data (RD19 decision 5): Clear Browsing
/// Data, and its removal when the partition's data is deleted.
public protocol AdultBrowserData: Sendable {
    /// Removes every kind of website data from the adult store.
    func clear() async
    /// Removes the adult store: its data first, then the store itself. A
    /// store WebKit reports as in use, after its data were removed, counts
    /// as removed (assumption A2).
    ///
    /// - Throws: `AdultBrowserDataError.couldNotRemove` for any other
    ///   failure.
    func removeStore() async throws
}

/// The adult browser's data in WebKit: the identified store of
/// `identifier`.
public struct WebKitAdultBrowserData: AdultBrowserData {
    public let identifier: UUID

    public init(identifier: UUID) {
        self.identifier = identifier
    }

    public func clear() async {
        await Self.clear(identifier)
    }

    public func removeStore() async throws {
        await clear()
        try await Self.remove(identifier)
    }

    @MainActor
    private static func clear(_ identifier: UUID) async {
        let store = WKWebsiteDataStore(forIdentifier: identifier)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    @MainActor
    private static func remove(_ identifier: UUID) async throws {
        do {
            try await WKWebsiteDataStore.remove(forIdentifier: identifier)
        } catch {
            guard isInUse(error) else { throw AdultBrowserDataError.couldNotRemove }
        }
    }

    /// Whether `error` is WebKit's refusal of a store that a web view still
    /// uses ("Data store is in use"): the adult browser model that UIKit
    /// keeps after a lock (RD18 assumption A4) holds the store object.
    static func isInUse(_ error: any Error) -> Bool {
        (error as NSError).localizedDescription.localizedCaseInsensitiveContains("in use")
    }
}
