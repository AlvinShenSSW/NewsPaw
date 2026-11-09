import Foundation
import SwiftUI

struct CategoryRoutingEditor: View {
    let model: AppModel
    let config: AppConfig
    @Environment(\.dismiss) private var dismiss
    @State private var categoryId: String
    @State private var primary = ""
    @State private var backup = ""
    @State private var revision: Int
    @State private var failure: Phrase?
    @State private var busy = false

    init(model: AppModel, config: AppConfig) {
        self.model = model
        self.config = config
        let first = config.categories.first
        let digest = first.flatMap { category in config.subscriptions.first { $0.categoryId == category.id } }
        _categoryId = State(initialValue: first?.id ?? "")
        _primary = State(initialValue: digest?.primaryProfileId ?? "")
        _backup = State(initialValue: digest?.backupProfileId ?? "")
        _revision = State(initialValue: model.configRevision)
    }

    private var category: AppConfig.Category? { config.categories.first { $0.id == categoryId } }
    // Schema v4 keeps model overrides on each digest; this editor sets them for every digest
    // of the category until the redesigned digest page (R09) edits them one digest at a time.
    private var digests: [AppConfig.Subscription] { config.subscriptions.filter { $0.categoryId == categoryId } }

    var body: some View {
        VStack {
            Form {
                Picker(model.text(.categories), selection: $categoryId) {
                    ForEach(config.categories) { Text($0.name).tag($0.id) }
                }
                .onChange(of: categoryId) {
                    primary = digests.first?.primaryProfileId ?? ""
                    backup = digests.first?.backupProfileId ?? ""
                }
                selector(.primary, role: "primary", selection: $primary)
                selector(.backup, role: "backup", selection: $backup)
                if let failure { Text(model.text(failure)).foregroundStyle(.secondary) }
            }
            .formStyle(.grouped)
            HStack {
                Button(SubscriptionCopy.dismiss.text(model.uiLanguage)) { dismiss() }
                Spacer()
                Button(ConnectionCopy.save.text(model.uiLanguage)) { Task { await save() } }
                    .disabled(category == nil)
            }.padding()
        }
        .disabled(busy)
        .frame(minWidth: 540, minHeight: 330)
    }

    private func selector(_ title: Phrase, role: String, selection: Binding<String>) -> some View {
        Picker(model.text(title), selection: selection) {
            Text(ConnectionCopy.inherit.text(model.uiLanguage)).tag("")
            ForEach(config.modelProfiles.filter { $0.partition == category?.partition && $0.role == role }) {
                Text($0.provider + " · " + $0.model).tag($0.id)
            }
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        failure = nil
        do {
            var updated = try ProtectedSettings.record(await model.request("config.get"), revision: revision)
            for digest in digests {
                updated = try ProtectedSettings.modify(updated, collection: "subscriptions", id: digest.id, fields: [
                    "primary_profile_id": primary.isEmpty ? NSNull() as Any : primary,
                    "backup_profile_id": backup.isEmpty ? NSNull() as Any : backup,
                ])
            }
            _ = try await model.request("config.save", fields: ["revision": revision, "document": updated])
            await model.refresh()
            dismiss()
        } catch BackendFailure.conflict { failure = .conflict }
        catch { failure = .saveFailed }
    }
}

private enum MediaPolicyKind: String, Identifiable {
    case newspaper, media
    var id: String { rawValue }
}

struct CapabilityRouting: View {
    let model: AppModel
    let profiles: [AppConfig.Profile]
    @State private var available: Set<String> = []
    @State private var editing: MediaPolicyKind?

    var body: some View {
        Group {
            if !available.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(ConnectionCopy.tools.text(model.uiLanguage)).font(.headline)
                    if available.contains("newspaper") {
                        Button(ConnectionCopy.configureImage.text(model.uiLanguage)) { editing = .newspaper }
                    }
                    if available.contains("media") {
                        Button(ConnectionCopy.configureSpeech.text(model.uiLanguage)) { editing = .media }
                    }
                }
            }
        }
        .task {
            var observed: Set<String> = []
            for operation in ["newspaper", "media"] {
                if (try? await model.request(operation + ".policy")) != nil { observed.insert(operation) }
            }
            available = observed
        }
        .sheet(item: $editing) { MediaPolicyEditor(model: model, profiles: profiles, kind: $0) }
    }

}

private struct MediaPolicyEditor: View {
    let model: AppModel
    let profiles: [AppConfig.Profile]
    let kind: MediaPolicyKind
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: Any] = [:]
    @State private var revision = 0
    @State private var failure: Phrase?
    @State private var busy = false

    private func label(_ key: ConnectionCopy) -> String { key.text(model.uiLanguage) }
    private func value(_ key: String) -> Binding<String> {
        Binding(get: { values[key] as? String ?? "" }, set: { values[key] = $0.isEmpty ? NSNull() as Any : $0 })
    }
    private func units(_ key: String) -> Binding<String> {
        Binding(
            get: {
                if let text = values[key] as? String { return text }
                return (values[key] as? Int).map(String.init) ?? ""
            },
            set: { values[key] = $0.isEmpty ? NSNull() as Any : $0 }
        )
    }
    private func flag(_ key: String) -> Binding<Bool> {
        Binding(get: { values[key] as? Bool ?? false }, set: { values[key] = $0 })
    }

    var body: some View {
        VStack {
            Form {
                if kind == .newspaper {
                    Toggle(ConnectionCopy.configureImage.text(model.uiLanguage), isOn: flag("enabled"))
                    modelPicker(.image, key: "generation_profile", capability: "image")
                    modelPicker(.image, key: "backup_profile", capability: "image", prefix: model.text(.backup))
                    modelPicker(.vision, key: "vision_profile", capability: "vision")
                    TextField(label(.image) + " · " + label(.hold), text: units("generation_hold"))
                    TextField(label(.vision) + " · " + label(.hold), text: units("vision_hold"))
                    TextField(label(.hold), text: units("task_limit"))
                    Stepper("\(label(.pages)) · \(values["pages"] as? Int ?? 1)", value: Binding(
                        get: { values["pages"] as? Int ?? 1 },
                        set: { values["pages"] = $0 }
                    ), in: 1...2)
                } else {
                    modelPicker(.vision, key: "vision_profile", capability: "vision")
                    TextField(label(.vision) + " · " + label(.hold), text: units("vision_hold"))
                    modelPicker(.speech, key: "stt_profile", capability: "stt")
                    TextField(label(.speech) + " · " + label(.hold), text: units("stt_hold"))
                    Toggle("/listen", isOn: flag("listen_enabled"))
                }
                if let failure { Text(model.text(failure)).foregroundStyle(.secondary) }
            }
            .formStyle(.grouped)
            .disabled(revision == 0 || busy)
            HStack {
                Button(SubscriptionCopy.dismiss.text(model.uiLanguage)) { dismiss() }
                Spacer()
                Button(label(.save)) { Task { await save() } }.disabled(revision == 0 || busy)
            }.padding()
        }
        .frame(minWidth: 570, minHeight: 400)
        .task { await load() }
    }

    private func modelPicker(_ title: ConnectionCopy, key: String, capability: String, prefix: String? = nil) -> some View {
        Picker(prefix.map { $0 + " · " + label(title) } ?? label(title), selection: value(key)) {
            Text(SubscriptionCopy.none.text(model.uiLanguage)).tag("")
            ForEach(profiles.filter { $0.capabilities.contains(capability) || $0.id == values[key] as? String }) {
                Text($0.provider + " · " + $0.model).tag($0.id)
            }
        }
    }

    private func load() async {
        do {
            let data = try await model.request(kind.rawValue + ".policy")
            let current: SettingsRevision = try BackendRPC.decode(data)
            values = try ProtectedSettings.record(data, revision: current.revision, field: "settings")
            revision = current.revision
        } catch { failure = .saveFailed }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        failure = nil
        do {
            var settings = values
            for key in ["generation_hold", "vision_hold", "task_limit", "stt_hold"] {
                if let raw = settings[key] as? String {
                    guard let value = boundedUnits(raw), value > 0 else { throw BackendFailure.rejected }
                    settings[key] = value
                }
            }
            _ = try await model.request(kind.rawValue + ".configure", fields: ["settings": settings, "revision": revision])
            dismiss()
        } catch BackendFailure.conflict { failure = .conflict }
        catch { failure = .saveFailed }
    }
}
