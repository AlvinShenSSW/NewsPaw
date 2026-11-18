import Foundation

/// The device's local day of an overview (spec N07; RD23 decision 3). Pure.
///
/// A day's key is the year, month and day of an instant in a Gregorian
/// calendar set to the given calendar's time zone, written `yyyy-MM-dd`, so
/// that keys sort as days do whatever calendar the device uses. A day's
/// start is the calendar's `startOfDay`, as RD14's daily limit takes it.
public enum OverviewDay {
    /// How many days the overviews are kept and browsed: today and the six
    /// before it (decision 9 of the spec review).
    public static let keptDays = 7

    /// The key of the local day that holds `date`.
    public static func key(for date: Date, calendar: Calendar) -> String {
        let components = gregorian(calendar).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// Where the local day that holds `date` starts.
    public static func start(of date: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: date)
    }

    /// The key of the day `days` days before the day that holds `date`
    /// (negative: after it).
    public static func key(daysBefore days: Int, _ date: Date, calendar: Calendar) -> String {
        let gregorian = gregorian(calendar)
        let start = gregorian.startOfDay(for: date)
        // Noon of the day: adding whole days to it never lands on a day
        // that a daylight-saving change shortened or lengthened by an hour.
        let noon = gregorian.date(byAdding: .hour, value: 12, to: start) ?? start
        let moved = gregorian.date(byAdding: .day, value: -days, to: noon) ?? noon
        return key(for: moved, calendar: calendar)
    }

    /// The oldest key of the window that holds `date`: six days before
    /// today. Rows with an older key are cleaned up (decision 15).
    public static func oldestKept(_ date: Date, calendar: Calendar) -> String {
        key(daysBefore: keptDays - 1, date, calendar: calendar)
    }

    /// The next local midnight after `date`: when the day's key changes.
    public static func nextStart(after date: Date, calendar: Calendar) -> Date {
        // A day lasts 23 to 25 hours: 36 hours after its start is always
        // inside the next one.
        calendar.startOfDay(for: calendar.startOfDay(for: date).addingTimeInterval(36 * 60 * 60))
    }

    private static func gregorian(_ calendar: Calendar) -> Calendar {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        gregorian.locale = Locale(identifier: "en_US_POSIX")
        return gregorian
    }
}
