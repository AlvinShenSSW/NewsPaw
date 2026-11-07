import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

private enum OperationsCopy {
    case title, process, business, sources, current, subscriptions, fallbacks, verified, queued, delivered, unknown
    case logSize, exportSupport, exportSettings, preview, previewDetails, restore, restoreHint, freshOnly
    case cleanup, clean, removed, deferred, snapshot, verify, integrity, failure, saved, omitted

    func text(_ language: AppLanguage) -> String {
        let words: (String, String, String) = switch self {
        case .title: ("诊断与数据管理", "Diagnostics and data", "診断とデータ管理")
        case .process: ("驻守进程", "Resident process", "常駐プロセス")
        case .business: ("业务状态", "News activity", "ニュースの動作状況")
        case .sources: ("启用的来源", "Enabled sources", "有効な情報源")
        case .current: ("数据新鲜的来源", "Sources with current data", "最新データのある情報源")
        case .subscriptions: ("启用的订阅", "Enabled subscriptions", "有効な購読")
        case .fallbacks: ("近期模型主备切换", "Recent model fallbacks", "直近のモデル切り替え")
        case .verified: ("已验证的模型能力", "Verified model capabilities", "検証済みモデル機能")
        case .queued: ("近期待投递项目", "Recent pending deliveries", "直近の配信待ち")
        case .delivered: ("近期确认投递", "Recent confirmed deliveries", "直近の配信確認済み")
        case .unknown: ("近期投递结果未知", "Recent unknown delivery outcomes", "直近の配信結果不明")
        case .logSize: ("服务日志大小", "Service log size", "サービスログのサイズ")
        case .exportSupport: ("保存脱敏诊断", "Save redacted diagnostics", "匿名化した診断を保存")
        case .exportSettings: ("保存便携配置", "Save portable settings", "移行用設定を保存")
        case .preview: ("选择配置并预览", "Choose and preview settings", "設定を選択してプレビュー")
        case .previewDetails: ("查看将导入的配置", "View settings to import", "インポートする設定を表示")
        case .restore: ("导入预览中的配置", "Import previewed settings", "プレビューした設定をインポート")
        case .restoreHint: ("导入后保持停用。模型和 Bot 需重新验证，Bot 需重新绑定。", "Imported settings stay inactive. Verify models and Bots again, then pair the Bots.", "インポートした設定は無効のままです。モデルと Bot を再検証し、Bot を再ペアリングしてください。")
        case .freshOnly: ("配置只能导入到尚未使用的实例。", "Settings can only be imported into a fresh instance.", "設定をインポートできるのは未使用の環境だけです。")
        case .cleanup: ("预览可清理项目", "Preview cleanup", "クリーンアップをプレビュー")
        case .clean: ("清理当前可删除项目", "Clean up eligible data", "削除可能なデータをクリーンアップ")
        case .removed: ("清理完成", "Cleanup completed", "クリーンアップ完了")
        case .deferred: ("有媒体正在使用，媒体清理已延后。", "Media cleanup deferred while files are in use.", "ファイルが使用中のため、メディアのクリーンアップを保留しました。")
        case .snapshot: ("迁移快照文件名", "Migration snapshot filename", "移行スナップショットのファイル名")
        case .verify: ("验证快照完整性", "Verify snapshot integrity", "スナップショットの整合性を検証")
        case .integrity: ("完整性通过 · 数据库版本", "Integrity verified · Database version", "整合性確認済み · データベースバージョン")
        case .failure: ("操作未完成。请检查本地状态后重试。", "The operation did not complete. Check local status and retry.", "操作が完了しませんでした。ローカルの状態を確認して再試行してください。")
        case .saved: ("已保存到所选文件。", "Saved to the selected file.", "選択したファイルに保存しました。")
        case .omitted: ("导出中省略的项目数", "Entries omitted during export", "エクスポート時に除外された項目数")
        }
        return switch language {
        case .zhHans: words.0
        case .en: words.1
        case .ja: words.2
        }
    }
}

struct OperationsWorkspace: View {
    let model: AppModel
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Label(OperationsCopy.title.text(model.uiLanguage), systemImage: "stethoscope")
        }
        .sheet(isPresented: $showing) { OperationsSheet(model: model) }
    }
}

private struct Diagnostics: Decodable {
    struct Business: Decodable {
        let scheduling: String
        let enabledSubscriptions, enabledSources, modelFallbackTasks, logBytes: Int
        let sourceFreshness, modelVerification, recentDeliveryParts: [String: Int]
    }
    let process: String
    let business: Business
}

private struct RestorePreview: Decodable {
    let revision: Int
    let digest: String
    let omitted: [String: Int]
}

private struct CleanupPreview: Decodable {
    let logCandidates, attemptCandidates, snapshotCandidates, auditCandidates, mediaCandidates: Int
    let mediaDeferred: Bool
    var count: Int { logCandidates + attemptCandidates + snapshotCandidates + auditCandidates + mediaCandidates }
}

private struct BackupVerification: Decodable {
    let schemaVersion: Int
    let integrity: String
}

private struct OperationsSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var diagnostics: Diagnostics?
    @State private var importing = false
    @State private var portable: [String: Any]?
    @State private var restore: RestorePreview?
    @State private var normalizedSettings = ""
    @State private var cleanup: CleanupPreview?
    @State private var confirmClean = false
    @State private var confirmRestore = false
    @State private var snapshot = ""
    @State private var backup: BackupVerification?
    @State private var message: String?
    @State private var busy = false

    private func text(_ key: OperationsCopy) -> String { key.text(model.uiLanguage) }

    var body: some View {
        Form {
            if let diagnostics {
                Section(text(.process)) {
                    Text(model.text(diagnostics.process == "running" ? .connected : diagnostics.process == "stopping" ? .stopping : .offline))
                }
                Section(text(.business)) { business(diagnostics.business) }
            }
            Section {
                Button(text(.exportSupport)) { Task { await run { try await export("ops.support_snapshot", name: "NewsPaw-diagnostics.json") } } }
                Button(text(.exportSettings)) { Task { await run { try await export("ops.export_settings", name: "NewsPaw-settings.json") } } }
                Button(text(.preview)) { importing = true }
                if let restore {
                    LabeledContent(text(.omitted), value: restore.omitted.values.reduce(0, +).formatted())
                    DisclosureGroup(text(.previewDetails)) {
                        ScrollView {
                            Text(normalizedSettings).font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 180)
                    }
                    Text(text(.restoreHint)).foregroundStyle(.secondary)
                    Button(text(.restore)) { confirmRestore = true }
                }
            }
            Section {
                Button(text(.cleanup)) { Task { await run { try await previewCleanup() } } }
                if let cleanup {
                    LabeledContent(text(.cleanup), value: cleanup.count.formatted())
                    if cleanup.mediaDeferred { Text(text(.deferred)).foregroundStyle(.secondary) }
                    Button(text(.clean), role: .destructive) { confirmClean = true }
                        .disabled(cleanup.count == 0)
                }
                TextField(text(.snapshot), text: $snapshot)
                Button(text(.verify)) { Task { await run { try await verify() } } }
                    .disabled(snapshot.isEmpty)
                if let backup, backup.integrity == "ok" {
                    LabeledContent(text(.integrity), value: backup.schemaVersion.formatted())
                }
            }
            if let message { Text(message).foregroundStyle(.secondary) }
            HStack {
                Button(SubscriptionCopy.dismiss.text(model.uiLanguage)) { dismiss() }
                Spacer()
                Button(model.text(.refresh)) { Task { await run { try await load() } } }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 570, minHeight: 480)
        .disabled(busy)
        .task { await run { try await load() } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            Task { await run { try await previewImport(result.get()) } }
        }
        .confirmationDialog(text(.clean), isPresented: $confirmClean) {
            Button(text(.clean), role: .destructive) { Task { await run { try await clean() } } }
        }
        .confirmationDialog(text(.restore), isPresented: $confirmRestore) {
            Button(text(.restore)) { Task { await run { try await apply() } } }
        } message: { Text(text(.restoreHint)) }
    }

    @ViewBuilder private func business(_ view: Diagnostics.Business) -> some View {
        LabeledContent(ConnectionCopy.schedule.text(model.uiLanguage),
                       value: model.text(view.scheduling == "enabled" ? .enabled : .disabled))
        LabeledContent(text(.subscriptions), value: view.enabledSubscriptions.formatted())
        LabeledContent(text(.sources), value: view.enabledSources.formatted())
        LabeledContent(text(.current), value: (view.sourceFreshness["current"] ?? 0).formatted())
        LabeledContent(text(.verified), value: (view.modelVerification["verified"] ?? 0).formatted())
        LabeledContent(text(.fallbacks), value: view.modelFallbackTasks.formatted())
        LabeledContent(text(.queued), value: (view.recentDeliveryParts["pending"] ?? 0).formatted())
        LabeledContent(text(.delivered), value: (view.recentDeliveryParts["delivered"] ?? 0).formatted())
        LabeledContent(text(.unknown), value: (view.recentDeliveryParts["outcome_unknown"] ?? 0).formatted())
        LabeledContent(text(.logSize), value: ByteCountFormatter.string(fromByteCount: Int64(view.logBytes), countStyle: .file))
    }

    private func load() async throws {
        diagnostics = try BackendRPC.decode(await model.request("ops.diagnostics"))
    }

    private func run(_ action: @MainActor () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        message = nil
        defer { busy = false }
        do { try await action() }
        catch BackendFailure.freshInstanceRequired { message = text(.freshOnly) }
        catch BackendFailure.conflict { message = model.text(.conflict) }
        catch { message = text(.failure) }
    }

    private func export(_ operation: String, name: String) async throws {
        let reply = try await model.request(operation)
        let json = try JSONSerialization.jsonObject(with: reply)
        let formatted = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = name
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK, let url = panel.url else { return }
        try formatted.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        message = text(.saved)
    }

    private func previewImport(_ url: URL) async throws {
        portable = nil
        restore = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw BackendFailure.rejected
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let maxBytes = 512 * 1024
        guard let data = try handle.read(upToCount: maxBytes + 1), data.count <= maxBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BackendFailure.rejected
        }
        let reply = try await model.request("ops.preview_import", fields: ["portable": object])
        let view: RestorePreview = try BackendRPC.decode(reply)
        let document = try ProtectedSettings.record(reply, revision: view.revision, field: "settings")
        let pretty = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        normalizedSettings = String(decoding: pretty, as: UTF8.self)
        portable = object
        restore = view
    }

    private func apply() async throws {
        guard let portable, let restore else { return }
        _ = try await model.request("ops.apply_import", fields: [
            "portable": portable, "digest": restore.digest, "revision": restore.revision,
        ])
        self.portable = nil
        self.restore = nil
        normalizedSettings = ""
        await model.refresh()
        try await load()
    }

    private func previewCleanup() async throws {
        cleanup = try BackendRPC.decode(await model.request("ops.cleanup"))
    }

    private func clean() async throws {
        _ = try await model.request("ops.cleanup", fields: ["apply": true])
        cleanup = nil
        try await load()
        message = text(.removed)
    }

    private func verify() async throws {
        backup = nil
        backup = try BackendRPC.decode(await model.request("ops.verify_backup", fields: ["name": snapshot]))
    }
}
