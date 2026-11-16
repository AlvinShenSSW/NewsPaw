import Foundation
@testable import NewsPawKit
import Testing

/// RD18 criterion 8: the lock rule of decision 8, as a table, with a
/// stubbed clock; and criterion 9's rule for the cover.
@Suite("Lock timing")
struct LockTimingTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("the settings are immediately, one minute and five minutes, stored as seconds")
    func values() {
        #expect(LockTiming.allCases.map(\.rawValue) == [0, 60, 300])
        #expect(LockTiming(rawValue: 0) == .immediately)
        #expect(LockTiming(rawValue: 61) == nil)
    }

    @Test("only immediately locks at did-enter-background")
    func enteringBackground() {
        #expect(LockRule.locksOnEnteringBackground(.immediately))
        #expect(!LockRule.locksOnEnteringBackground(.afterOneMinute))
        #expect(!LockRule.locksOnEnteringBackground(.afterFiveMinutes))
    }

    struct Row: Sendable, CustomStringConvertible {
        var timing: LockTiming
        /// Seconds away at did-activate; `nil` when the scene was not away.
        var away: TimeInterval?
        var enteredBackground: Bool
        var fallback: Bool
        var locks: Bool

        var description: String {
            "\(timing) away \(away.map { "\($0)" } ?? "-") background \(enteredBackground) fallback \(fallback) → \(locks)"
        }
    }

    static let rows: [Row] = [
        // Not away: nothing locks.
        Row(timing: .immediately, away: nil, enteredBackground: false, fallback: true, locks: false),
        Row(timing: .afterOneMinute, away: nil, enteredBackground: false, fallback: true, locks: false),
        // Immediately: the background locks whatever the time.
        Row(timing: .immediately, away: 0, enteredBackground: true, fallback: false, locks: true),
        Row(timing: .immediately, away: 1, enteredBackground: true, fallback: true, locks: true),
        // Immediately, never in the background, without the fallback: a
        // glance, however long, does not lock.
        Row(timing: .immediately, away: 1, enteredBackground: false, fallback: false, locks: false),
        Row(timing: .immediately, away: 600, enteredBackground: false, fallback: false, locks: false),
        // With the fallback: five seconds or more locks, less does not, and
        // a negative time locks.
        Row(timing: .immediately, away: 4.9, enteredBackground: false, fallback: true, locks: false),
        Row(timing: .immediately, away: 5, enteredBackground: false, fallback: true, locks: true),
        Row(timing: .immediately, away: 600, enteredBackground: false, fallback: true, locks: true),
        Row(timing: .immediately, away: -1, enteredBackground: false, fallback: true, locks: true),
        // One minute: by the time away alone, in the background or not.
        Row(timing: .afterOneMinute, away: 59.9, enteredBackground: true, fallback: true, locks: false),
        Row(timing: .afterOneMinute, away: 59.9, enteredBackground: false, fallback: true, locks: false),
        Row(timing: .afterOneMinute, away: 60, enteredBackground: true, fallback: false, locks: true),
        Row(timing: .afterOneMinute, away: 60, enteredBackground: false, fallback: false, locks: true),
        Row(timing: .afterOneMinute, away: 3_600, enteredBackground: true, fallback: false, locks: true),
        // The clock was set back while away.
        Row(timing: .afterOneMinute, away: -0.5, enteredBackground: true, fallback: false, locks: true),
        Row(timing: .afterOneMinute, away: -86_400, enteredBackground: false, fallback: false, locks: true),
        // Five minutes.
        Row(timing: .afterFiveMinutes, away: 60, enteredBackground: true, fallback: true, locks: false),
        Row(timing: .afterFiveMinutes, away: 299.9, enteredBackground: true, fallback: true, locks: false),
        Row(timing: .afterFiveMinutes, away: 300, enteredBackground: true, fallback: false, locks: true),
        Row(timing: .afterFiveMinutes, away: -1, enteredBackground: true, fallback: false, locks: true),
    ]

    @Test("the rule at did-activate", arguments: rows)
    func activating(row: Row) {
        let began = row.away.map { _ in start }
        let now = start.addingTimeInterval(row.away ?? 0)
        #expect(
            LockRule.locksOnActivating(
                row.timing, awayBegan: began, now: now, enteredBackground: row.enteredBackground, fallback: row.fallback
            ) == row.locks
        )
    }

    // MARK: - One absence

    @Test("away begins at the first will-deactivate; a later one does not move it")
    func repeatedDeactivations() {
        var absence = Absence()
        #expect(!absence.isAway)
        absence.willDeactivate(at: start)
        // The system's prompt, the app switcher, another deactivation: the
        // absence is counted from the first.
        absence.willDeactivate(at: start.addingTimeInterval(50))
        absence.willDeactivate(at: start.addingTimeInterval(58))
        #expect(absence.began == start)

        // 61 seconds after the first; 3 after the last.
        do {
            let locks = absence.didActivate(at: start.addingTimeInterval(61), timing: .afterOneMinute, fallback: false)
            #expect(locks)
        }
        // Did-activate ended the absence.
        #expect(!absence.isAway)
        #expect(absence == Absence())
    }

    @Test("a short absence under one minute does not lock, and the next absence starts anew")
    func shortAbsences() {
        var absence = Absence()
        absence.willDeactivate(at: start)
        do {
            let locks = absence.didEnterBackground(at: start.addingTimeInterval(1), timing: .afterOneMinute)
            #expect(!locks)
        }
        do {
            let locks = absence.didActivate(at: start.addingTimeInterval(40), timing: .afterOneMinute, fallback: true)
            #expect(!locks)
        }
        // Forty seconds later another forty seconds away: eighty since the
        // first absence began, and still no lock.
        absence.willDeactivate(at: start.addingTimeInterval(80))
        do {
            let locks = absence.didActivate(at: start.addingTimeInterval(120), timing: .afterOneMinute, fallback: true)
            #expect(!locks)
        }
    }

    @Test("immediately: the background locks at once; an absence that never entered it locks by the fallback only")
    func immediately() {
        var absence = Absence()
        absence.willDeactivate(at: start)
        do {
            let locks = absence.didEnterBackground(at: start.addingTimeInterval(0.5), timing: .immediately)
            #expect(locks)
        }
        #expect(absence.enteredBackground)
        // What did-activate answers after that (the Settings screen of the
        // normal partition is closed by it).
        do {
            let locks = absence.didActivate(at: start.addingTimeInterval(2), timing: .immediately, fallback: false)
            #expect(locks)
        }

        // Control Centre for three seconds.
        absence.willDeactivate(at: start)
        do {
            let locks = absence.didActivate(at: start.addingTimeInterval(3), timing: .immediately, fallback: true)
            #expect(!locks)
        }
        // A window left for ten seconds without the background.
        absence.willDeactivate(at: start)
        do {
            let locks = absence.didActivate(at: start.addingTimeInterval(10), timing: .immediately, fallback: true)
            #expect(locks)
        }
        absence.willDeactivate(at: start)
        do {
            let locks = absence.didActivate(at: start.addingTimeInterval(10), timing: .immediately, fallback: false)
            #expect(!locks)
        }
    }

    @Test("the background without a will-deactivate before it begins the absence")
    func backgroundFirst() {
        var absence = Absence()
        do {
            let locks = absence.didEnterBackground(at: start, timing: .afterFiveMinutes)
            #expect(!locks)
        }
        #expect(absence.began == start)
        do {
            let locks = absence.didActivate(at: start.addingTimeInterval(300), timing: .afterFiveMinutes, fallback: false)
            #expect(locks)
        }
    }

    @Test("did-activate without an absence locks nothing")
    func activateWithoutAbsence() {
        var absence = Absence()
        for timing in LockTiming.allCases {
            do {
                let locks = absence.didActivate(at: start, timing: timing, fallback: true)
                #expect(!locks)
            }
        }
    }

    @Test("the clock set back while away locks under a timed setting")
    func clockSetBack() {
        var absence = Absence()
        absence.willDeactivate(at: start)
        do {
            let locks = absence.didActivate(at: start.addingTimeInterval(-30), timing: .afterFiveMinutes, fallback: false)
            #expect(locks)
        }
    }

    // MARK: - Criterion 9: the cover's rule

    @Test("criterion 9: the cover is shown exactly while the adult workspace is shown and the scene is not active")
    func cover() {
        #expect(CoverRule.isShown(adultIsShown: true, sceneIsActive: false))
        #expect(!CoverRule.isShown(adultIsShown: true, sceneIsActive: true))
        #expect(!CoverRule.isShown(adultIsShown: false, sceneIsActive: false))
        #expect(!CoverRule.isShown(adultIsShown: false, sceneIsActive: true))
    }
}
