import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Backend shapes

struct SourceItem: Decodable, Identifiable, Equatable {
    struct Source: Decodable, Equatable {
        let id, name, url, kind: String
        let partition: String?
        let categoryIds: [String]
        let enabled: Bool
        let focus: String?
    }
    struct Health: Decodable, Equatable {
        struct Attempt: Decodable, Equatable { let status: String }
        let freshness: String
        let latestPublication: String?
        let lastAttempt: Attempt?
    }
    let source: Source
    let health: Health?
    let previewReady: Bool
    var id: String { source.id }
}

struct CatalogEntry: Decodable, Identifiable, Equatable {
    let id, name, url, kind, categoryId, partition, connection: String
    let focus: String?
}

struct Discovery: Decodable {
    struct Choice: Decodable, Equatable { let url, kind: String; let name: String? }
    let choices: [Choice]
}

struct DigestPreview: Decodable, Equatable {
    struct Source: Decodable, Equatable { let id, name: String; let ready: Bool }
    let blockers: [String]
    let bots: [String]
    let sources: [Source]
}

struct OPMLImport: Decodable, Equatable {
    private struct Skipped: Decodable { init(from decoder: Decoder) {} }
    let added: [String]
    let existing: [String]
    let rejected: Int

    private enum Keys: String, CodingKey { case added, existing, rejected }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        added = try values.decode([String].self, forKey: .added)
        existing = try values.decode([String].self, forKey: .existing)
        rejected = try values.decode([Skipped].self, forKey: .rejected).count
    }
}

private struct Trial: Decodable {
    struct Attempt: Decodable { let status: String }
    struct Entry: Decodable { let publishedAt: String? }
    let attempt: Attempt
    let entries: [Entry]
    let previewReady: Bool
}

private struct Impact: Decodable {
    struct Subscription: Decodable { let id: String; let wasEnabled, enabled: Bool }
    let subscriptions: [Subscription]
}

extension AppConfig.Subscription {
    /// Mirrors `uses_category_sources`: a digest follows its category unless it lists its own sources.
    var followsCategory: Bool {
        (sourceMode ?? ((sourceIds ?? []).isEmpty ? "category" : "explicit")) == "category"
    }
}

// MARK: - State and actions

/// Everything the digests page edits. Every save applies its change to the newest stored
/// record (EditorState), so a background change is merged, never overwritten.
@MainActor @Observable
final class DigestsData {
    private(set) var sources: [SourceItem] = []
    private(set) var catalog: [CatalogEntry] = []
    private(set) var today: [String: Occurrence] = [:]
    private(set) var newspaperReady = false
    private(set) var working: Set<String> = []
    private(set) var failures: [String: BackendError] = [:]
    private(set) var notes: [String: String] = [:]
    private(set) var savedAt: [String: Date] = [:]
    private(set) var previews: [String: DigestPreview] = [:]
    private(set) var sent: Set<String> = []
    private(set) var impacts: [String: [String]] = [:]
    var imported: OPMLImport?

    func load(_ client: BackendClient, now: Date = Date()) async {
        do {
            sources = try BackendRPC.decode(await client.call(.sourcesList))
            if catalog.isEmpty { catalog = try BackendRPC.decode(await client.call(.sourcesCatalog)) }
            struct Rows: Decodable { let occurrences: [Occurrence] }
            let rows: Rows = try BackendRPC.decode(await client.call(.scheduleStatus, ["limit": 100]))
            let day = OverviewData.day(now)
            today = Dictionary(rows.occurrences.filter { $0.civilDate == day && $0.accountId == nil }
                .sorted { ($0.targetAt ?? "") < ($1.targetAt ?? "") }.map { ($0.subscriptionId, $0) }) { earlier, later in
                // The row shows the edition that matters now: the next one still to come, else the last.
                earlier.status == "planned" ? earlier : later
            }
            struct Paper: Decodable {
                struct Settings: Decodable { let enabled: Bool; let generationProfile: String? }
                let settings: Settings
            }
            let paper: Paper = try BackendRPC.decode(await client.call(.newspaperPolicy))
            newspaperReady = paper.settings.enabled && paper.settings.generationProfile != nil
        } catch {
            // The page keeps the last good lists; each action reports its own failure.
        }
    }

    /// Sources shown under a digest: its category's sources, plus any it lists by id.
    func listed(_ subscription: AppConfig.Subscription) -> [SourceItem] {
        let own = Set(subscription.sourceIds ?? [])
        return sources.filter { $0.source.categoryIds.contains(subscription.categoryId) || own.contains($0.id) }
    }

    /// Whether the digest collects from this source now.
    func included(_ item: SourceItem, in subscription: AppConfig.Subscription) -> Bool {
        guard item.source.enabled else { return false }
        return subscription.followsCategory || (subscription.sourceIds ?? []).contains(item.id)
    }

    /// The editable draft of a stored subscription, as `subscriptions.save` expects it.
    nonisolated static func draft(_ stored: [String: Any]) -> [String: Any] {
        var draft = stored
        draft.removeValue(forKey: "enabled")
        if draft["source_mode"] == nil {
            draft["source_mode"] = ((stored["source_ids"] as? [String]) ?? []).isEmpty ? "category" : "explicit"
        }
        return draft
    }

    /// Applies `change` to the newest stored draft of `id` and saves it, keeping its on/off
    /// state unless `enable` says otherwise.
    @discardableResult
    func save(_ id: String, model: AppModel, enable: Bool? = nil, change: EditorState.Change = { $0 }) async -> Bool {
        let client = model.client
        var enabled = false
        let editor = EditorState(
            load: {
                let current = try await client.configDocument()
                let subscriptions = current.document["subscriptions"] as? [[String: Any]] ?? []
                guard let stored = subscriptions.first(where: { $0["id"] as? String == id }) else {
                    throw BackendError(code: "missing_subscription")
                }
                enabled = stored["enabled"] as? Bool ?? false
                return (current.revision, Self.draft(stored))
            },
            store: { draft, revision in
                _ = try await client.call(.subscriptionsSave, ["draft": draft, "revision": revision, "enable": enable ?? enabled])
            }
        )
        working.insert(id)
        defer { working.remove(id) }
        let saved = await editor.apply(change)
        if saved {
            failures[id] = nil
            savedAt[id] = editor.savedAt
        } else if let failure = editor.failure {
            failures[id] = failure
            if failure.code == "subscription_not_ready" { await preview(id, model: model) }
        }
        await model.refresh()
        await load(model.client)
        return saved
    }

    /// What the next edition would use, and what still stops it (`subscriptions.preview`).
    func preview(_ id: String, model: AppModel) async {
        previews[id] = nil
        do {
            let current = try await model.client.configDocument()
            let subscriptions = current.document["subscriptions"] as? [[String: Any]] ?? []
            guard let stored = subscriptions.first(where: { $0["id"] as? String == id }) else { return }
            previews[id] = try BackendRPC.decode(await model.client.call(.subscriptionsPreview, [
                "draft": Self.draft(stored), "revision": current.revision,
            ]))
        } catch let error as BackendError {
            failures[id] = error
        } catch {
            failures[id] = BackendError(code: "invalid_reply")
        }
    }

    /// Turning a digest on (interaction-spec §5.2): bring in the category's recommended
    /// sources when it has none, choose the only usable Bot when none is chosen, then enable.
    @discardableResult
    func turnOn(_ subscription: AppConfig.Subscription, model: AppModel) async -> Bool {
        if listed(subscription).isEmpty {
            for entry in catalog where entry.categoryId == subscription.categoryId && entry.connection != "adapter_required" {
                await addSource(name: entry.name, url: entry.url, kind: entry.kind, focus: entry.focus, to: subscription, model: model)
            }
        }
        let usable = model.usableBots(for: subscription.categoryId)
        return await save(subscription.id, model: model, enable: true) { draft in
            var draft = draft
            if (draft["bot_ids"] as? [String] ?? []).isEmpty, usable.count == 1 { draft["bot_ids"] = usable }
            return draft
        }
    }

    /// Adds a source to the digest's category as an inactive draft and tries it once; a
    /// working source is enabled (and, for a digest with its own list, added to it).
    func addSource(name: String, url: String, kind: String, focus: String?, to subscription: AppConfig.Subscription, model: AppModel) async {
        let category = subscription.categoryId
        let id = "src_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let partition = model.config?.categories.first { $0.id == category }?.partition ?? "normal"
        var source: [String: Any] = [
            "id": id, "name": name, "url": url, "kind": kind, "partition": partition,
            "category_ids": [category], "enabled": false,
        ]
        if let focus { source["focus"] = focus }
        working.insert(category)
        defer { working.remove(category) }
        do {
            try await saveSource(source, model: model)
            failures[category] = nil
        } catch {
            failures[category] = error as? BackendError ?? BackendError(code: "invalid_reply")
            return
        }
        await load(model.client)
        if await trial(id, model: model), !subscription.followsCategory {
            await include(id, in: subscription.id, true, model: model)
        }
    }

    /// Tries a source (`sources.preview`). A source that is not on yet is turned on when the
    /// try worked. Returns whether the source is now on.
    @discardableResult
    func trial(_ id: String, model: AppModel) async -> Bool {
        working.insert(id)
        defer { working.remove(id) }
        notes[id] = nil
        do {
            let result: Trial = try BackendRPC.decode(await model.client.call(.sourcesPreview, ["source_id": id]))
            let latest = result.entries.compactMap(\.publishedAt).max()
            failures[id] = nil
            if ["failed", "rate_limited", "timeout", "unsupported"].contains(result.attempt.status) {
                failures[id] = BackendError(code: result.attempt.status, domain: "sources")
            } else {
                note(id, L10n.Digests.trialResult(model.uiLanguage, [
                    "count": String(result.entries.count), "time": OverviewData.clock(latest),
                ]))
            }
            if result.previewReady, failures[id] == nil, let stored = sources.first(where: { $0.id == id }), !stored.source.enabled {
                try await setSource(id, enabled: true, model: model)
            }
        } catch {
            failures[id] = error as? BackendError ?? BackendError(code: "invalid_reply")
        }
        await load(model.client)
        return sources.first { $0.id == id }?.source.enabled == true
    }

    /// A trial result stays under its row for five seconds, then folds into the status dot.
    private func note(_ id: String, _ text: String) {
        notes[id] = text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if self?.notes[id] == text { self?.notes[id] = nil }
        }
    }

    /// The source checkbox: a digest that follows its category turns the source itself on or
    /// off; a digest with its own list adds or removes it there.
    func toggle(_ item: SourceItem, in subscription: AppConfig.Subscription, _ on: Bool, model: AppModel) async {
        do {
            if on, !item.source.enabled {
                guard await trial(item.id, model: model) else { return }
            } else if subscription.followsCategory {
                try await setSource(item.id, enabled: on, model: model)
            }
            if !subscription.followsCategory { await include(item.id, in: subscription.id, on, model: model) }
        } catch {
            failures[item.id] = error as? BackendError ?? BackendError(code: "invalid_reply")
        }
        await load(model.client)
        await model.refresh()
    }

    private func include(_ source: String, in subscription: String, _ on: Bool, model: AppModel) async {
        await save(subscription, model: model) { draft in
            var draft = draft
            var ids = draft["source_ids"] as? [String] ?? []
            ids.removeAll { $0 == source }
            if on { ids.append(source) }
            draft["source_ids"] = ids
            draft["source_mode"] = "explicit"
            return draft
        }
    }

    func setSource(_ id: String, enabled: Bool, model: AppModel) async throws {
        let current = try await model.client.configDocument()
        guard var source = (current.document["sources"] as? [[String: Any]])?.first(where: { $0["id"] as? String == id }) else {
            throw BackendError(code: "missing_source", domain: "sources")
        }
        source["enabled"] = enabled
        try await saveSource(source, model: model)
    }

    /// Saves one source against the newest revision, retrying once after a conflict.
    private func saveSource(_ source: [String: Any], model: AppModel) async throws {
        for attempt in 0..<2 {
            let revision = try await model.client.configDocument().revision
            do {
                _ = try await model.client.call(.sourcesSave, ["source": source, "revision": revision])
                return
            } catch let error as BackendError where error.isConflict && attempt == 0 {
                continue
            }
        }
    }

    /// The digests a removal would turn off, named in the confirmation (`sources.impact`).
    func loadImpact(_ id: String, model: AppModel) async {
        impacts[id] = nil
        guard let impact: Impact = try? BackendRPC.decode(await model.client.call(.sourcesImpact, ["source_id": id, "action": "delete"])) else { return }
        impacts[id] = impact.subscriptions.filter { $0.wasEnabled && !$0.enabled }.map { model.digestTitle($0.id) }
    }

    func removeSource(_ id: String, model: AppModel) async {
        working.insert(id)
        defer { working.remove(id) }
        do {
            let revision = try await model.client.configDocument().revision
            _ = try await model.client.call(.sourcesDelete, ["source_id": id, "revision": revision])
            failures[id] = nil
        } catch {
            failures[id] = error as? BackendError ?? BackendError(code: "invalid_reply")
        }
        await load(model.client)
        await model.refresh()
    }

    func importOPML(_ content: String, model: AppModel) async -> BackendError? {
        do {
            let revision = try await model.client.configDocument().revision
            imported = try BackendRPC.decode(await model.client.call(.sourcesImportOPML, ["content": content, "revision": revision]))
            await load(model.client)
            return nil
        } catch {
            return error as? BackendError ?? BackendError(code: "invalid_reply")
        }
    }

    /// Imported feeds arrive unclassified; this files them under one digest's category as
    /// inactive drafts, to be tried there before they are used (interaction-spec §5.5).
    func file(_ ids: [String], under category: String, model: AppModel) async -> BackendError? {
        let partition = model.config?.categories.first { $0.id == category }?.partition ?? "normal"
        let editor = EditorState(client: model.client)
        let wanted = Set(ids)
        await editor.apply { document in
            var document = document
            document["sources"] = (document["sources"] as? [[String: Any]] ?? []).map { source in
                guard let id = source["id"] as? String, wanted.contains(id), (source["category_ids"] as? [String] ?? []).isEmpty else { return source }
                var source = source
                source["partition"] = partition
                source["category_ids"] = [category]
                source["enabled"] = false
                return source
            }
            return document
        }
        imported = nil
        await load(model.client)
        await model.refresh()
        return editor.failure
    }

    /// Splits a regional digest in two (interaction-spec §5.7): the copy takes the
    /// entertainment sources, the original keeps the rest, and the copy starts off.
    func split(_ subscription: AppConfig.Subscription, model: AppModel) async -> String? {
        let id = "sub_" + String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(20))
        let items = listed(subscription)
        let entertainment = items.filter { $0.source.focus == "entertainment" }.map(\.id)
        let rest = items.filter { $0.source.focus != "entertainment" }.map(\.id)
        let title = model.digestTitle(subscription.id)
        let names = (title, title + " · " + model.text(L10n.Digests.entertainmentTag))
        let editor = EditorState(client: model.client)
        let saved = await editor.apply { document in
            var document = document
            var subscriptions = document["subscriptions"] as? [[String: Any]] ?? []
            guard let index = subscriptions.firstIndex(where: { $0["id"] as? String == subscription.id }) else {
                throw BackendError(code: "missing_subscription")
            }
            var copy = subscriptions[index]
            copy["id"] = id
            copy["name"] = names.1
            copy["enabled"] = false
            copy.removeValue(forKey: "focus_weights")
            subscriptions[index]["name"] = names.0
            if !entertainment.isEmpty, !rest.isEmpty {
                subscriptions[index]["source_mode"] = "explicit"
                subscriptions[index]["source_ids"] = rest
                subscriptions[index].removeValue(forKey: "focus_weights")
                copy["source_mode"] = "explicit"
                copy["source_ids"] = entertainment
            }
            subscriptions.append(copy)
            document["subscriptions"] = subscriptions
            return document
        }
        if !saved { failures[subscription.id] = editor.failure }
        await model.refresh()
        await load(model.client)
        return saved ? id : nil
    }

    /// Merges a split digest back: it is removed, and the one left follows its category again.
    func merge(_ subscription: AppConfig.Subscription, model: AppModel) async {
        let editor = EditorState(client: model.client)
        let saved = await editor.apply { document in
            var document = document
            var subscriptions = (document["subscriptions"] as? [[String: Any]] ?? []).filter { $0["id"] as? String != subscription.id }
            let remaining = subscriptions.indices.filter { subscriptions[$0]["category_id"] as? String == subscription.categoryId }
            if remaining.count == 1 {
                subscriptions[remaining[0]]["source_mode"] = "category"
                subscriptions[remaining[0]]["source_ids"] = [String]()
            }
            document["subscriptions"] = subscriptions
            return document
        }
        if !saved { failures[subscription.id] = editor.failure }
        await model.refresh()
        await load(model.client)
    }

    func sendNow(_ id: String, model: AppModel) async {
        working.insert(id)
        defer { working.remove(id) }
        if await model.sendNow(id) { sent.insert(id) }
        await load(model.client)
    }

    func reportFailure(_ key: String, _ error: BackendError?) { failures[key] = error }
}

extension AppModel {
    /// Paired, unpaused Bots that may receive this category (adult needs an adult-allowed Bot).
    func usableBots(for category: String) -> [String] {
        let adult = config?.categories.first { $0.id == category }?.partition == "adult"
        let allowed = Set((config?.bots ?? []).filter { !adult || $0.adultAllowed }.map(\.id))
        return bots.filter { $0.paired && !$0.paused && allowed.contains($0.id) }.map(\.id)
    }

    /// The adult model group has a primary model with a saved key.
    var adultModelReady: Bool {
        config?.modelProfiles.contains { $0.partition == "adult" && $0.role == "primary" && $0.credentialRef != nil } ?? false
    }

    /// "→ @bot", or "→ 2 Bots" when there are several.
    func botsPhrase(_ ids: [String]) -> String? {
        switch ids.count {
        case 0: nil
        case 1: "→ " + (bots.first { $0.id == ids[0] }.flatMap { $0.username.map { "@" + $0 } ?? $0.name } ?? ids[0])
        default: "→ " + L10n.Digests.botCount(uiLanguage, ["count": String(ids.count)])
        }
    }
}

/// Send times as the stepper edits them: wall-clock "HH:mm" values held as UTC dates, so
/// the editor's time zone never shifts them.
enum DigestTimes {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func parse(_ value: String) -> Date? { formatter.date(from: value) }
    static func format(_ date: Date) -> String { formatter.string(from: date) }

    /// The stored form: unique and in order, so a repeated time is sent once.
    static func stored(_ times: [Date]) -> [String] { Array(Set(times.map(format))).sorted() }

    /// "＋ Add a time" proposes one hour after the last time (08:00 when there is none).
    static func next(after last: Date?) -> Date {
        guard let last else { return parse("08:00")! }
        return parse(format(last.addingTimeInterval(3_600)))!
    }
}

/// The next send time of a digest, as "today 08:00" / "tomorrow 08:00" in its own time zone.
enum NextSend {
    static func text(times: [String], zone: String, now: Date, _ language: AppLanguage) -> String? {
        guard let tz = TimeZone(identifier: zone) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let parts = times.compactMap { time -> (Int, Int)? in
            let pieces = time.split(separator: ":").compactMap { Int($0) }
            return pieces.count == 2 ? (pieces[0], pieces[1]) : nil
        }.sorted { $0 < $1 }
        guard !parts.isEmpty else { return nil }
        let clock = calendar.dateComponents([.hour, .minute], from: now)
        let current = (clock.hour ?? 0, clock.minute ?? 0)
        if let next = parts.first(where: { $0 > current }) {
            return L10n.Digests.today(language, ["time": String(format: "%02d:%02d", next.0, next.1)])
        }
        return L10n.Digests.tomorrow(language, ["time": String(format: "%02d:%02d", parts[0].0, parts[0].1)])
    }
}

// MARK: - Page

struct DigestsPage: View {
    let model: AppModel
    let config: AppConfig
    @State private var data = DigestsData()
    @State private var expanded: String?
    @State private var importing = false
    @State private var importFailure: BackendError?

    init(model: AppModel, config: AppConfig, expanded: String? = nil) {
        self.model = model
        self.config = config
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.text(L10n.Digests.intro)).font(.callout).foregroundStyle(.secondary)
            if let importFailure { FailureNote(model: model, failure: importFailure) }
            if model.usableBots(for: "world").isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "paperplane").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(model.text(L10n.Digests.needsBot))
                    Spacer()
                    Button(model.text(L10n.Digests.completeSetup)) { model.page = .connect }
                }
                .font(.callout)
                .padding(10)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            ForEach(ordered) { subscription in
                DigestRow(model: model, data: data, subscription: subscription,
                          expanded: Binding(get: { expanded == subscription.id },
                                            set: { expanded = $0 ? subscription.id : nil }),
                          reveal: { expanded = $0 })
            }
        }
        .task(id: model.configRevision) { await data.load(model.client) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    importing = true
                } label: {
                    Label(model.text(L10n.Digests.importOPML), systemImage: "square.and.arrow.down")
                }
                .help(model.text(L10n.Digests.importOPML))
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "opml") ?? .xml, .xml]) { result in
            guard case let .success(url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                importFailure = BackendError(code: "invalid_opml", domain: "sources")
                return
            }
            Task { importFailure = await data.importOPML(content, model: model) }
        }
        .sheet(isPresented: Binding(get: { data.imported != nil }, set: { if !$0 { data.imported = nil } })) {
            if let result = data.imported {
                ImportResult(model: model, data: data, result: result, choices: ordered) { importFailure = $0 }
            }
        }
    }

    private var ordered: [AppConfig.Subscription] {
        let order = Dictionary(uniqueKeysWithValues: config.categories.enumerated().map { ($1.id, $0) })
        return config.subscriptions.sorted { (order[$0.categoryId] ?? 99, $0.id) < (order[$1.categoryId] ?? 99, $1.id) }
    }
}

private struct ImportResult: View {
    let model: AppModel
    let data: DigestsData
    let result: OPMLImport
    let choices: [AppConfig.Subscription]
    let failed: (BackendError?) -> Void
    @State private var category = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.text(L10n.Digests.importOPML)).font(.headline)
            Text(L10n.Digests.importSummary(model.uiLanguage, [
                "added": String(result.added.count), "existing": String(result.existing.count), "rejected": String(result.rejected),
            ]))
            if !result.added.isEmpty {
                Picker(model.text(L10n.Digests.importInto), selection: $category) {
                    ForEach(categories, id: \.self) { id in
                        Text(model.digestTitle(choices.first { $0.categoryId == id }?.id ?? id)).tag(id)
                    }
                }
                .fixedSize()
                Text(model.text(L10n.Digests.importNote)).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if result.added.isEmpty {
                    Button(model.text(L10n.Digests.done)) { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button(model.text(L10n.Digests.later)) { dismiss() }
                    Button(model.text(L10n.Digests.add)) {
                        Task { failed(await data.file(result.added, under: category, model: model)) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(category.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { category = categories.first ?? "" }
    }

    /// Ordinary categories only: feeds from a file are never filed as adult content here.
    private var categories: [String] {
        let ordinary = Set(model.config?.categories.filter { $0.partition == "normal" && !["x", "x_adult"].contains($0.id) }.map(\.id) ?? [])
        var seen = Set<String>()
        return choices.map(\.categoryId).filter { ordinary.contains($0) && seen.insert($0).inserted }
    }
}

private struct DigestRow: View {
    let model: AppModel
    let data: DigestsData
    let subscription: AppConfig.Subscription
    @Binding var expanded: Bool
    let reveal: (String) -> Void
    @State private var confirmOff = false

    private var category: AppConfig.Category? { model.config?.categories.first { $0.id == subscription.categoryId } }
    private var adult: Bool { category?.partition == "adult" }
    private var missing: Words? {
        guard !subscription.enabled else { return nil }
        if adult, !model.adultModelReady || model.usableBots(for: subscription.categoryId).isEmpty { return L10n.Digests.needsAdultSetup }
        if model.usableBots(for: subscription.categoryId).isEmpty { return L10n.Digests.needsBot }
        return nil
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                header
                if expanded {
                    Divider().padding(.vertical, 8)
                    DigestEditor(model: model, data: data, subscription: subscription, pause: { confirmOff = true }, reveal: reveal)
                }
            }
            .padding(4)
        }
        .overlay {
            if expanded { RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 1) }
        }
        .confirmationDialog(L10n.Digests.offTitle(model.uiLanguage, ["name": model.digestTitle(subscription.id)]), isPresented: $confirmOff) {
            Button(model.text(L10n.Digests.turnOff)) { Task { await data.save(subscription.id, model: model, enable: false) } }
            Button(model.text(L10n.Shell.cancel), role: .cancel) {}
        } message: {
            Text(offBody)
        }
    }

    private var offBody: String {
        if let occurrence = data.today[subscription.id], ["planned", "preparing", "late"].contains(occurrence.status) {
            return L10n.Digests.offBodyToday(model.uiLanguage, ["time": OverviewData.clock(occurrence.targetAt)])
        }
        return model.text(L10n.Digests.offBody)
    }

    private var header: some View {
        HStack(spacing: 12) {
            CategorySymbol(id: subscription.categoryId)
                .foregroundStyle(subscription.enabled ? (adult ? Color.purple : Color.accentColor) : Color.secondary)
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.digestTitle(subscription.id)).fontWeight(.medium)
                    if adult {
                        Text(model.text(L10n.Digests.adult)).font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.purple.opacity(0.15), in: Capsule()).foregroundStyle(.purple)
                    }
                }
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let occurrence = data.today[subscription.id] {
                let state = OccurrenceState(occurrence, paused: model.schedulingPaused, abandoned: false)
                HStack(spacing: 5) {
                    Circle().fill(state.dot).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text(model.text(state.title)).font(.caption)
                }
                .accessibilityElement(children: .combine)
            }
            if missing == L10n.Digests.needsAdultSetup {
                Button(model.text(L10n.Digests.completeSetup)) { model.page = .connect }.buttonStyle(.link)
            }
            if data.working.contains(subscription.id) { ProgressView().controlSize(.small) }
            Toggle(model.text(L10n.Digests.enabled), isOn: Binding(
                get: { subscription.enabled },
                set: { on in
                    if on {
                        Task { if await data.turnOn(subscription, model: model) { reveal(subscription.id) } }
                    } else {
                        confirmOff = true
                    }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(missing != nil || data.working.contains(subscription.id))
            .accessibilityLabel(model.digestTitle(subscription.id))
            Button(model.text(expanded ? L10n.Digests.collapse : L10n.Digests.edit)) {
                withAnimation(.snappy) { expanded.toggle() }
            }
            .buttonStyle(.link)
        }
        .frame(minHeight: 36)
    }

    private var summary: String {
        let language = model.uiLanguage
        if let missing { return model.text(L10n.Digests.offPrefix) + " · " + model.text(missing) }
        let times = subscription.times.isEmpty ? "--:--" : subscription.times.joined(separator: "、")
        let target = model.botsPhrase(subscription.botIds ?? []) ?? model.text(L10n.Digests.noTarget)
        if !subscription.enabled {
            let count = data.listed(subscription).count
            let recommended = data.catalog.filter { $0.categoryId == subscription.categoryId && $0.connection != "adapter_required" }.count
            return L10n.Digests.offSummary(language, [
                "times": times,
                "sources": count > 0 ? L10n.Digests.sourceCount(language, ["count": String(count)])
                    : L10n.Digests.recommendedCount(language, ["count": String(recommended)]),
            ])
        }
        let count = data.listed(subscription).filter { data.included($0, in: subscription) }.count
        var parts = [L10n.Digests.everyDay(language, ["times": times]) + " " + target,
                     L10n.Digests.sourceCount(language, ["count": String(count)])]
        if let next = NextSend.text(times: subscription.times, zone: subscription.timezone, now: Date(), language) {
            parts.append(L10n.Digests.next(language, ["when": next]))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Inline editor

private enum PreviewMode { case preview, send }

private struct DigestEditor: View {
    let model: AppModel
    let data: DigestsData
    let subscription: AppConfig.Subscription
    let pause: () -> Void
    let reveal: (String) -> Void
    @State private var times: [Date] = []
    @State private var pending: Task<Void, Never>?
    @State private var ratio: Double = 50
    @State private var showZones = false
    @State private var showCatalog = false
    @State private var showPaste = false
    @State private var pasted = ""
    @State private var choices: [Discovery.Choice] = []
    @State private var discovering = false
    @State private var removing: SourceItem?
    @State private var confirmSplit = false
    @State private var confirmMerge = false
    @State private var popover: PreviewMode?

    private var regional: Bool { ["japan", "australia", "china"].contains(subscription.categoryId) }
    private var adult: Bool { model.config?.categories.first { $0.id == subscription.categoryId }?.partition == "adult" }
    private var siblings: [AppConfig.Subscription] {
        model.config?.subscriptions.filter { $0.categoryId == subscription.categoryId } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let failure = data.failures[subscription.id] {
                FailureNote(model: model, failure: failure)
                if let preview = data.previews[subscription.id], !preview.blockers.isEmpty {
                    blockers(preview.blockers)
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    label(L10n.Digests.times)
                    timesRow
                }
                GridRow {
                    label(L10n.Digests.sendTo)
                    botsRow
                }
                GridRow {
                    label(L10n.Digests.count)
                    HStack(spacing: 16) {
                        Picker(model.text(L10n.Digests.count), selection: Binding(
                            get: { subscription.maxItems ?? 5 },
                            set: { value in Task { await data.save(subscription.id, model: model) { var d = $0; d["max_items"] = value; return d } } }
                        )) {
                            ForEach([3, 5, 8, 10, 15], id: \.self) { Text(L10n.Digests.upTo(model.uiLanguage, ["count": String($0)])).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        Text(model.text(L10n.Digests.countNote)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    label(L10n.Digests.style)
                    styleRow
                }
                if regional {
                    GridRow {
                        label(L10n.Digests.ratio)
                        ratioRow
                    }
                }
            }
            sourcesTable
            DisclosureGroup(model.text(L10n.Digests.advanced)) { advanced.padding(.top, 6) }
            footer
        }
        .onAppear(perform: reset)
        .onChange(of: subscription.times) { reset() }
        .onChange(of: subscription.focusWeights) { reset() }
        .confirmationDialog(removing.map { L10n.Digests.removeTitle(model.uiLanguage, ["name": $0.source.name]) } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            if let item = removing {
                Button(model.text(L10n.Digests.remove), role: .destructive) { Task { await data.removeSource(item.id, model: model) } }
                Button(model.text(L10n.Shell.cancel), role: .cancel) {}
            }
        } message: {
            Text(removalBody)
        }
        .confirmationDialog(L10n.Digests.splitTitle(model.uiLanguage, ["name": model.digestTitle(subscription.id)]), isPresented: $confirmSplit) {
            Button(model.text(L10n.Digests.split)) {
                Task { if let id = await data.split(subscription, model: model) { reveal(id) } }
            }
            Button(model.text(L10n.Shell.cancel), role: .cancel) {}
        } message: {
            Text(model.text(L10n.Digests.splitBody))
        }
        .confirmationDialog(L10n.Digests.mergeTitle(model.uiLanguage, ["name": mergeTarget]), isPresented: $confirmMerge) {
            Button(model.text(L10n.Digests.merge), role: .destructive) { Task { await data.merge(subscription, model: model) } }
            Button(model.text(L10n.Shell.cancel), role: .cancel) {}
        } message: {
            Text(model.text(L10n.Digests.mergeBody))
        }
    }

    private var removalBody: String {
        guard let item = removing, let names = data.impacts[item.id], !names.isEmpty else { return model.text(L10n.Digests.removeBody) }
        return L10n.Digests.removeTurnsOff(model.uiLanguage, ["names": names.joined(separator: "、")])
    }

    private var mergeTarget: String {
        siblings.first { $0.id != subscription.id }.map { model.digestTitle($0.id) } ?? ""
    }

    private func label(_ words: Words) -> some View {
        Text(model.text(words)).foregroundStyle(.secondary)
            .frame(minWidth: 88, alignment: .trailing)
            .gridColumnAlignment(.trailing)
    }

    private func blockers(_ codes: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(codes, id: \.self) { code in
                Text("• " + FailureCopy.message(for: BackendError(code: code, domain: "subscriptions"), model.uiLanguage))
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private func reset() {
        times = subscription.times.compactMap(DigestTimes.parse)
        if let weights = subscription.focusWeights, let domestic = weights["domestic"], let other = weights["entertainment"], domestic + other > 0 {
            ratio = Double(domestic * 100 / (domestic + other))
        } else {
            ratio = 50
        }
    }

    /// Times save one second after the last change, so stepping does not save on every tick.
    private func saveTimes() {
        pending?.cancel()
        let values = DigestTimes.stored(times)
        pending = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await data.save(subscription.id, model: model) { var d = $0; d["times"] = values; return d }
        }
    }

    private var timesRow: some View {
        HStack(spacing: 8) {
            ForEach(times.indices, id: \.self) { index in
                HStack(spacing: 2) {
                    DatePicker(model.text(L10n.Digests.times), selection: Binding(
                        get: { times.indices.contains(index) ? times[index] : Date() },
                        set: { times[index] = $0; saveTimes() }
                    ), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.stepperField)
                    .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                    // 24-hour, matching the "08:30" in summaries and Telegram.
                    .environment(\.locale, Locale(identifier: "en_GB"))
                    if times.count > 1 {
                        Button {
                            times.remove(at: index)
                            saveTimes()
                        } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                            .help(model.text(L10n.Digests.removeTime))
                            .accessibilityLabel(model.text(L10n.Digests.removeTime))
                    }
                }
            }
            if times.count < 6 {
                Button(model.text(L10n.Digests.addTime)) {
                    times.append(DigestTimes.next(after: times.last))
                    saveTimes()
                }
            }
            Spacer(minLength: 8)
            Button(zoneLabel) { showZones = true }
                .buttonStyle(.link).font(.caption)
                .popover(isPresented: $showZones, arrowEdge: .bottom) {
                    TimeZonePicker(model: model, selected: subscription.timezone) { zone in
                        showZones = false
                        Task { await data.save(subscription.id, model: model) { var d = $0; d["timezone"] = zone; return d } }
                    }
                }
        }
    }

    private var zoneLabel: String {
        let system = subscription.timezone == TimeZone.current.identifier
        return L10n.Digests.zone(model.uiLanguage, [
            "zone": subscription.timezone + (system ? model.text(L10n.Digests.followsSystem) : ""),
        ])
    }

    private var botsRow: some View {
        let usable = model.usableBots(for: subscription.categoryId)
        let chosen = Set(subscription.botIds ?? [])
        let locked = usable.count == 1 && chosen == Set(usable)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                if model.bots.isEmpty {
                    Button(model.text(L10n.Digests.addBot)) { model.page = .connect }.buttonStyle(.link)
                }
                ForEach(model.bots) { bot in
                    let allowed = usable.contains(bot.id)
                    Toggle(isOn: Binding(
                        get: { chosen.contains(bot.id) },
                        set: { on in
                            Task {
                                await data.save(subscription.id, model: model) { draft in
                                    var draft = draft
                                    var ids = Set(draft["bot_ids"] as? [String] ?? [])
                                    if on { ids.insert(bot.id) } else { ids.remove(bot.id) }
                                    draft["bot_ids"] = ids.sorted()
                                    return draft
                                }
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(bot.username.map { "@" + $0 } ?? bot.name)
                            if !allowed {
                                Text(model.text(adult ? L10n.Digests.botNotAdult : L10n.Digests.botNotPaired))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled((!allowed && !chosen.contains(bot.id)) || (locked && chosen.contains(bot.id)))
                }
            }
            if locked {
                Text(model.text(L10n.Digests.onlyBot)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var styleRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(model.text(L10n.Digests.style), selection: Binding(
                get: { subscription.style ?? "text" },
                set: { value in
                    guard value != "newspaper" || data.newspaperReady else { return }
                    Task { await data.save(subscription.id, model: model) { var d = $0; d["style"] = value; return d } }
                }
            )) {
                Text(model.text(L10n.Digests.styleText)).tag("text")
                Text(model.text(L10n.Digests.styleImage)).tag("source_image")
                Text(model.text(L10n.Digests.stylePaper)).tag("newspaper")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if !data.newspaperReady {
                HStack(spacing: 4) {
                    Text(model.text(L10n.Digests.paperNeedsSetup)).foregroundStyle(.orange)
                    Button(model.text(L10n.Digests.goConnect)) { model.page = .connect }.buttonStyle(.link)
                }
                .font(.caption)
            }
        }
    }

    private var ratioRow: some View {
        HStack {
            Text(L10n.Digests.domestic(model.uiLanguage, ["value": String(Int(ratio))]))
                .font(.caption).monospacedDigit().frame(width: 84, alignment: .leading)
            Slider(value: $ratio, in: 0...100, step: 5) { editing in
                guard !editing else { return }
                let domestic = Int(ratio)
                Task {
                    await data.save(subscription.id, model: model) { var d = $0; d["focus_weights"] = ["domestic": domestic, "entertainment": 100 - domestic]; return d }
                }
            }
            .frame(maxWidth: 320)
            .accessibilityValue(L10n.Digests.domestic(model.uiLanguage, ["value": String(Int(ratio))]))
            Text(L10n.Digests.entertainment(model.uiLanguage, ["value": String(100 - Int(ratio))]))
                .font(.caption).monospacedDigit().frame(width: 84, alignment: .trailing)
        }
    }

    private var sourcesTable: some View {
        let items = data.listed(subscription)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.Digests.sourcesTitle(model.uiLanguage, ["count": String(items.filter { data.included($0, in: subscription) }.count)]))
                    .fontWeight(.medium)
                if data.working.contains(subscription.categoryId) { ProgressView().controlSize(.small) }
                Spacer()
                Button(model.text(L10n.Digests.fromCatalog)) { showCatalog = true }
                    .buttonStyle(.link)
                    .popover(isPresented: $showCatalog, arrowEdge: .bottom) { catalogPopover }
                Button(model.text(L10n.Digests.pasteLink)) {
                    pasted = ""
                    choices = []
                    showPaste = true
                }
                .buttonStyle(.link)
                .popover(isPresented: $showPaste, arrowEdge: .bottom) { pastePopover }
            }
            .padding(.vertical, 6)
            if let failure = data.failures[subscription.categoryId] { FailureNote(model: model, failure: failure) }
            if items.isEmpty {
                Text(model.text(L10n.Digests.noSources)).font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
            }
            ForEach(items) { item in
                Divider()
                SourceRow(model: model, data: data, item: item, subscription: subscription) {
                    removing = item
                    Task { await data.loadImpact(item.id, model: model) }
                }
            }
        }
    }

    private var catalogPopover: some View {
        let added = Set(data.sources.map(\.source.url))
        let entries = data.catalog.filter { $0.categoryId == subscription.categoryId && !added.contains($0.url) }
        return VStack(alignment: .leading, spacing: 8) {
            Text(model.text(L10n.Digests.fromCatalog)).font(.headline)
            if entries.isEmpty { Text(model.text(L10n.Digests.catalogEmpty)).foregroundStyle(.secondary) }
            ForEach(entries) { entry in
                HStack {
                    VStack(alignment: .leading) {
                        Text(entry.name)
                        Text(entryDetail(entry)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.text(L10n.Digests.add)) {
                        Task {
                            await data.addSource(name: entry.name, url: entry.url, kind: entry.kind, focus: entry.focus,
                                                 to: subscription, model: model)
                        }
                    }
                    .disabled(entry.connection == "adapter_required")
                }
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private func entryDetail(_ entry: CatalogEntry) -> String {
        if entry.connection == "adapter_required" { return model.text(L10n.Digests.notReadable) }
        var parts = [entry.kind.uppercased()]
        if let focus = entry.focus { parts.append(model.text(focus == "domestic" ? L10n.Digests.domesticTag : L10n.Digests.entertainmentTag)) }
        return parts.joined(separator: " · ")
    }

    private var pastePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(model.text(L10n.Digests.pastePlaceholder), text: $pasted)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await discover() } }
            if let failure = data.failures["discover." + subscription.id] {
                Text(FailureCopy.message(for: failure, model.uiLanguage)).font(.caption).foregroundStyle(.red)
            }
            ForEach(choices.indices, id: \.self) { index in
                let choice = choices[index]
                HStack {
                    VStack(alignment: .leading) {
                        Text(choice.name ?? choice.url).lineLimit(1)
                        Text(choice.kind.uppercased()).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.text(L10n.Digests.add)) {
                        showPaste = false
                        Task {
                            await data.addSource(name: choice.name ?? choice.url, url: choice.url, kind: choice.kind, focus: nil,
                                                 to: subscription, model: model)
                        }
                    }
                }
            }
            HStack {
                if discovering {
                    ProgressView().controlSize(.small)
                    Text(model.text(L10n.Digests.reading)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.text(L10n.Digests.identify)) { Task { await discover() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty || discovering)
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    private func discover() async {
        let key = "discover." + subscription.id
        discovering = true
        defer { discovering = false }
        data.reportFailure(key, nil)
        do {
            let found: Discovery = try BackendRPC.decode(await model.client.call(.sourcesDiscover, ["url": pasted.trimmingCharacters(in: .whitespaces)]))
            choices = found.choices
            if choices.isEmpty { data.reportFailure(key, BackendError(code: "unsupported_source", domain: "sources")) }
        } catch {
            choices = []
            data.reportFailure(key, error as? BackendError ?? BackendError(code: "invalid_reply"))
        }
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                modelPicker(L10n.Digests.primaryModel, key: "primary_profile_id", role: "primary", current: subscription.primaryProfileId)
                modelPicker(L10n.Digests.backupModel, key: "backup_profile_id", role: "backup", current: subscription.backupProfileId)
            }
            HStack(spacing: 10) {
                if siblings.count > 1, siblings.first?.id != subscription.id {
                    Button(L10n.Digests.mergeInto(model.uiLanguage, ["name": mergeTarget])) { confirmMerge = true }
                } else if regional, siblings.count == 1 {
                    Button(model.text(L10n.Digests.split)) { confirmSplit = true }
                }
                if subscription.enabled {
                    Button(model.text(L10n.Digests.pauseThis), action: pause)
                }
            }
        }
    }

    private func modelPicker(_ title: Words, key: String, role: String, current: String?) -> some View {
        let partition = adult ? "adult" : "normal"
        let profiles = model.config?.modelProfiles.filter { $0.partition == partition && $0.role == role } ?? []
        return Picker(model.text(title), selection: Binding(
            get: { current ?? "" },
            set: { value in Task { await data.save(subscription.id, model: model) { var d = $0; d[key] = value.isEmpty ? NSNull() : value; return d } } }
        )) {
            Text(model.text(L10n.Digests.defaultModel)).tag("")
            ForEach(profiles) { Text($0.model).tag($0.id) }
        }
        .fixedSize()
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let saved = data.savedAt[subscription.id] {
                Text(L10n.Shell.savedAt(model.uiLanguage, ["time": saved.formatted(date: .omitted, time: .shortened)]))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if data.sent.contains(subscription.id) {
                HStack(spacing: 4) {
                    Text(model.text(L10n.Digests.sent))
                    Button(model.text(L10n.Digests.view)) { model.page = .overview }.buttonStyle(.link)
                }
                .font(.caption)
            }
            Spacer()
            Button(model.text(L10n.Digests.preview)) { open(.preview) }
            Button(model.text(L10n.Overview.sendTrial)) { open(.send) }
                .buttonStyle(.borderedProminent)
                .disabled(!subscription.enabled || data.working.contains(subscription.id))
        }
        .popover(isPresented: Binding(get: { popover != nil }, set: { if !$0 { popover = nil } }), arrowEdge: .top) {
            previewPopover
        }
    }

    private func open(_ mode: PreviewMode) {
        popover = mode
        Task { await data.preview(subscription.id, model: model) }
    }

    private var previewPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.text(popover == .send ? L10n.Overview.sendTrial : L10n.Digests.preview)).font(.headline)
            if let preview = data.previews[subscription.id] {
                if preview.blockers.isEmpty {
                    let ready = preview.sources.filter(\.ready)
                    Text(L10n.Digests.previewReady(model.uiLanguage, [
                        "count": String(subscription.maxItems ?? 5),
                        "sources": String(ready.count),
                        "bots": model.botsPhrase(preview.bots) ?? "",
                    ]))
                    if popover == .preview {
                        Text(ready.map(\.name).joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    blockers(preview.blockers)
                }
                HStack {
                    Spacer()
                    if popover == .send, preview.blockers.isEmpty {
                        Button(model.text(L10n.Shell.cancel)) { popover = nil }
                        Button(model.text(L10n.Digests.send)) {
                            popover = nil
                            Task { await data.sendNow(subscription.id, model: model) }
                        }
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Button(model.text(L10n.Digests.done)) { popover = nil }.keyboardShortcut(.defaultAction)
                    }
                }
            } else if let failure = data.failures[subscription.id] {
                Text(FailureCopy.message(for: failure, model.uiLanguage)).foregroundStyle(.red)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

private struct SourceRow: View {
    let model: AppModel
    let data: DigestsData
    let item: SourceItem
    let subscription: AppConfig.Subscription
    let remove: () -> Void

    private var unverified: Bool { !item.previewReady && !item.source.enabled }
    private var unsupported: Bool { ["unsupported_source", "unsupported"].contains(data.failures[item.id]?.code ?? "") }

    var body: some View {
        HStack(spacing: 10) {
            Toggle(item.source.name, isOn: Binding(
                get: { data.included(item, in: subscription) },
                set: { on in Task { await data.toggle(item, in: subscription, on, model: model) } }
            ))
            .toggleStyle(.checkbox).labelsHidden()
            .disabled(unverified || unsupported || data.working.contains(item.id))
            Text(String(item.source.name.prefix(1)).uppercased())
                .font(.caption.bold()).foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.source.name).foregroundStyle(unverified ? .secondary : .primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if let note = data.notes[item.id] { Text(note).font(.caption).foregroundStyle(.secondary) }
                if let failure = data.failures[item.id], !unsupported {
                    Text(FailureCopy.message(for: failure, model.uiLanguage)).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            if data.working.contains(item.id) {
                ProgressView().controlSize(.small)
                Text(model.text(L10n.Digests.reading)).font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 5) {
                    Circle().fill(dot).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text(status).font(.caption)
                }
                .accessibilityElement(children: .combine)
                if unsupported {
                    Button(model.text(L10n.Digests.remove), action: remove)
                } else if unverified {
                    Button(model.text(L10n.Digests.tryThenEnable)) { Task { await data.trial(item.id, model: model) } }
                } else {
                    Button(model.text(L10n.Digests.tryNow)) { Task { await data.trial(item.id, model: model) } }.buttonStyle(.link)
                }
            }
            Menu {
                Button(model.text(L10n.Digests.remove), role: .destructive, action: remove)
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(model.text(L10n.Digests.more))
                .accessibilityLabel(model.text(L10n.Digests.more))
        }
        .padding(.vertical, 6)
    }

    private var detail: String {
        var parts = [item.source.kind.uppercased()]
        if let focus = item.source.focus { parts.append(model.text(focus == "domestic" ? L10n.Digests.domesticTag : L10n.Digests.entertainmentTag)) }
        if let latest = item.health?.latestPublication, let date = OverviewData.date(latest) {
            parts.append(L10n.Digests.latest(model.uiLanguage, ["time": date.formatted(date: .abbreviated, time: .shortened)]))
        }
        return parts.joined(separator: " · ")
    }

    private var failedStatus: String? {
        guard let status = item.health?.lastAttempt?.status, ["failed", "rate_limited", "timeout"].contains(status) else { return nil }
        return status
    }

    private var dot: Color {
        if unsupported || unverified { return .gray }
        if failedStatus != nil { return .red }
        switch item.health?.freshness {
        case "stale": return .orange
        case "current": return .green
        default: return .gray
        }
    }

    private var status: String {
        if unsupported { return model.text(L10n.Digests.notReadable) }
        if unverified { return model.text(L10n.Digests.unverified) }
        if let failedStatus {
            return model.text(L10n.Digests.unreadable) + " · " + FailureCopy.message(for: BackendError(code: failedStatus, domain: "sources"), model.uiLanguage)
        }
        switch item.health?.freshness {
        case "stale":
            let days = item.health?.latestPublication.flatMap(OverviewData.date).map { max(1, Int(Date().timeIntervalSince($0) / 86_400)) } ?? 3
            return L10n.Digests.staleDays(model.uiLanguage, ["days": String(days)])
        case "current": return model.text(L10n.Digests.healthy)
        default: return model.text(L10n.Digests.unknownHealth)
        }
    }
}

private struct TimeZonePicker: View {
    let model: AppModel
    let selected: String
    let choose: (String) -> Void
    @State private var query = ""

    var body: some View {
        let zones = TimeZone.knownTimeZoneIdentifiers.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }.prefix(80)
        VStack(alignment: .leading, spacing: 8) {
            TextField(model.text(L10n.Digests.searchZone), text: $query).textFieldStyle(.roundedBorder)
            Button(L10n.Digests.systemZone(model.uiLanguage, ["zone": TimeZone.current.identifier])) { choose(TimeZone.current.identifier) }
                .buttonStyle(.link)
            List(Array(zones), id: \.self) { zone in
                Button {
                    choose(zone)
                } label: {
                    HStack {
                        Text(zone)
                        Spacer()
                        if zone == selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(height: 220)
        }
        .padding(12)
        .frame(width: 300)
    }
}
