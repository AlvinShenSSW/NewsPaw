import Foundation
import GRDB
@testable import NewsPawKit
import Testing

/// Configuration files built as JSON objects, to be changed member by member.
enum ConfigurationJSON {
    static let normalCategory = "11111111-1111-4111-8111-111111111111"
    static let secondNormalCategory = "22222222-2222-4222-8222-222222222222"
    static let adultCategory = "33333333-3333-4333-8333-333333333333"

    /// A valid file with both partitions: two normal categories, one adult
    /// category, a feed and a web page in the normal partition, a feed in
    /// the adult partition, a primary slot in each partition, and every
    /// setting member.
    static func base() -> [String: Any] {
        [
            "schema_version": 1,
            "exported_at": "2026-11-16T09:00:00Z",
            "app_version": "0.1.0 (1)",
            "includes_adult": true,
            "settings": [
                "refresh_minutes": 15, "retention_days": 7, "reading_locale": "en", "auto_translate_titles": false,
                "show_original_titles": true,
            ],
            "categories": [
                category(normalCategory, "News", partition: "normal", order: 0),
                category(secondNormalCategory, "Tech", partition: "normal", order: 1),
                category(adultCategory, "Private", partition: "adult", order: 0),
            ],
            "sources": [
                source(category: normalCategory, kind: "feed", name: "Alpha", url: "https://alpha.example/feed"),
                source(category: secondNormalCategory, kind: "webpage", name: "Beta", url: "https://beta.example/"),
                source(category: adultCategory, kind: "feed", name: "Gamma", url: "https://gamma.example/feed"),
            ],
            "partition_settings": [
                ["partition": "normal", "daily_auto_limit": 50, "list_thumbnails": false],
                ["partition": "adult", "daily_auto_limit": 10, "list_thumbnails": true],
            ],
            "model_slots": [
                slot(partition: "normal", role: "primary"),
                slot(partition: "adult", role: "primary", address: "https://adult.models.example/v1"),
            ],
        ]
    }

    static func category(_ id: String, _ name: String, partition: String, order: Int, icon: String = "newspaper") -> [String: Any] {
        ["id": id, "name": name, "partition": partition, "sort_order": order, "icon": icon, "overview": "auto"]
    }

    static func source(category: String, kind: String, name: String, url: String, id: String = UUID().uuidString.lowercased()) -> [String: Any] {
        [
            "id": id, "category_id": category, "kind": kind, "name": name, "url": url, "paused": false,
            "auto_translate": "inherit", "body_mode": "auto", "translate_page": false,
        ]
    }

    static func slot(partition: String, role: String, address: String = "https://api.openai.com/v1", model: String = "gpt-test") -> [String: Any] {
        ["partition": partition, "role": role, "preset": "custom", "base_url": address, "model": model]
    }

    static func data(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func text(_ object: [String: Any]) -> String {
        String(decoding: data(object), as: UTF8.self)
    }

    /// The file with `mutate` applied to its object.
    static func with(_ mutate: (inout [String: Any]) -> Void) -> Data {
        var object = base()
        mutate(&object)
        return data(object)
    }

    /// Changes element `index` of the array member `member`.
    static func change(_ object: inout [String: Any], _ member: String, at index: Int, _ mutate: (inout [String: Any]) -> Void) {
        var array = object[member] as! [[String: Any]]
        mutate(&array[index])
        object[member] = array
    }

    /// The text of `object` with the JSON number `marker` replaced by
    /// `replacement` — for the values JSONSerialization cannot write.
    static func replacing(_ marker: Int, with replacement: String, in object: [String: Any]) -> Data {
        let text = text(object)
        #expect(text.contains("\(marker)"))
        return Data(text.replacingOccurrences(of: "\(marker)", with: replacement).utf8)
    }
}

/// Both libraries of one store, an in-memory key store each, and a
/// preferences suite of their own: what an import and an export work on.
/// Sendable by hand: `UserDefaults` is safe to use from any thread.
struct ConfigurationFixture: @unchecked Sendable {
    let directory: URL
    let clock: TestClock
    let store: LibraryStore
    let normal: Library
    let adult: Library
    let normalKeys: InMemoryKeyStore
    let adultKeys: InMemoryKeyStore
    let defaults: UserDefaults
    let suiteName: String
    let preferences: Preferences

    static func make(adult makesAdult: Bool = true) async throws -> ConfigurationFixture {
        let directory = try makeTemporaryDirectory()
        let clock = TestClock()
        let store = LibraryStore(directory: directory, cacheRoot: directory.appending(path: "Images"), now: clock.now)
        let normal = try await store.openNormal()
        let adult = try await store.createAdultLibrary()
        let suiteName = "NewsPawConfigurationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return ConfigurationFixture(
            directory: directory, clock: clock, store: store, normal: normal, adult: adult,
            normalKeys: InMemoryKeyStore(partition: .normal), adultKeys: InMemoryKeyStore(partition: .adult),
            defaults: defaults, suiteName: suiteName, preferences: Preferences(defaults)
        )
    }

    var normalTarget: ConfigurationTarget {
        ConfigurationTarget(library: normal, keys: normalKeys)
    }

    var adultTarget: ConfigurationTarget {
        ConfigurationTarget(library: adult, keys: adultKeys)
    }

    func models(_ partition: Partition, http: any ModelHTTP = StubModelHTTP.completing()) -> LibraryModels {
        partition == .normal
            ? LibraryModels(library: normal, keys: normalKeys, http: http)
            : LibraryModels(library: adult, keys: adultKeys, http: http)
    }

    func library(_ partition: Partition) -> Library {
        partition == .normal ? normal : adult
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    /// Imports `document`: its adult part into the adult library when it
    /// has one and `withAdult` is set.
    @discardableResult
    func importDocument(
        _ document: ConfigurationDocument, mode: ConfigurationImportMode, withAdult: Bool = true,
        hooks: ConfigurationTransfer.Hooks = .init(),
        completion: @Sendable (ConfigurationImportResult) async -> Void = { _ in }
    ) async -> ConfigurationImportResult {
        let job = ConfigurationImport(document: document, normal: normalTarget, adult: withAdult ? adultTarget : nil)
        return await ConfigurationTransfer.run(job, mode: mode, preferences: preferences, hooks: hooks, completion: completion)
    }

    /// The preview of `document` against both libraries, or the normal one.
    func preview(_ document: ConfigurationDocument, withAdult: Bool = true) async throws -> ConfigurationPreview {
        try await ConfigurationTransfer.preview(document, normal: normal, adult: withAdult ? adult : nil, preferences: preferences)
    }

    /// Exports both libraries, or the normal one only.
    func export(adult withAdult: Bool = true) async throws -> Data {
        try await ConfigurationTransfer.export(
            normal: normal, adult: withAdult ? adult : nil, preferences: preferences, appVersion: "0.1.0 (1)", now: clock.now()
        )
    }
}

/// A key for tests.
func secretKey(_ text: String) -> SecretKey {
    try! SecretKey.validate(text).get()
}

/// Every row of every table of a library, compared logically.
func fullDump(_ library: Library) async throws -> DatabaseSnapshot {
    try await library.pool.read { try DatabaseSnapshot.read($0) }
}

/// Reads a document that is expected to pass.
func readDocument(_ data: Data, sourceLocation: SourceLocation = #_sourceLocation) throws -> ConfigurationDocument {
    switch ConfigurationFile.read(data) {
    case .success(let document): return document
    case .failure(let refusal):
        Issue.record("refused: \(refusal)", sourceLocation: sourceLocation)
        throw refusal
    }
}

/// Rows for the import tests, written directly.
extension Library {
    /// A category placed last.
    @discardableResult
    func testCategory(_ name: String, icon: String = "folder", overview: OverviewMode = .auto) async throws -> UUID {
        let id = UUID()
        let now = now()
        try await pool.write { db in
            let last = try Int.fetchOne(db, sql: "SELECT MAX(sort_order) FROM category")
            try Category(id: id, name: name, sortOrder: (last ?? -1) + 1, iconName: icon, overview: overview, updatedAt: now).insert(db)
        }
        return id
    }

    @discardableResult
    func testSource(
        _ name: String, url: String, category: UUID, kind: SourceKind = .feed, paused: Bool = false,
        autoTranslate: AutoTranslate = .inherit, bodyMode: BodyMode = .auto, translatePage: Bool = false
    ) async throws -> UUID {
        let id = UUID()
        try await insert(Source(
            id: id, categoryID: category, kind: kind, url: url, name: name, siteURL: "https://site.example/", paused: paused,
            autoTranslate: autoTranslate, bodyMode: bodyMode, translatePage: translatePage, etag: "\"etag\"",
            lastModified: "Mon, 16 Nov 2026 09:00:00 GMT", lastSuccessAt: now(), lastError: nil, updatedAt: now()
        ))
        return id
    }

    /// `count` articles of `source`, the first `starred` of them starred and
    /// read, each with a body and a translation.
    func testArticles(source: UUID, count: Int, starred: Int) async throws {
        let now = now()
        try await pool.write { db in
            for index in 0..<count {
                let article = Article(
                    id: UUID(), sourceID: source, externalID: "\(source)-\(index)", url: "https://item.example/\(source)/\(index)",
                    title: "Title \(index)", excerpt: nil, author: nil, imageURL: nil, publishedAt: now, firstSeenAt: now,
                    language: "en", readAt: index < starred ? now : nil, starredAt: index < starred ? now : nil
                )
                try article.insert(db)
                try ArticleBody(articleID: article.id, origin: .feed, blocks: #"[{"type":"paragraph","text":"Body"}]"#, fetchedAt: now).insert(db)
                try db.execute(
                    sql: "INSERT INTO translation (article_id, locale, title, excerpt, state, error, model, updated_at) VALUES (?, 'zh-Hans', '标题', NULL, 'done', NULL, 'm', ?)",
                    arguments: [article.id.databaseKey, now]
                )
            }
        }
    }

    /// One usage row.
    func testUsage() async throws {
        try await insertUsage(UsageRecord(
            id: UUID(), model: "m", purpose: .titles, inputTokens: 1, outputTokens: 1, outcome: .ok, at: now(), automatic: true
        ))
    }

    /// The rows of one table, rendered.
    func rows(_ table: String) async throws -> [[String?]] {
        try await fullDump(self).rows[table] ?? []
    }
}

/// Whether every row of `before` is still in `after`, unchanged.
func keepsEveryRow(_ before: DatabaseSnapshot, in after: DatabaseSnapshot) -> [String] {
    var missing: [String] = []
    for (table, rows) in before.rows {
        var remaining = after.rows[table] ?? []
        for row in rows {
            if let index = remaining.firstIndex(of: row) {
                remaining.remove(at: index)
            } else {
                missing.append("\(table): \(row)")
            }
        }
    }
    return missing
}
