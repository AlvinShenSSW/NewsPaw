import Foundation

/// Writes OPML 2.0 (RD08 decision 6): UTF-8 with an XML declaration, no
/// document type, a `head` with a title and the creation date, and one
/// top-level outline per category — an empty element when it holds no feed
/// — with its feeds inside.
public enum OPMLWriter {
    public struct Feed: Sendable, Hashable {
        public let name: String
        public let address: String
        public let siteAddress: String?

        public init(name: String, address: String, siteAddress: String?) {
            self.name = name
            self.address = address
            self.siteAddress = siteAddress
        }
    }

    public struct Folder: Sendable, Hashable {
        public let name: String
        public let feeds: [Feed]

        public init(name: String, feeds: [Feed]) {
            self.name = name
            self.feeds = feeds
        }
    }

    /// The file for `folders`, in their order, dated `created`.
    public static func document(_ folders: [Folder], created: Date) -> Data {
        var text = """
            <?xml version="1.0" encoding="UTF-8"?>
            <opml version="2.0">
              <head>
                <title>NewsPaw</title>
                <dateCreated>\(rfc822(created))</dateCreated>
              </head>
              <body>

            """
        for folder in folders {
            let name = attribute(folder.name)
            if folder.feeds.isEmpty {
                text += "    <outline text=\"\(name)\" title=\"\(name)\"/>\n"
                continue
            }
            text += "    <outline text=\"\(name)\" title=\"\(name)\">\n"
            for feed in folder.feeds {
                let feedName = attribute(feed.name)
                text += "      <outline text=\"\(feedName)\" title=\"\(feedName)\" type=\"rss\" xmlUrl=\"\(attribute(feed.address))\""
                if let site = feed.siteAddress {
                    text += " htmlUrl=\"\(attribute(site))\""
                }
                text += "/>\n"
            }
            text += "    </outline>\n"
        }
        text += "  </body>\n</opml>\n"
        return Data(text.utf8)
    }

    /// `value` for a double-quoted attribute: `&`, `<`, `>` and `"`
    /// escaped, tab, line feed and carriage return written as character
    /// references so that the parser keeps them, and characters XML 1.0
    /// does not allow dropped.
    static func attribute(_ value: String) -> String {
        var result = ""
        result.unicodeScalars.reserveCapacity(value.unicodeScalars.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "\t": result += "&#9;"
            case "\n": result += "&#10;"
            case "\r": result += "&#13;"
            default:
                // Char ::= #x9 | #xA | #xD | [#x20-#xD7FF] | [#xE000-#xFFFD]
                // | [#x10000-#x10FFFF]; Swift scalars are never surrogates.
                if scalar.value >= 0x20, scalar.value != 0xFFFE, scalar.value != 0xFFFF {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }

    /// RFC 822 with a four-digit year, in GMT, as OPML 2.0 asks.
    static func rfc822(_ date: Date) -> String {
        date.formatted(
            Date.VerbatimFormatStyle(
                format: "\(weekday: .abbreviated), \(day: .twoDigits) \(month: .abbreviated) \(year: .defaultDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits) GMT",
                locale: Locale(identifier: "en_US_POSIX"),
                timeZone: .gmt,
                calendar: Calendar(identifier: .gregorian)
            )
        )
    }
}
