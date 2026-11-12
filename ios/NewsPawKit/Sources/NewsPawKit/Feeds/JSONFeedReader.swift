import Foundation

/// Reads a JSON Feed (versions 1 and 1.1) with the system JSON parser. Each
/// field is read on its own: a missing or wrongly typed field is absent and
/// does not affect the others. An `id` may be a string or a number.
enum JSONFeedReader {
    static let versionPrefix = "https://jsonfeed.org/version/"

    /// The deepest nesting of objects and arrays read. A JSON Feed needs
    /// about five levels (feed, items, item, authors, author) and a few more
    /// for extension objects; 64 leaves ample room. The system JSON parser
    /// recurses once per level, and a few hundred levels of objects overflow
    /// the small stack of a concurrency thread (measured: about 480 levels,
    /// 3.7 KB, end the process), so deeper documents are refused before it
    /// sees them.
    static let maximumNesting = 64

    /// The most members of one object. A feed's objects have a few dozen;
    /// items are array elements, not members. The system parser keys an
    /// object's members by a hash in which chosen keys collide, at a cost
    /// growing with the square of their number (R15: 11.3 MB, 23 s).
    static let maximumMembers = 4_096

    /// The longest object key, in bytes as written. Swift hashes and
    /// compares a key made of a long run of combining marks in time growing
    /// with the square of its length (V1).
    static let maximumKeyBytes = 1_024

    /// The feed, or `nil` when `data` is not JSON, not a JSON Feed, or past
    /// one of the limits above.
    static func read(_ data: Data, baseURL: URL) -> ParsedFeed? {
        guard !exceedsLimits(data),
              let root = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let version = root["version"] as? String, version.hasPrefix(versionPrefix)
        else { return nil }

        let rawItems = root["items"] as? [Any] ?? []
        let items = rawItems.compactMap { value -> ParsedItem? in
            guard let object = value as? [String: Any] else { return nil }
            return rawItem(object).resolved(against: baseURL)
        }
        return ParsedFeed(
            format: .json,
            title: string(root["title"]).map(HTMLText.collapseWhitespace).flatMap { $0.isEmpty ? nil : $0 },
            siteURL: RawItem.webAddress(string(root["home_page_url"]), base: baseURL),
            items: items,
            isComplete: true
        )
    }

    /// Whether `data` must not reach the system parser, decided before it
    /// does. A zero byte means the text is not UTF-8 JSON (UTF-16 and UTF-32
    /// put one in every ASCII character), which the system parser would
    /// accept and nest without the limit below (R14). Then, in one pass over
    /// the bytes: objects and arrays nested deeper than `maximumNesting`, an
    /// object with more than `maximumMembers` members (`:` outside strings,
    /// counted per open object), or a key — a string followed by `:` —
    /// longer than `maximumKeyBytes`. Brackets and colons inside strings are
    /// not counted; a backslash in a string escapes the byte after it.
    /// Unclosed brackets count as open, so a truncated document is judged by
    /// what it reached.
    static func exceedsLimits(_ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return false }
            if memchr(base, 0, buffer.count) != nil {
                return true
            }
            // Members of each open container; arrays count too, harmlessly
            // (a `:` in an array is not JSON).
            var members = [Int](repeating: 0, count: maximumNesting + 1)
            var depth = 0
            var inString = false
            var escaped = false
            var stringStart = 0
            // The length of the string just closed, while only white space
            // has followed it.
            var closedString: Int?
            for (index, byte) in buffer.enumerated() {
                if inString {
                    if escaped {
                        escaped = false
                    } else if byte == UInt8(ascii: "\\") {
                        escaped = true
                    } else if byte == UInt8(ascii: "\"") {
                        inString = false
                        closedString = index - stringStart
                    }
                    continue
                }
                switch byte {
                case UInt8(ascii: "\""):
                    inString = true
                    stringStart = index + 1
                    closedString = nil
                case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                    break
                case UInt8(ascii: ":"):
                    if let length = closedString, length > maximumKeyBytes {
                        return true
                    }
                    closedString = nil
                    members[depth] += 1
                    if members[depth] > maximumMembers {
                        return true
                    }
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    closedString = nil
                    depth += 1
                    if depth > maximumNesting {
                        return true
                    }
                    members[depth] = 0
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    closedString = nil
                    // A closer without an opener is invalid JSON; never
                    // letting it lower the count keeps the check conservative.
                    depth = max(0, depth - 1)
                default:
                    closedString = nil
                }
            }
            return false
        }
    }

    private static func rawItem(_ object: [String: Any]) -> RawItem {
        var item = RawItem()
        item.identifier = identifier(object["id"])
        item.link = string(object["url"]) ?? string(object["external_url"])
        item.title = string(object["title"])
        item.titleKind = .text
        item.summary = string(object["summary"])
        item.summaryKind = .text
        if let html = string(object["content_html"]) {
            item.content = html
            item.contentKind = .html
        } else if let text = string(object["content_text"]) {
            item.content = text
            item.contentKind = .text
        }
        item.date = string(object["date_published"])
        item.fallbackDate = string(object["date_modified"])
        item.jsonImage = string(object["image"]) ?? string(object["banner_image"])
        item.author = authorName(object["authors"]) ?? authorName(object["author"])
        return item
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// A string, or a number written as JSON would write it; not a Boolean.
    private static func identifier(_ value: Any?) -> String? {
        if let text = value as? String {
            return text
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        if double.isFinite, double == double.rounded(), abs(double) < 1e15 {
            return String(Int64(double))
        }
        return number.stringValue
    }

    /// The first author's name, from version 1.1's `authors` array or
    /// version 1's `author` object.
    private static func authorName(_ value: Any?) -> String? {
        if let list = value as? [Any] {
            return list.lazy.compactMap { ($0 as? [String: Any]).flatMap { string($0["name"]) } }.first
        }
        if let object = value as? [String: Any] {
            return string(object["name"])
        }
        return nil
    }
}
