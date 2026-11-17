import Foundation
import Synchronization

/// One partition's library and key store, which an import may write (RD20
/// decision 5). They are paired by the precondition `LibraryModels.init`
/// has: a key store of another partition is a programming error.
public struct ConfigurationTarget: Sendable {
    public let library: Library
    let keys: any KeyStore

    public init(library: Library, keys: any KeyStore) {
        precondition(keys.partition == library.partition, "a key store of another partition")
        self.library = library
        self.keys = keys
    }
}

/// One confirmed import (RD20 decision 5): the document without its adult
/// part, the normal target, and — only when the document has an adult part
/// and an adult target is given — the two together in a box that the write
/// task empties once its adult steps have ended, so that the task holds
/// nothing of the adult partition afterwards. A partition the file contains
/// that has no target here is dropped here and never seen again.
public final class ConfigurationImport: Sendable {
    let document: ConfigurationDocument
    let normal: ConfigurationTarget
    private let adult: Mutex<(target: ConfigurationTarget, part: ConfigurationPartition)?>
    /// Whether the import writes the adult partition.
    public let includesAdult: Bool

    public init(document: ConfigurationDocument, normal: ConfigurationTarget, adult: ConfigurationTarget?) {
        precondition(normal.library.partition == .normal, "a library of another partition")
        precondition(adult.map { $0.library.partition == .adult } ?? true, "a library of another partition")
        self.document = document.withoutAdult
        self.normal = normal
        if let part = document.adult, let adult {
            self.adult = Mutex((adult, part))
            includesAdult = true
        } else {
            self.adult = Mutex(nil)
            includesAdult = false
        }
    }

    /// The adult target and part, once; `nil` afterwards.
    func takeAdult() -> (target: ConfigurationTarget, part: ConfigurationPartition)? {
        adult.withLock { content in
            defer { content = nil }
            return content
        }
    }

    /// Whether the import holds nothing of the adult partition.
    public var holdsNoAdultPart: Bool {
        adult.withLock { $0 == nil }
    }
}

/// Why an export did not produce a file.
public enum ConfigurationExportError: Error, Sendable, Hashable {
    /// More than 500 categories or 5,000 sources, or more than 5 MB: a file
    /// this app would refuse to import.
    case tooLarge
    /// A library could not be read, or the file would not be read back.
    case failed
}

/// One partition of a preview: what Merge would do and what Replace would
/// do.
public struct ConfigurationPartitionPreview: Sendable {
    public let merge: ConfigurationPlan
    public let replace: ConfigurationPlan

    public var partition: Partition {
        merge.partition
    }
}

/// What the preview shows (ux S11; RD20 decision 8).
public struct ConfigurationPreview: Sendable {
    /// The normal partition first.
    public let partitions: [ConfigurationPartitionPreview]
    /// The global settings the file has with another value.
    public let settingDifferences: [ConfigurationSettingDifference]

    /// Whether Merge would write anything.
    public var mergeWritesSomething: Bool {
        partitions.contains { $0.merge.writesSomething }
    }
}

/// How one partition of an import ended.
public enum ConfigurationPartitionOutcome: Sendable {
    /// Written, as the plan says; `keysNeeded` slots have no usable key.
    case imported(ConfigurationPlan, keysNeeded: Int)
    /// Its transaction failed; nothing of it was written.
    case failed
    /// Not tried, because an earlier step failed.
    case notTried
}

/// What an import did (decision 5, step 5).
public struct ConfigurationImportResult: Sendable {
    public let mode: ConfigurationImportMode
    /// `nil` when the import had no adult part.
    public let adult: ConfigurationPartitionOutcome?
    public let normal: ConfigurationPartitionOutcome
    /// Whether the global settings were written (Replace, after the normal
    /// partition committed).
    public let settingsReplaced: Bool

    /// Whether nothing at all was written.
    public var changedNothing: Bool {
        if case .imported = normal { return false }
        if case .imported? = adult { return false }
        return true
    }

    /// The adult partition was imported and the normal one was not.
    public var isPartial: Bool {
        guard case .imported? = adult else { return false }
        if case .imported = normal { return false }
        return true
    }
}

/// Export, preview and import of the configuration file (spec N10; RD20
/// decisions 5 and 6). None of them makes a request, none reads a key, and
/// nothing from the file is ever written to a key store: an import only
/// removes the items of references it cleared.
public enum ConfigurationTransfer {
    /// Test hooks: run inside each partition's transaction before its
    /// commit.
    struct Hooks: Sendable {
        var insideAdultTransaction: (@Sendable () throws -> Void)?
        var insideNormalTransaction: (@Sendable () throws -> Void)?
    }

    // MARK: - Export (decision 6)

    /// The file of the normal library, of the adult library when given,
    /// and of the global settings. Reads each library once and never a key
    /// store.
    ///
    /// - Throws: `ConfigurationExportError`.
    public static func export(
        normal: Library, adult: Library?, preferences: Preferences, appVersion: String, now: Date
    ) async throws -> Data {
        precondition(normal.partition == .normal && (adult?.partition ?? .adult) == .adult, "a library of another partition")
        let normalSnapshot: ConfigurationSnapshot
        let adultSnapshot: ConfigurationSnapshot?
        do {
            normalSnapshot = try await normal.configurationExportSnapshot()
            adultSnapshot = try await adult?.configurationExportSnapshot()
        } catch {
            throw ConfigurationExportError.failed
        }
        let categories = normalSnapshot.categories.count + (adultSnapshot?.categories.count ?? 0)
        let sources = normalSnapshot.sources.count + (adultSnapshot?.sources.count ?? 0)
        guard categories <= ConfigurationFile.maximumCategories, sources <= ConfigurationFile.maximumSources else {
            throw ConfigurationExportError.tooLarge
        }
        let data: Data
        do {
            data = try ConfigurationWriter.data(
                settings: .inEffect(preferences), normal: normalSnapshot, adult: adultSnapshot, appVersion: appVersion, exportedAt: now
            )
        } catch {
            throw ConfigurationExportError.failed
        }
        // A file this app would refuse to import is not written.
        switch ConfigurationFile.read(data) {
        case .success: return data
        case .failure(.tooLarge), .failure(.tooManyCategories), .failure(.tooManySources): throw ConfigurationExportError.tooLarge
        case .failure: throw ConfigurationExportError.failed
        }
    }

    // MARK: - Preview

    /// Plans the document against the libraries given: the normal one, and
    /// the adult one when the document has an adult part and the adult
    /// library is given. Reads each library once; writes nothing.
    public static func preview(
        _ document: ConfigurationDocument, normal: Library, adult: Library?, preferences: Preferences
    ) async throws -> ConfigurationPreview {
        precondition(normal.partition == .normal && (adult?.partition ?? .adult) == .adult, "a library of another partition")
        let now = normal.now()
        var partitions: [ConfigurationPartitionPreview] = []
        var compared: [(ConfigurationPartition, Library)] = [(document.normal, normal)]
        if let part = document.adult, let adult {
            compared.append((part, adult))
        }
        for (part, library) in compared {
            let snapshot = try await library.configurationSnapshot()
            partitions.append(ConfigurationPartitionPreview(
                merge: ConfigurationPlan.make(part, snapshot: snapshot, mode: .merge, now: now),
                replace: ConfigurationPlan.make(part, snapshot: snapshot, mode: .replace, now: now)
            ))
        }
        return ConfigurationPreview(
            partitions: partitions, settingDifferences: document.settings.differences(from: .inEffect(preferences))
        )
    }

    // MARK: - Import (decision 5)

    /// Carries out `job` (decision 5): the adult transaction, when the job
    /// has an adult part, then the normal one, then the global settings
    /// (Replace), then the normal keychain removals, then `completion`,
    /// once.
    ///
    /// - Returns: what `completion` was given.
    @discardableResult
    public static func run(
        _ job: ConfigurationImport, mode: ConfigurationImportMode, preferences: Preferences,
        completion: @Sendable (ConfigurationImportResult) async -> Void
    ) async -> ConfigurationImportResult {
        await run(job, mode: mode, preferences: preferences, hooks: Hooks(), completion: completion)
    }

    static func run(
        _ job: ConfigurationImport, mode: ConfigurationImportMode, preferences: Preferences, hooks: Hooks,
        completion: @Sendable (ConfigurationImportResult) async -> Void
    ) async -> ConfigurationImportResult {
        var adultOutcome: ConfigurationPartitionOutcome?
        // Step 1: the adult partition, its transaction and then its
        // keychain removals. The job's box is emptied here, and what it held
        // goes out of scope with this block.
        if job.includesAdult {
            if let taken = job.takeAdult() {
                if let plan = await transaction(taken.part, into: taken.target, mode: mode, inside: hooks.insideAdultTransaction) {
                    release(plan, from: taken.target)
                    adultOutcome = await imported(plan, in: taken.target)
                } else {
                    adultOutcome = .failed
                }
            } else {
                // Run twice: the adult part is gone.
                adultOutcome = .failed
            }
        }
        let result: ConfigurationImportResult
        if case .failed? = adultOutcome {
            result = ConfigurationImportResult(mode: mode, adult: adultOutcome, normal: .notTried, settingsReplaced: false)
        } else {
            // Step 2: the normal partition's transaction.
            let normalPlan = await transaction(job.document.normal, into: job.normal, mode: mode, inside: hooks.insideNormalTransaction)
            // Step 3: the global settings, only after the normal partition
            // committed (every file contains it).
            var settingsReplaced = false
            if mode == .replace, normalPlan != nil {
                job.document.settings.apply(to: preferences)
                settingsReplaced = true
            }
            // Step 4: the normal partition's keychain removals.
            var normalOutcome = ConfigurationPartitionOutcome.failed
            if let normalPlan {
                release(normalPlan, from: job.normal)
                normalOutcome = await imported(normalPlan, in: job.normal)
            }
            result = ConfigurationImportResult(mode: mode, adult: adultOutcome, normal: normalOutcome, settingsReplaced: settingsReplaced)
        }
        // Step 5.
        await completion(result)
        return result
    }

    /// One partition's transaction; `nil` when it failed and wrote
    /// nothing.
    private static func transaction(
        _ part: ConfigurationPartition, into target: ConfigurationTarget, mode: ConfigurationImportMode,
        inside: (@Sendable () throws -> Void)?
    ) async -> ConfigurationPlan? {
        try? await target.library.importConfiguration(part, mode: mode, inside: inside)
    }

    /// Removes the keychain items of the references the transaction
    /// cleared or whose slot it removed. A failure is ignored: no row names
    /// the item any more, so it is never read or sent (decision 5).
    private static func release(_ plan: ConfigurationPlan, from target: ConfigurationTarget) {
        for reference in plan.releasedKeyReferences {
            try? target.keys.remove(reference)
        }
    }

    /// The outcome of a committed partition, with the number of its slots
    /// that have no usable key ("Key needed").
    private static func imported(_ plan: ConfigurationPlan, in target: ConfigurationTarget) async -> ConfigurationPartitionOutcome {
        let references = (try? await target.library.configurationSlotReferences()) ?? [:]
        let keysNeeded = references.values.filter { reference in
            guard let reference else { return true }
            return (try? target.keys.read(reference)) == nil
        }.count
        return .imported(plan, keysNeeded: keysNeeded)
    }
}
