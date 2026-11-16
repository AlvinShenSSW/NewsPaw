import Foundation

/// Whether a model's reply is a translation that can be used (spec N06; RD14
/// decision 5). Pure. One failed check rejects the whole reply: a wrong
/// length usually means the entries are shifted. There is no check of the
/// output's language.
enum TranslationAcceptance {
    /// Accepts `reply` for `originals` (the texts as sent), or names the
    /// first check it fails, in this order: the count, an empty entry, a
    /// reply cut off, an implausible length.
    ///
    /// - Returns: the entries, cleaned (`clean(_:)`), in the originals'
    ///   order.
    static func check(originals: [String], reply: ModelReply) -> Result<[String], TranslationFailure> {
        guard reply.texts.count == originals.count else { return .failure(.count) }
        let entries = reply.texts.map(clean)
        guard !entries.contains(where: \.isEmpty) else { return .failure(.empty) }
        guard !reply.isCutOff else { return .failure(.cutOff) }
        for (entry, original) in zip(entries, originals) where !isPlausible(entry: entry.count, original: original.count) {
            return .failure(.length)
        }
        return .success(entries)
    }

    /// An entry's length, in characters, is plausible for its original's:
    /// at most six times the original plus 40, and, for an original over
    /// 40 characters, at least a tenth of it.
    static func isPlausible(entry: Int, original: Int) -> Bool {
        entry <= 6 * original + 40 && (original <= 40 || entry * 10 >= original)
    }

    /// An entry as it is stored: line breaks turned into spaces, control
    /// characters removed, trimmed.
    static func clean(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029:
                kept.append(" ")
            default:
                if scalar.properties.generalCategory != .control {
                    kept.append(scalar)
                }
            }
        }
        return String(kept).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
