import Foundation
import GRDB
@testable import NewsPawKit
import Testing

// Nested in the serialized group: see `TimedAndHeavySuites`.
extension TimedAndHeavySuites {
    /// RD09 criterion 1's timing, recorded and not gated: pages 1 and 2 of
    /// every scope and `sourceSummaries()` over 50,000 articles in 100
    /// sources whose rows carry bodies of a few kilobytes.
    @Suite("Article list timing")
    struct ArticleListTimingTests {
        @Test("pages 1 and 2 of every scope and the source summaries at 50,000 articles, timed")
        func fiftyThousandArticles() async throws {
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let library = try await LibraryStore(directory: directory, cacheRoot: directory.appending(path: "Images")).openNormal()
            var categories: [UUID] = []
            for index in 0..<10 {
                categories.append(try await library.createCategory(name: "Category \(index)", icon: .folder).id)
            }
            var sources: [UUID] = []
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            for index in 0..<100 {
                let source = Sample.source(
                    in: categories[index % 10], url: "https://source\(index).example.invalid/feed", name: "Source \(index)", at: start
                )
                try await library.insert(source)
                sources.append(source.id)
            }
            let body = "<p>" + String(repeating: "A paragraph of feed HTML kept with the article. ", count: 60) + "</p>"
            let sourceKeys = sources.map(\.databaseKey)
            let seeding = ContinuousClock.now
            try await library.pool.write { db in
                let insert = try db.makeStatement(sql: """
                    INSERT INTO article (id, source_id, external_id, url, title, excerpt, author, image_url,
                                         published_at, first_seen_at, read_at, starred_at, content_html)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """)
                for index in 0..<50_000 {
                    let firstSeen = start.addingTimeInterval(TimeInterval(index * 60))
                    // Most are dated a little before they were seen; some are undated.
                    let published: Date? = index % 10 == 0 ? nil : firstSeen.addingTimeInterval(-TimeInterval(index % 7_200))
                    try insert.execute(arguments: [
                        UUID().databaseKey, sourceKeys[index % 100], "ext-\(index)", "https://example.invalid/a/\(index)",
                        "Article \(index) with a title of ordinary length", "An excerpt of a sentence or two for article \(index).",
                        "Author", index % 4 == 0 ? "https://example.invalid/i/\(index).jpg" : nil,
                        published, firstSeen, index % 3 == 0 ? firstSeen : nil, index % 97 == 0 ? firstSeen : nil, body,
                    ])
                }
            }
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: directory.appending(path: "normal.sqlite").path)[.size] as? Int) ?? 0
            print("RD09 timing: seeded 50,000 articles in 100 sources in \(ContinuousClock.now - seeding); database \(fileSize / 1_048_576) MB")

            let clock = ContinuousClock()
            func time(_ name: String, _ operation: () async throws -> Int) async throws {
                var durations: [Duration] = []
                var count = 0
                for _ in 0..<5 {
                    let started = clock.now
                    count = try await operation()
                    durations.append(clock.now - started)
                }
                let first = durations[0]
                let median = durations.sorted()[2]
                print("RD09 timing: \(name): first \(first.milliseconds) ms, median of 5 \(median.milliseconds) ms (\(count) rows)")
            }
            let cases: [(String, ArticleScope, ArticleFilter)] = [
                ("all unread", .library, .unread),
                ("starred", .starred, .all),
                ("category, unread", .category(categories[3]), .unread),
                ("category, all", .category(categories[3]), .all),
                ("source, unread", .source(sources[42]), .unread),
                ("source, all", .source(sources[42]), .all),
            ]
            for (name, scope, filter) in cases {
                var conditions: [String] = []
                var arguments: [(any DatabaseValueConvertible)?] = []
                Library.appendListConditions(scope, filter: filter, to: &conditions, arguments: &arguments)
                let sql = "EXPLAIN QUERY PLAN " + Library.articleRowsSQL(where: conditions)
                let planArguments = StatementArguments(arguments + [200])
                let plan = try await library.pool.read { db in
                    try Row.fetchAll(db, sql: sql, arguments: planArguments).map { $0["detail"] as String }
                }
                print("RD09 timing: \(name): plan \(plan)")
                try await time("\(name), page 1") {
                    try await library.articleRows(scope, filter: filter).count
                }
                let first = try await library.articleRows(scope, filter: filter)
                try await time("\(name), page 2") {
                    try await library.articleRows(scope, filter: filter, after: first.last?.position).count
                }
                // The second page continues the first.
                let both = try await library.articleRows(scope, filter: filter, limit: 400).map(\.id)
                let second = try await library.articleRows(scope, filter: filter, after: first.last?.position).map(\.id)
                #expect(first.map(\.id) + second == both, "\(name)")
            }
            try await time("sourceSummaries()") {
                try await library.sourceSummaries().count
            }
            #expect(try await library.sourceSummaries().reduce(0) { $0 + $1.articleCount } == 50_000)
        }
    }
}

private extension Duration {
    var milliseconds: String {
        let (seconds, attoseconds) = components
        return String(format: "%.1f", Double(seconds) * 1_000 + Double(attoseconds) / 1e15)
    }
}
