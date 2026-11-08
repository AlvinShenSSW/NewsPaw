import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct SourceDraft: Equatable {
    let id: String
    var name: String
    var url: String
    var kind: String
    var partition: String?
    var categoryIds: Set<String>
    var focus: String?
    var enabled: Bool

    init(_ source: AppConfig.Source?) {
        id = source?.id ?? "sources_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        name = source?.name ?? ""
        url = source?.url ?? ""
        kind = source?.kind ?? "draft"
        partition = source?.partition
        categoryIds = Set(source?.categoryIds ?? [])
        focus = source?.focus
        enabled = source?.enabled ?? false
    }

    var fields: [String: Any] {
        var result: [String: Any] = [
            "id": id, "name": name, "url": url, "kind": kind,
            "partition": partition.map { $0 as Any } ?? NSNull(),
            "category_ids": categoryIds.sorted(), "enabled": enabled,
        ]
        if let focus { result["focus"] = focus }
        return result
    }
}

private struct SourceSelection: Identifiable {
    let source: AppConfig.Source?
    var id: String { source?.id ?? "new-source" }
}

private struct SourceMutation: Decodable { let revision: Int }
private struct SourceCatalogEntry: Decodable, Identifiable {
    let id, name, url, kind, categoryId, partition: String
    let focus: String?
}
private struct SourceDiscovery: Decodable {
    struct Choice: Decodable, Identifiable {
        let url, kind, name: String
        let partition: String?
        let categoryIds: [String]?
        var id: String { url }
    }
    let kind: String
    let choices: [Choice]
}
private struct SourceTrial: Decodable {
    struct Attempt: Decodable {
        let status: String
        let acceptedCount: Int?
        let checkedAt: String?
        let coverageComplete: Bool?
    }
    struct Health: Decodable { let freshness: String }
    struct Entry: Decodable { let title: String; let publishedAt: String? }
    let attempt: Attempt
    let entries: [Entry]
    let previewReady: Bool
    let health: Health?
}
private struct SourceImpact: Decodable, Identifiable {
    struct Subscription: Decodable, Identifiable {
        let id, name: String
        let enabled: Bool
        let blockers: [String]
    }
    let revision: Int
    let action: String
    let subscriptions: [Subscription]
    var id: String { action }
}
private struct SourceImport: Decodable {
    struct Rejection: Decodable { let index: Int; let reason: String }
    let added, existing: [String]
    let rejected: [Rejection]
}

struct SourceWorkspace: View {
    let model: AppModel
    let sources: [AppConfig.Source]
    @State private var editor: SourceSelection?
    @State private var importing = false
    @State private var importResult: SourceImport?
    @State private var failure: Phrase?
    @State private var importRevision = 0

    private func label(_ key: SubscriptionCopy) -> String { key.text(model.uiLanguage) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(model.text(.sources)).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(label(.newSource)) { editor = SourceSelection(source: nil) }
                Button(label(.importOPML)) {
                    importRevision = model.configRevision
                    importing = true
                }
            }
            if sources.isEmpty {
                Text(model.text(.noSources)).foregroundStyle(.secondary)
            } else {
                ForEach(sources) { source in
                    Button { editor = SourceSelection(source: source) } label: {
                        HStack {
                            Text(source.name)
                            Spacer()
                            Text(source.kind).foregroundStyle(.secondary)
                            Text(model.text(source.enabled ? .enabled : .disabled))
                                .font(.caption).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").accessibilityHidden(true)
                        }
                        .padding(7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if let report = importResult {
                Text("\(label(.added)) \(report.added.count) · \(label(.duplicate)) \(report.existing.count) · \(label(.rejected)) \(report.rejected.count)")
            }
            if let failure { Text(model.text(failure)).foregroundStyle(.secondary) }
        }
        .sheet(item: $editor) { selection in SourceEditor(model: model, source: selection.source) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "opml") ?? .xml, .xml]) { result in
            Task { await importFile(result) }
        }
    }

    private func importFile(_ result: Result<URL, Error>) async {
        failure = nil
        importResult = nil
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let limit = 1024 * 1024
            guard let data = try file.read(upToCount: limit + 1), data.count <= limit,
                  let text = String(data: data, encoding: .utf8) else { throw BackendFailure.invalidReply }
            importResult = try BackendRPC.decode(await model.request(
                "sources.import_opml", fields: ["content": text, "revision": importRevision]
            ))
            await model.refresh()
        } catch BackendFailure.conflict {
            failure = .conflict
        } catch {
            failure = .saveFailed
        }
    }
}

private struct SourceEditor: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SourceDraft
    @State private var saved: SourceDraft?
    @State private var revision: Int
    @State private var catalog: [SourceCatalogEntry] = []
    @State private var discovery: SourceDiscovery?
    @State private var trial: SourceTrial?
    @State private var impact: SourceImpact?
    @State private var showImpact = false
    @State private var failure: Phrase?
    @State private var busy = false

    init(model: AppModel, source: AppConfig.Source?) {
        self.model = model
        let current = SourceDraft(source)
        _draft = State(initialValue: current)
        _saved = State(initialValue: source == nil ? nil : current)
        _revision = State(initialValue: model.configRevision)
    }

    private func label(_ key: SubscriptionCopy) -> String { key.text(model.uiLanguage) }
    private var categories: [AppConfig.Category] { model.config?.categories ?? [] }
    private var isRegional: Bool { !draft.categoryIds.isDisjoint(with: ["japan", "australia", "china"]) }

    var body: some View {
        VStack {
            Form {
                Section(label(.sourceList)) {
                    TextField(label(.sourceURL), text: $draft.url)
                    TextField(label(.name), text: $draft.name)
                    Picker(label(.sourceType), selection: $draft.kind) {
                        ForEach(["draft", "rss", "atom", "web", "github", "huggingface"], id: \.self) {
                            Text($0 == "draft" ? label(.neutral) : $0).tag($0)
                        }
                    }
                    HStack {
                        Button(label(.catalog)) { Task { await readCatalog() } }
                        Button(label(.discover)) { Task { await discover() } }
                            .disabled(draft.url.isEmpty)
                    }
                    if !catalog.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(catalog) { row in
                                    Button(row.name) { use(row) }
                                }
                            }
                        }
                        .frame(maxHeight: 125)
                    }
                    if let discovery {
                        if discovery.choices.isEmpty {
                            Text(label(discovery.kind == "x" ? .xDestination : .unsupported))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(discovery.choices) { choice in
                            Button(choice.name) { use(choice) }
                        }
                    }
                }
                .disabled(draft.enabled)
                Section(model.text(.categories)) {
                    ForEach(categories.filter { draft.partition == nil || $0.partition == draft.partition }) { category in
                        Toggle(category.name, isOn: Binding(
                            get: { draft.categoryIds.contains(category.id) },
                            set: { setCategory(category, enabled: $0) }
                        ))
                    }
                    if isRegional {
                        Picker(label(.weighted), selection: $draft.focus) {
                            Text(label(.neutral)).tag(nil as String?)
                            Text(label(.domestic)).tag("domestic" as String?)
                            Text(label(.entertainment)).tag("entertainment" as String?)
                        }
                    }
                }
                .disabled(draft.enabled)
                if let trial, draft == saved {
                    Section(label(.trial)) {
                        Text(label(trial.previewReady ? .previewPassed : .previewUnavailable))
                        Text(label(trial.health?.freshness == "current" ? .current : trial.health?.freshness == "stale" ? .stale : .unknownFreshness))
                        if trial.attempt.coverageComplete == false { Text(label(.partialCoverage)) }
                        Text("\(label(.accepted)) · \(trial.attempt.acceptedCount ?? 0)")
                        if let checked = trial.attempt.checkedAt { Text(checked).font(.caption) }
                        ForEach(Array(trial.entries.prefix(5).enumerated()), id: \.offset) { _, entry in
                            VStack(alignment: .leading) {
                                Text(entry.title)
                                if let published = entry.publishedAt {
                                    Text(published).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if let failure { Text(model.text(failure)).foregroundStyle(.secondary) }
            }
            .formStyle(.grouped)
            HStack {
                Button(label(.dismiss)) { dismiss() }
                Spacer()
                if saved != nil {
                    Button(label(.trial)) { Task { await preview() } }.disabled(draft != saved)
                    if draft.enabled {
                        Button(label(.pause)) { Task { await review("pause") } }
                    }
                    Button(label(.remove), role: .destructive) { Task { await review("delete") } }
                }
                if !draft.enabled {
                    Button(label(.saveSource)) { Task { await save(enabled: false) } }
                        .disabled(draft.name.isEmpty || draft.url.isEmpty)
                    if trial?.previewReady == true && draft == saved {
                        Button(label(.enableSource)) { Task { await save(enabled: true) } }
                    }
                }
            }
            .padding()
        }
        .frame(minWidth: 640, minHeight: 560)
        .disabled(busy)
        .confirmationDialog(label(.impact), isPresented: $showImpact, presenting: impact) { preview in
            Button(label(preview.action == "delete" ? .remove : .pause), role: .destructive) {
                Task { await apply(preview) }
            }
        } message: { preview in
            let rows = preview.subscriptions.map {
                $0.name + " · " + ($0.enabled && $0.blockers.isEmpty ? label(.ready) : label(.needsReview))
            }
            Text(rows.isEmpty ? label(.none) : rows.joined(separator: "\n"))
        }
    }

    private func setCategory(_ category: AppConfig.Category, enabled: Bool) {
        if enabled {
            draft.partition = category.partition
            draft.categoryIds.insert(category.id)
        } else {
            draft.categoryIds.remove(category.id)
            if draft.categoryIds.isEmpty { draft.partition = nil }
        }
        if !isRegional { draft.focus = nil }
    }

    private func use(_ row: SourceCatalogEntry) {
        draft.name = row.name
        draft.url = row.url
        draft.kind = row.kind
        draft.partition = row.partition
        draft.categoryIds = [row.categoryId]
        draft.focus = row.focus
        catalog = []
        discovery = nil
    }

    private func use(_ choice: SourceDiscovery.Choice) {
        draft.name = choice.name
        draft.url = choice.url
        draft.kind = choice.kind
        if let partition = choice.partition {
            draft.partition = partition
            draft.categoryIds = Set(choice.categoryIds ?? [])
        }
        if !isRegional { draft.focus = nil }
        discovery = nil
    }

    private func perform(_ work: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        failure = nil
        defer { busy = false }
        do {
            try await work()
        } catch BackendFailure.conflict {
            failure = .conflict
        } catch {
            failure = .saveFailed
        }
    }

    private func readCatalog() async {
        await perform {
            catalog = try BackendRPC.decode(await model.request("sources.catalog"))
        }
    }

    private func discover() async {
        await perform {
            discovery = try BackendRPC.decode(await model.request("sources.discover", fields: ["url": draft.url]))
            if discovery?.kind == "draft" { draft.kind = "draft" }
        }
    }

    private func save(enabled: Bool) async {
        await perform {
            var target = draft
            target.enabled = enabled
            let result: SourceMutation = try BackendRPC.decode(await model.request(
                "sources.save", fields: ["source": target.fields, "revision": revision]
            ))
            draft = target
            saved = target
            revision = result.revision
            if !enabled { trial = nil }
            await model.refresh()
        }
    }

    private func preview() async {
        await perform {
            trial = nil
            trial = try BackendRPC.decode(await model.request("sources.preview", fields: ["source_id": draft.id]))
        }
    }

    private func review(_ action: String) async {
        await perform {
            impact = try BackendRPC.decode(await model.request(
                "sources.impact", fields: ["source_id": draft.id, "action": action]
            ))
            showImpact = true
        }
    }

    private func apply(_ preview: SourceImpact) async {
        await perform {
            if preview.action == "delete" {
                _ = try await model.request("sources.delete", fields: ["source_id": draft.id, "revision": preview.revision])
                await model.refresh()
                dismiss()
            } else if var target = saved, preview.revision == revision {
                target.enabled = false
                let result: SourceMutation = try BackendRPC.decode(await model.request(
                    "sources.save", fields: ["source": target.fields, "revision": preview.revision]
                ))
                draft = target
                saved = target
                revision = result.revision
                trial = nil
                await model.refresh()
            } else {
                throw BackendFailure.conflict
            }
        }
    }
}
