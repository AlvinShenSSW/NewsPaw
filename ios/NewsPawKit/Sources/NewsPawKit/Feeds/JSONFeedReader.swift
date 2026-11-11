import Foundation

/// Reads a JSON Feed (versions 1 and 1.1) with the system JSON parser. Each
/// field is read on its own: a missing or wrongly typed field is absent and
/// does not affect the others. An `id` may be a string or a number.
enum JSONFeedReader {
    static let versionPrefix = "https://jsonfeed.org/version/"

    /// The feed, or `nil` when `data` is not JSON or not a JSON Feed.
    static func read(_ data: Data, baseURL: URL) -> ParsedFeed? {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
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
