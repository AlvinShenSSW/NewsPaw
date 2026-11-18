import Foundation
import GRDB
@testable import NewsPawKit
import Testing

/// RD25: search of article titles, original and translated, within one
/// library (spec N05; criteria 1 to 6 and 11).
@Suite("Search")
struct SearchTests {
    // MARK: - Criterion 1: matching

    @Test("folding: case and width are folded, kana marks and Chinese are kept, whatever the locale (A5)")
    func folding() {
        #expect(SearchQuery.fold("ＡＩ") == "ai")
        #expect(SearchQuery.fold("ｱｯﾌﾟﾙ") == "アップル")
        #expect(SearchQuery.fold("ＧＰＴ－５") == "gpt-5")
        #expect(SearchQuery.fold("Straße") == "strasse")
        #expect(SearchQuery.fold("APPLE") == "apple")
        #expect(SearchQuery.fold("がん") == "がん")
        #expect(SearchQuery.fold("が") != SearchQuery.fold("か"))
        #expect(SearchQuery.fold("苹果发布新款芯片") == "苹果发布新款芯片")
        #expect(SearchQuery.fold("蘋果") == "蘋果")
        // Canonical composition: a decomposed e-acute is the composed one.
        #expect(SearchQuery.fold("e\u{301}") == "\u{e9}")
    }

    @Test("Chinese, Japanese and Latin terms inside longer titles, folded on both sides")
    func matchingScripts() async throws {
        let fixture = try await SearchFixture.make()
        defer { fixture.remove() }
        let apple = "今天苹果发布了新款手机"
        let ai = "中国人工智能产业报告发布"
        let tokyo = "東京で新型ＡＩ発表"
        let halfWidth = "ｱｯﾌﾟﾙの新製品"
        let english = "Apple releases a new chip"
        let kestrel = "Kestrel sightings rise in spring"
        for title in [apple, ai, tokyo, halfWidth, english, kestrel] {
            try await fixture.article(title)
        }
        try await fixture.article(nil)

        #expect(try await fixture.search("苹果") == [apple])
        #expect(try await fixture.search("人工智能") == [ai])
        #expect(try await fixture.search("東京") == [tokyo])
        #expect(try await fixture.search("アップル") == [halfWidth])
        #expect(try await fixture.search("ai") == [tokyo])
        #expect(try await fixture.search("ＡＩ") == [tokyo])
        #expect(try await fixture.search("APPLE") == [english])
        // One character.
        #expect(try await fixture.search("苹") == [apple])
        #expect(try await fixture.search("k") == [kestrel])
        // Two terms, in either order, both in the same title.
        #expect(try await fixture.search("kestrel spring") == [kestrel])
        #expect(try await fixture.search("spring kestrel") == [kestrel])
        #expect(try await fixture.search("kestrel chip") == [])
        // Newest first.
        #expect(try await fixture.search("e") == [kestrel, english])
    }

    @Test("a translated title in the reading language is searched when done; another language's, a failed or none row, or none without a reading language, is not")
    func matchingTranslations() async throws {
        let fixture = try await SearchFixture.make()
        defer { fixture.remove() }
        let foreign = try await fixture.article("A buzzard over the moor")
        try await fixture.translate(foreign, .simplifiedChinese, .done, title: "荒野上空的鵟鸟")
        try await fixture.translate(foreign, .japanese, .done, title: "荒野の上のノスリ")
        let failed = try await fixture.article("A failed story")
        let none = try await fixture.article("A story without translation")
        try await fixture.library.pool.write { db in
            // The shapes RD14 never writes with a title, written in SQL.
            try db.execute(sql: """
                INSERT INTO translation (article_id, locale, title, state, error, updated_at) VALUES
                    (?, 'zh-Hans', '失败标题词', 'failed', 'malformed', '2026-11-17 00:00:00.000'),
                    (?, 'zh-Hans', '无译标题词', 'none', NULL, '2026-11-17 00:00:00.000')
                """, arguments: [failed.databaseKey, none.databaseKey])
        }

        #expect(try await fixture.search("鵟鸟") == ["A buzzard over the moor"])
        #expect(try await fixture.search("buzzard") == ["A buzzard over the moor"])
        // Only in a translation of another language.
        #expect(try await fixture.search("ノスリ") == [])
        #expect(try await fixture.search("ノスリ", locale: .japanese) == ["A buzzard over the moor"])
        // A failed or none row is not searched.
        #expect(try await fixture.search("失败标题词") == [])
        #expect(try await fixture.search("无译标题词") == [])
        // No reading language: originals only.
        #expect(try await fixture.search("鵟鸟", locale: nil) == [])
        #expect(try await fixture.search("buzzard", locale: nil) == ["A buzzard over the moor"])
        // Every term in the same text: one in the original, one in the
        // translation, is no match.
        #expect(try await fixture.search("buzzard 鵟鸟") == [])
        // The row carries the stored translation of the reading language.
        let rows = try await fixture.library.articleRows(
            .library, filter: .all, translationsIn: .simplifiedChinese, matching: SearchQuery("buzzard")!
        )
        #expect(rows.map(\.translation?.title) == ["荒野上空的鵟鸟"])
    }

    @Test("a Traditional Chinese original is found by Simplified text through RD14's converted row, and not without it")
    func traditionalThroughConversion() async throws {
        let fixture = try await SearchFixture.make()
        defer { fixture.remove() }
        let traditional = "蘋果發佈新款晶片"
        let converted = try #require(TextLanguage.simplified(traditional))
        #expect(converted.contains("苹果"))
        let judged = try await fixture.article(traditional)
        try await fixture.translate(judged, .simplifiedChinese, .done, title: converted)
        try await fixture.article("蘋果晶片產量創新高")

        #expect(try await fixture.search("苹果") == [traditional])
        #expect(try await fixture.search("蘋果") == ["蘋果晶片產量創新高", traditional])
    }

    // MARK: - Criterion 2: untrusted query text

    @Test("query text is never syntax: hostile strings return results or none and never throw; % and _ match only themselves")
    func hostileQueries() async throws {
        let fixture = try await SearchFixture.make()
        defer { fixture.remove() }
        try await fixture.article("Results 100% certain")
        try await fixture.article("snake_case names")
        try await fixture.article(#"A "quoted" word and a back\slash"#)
        try await fixture.article("Plain title")
        let hostile = [
            "*", "\"", "\"abc", "'", "%", "_", "\\", "NEAR(a b)", "AND", "OR", "NOT", "a:b", "^x", "(", ")", "-x",
            "👍🏽", "e\u{301}\u{302}\u{303}", "a\u{0}b", "\u{0}", String(repeating: "a", count: 10_000),
            "'; DROP TABLE article; --", "\" OR 1=1 --", "a' OR 'a'='a",
        ]
        for text in hostile {
            let query = try #require(SearchQuery(text), "\(text.prefix(20)) is a query")
            do {
                _ = try await fixture.library.articleRows(.library, filter: .all, translationsIn: .simplifiedChinese, matching: query)
            } catch {
                Issue.record("\(text.prefix(20)) threw \(error)")
            }
        }
        #expect(try await fixture.search("%") == ["Results 100% certain"])
        #expect(try await fixture.search("_") == ["snake_case names"])
        #expect(try await fixture.search("\"") == [#"A "quoted" word and a back\slash"#])
        #expect(try await fixture.search("\\") == [#"A "quoted" word and a back\slash"#])
        #expect(try await fixture.search("'") == [])
        #expect(try await fixture.search("'; DROP TABLE article; --") == [])
        // Nothing was dropped or changed.
        #expect(try await fixture.library.articles().count == 4)
        try await expectSearchTextMatchesDerivation(fixture.library)
    }

    @Test("white space only is no query; at most 100 characters; repeated terms count once; terms in typed order")
    func queryShape() throws {
        #expect(SearchQuery("") == nil)
        #expect(SearchQuery("   \t\n") == nil)
        #expect(SearchQuery("\u{3000}\u{3000}") == nil)
        #expect(SearchQuery(" \u{3000}苹果\u{3000}")?.terms == ["苹果"])
        #expect(SearchQuery("苹果\u{3000}芯片")?.terms == ["苹果", "芯片"])
        #expect(SearchQuery("Spring kestrel SPRING spring")?.terms == ["spring", "kestrel"])
        #expect(SearchQuery(String(repeating: "a", count: 10_000))?.terms == [String(repeating: "a", count: 100)])
        // The cut counts characters of the trimmed text, not terms.
        let long = String(repeating: "b", count: 98) + " cdef"
        #expect(SearchQuery(long)?.terms == [String(repeating: "b", count: 98), "c"])
        // A character is a grapheme: an emoji with a modifier is one.
        let emoji = String(repeating: "👍🏽", count: 150)
        #expect(SearchQuery(emoji)?.terms.first?.count == 100)
    }

    // MARK: - Criterion 3: the index is current on every write path

    @Test("collection through insertArticles keeps the index, and the search feed collects as the UI tests expect")
    func collectionPath() async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let source = Sample.source(in: fixture.categoryID, url: FixtureTransport.Address.search, name: "Search", at: fixture.clock.now())
        try await fixture.library.insert(source)

        _ = try await Refresher(library: fixture.library, transport: FixtureTransport()).refresh(.library)

        let rows = try await expectSearchTextMatchesDerivation(fixture.library)
        #expect(rows == 3)
        let titles = try await fixture.library.articleRows(
            .library, filter: .all, matching: SearchQuery("芯片")!
        ).map(\.title)
        #expect(titles == ["苹果发布新款芯片"])
        let all = try await fixture.library.articleRows(.library, filter: .all).map(\.title)
        #expect(all == FixtureTransport.searchTitles)
    }

    @Test("a source added with its first articles keeps the index")
    func addedSourcePath() async throws {
        let fixture = try await SearchFixture.make()
        defer { fixture.remove() }
        let detector = SourceDetector(transport: FixtureTransport(), candidateLimit: FixtureTransport.candidateLimit)
        guard case .feed(let candidate) = try await detector.detect(FixtureTransport.Address.privateSearch, in: fixture.library) else {
            Issue.record("not a feed")
            return
        }
        try await fixture.library.addFeedSource(candidate, name: "Private", categoryID: fixture.category)

        #expect(try await expectSearchTextMatchesDerivation(fixture.library) == 1)
        #expect(try await fixture.search("nightjar") == [FixtureTransport.privateSearchTitle])
    }

    @Test("record inserts, title changes and every translation write keep the index")
    func recordAndTranslationPaths() async throws {
        let fixture = try await SearchFixture.make()
        defer { fixture.remove() }
        let first = try await fixture.article("First kestrel")
        let untitled = try await fixture.article(nil)
        let second = try await fixture.article("Second kestrel")
        #expect(try await expectSearchTextMatchesDerivation(fixture.library, "record inserts") == 2)

        // A title changed in SQL, set, and cleared.
        try await fixture.library.pool.write { db in
            try db.execute(sql: "UPDATE article SET title = 'Renamed osprey' WHERE id = ?", arguments: [first.databaseKey])
            try db.execute(sql: "UPDATE article SET title = 'Late title' WHERE id = ?", arguments: [untitled.databaseKey])
        }
        try await expectSearchTextMatchesDerivation(fixture.library, "titles changed")
        #expect(try await fixture.search("osprey") == ["Renamed osprey"])
        #expect(try await fixture.search("first") == [])
        try await fixture.library.pool.write { db in
            try db.execute(sql: "UPDATE article SET title = NULL WHERE id = ?", arguments: [untitled.databaseKey])
        }
        try await expectSearchTextMatchesDerivation(fixture.library, "title cleared")

        // A translation inserted in each state.
        try await fixture.translate(first, .simplifiedChinese, .done, title: "改名的鹗")
        try await fixture.translate(second, .simplifiedChinese, .failed, title: nil)
        try await fixture.translate(untitled, .simplifiedChinese, .none, title: nil)
        try await fixture.translate(second, .japanese, .done, title: "二番目のチョウゲンボウ")
        #expect(try await expectSearchTextMatchesDerivation(fixture.library, "translations inserted") == 4)

        // Upserted from done to failed and back.
        try await fixture.translate(first, .simplifiedChinese, .failed, title: nil)
        try await expectSearchTextMatchesDerivation(fixture.library, "done to failed")
        #expect(try await fixture.search("鹗") == [])
        try await fixture.translate(first, .simplifiedChinese, .done, title: "新的鹗")
        try await expectSearchTextMatchesDerivation(fixture.library, "failed to done")
        #expect(try await fixture.search("新的鹗") == ["Renamed osprey"])
        // Upserted from done to done with another title.
        try await fixture.translate(first, .simplifiedChinese, .done, title: "又一个鹗")
        try await expectSearchTextMatchesDerivation(fixture.library, "done to done")
        #expect(try await fixture.search("新的鹗") == [])

        // Deleted as RD14 deletes failed rows.
        try await fixture.translate(second, .simplifiedChinese, .failed, title: nil)
        try await fixture.library.write { db in try Library.deleteStoredFailures(db) }
        try await expectSearchTextMatchesDerivation(fixture.library, "failed rows deleted")
        // A done row deleted in SQL.
        try await fixture.library.pool.write { db in
            try db.execute(sql: "DELETE FROM translation WHERE article_id = ? AND locale = 'ja'", arguments: [second.databaseKey])
        }
        #expect(try await expectSearchTextMatchesDerivation(fixture.library, "done row deleted") == 3)
    }

    @Test("deleting a source, and a category with its sources, leaves no search row of their articles; moving them keeps them")
    func deletionPaths() async throws {
        let fixture = try await SearchFixture.make()
        defer { fixture.remove() }
        let other = try await fixture.library.createCategory(name: "Other", icon: .folder).id
        let otherSource = Sample.source(in: other, url: "https://other.example.invalid/feed", name: "Other", at: fixture.clock.now())
        try await fixture.library.insert(otherSource)
        let third = try await fixture.library.createCategory(name: "Third", icon: .folder).id
        let thirdSource = Sample.source(in: third, url: "https://third.example.invalid/feed", name: "Third", at: fixture.clock.now())
        try await fixture.library.insert(thirdSource)
        let kept = try await fixture.article("Kept heron")
        try await fixture.translate(kept, .simplifiedChinese, .done, title: "留下的鹭")
        let inOther = try await fixture.article("Other heron", source: otherSource.id)
        try await fixture.translate(inOther, .simplifiedChinese, .done, title: "别处的鹭")
        let inThird = try await fixture.article("Third heron", source: thirdSource.id)
        try await fixture.translate(inThird, .simplifiedChinese, .done, title: "第三的鹭")
        #expect(try await expectSearchTextMatchesDerivation(fixture.library) == 6)

        try await fixture.library.deleteSource(otherSource.id)
        #expect(try await expectSearchTextMatchesDerivation(fixture.library, "source deleted") == 4)
        #expect(try await fixture.search("heron") == ["Third heron", "Kept heron"])

        // A category deleted with its sources moved keeps their rows.
        try await fixture.library.deleteCategory(third, sources: .move(to: fixture.category))
        #expect(try await expectSearchTextMatchesDerivation(fixture.library, "category deleted, sources moved") == 4)

        try await fixture.library.deleteCategory(fixture.category, sources: .deleteSources)
        #expect(try await expectSearchTextMatchesDerivation(fixture.library, "category deleted with its sources") == 0)
        #expect(try await fixture.search("heron") == [])
        #expect(try await fixture.search("鹭") == [])
    }

    // MARK: - Criterion 4: every connection has the function, and none without it indexes silently

    @Test("an article inserted through the opened library is indexed and every reader has the function; a raw connection without the function cannot insert one")
    func connectionsWithoutTheFunctionFail() async throws {
        let fixture = try await SearchFixture.make()
        defer { fixture.remove() }
        try await fixture.article("Indexed kestrel")
        #expect(try await fixture.search("kestrel") == ["Indexed kestrel"])
        // Every reader of the pool has the function too.
        let folded = try await fixture.library.pool.read { db in
            try String.fetchOne(db, sql: "SELECT newspaw_search_fold('ＫＥＳＴＲＥＬ')")
        }
        #expect(folded == "kestrel")
        let url = fixture.store.fileURL(for: .normal)

        // A raw queue on the migrated file, without the function.
        let raw = try DatabaseQueue(path: url.path)
        defer { try? raw.close() }
        let sourceKey = fixture.source.databaseKey
        for (name, title) in [("titled", "Raw kestrel" as String?), ("untitled", nil)] {
            await #expect(throws: DatabaseError.self, "a raw insert of a \(name) article") {
                try await raw.write { db in
                    try db.execute(sql: """
                        INSERT INTO article (id, source_id, external_id, title, first_seen_at)
                        VALUES (?, ?, ?, ?, '2026-11-17 00:00:00.000')
                        """, arguments: [UUID().databaseKey, sourceKey, "raw-\(name)", title])
                }
            }
        }
        // Reads, state changes and deletes work without it.
        try await raw.write { db in
            try db.execute(sql: "UPDATE article SET read_at = '2026-11-17 00:00:00.000'")
        }
        #expect(try await raw.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article") } == 1)
        try raw.close()
        try await expectSearchTextMatchesDerivation(fixture.library)
        #expect(try await fixture.search("raw") == [])
    }

    // MARK: - Criterion 5: order and pages

    @Test("results come in list order in pages of 200; a run of more than 200 matches sharing one time straddles a page boundary without a repeat or a gap; rows carry the reading language's translation", arguments: [nil, ReadingLocale.simplifiedChinese])
    func orderAndPages(locale: ReadingLocale?) async throws {
        let fixture = try await ArticleFixture.make()
        defer { fixture.remove() }
        let category = try await fixture.category("News")
        let one = try await fixture.source("One", in: category)
        let two = try await fixture.source("Two", in: category)
        var matching = Set<UUID>()
        // 450 matches that share one time, between older and newer ones,
        // and articles that do not match, in two sources, read or not.
        for index in 0..<50 {
            let id = try await fixture.article(
                "Older heron \(index)", in: index % 2 == 0 ? one : two, published: fixture.at(index), firstSeen: fixture.at(index),
                read: index % 3 == 0
            )
            matching.insert(id)
        }
        for index in 0..<450 {
            let id = try await fixture.article(
                "Same-time heron \(index)", in: index % 2 == 0 ? one : two, published: fixture.at(10_000), firstSeen: fixture.at(10_000),
                starred: index % 7 == 0
            )
            matching.insert(id)
            try await fixture.article("Same-time crane \(index)", in: one, published: fixture.at(10_000), firstSeen: fixture.at(10_000))
        }
        for index in 0..<30 {
            let id = try await fixture.article("Undated heron \(index)", in: two, published: nil, firstSeen: fixture.at(20_000 + index))
            matching.insert(id)
        }
        let translated = fixture.expected(.library, .all).filter(matching.contains).prefix(5)
        try await fixture.library.storeTranslations(translated.map { id in
            TranslationRecord(
                articleID: id, locale: .simplifiedChinese, state: .done, title: "鹭 \(id.databaseKey.prefix(4))", excerpt: nil,
                failure: nil, model: "fixture-model"
            )
        })
        let query = try #require(SearchQuery("HERON"))

        var pages: [[ArticleRow]] = []
        var cursor: ArticlePosition?
        while true {
            let page = try await fixture.library.articleRows(
                .library, filter: .all, after: cursor, limit: Library.articlePageSize, translationsIn: locale, matching: query
            )
            if page.isEmpty { break }
            pages.append(page)
            cursor = page.last?.position
            if page.count < Library.articlePageSize { break }
        }
        let expected = fixture.expected(.library, .all).filter(matching.contains)
        #expect(expected.count == 530)
        #expect(pages.map(\.count) == [200, 200, 130])
        #expect(pages.joined().map(\.id) == expected)
        // The boundaries fall inside the run that shares one time.
        #expect(pages[0].last?.shownAt == fixture.at(10_000) && pages[1].first?.shownAt == fixture.at(10_000))
        let titled = pages.joined().filter { $0.translation != nil }
        if locale == nil {
            #expect(titled.isEmpty)
        } else {
            #expect(titled.map(\.id) == Array(translated))
            #expect(titled.allSatisfy { $0.translation?.title?.hasPrefix("鹭") == true })
        }
    }

    @Test("the search page query selects no content_html and walks the covering index, with a cursor and a locale")
    func pageQueryShape() async throws {
        let fixture = try await SearchFixture.make()
        defer { fixture.remove() }
        let query = try #require(SearchQuery("kestrel spring"))
        let cursor = ArticlePosition(shownAt: "2026-11-13 00:00:00.000", firstSeenAt: "2026-11-13 00:00:00.000", rowID: 5)
        for (locale, after) in [(nil, nil), (ReadingLocale.simplifiedChinese, cursor)] as [(ReadingLocale?, ArticlePosition?)] {
            let (sql, arguments) = Library.pageQuery(
                .library, filter: .all, after: after, limit: 200, translationsIn: locale, matching: query
            )
            #expect(!sql.contains("content_html"))
            let plan = try await fixture.library.pool.read { db in
                try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments).map { $0["detail"] as String }
            }
            print("RD25 search page plan (locale \(locale?.rawValue ?? "none"), cursor \(after != nil)): \(plan)")
            #expect(plan.contains { $0.contains("COVERING INDEX article_search_order") }, "\(plan)")
            #expect(!plan.contains { $0.contains("sqlite_autoindex_article_1") }, "\(plan)")
            // Arguments: [join locale], reading locale or '', two terms, [cursor], limit.
            let expectedCount = (locale == nil ? 0 : 1) + 1 + 2 + (after == nil ? 0 : 3) + 1
            #expect(sql.filter { $0 == "?" }.count == expectedCount)
            _ = arguments
        }
    }

    // MARK: - Criterion 6: partitions

    @Test("a word only in the adult library is found there and not in the normal one, and the reverse; a word in both is found in each")
    func partitions() async throws {
        let fixture = try await SearchFixture.make()
        defer { fixture.remove() }
        let adult = try await fixture.store.createAdultLibrary()
        let adultCategory = try await adult.createCategory(name: "Private", icon: .folder).id
        let adultSource = Sample.source(in: adultCategory, url: "https://private.example.invalid/feed", name: "Private", at: fixture.clock.now())
        try await adult.insert(adultSource)

        let adultTitled = try await fixture.article("Nightjar control word", in: adult, source: adultSource.id)
        let adultTranslated = try await fixture.article("Another control word", in: adult, source: adultSource.id)
        try await fixture.translate(adultTranslated, .simplifiedChinese, .done, title: "夜鹰译名", in: adult)
        let normalTitled = try await fixture.article("Kestrel control word")
        try await fixture.translate(normalTitled, .simplifiedChinese, .done, title: "红隼译名")
        _ = adultTitled

        // The control word: found in each, so the empty results mean something.
        #expect(try await fixture.search("control") == ["Kestrel control word"])
        #expect(try await fixture.search("control", in: adult) == ["Another control word", "Nightjar control word"])
        // Adult-only words, in a title and in a translation.
        #expect(try await fixture.search("nightjar") == [])
        #expect(try await fixture.search("夜鹰") == [])
        #expect(try await fixture.search("nightjar", in: adult) == ["Nightjar control word"])
        #expect(try await fixture.search("夜鹰", in: adult) == ["Another control word"])
        // Normal-only words.
        #expect(try await fixture.search("kestrel", in: adult) == [])
        #expect(try await fixture.search("红隼", in: adult) == [])
        #expect(try await fixture.search("红隼") == ["Kestrel control word"])
        // Each library's index holds its own rows only.
        let normalIndex = try await fixture.library.pool.read { db in try storedSearchText(db).map(\.text) }
        let adultIndex = try await adult.pool.read { db in try storedSearchText(db).map(\.text) }
        #expect(!normalIndex.contains { $0.contains("nightjar") || $0.contains("夜鹰") })
        #expect(!adultIndex.contains { $0.contains("kestrel") || $0.contains("红隼") })
        try await expectSearchTextMatchesDerivation(fixture.library)
        try await expectSearchTextMatchesDerivation(adult)
    }

    // MARK: - Criterion 11: nothing is kept

    @Test("a search writes nothing to the library")
    func searchWritesNothing() async throws {
        let fixture = try await SearchFixture.make()
        defer { fixture.remove() }
        let id = try await fixture.article("Kestrel over the hill")
        try await fixture.translate(id, .simplifiedChinese, .done, title: "山上的红隼")
        let before = try await fixture.library.pool.read { try DatabaseSnapshot.read($0) }

        for text in ["kestrel", "红隼", "a query the owner typed", "'; --"] {
            _ = try await fixture.search(text)
        }

        let after = try await fixture.library.pool.read { try DatabaseSnapshot.read($0) }
        #expect(after == before)
        // No file of the library's directory holds the query's text.
        let directory = fixture.store.fileURL(for: .normal).deletingLastPathComponent()
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let bytes = try Data(contentsOf: directory.appending(path: name))
            #expect(bytes.range(of: Data("a query the owner typed".utf8)) == nil, "\(name)")
        }
    }

    // MARK: - The search fixture feeds (UI tests)

    @Test("the search fixture feeds answer with their titles")
    func fixtureFeeds() async throws {
        let transport = FixtureTransport()
        guard case .feed(let search) = try await FeedFetcher(transport: transport).fetch(FixtureTransport.Address.search),
              case .feed(let privateSearch) = try await FeedFetcher(transport: transport).fetch(FixtureTransport.Address.privateSearch)
        else {
            Issue.record("not feeds")
            return
        }
        #expect(search.feed.items.map(\.title) == FixtureTransport.searchTitles)
        #expect(privateSearch.feed.items.map(\.title) == [FixtureTransport.privateSearchTitle])
    }
}
