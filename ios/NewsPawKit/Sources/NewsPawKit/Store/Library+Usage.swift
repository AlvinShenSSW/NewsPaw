import Foundation
import GRDB

/// A period of Settings › Usage (spec N11; RD17 decision 2): today, or
/// today and the 6 or 29 local days before it. A period has no upper
/// bound: a row stamped later than now (a clock set back) is in it, as the
/// daily automatic count includes it.
public enum UsagePeriod: String, Sendable, Hashable, CaseIterable {
    case today
    case sevenDays
    case thirtyDays

    /// How many local days before today the period begins.
    private var daysBeforeToday: Int {
        switch self {
        case .today: 0
        case .sevenDays: 6
        case .thirtyDays: 29
        }
    }

    /// The period's first instant: local midnight of today, moved back by
    /// whole local days in `calendar`, so that a daylight-saving change in
    /// between moves the instant and not the wall-clock time.
    public func start(now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        guard daysBeforeToday > 0, let earlier = calendar.date(byAdding: .day, value: -daysBeforeToday, to: today) else {
            return today
        }
        // A day whose midnight the zone skips begins at its first instant.
        return calendar.startOfDay(for: earlier)
    }
}

/// The requests of one model for one purpose in a period (spec N11; RD17
/// decision 3). Every sent request counts, whatever its outcome or whether
/// it was automatic. A count the service did not return adds nothing to
/// the sums and makes its request one "without tokens"; nothing is
/// converted to money.
public struct UsageTotal: Sendable, Hashable {
    /// The model name as sent.
    public let model: String
    public let purpose: UsagePurpose
    public let requests: Int
    /// The reported input tokens, summed; `Int.max` at most.
    public let inputTokens: Int
    /// The reported output tokens, summed; `Int.max` at most.
    public let outputTokens: Int
    /// The requests that lack the input count, the output count or both.
    public let requestsWithoutTokens: Int

    public init(model: String, purpose: UsagePurpose, requests: Int, inputTokens: Int, outputTokens: Int, requestsWithoutTokens: Int) {
        self.model = model
        self.purpose = purpose
        self.requests = requests
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.requestsWithoutTokens = requestsWithoutTokens
    }

    /// Whether at least one request reported both counts: otherwise the
    /// sums are not shown, only "Tokens unknown".
    public var hasTokens: Bool {
        requestsWithoutTokens < requests
    }
}

/// The usage totals of one library (spec N11; RD17 decision 3). Every query
/// works on this library alone: the totals of a partition are its own
/// rows.
extension Library {
    /// The totals per model and purpose of the requests at or after
    /// `start`, by model name and then in `UsagePurpose` order. One query
    /// over the `usage_at` index. `TOTAL` sums as a real number, so token
    /// counts from untrusted replies cannot make the query fail; each sum
    /// is brought back saturating at `Int.max`. A purpose outside
    /// `UsagePurpose` is skipped.
    public func usageTotals(since start: Date) async throws -> [UsageTotal] {
        let totals = try await read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT model, purpose, COUNT(*) AS requests,
                        TOTAL(input_tokens) AS input, TOTAL(output_tokens) AS output,
                        SUM(input_tokens IS NULL OR output_tokens IS NULL) AS unknown
                    FROM usage WHERE at >= ? GROUP BY model, purpose
                    """,
                arguments: [start]
            )
            .compactMap { row -> UsageTotal? in
                guard let purpose = UsagePurpose(rawValue: row["purpose"]) else { return nil }
                return UsageTotal(
                    model: row["model"], purpose: purpose, requests: row["requests"],
                    inputTokens: Self.saturatingCount(row["input"]), outputTokens: Self.saturatingCount(row["output"]),
                    requestsWithoutTokens: row["unknown"]
                )
            }
        }
        let order = Dictionary(uniqueKeysWithValues: UsagePurpose.allCases.enumerated().map { ($1, $0) })
        return totals.sorted { first, second in
            if first.model != second.model {
                return first.model < second.model
            }
            return order[first.purpose, default: 0] < order[second.purpose, default: 0]
        }
    }

    /// A sum of counts as a whole number: `Int.max` when it is beyond it.
    static func saturatingCount(_ sum: Double) -> Int {
        guard sum.isFinite, sum > 0 else { return 0 }
        guard sum < Double(Int.max) else { return Int.max }
        return Int(sum)
    }
}

#if DEBUG
// MARK: - UI-test seeding (debug builds only)

extension Library {
    /// Inserts five usage rows of the model `seed-<partition>` (RD17
    /// decision 8): two `titles` rows now, automatic, one with 100 / 20
    /// tokens and one without; and, manual, a `body` row at noon 3 days
    /// ago, a `page` row 20 days ago and an `overview` row 40 days ago.
    /// Does nothing when a row of that model exists, so running it again
    /// is harmless. Compiled into debug builds only; release builds do not
    /// contain it.
    public func insertUsageForUITests(calendar: Calendar) async throws {
        let model = "seed-\(partition.rawValue)"
        let now = now()
        let today = calendar.startOfDay(for: now)
        func noon(daysAgo: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today
            return calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: day)) ?? day
        }
        let rows = [
            UsageRecord(id: UUID(), model: model, purpose: .titles, inputTokens: 100, outputTokens: 20, outcome: .ok, at: now, automatic: true),
            UsageRecord(id: UUID(), model: model, purpose: .titles, inputTokens: nil, outputTokens: nil, outcome: .unreachable, at: now,
                        automatic: true),
            UsageRecord(id: UUID(), model: model, purpose: .body, inputTokens: 300, outputTokens: 50, outcome: .ok, at: noon(daysAgo: 3),
                        automatic: false),
            UsageRecord(id: UUID(), model: model, purpose: .page, inputTokens: 1_000, outputTokens: 200, outcome: .ok,
                        at: noon(daysAgo: 20), automatic: false),
            UsageRecord(id: UUID(), model: model, purpose: .overview, inputTokens: 5_000, outputTokens: 500, outcome: .ok,
                        at: noon(daysAgo: 40), automatic: false),
        ]
        try await write { db in
            let existing = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage WHERE model = ?", arguments: [model]) ?? 0
            guard existing == 0 else { return }
            for row in rows {
                try row.insert(db)
            }
        }
    }
}
#endif
