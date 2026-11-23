import Foundation
import GRDB
@testable import NewsPawKit
import Testing

/// RD11 decision 4: the feed HTML of an article is read cut to a limit, in
/// the query.
@Suite("Article HTML read", .serialized)
struct ArticleHTMLReadTests {
    private func setHTML(_ html: String?, of id: UUID, in library: Library) async throws {
        try await library.pool.write { db in
            try db.execute(sql: "UPDATE article SET content_html = ? WHERE id = ?", arguments: [html, id.databaseKey])
        }
    }

    @Test("the HTML is cut to the limit in characters; shorter HTML is whole; no HTML and no article are nil")
    func cutInTheQuery() async throws {
        let fixture = try await ArticleFixture.make()
        defer { fixture.remove() }
        let category = try await fixture.category("World")
        let source = try await fixture.source("Feed", in: category)
        let id = try await fixture.article("One", in: source, published: nil, firstSeen: fixture.at(0))
        let library = fixture.library

        #expect(try await library.contentHTML(ofArticle: id, limit: 1_000) == "<p>Stored HTML of One</p>")
        #expect(try await library.contentHTML(ofArticle: id, limit: 9) == "<p>Stored")
        #expect(try await library.contentHTML(ofArticle: id, limit: 0) == "")

        // Characters, not bytes: three-byte characters count one each.
        try await setHTML(String(repeating: "中", count: 50) + "tail", of: id, in: library)
        #expect(try await library.contentHTML(ofArticle: id, limit: 50) == String(repeating: "中", count: 50))
        #expect(try await library.contentHTML(ofArticle: id, limit: 52) == String(repeating: "中", count: 50) + "ta")

        // The converter's limit and one character more, as the reading
        // screen asks: the converter then knows that the input was cut.
        let limit = ArticleBlocks.maximumInputCharacters
        try await setHTML(String(repeating: "a", count: limit + 500), of: id, in: library)
        let read = try #require(try await library.contentHTML(ofArticle: id, limit: limit + 1))
        #expect(read.utf8.count == limit + 1)
        #expect(ArticleBlocks.make(html: read, baseURL: nil).isCut)
        try await setHTML(String(repeating: "a", count: limit), of: id, in: library)
        let whole = try #require(try await library.contentHTML(ofArticle: id, limit: limit + 1))
        #expect(whole.utf8.count == limit)
        #expect(!ArticleBlocks.make(html: whole, baseURL: nil).isCut)

        try await setHTML(nil, of: id, in: library)
        #expect(try await library.contentHTML(ofArticle: id, limit: 1_000) == nil)
        #expect(try await library.contentHTML(ofArticle: UUID(), limit: 1_000) == nil)
    }

    @Test("reading and converting an article's HTML writes nothing: no body row, the HTML as it was")
    func nothingIsWritten() async throws {
        let fixture = try await ArticleFixture.make()
        defer { fixture.remove() }
        let category = try await fixture.category("World")
        let source = try await fixture.source("Feed", in: category)
        let id = try await fixture.article("One", in: source, published: nil, firstSeen: fixture.at(0))
        let library = fixture.library
        let html = try #require(try await library.contentHTML(ofArticle: id, limit: ArticleBlocks.maximumInputCharacters + 1))
        _ = ArticleBlocks.make(html: html, baseURL: URL(string: "https://example.invalid/one"))
        let (bodies, stored) = try await library.pool.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article_body") ?? -1,
                try String.fetchOne(db, sql: "SELECT content_html FROM article WHERE id = ?", arguments: [id.databaseKey])
            )
        }
        #expect(bodies == 0)
        #expect(stored == "<p>Stored HTML of One</p>")
    }
}
