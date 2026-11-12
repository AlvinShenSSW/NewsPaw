#if DEBUG
import Foundation
import Synchronization

/// The transport of a debug build running under the UI tests (RD05
/// criterion 19): it answers a fixed table of synthetic documents and
/// reports every other address as unreachable, so no UI test reaches a real
/// host. Compiled into debug builds only; release builds do not contain it.
public final class FixtureTransport: Transport {
    /// The candidate limit the app uses with this transport, so that a
    /// declared feed that answers slowly is "not checked" in a second.
    public static let candidateLimit = Duration.seconds(1)
    /// How long the slow declared feed takes to answer.
    static let slowAnswer = Duration.seconds(3)

    /// The addresses of the table, in normal form.
    public enum Address {
        /// An RSS feed with three items.
        public static let feed = "https://feed.example.invalid/rss.xml"
        /// A page declaring two feeds, RSS and Atom.
        public static let twoFeeds = "https://twofeeds.example.invalid/"
        /// A page declaring one feed.
        public static let oneFeed = "https://onefeed.example.invalid/"
        /// A page with a title and no feed.
        public static let noFeed = "https://nofeed.example.invalid/"
        /// An address answering 403.
        public static let forbidden = "https://forbidden.example.invalid/"
        /// An address that does not answer.
        public static let unreachable = "https://unreachable.example.invalid/"
        /// An address whose exchange passes its deadline.
        public static let timesOut = "https://timeout.example.invalid/"
        /// A page declaring a feed that answers and one that answers only
        /// after the candidate limit.
        public static let slowFeeds = "https://slowfeeds.example.invalid/"
        /// The slow feed `slowFeeds` declares.
        public static let slowFeed = "https://slowfeeds.example.invalid/slow.xml"
        /// A feed that answers, then fails, then answers again, counted per
        /// transport.
        public static let sequence = "https://sequence.example.invalid/rss.xml"
        /// The suggested BBC World feed, answered with a synthetic feed.
        public static let suggested = "https://feeds.bbci.co.uk/news/world/rss.xml"
    }

    private let sequenceRequests = Mutex(0)

    public init() {}

    public func fetch(_ request: TransportRequest) async throws -> TransportResponse {
        try Task.checkCancellation()
        let url = request.url
        func answer(_ body: String, type: String, status: Int = 200) -> TransportResponse {
            TransportResponse(finalURL: url, status: status, headers: ["Content-Type": type], body: Data(body.utf8))
        }
        let rss = "application/rss+xml; charset=utf-8"
        let html = "text/html; charset=utf-8"
        switch url.absoluteString {
        case Address.feed:
            return answer(Self.rss(title: "Fixture Feed", items: ["Fixture story one", "Fixture story two", "Fixture story three"]), type: rss)
        case Address.twoFeeds:
            return answer(Self.page(title: "Two Feeds Site", links: [
                ("application/rss+xml", "/news.xml", "News"), ("application/atom+xml", "/atom.xml", "Updates"),
            ]), type: html)
        case "https://twofeeds.example.invalid/news.xml":
            return answer(Self.rss(title: "Two Feeds News", items: ["News story one", "News story two"]), type: rss)
        case "https://twofeeds.example.invalid/atom.xml":
            return answer(Self.atom(title: "Two Feeds Updates", items: ["Update one", "Update two"]), type: "application/atom+xml")
        case Address.oneFeed:
            return answer(Self.page(title: "One Feed Site", links: [("application/rss+xml", "/feed.xml", "Feed")]), type: html)
        case "https://onefeed.example.invalid/feed.xml":
            return answer(Self.rss(title: "One Feed", items: ["One feed story"]), type: rss)
        case Address.noFeed:
            return answer(Self.page(title: "Plain Page", links: []), type: html)
        case Address.forbidden:
            return answer("", type: html, status: 403)
        case Address.timesOut:
            throw TransportFailure.timedOut
        case Address.slowFeeds:
            return answer(Self.page(title: "Slow Feeds Site", links: [
                ("application/rss+xml", "/fast.xml", "Fast"), ("application/rss+xml", "/slow.xml", "Slow"),
            ]), type: html)
        case "https://slowfeeds.example.invalid/fast.xml":
            return answer(Self.rss(title: "Fast Feed", items: ["Fast story"]), type: rss)
        case Address.slowFeed:
            try await Task.sleep(for: Self.slowAnswer)
            return answer(Self.rss(title: "Slow Feed", items: ["Slow story"]), type: rss)
        case Address.sequence:
            let number = sequenceRequests.withLock { count in
                count += 1
                return count
            }
            if number == 2 {
                return answer("", type: html, status: 500)
            }
            return answer(Self.rss(title: "Sequence Feed", items: ["Sequence story \(number)"]), type: rss)
        case Address.suggested:
            return answer(Self.rss(title: "BBC News (fixture)", items: ["Fixture world story"]), type: rss)
        default:
            throw TransportFailure.unreachable
        }
    }

    // MARK: - Documents

    /// Items dated an hour apart, the first the newest, all in the past.
    private static func rss(title: String, items: [String]) -> String {
        let entries = items.enumerated().map { index, item in
            """
            <item><title>\(item)</title><link>https://example.invalid/\(slug(title))/\(slug(item))</link>\
            <guid>\(slug(title))-\(index)-\(item)</guid><pubDate>\(date(hoursAgo: index + 1))</pubDate></item>
            """
        }.joined(separator: "\n")
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <rss version="2.0"><channel><title>\(title)</title><link>https://example.invalid/\(slug(title))</link>
            \(entries)
            </channel></rss>
            """
    }

    private static func atom(title: String, items: [String]) -> String {
        let formatter = ISO8601DateFormatter()
        let entries = items.enumerated().map { index, item in
            """
            <entry><title>\(item)</title><id>urn:\(slug(title)):\(index)</id>\
            <link href="https://example.invalid/\(slug(title))/\(index)"/>\
            <updated>\(formatter.string(from: fixtureNow.addingTimeInterval(-3600 * Double(index + 1))))</updated></entry>
            """
        }.joined(separator: "\n")
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom"><title>\(title)</title><id>urn:\(slug(title))</id>
            \(entries)
            </feed>
            """
    }

    private static func page(title: String, links: [(type: String, href: String, title: String)]) -> String {
        let declarations = links.map { "<link rel=\"alternate\" type=\"\($0.type)\" href=\"\($0.href)\" title=\"\($0.title)\">" }
            .joined(separator: "\n")
        return """
            <!DOCTYPE html>
            <html><head><title>\(title)</title>
            \(declarations)
            </head><body><p>\(title)</p></body></html>
            """
    }

    /// A fixed moment in the past, so that the documents are the same on
    /// every run and no item lies in the future.
    private static let fixtureNow = Date(timeIntervalSince1970: 1_793_000_000)

    private static func date(hoursAgo hours: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: fixtureNow.addingTimeInterval(-3600 * Double(hours)))
    }

    private static func slug(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
#endif
