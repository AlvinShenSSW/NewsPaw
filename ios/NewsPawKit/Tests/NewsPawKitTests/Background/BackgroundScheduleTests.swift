import Foundation
@testable import NewsPawKit
import Testing

/// RD24 criterion 2 and approach 3: the schedule's rule and its
/// reconciliation, with a recording scheduler.
@MainActor
@Suite("Background schedule")
struct BackgroundScheduleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("on with 15, 30 or 60 minutes: one request, earliest now plus the interval; off or Manual Only: none")
    func rule() {
        for interval in RefreshInterval.allCases {
            let on = BackgroundSchedule.action(enabled: true, interval: interval, now: now)
            if interval == .manualOnly {
                #expect(on == .cancel)
            } else {
                #expect(on == .submit(earliest: now.addingTimeInterval(TimeInterval(interval.rawValue) * 60)), "\(interval)")
            }
            #expect(BackgroundSchedule.action(enabled: false, interval: interval, now: now) == .cancel, "\(interval)")
        }
    }

    @Test("each reconciliation leaves one request pending while on, and none while off or Manual Only")
    func reconciliation() {
        let scheduler = RecordingScheduler()
        // Launch, a change of the interval, of the switch, the background,
        // a run's start: each is one reconciliation with the settings then.
        let steps: [(Bool, RefreshInterval, Date?)] = [
            (true, .thirtyMinutes, now.addingTimeInterval(1800)),
            (true, .fifteenMinutes, now.addingTimeInterval(900)),
            (false, .fifteenMinutes, nil),
            (true, .fifteenMinutes, now.addingTimeInterval(900)),
            (true, .manualOnly, nil),
            (true, .sixtyMinutes, now.addingTimeInterval(3600)),
        ]
        for (enabled, interval, pending) in steps {
            BackgroundSchedule.reconcile(enabled: enabled, interval: interval, now: now, scheduler: scheduler)
            #expect(scheduler.pending == pending, "\(enabled) \(interval)")
        }
        #expect(scheduler.submissions.count == 4)
        #expect(scheduler.cancellations == 2)
    }

    @Test("a refused submission is ignored and changes nothing else")
    func refusedSubmission() {
        let scheduler = RecordingScheduler()
        scheduler.refuses = true
        BackgroundSchedule.reconcile(enabled: true, interval: .thirtyMinutes, now: now, scheduler: scheduler)
        #expect(scheduler.submissions.count == 1)
        #expect(scheduler.cancellations == 0)
        #expect(scheduler.pending == nil)
    }
}
