import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

// MARK: - Backend shapes

/// `ops.cleanup`: what a cleanup would remove (preview) or removed (`apply`).
struct CleanupSummary: Decodable, Equatable {
    /// X posts: `candidates` in a preview, `purged` after applying; empty when X is not set up.
    struct XPart: Decodable, Equatable {
        let candidates: Int?
        let purged: Int?
    }

    let x: XPart
    let logCandidates, logRemoved, attemptCandidates, snapshotCandidates, mediaCandidates, mediaRemoved: Int
    let mediaDeferred: Bool

    var logs: Int { logCandidates }
    /// Fetch attempts and their snapshots ("抓取记录").
    var records: Int { attemptCandidates + snapshotCandidates }
    var images: Int { mediaCandidates }
    var xPosts: Int { x.candidates ?? 0 }
    var count: Int { logs + records + images + xPosts }
    /// What an applied cleanup removed (attempts and snapshots are deleted as counted).
    var removed: Int { logRemoved + records + mediaRemoved + (x.purged ?? 0) }
}

/// `ops.verify_backup`.
struct BackupCheck: Decodable, Equatable {
    let schemaVersion: Int
    let sizeBytes: Int
    let integrity: String
}

/// One `jobs.list` row, read-only.
struct JobRecord: Decodable, Equatable, Identifiable {
    let jobId: String
    let subscriptionId: String?
    let accountId: String?
    let status: String
    let createdAt: String
    let errorKind: String?

    var id: String { jobId }

    /// The job's state in the interface's words (contract §3); nil for a state it does not name.
    var phrase: Words? {
        switch status {
        case "collecting", "editing", "preparing_media", "inflight", "waiting": L10n.Overview.preparing
        case "awaiting_delivery": L10n.Settings.jobHandedOff
        case "no_news": L10n.Overview.skipped
        case "collection_failed", "blocked", "refused", "stale": L10n.Overview.failed
        case "cancelled": L10n.Settings.jobCancelled
        case "paused": L10n.Overview.jobPaused
        case "outcome_unknown": L10n.Overview.unknown
        default: nil
        }
    }
}

/// `delivery.status` for one job: each Bot's state and how many parts arrived.
struct DeliveryRecord: Equatable {
    struct Target: Equatable, Identifiable {
        let botId: String
        let status: String
        let delivered: Int
        let parts: Int
        var id: String { botId }

        var phrase: Words? {
            switch status {
            case "pending": L10n.Overview.waiting
            case "inflight": L10n.Settings.sending
            case "delivered": L10n.Overview.delivered
            case "partial": L10n.Overview.partial
            case "outcome_unknown": L10n.Overview.unknown
            case "blocked", "revoked": L10n.Overview.failed
            case "skipped": L10n.Overview.skipped
            default: nil
            }
        }
    }

    let targets: [Target]

    fileprivate struct Reply: Decodable {
        struct Target: Decodable { let status: String; let delivered: Int; let partCount: Int }
        let targets: [String: Target]
    }

    fileprivate init(_ reply: Reply) {
        targets = reply.targets.keys.sorted().map { id in
            let target = reply.targets[id]!
            return Target(botId: id, status: target.status, delivered: target.delivered, parts: target.partCount)
        }
    }

    init(targets: [Target]) { self.targets = targets }
}

/// A digest named in an import preview, as the backend normalized it.
struct DigestRef: Equatable {
    let id: String
    let categoryId: String
    let name: String?
}

/// A built-in digest type (`categories`) the file renames or moves to the other partition,
/// with the digests of that type, so the change is named by what the owner knows.
struct DigestTypeChange: Equatable {
    let categoryId: String
    let name: String?
    let partition: String?
    let digests: [DigestRef]
}

/// One line of "what would change" before an import (interaction-spec §8.4).
enum ImportChange: Equatable {
    enum Kind: Equatable, CaseIterable {
        case sources, bots, accounts, models

        var key: String {
            switch self {
            case .sources: "sources"
            case .bots: "bots"
            case .accounts: "accounts"
            case .models: "model_profiles"
            }
        }

        var title: Words {
            switch self {
            case .sources: L10n.Settings.kindSources
            case .bots: L10n.Settings.kindBots
            case .accounts: L10n.Settings.kindAccounts
            case .models: L10n.Settings.kindModels
            }
        }
    }

    case uiLanguage(AppLanguage)
    case newsLanguage(AppLanguage)
    case timezone(String)
    /// Digests added or edited (in the file's order) and digests the file does not have.
    case digests(changed: [DigestRef], removed: [DigestRef])
    case collection(Kind, added: Int, removed: Int, changed: Int)
    /// Entries the export or the backend left out (keys, private addresses).
    case omitted(Int)
    /// Digest types (`categories`) renamed, moved between ordinary and adult, added or removed.
    case digestTypes(changed: [DigestTypeChange], added: Int, removed: Int)
    /// Any other stored difference: never reported as "changes nothing".
    case other

    /// Every top-level field the lines above describe; a difference anywhere else is `.other`.
    private static let described: Set<String> = [
        "ui_locale", "news_output_locale", "timezone", "subscriptions", "categories",
        "sources", "bots", "accounts", "model_profiles",
    ]

    /// Compares the current configuration with the settings the backend would store.
    static func list(current: [String: Any], incoming: [String: Any], omitted: [String: Int]) -> [ImportChange] {
        var changes: [ImportChange] = []
        func differs(_ key: String) -> String? {
            guard let value = incoming[key] as? String, value != current[key] as? String else { return nil }
            return value
        }
        if let value = differs("ui_locale").flatMap(AppLanguage.init(rawValue:)) { changes.append(.uiLanguage(value)) }
        if let value = differs("news_output_locale").flatMap(AppLanguage.init(rawValue:)) { changes.append(.newsLanguage(value)) }
        if let value = differs("timezone") { changes.append(.timezone(value)) }

        let digests = compare(current["subscriptions"], incoming["subscriptions"])
        func ref(_ entry: [String: Any]) -> DigestRef {
            DigestRef(id: entry["id"] as? String ?? "", categoryId: entry["category_id"] as? String ?? "",
                      name: (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
        if !digests.edited.isEmpty || !digests.removed.isEmpty {
            changes.append(.digests(changed: digests.edited.map(ref), removed: digests.removed.map(ref)))
        }
        for kind in Kind.allCases {
            let result = compare(current[kind.key], incoming[kind.key])
            let added = result.edited.count - result.changed
            if !result.edited.isEmpty || !result.removed.isEmpty {
                changes.append(.collection(kind, added: added, removed: result.removed.count, changed: result.changed))
            }
        }
        let types = compare(current["categories"], incoming["categories"])
        if !types.edited.isEmpty || !types.removed.isEmpty {
            let before = Dictionary((current["categories"] as? [[String: Any]] ?? []).compactMap { entry in
                (entry["id"] as? String).map { ($0, entry) }
            }, uniquingKeysWith: { first, _ in first })
            let digestsByType = Dictionary(grouping: (incoming["subscriptions"] as? [[String: Any]] ?? []).map(ref), by: \.categoryId)
            let changed: [DigestTypeChange] = types.edited.compactMap { entry in
                guard let id = entry["id"] as? String, let old = before[id] else { return nil }
                let name = entry["name"] as? String
                let partition = entry["partition"] as? String
                return DigestTypeChange(
                    categoryId: id,
                    name: name != old["name"] as? String ? name : nil,
                    partition: partition != old["partition"] as? String ? partition : nil,
                    digests: digestsByType[id] ?? []
                )
            }
            changes.append(.digestTypes(changed: changed, added: types.edited.count - types.changed, removed: types.removed.count))
        }
        let left = omitted.values.reduce(0, +)
        if left > 0 { changes.append(.omitted(left)) }
        let others = Set(current.keys).union(incoming.keys).subtracting(described)
        if others.contains(where: { key in !same(current[key], incoming[key]) }) { changes.append(.other) }
        return changes
    }

    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): NSDictionary(dictionary: ["v": a]).isEqual(to: ["v": b])
        default: false
        }
    }

    /// Records by `id`: added or edited ones in the incoming order (with how many were edited),
    /// and current ones the incoming list does not have.
    private static func compare(_ current: Any?, _ incoming: Any?) -> (edited: [[String: Any]], changed: Int, removed: [[String: Any]]) {
        let old = current as? [[String: Any]] ?? []
        let new = incoming as? [[String: Any]] ?? []
        let byId = Dictionary(old.compactMap { entry in (entry["id"] as? String).map { ($0, entry) } }, uniquingKeysWith: { first, _ in first })
        let incomingIds = Set(new.compactMap { $0["id"] as? String })
        var edited: [[String: Any]] = []
        var changed = 0
        for entry in new {
            guard let id = entry["id"] as? String, let before = byId[id] else {
                edited.append(entry)
                continue
            }
            if !NSDictionary(dictionary: before).isEqual(to: entry) {
                edited.append(entry)
                changed += 1
            }
        }
        let removed = old.filter { ($0["id"] as? String).map { !incomingIds.contains($0) } ?? false }
        return (edited, changed, removed)
    }
}

/// A previewed import, kept until it is applied or dismissed.
struct ImportPreview {
    /// The file exactly as read; `ops.apply_import` checks it against the preview's digest.
    let portable: [String: Any]
    let digest: String
    let revision: Int
    let requiresPairing: Bool
    let changes: [ImportChange]
    /// The first preview went stale before it was applied; this is the comparison made again.
    let changedSincePreview: Bool
}

// MARK: - Files

/// Save and open panels and the pasteboard; tests answer them directly (nil = cancelled).
struct SettingsFiles {
    var save: @MainActor (_ suggestedName: String) async -> URL?
    var open: @MainActor (_ directory: URL?) async -> URL?
    var copy: @MainActor (_ text: String) -> Void

    @MainActor static var system: SettingsFiles {
        SettingsFiles(
            save: { name in
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.json]
                panel.nameFieldStringValue = name
                let response = await withCheckedContinuation { continuation in
                    panel.begin { continuation.resume(returning: $0) }
                }
                return response == .OK ? panel.url : nil
            },
            open: { directory in
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                if let directory {
                    // Backups have no extension; start where they are kept.
                    panel.directoryURL = directory
                } else {
                    panel.allowedContentTypes = [.json]
                }
                let response = await withCheckedContinuation { continuation in
                    panel.begin { continuation.resume(returning: $0) }
                }
                return response == .OK ? panel.url : nil
            },
            copy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        )
    }
}

// MARK: - Settings page data

/// Everything the data and advanced sections do (interaction-spec §8.4–§8.5). Each action has a
/// key; its failure (by backend code) and its last success note are kept under that key.
@MainActor @Observable
final class SettingsData {
    static let maxPortableBytes = 512 * 1024

    private(set) var working: Set<String> = []
    private(set) var failures: [String: BackendError] = [:]
    private(set) var done: [String: Words] = [:]
    private(set) var importPreview: ImportPreview?
    private(set) var cleanup: CleanupSummary?
    /// The retention the shown cleanup preview was counted with; applying uses exactly that.
    private(set) var cleanupDays: Int?
    private(set) var cleaned: Int?
    private(set) var backup: BackupCheck?
    private(set) var jobs: [JobRecord]?
    private(set) var deliveries: [String: DeliveryRecord] = [:]
    @ObservationIgnored var files: SettingsFiles

    init(files: SettingsFiles = .system) {
        self.files = files
    }

    func isBusy(_ key: String) -> Bool { working.contains(key) }

    private func run(_ key: String, model: AppModel, _ body: () async throws -> Void) async {
        guard !working.contains(key) else { return }
        guard model.connection == .connected else {
            failures[key] = BackendError(code: "backend_unreachable")
            return
        }
        working.insert(key)
        failures[key] = nil
        done[key] = nil
        defer { working.remove(key) }
        do {
            try await body()
        } catch {
            failures[key] = BackendError.wrapping(error)
        }
    }

    private static func pretty(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data)
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    /// A preview counted for another retention no longer describes what a cleanup would remove.
    func retentionChanged(to days: Int) {
        guard cleanupDays != days else { return }
        cleanup = nil
        cleanupDays = nil
    }

    /// Writes a file only the owner can read, from its first byte: a new 0600 file next to the
    /// destination, renamed over it. Nothing is changed afterwards that could fail on a volume
    /// without POSIX permissions.
    nonisolated static func writePrivately(_ data: Data, to url: URL) throws {
        let failed = BackendError(code: "file_write_failed")
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw failed }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
            unlink(temporary.path)
            throw failed
        }
        guard rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw failed
        }
    }

    private func save(_ operation: Operation, name: String, key: String, model: AppModel) async {
        await run(key, model: model) {
            let content = try Self.pretty(await model.client.call(operation))
            guard let url = await files.save(name) else { return }
            try Self.writePrivately(content, to: url)
            done[key] = L10n.Settings.saved
        }
    }

    // MARK: Export and import

    func export(model: AppModel) async {
        await save(.opsExportSettings, name: "NewsPaw-settings.json", key: "export", model: model)
    }

    func chooseImport(model: AppModel) async {
        await run("import", model: model) {
            guard let url = await files.open(nil) else { return }
            importPreview = nil
            let portable = try Self.readPortable(url)
            try await preview(portable, model: model, again: false)
        }
    }

    /// Reads a settings file without sending anything the backend would refuse anyway.
    private static func readPortable(_ url: URL) throws -> [String: Any] {
        let refused = BackendError(code: "invalid_portable_settings")
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw refused }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard let data = try handle.read(upToCount: maxPortableBytes + 1), data.count <= maxPortableBytes,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw refused }
            return object
        } catch {
            throw refused
        }
    }

    private func preview(_ portable: [String: Any], model: AppModel, again: Bool) async throws {
        struct Reply: Decodable {
            let revision: Int
            let digest: String
            let requiresPairing: Bool
            let omitted: [String: Int]
        }
        let data = try await model.client.call(.opsPreviewImport, ["portable": portable])
        let reply: Reply = try BackendRPC.decode(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settings = object["settings"] as? [String: Any] else { throw BackendFailure.invalidReply }
        let current = try await model.client.configDocument().document
        importPreview = ImportPreview(
            portable: portable, digest: reply.digest, revision: reply.revision, requiresPairing: reply.requiresPairing,
            changes: ImportChange.list(current: current, incoming: settings, omitted: reply.omitted),
            changedSincePreview: again
        )
    }

    /// Applies exactly what was previewed. If the stored data changed meanwhile, the comparison is
    /// made again and shown for another confirmation instead of applying something unseen.
    func applyImport(model: AppModel) async {
        guard let shown = importPreview else { return }
        await run("import", model: model) {
            do {
                _ = try await model.client.call(.opsApplyImport, [
                    "portable": shown.portable, "digest": shown.digest, "revision": shown.revision,
                ])
            } catch let failure as BackendError where failure.isConflict {
                // `configuration_changed`: the instance changed since the preview. Asking again
                // names why (with the real backend, that it is no longer untouched); a fresh
                // comparison is shown for another confirmation, never applied unseen.
                importPreview = nil
                try await preview(shown.portable, model: model, again: true)
                return
            }
            importPreview = nil
            done["import"] = L10n.Settings.imported
            await model.refresh()
        }
    }

    func cancelImport() {
        importPreview = nil
        failures["import"] = nil
    }

    // MARK: Advanced

    func copyDiagnostics(model: AppModel) async {
        await run("diagnostics", model: model) {
            let content = try Self.pretty(await model.client.call(.opsDiagnostics))
            files.copy(String(decoding: content, as: UTF8.self))
            done["diagnostics"] = L10n.Settings.copied
        }
    }

    func saveDiagnostics(model: AppModel) async {
        await save(.opsDiagnostics, name: "NewsPaw-diagnostics.json", key: "diagnostics", model: model)
    }

    func saveSnapshot(model: AppModel) async {
        await save(.opsSupportSnapshot, name: "NewsPaw-support-snapshot.json", key: "snapshot", model: model)
    }

    /// The backend checks only a backup in its own folder, by name.
    func verifyBackup(model: AppModel) async {
        await run("backup", model: model) {
            guard let url = await files.open(model.dataDirectory) else { return }
            backup = nil
            if let folder = model.dataDirectory {
                let chosen = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
                guard chosen == folder.resolvingSymlinksInPath().standardizedFileURL.path else {
                    throw BackendError(code: "invalid_backup")
                }
            }
            backup = try BackendRPC.decode(await model.client.call(.opsVerifyBackup, ["name": url.lastPathComponent]))
        }
    }

    func previewCleanup(model: AppModel) async {
        await run("cleanup", model: model) {
            cleaned = nil
            cleanup = nil
            cleanupDays = nil
            let days = model.retentionDays
            let summary: CleanupSummary = try BackendRPC.decode(await model.client.call(.opsCleanup, ["retention_days": days]))
            // The picker changed while this was counted: it no longer describes the choice shown.
            guard model.retentionDays == days else { return }
            cleanup = summary
            cleanupDays = days
        }
    }

    /// Removes what the confirmed preview counted: the same retention, never a later choice.
    func applyCleanup(model: AppModel) async {
        guard cleanup != nil, let days = cleanupDays else { return }
        await run("cleanup", model: model) {
            let result: CleanupSummary = try BackendRPC.decode(
                await model.client.call(.opsCleanup, ["apply": true, "retention_days": days])
            )
            cleanup = nil
            cleanupDays = nil
            cleaned = result.removed
        }
    }

    func loadJobs(model: AppModel) async {
        await run("jobs", model: model) {
            jobs = try BackendRPC.decode(await model.client.call(.jobsList, ["limit": 25]))
        }
    }

    func loadDelivery(_ jobId: String, model: AppModel) async {
        await run("delivery." + jobId, model: model) {
            do {
                let reply: DeliveryRecord.Reply = try BackendRPC.decode(await model.client.call(.deliveryStatus, ["job_id": jobId]))
                deliveries[jobId] = DeliveryRecord(reply)
            } catch let failure as BackendError where failure.code == "missing_delivery" {
                // The job never reached delivery: nothing was sent, which is not a failure.
                deliveries[jobId] = DeliveryRecord(targets: [])
            }
        }
    }
}

// MARK: - Backend status line

enum BackendLine {
    /// "今天 07:02 启动 · 版本 0.5.0 (5)"; nil when the backend does not report either.
    static func detail(_ status: ServiceStatus?, build: String?, now: Date = Date(), _ language: AppLanguage,
                       calendar: Calendar = .current) -> String? {
        guard let status else { return nil }
        var parts: [String] = []
        if let started = status.startedAt.flatMap(OverviewData.date) {
            parts.append(L10n.Settings.started(language, ["when": Stamp.relative(started, now: now, language, calendar: calendar)]))
        }
        if let version = status.version {
            let shown = build.map { "\(version) (\($0))" } ?? version
            parts.append(L10n.Settings.version(language, ["version": shown]))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The app's build number, shown only when the app and the backend are the same version.
    static func build(for version: String?, bundle: Bundle = .main) -> String? {
        guard let version, bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version else { return nil }
        return bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }
}

// MARK: - Menu bar (§8.3)

enum MenuItem: Equatable {
    case status(String), divider, open, pause(checked: Bool), quit
}

struct NextDelivery: Equatable {
    let subscriptionId: String
    let at: Date
}

extension AppModel {
    /// The menu bar icon is greyed and says "paused" while every delivery is paused.
    var menuBarPaused: Bool { connection == .connected && schedulingPaused }

    /// The next scheduled edition of an enabled digest that has somewhere to go.
    func nextDelivery(now: Date = Date()) -> NextDelivery? {
        guard let config else { return nil }
        var best: NextDelivery?
        for subscription in config.subscriptions where subscription.enabled && !(subscription.botIds ?? []).isEmpty {
            guard let zone = TimeZone(identifier: subscription.timezone) else { continue }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            for offset in 0...1 {
                guard let base = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
                let civil = calendar.dateComponents([.year, .month, .day], from: base)
                for time in subscription.times {
                    let parts = time.split(separator: ":").compactMap { Int($0) }
                    guard parts.count == 2,
                          let target = OverviewData.resolveWallTime(civil, hour: parts[0], minute: parts[1], calendar: calendar),
                          target > now, target < best?.at ?? .distantFuture else { continue }
                    best = NextDelivery(subscriptionId: subscription.id, at: target)
                }
            }
        }
        return best
    }

    /// "后台运行中 · 下一期 18:00 科技数码", or the plain state.
    func menuStatus(now: Date = Date(), calendar: Calendar = .current) -> String {
        guard connection == .connected, !schedulingPaused, let next = nextDelivery(now: now) else { return text(statusTitle) }
        let clock = Stamp.clock(next.at)
        let when = calendar.isDate(next.at, inSameDayAs: now) ? clock : L10n.Settings.tomorrowAt(uiLanguage, ["time": clock])
        return L10n.Settings.menuNext(uiLanguage, ["status": text(statusTitle), "time": when, "digest": digestTitle(next.subscriptionId)])
    }

    /// The menu's items in order. Stopping the backend is not one of them (Settings, confirmed).
    func menuItems(now: Date = Date()) -> [MenuItem] {
        var items: [MenuItem] = [.status(menuStatus(now: now)), .divider, .open]
        if connection == .connected { items.append(.pause(checked: schedulingPaused)) }
        return items + [.divider, .quit]
    }
}
