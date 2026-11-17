import Foundation
import GRDB
@testable import NewsPawKit
import SQLite3
import Testing

// Nested in the serialized group: see `TimedAndHeavySuites`.
extension TimedAndHeavySuites {
    /// RD25 criterion 7: search at the issue's volume — 50,000 articles in
    /// 50 sources over 30 days, each with about 3 KB of feed HTML, and
    /// 30,000 `done` translations — written at the migration before search,
    /// then migrated (the backfill timed), then searched.
    ///
    /// The times are recorded and bounded with a wide margin (500 ms, about
    /// ten times the slowest the design measured warm). Two checks do not
    /// depend on the file cache: the page query's plan, and the pages a
    /// fresh connection reads for the commonest one-letter query.
    @Suite("Search volume")
    struct SearchVolumeTests {
        /// A small deterministic generator (SplitMix64), so that every run
        /// searches the same library.
        struct Generator {
            var state: UInt64

            mutating func next() -> UInt64 {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                return z ^ (z >> 31)
            }

            mutating func int(_ range: ClosedRange<Int>) -> Int {
                range.lowerBound + Int(next() % UInt64(range.count))
            }

            mutating func pick(_ words: [String]) -> String {
                words[int(0...(words.count - 1))]
            }
        }

        static let chinese = (
            "苹果 华为 日本 美国 中国 人工 智能 模型 发布 芯片 政府 经济 市场 股市 科技 公司 研究 大学 新闻 报告 数据 安全 网络 手机 "
                + "电脑 汽车 电动 能源 气候 天气 地震 选举 总统 外交 贸易 关税 银行 利率 通胀 房价 教育 医疗 疫苗 体育 足球 篮球 电影 音乐 "
                + "游戏 开源 代码 软件 硬件 系统 更新 版本 漏洞 隐私 用户 平台 社交 视频 直播 旅游 航空 铁路 城市 农村 人口 就业 工资 消费"
        ).split(separator: " ").map(String.init)
        static let japanese = (
            "東京 大阪 日本 政府 首相 経済 株価 円安 地震 台風 天気 選挙 アップル グーグル エーアイ 人工知能 スマホ 発表 新型 開発 研究 "
                + "大学 企業 市場 ニュース 速報 試合 野球 サッカー 映画 アニメ ゲーム について が を に で は と の 新しい 最新 公開 予定 "
                + "発売 価格 値上げ 調査 結果 問題 対策"
        ).split(separator: " ").map(String.init)
        static let english = (
            "apple google microsoft openai model release chip government economy market stock tech company research university "
                + "news report data security network phone computer car electric energy climate weather earthquake election president "
                + "trade tariff bank rate inflation housing education health vaccine sports football film music game open source code "
                + "software hardware system update version the a of in on for with new how why what is are to and launches says after "
                + "over amid"
        ).split(separator: " ").map(String.init)

        enum Language { case chinese, japanese, english }

        static func title(_ language: Language, _ generator: inout Generator) -> String {
            switch language {
            case .chinese:
                return (0..<generator.int(6...14)).map { _ in generator.pick(chinese) }.joined()
            case .japanese:
                return (0..<generator.int(6...12)).map { _ in generator.pick(japanese) }.joined()
            case .english:
                var words = (0..<generator.int(6...13)).map { _ in generator.pick(english) }
                words[0] = words[0].capitalized
                return words.joined(separator: " ")
            }
        }

        @Test("the first page of each query at 50,000 articles is under 500 ms; the plan uses the covering index; a fresh connection reads few pages; the backfill is under 10 s")
        func fiftyThousandArticles() async throws {
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let start = Date(timeIntervalSince1970: 1_800_000_000)

            // Written at the migration before search.
            do {
                let library = try await LibraryStore(directory: directory)
                    .open(.normal, migrator: SchemaTests.migratorBeforeSearch, create: true)
                var sources: [String] = []
                for index in 0..<10 {
                    let category = try await library.createCategory(name: "Category \(index)", icon: .folder).id
                    for number in 0..<5 {
                        let source = Sample.source(
                            in: category, url: "https://source\(index)-\(number).example.invalid/feed", name: "Source \(index)-\(number)",
                            at: start
                        )
                        try await library.insert(source)
                        sources.append(source.id.databaseKey)
                    }
                }
                let seeding = ContinuousClock.now
                let sourceKeys = sources
                let counts = try await library.pool.write { db -> (articles: Int, done: Int) in
                    var generator = Generator(state: 25)
                    let article = try db.makeStatement(sql: """
                        INSERT INTO article (id, source_id, external_id, url, title, excerpt, published_at, first_seen_at, content_html)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """)
                    let translation = try db.makeStatement(sql: """
                        INSERT INTO translation (article_id, locale, title, state, model, updated_at)
                        VALUES (?, 'zh-Hans', ?, ?, 'fixture-model', ?)
                        """)
                    var done = 0
                    for index in 0..<50_000 {
                        let roll = generator.int(0...99)
                        let language: Language = roll < 40 ? .chinese : roll < 60 ? .japanese : .english
                        let id = UUID().databaseKey
                        // Thirty days, about a minute apart.
                        let seen = start.addingTimeInterval(TimeInterval(index) * 30 * 86_400 / 50_000)
                        let title = Self.title(language, &generator)
                        let body = String(repeating: "<p>" + String(repeating: title, count: 4) + "</p>", count: 6)
                        try article.execute(arguments: [
                            id, sourceKeys[generator.int(0...49)], "ext-\(index)", "https://example.invalid/a/\(index)", title,
                            Self.title(language, &generator), index % 10 == 0 ? nil : seen, seen, body,
                        ])
                        if language == .chinese {
                            try translation.execute(arguments: [id, nil, "none", seen])
                        } else {
                            try translation.execute(arguments: [id, Self.title(.chinese, &generator), "done", seen])
                            done += 1
                        }
                    }
                    return (50_000, done)
                }
                print("RD25 volume: seeded \(counts.articles) articles, \(counts.done) done translations in \(ContinuousClock.now - seeding)")
                #expect(counts.done >= 29_000 && counts.done <= 31_000)
                try library.close()
            }
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: directory.appending(path: "normal.sqlite").path)[.size] as? Int) ?? 0
            print("RD25 volume: database before the search migration \(fileSize / 1_048_576) MB")

            // The migration, with its backfill.
            let migrating = ContinuousClock.now
            let library = try await LibraryStore(directory: directory).openNormal()
            let backfill = ContinuousClock.now - migrating
            print("RD25 volume: open with the search migration (backfill) \(backfill.milliseconds) ms")
            #expect(backfill < .seconds(10))
            let indexed = try await library.pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_text") ?? 0 }
            print("RD25 volume: search_text rows \(indexed)")
            #expect(indexed > 79_000)

            // The first page of each query, three times, the fastest kept.
            let twentyTerms = Array(Self.english.prefix(20)).joined(separator: " ")
            let queries = ["苹果", "人工智能", "東京", "アップル", "apple", "election", "the", "e", twentyTerms]
            let clock = ContinuousClock()
            for text in queries {
                let query = try #require(SearchQuery(text))
                var durations: [Duration] = []
                var count = 0
                for _ in 0..<3 {
                    let started = clock.now
                    count = try await library.articleRows(.library, filter: .all, translationsIn: .simplifiedChinese, matching: query).count
                    durations.append(clock.now - started)
                }
                let fastest = durations.min() ?? .zero
                print("RD25 volume: \"\(text.prefix(24))\": \(durations.map(\.milliseconds)) ms, fastest \(fastest.milliseconds) ms, \(count) rows")
                #expect(fastest < .milliseconds(500), "\(text.prefix(24)): \(fastest.milliseconds) ms")
            }

            // The plan of the page query: the matches through the covering
            // index, no lookup through the unique id index.
            let (sql, arguments) = Library.pageQuery(
                .library, filter: .all, after: nil, limit: Library.articlePageSize, translationsIn: .simplifiedChinese,
                matching: SearchQuery("e")
            )
            let plan = try await library.pool.read { db in
                try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments).map { $0["detail"] as String }
            }
            print("RD25 volume: plan \(plan)")
            #expect(plan.contains { $0.contains("COVERING INDEX article_search_order") }, "\(plan)")
            #expect(!plan.contains { $0.contains("sqlite_autoindex_article_1") }, "\(plan)")
            #expect(plan.contains { $0.contains("SEARCH article USING INTEGER PRIMARY KEY (rowid=?)") }, "\(plan)")
            try library.close()

            // Pages read by a fresh connection, which the file cache does
            // not change: a scan of search_text alone, then the page for "e".
            let path = directory.appending(path: "normal.sqlite").path
            let scanSQL = "SELECT COUNT(*) FROM search_text WHERE instr(text, ?) > 0"
            let scanPages = try Self.pagesRead(path: path) { db in
                _ = try Int.fetchOne(db, sql: scanSQL, arguments: ["no title holds this"])
            }
            var firstPageCount = 0
            let pagePages = try Self.pagesRead(path: path) { db in
                firstPageCount = try Row.fetchAll(db, sql: sql, arguments: arguments).count
            }
            print("RD25 volume: fresh connection pages read: scan of search_text \(scanPages), first page for \"e\" \(pagePages) (\(firstPageCount) rows)")
            #expect(firstPageCount == Library.articlePageSize)
            #expect(pagePages < 2 * scanPages + 200, "\(pagePages) pages against \(scanPages)")
        }

        /// The pages a fresh read-only connection on `path` reads from the
        /// file (`SQLITE_DBSTATUS_CACHE_MISS`) while running `work`.
        static func pagesRead(path: String, _ work: (Database) throws -> Void) throws -> Int {
            var configuration = Configuration()
            configuration.readonly = true
            let queue = try DatabaseQueue(path: path, configuration: configuration)
            defer { try? queue.close() }
            return try queue.read { db in
                var before: Int32 = 0
                var after: Int32 = 0
                var high: Int32 = 0
                sqlite3_db_status(db.sqliteConnection, SQLITE_DBSTATUS_CACHE_MISS, &before, &high, 0)
                try work(db)
                sqlite3_db_status(db.sqliteConnection, SQLITE_DBSTATUS_CACHE_MISS, &after, &high, 0)
                return Int(after - before)
            }
        }
    }
}

private extension Duration {
    var milliseconds: String {
        let (seconds, attoseconds) = components
        return String(format: "%.1f", Double(seconds) * 1_000 + Double(attoseconds) / 1e15)
    }
}
