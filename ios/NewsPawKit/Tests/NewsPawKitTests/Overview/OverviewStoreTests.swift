import Foundation
import GRDB
@testable import NewsPawKit
import Testing

/// RD23 decisions 2, 7, 9 (a), 11 (f), 13 and 15: the overview table, its
/// migration, the writer's reads and its guarded store, the screens'
/// reads, the mode, the clean-up, the cascade, the move and the slot
/// change (criteria 2, 4, 15's read, 16, 17 and 21).
@Suite("Overview store", .serialized)
struct OverviewStoreTests {
    static let utc = OverviewFixture.utc

    func record(
        _ category: UUID, day: String, locale: ReadingLocale = .simplifiedChinese, state: OverviewState = .done, text: String? = "Summary.",
        highlights: [OverviewHighlight] = [], failure: TranslationFailure? = nil, coveredUntil: Date? = nil
    ) -> OverviewRecord {
        OverviewRecord(
            categoryID: category, day: day, locale: locale, state: state, text: state == .done ? text : nil, highlights: highlights,
            articleCount: 3, coveredUntil: state == .done ? coveredUntil ?? Date(timeIntervalSince1970: 1_800_000_000) : nil,
            model: "m", failure: state == .failed ? failure ?? .refused : nil
        )
    }

    // MARK: - Criterion 21: the migration

    @Test("criterion 21: the overview migration creates the table with its columns, cascade and uniqueness")
    func table() async throws {
        let fixture = try await OverviewFixture.make(primary: false)
        defer { fixture.remove() }
        let (columns, keys, unique) = try await fixture.library.pool.read { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(overview)").map { row in
                SchemaTests.ColumnInfo(row["name"], row["type"], notNull: row["notnull"], default: row["dflt_value"], pk: row["pk"])
            }
            let keys = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(overview)").map { row in
                SchemaTests.ForeignKeyInfo(column: row["from"], table: row["table"], destination: row["to"], onDelete: row["on_delete"])
            }
            var unique: [[String]] = []
            for index in try Row.fetchAll(db, sql: "PRAGMA index_list(overview)") where (index["unique"] as Bool) {
                let name: String = index["name"]
                unique.append(try Row.fetchAll(db, sql: "PRAGMA index_info(\(name))").map { $0["name"] as String })
            }
            return (columns, keys, unique)
        }
        #expect(columns == [
            .init("id", "TEXT", notNull: true, pk: 1),
            .init("category_id", "TEXT", notNull: true),
            .init("day", "TEXT", notNull: true),
            .init("locale", "TEXT", notNull: true),
            .init("text", "TEXT", notNull: false),
            .init("highlights", "TEXT", notNull: true, default: "'[]'"),
            .init("article_count", "INTEGER", notNull: true, default: "0"),
            .init("covered_until", "TEXT", notNull: false),
            .init("model", "TEXT", notNull: false),
            .init("state", "TEXT", notNull: true),
            .init("error", "TEXT", notNull: false),
            .init("created_at", "TEXT", notNull: true),
        ])
        #expect(keys == [.init(column: "category_id", table: "category", destination: "id", onDelete: "CASCADE")])
        #expect(Set(unique) == [["id"], ["category_id", "day", "locale"]])
    }

    @Test("criterion 21: a library of the migration before the overview one, with rows in every table, migrates and keeps every row; the overview table starts empty")
    func previousVersionMigrates() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var beforeOverview = DatabaseMigrator()
        Schema.registerV1(in: &beforeOverview)
        Schema.registerV2(in: &beforeOverview)
        Schema.registerV3(in: &beforeOverview)
        Schema.registerV4(in: &beforeOverview)
        Schema.registerV5(in: &beforeOverview)
        Schema.registerV6(in: &beforeOverview)
        // The migrations before the overview one (batch 4: v7–v9).
        Schema.registerSearch(in: &beforeOverview)
        Schema.registerBodyTranslation(in: &beforeOverview)
        Schema.registerPageText(in: &beforeOverview)
        let clock = TestClock()
        let before: DatabaseSnapshot
        do {
            let library = try await LibraryStore(directory: directory, now: clock.now).open(.normal, migrator: beforeOverview, create: true)
            let world = try await library.createCategory(name: "World", icon: .globe)
            try await library.pool.write { db in
                try db.execute(sql: "UPDATE category SET overview = 'manual'")
            }
            let sources = try await Sample.fill(library, category: world.id, prefix: "v6", at: clock.now())
            let article = try await library.articles().first!
            try await library.storeTranslations([
                TranslationRecord(articleID: article.id, locale: .english, state: .done, title: "T", excerpt: nil, failure: nil, model: "m"),
            ])
            try await library.insertUsage(UsageRecord(
                id: UUID(), model: "m", purpose: .titles, inputTokens: 1, outputTokens: 1, outcome: .ok, at: clock.now(), automatic: true
            ))
            try await library.setLastRefreshAt(clock.now())
            #expect(sources.count == 2)
            before = try await library.pool.read { try DatabaseSnapshot.read($0) }
        }
        #expect(before.appliedMigrations == Array(currentMigrations.dropLast()))
        #expect(currentMigrations.last == Schema.overviewMigration)

        let library = try await LibraryStore(directory: directory).openNormal()

        let after = try await library.pool.read { try DatabaseSnapshot.read($0) }
        #expect(after.appliedMigrations == currentMigrations)
        for (table, rows) in before.rows where table != "grdb_migrations" {
            #expect(after.rows[table] == rows, "rows of \(table)")
        }
        #expect(after.rows["overview"] == [])
        #expect(after.integrity == ["ok"])
        #expect(before.schema.allSatisfy { after.schema.contains($0) })
        // The stored mode is read as it was.
        #expect(try await library.categories().first?.overview == .manual)
    }

    // MARK: - Criterion 17: the mode

    @Test("criterion 17: setCategoryOverview stores auto, manual and off with updated_at; new categories are auto; an unknown one throws")
    func mode() async throws {
        let fixture = try await OverviewFixture.make(primary: false)
        defer { fixture.remove() }
        let category = try await fixture.category()
        #expect(try await fixture.library.categories().first?.overview == .auto)
        for mode in [OverviewMode.manual, .off, .auto] {
            fixture.clock.advance()
            try await fixture.library.setCategoryOverview(category, to: mode)
            let stored = try await fixture.library.categories().first
            #expect(stored?.overview == mode)
            #expect(stored?.updatedAt == fixture.clock.now())
        }
        await #expect(throws: LibraryError.unknownCategory) {
            try await fixture.library.setCategoryOverview(UUID(), to: .off)
        }
    }

    @Test("criterion 17: Off deletes nothing")
    func offDeletesNothing() async throws {
        let fixture = try await OverviewFixture.make(primary: false)
        defer { fixture.remove() }
        let (category, _, _) = try await fixture.filledCategory()
        _ = try await fixture.library.storeOverview(record(category, day: fixture.today), sent: [], slots: [:])
        try await fixture.library.setCategoryOverview(category, to: .off)
        #expect(try await fixture.rows().count == 1)
    }

    // MARK: - The due rule and the input (gap 1, decision 2)

    @Test("gap 1: due is auto, no row that day in any locale, and an article first seen since the day's start; in the owner's order")
    func dueRule() async throws {
        let fixture = try await OverviewFixture.make(primary: false)
        defer { fixture.remove() }
        let now = fixture.clock.now()
        let start = OverviewDay.start(of: now, calendar: Self.utc)
        let (first, _, _) = try await fixture.filledCategory("First")
        let (manual, _, _) = try await fixture.filledCategory("Manual", mode: .manual)
        let (off, _, _) = try await fixture.filledCategory("Off", mode: .off)
        let (withRow, _, _) = try await fixture.filledCategory("With row")
        let (yesterdayOnly, yesterdaySource, _) = try await fixture.filledCategory("Yesterday", articles: 0)
        try await fixture.article("Old", in: yesterdaySource, at: start.addingTimeInterval(-1))
        let (atMidnight, midnightSource, _) = try await fixture.filledCategory("At midnight", articles: 0)
        try await fixture.article("Just after midnight", in: midnightSource, at: start)
        let (empty, _, _) = try await fixture.filledCategory("Empty", articles: 0)
        _ = try await fixture.library.storeOverview(record(withRow, day: fixture.today, locale: .japanese), sent: [], slots: [:])

        let due = try await fixture.library.overviewDueCategories(day: fixture.today, dayStart: start)

        #expect(due == [first, atMidnight])
        #expect(!due.contains(manual) && !due.contains(off) && !due.contains(withRow) && !due.contains(yesterdayOnly) && !due.contains(empty))
    }

    @Test("criterion 4: the input is the articles first seen after the newest earlier-day done overview's covered_until in the locale, else the last 24 hours")
    func inputAndAnchor() async throws {
        let fixture = try await OverviewFixture.make(primary: false)
        defer { fixture.remove() }
        let now = fixture.clock.now()
        let category = try await fixture.category()
        let source = try await fixture.source(in: category)
        let old = try await fixture.article("Two days old", in: source, at: now.addingTimeInterval(-2 * 86_400))
        let edge = try await fixture.article("Exactly 24 hours", in: source, at: now.addingTimeInterval(-86_400))
        let recent = try await fixture.article("Recent", in: source, at: now.addingTimeInterval(-3_600))
        let newest = try await fixture.article("Newest", in: source, at: now.addingTimeInterval(-60))

        // No earlier overview: the last 24 hours, the boundary included, newest first.
        var read = try await fixture.library.overviewJobRead(category: category, locale: .simplifiedChinese, now: now, calendar: Self.utc)
        #expect(read.input.map(\.id) == [newest, recent, edge])
        #expect(!read.input.map(\.id).contains(old))

        // An earlier day's done overview in this locale anchors at its covered_until (exclusive).
        let yesterday = OverviewDay.key(daysBefore: 1, now, calendar: Self.utc)
        let older = OverviewDay.key(daysBefore: 3, now, calendar: Self.utc)
        _ = try await fixture.library.storeOverview(
            record(category, day: yesterday, coveredUntil: now.addingTimeInterval(-3_600)), sent: [], slots: [:]
        )
        _ = try await fixture.library.storeOverview(
            record(category, day: older, coveredUntil: now.addingTimeInterval(-3 * 86_400)), sent: [], slots: [:]
        )
        // Of another locale, a failed one and today's: not anchors.
        _ = try await fixture.library.storeOverview(
            record(category, day: yesterday, locale: .english, coveredUntil: now.addingTimeInterval(-60)), sent: [], slots: [:]
        )
        _ = try await fixture.library.storeOverview(record(category, day: fixture.today, coveredUntil: now), sent: [], slots: [:])
        read = try await fixture.library.overviewJobRead(category: category, locale: .simplifiedChinese, now: now, calendar: Self.utc)
        #expect(read.input.map(\.id) == [newest])

        // In English the anchor is that locale's (60 s ago): nothing after it.
        read = try await fixture.library.overviewJobRead(category: category, locale: .english, now: now, calendar: Self.utc)
        #expect(read.input.isEmpty)
        // In Japanese there is none: the last 24 hours.
        read = try await fixture.library.overviewJobRead(category: category, locale: .japanese, now: now, calendar: Self.utc)
        #expect(read.input.map(\.id) == [newest, recent, edge])
        #expect(read.hasRowThatDay)
        #expect(read.day == fixture.today)
    }

    @Test("the input holds at most 40 articles, newest first in list order, without those with no letter; the count has no limit")
    func inputLimitAndCount() async throws {
        let fixture = try await OverviewFixture.make(primary: false)
        defer { fixture.remove() }
        let (category, source, ids) = try await fixture.filledCategory(articles: 45)
        try await fixture.article("1234", excerpt: "!!!", in: source)
        let read = try await fixture.library.overviewJobRead(category: category, locale: .english, now: fixture.clock.now(), calendar: Self.utc)
        #expect(read.input.map(\.id) == Array(ids.reversed().prefix(40)))
        let counts = try await fixture.library.overviewInputCounts(locale: .english, now: fixture.clock.now(), calendar: Self.utc)
        #expect(counts[category] == 45)
    }

    // MARK: - The guarded store (decision 11 (f))

    @Test("a done row replaces the row of its day and locale; a failed row never replaces a done row; a failed one is replaced by done")
    func conflicts() async throws {
        let fixture = try await OverviewFixture.make()
        defer { fixture.remove() }
        let (category, _, ids) = try await fixture.filledCategory()
        let slots = try await fixture.library.slotIdentities()
        let library = fixture.library
        #expect(try await library.storeOverview(record(category, day: "2027-01-15", state: .failed), sent: ids, slots: slots) == .stored)
        #expect(try await fixture.rows().map(\.state) == ["failed"])
        #expect(try await library.storeOverview(record(category, day: "2027-01-15", text: "One"), sent: ids, slots: slots) == .stored)
        #expect(try await library.storeOverview(record(category, day: "2027-01-15", text: "Two"), sent: ids, slots: slots) == .stored)
        #expect(try await library.storeOverview(record(category, day: "2027-01-15", state: .failed), sent: ids, slots: slots) == .doneKept)
        let rows = try await fixture.rows()
        #expect(rows.count == 1)
        #expect(rows.first?.state == "done")
        #expect(rows.first?.text == "Two")
        // Another locale is a row of its own.
        #expect(try await library.storeOverview(record(category, day: "2027-01-15", locale: .english), sent: ids, slots: slots) == .stored)
        #expect(try await fixture.rows().count == 2)
    }

    @Test("criterion 14: nothing is stored when the category is gone or a sent article no longer exists in it")
    func storeGuards() async throws {
        let fixture = try await OverviewFixture.make()
        defer { fixture.remove() }
        let (category, _, ids) = try await fixture.filledCategory()
        let (other, otherSource, _) = try await fixture.filledCategory("Other")
        let library = fixture.library
        let slots = try await library.slotIdentities()
        // An article of another category among those sent.
        let foreign = try await fixture.article("Elsewhere", in: otherSource)
        #expect(try await library.storeOverview(record(category, day: "2027-01-15"), sent: ids + [foreign], slots: slots) == .gone)
        // A sent article deleted.
        try await library.pool.write { db in try db.execute(sql: "DELETE FROM article WHERE id = ?", arguments: [ids[0].databaseKey]) }
        #expect(try await library.storeOverview(record(category, day: "2027-01-15"), sent: ids, slots: slots) == .gone)
        // The category deleted.
        try await library.deleteCategory(other, sources: .deleteSources)
        #expect(try await library.storeOverview(record(other, day: "2027-01-15"), sent: [], slots: slots) == .gone)
        #expect(try await fixture.rows().isEmpty)
    }

    @Test("decision 11 (f): a failed row needs the slots as the job read them on role, address, model and key, not the Test outcome")
    func failedRowSlotComparison() async throws {
        let fixture = try await OverviewFixture.make()
        defer { fixture.remove() }
        let (category, _, ids) = try await fixture.filledCategory()
        let library = fixture.library
        let slots = try await library.slotIdentities()
        let slot = try await library.modelSlot(.primary)!
        try await library.setModelTestOutcome(.passed, role: .primary, baseURL: slot.baseURL, model: slot.model, keyRef: slot.keyRef!)
        #expect(try await library.storeOverview(record(category, day: "2027-01-14", state: .failed), sent: ids, slots: slots) == .stored)
        try await fixture.saveSlot(.primary, model: "another-model")
        #expect(try await library.storeOverview(record(category, day: "2027-01-15", state: .failed), sent: ids, slots: slots) == .slotsChanged)
        // A done row does not compare slots.
        #expect(try await library.storeOverview(record(category, day: "2027-01-15"), sent: ids, slots: slots) == .stored)
    }

    // MARK: - Reading for the screens (criterion 15's read)

    @Test("criterion 15: a highlight is read only while its article exists and still belongs to the category; the summary stays")
    func highlightsFiltered() async throws {
        let fixture = try await OverviewFixture.make()
        defer { fixture.remove() }
        let (category, _, ids) = try await fixture.filledCategory()
        let other = try await fixture.category("Other")
        let movingSource = try await fixture.source(in: category, name: "Moving")
        let moving = try await fixture.article("Moves away", in: movingSource)
        let highlights = (ids + [moving]).map { OverviewHighlight(articleID: $0, text: "About \($0)") }
        _ = try await fixture.library.storeOverview(record(category, day: fixture.today, highlights: highlights), sent: [], slots: [:])
        #expect(try await fixture.library.overviews(on: fixture.today, locale: .simplifiedChinese)[category]?.highlights.count == 4)

        try await fixture.library.pool.write { db in try db.execute(sql: "DELETE FROM article WHERE id = ?", arguments: [ids[1].databaseKey]) }
        try await fixture.library.updateSource(movingSource, SourceChanges(categoryID: other))
        let read = try await fixture.library.overviews(on: fixture.today, locale: .simplifiedChinese)[category]
        #expect(read?.highlights.map(\.articleID) == [ids[0], ids[2]])
        #expect(read?.text == "Summary.")
        #expect(read?.state == .done)
        // Other locales and days are not read.
        #expect(try await fixture.library.overviews(on: fixture.today, locale: .english).isEmpty)
        #expect(try await fixture.library.overviews(on: "2000-01-01", locale: .simplifiedChinese).isEmpty)
    }

    @Test("Earlier Overviews: done rows of the locale in the window before today, newest first; failed and today's left out")
    func earlier() async throws {
        let fixture = try await OverviewFixture.make()
        defer { fixture.remove() }
        let category = try await fixture.category()
        let now = fixture.clock.now()
        for days in 0...7 {
            _ = try await fixture.library.storeOverview(
                record(category, day: OverviewDay.key(daysBefore: days, now, calendar: Self.utc), text: "Day -\(days)"), sent: [], slots: [:]
            )
        }
        _ = try await fixture.library.storeOverview(
            record(category, day: OverviewDay.key(daysBefore: 2, now, calendar: Self.utc), locale: .english), sent: [], slots: [:]
        )
        try await fixture.library.pool.write { db in
            try db.execute(sql: "UPDATE overview SET state = 'failed', text = NULL, error = 'refused' WHERE text = 'Day -3'")
        }
        let earlier = try await fixture.library.earlierOverviews(
            of: category, locale: .simplifiedChinese, from: OverviewDay.oldestKept(now, calendar: Self.utc), before: fixture.today
        )
        #expect(earlier.map(\.text) == ["Day -1", "Day -2", "Day -4", "Day -5", "Day -6"])
    }

    // MARK: - Criterion 16: clean-up, cascade, move

    @Test("criterion 16: clean-up deletes rows older than today minus six local days, whatever the article retention")
    func cleanUp() async throws {
        let fixture = try await OverviewFixture.make()
        defer { fixture.remove() }
        let category = try await fixture.category()
        let now = fixture.clock.now()
        for days in 0...9 {
            _ = try await fixture.library.storeOverview(
                record(category, day: OverviewDay.key(daysBefore: days, now, calendar: Self.utc)), sent: [], slots: [:]
            )
        }
        #expect(try await fixture.library.cleanUp(keeping: .forever) == 0)
        #expect(try await fixture.library.cleanUpOverviews(before: OverviewDay.oldestKept(now, calendar: Self.utc)) == 3)
        let days = try await fixture.rows().map(\.day)
        #expect(days.count == 7)
        #expect(days.min() == OverviewDay.key(daysBefore: 6, now, calendar: Self.utc))
    }

    @Test("criterion 16: deleting a category deletes its overviews; deleting a source leaves them")
    func cascade() async throws {
        let fixture = try await OverviewFixture.make()
        defer { fixture.remove() }
        let (category, source, _) = try await fixture.filledCategory()
        let (kept, _, _) = try await fixture.filledCategory("Kept")
        _ = try await fixture.library.storeOverview(record(category, day: fixture.today), sent: [], slots: [:])
        _ = try await fixture.library.storeOverview(record(kept, day: fixture.today), sent: [], slots: [:])
        try await fixture.library.deleteSource(source)
        #expect(try await fixture.rows(of: category).count == 1)
        try await fixture.library.deleteCategory(category, sources: .deleteSources)
        #expect(try await fixture.rows(of: category).isEmpty)
        #expect(try await fixture.rows(of: kept).count == 1)
    }

    @Test("criterion 16: a move deletes the moved category's overviews in the old library, also when it stays there", arguments: [true, false])
    func move(staying: Bool) async throws {
        let fixture = try await CategoryMoveTests.Fixture.make(toAdult: true, twin: staying)
        defer { fixture.remove() }
        let day = "2027-01-15"
        _ = try await fixture.old.storeOverview(record(fixture.category, day: day), sent: [], slots: [:])
        _ = try await fixture.old.storeOverview(record(fixture.kept, day: day), sent: [], slots: [:])
        let plan = try await fixture.plan()
        let outcome = await CategoryMove.run(plan, from: fixture.old, to: fixture.destination)
        #expect(outcome == .moved(staying: staying ? 1 : 0, categoryRemoved: !staying))
        let left = try await fixture.old.pool.read { db in
            try String.fetchAll(db, sql: "SELECT category_id FROM overview")
        }
        #expect(left == [fixture.kept.databaseKey])
        let copied = try await fixture.destination.pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM overview") ?? -1 }
        #expect(copied == 0, "overviews are not moved")
    }

    // MARK: - The slot change (decision 2, Storage)

    @Test("criterion 7: a slot save, a slot removal and a key removal each delete failed overviews, keep done ones and failed translations go too")
    func slotChangeDeletesFailures() async throws {
        let fixture = try await OverviewFixture.make(backup: true)
        defer { fixture.remove() }
        let (category, _, ids) = try await fixture.filledCategory()
        let library = fixture.library
        func seed() async throws {
            let slots = try await library.slotIdentities()
            _ = try await library.storeOverview(record(category, day: "2027-01-14", state: .failed), sent: ids, slots: slots)
            _ = try await library.storeOverview(record(category, day: "2027-01-15"), sent: ids, slots: slots)
            try await library.storeTranslations([
                TranslationRecord(articleID: ids[0], locale: .english, state: .failed, title: nil, excerpt: nil, failure: .refused, model: "m"),
            ])
        }
        for change in 0..<3 {
            try await seed()
            #expect(try await fixture.rows().map(\.state).sorted() == ["done", "failed"])
            switch change {
            case 0: try await fixture.saveSlot(.primary, model: "repaired-\(change)")
            case 1: try await fixture.models.removeKey(.backup)
            default: try await fixture.models.removeSlot(.backup)
            }
            #expect(try await fixture.rows().map(\.state) == ["done"], "change \(change)")
            #expect(try await library.translations(of: [ids[0]], locale: .english).isEmpty, "change \(change)")
        }
    }
}
