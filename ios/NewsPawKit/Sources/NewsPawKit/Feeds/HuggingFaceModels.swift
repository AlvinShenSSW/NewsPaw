import Foundation

/// Reads the Hub's list of an account's models (RD26 decision 4, spec N03,
/// N12). Pure: bytes in, a `ParsedFeed` or "not a list" out. The answer is
/// untrusted text: nothing in it is followed or executed, and each item's
/// link is built from a model name that passes the name rule, never taken
/// from the answer.
enum HuggingFaceModels {
    /// The most elements read: the length of the list the app asks for.
    static let maximumElements = 30

    /// The models of `data`, newest first as the Hub lists them, or `nil`
    /// when `data` is past the JSON limits, is not JSON, or is not an
    /// array. Of the first `maximumElements` elements, each object with a
    /// string `id` of the form `<account>/<model>` (both parts names) is an
    /// item: its identity is `_id` when that is 1–64 ASCII letters and
    /// digits, else `id`; its title is `id`; its link
    /// `https://huggingface.co/<id>`; its time `createdAt` when it is a
    /// string `FeedDate` reads. Every other element and member is ignored.
    static func read(_ data: Data) -> ParsedFeed? {
        guard !JSONFeedReader.exceedsLimits(data),
              let root = try? JSONSerialization.jsonObject(with: data, options: []) as? [Any]
        else { return nil }
        let items = root.prefix(maximumElements).compactMap { element -> ParsedItem? in
            guard let object = element as? [String: Any], let id = object["id"] as? String, isModelName(id) else { return nil }
            let databaseID = (object["_id"] as? String).flatMap { isDatabaseID($0) ? $0 : nil }
            return ParsedItem(
                externalID: databaseID ?? id,
                url: "https://huggingface.co/" + id,
                title: id,
                publishedAt: (object["createdAt"] as? String).flatMap(FeedDate.parse)
            )
        }
        return ParsedFeed(format: .huggingFace, title: nil, siteURL: nil, items: items, isComplete: true)
    }

    /// `<account>/<model>`, each part a name (`HuggingFaceAccount.isName`).
    static func isModelName(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { HuggingFaceAccount.isName($0) }
    }

    /// 1–64 ASCII letters and digits.
    private static func isDatabaseID(_ text: String) -> Bool {
        (1...64).contains(text.utf8.count) && text.utf8.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        }
    }
}
