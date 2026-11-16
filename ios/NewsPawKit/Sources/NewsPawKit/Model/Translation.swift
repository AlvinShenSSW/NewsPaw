import Foundation

/// The reading language (spec N06; RD14 decision 1): what titles and
/// excerpts are translated into. A global setting, independent of the
/// interface language. The raw values are BCP 47 tags, stored in
/// `translation.locale` and in the preferences' `reading_locale`.
public enum ReadingLocale: String, Sendable, Hashable, CaseIterable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case japanese = "ja"

    public static let standard = ReadingLocale.simplifiedChinese

    /// The reading language the first run preselects (RD21 decision 4),
    /// from the system's preferred languages, the first of which is the
    /// system language: Chinese of any script or region → Simplified
    /// Chinese, Japanese → Japanese, English → English, anything else → the
    /// standard.
    public static func preselected(from preferredLanguages: [String]) -> ReadingLocale {
        guard let first = preferredLanguages.first else { return .standard }
        let code = first.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? ""
        switch code {
        case "zh": return .simplifiedChinese
        case "ja": return .japanese
        case "en": return .english
        default: return .standard
        }
    }

    /// The language's name in English, as the model's instructions name it.
    var englishName: String {
        switch self {
        case .simplifiedChinese: "Simplified Chinese"
        case .english: "English"
        case .japanese: "Japanese"
        }
    }
}

/// What a stored translation row says (decision 2). Stored in
/// `translation.state`.
///
/// Adding a case needs a schema migration, even an empty one.
public enum TranslationState: String, Sendable, Hashable, CaseIterable {
    /// Nothing to show in place of the originals.
    case none
    /// What is shown in place of the originals; a missing text shows its
    /// original.
    case done
    /// The model's reply for this article could not be used; the reason is
    /// kept.
    case failed
}

/// Why an article's translation failed and was stored (decisions 2, 5 and
/// 6). Stored in `translation.error`.
///
/// Adding a case needs a schema migration, even an empty one.
public enum TranslationFailure: String, Error, Sendable, Hashable, CaseIterable {
    /// The model declined.
    case refused
    /// The reply was cut off.
    case cutOff = "cut_off"
    /// The reply's content was not the requested shape.
    case malformed
    /// The reply held another number of texts.
    case count
    /// An entry of the reply was empty.
    case empty
    /// An entry's length was implausible for its original.
    case length
    /// The service objected to the request (400, 413, 422).
    case badRequest = "bad_request"
}

/// An article's stored translation in the reading language, as a row and the
/// reading screen read it (decision 11). An article without one is waiting.
public struct StoredTranslation: Sendable, Hashable {
    public let state: TranslationState
    /// The translated title; `nil` shows the original.
    public let title: String?
    /// The translated excerpt; `nil` shows the original.
    public let excerpt: String?
    /// The reason, with `failed` only.
    public let failure: TranslationFailure?

    public init(state: TranslationState, title: String?, excerpt: String?, failure: TranslationFailure?) {
        self.state = state
        self.title = title
        self.excerpt = excerpt
        self.failure = failure
    }

    /// Reads the stored columns; `nil` for a state this build does not know.
    init?(state: String?, title: String?, excerpt: String?, error: String?) {
        guard let state, let known = TranslationState(rawValue: state) else { return nil }
        self.state = known
        self.title = known == .done ? title : nil
        self.excerpt = known == .done ? excerpt : nil
        failure = known == .failed ? error.flatMap(TranslationFailure.init(rawValue:)) ?? .malformed : nil
    }
}
