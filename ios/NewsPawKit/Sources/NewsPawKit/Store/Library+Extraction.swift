import Foundation
import GRDB

/// An extraction kept with its article (RD12 decision 3): the extracted
/// HTML, the address that answered and when it was fetched. Its blocks are
/// derived at every opening, as the feed's are.
public struct StoredExtraction: Sendable, Hashable {
    public let html: String
    /// The address that answered, after redirects: the base of the HTML's
    /// relative links.
    public let address: URL
    public let fetchedAt: Date
    /// The extractor cut the HTML at its limit: the body is incomplete.
    public let isCut: Bool
}

/// What `article_body.blocks` holds for an extraction:
/// `{"v":1,"html":…,"address":…}`, with `"cut":true` when the extractor cut
/// the HTML at its limit (absent, it was not cut).
struct ExtractionEnvelope: Codable, Equatable {
    var v: Int
    var html: String
    var address: String
    var cut: Bool?

    static let version = 1
}

/// The extracted bodies (RD12 decision 3). A row of `article_body` with
/// `origin` = `extracted` per article whose page was extracted; it goes
/// with its article through the foreign key's cascade. No migration: the
/// table exists since `v1`.
extension Library {
    /// The extraction stored with the article, or `nil` when there is none,
    /// its origin is not `extracted`, or its envelope is of another version
    /// or cannot be read.
    public func extraction(ofArticle id: UUID) async throws -> StoredExtraction? {
        let stored = try await read { db -> (origin: String, blocks: String, fetchedAt: Date?)? in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT origin, blocks, fetched_at FROM article_body WHERE article_id = ?", arguments: [id.databaseKey]
            ) else { return nil }
            return (row["origin"], row["blocks"], row["fetched_at"])
        }
        guard let (origin, blocks, fetchedAt) = stored, origin == BodyOrigin.extracted.rawValue, let fetchedAt,
              let envelope = try? JSONDecoder().decode(ExtractionEnvelope.self, from: Data(blocks.utf8)),
              envelope.v == ExtractionEnvelope.version,
              let address = URL(string: envelope.address), address.isCollectableAddress
        else { return nil }
        return StoredExtraction(html: envelope.html, address: address, fetchedAt: fetchedAt, isCut: envelope.cut == true)
    }

    /// Keeps `html`, extracted from the page that answered at `address`,
    /// with the article, in place of any body stored with it, with the
    /// library's time as its fetch time.
    ///
    /// - Throws: `unknownArticle` when the library no longer holds the
    ///   article; then nothing is written.
    public func storeExtraction(html: String, address: URL, isCut: Bool = false, ofArticle id: UUID) async throws {
        let envelope = ExtractionEnvelope(
            v: ExtractionEnvelope.version, html: html, address: address.absoluteString, cut: isCut ? true : nil
        )
        let text = try String(decoding: JSONEncoder().encode(envelope), as: UTF8.self)
        let now = now()
        try await write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM article WHERE id = ?)", arguments: [id.databaseKey]) == true else {
                throw LibraryError.unknownArticle
            }
            try db.execute(sql: """
                INSERT INTO article_body (article_id, origin, blocks, fetched_at) VALUES (?, ?, ?, ?)
                ON CONFLICT (article_id) DO UPDATE SET
                    origin = excluded.origin, blocks = excluded.blocks, fetched_at = excluded.fetched_at
                """, arguments: [id.databaseKey, BodyOrigin.extracted.rawValue, text, now])
        }
    }
}
