import Foundation

/// Reads the dates feeds write (spec N04). Each accepted form is matched
/// against the whole string, after surrounding white space is removed;
/// anything else is "no date".
///
/// - The RFC 822 family, as RSS writes it: an optional day name, day, month
///   name, a two- or four-digit year, hours and minutes with optional
///   seconds, then a numeric offset (`+0900`, `+09:00`), one of the zone
///   abbreviations in `zones`, or no zone at all (read as UTC). An
///   abbreviation that is not in the table means "no date".
/// - The ISO 8601 family, as Atom, JSON Feed and Dublin Core write it: a date
///   and time with `Z` or an offset, optional fractional seconds, or no zone
///   (read as UTC); and a date alone (midnight UTC).
///
/// The system's date formatters are not used: they do not know several of
/// these abbreviations, and in date-only mode they accept any string that
/// merely starts with a date.
enum FeedDate {
    /// The longest string looked at, in UTF-8 bytes, white space included.
    /// A date is at most 64 bytes once trimmed; the cap keeps a megabyte of
    /// "date" from being copied first.
    static let maximumBytes = 1_024

    static func parse(_ text: String) -> Date? {
        guard text.utf8.count <= maximumBytes else { return nil }
        let bytes = Array(text.utf8)
        var start = 0
        var end = bytes.count
        while start < end, isSpace(bytes[start]) { start += 1 }
        while end > start, isSpace(bytes[end - 1]) { end -= 1 }
        guard end > start, end - start <= 64 else { return nil }
        let slice = bytes[start..<end]
        if let first = slice.first, isDigit(first), slice.count >= 10, slice[slice.startIndex + 4] == UInt8(ascii: "-") {
            return parseISO8601(slice)
        }
        return parseRFC822(slice)
    }

    // MARK: - Zone abbreviations

    /// Offsets from UTC in minutes. `UTC` is accepted beside RFC 822's `UT`.
    static let zones: [String: Int] = [
        "UT": 0, "UTC": 0, "GMT": 0, "Z": 0,
        "JST": 9 * 60, "KST": 9 * 60,
        "AEST": 10 * 60, "AEDT": 11 * 60,
        "ACST": 9 * 60 + 30, "ACDT": 10 * 60 + 30,
        "AWST": 8 * 60,
        "CET": 60, "CEST": 2 * 60,
        "EST": -5 * 60, "EDT": -4 * 60,
        "CST": -6 * 60, "CDT": -5 * 60,
        "MST": -7 * 60, "MDT": -6 * 60,
        "PST": -8 * 60, "PDT": -7 * 60,
    ]

    private static let months: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
        "january": 1, "february": 2, "march": 3, "april": 4, "june": 6,
        "july": 7, "august": 8, "sept": 9, "september": 9, "october": 10,
        "november": 11, "december": 12,
    ]

    private static let dayNames: Set<String> = [
        "mon", "tue", "wed", "thu", "fri", "sat", "sun",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    ]

    // MARK: - RFC 822

    private static func parseRFC822(_ bytes: ArraySlice<UInt8>) -> Date? {
        var tokens = String(decoding: bytes, as: UTF8.self)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard !tokens.isEmpty else { return nil }

        // An optional day name, with or without its comma.
        var first = tokens[0]
        if first.hasSuffix(",") {
            first.removeLast()
            guard dayNames.contains(first.lowercased()) else { return nil }
            tokens.removeFirst()
        } else if dayNames.contains(first.lowercased()) {
            tokens.removeFirst()
            if tokens.first == "," {
                tokens.removeFirst()
            }
        }
        guard tokens.count == 4 || tokens.count == 5 else { return nil }

        guard let day = number(tokens[0], digits: 1...2),
              let month = months[tokens[1].lowercased()],
              let rawYear = number(tokens[2], digits: 2...4), tokens[2].count != 3
        else { return nil }
        let year = tokens[2].count == 2 ? (rawYear < 50 ? 2000 + rawYear : 1900 + rawYear) : rawYear

        let time = tokens[3].split(separator: ":", omittingEmptySubsequences: false)
        guard time.count == 2 || time.count == 3,
              let hour = number(String(time[0]), digits: 1...2),
              let minute = number(String(time[1]), digits: 2...2)
        else { return nil }
        var second = 0
        if time.count == 3 {
            guard let value = number(String(time[2]), digits: 2...2) else { return nil }
            second = value
        }

        var offset = 0
        if tokens.count == 5 {
            guard let value = zoneOffset(tokens[4]) else { return nil }
            offset = value
        }
        return makeDate(year: year, month: month, day: day, hour: hour, minute: minute, second: second, fraction: 0, offsetMinutes: offset)
    }

    /// A numeric offset (`+0900`, `-05:00`) or an abbreviation from `zones`.
    private static func zoneOffset(_ token: String) -> Int? {
        if let sign = token.first, sign == "+" || sign == "-" {
            return numericOffset(Array(token.utf8))
        }
        return zones[token.uppercased()]
    }

    // MARK: - ISO 8601

    private static func parseISO8601(_ bytes: ArraySlice<UInt8>) -> Date? {
        var index = bytes.startIndex
        func digits(_ count: Int) -> Int? {
            guard bytes.endIndex - index >= count else { return nil }
            var value = 0
            for _ in 0..<count {
                guard isDigit(bytes[index]) else { return nil }
                value = value * 10 + Int(bytes[index] - 48)
                index += 1
            }
            return value
        }
        func expect(_ character: Character) -> Bool {
            guard index < bytes.endIndex, bytes[index] == character.asciiValue else { return false }
            index += 1
            return true
        }

        guard let year = digits(4), expect("-"), let month = digits(2), expect("-"), let day = digits(2) else { return nil }
        if index == bytes.endIndex {
            return makeDate(year: year, month: month, day: day, hour: 0, minute: 0, second: 0, fraction: 0, offsetMinutes: 0)
        }
        guard index < bytes.endIndex, bytes[index] == UInt8(ascii: "T") || bytes[index] == UInt8(ascii: "t") || bytes[index] == UInt8(ascii: " ") else {
            return nil
        }
        index += 1
        guard let hour = digits(2), expect(":"), let minute = digits(2) else { return nil }
        var second = 0
        var fraction = 0.0
        if expect(":") {
            guard let value = digits(2) else { return nil }
            second = value
            if index < bytes.endIndex, bytes[index] == UInt8(ascii: ".") || bytes[index] == UInt8(ascii: ",") {
                index += 1
                var scale = 0.1
                var count = 0
                while index < bytes.endIndex, isDigit(bytes[index]) {
                    fraction += Double(bytes[index] - 48) * scale
                    scale /= 10
                    count += 1
                    index += 1
                }
                guard count > 0 else { return nil }
            }
        }
        var offset = 0
        if index < bytes.endIndex {
            let rest = Array(bytes[index...])
            if rest == [UInt8(ascii: "Z")] || rest == [UInt8(ascii: "z")] {
                offset = 0
            } else if let value = numericOffset(rest) {
                offset = value
            } else {
                return nil
            }
        }
        return makeDate(year: year, month: month, day: day, hour: hour, minute: minute, second: second, fraction: fraction, offsetMinutes: offset)
    }

    // MARK: - Shared

    /// `+HH`, `+HHMM` or `+HH:MM` (and the same with `-`), as minutes.
    private static func numericOffset(_ bytes: [UInt8]) -> Int? {
        guard let sign = bytes.first, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") else { return nil }
        let body = bytes.dropFirst().filter { $0 != UInt8(ascii: ":") }
        let colons = bytes.count - 1 - body.count
        guard body.allSatisfy(isDigit), body.count == 2 || body.count == 4, colons == 0 || (colons == 1 && body.count == 4 && bytes[3] == UInt8(ascii: ":")) else {
            return nil
        }
        let values = body.map { Int($0 - 48) }
        let hours = values[0] * 10 + values[1]
        let minutes = body.count == 4 ? values[2] * 10 + values[3] : 0
        guard hours <= 23, minutes <= 59 else { return nil }
        let total = hours * 60 + minutes
        return sign == UInt8(ascii: "-") ? -total : total
    }

    private static func number(_ token: String, digits: ClosedRange<Int>) -> Int? {
        guard digits.contains(token.utf8.count), token.utf8.allSatisfy(isDigit) else { return nil }
        return Int(token)
    }

    private static func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, fraction: Double, offsetMinutes: Int) -> Date? {
        guard (1...9999).contains(year), (1...12).contains(month), day >= 1, day <= daysInMonth(year: year, month: month),
              (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second)
        else { return nil }
        // A leap second is read as the last second of its minute.
        let seconds = daysFromCivil(year: year, month: month, day: day) * 86_400
            + hour * 3_600 + minute * 60 + min(second, 59) - offsetMinutes * 60
        return Date(timeIntervalSince1970: TimeInterval(seconds) + fraction)
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 48 && byte <= 57
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}
