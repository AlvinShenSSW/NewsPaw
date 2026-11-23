import Foundation
import GRDB
@testable import NewsPawKit
import Testing

/// RD17: the periods of Settings › Usage, the totals per model and purpose,
/// today's automatic count, the partition of each, and the queries'
/// failures. Criteria 1, 2, 3, 7 (package) and 9 (package).
@Suite("Usage totals", .serialized)
struct UsageTotalsTests {
    // MARK: - Criterion 1: periods on the local day

    private static func instant(_ text: String) -> Date {
        // Whole seconds or milliseconds, in UTC.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = text.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        guard let date = formatter.date(from: text) else { fatalError("not an instant: \(text)") }
        return date
    }

    private static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    @Test("a period starts at local midnight today and 6 or 29 days before, in Shanghai and New York, across both daylight-saving changes",
          arguments: [
              // Shanghai (UTC+8, no daylight saving): mid-morning.
              ("Asia/Shanghai", "2026-11-16T02:30:00Z", "2026-11-15T16:00:00Z", "2026-11-09T16:00:00Z", "2026-10-17T16:00:00Z"),
              // Shanghai, exactly at midnight: the new day.
              ("Asia/Shanghai", "2026-11-15T16:00:00Z", "2026-11-15T16:00:00Z", "2026-11-09T16:00:00Z", "2026-10-17T16:00:00Z"),
              // Shanghai, the last millisecond of the day before.
              ("Asia/Shanghai", "2026-11-15T15:59:59.999Z", "2026-11-14T16:00:00Z", "2026-11-08T16:00:00Z", "2026-10-16T16:00:00Z"),
              // New York, the day after summer time ended (1 November 2026):
              // today is EST (UTC-5), 6 and 29 days before are EDT (UTC-4).
              ("America/New_York", "2026-11-02T14:00:00Z", "2026-11-02T05:00:00Z", "2026-10-27T04:00:00Z", "2026-10-04T04:00:00Z"),
              // New York, on the 25-hour day itself: it began in EDT.
              ("America/New_York", "2026-11-01T17:00:00Z", "2026-11-01T04:00:00Z", "2026-10-26T04:00:00Z", "2026-10-03T04:00:00Z"),
              // New York, the day after summer time began (8 March 2026):
              // today is EDT, 6 and 29 days before are EST.
              ("America/New_York", "2026-03-09T16:00:00Z", "2026-03-09T04:00:00Z", "2026-03-03T05:00:00Z", "2026-02-08T05:00:00Z"),
          ])
    func periodStarts(zone: String, now: String, today: String, sevenDays: String, thirtyDays: String) {
        let calendar = Self.calendar(zone)
        let now = Self.instant(now)
        #expect(UsagePeriod.today.start(now: now, calendar: calendar) == Self.instant(today))
        #expect(UsagePeriod.sevenDays.start(now: now, calendar: calendar) == Self.instant(sevenDays))
        #expect(UsagePeriod.thirtyDays.start(now: now, calendar: calendar) == Self.instant(thirtyDays))
    }

    // MARK: - Criteria 1, 2, 3: the totals equal a count over the rows

    /// One row to insert, by its offset from a period's start.
    private struct Row {
        let model: String
        let purpose: UsagePurpose
        let input: Int?
        let output: Int?
        let outcome: UsageOutcome
        let at: Date
        let automatic: Bool

        var record: UsageRecord {
            UsageRecord(id: UUID(), model: model, purpose: purpose, inputTokens: input, outputTokens: output, outcome: outcome,
                        at: at, automatic: automatic)
        }
    }

    /// The totals a period should show, computed over the rows in Swift.
    private static func expected(_ rows: [Row], since start: Date) -> Set<UsageTotal> {
        let inPeriod = rows.filter { $0.at >= start }
        let groups = Dictionary(grouping: inPeriod) { "\($0.model)|\($0.purpose.rawValue)" }
        return Set(groups.values.map { group in
            UsageTotal(
                model: group[0].model, purpose: group[0].purpose, requests: group.count,
                inputTokens: group.compactMap(\.input).reduce(0, +), outputTokens: group.compactMap(\.output).reduce(0, +),
                requestsWithoutTokens: group.filter { $0.input == nil || $0.output == nil }.count
            )
        })
    }

    private static let millisecond: TimeInterval = 0.001

    @Test("per period the totals per model and purpose equal a count over the rows; a row at a period's start is in it, one a millisecond before is not")
    func totalsMatchTheRows() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calendar = Self.calendar("Asia/Shanghai")
        let now = Self.instant("2026-11-16T02:30:00Z")
        let library = try await LibraryStore(directory: directory, now: { now }).openNormal()
        let today = UsagePeriod.today.start(now: now, calendar: calendar)
        let week = UsagePeriod.sevenDays.start(now: now, calendar: calendar)
        let month = UsagePeriod.thirtyDays.start(now: now, calendar: calendar)

        var rows: [Row] = []
        // Every purpose today, with a failed and a cancelled request.
        for (index, purpose) in UsagePurpose.allCases.enumerated() {
            rows.append(Row(model: "alpha", purpose: purpose, input: 10 + index, output: 1 + index, outcome: .ok,
                            at: now.addingTimeInterval(-60), automatic: purpose == .titles))
        }
        rows.append(Row(model: "alpha", purpose: .titles, input: nil, output: nil, outcome: .serverError, at: now, automatic: true))
        rows.append(Row(model: "alpha", purpose: .body, input: nil, output: nil, outcome: .cancelled, at: now, automatic: false))
        // Only one count reported: counted as unknown, the reported one added.
        rows.append(Row(model: "alpha", purpose: .titles, input: 7, output: nil, outcome: .ok, at: now, automatic: true))
        rows.append(Row(model: "alpha", purpose: .titles, input: nil, output: 3, outcome: .ok, at: now, automatic: false))
        // A model whose requests never report counts.
        rows.append(Row(model: "beta", purpose: .page, input: nil, output: nil, outcome: .ok, at: now, automatic: false))
        rows.append(Row(model: "beta", purpose: .page, input: nil, output: nil, outcome: .malformed, at: now, automatic: false))
        // The boundaries of each period: exactly at its start, a millisecond before.
        for start in [today, week, month] {
            rows.append(Row(model: "edge", purpose: .titles, input: 100, output: 10, outcome: .ok, at: start, automatic: true))
            rows.append(Row(model: "edge", purpose: .titles, input: 1_000, output: 100, outcome: .ok,
                            at: start.addingTimeInterval(-Self.millisecond), automatic: true))
        }
        // A row stamped later than now (a clock set back) is in every period.
        rows.append(Row(model: "edge", purpose: .overview, input: 5, output: 5, outcome: .ok, at: now.addingTimeInterval(3_600), automatic: false))
        for row in rows {
            try await library.insertUsage(row.record)
        }

        for (period, start) in [(UsagePeriod.today, today), (.sevenDays, week), (.thirtyDays, month)] {
            let totals = try await library.usageTotals(since: start)
            #expect(Set(totals) == Self.expected(rows, since: start), "\(period)")
            #expect(totals.count == Set(totals).count, "\(period): one total per model and purpose")
        }

        // Hand-checked values of today.
        let todays = try await library.usageTotals(since: today)
        let titles = try #require(todays.first { $0.model == "alpha" && $0.purpose == .titles })
        #expect(titles.requests == 4)
        #expect(titles.inputTokens == 10 + 7)
        #expect(titles.outputTokens == 1 + 3)
        #expect(titles.requestsWithoutTokens == 3)
        let beta = try #require(todays.first { $0.model == "beta" })
        #expect(beta.requests == 2 && beta.requestsWithoutTokens == 2 && beta.inputTokens == 0 && beta.outputTokens == 0)
        #expect(!beta.hasTokens)
        #expect(titles.hasTokens)
        // The edge rows: today holds the one at today's start only.
        let edge = try #require(todays.first { $0.model == "edge" && $0.purpose == .titles })
        #expect(edge.requests == 1 && edge.inputTokens == 100)
        let weekEdge = try #require(try await library.usageTotals(since: week).first { $0.model == "edge" && $0.purpose == .titles })
        #expect(weekEdge.requests == 3 && weekEdge.inputTokens == 100 + 1_000 + 100)
        let monthEdge = try #require(try await library.usageTotals(since: month).first { $0.model == "edge" && $0.purpose == .titles })
        #expect(monthEdge.requests == 5 && monthEdge.inputTokens == 100 + 1_000 + 100 + 1_000 + 100)
        // All five purposes are totalled, in the purposes' order.
        #expect(todays.filter { $0.model == "alpha" }.map(\.purpose) == UsagePurpose.allCases)

        // Today's automatic requests: the automatic rows from today's start.
        let automaticToday = rows.filter { $0.automatic && $0.at >= today }.count
        #expect(try await library.automaticRequestCount(since: today) == automaticToday)
        #expect(automaticToday == 4)
    }

    @Test("an empty period has no totals")
    func emptyPeriod() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Self.instant("2026-11-16T02:30:00Z")
        let library = try await LibraryStore(directory: directory, now: { now }).openNormal()
        #expect(try await library.usageTotals(since: .distantPast).isEmpty)
        try await library.insertUsage(Row(model: "old", purpose: .test, input: 1, output: 1, outcome: .ok,
                                          at: now.addingTimeInterval(-40 * 86_400), automatic: false).record)
        #expect(try await library.usageTotals(since: UsagePeriod.thirtyDays.start(now: now, calendar: Self.calendar("Asia/Shanghai"))).isEmpty)
    }

    @Test("criterion 3: two rows with input Int.max total to Int.max without trapping; output is still summed exactly")
    func sumsSaturate() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Self.instant("2026-11-16T02:30:00Z")
        let library = try await LibraryStore(directory: directory, now: { now }).openNormal()
        for _ in 0..<2 {
            try await library.insertUsage(Row(model: "huge", purpose: .titles, input: Int.max, output: 2, outcome: .ok,
                                              at: now, automatic: true).record)
        }
        let totals = try await library.usageTotals(since: .distantPast)
        #expect(totals == [UsageTotal(model: "huge", purpose: .titles, requests: 2, inputTokens: Int.max, outputTokens: 4,
                                      requestsWithoutTokens: 0)])
    }

    @Test("a purpose outside the closed set is skipped")
    func unknownPurposeSkipped() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try await LibraryStore(directory: directory).openNormal()
        try await library.pool.write { db in
            try db.execute(sql: """
                INSERT INTO usage (id, model, purpose, input_tokens, output_tokens, outcome, at, automatic)
                VALUES ('5b0c7a6e-0000-4000-8000-000000000017', 'm', 'future', 1, 2, 'ok', '2026-11-15 00:00:00.000', 0)
                """)
        }
        #expect(try await library.usageTotals(since: .distantPast).isEmpty)
    }

    // MARK: - Criterion 7 (package): two libraries of one store

    @Test("rows and a limit of the adult library are absent from the normal library's totals and limit, and the other way round")
    func partitionsKeepTheirOwn() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Self.instant("2026-11-16T02:30:00Z")
        let store = LibraryStore(directory: directory, now: { now })
        let normal = try await store.openNormal()
        let adult = try await store.createAdultLibrary()

        try await adult.insertUsage(Row(model: "adult-model", purpose: .titles, input: 5, output: 6, outcome: .ok,
                                        at: now, automatic: true).record)
        try await adult.setDailyAutomaticLimit(50)
        #expect(try await normal.usageTotals(since: .distantPast).isEmpty)
        #expect(try await normal.dailyAutomaticLimit() == Library.standardDailyAutomaticLimit)
        #expect(try await normal.automaticRequestCount(since: .distantPast) == 0)

        try await normal.insertUsage(Row(model: "normal-model", purpose: .test, input: 1, output: 1, outcome: .ok,
                                         at: now, automatic: false).record)
        try await normal.setDailyAutomaticLimit(500)
        #expect(try await adult.usageTotals(since: .distantPast).map(\.model) == ["adult-model"])
        #expect(try await adult.dailyAutomaticLimit() == 50)
        #expect(try await adult.automaticRequestCount(since: .distantPast) == 1)
        #expect(try await normal.usageTotals(since: .distantPast).map(\.model) == ["normal-model"])
        #expect(try await normal.dailyAutomaticLimit() == 500)
    }

    // MARK: - Criterion 9 (package): the queries fail

    @Test("on a library that cannot be read, the totals, the limit, the count and the write each throw")
    func queriesFail() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try await LibraryStore(directory: directory).openNormal()
        try library.close()
        await #expect(throws: LibraryError.self) { try await library.usageTotals(since: .distantPast) }
        await #expect(throws: LibraryError.self) { try await library.dailyAutomaticLimit() }
        await #expect(throws: LibraryError.self) { try await library.automaticRequestCount(since: .distantPast) }
        await #expect(throws: LibraryError.self) { try await library.setDailyAutomaticLimit(100) }
    }

    // MARK: - The UI tests' seeding (debug builds)

    #if DEBUG
    @Test("the seeding inserts five rows of seed-<partition> once, spread over the periods as the UI tests read them")
    func seeding() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calendar = Self.calendar("Asia/Shanghai")
        let now = Self.instant("2026-11-16T02:30:00Z")
        let store = LibraryStore(directory: directory, now: { now })
        let normal = try await store.openNormal()
        let adult = try await store.createAdultLibrary()
        try await normal.insertUsageForUITests(calendar: calendar)
        try await normal.insertUsageForUITests(calendar: calendar)
        try await adult.insertUsageForUITests(calendar: calendar)
        #expect(try await normal.usageRecords().count == 5)
        #expect(try await adult.usageRecords().map(\.model) == Array(repeating: "seed-adult", count: 5))

        func purposes(_ period: UsagePeriod) async throws -> [UsagePurpose] {
            try await normal.usageTotals(since: period.start(now: now, calendar: calendar)).map(\.purpose)
        }
        let today = try await normal.usageTotals(since: UsagePeriod.today.start(now: now, calendar: calendar))
        #expect(today == [UsageTotal(model: "seed-normal", purpose: .titles, requests: 2, inputTokens: 100, outputTokens: 20,
                                     requestsWithoutTokens: 1)])
        #expect(try await purposes(.sevenDays) == [.titles, .body])
        #expect(try await purposes(.thirtyDays) == [.titles, .body, .page])
        #expect(try await normal.automaticRequestCount(since: UsagePeriod.today.start(now: now, calendar: calendar)) == 2)
    }
    #endif
}
