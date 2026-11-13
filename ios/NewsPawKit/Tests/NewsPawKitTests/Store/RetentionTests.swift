import Foundation
import GRDB
@testable import NewsPawKit
import Testing

/// RD06 criterion 5: clean-up, with an injected clock.
@Suite("Retention")
struct RetentionTests {
    private static let day: TimeInterval = 86_400

    /// Inserts an article of `source` with its body; ages are in seconds
    /// before the clock's current time.
    @discardableResult
    private func article(
        _ fixture: RefreshFixture, _ source: UUID, _ externalID: String, firstSeenAgo: TimeInterval,
        publishedAgo: TimeInterval? = nil, starred: Bool = false, read: Bool = false
    ) async throws -> Article {
        let now = fixture.clock.now()
        let article = Article(
            id: UUID(), sourceID: source, externalID: externalID, url: "https://example.invalid/\(externalID)",
            title: externalID, excerpt: nil, author: nil, imageURL: nil,
            publishedAt: publishedAgo.map { now.addingTimeInterval(-$0) }, firstSeenAt: now.addingTimeInterval(-firstSeenAgo),
            language: nil, readAt: read ? now : nil, starredAt: starred ? now : nil
        )
        try await fixture.library.insert(article)
        try await fixture.library.insert(Sample.body(of: article.id, at: now))
        return article
    }

    private func externalIDs(_ library: Library) async throws -> Set<String> {
        Set(try await library.articles().map(\.externalID))
    }

    @Test("an unstarred article first seen more than the period ago goes with its body; exactly the period or later stays; starred stays; read state and published time play no part",
          arguments: [Retention.sevenDays, .thirtyDays, .ninetyDays])
    func cleanUp(_ retention: Retention) async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let source = try await fixture.addFeed("one").id
        let period = TimeInterval(retention.rawValue) * Self.day
        try await article(fixture, source, "older", firstSeenAgo: period + 1)
        try await article(fixture, source, "older-read", firstSeenAgo: period + 1, read: true)
        try await article(fixture, source, "much-older", firstSeenAgo: period * 3)
        try await article(fixture, source, "exactly", firstSeenAgo: period)
        try await article(fixture, source, "younger", firstSeenAgo: period - 1)
        try await article(fixture, source, "younger-read", firstSeenAgo: 60, read: true)
        try await article(fixture, source, "starred-old", firstSeenAgo: period * 3, starred: true)
        try await article(fixture, source, "starred-old-read", firstSeenAgo: period * 3, starred: true, read: true)
        try await article(fixture, source, "published-years-ago-seen-today", firstSeenAgo: 0, publishedAgo: 3 * 365 * Self.day)
        try await article(fixture, source, "published-yesterday-seen-40-days-ago", firstSeenAgo: 40 * Self.day, publishedAgo: Self.day)
        let sourceBefore = try await rawSourceRow(fixture.library, source)
        let categoriesBefore = try await fixture.library.categories()

        let deleted = try await fixture.library.cleanUp(keeping: retention)

        var gone: Set<String> = ["older", "older-read", "much-older"]
        if retention.rawValue < 40 {
            gone.insert("published-yesterday-seen-40-days-ago")
        }
        let all: Set<String> = [
            "older", "older-read", "much-older", "exactly", "younger", "younger-read", "starred-old", "starred-old-read",
            "published-years-ago-seen-today", "published-yesterday-seen-40-days-ago",
        ]
        #expect(deleted == gone.count)
        #expect(try await externalIDs(fixture.library) == all.subtracting(gone))
        // Bodies went with their articles.
        let counts = try await rowCounts(fixture.library)
        #expect(counts["article_body"] == all.count - gone.count)
        // One seen row per deleted article, with its hash and the clean-up's time.
        let seen = try await fixture.library.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT source_id, external_id_hash, last_seen_at FROM seen").map { row in
                (source: row["source_id"] as String, hash: row["external_id_hash"] as String, lastSeen: row["last_seen_at"] as Date)
            }
        }
        #expect(seen.count == gone.count)
        #expect(Set(seen.map(\.hash)) == Set(gone.map(Library.seenHash)))
        #expect(seen.allSatisfy { $0.source == source.databaseKey })
        #expect(seen.allSatisfy { $0.lastSeen == fixture.clock.now() })
        // Nothing the owner edits changed.
        #expect(try await rawSourceRow(fixture.library, source) == sourceBefore)
        #expect(try await fixture.library.categories() == categoriesBefore)
    }

    @Test("the seen hash is the lowercase hexadecimal SHA-256 of the identifier's UTF-8 bytes")
    func seenHash() {
        #expect(Library.seenHash("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(Library.seenHash("日本") == "cf2abf0c5be326cb922a70f8163f91079c4d9aa8655c60ead89ad545c9de2e92")
    }

    @Test("forever deletes nothing")
    func forever() async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let source = try await fixture.addFeed("one").id
        try await article(fixture, source, "ancient", firstSeenAgo: 3_000 * Self.day)
        #expect(try await fixture.library.cleanUp(keeping: .forever) == 0)
        #expect(try await rowCounts(fixture.library)["article"] == 1)
        #expect(try await rowCounts(fixture.library)["seen"] == 0)
    }

    @Test("the clean-up is one transaction: when a seen insert is aborted, no article is deleted")
    func oneTransaction() async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let source = try await fixture.addFeed("one").id
        try await article(fixture, source, "old-1", firstSeenAgo: 100 * Self.day)
        try await article(fixture, source, "old-2", firstSeenAgo: 100 * Self.day)
        try await fixture.library.pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER abort_seen BEFORE INSERT ON seen
                WHEN (SELECT COUNT(*) FROM seen) >= 1
                BEGIN SELECT RAISE(ABORT, 'refused for the test'); END
                """)
        }
        await #expect(throws: LibraryError.self) { try await fixture.library.cleanUp(keeping: .thirtyDays) }
        #expect(try await rowCounts(fixture.library)["article"] == 2)
        #expect(try await rowCounts(fixture.library)["article_body"] == 2)
        #expect(try await rowCounts(fixture.library)["seen"] == 0)
    }
}
