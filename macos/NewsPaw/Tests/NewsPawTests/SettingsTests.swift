import AppKit
import SwiftUI
import Foundation
import Testing

@testable import NewsPaw

/// A backend that answers the shell's poll and fails `service.stop` the given way.
@MainActor
private func stoppingClient(_ stop: @escaping @MainActor () throws -> String) -> BackendClient {
    BackendClient { body, _ in
        let request = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
        let reply: String = try await MainActor.run {
            switch request["op"] as? String {
            case "service.status": return #"{"ok":true,"result":{"protocol_version":1,"state":"running"}}"#
            case "config.get": return #"{"ok":true,"result":{"revision":1,"document":{"ui_locale":"en","news_output_locale":"en","categories":[],"subscriptions":[],"sources":[],"accounts":[],"model_profiles":[]}}}"#
            case "bots.list": return #"{"ok":true,"result":[]}"#
            case "service.stop": return try stop()
            default: return #"{"ok":false,"error":"unknown_operation"}"#
            }
        }
        return Data(reply.utf8)
    }
}

// MARK: - R06-11: a failed stop names what happened

@Test @MainActor func aFailedStopIsReportedWithItsOwnCode() async throws {
    let name = "NewsPawTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }

    let refused = AppModel(client: stoppingClient {
        #"{"ok":false,"error":"internal_error","error_detail":{"code":"internal_error","domain":"service","retryable":false}}"#
    }, defaults: defaults)
    await refused.refresh()
    await refused.stopBackend()
    #expect(refused.error != nil)
    #expect(refused.lastFailure?.code == "internal_error")
    #expect(refused.connection == .connected)

    let lost = AppModel(client: stoppingClient { throw SocketFailure.disconnected }, defaults: defaults)
    await lost.refresh()
    await lost.stopBackend()
    #expect(lost.lastFailure?.code == "backend_unreachable")
    #expect(lost.connection == .offline)

    // A reply that does not say "stopping" is not a confirmed stop.
    let odd = AppModel(client: stoppingClient { #"{"ok":true,"result":{"protocol_version":1,"state":"running"}}"# }, defaults: defaults)
    await odd.refresh()
    await odd.stopBackend()
    #expect(odd.lastFailure?.code == "invalid_reply")
    // A stop failure is shown with its code's copy, so no retry of a destructive action is offered.
    #expect(odd.retryLast == nil)
}

@Test func stoppingTheBackendIsConfirmedWithTheAgreedWording() {
    #expect(L10n.Shell.stopBody.zh == "停止后菜单栏将不再推送，直到你再次打开 NewsPaw。")
    for language in AppLanguage.allCases {
        #expect(!L10n.Shell.stopBody(language).isEmpty)
    }
}

// MARK: - In-memory backend

/// The settings page's operations with the real backend's rules (`control.py`,
/// `operations.py`, `scheduler.py`): an import is previewed only on an untouched instance and
/// applied only with the preview's digest and revision; imported digests and sources are always
/// off; `schedule.configure` needs the current revision and is what `setup.readiness` reports;
/// once `service.stop` is answered the process is gone until it is started again.
@MainActor
final class SettingsBackend {
    var revision = 1
    /// `_fresh`: the revision an untouched instance has, and whether anything else was stored.
    var freshRevision = 1
    var used = false
    var document: [String: Any] = [
        "ui_locale": "en", "news_output_locale": "en", "timezone": "Asia/Tokyo", "owner_id": NSNull(),
        "x_api": ["credential_ref": NSNull()],
        "categories": [["id": "world", "name": "World", "partition": "normal"], ["id": "ai", "name": "AI", "partition": "normal"]],
        "subscriptions": [
            ["id": "sub_world", "category_id": "world", "timezone": "Asia/Tokyo", "enabled": false, "times": ["08:00"], "bot_ids": [], "source_ids": []],
            ["id": "sub_ai", "category_id": "ai", "timezone": "Asia/Tokyo", "enabled": false, "times": ["12:00"], "bot_ids": [], "source_ids": []],
        ],
        "sources": [], "accounts": [], "bots": [],
        "model_profiles": [["id": "normal_primary", "partition": "normal", "role": "primary", "provider": "openai",
                            "base_url": "https://api.openai.com/v1", "model": "gpt", "credential_ref": NSNull(), "capabilities": []]],
    ]
    var scheduleRevision = 1
    var scheduleEnabled = true
    var startedAt: String? = "2026-11-10T07:02:00+00:00"
    var version: String? = "0.5.0"
    private(set) var stopping = false
    private(set) var stopped = false
    /// `service.stop` answers this instead of stopping.
    var stopRefusal: String?
    /// Ages in days of cleanup candidates (rotated logs and fetch records).
    var logAges: [Int] = [10, 40, 100]
    var recordAges: [Int] = [3, 45]
    var jobs: [[String: Any]] = []
    /// Runs while an `ops.cleanup` preview is being answered (the owner acts meanwhile).
    var duringCleanupPreview: (@MainActor () -> Void)?
    var manifests: [String: [String: Any]] = [:]
    private(set) var requests: [[String: Any]] = []

    func calls(_ op: String) -> [[String: Any]] { requests.filter { $0["op"] as? String == op } }
    var ops: [String] { requests.compactMap { $0["op"] as? String } }

    /// launchd starts the process again (kickstart, or registering with RunAtLoad).
    func run() {
        stopping = false
        stopped = false
        startedAt = "2026-11-10T09:30:00+00:00"
    }

    var client: BackendClient {
        BackendClient { [unowned self] body, _ in
            let reply = try await MainActor.run { () throws -> Data in
                let request = try JSONSerialization.jsonObject(with: body) as! [String: Any]
                if self.stopped { throw SocketFailure.disconnected }
                self.requests.append(request)
                return self.answer(request)
            }
            return reply
        }
    }

    private func ok(_ result: Any) -> Data { try! JSONSerialization.data(withJSONObject: ["ok": true, "result": result]) }
    private func refuse(_ code: String, _ domain: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["ok": false, "error": code, "error_detail": ["code": code, "domain": domain, "retryable": false]])
    }

    private func status() -> [String: Any] {
        var result: [String: Any] = ["protocol_version": 1, "state": stopping ? "stopping" : "running",
                                     "operations": ["service.status", "service.stop", "setup.readiness"]]
        if let startedAt { result["started_at"] = startedAt }
        if let version { result["version"] = version }
        return result
    }

    /// `_scrub_settings`: no owner, no keys, Bots unpaired, every digest and source off.
    private func scrub(_ settings: [String: Any]) -> [String: Any] {
        var settings = settings
        settings["owner_id"] = NSNull()
        settings["subscriptions"] = (settings["subscriptions"] as? [[String: Any]] ?? []).map { var s = $0; s["enabled"] = false; return s }
        settings["sources"] = (settings["sources"] as? [[String: Any]] ?? []).map { var s = $0; s["enabled"] = false; return s }
        settings["bots"] = (settings["bots"] as? [[String: Any]] ?? []).map {
            var b = $0; b["paired"] = false; b["verified"] = false; b["credential_ref"] = NSNull(); return b
        }
        settings["model_profiles"] = (settings["model_profiles"] as? [[String: Any]] ?? []).map {
            var p = $0; p["credential_ref"] = NSNull(); p["capabilities"] = [String](); return p
        }
        return settings
    }

    struct Refusal: Error { let code: String }

    private func preview(_ portable: Any?) -> Result<[String: Any], Refusal> {
        guard revision == freshRevision, !used else { return .failure(Refusal(code: "restore_requires_fresh_instance")) }
        guard let portable = portable as? [String: Any], Set(portable.keys) == ["format", "settings", "omitted"],
              portable["format"] as? Int == 1, let settings = portable["settings"] as? [String: Any],
              let omitted = portable["omitted"] as? [String: Int] else { return .failure(Refusal(code: "invalid_portable_settings")) }
        let scrubbed = scrub(settings)
        // `_preview`: sha256 of (revision, normalized settings, omitted) — the same file at the
        // same revision always gives the same digest.
        let canonical = (try? JSONSerialization.data(withJSONObject: [scrubbed, omitted], options: .sortedKeys)) ?? Data()
        let digest = "digest-\(revision)-\(canonical.base64EncodedString().hashValue)"
        return .success(["revision": revision, "digest": digest, "settings": scrubbed,
                         "omitted": omitted, "scheduling": "disabled",
                         "requires_pairing": !((scrubbed["bots"] as? [Any]) ?? []).isEmpty])
    }

    private func answer(_ request: [String: Any]) -> Data {
        let op = request["op"] as? String ?? ""
        if op == "service.status" { return ok(status()) }
        if op == "service.stop" {
            if let stopRefusal { return refuse(stopRefusal, "service") }
            stopping = true
            defer { stopped = true }
            return ok(status())
        }
        if stopping { return refuse("service_stopping", "service") }
        switch op {
        case "setup.readiness":
            return ok(["complete": false, "next": "bot", "scheduling_enabled": scheduleEnabled, "steps": []])
        case "config.get":
            return ok(["revision": revision, "document": document])
        case "config.save":
            guard request["revision"] as? Int == revision else { return refuse("config_conflict", "config") }
            document = request["document"] as! [String: Any]
            revision += 1
            used = true
            return ok(["revision": revision])
        case "bots.list":
            return ok([])
        case "schedule.status":
            return ok(["revision": scheduleRevision, "settings": ["enabled": scheduleEnabled], "activated_at": NSNull(), "occurrences": []])
        case "schedule.configure":
            guard request["revision"] as? Int == scheduleRevision else { return refuse("schedule_policy_changed", "schedule") }
            scheduleEnabled = (request["settings"] as? [String: Any])?["enabled"] as? Bool ?? scheduleEnabled
            scheduleRevision += 1
            return ok(["revision": scheduleRevision, "settings": ["enabled": scheduleEnabled]])
        case "ops.export_settings":
            return ok(["format": 1, "settings": scrub(document), "omitted": ["labels": 0]])
        case "ops.preview_import":
            switch preview(request["portable"]) {
            case let .success(result): return ok(result)
            case let .failure(refusal): return refuse(refusal.code, "ops")
            }
        case "ops.apply_import":
            guard request["revision"] as? Int == revision else { return refuse("configuration_changed", "ops") }
            switch preview(request["portable"]) {
            case let .failure(refusal): return refuse(refusal.code, "ops")
            case let .success(result):
                guard request["digest"] as? String == result["digest"] as? String else { return refuse("preview_changed", "ops") }
                document = result["settings"] as! [String: Any]
                revision += 1
                used = true
                return ok(["revision": revision, "scheduling": "disabled", "requires_pairing": result["requires_pairing"]!])
            }
        case "ops.diagnostics":
            return ok(["process": "running", "business": ["scheduling": scheduleEnabled ? "enabled" : "disabled", "log_bytes": 2048]])
        case "ops.support_snapshot":
            return ok(["format": 1, "database_version": 30, "process": "running"])
        case "ops.verify_backup":
            let name = request["name"] as? String ?? ""
            guard name.range(of: #"^state\.db\.backup-[a-f0-9]{32}$"#, options: .regularExpression) != nil else {
                return refuse("invalid_backup", "ops")
            }
            return ok(["schema_version": 30, "size_bytes": 4096, "integrity": "ok", "restorable": false])
        case "ops.cleanup":
            let days = request["retention_days"] as? Int ?? 7
            guard [7, 30, 90].contains(days) else { return refuse("invalid_cleanup", "ops") }
            let apply = request["apply"] as? Bool ?? false
            if !apply, let during = duringCleanupPreview {
                duringCleanupPreview = nil
                during()
            }
            let logs = logAges.filter { $0 > days }.count
            let records = recordAges.filter { $0 > days }.count
            if apply {
                logAges.removeAll { $0 > days }
                recordAges.removeAll { $0 > days }
            }
            return ok(["apply": apply, "x": apply ? ["purged": 0] : ["candidates": 0], "log_bytes": 4096,
                       "log_candidates": logs, "log_removed": apply ? logs : 0,
                       "attempt_candidates": records, "snapshot_candidates": 0,
                       "media_candidates": 0, "media_removed": 0, "media_deferred": false])
        case "jobs.list":
            return ok(jobs)
        case "delivery.status":
            guard let job = request["job_id"] as? String, let manifest = manifests[job] else { return refuse("missing_delivery", "delivery") }
            return ok(manifest)
        default:
            return refuse("unknown_operation", "protocol")
        }
    }
}

/// A login item whose state and failures the test sets, with `ResidentAgent`'s guards.
@MainActor
final class FakeResident: ResidentService {
    var state: ResidentState = .on
    var calls: [String] = []
    var enableError: Error?
    var disableError: Error?
    var startError: Error?
    var waitError: Error?
    /// `agent.lock` is released before the process exits: the next `kickstart` finds the old
    /// process still running (and does nothing), then it exits 0 and launchd leaves it stopped.
    var stillExitingAtNextStart = false
    let backend: SettingsBackend

    init(_ backend: SettingsBackend, state: ResidentState = .on) {
        self.backend = backend
        self.state = state
    }

    func enable() async throws {
        calls.append("enable")
        guard state == .off else { throw ResidentFailure.serviceUnavailable }
        if let enableError { throw enableError }
        state = .on
        backend.run()
    }

    func disable(waitForWorker: Bool) async throws {
        calls.append("disable(\(waitForWorker))")
        guard state == .on || state == .approval else { throw ResidentFailure.serviceUnavailable }
        if let disableError { throw disableError }
        state = .off
    }

    func waitUntilStopped() async throws {
        calls.append("wait")
        if let waitError { throw waitError }
    }

    func start() async throws {
        calls.append("start")
        guard state == .on else { throw ResidentFailure.serviceUnavailable }
        if let startError { throw startError }
        if stillExitingAtNextStart {
            stillExitingAtNextStart = false
            return
        }
        backend.run()
    }

    func openLoginItemsSettings() { calls.append("openSettings") }
}

@MainActor
private func connected(_ backend: SettingsBackend, dataDirectory: URL? = nil) async throws -> (AppModel, () -> Void) {
    let name = "NewsPawTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    let model = AppModel(client: backend.client, defaults: defaults, dataDirectory: dataDirectory)
    await model.refresh()
    #expect(model.connection == .connected)
    return (model, { defaults.removePersistentDomain(forName: name) })
}

@MainActor
private func control(_ resident: FakeResident) -> BackendControl {
    let control = BackendControl(service: resident)
    control.settleInterval = .milliseconds(1)
    return control
}

/// Panels answered by the test: nil is a cancelled panel.
@MainActor
private final class Panels {
    var saveURL: URL?
    var openURL: URL?
    var copied: [String] = []
    var asked: [String] = []

    var files: SettingsFiles {
        SettingsFiles(
            save: { [unowned self] name in self.asked.append("save:" + name); return self.saveURL },
            open: { [unowned self] _ in self.asked.append("open"); return self.openURL },
            copy: { [unowned self] text in self.copied.append(text) }
        )
    }
}

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("np-settings-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

// MARK: - A1: the login switch follows the login item

@Test @MainActor func theLoginSwitchShowsTheLoginItemsActualState() async throws {
    let backend = SettingsBackend()
    let resident = FakeResident(backend, state: .on)
    let backendControl = control(resident)
    backendControl.reload()
    #expect(backendControl.loginOn && backendControl.canToggle && backendControl.note == nil)

    resident.state = .off
    backendControl.reload()
    #expect(!backendControl.loginOn && backendControl.canToggle)

    // Registered but not allowed yet: not on, and System Settings is offered.
    resident.state = .approval
    backendControl.reload()
    #expect(!backendControl.loginOn && !backendControl.canToggle)
    #expect(backendControl.note == .approval && backendControl.note?.offersSettings == true)

    resident.state = .unavailable
    backendControl.reload()
    #expect(!backendControl.loginOn && backendControl.note == .unavailable && backendControl.note?.offersSettings == true)

    resident.state = .notPackaged
    backendControl.reload()
    #expect(!backendControl.canToggle && backendControl.note == .notPackaged && backendControl.note?.offersSettings == false)
}

@Test @MainActor func aRefusedRegistrationIsExplainedAndOffersLoginItemsSettings() async throws {
    let backend = SettingsBackend()
    let (model, cleanup) = try await connected(backend)
    defer { cleanup() }
    let resident = FakeResident(backend, state: .off)
    let backendControl = control(resident)
    backendControl.reload()

    // e.g. a Launch Constraint violation reported by SMAppService.register().
    resident.enableError = NSError(domain: "SMAppServiceErrorDomain", code: 1)
    await backendControl.setLoginItem(true, model: model)
    #expect(backendControl.note == .refused && backendControl.note?.offersSettings == true)
    #expect(!backendControl.loginOn)

    resident.enableError = ResidentFailure.legacyServiceActive
    await backendControl.setLoginItem(true, model: model)
    #expect(backendControl.note == .legacy)

    resident.enableError = nil
    await backendControl.setLoginItem(true, model: model)
    #expect(backendControl.loginOn && backendControl.note == nil)
}

@Test @MainActor func turningTheLoginItemOffStopsTheBackendBeforeUnregistering() async throws {
    let backend = SettingsBackend()
    let (model, cleanup) = try await connected(backend)
    defer { cleanup() }
    let resident = FakeResident(backend, state: .on)
    let backendControl = control(resident)
    backendControl.reload()
    await backendControl.setLoginItem(false, model: model)
    #expect(backend.ops.contains("service.stop"))
    #expect(resident.calls == ["disable(true)"])
    #expect(!backendControl.loginOn && backendControl.note == nil)
    #expect(model.connection != .connected)

    // A worker that does not stop in time keeps the login item and says so.
    let other = SettingsBackend()
    let (second, cleanupSecond) = try await connected(other)
    defer { cleanupSecond() }
    let stuck = FakeResident(other, state: .on)
    stuck.disableError = ResidentFailure.workerStillRunning
    let stuckControl = control(stuck)
    stuckControl.reload()
    await stuckControl.setLoginItem(false, model: second)
    #expect(stuckControl.loginOn && stuckControl.note == .stillRunning)
}

@Test @MainActor func restartStopsWaitsForTheProcessAndStartsItAgain() async throws {
    let backend = SettingsBackend()
    let (model, cleanup) = try await connected(backend)
    defer { cleanup() }
    let resident = FakeResident(backend, state: .on)
    let backendControl = control(resident)
    backendControl.reload()
    #expect(backendControl.canRestart)
    await backendControl.restart(model: model)
    #expect(backend.ops.filter { $0 == "service.stop" }.count == 1)
    #expect(resident.calls == ["wait", "start"])
    #expect(model.connection == .connected && backendControl.note == nil)
    #expect(model.service?.startedAt == "2026-11-10T09:30:00+00:00")

    // A refused stop does not start anything and shows the stop's own failure.
    backend.stopRefusal = "internal_error"
    resident.calls = []
    await backendControl.restart(model: model)
    #expect(resident.calls.isEmpty && model.lastFailure?.code == "internal_error")

    // Not registered (e.g. a development run): there is nothing launchd could start again.
    resident.state = .off
    backendControl.reload()
    #expect(!backendControl.canRestart)
}

@Test @MainActor func startingABackendThatIsNotRunning() async throws {
    let backend = SettingsBackend()
    let (model, cleanup) = try await connected(backend)
    defer { cleanup() }
    await model.stopBackend()
    await model.refresh()
    #expect(model.connection == .offline)
    // Registered: launchd starts the registered job.
    let resident = FakeResident(backend, state: .on)
    let backendControl = control(resident)
    await backendControl.start(model: model)
    #expect(resident.calls == ["start"] && model.connection == .connected)

    // Not registered: starting registers it (RunAtLoad starts it).
    await model.stopBackend()
    await model.refresh()
    let unregistered = FakeResident(backend, state: .off)
    let second = control(unregistered)
    await second.start(model: model)
    #expect(unregistered.calls == ["enable"] && second.loginOn && model.connection == .connected)

    // launchd refuses: say so and offer the login items settings.
    await model.stopBackend()
    await model.refresh()
    let refusing = FakeResident(backend, state: .on)
    refusing.startError = ResidentFailure.serviceUnavailable
    let third = control(refusing)
    await third.start(model: model)
    #expect(third.note == .startFailed && third.note?.offersSettings == true)
}

@Test @MainActor func openingNewsPawStartsAStoppedBackendOnlyWhenItStartsAtLogin() async throws {
    let backend = SettingsBackend()
    let (model, cleanup) = try await connected(backend)
    defer { cleanup() }
    let running = FakeResident(backend, state: .on)
    await control(running).startIfStopped(model: model)
    #expect(running.calls.isEmpty)

    await model.stopBackend()
    await model.refresh()
    let off = FakeResident(backend, state: .off)
    await control(off).startIfStopped(model: model)
    #expect(off.calls.isEmpty && model.connection == .offline)

    let registered = FakeResident(backend, state: .on)
    let backendControl = control(registered)
    await backendControl.startIfStopped(model: model)
    await backendControl.startIfStopped(model: model)
    #expect(registered.calls == ["start"] && model.connection == .connected)
}

// MARK: - A2: one pause switch everywhere

@Test @MainActor func pausingReadsTheSameInSettingsTheMenuBarAndTheSidebar() async throws {
    let backend = SettingsBackend()
    let (model, cleanup) = try await connected(backend)
    defer { cleanup() }
    #expect(!model.schedulingPaused)
    #expect(model.menuItems().contains(.pause(checked: false)))
    #expect(model.statusTitle == L10n.Shell.running && !model.menuBarPaused)

    // Settings (or the menu bar) pauses: all three read paused right away.
    await model.setPaused(true)
    #expect(!backend.scheduleEnabled && model.schedulingPaused)
    #expect(model.menuItems().contains(.pause(checked: true)))
    #expect(model.statusTitle == L10n.Shell.paused && model.menuBarPaused)
    #expect(model.menuStatus() == L10n.Shell.paused(.en))

    // Resumed elsewhere (a Telegram command): the next poll brings all three back.
    backend.scheduleEnabled = true
    backend.scheduleRevision += 1
    await model.refresh()
    #expect(!model.schedulingPaused && model.menuItems().contains(.pause(checked: false)) && !model.menuBarPaused)
    #expect(model.statusTitle == L10n.Shell.running)
}

// MARK: - §8.3 menu bar

@Test @MainActor func theMenuBarNamesTheNextDeliveryAndHasNoStopItem() async throws {
    let backend = SettingsBackend()
    var subscriptions = backend.document["subscriptions"] as! [[String: Any]]
    subscriptions[0]["enabled"] = true
    subscriptions[0]["bot_ids"] = ["bot1"]
    subscriptions[0]["timezone"] = "UTC"
    subscriptions[0]["times"] = ["08:00", "18:00"]
    // On, but with no Bot: nothing will be sent, so it is not "next".
    subscriptions[1]["enabled"] = true
    subscriptions[1]["timezone"] = "UTC"
    subscriptions[1]["times"] = ["12:00"]
    backend.document["subscriptions"] = subscriptions
    let (model, cleanup) = try await connected(backend)
    defer { cleanup() }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let noon = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 11, minute: 30))!
    let next = try #require(model.nextDelivery(now: noon))
    #expect(next.subscriptionId == "sub_world")
    #expect(next.at == calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 18)))
    let late = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 19))!
    #expect(model.nextDelivery(now: late)?.at == calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 8)))

    let items = model.menuItems(now: noon)
    guard case let .status(line) = items.first else { Issue.record("no status line"); return }
    #expect(line.hasPrefix(L10n.Shell.running(.en)) && line.contains(model.digestTitle("sub_world")))
    #expect(Array(items.dropFirst()) == [.divider, .open, .pause(checked: false), .divider, .quit])

    // Offline: only the status, Open and Quit — and never a stop item.
    await model.stopBackend()
    await model.refresh()
    #expect(Array(model.menuItems().dropFirst()) == [.divider, .open, .divider, .quit])
}

// MARK: - A3: import previews its changes and never turns a digest on

@MainActor
private func portable(_ backend: SettingsBackend) -> [String: Any] {
    var settings = backend.document
    settings["ui_locale"] = "ja"
    settings["timezone"] = "Europe/Paris"
    var subscriptions = settings["subscriptions"] as! [[String: Any]]
    subscriptions[0]["enabled"] = true
    subscriptions[0]["times"] = ["07:30"]
    subscriptions.remove(at: 1)
    subscriptions.append(["id": "sub_extra", "name": "Morning AI", "category_id": "ai", "timezone": "Europe/Paris", "enabled": true,
                          "times": ["09:00"], "bot_ids": ["bot_home"], "source_ids": []])
    settings["subscriptions"] = subscriptions
    settings["sources"] = [["id": "src_one", "name": "One", "kind": "rss", "url": "https://example.com/feed", "enabled": true]]
    settings["bots"] = [["id": "bot_home", "name": "Home", "credential_ref": NSNull(), "telegram_id": NSNull(), "chat_id": NSNull(),
                         "verified": false, "paired": false, "adult_allowed": false]]
    return ["format": 1, "settings": settings, "omitted": ["source_urls": 2]]
}

private func write(_ object: Any, in folder: URL) throws -> URL {
    let url = folder.appendingPathComponent("NewsPaw-settings.json")
    try JSONSerialization.data(withJSONObject: object).write(to: url)
    return url
}

@Test @MainActor func importListsWhatWillChangeAndNeverTurnsADigestOn() async throws {
    let backend = SettingsBackend()
    let (model, cleanup) = try await connected(backend)
    defer { cleanup() }
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let panels = Panels()
    panels.openURL = try write(portable(backend), in: folder)
    let data = SettingsData(files: panels.files)

    await data.chooseImport(model: model)
    let preview = try #require(data.importPreview)
    #expect(!backend.ops.contains("ops.apply_import"))
    #expect(preview.changes.contains(.uiLanguage(.ja)))
    #expect(preview.changes.contains(.timezone("Europe/Paris")))
    #expect(preview.changes.contains { change in
        if case let .digests(changed, removed) = change {
            return changed.map(\.id) == ["sub_world", "sub_extra"] && removed.map(\.id) == ["sub_ai"]
        }
        return false
    })
    #expect(preview.changes.contains(.collection(.sources, added: 1, removed: 0, changed: 0)))
    #expect(preview.changes.contains(.collection(.bots, added: 1, removed: 0, changed: 0)))
    #expect(preview.changes.contains(.omitted(2)))
    #expect(preview.requiresPairing)

    await data.applyImport(model: model)
    let applied = try #require(backend.calls("ops.apply_import").first)
    #expect(applied["digest"] as? String == preview.digest && applied["revision"] as? Int == preview.revision)
    #expect(data.importPreview == nil && data.failures["import"] == nil && data.done["import"] != nil)
    // Nothing the app sent turns a digest or the schedule on, and the stored digests are off.
    #expect(!backend.ops.contains("subscriptions.save") && !backend.ops.contains("schedule.configure") && !backend.ops.contains("config.save"))
    let stored = backend.document["subscriptions"] as! [[String: Any]]
    #expect(stored.count == 2 && stored.allSatisfy { $0["enabled"] as? Bool == false })
    #expect(model.config?.subscriptions.allSatisfy { !$0.enabled } == true)
    #expect(model.configRevision == backend.revision)
}

@Test @MainActor func anImportRefusedAtPreviewIsNamedAndNothingIsApplied() async throws {
    let backend = SettingsBackend()
    backend.used = true
    let (model, cleanup) = try await connected(backend)
    defer { cleanup() }
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let panels = Panels()
    panels.openURL = try write(portable(backend), in: folder)
    let data = SettingsData(files: panels.files)
    await data.chooseImport(model: model)
    #expect(data.importPreview == nil)
    #expect(data.failures["import"]?.code == "restore_requires_fresh_instance")
    #expect(!backend.ops.contains("ops.apply_import"))
}

@Test @MainActor func anImportWhoseInstanceChangedMeanwhileNamesWhyAndAppliesNothing() async throws {
    // ops.apply_import checks the revision first; a changed revision also means the instance is
    // no longer untouched, so the second look names that (the real backend has no other outcome).
    let backend = SettingsBackend()
    let (model, cleanup) = try await connected(backend)
    defer { cleanup() }
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let panels = Panels()
    panels.openURL = try write(portable(backend), in: folder)
    let data = SettingsData(files: panels.files)
    await data.chooseImport(model: model)
    #expect(data.importPreview != nil)
    backend.revision += 1
    backend.used = true
    await data.applyImport(model: model)
    #expect(data.importPreview == nil && data.failures["import"]?.code == "restore_requires_fresh_instance")
    #expect(backend.calls("ops.apply_import").count == 1)
    #expect((backend.document["subscriptions"] as! [[String: Any]]).map { $0["id"] as! String } == ["sub_world", "sub_ai"])
}

@Test @MainActor func theSameFileAtTheSameRevisionPreviewsToTheSameDigest() async throws {
    let backend = SettingsBackend()
    let (model, cleanup) = try await connected(backend)
    defer { cleanup() }
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let panels = Panels()
    panels.openURL = try write(portable(backend), in: folder)
    let data = SettingsData(files: panels.files)
    await data.chooseImport(model: model)
    let first = try #require(data.importPreview).digest
    await data.chooseImport(model: model)
    #expect(data.importPreview?.digest == first)
    await data.applyImport(model: model)
    #expect(backend.used && data.failures["import"] == nil)
}

@Test @MainActor func aFileThatIsNotExportedSettingsIsRefusedWithoutAsking() async throws {
    let backend = SettingsBackend()
    let (model, cleanup) = try await connected(backend)
    defer { cleanup() }
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let panels = Panels()
    let data = SettingsData(files: panels.files)

    let notJSON = folder.appendingPathComponent("notes.json")
    try Data("not json".utf8).write(to: notJSON)
    panels.openURL = notJSON
    await data.chooseImport(model: model)
    #expect(data.failures["import"]?.code == "invalid_portable_settings")

    let huge = folder.appendingPathComponent("huge.json")
    try Data(("{\"x\":\"" + String(repeating: "a", count: 600 * 1024) + "\"}").utf8).write(to: huge)
    panels.openURL = huge
    await data.chooseImport(model: model)
    #expect(data.failures["import"]?.code == "invalid_portable_settings")
    #expect(!backend.ops.contains("ops.preview_import"))
}

@Test @MainActor func cancellingAPanelChangesNothing() async throws {
    let backend = SettingsBackend()
    let (model, cleanup) = try await connected(backend)
    defer { cleanup() }
    let panels = Panels()
    let data = SettingsData(files: panels.files)
    await data.chooseImport(model: model)
    await data.export(model: model)
    await data.saveDiagnostics(model: model)
    await data.verifyBackup(model: model)
    #expect(data.failures.isEmpty && data.done.isEmpty && data.importPreview == nil)
    #expect(!backend.ops.contains("ops.preview_import") && !backend.ops.contains("ops.verify_backup"))
}

// MARK: - §8.4 data

@Test @MainActor func exportedSettingsAreReadableOnlyByTheOwner() async throws {
    let backend = SettingsBackend()
    let (model, cleanup) = try await connected(backend)
    defer { cleanup() }
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let panels = Panels()
    panels.saveURL = folder.appendingPathComponent("out.json")
    let data = SettingsData(files: panels.files)
    await data.export(model: model)
    let written = try #require(panels.saveURL)
    let attributes = try FileManager.default.attributesOfItem(atPath: written.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: written)) as? [String: Any]
    #expect(object?["format"] as? Int == 1 && object?["settings"] != nil)
    #expect(data.done["export"] != nil && data.failures["export"] == nil)
}

@Test @MainActor func cleanupUsesTheChosenRetentionAndRemovesOnlyAfterConfirming() async throws {
    let backend = SettingsBackend()
    let (model, cleanup) = try await connected(backend)
    defer { cleanup() }
    #expect(model.retentionDays == 30)
    model.setRetentionDays(90)
    #expect(model.retentionDays == 90)
    model.setRetentionDays(14)
    #expect(model.retentionDays == 90)
    model.setRetentionDays(30)
    let data = SettingsData()
    await data.previewCleanup(model: model)
    #expect(backend.calls("ops.cleanup").first?["retention_days"] as? Int == 30)
    #expect(backend.calls("ops.cleanup").first?["apply"] == nil)
    let summary = try #require(data.cleanup)
    #expect(summary.count == 3 && summary.logs == 2 && summary.records == 1)
    await data.applyCleanup(model: model)
    #expect(backend.calls("ops.cleanup").last?["apply"] as? Bool == true)
    #expect(backend.calls("ops.cleanup").last?["retention_days"] as? Int == 30)
    #expect(data.cleanup == nil && data.cleaned == 3)
    #expect(backend.logAges == [10] && backend.recordAges == [3])
}

@Test func cleanupRepliesAreCountedFromTheBackendsShape() throws {
    // The reply ops.cleanup gives today (captured from the backend on a fresh database).
    let preview = #"{"apply":false,"x":{"candidates":5},"log_bytes":0,"log_candidates":2,"log_removed":0,"attempt_candidates":3,"snapshot_candidates":1,"media_candidates":4,"media_removed":0,"media_deferred":false}"#
    let counted = try BackendRPC.decode(Data(preview.utf8)) as CleanupSummary
    #expect(counted.count == 15 && counted.records == 4 && counted.images == 4 && counted.xPosts == 5 && !counted.mediaDeferred)
    let applied = #"{"apply":true,"x":{"purged":1},"log_bytes":0,"log_candidates":2,"log_removed":1,"attempt_candidates":3,"snapshot_candidates":0,"media_candidates":4,"media_removed":2,"media_deferred":true}"#
    let removed = try BackendRPC.decode(Data(applied.utf8)) as CleanupSummary
    #expect(removed.removed == 7 && removed.mediaDeferred)
    let empty = try BackendRPC.decode(Data(#"{"apply":false,"x":{},"log_bytes":0,"log_candidates":0,"log_removed":0,"attempt_candidates":0,"snapshot_candidates":0,"media_candidates":0,"media_removed":0,"media_deferred":false}"#.utf8)) as CleanupSummary
    #expect(empty.count == 0)
}

@Test @MainActor func aBackupIsCheckedOnlyFromTheDataFolder() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let backend = SettingsBackend()
    let (model, cleanup) = try await connected(backend, dataDirectory: folder)
    defer { cleanup() }
    let panels = Panels()
    let data = SettingsData(files: panels.files)

    let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("state.db.backup-" + String(repeating: "a", count: 32))
    panels.openURL = elsewhere
    await data.verifyBackup(model: model)
    #expect(data.failures["backup"]?.code == "invalid_backup" && !backend.ops.contains("ops.verify_backup"))

    let name = "state.db.backup-" + String(repeating: "b", count: 32)
    panels.openURL = folder.appendingPathComponent(name)
    await data.verifyBackup(model: model)
    #expect(backend.calls("ops.verify_backup").first?["name"] as? String == name)
    #expect(data.backup?.schemaVersion == 30 && data.failures["backup"] == nil)
}

@Test @MainActor func diagnosticsAreCopiedAndSnapshotsSaved() async throws {
    let backend = SettingsBackend()
    let (model, cleanup) = try await connected(backend)
    defer { cleanup() }
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let panels = Panels()
    let data = SettingsData(files: panels.files)
    await data.copyDiagnostics(model: model)
    #expect(panels.copied.count == 1 && panels.copied[0].contains("\"process\""))
    panels.saveURL = folder.appendingPathComponent("snapshot.json")
    await data.saveSnapshot(model: model)
    let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("snapshot.json"))) as? [String: Any]
    #expect(saved?["database_version"] as? Int == 30 && data.done["snapshot"] != nil)
}

@Test @MainActor func jobsAndTheirDeliveriesAreListedReadOnly() async throws {
    let backend = SettingsBackend()
    backend.jobs = [
        ["job_id": "job_2", "subscription_id": "sub_world", "account_id": NSNull(), "stage": "awaiting_delivery", "status": "awaiting_delivery",
         "created_at": "2026-11-10T08:00:00+00:00", "updated_at": "2026-11-10T08:01:00+00:00", "error_kind": NSNull()],
        ["job_id": "job_1", "subscription_id": "sub_ai", "account_id": NSNull(), "stage": "no_news", "status": "no_news",
         "created_at": "2026-11-09T12:00:00+00:00", "updated_at": "2026-11-09T12:00:00+00:00", "error_kind": NSNull()],
    ]
    backend.manifests["job_2"] = ["job_id": "job_2", "edition_id": "e", "partition": "normal", "locale": "en", "started": true, "reason": NSNull(),
                                  "targets": ["bot1": ["status": "delivered", "selected": true, "chat_id": 7, "reason": NSNull(), "backoff_until": NSNull(), "delivered": 2, "part_count": 2]]]
    let (model, cleanup) = try await connected(backend)
    defer { cleanup() }
    let data = SettingsData()
    await data.loadJobs(model: model)
    let jobs = try #require(data.jobs)
    #expect(jobs.map(\.jobId) == ["job_2", "job_1"])
    #expect(jobs[0].phrase == L10n.Settings.jobHandedOff && jobs[1].phrase == L10n.Overview.skipped)
    await data.loadDelivery("job_2", model: model)
    let delivery = try #require(data.deliveries["job_2"])
    #expect(delivery.targets.map(\.botId) == ["bot1"] && delivery.targets[0].phrase == L10n.Overview.delivered)
    #expect(delivery.targets[0].delivered == 2 && delivery.targets[0].parts == 2)
    // A job that never reached delivery has no record, which is not a failure.
    await data.loadDelivery("job_1", model: model)
    #expect(data.deliveries["job_1"]?.targets.isEmpty == true && data.failures["delivery.job_1"] == nil)
    // Only reads were sent.
    #expect(Set(backend.ops).isSubset(of: ["service.status", "setup.readiness", "config.get", "bots.list", "jobs.list", "delivery.status"]))
}

@Test @MainActor func whileTheBackendIsDownNothingIsSentAndTheReasonIsShown() async throws {
    let backend = SettingsBackend()
    let (model, cleanup) = try await connected(backend)
    defer { cleanup() }
    await model.stopBackend()
    await model.refresh()
    #expect(model.connection == .offline)
    let panels = Panels()
    panels.saveURL = FileManager.default.temporaryDirectory.appendingPathComponent("never.json")
    let data = SettingsData(files: panels.files)
    await data.export(model: model)
    await data.previewCleanup(model: model)
    #expect(data.failures["export"]?.code == "backend_unreachable" && data.failures["cleanup"]?.code == "backend_unreachable")
    #expect(panels.asked.isEmpty)
}

@Test @MainActor func aRefusedOperationIsShownWithItsCode() async throws {
    let backend = SettingsBackend()
    let (model, cleanup) = try await connected(backend)
    defer { cleanup() }
    let panels = Panels()
    panels.openURL = URL(fileURLWithPath: "/nonexistent/state.db.backup-zz")
    let data = SettingsData(files: panels.files)
    // A data folder the app does not know (tests): the backend decides.
    await data.verifyBackup(model: model)
    #expect(data.failures["backup"]?.code == "invalid_backup")
    let entry = FailureCopy.entry(for: BackendError(code: "invalid_backup"))
    #expect(entry.message != FailureCopy.fallback)
}

// MARK: - Copy

@Test func settingsFailuresHaveTheirOwnCopy() {
    for code in ["restore_requires_fresh_instance", "invalid_portable_settings", "settings_not_portable", "invalid_backup",
                 "invalid_cleanup", "missing_delivery"] {
        #expect(FailureCopy.table[code] != nil, "\(code) has no copy")
    }
}

@Test func settingsCopyHasAllLanguagesAndAvoidsInternalWords() {
    let banned = ["hold", "微美元", "µ", "probe", "revision", "subscription", "credential", "profile", "scope", "daemon", "cap"]
    for words in L10n.Settings.all {
        for language in AppLanguage.allCases {
            let text = words(language)
            #expect(!text.trimmingCharacters(in: .whitespaces).isEmpty)
            for word in banned { #expect(!text.lowercased().contains(word), "\(word) in \(text)") }
        }
        #expect(words.zh != words.en)
    }
    for note in LoginNote.allCases {
        for language in AppLanguage.allCases { #expect(!note.message(language).isEmpty) }
    }
}

@Test func theBackendStatusLineNamesWhenItStartedAndItsVersion() throws {
    // Stamp shows local wall-clock times, so the fixture is built in the local calendar.
    let calendar = Calendar.current
    let now = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
    let started = calendar.date(bySettingHour: 7, minute: 2, second: 0, of: now)!
    let stamp = ISO8601DateFormatter().string(from: started)
    let status: ServiceStatus = try BackendRPC.decode(Data(#"{"protocol_version":1,"state":"running","started_at":"\#(stamp)","version":"0.5.0"}"#.utf8))
    #expect(status.version == "0.5.0" && status.startedAt == stamp)
    #expect(BackendLine.detail(status, build: nil, now: now, .zhHans, calendar: calendar) == "今天 07:02 启动 · 版本 0.5.0")
    #expect(BackendLine.detail(status, build: "5", now: now, .en, calendar: calendar)?.hasSuffix("0.5.0 (5)") == true)
    let older: ServiceStatus = try BackendRPC.decode(Data(#"{"protocol_version":1,"state":"running"}"#.utf8))
    #expect(BackendLine.detail(older, build: "5", now: now, .en, calendar: calendar) == nil)
}

// MARK: - Review cycle 1

@Test @MainActor func theSettingsStatusRowSaysPausedLikeTheSidebarAndMenuBar() async throws {
    let backend = SettingsBackend()
    let (model, cleanup) = try await connected(backend)
    defer { cleanup() }
    #expect(model.settingsStatus.words == L10n.Settings.running)
    await model.setPaused(true)
    #expect(model.settingsStatus.words == L10n.Shell.paused && model.settingsStatus.words == model.statusTitle)
    #expect(model.settingsStatus.color == .orange)
    await model.setPaused(false)
    #expect(model.settingsStatus.words == L10n.Settings.running && model.settingsStatus.color == .green)
}

@Test @MainActor func cleanupRemovesWhatThePreviewCountedEvenIfTheRetentionChangedSince() async throws {
    let backend = SettingsBackend()
    let (model, cleanup) = try await connected(backend)
    defer { cleanup() }
    model.setRetentionDays(90)
    let data = SettingsData()
    await data.previewCleanup(model: model)
    #expect(data.cleanup?.count == 1)
    // Changed after looking: the confirmed list (90 days) is what goes, not a 7-day sweep.
    model.setRetentionDays(7)
    await data.applyCleanup(model: model)
    #expect(backend.calls("ops.cleanup").last?["retention_days"] as? Int == 90)
    #expect(data.cleaned == 1 && backend.logAges == [10, 40] && backend.recordAges == [3, 45])
    // A preview made for another retention is dropped when the choice changes.
    await data.previewCleanup(model: model)
    #expect(data.cleanup != nil)
    data.retentionChanged(to: 30)
    #expect(data.cleanup == nil)
}

@Test @MainActor func restartStartsAgainWhenTheOldProcessWasStillExiting() async throws {
    let backend = SettingsBackend()
    let (model, cleanup) = try await connected(backend)
    defer { cleanup() }
    let resident = FakeResident(backend, state: .on)
    resident.stillExitingAtNextStart = true
    let backendControl = control(resident)
    backendControl.settleAttempts = 3
    backendControl.reload()
    await backendControl.restart(model: model)
    #expect(resident.calls == ["wait", "start", "start"])
    #expect(model.connection == .connected && backendControl.note == nil)
}

@Test func launchdOutputTellsWhetherTheServiceStillHasAProcess() {
    let running = "gui/501/io.newspaw.resident = {\n\tactive count = 1\n\tstate = running\n\n\tprogram = x\n\tpid = 2241\n}"
    let stopped = "gui/501/io.newspaw.resident = {\n\tactive count = 0\n\tstate = not running\n\tlast exit code = 0\n}"
    #expect(ResidentAgent.launchdShowsProcess(running))
    #expect(!ResidentAgent.launchdShowsProcess(stopped))
    #expect(!ResidentAgent.launchdShowsProcess(""))
}

@Test @MainActor func aStaleStartFailureClearsOnceTheBackendAnswersOrTheLoginItemChanges() async throws {
    let backend = SettingsBackend()
    let (model, cleanup) = try await connected(backend)
    defer { cleanup() }
    await model.stopBackend()
    await model.refresh()
    let resident = FakeResident(backend, state: .on)
    resident.startError = ResidentFailure.serviceUnavailable
    let backendControl = control(resident)
    await backendControl.start(model: model)
    #expect(backendControl.note == .startFailed)
    // launchd brought it up after all (or the owner started it some other way).
    backend.run()
    await model.refresh()
    backendControl.reload(model: model)
    #expect(backendControl.note == nil)

    // Refused registration, then the owner allows it in System Settings.
    let other = FakeResident(backend, state: .off)
    other.enableError = NSError(domain: "SMAppServiceErrorDomain", code: 1)
    let second = control(other)
    await second.setLoginItem(true, model: model)
    #expect(second.note == .refused)
    other.state = .on
    second.reload(model: model)
    #expect(second.note == nil)
}

@Test @MainActor func aRestartThatCouldNotStopInTimeSaysSoInRestartTerms() async throws {
    let backend = SettingsBackend()
    let (model, cleanup) = try await connected(backend)
    defer { cleanup() }
    let resident = FakeResident(backend, state: .on)
    resident.waitError = ResidentFailure.workerStillRunning
    let backendControl = control(resident)
    backendControl.reload()
    await backendControl.restart(model: model)
    #expect(backendControl.note == .restartNotStopped)
    #expect(!L10n.Settings.noteRestartNotStopped.zh.contains("自动启动"))
}

@Test func savedFilesAreOwnerOnlyFromTheStartAndReplaceAnOlderFile() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("out.json")
    try Data("old".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    try SettingsData.writePrivately(Data("{}".utf8), to: url)
    #expect(try String(contentsOf: url, encoding: .utf8) == "{}")
    let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    #expect(mode == 0o600)
    // No temporary file is left next to it.
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["out.json"])
    // An unwritable place is reported as such.
    #expect(throws: BackendError(code: "file_write_failed")) {
        try SettingsData.writePrivately(Data("{}".utf8), to: folder.appendingPathComponent("missing/out.json"))
    }
}

// MARK: - Review cycle 2

@Test @MainActor func aCleanupPreviewForAnEarlierRetentionChoiceIsNotShown() async throws {
    let backend = SettingsBackend()
    let (model, cleanup) = try await connected(backend)
    defer { cleanup() }
    let data = SettingsData()
    // The owner switches 30 → 90 while the 30-day preview is on its way.
    backend.duringCleanupPreview = {
        model.setRetentionDays(90)
        data.retentionChanged(to: 90)
    }
    await data.previewCleanup(model: model)
    #expect(data.cleanup == nil && data.cleanupDays == nil)
    await data.applyCleanup(model: model)
    #expect(backend.calls("ops.cleanup").count == 1 && backend.logAges == [10, 40, 100])
    // Asked again, the preview matches the picker.
    await data.previewCleanup(model: model)
    #expect(data.cleanupDays == 90 && backend.calls("ops.cleanup").last?["retention_days"] as? Int == 90)
}

@Test @MainActor func aFileThatOnlyChangesADigestTypeIsNotShownAsChangingNothing() async throws {
    let backend = SettingsBackend()
    let (model, cleanup) = try await connected(backend)
    defer { cleanup() }
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    var settings = backend.document
    var categories = settings["categories"] as! [[String: Any]]
    categories[0]["partition"] = "adult"
    categories[1]["name"] = "Machine learning"
    settings["categories"] = categories
    let panels = Panels()
    panels.openURL = try write(["format": 1, "settings": settings, "omitted": [String: Int]()], in: folder)
    let data = SettingsData(files: panels.files)
    await data.chooseImport(model: model)
    let changes = try #require(data.importPreview).changes
    #expect(!changes.isEmpty)
    #expect(changes.contains(.digestTypes(
        changed: [
            DigestTypeChange(categoryId: "world", name: nil, partition: "adult", digests: [DigestRef(id: "sub_world", categoryId: "world", name: nil)]),
            DigestTypeChange(categoryId: "ai", name: "Machine learning", partition: nil, digests: [DigestRef(id: "sub_ai", categoryId: "ai", name: nil)]),
        ],
        added: 0, removed: 0
    )))
}

@Test func anyOtherDifferenceIsListedRatherThanReportedAsNothing() {
    let current: [String: Any] = ["schema_version": 4, "ui_locale": "en", "owner_id": NSNull(), "x_api": ["credential_ref": NSNull()],
                                  "categories": [], "subscriptions": [], "sources": [], "accounts": [], "bots": [], "model_profiles": []]
    #expect(ImportChange.list(current: current, incoming: current, omitted: [:]).isEmpty)
    var incoming = current
    incoming["x_api"] = ["credential_ref": "keychain:00000000-0000-0000-0000-000000000000"]
    #expect(ImportChange.list(current: current, incoming: incoming, omitted: [:]) == [.other])
    var future = current
    future["schema_version"] = 5
    future["new_setting"] = true
    #expect(ImportChange.list(current: current, incoming: future, omitted: [:]) == [.other])
}

// MARK: - Review cycle 3

@Test func theTwentyFourHourRuleForXPostTextIsStatedBesideTheRetentionChoice() {
    // ops.cleanup purges X post text older than 24 hours whatever retention is chosen
    // (x/timelines.py purge_expired, _AGE = 24 h); the copy must not imply otherwise.
    for language in AppLanguage.allCases {
        let note = L10n.Settings.retentionNote(language)
        #expect(note.contains("X") && note.contains("24"), "\(note)")
        let found = L10n.Settings.cleanupFound(language, ["count": "9", "logs": "1", "records": "2", "images": "3", "posts": "3"])
        #expect(found.contains("24"), "\(found)")
    }
    #expect(L10n.Settings.retentionNote.zh.contains("X 帖子正文"))
    #expect(L10n.Settings.cleanupFound.zh.contains("超过 24 小时的 X 帖子正文 {posts}"))
}

// MARK: - Review cycle 4

@Test @MainActor func theNextDeliveryCountsASpecialXAccountsOwnTime() async throws {
    let backend = SettingsBackend()
    var subscriptions = backend.document["subscriptions"] as! [[String: Any]]
    subscriptions[0]["enabled"] = true
    subscriptions[0]["bot_ids"] = ["bot1"]
    subscriptions[0]["timezone"] = "UTC"
    subscriptions[0]["times"] = ["18:00"]
    backend.document["subscriptions"] = subscriptions
    backend.document["accounts"] = [
        // Sent on its own at 12:00 to the digest's Bot (bot_ids null = the digest's).
        ["id": "acc_special", "handle": "breaking", "priority": "special", "partition": "normal", "subscription_id": "sub_world",
         "remote_id": "42", "times": ["12:00"], "bot_ids": NSNull()],
        // Its own empty recipient list: nothing is sent at 11:45.
        ["id": "acc_nobody", "handle": "quiet", "priority": "special", "partition": "normal", "subscription_id": "sub_world",
         "remote_id": "43", "times": ["11:45"], "bot_ids": [String]()],
        // Not yet resolved on X (no remote id): the scheduler has no scope for it.
        ["id": "acc_unresolved", "handle": "later", "priority": "special", "partition": "normal", "subscription_id": "sub_world",
         "remote_id": NSNull(), "times": ["11:40"], "bot_ids": NSNull()],
    ]
    let (model, cleanup) = try await connected(backend)
    defer { cleanup() }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let eleven = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 11))!
    let next = try #require(model.nextDelivery(now: eleven))
    #expect(next.at == calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12)))
    #expect(next.subscriptionId == "sub_world" && next.accountId == "acc_special")
    #expect(model.menuStatus(now: eleven).contains("@breaking"))
    // Late in the day the account's next slot is tomorrow 12:00, after the digest's 18:00 today.
    let afternoon = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 13))!
    #expect(model.nextDelivery(now: afternoon)?.accountId == nil)
}

@Test @MainActor func aLongImportListScrollsAndKeepsItsButtonsInView() throws {
    let model = AppModel(client: BackendClient { _, _ in Data() })
    let digests = (0..<200).map { index in
        DigestRef(id: "sub_\(index)", categoryId: "world", name: "A digest with a fairly long name number \(index) for the morning")
    }
    let preview = ImportPreview(portable: [:], digest: "d", revision: 1, requiresPairing: true,
                                changes: [.digests(changed: digests, removed: digests)], changedSincePreview: true)
    let host = NSHostingView(rootView: ImportPopover(model: model, data: SettingsData(), preview: preview))
    #expect(host.fittingSize.height <= 640, "popover is \(host.fittingSize.height) pt tall")
    // A short list stays compact.
    let short = ImportPreview(portable: [:], digest: "d", revision: 1, requiresPairing: false, changes: [.timezone("UTC")], changedSincePreview: false)
    #expect(NSHostingView(rootView: ImportPopover(model: model, data: SettingsData(), preview: short)).fittingSize.height < 300)
}
