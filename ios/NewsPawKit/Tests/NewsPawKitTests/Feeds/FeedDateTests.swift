import Foundation
@testable import NewsPawKit
import Testing

@Suite("Feed dates")
struct FeedDateTests {
    /// 2026-11-10 08:00:00 UTC.
    static let eightUTC = Date(timeIntervalSince1970: 1_794_297_600)

    @Test("the reference instant is what the tests assume")
    func reference() {
        #expect(ISO8601DateFormatter().string(from: Self.eightUTC) == "2026-11-10T08:00:00Z")
    }

    @Test(
        "RFC 822 dates with each listed zone abbreviation",
        arguments: [
            ("UT", 0), ("UTC", 0), ("GMT", 0), ("Z", 0), ("JST", 540), ("KST", 540), ("AEST", 600), ("AEDT", 660),
            ("ACST", 570), ("ACDT", 630), ("AWST", 480), ("CET", 60), ("CEST", 120), ("EST", -300), ("EDT", -240),
            ("CST", -360), ("CDT", -300), ("MST", -420), ("MDT", -360), ("PST", -480), ("PDT", -420),
        ]
    )
    func rfc822Abbreviations(_ zone: String, _ minutes: Int) {
        let expected = Self.eightUTC.addingTimeInterval(TimeInterval(-minutes * 60))
        #expect(FeedDate.parse("Tue, 10 Nov 2026 08:00:00 \(zone)") == expected)
        #expect(FeedDate.parse("Tue, 10 Nov 2026 08:00:00 \(zone.lowercased())") == expected)
    }

    @Test(
        "RFC 822 dates with numeric offsets and the usual variations",
        arguments: [
            ("Tue, 10 Nov 2026 08:00:00 +0000", 0),
            ("Tue, 10 Nov 2026 17:00:00 +0900", 0),
            ("Tue, 10 Nov 2026 03:00:00 -0500", 0),
            ("Tue, 10 Nov 2026 17:00:00 +09:00", 0),
            ("10 Nov 2026 08:00:00 GMT", 0),
            ("Tue, 10 Nov 2026 08:00 GMT", 0),
            ("Tue, 10 Nov 26 08:00:00 GMT", 0),
            ("Tuesday, 10 November 2026 08:00:00 GMT", 0),
            ("Tue 10 Nov 2026 08:00:00 GMT", 0),
            ("  Tue,  10 Nov 2026 08:00:00 GMT\n", 0),
            ("Tue, 10 Nov 2026 8:00:00 GMT", 0),
            ("Tue, 10 Nov 2026 08:00:30 GMT", 30),
            ("Tue, 10 Nov 2026 08:00:00", 0),
        ]
    )
    func rfc822Forms(_ text: String, _ extraSeconds: Int) {
        #expect(FeedDate.parse(text) == Self.eightUTC.addingTimeInterval(TimeInterval(extraSeconds)), "\(text)")
    }

    @Test(
        "ISO 8601 dates: with Z or an offset, fractional seconds, no zone, date only",
        arguments: [
            ("2026-11-10T08:00:00Z", 0.0),
            ("2026-11-10t08:00:00z", 0.0),
            ("2026-11-10T17:00:00+09:00", 0.0),
            ("2026-11-10T17:00:00+0900", 0.0),
            ("2026-11-10T03:00:00-05", 0.0),
            ("2026-11-10T08:00:00.250Z", 0.25),
            ("2026-11-10T08:00:00,5+00:00", 0.5),
            ("2026-11-10T08:00Z", 0.0),
            ("2026-11-10T08:00:00", 0.0),
            ("2026-11-10 08:00:00", 0.0),
            ("2026-11-10 17:00:00 +09:00", Double.nan),
            ("2026-11-10", -8 * 3600.0),
        ]
    )
    func iso8601Forms(_ text: String, _ offset: Double) {
        if offset.isNaN {
            #expect(FeedDate.parse(text) == nil, "\(text)")
        } else {
            #expect(FeedDate.parse(text) == Self.eightUTC.addingTimeInterval(offset), "\(text)")
        }
    }

    @Test(
        "anything else is no date, including strings that merely start with a date and unknown abbreviations",
        arguments: [
            "", "   ", "yesterday", "now",
            "2026-11-10 is the day", "2026-11-10T08:00:00Zjunk", "2026-11-10T08:00:00Z Z", "2026-11-10X",
            "Tue, 10 Nov 2026 08:00:00 GMT extra", "Tue, 10 Nov 2026 08:00:00 BST", "Tue, 10 Nov 2026 08:00:00 XYZ",
            "Tue, 10 Nov 2026 08:00:00 A", "Tue, 10 Nov 2026 08:00:00 +9", "Tue, 10 Nov 2026 08:00:00 +09000",
            "Noday, 10 Nov 2026 08:00:00 GMT", "Tue, 10 Foo 2026 08:00:00 GMT", "Tue, 10 Nov 202 08:00:00 GMT",
            "Tue, 31 Nov 2026 08:00:00 GMT", "Tue, 10 Nov 2026 24:00:00 GMT", "Tue, 10 Nov 2026 08:60:00 GMT",
            "2026-02-29", "2026-13-01", "2026-00-10", "2026-11-31", "2026-11-10T25:00:00Z", "2026-11-10T08:00:00+25:00",
            "2026-11-10T08:00:00.Z", "2026/11/10", "10/11/2026", "1794297600",
        ]
    )
    func rejected(_ text: String) {
        #expect(FeedDate.parse(text) == nil, "\(text)")
    }

    @Test("leap days are valid only in leap years")
    func leapDays() {
        #expect(FeedDate.parse("2028-02-29") != nil)
        #expect(FeedDate.parse("2000-02-29T00:00:00Z") != nil)
        #expect(FeedDate.parse("2100-02-29") == nil)
        #expect(FeedDate.parse("Thu, 29 Feb 2024 00:00:00 GMT") != nil)
    }

    @Test("a 1970 date and a far date read correctly")
    func extremes() {
        #expect(FeedDate.parse("1970-01-01T00:00:00Z") == Date(timeIntervalSince1970: 0))
        #expect(FeedDate.parse("1969-12-31T23:59:59Z") == Date(timeIntervalSince1970: -1))
        #expect(FeedDate.parse("2400-03-01T00:00:00Z") == Date(timeIntervalSince1970: 13_574_649_600))
    }
}
