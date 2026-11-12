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

    /// The feed, or `nil` when `data` is not JSON, not a JSON Feed, or nested
    /// deeper than `maximumNesting`.
    static func read(_ data: Data, baseURL: URL) -> ParsedFeed? {
        guard !nestsDeeper(than: maximumNesting, data),
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

    /// Whether objects and arrays in `data` nest deeper than `limit`, in one
    /// pass over the bytes. Brackets inside strings are not counted; a
    /// backslash in a string escapes the byte after it. Unclosed brackets
    /// count as open, so a truncated document is judged by the depth it
    /// reached.
    static func nestsDeeper(than limit: Int, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var depth = 0
            var inString = false
            var escaped = false
            for byte in buffer {
                if inString {
                    if escaped {
                        escaped = false
                    } else if byte == UInt8(ascii: "\\") {
                        escaped = true
                    } else if byte == UInt8(ascii: "\"") {
                        inString = false
                    }
                    continue
                }
                switch byte {
                case UInt8(ascii: "\""):
                    inString = true
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                    if depth > limit {
                        return true
                    }
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    // A closer without an opener is invalid JSON; never
                    // letting it lower the count keeps the check conservative.
                    depth = max(0, depth - 1)
                default:
                    break
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
