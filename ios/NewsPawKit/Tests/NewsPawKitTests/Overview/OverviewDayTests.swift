import Foundation
@testable import NewsPawKit
import Testing

/// RD23 decision 3 and criterion 12's pure part: a day's key and start in
/// the device's zone, across a daylight-saving change, and assumption A5
/// (the calendar's day start and the Gregorian key agree) as measured on
/// the platform the suite runs on.
@Suite("Overview days")
struct OverviewDayTests {
    static func calendar(_ zone: String, _ identifier: Calendar.Identifier = .gregorian) -> Calendar {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    /// An instant given as local wall-clock time in `zone`.
    static func local(_ text: String, _ zone: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: zone)!
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)!
    }

    @Test("the key is the local day in the calendar's zone, yyyy-MM-dd")
    func keyInZone() {
        let instant = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00 UTC
        #expect(OverviewDay.key(for: instant, calendar: Self.calendar("UTC")) == "2027-01-15")
        #expect(OverviewDay.key(for: instant, calendar: Self.calendar("Pacific/Kiritimati")) == "2027-01-15")
        #expect(OverviewDay.key(for: instant, calendar: Self.calendar("Pacific/Pago_Pago")) == "2027-01-14")
        #expect(OverviewDay.key(for: instant, calendar: Self.calendar("Asia/Tokyo")) == "2027-01-15")
    }

    @Test("a Japanese-era calendar gives the same key as a Gregorian one in its zone")
    func japaneseCalendar() {
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(OverviewDay.key(for: instant, calendar: Self.calendar("Asia/Tokyo", .japanese)) == "2027-01-15")
        #expect(OverviewDay.oldestKept(instant, calendar: Self.calendar("Asia/Tokyo", .japanese)) == "2027-01-09")
    }

    /// The zones of A5: one whose change is at 02:00 and one whose change
    /// skips midnight itself.
    static let daylightSavingZones: [(zone: String, springDay: String, autumnDay: String)] = [
        ("America/New_York", "2026-03-08", "2026-11-01"),
        ("America/Santiago", "2026-09-06", "2026-04-05"),
    ]

    @Test("A5 / criterion 12: across a daylight-saving change the calendar's day start and the key agree, at 23:59 and at 00:01")
    func daylightSaving() {
        for (zone, spring, autumn) in Self.daylightSavingZones {
            let calendar = Self.calendar(zone)
            for day in [spring, autumn] {
                // Every quarter hour of the day of the change and of the
                // hours around it: the start of the day an instant is in has
                // that instant's key, and the second before it has the key of
                // the day before.
                let noon = Self.local("\(day) 12:00:00", zone)
                var instant = noon.addingTimeInterval(-36 * 3_600)
                while instant < noon.addingTimeInterval(36 * 3_600) {
                    let start = OverviewDay.start(of: instant, calendar: calendar)
                    #expect(OverviewDay.key(for: start, calendar: calendar) == OverviewDay.key(for: instant, calendar: calendar), "\(zone) \(instant)")
                    #expect(OverviewDay.key(for: start.addingTimeInterval(-1), calendar: calendar) == OverviewDay.key(daysBefore: 1, instant, calendar: calendar), "\(zone) \(instant)")
                    #expect(start <= instant)
                    instant = instant.addingTimeInterval(900)
                }
                #expect(OverviewDay.key(for: noon, calendar: calendar) == day)
            }
        }
    }

    @Test("criterion 12: 23:59 is still the day, 00:01 the next, on the night before a change in New York")
    func midnightAroundChange() {
        let zone = "America/New_York"
        let calendar = Self.calendar(zone)
        #expect(OverviewDay.key(for: Self.local("2026-03-07 23:59:00", zone), calendar: calendar) == "2026-03-07")
        #expect(OverviewDay.key(for: Self.local("2026-03-08 00:01:00", zone), calendar: calendar) == "2026-03-08")
        #expect(OverviewDay.start(of: Self.local("2026-03-08 23:59:00", zone), calendar: calendar) == Self.local("2026-03-08 00:00:00", zone))
        // A day of 23 hours: the next start is 23 hours after this one.
        let start = Self.local("2026-03-08 00:00:00", zone)
        #expect(OverviewDay.nextStart(after: start, calendar: calendar).timeIntervalSince(start) == 23 * 3_600)
        let autumn = Self.local("2026-11-01 00:00:00", zone)
        #expect(OverviewDay.nextStart(after: autumn.addingTimeInterval(60), calendar: calendar).timeIntervalSince(autumn) == 25 * 3_600)
    }

    @Test("criterion 12: the 7-day window is today and the six days before it, across a change, and moves at local midnight")
    func window() {
        let zone = "America/New_York"
        let calendar = Self.calendar(zone)
        #expect(OverviewDay.oldestKept(Self.local("2026-03-10 08:00:00", zone), calendar: calendar) == "2026-03-04")
        #expect(OverviewDay.oldestKept(Self.local("2026-03-10 23:59:59", zone), calendar: calendar) == "2026-03-04")
        #expect(OverviewDay.oldestKept(Self.local("2026-03-11 00:00:00", zone), calendar: calendar) == "2026-03-05")
        #expect(OverviewDay.oldestKept(Self.local("2026-11-03 00:30:00", zone), calendar: calendar) == "2026-10-28")
        #expect(OverviewDay.key(daysBefore: 1, Self.local("2026-03-09 00:30:00", zone), calendar: calendar) == "2026-03-08")
        #expect(OverviewDay.key(daysBefore: 1, Self.local("2026-11-02 00:30:00", zone), calendar: calendar) == "2026-11-01")
        #expect(OverviewDay.key(daysBefore: 31, Self.local("2027-03-01 12:00:00", zone), calendar: calendar) == "2027-01-29")
    }
}
