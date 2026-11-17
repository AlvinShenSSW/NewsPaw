import Foundation
import NaturalLanguage

/// Language detection on the device (spec N06; RD14 decision 3): whether an
/// article's title and excerpt are sent to the model, converted from
/// Traditional to Simplified Chinese, or left as they are. Pure: it reads
/// nothing but its arguments and the system's recognizer and transform.
///
/// An article is judged as a whole: either every text with a letter is sent,
/// or none is. An unsure answer sends.
enum TextLanguage {
    /// A title is cut to this many characters before anything else.
    static let titleCharacters = 300
    /// An excerpt is cut to this many characters (collection cuts it there
    /// already).
    static let excerptCharacters = 500
    /// Every text is also cut to this many Unicode scalars.
    static let maximumScalars = 2_000
    /// The recognizer's least probability for Chinese (`zh-Hans`) or
    /// Japanese (`ja`) that keeps an article from being sent.
    static let recognizerThreshold = 0.75
    /// Under `en`, letters of other non-Latin scripts at this share of a
    /// text's units or more send it.
    static let otherScriptShare = 0.3

    /// What happens to an article.
    enum Decision: Equatable {
        /// Its texts with a letter go to the model.
        case send
        /// Nothing to show in place of the originals.
        case keep
        /// Written in Traditional Chinese under `zh-Hans`: the converted
        /// texts, `nil` for one the transform left unchanged; at least one
        /// is not `nil`.
        case converted(title: String?, excerpt: String?)
    }

    /// The judgement of one article: its texts cut to their bounds (`nil`
    /// when absent or empty), what is sent of them, and the decision.
    struct Judgement: Equatable {
        let title: String?
        let excerpt: String?
        let decision: Decision

        /// The texts a request carries for this article, in order: the
        /// title, then the excerpt, each only when it has a letter.
        var textsToSend: [String] {
            [title, excerpt].compactMap { text in
                guard let text, Units(text).hasLetter else { return nil }
                return text
            }
        }

        /// Whether the title is among `textsToSend`.
        var sendsTitle: Bool {
            title.map { Units($0).hasLetter } ?? false
        }
    }

    // MARK: - Cutting

    /// Cuts `text` to `maximumScalars` Unicode scalars, then to `characters`
    /// characters. The scalars are cut first, so that a character made of
    /// many scalars is not walked whole.
    static func cut(_ text: String, characters: Int) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.prefix(maximumScalars))
        return String(String(scalars).prefix(characters))
    }

    static func cutTitle(_ title: String?) -> String? {
        nonEmpty(title.map { cut($0, characters: titleCharacters) })
    }

    static func cutExcerpt(_ excerpt: String?) -> String? {
        nonEmpty(excerpt.map { cut($0, characters: excerptCharacters) })
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    // MARK: - Units

    /// A text's units by script: a Han character, a kana character and a
    /// letter of another non-Latin script count one each; a run of Latin
    /// letters counts one. Digits, punctuation, symbols and marks count
    /// nothing.
    struct Units: Equatable {
        var han = 0
        var kana = 0
        var other = 0
        var latin = 0

        var total: Int {
            han + kana + other + latin
        }

        var hasLetter: Bool {
            total > 0
        }

        init(_ text: String) {
            var inLatinRun = false
            for scalar in text.unicodeScalars {
                guard Self.isLetter(scalar) else {
                    inLatinRun = false
                    continue
                }
                if Self.isLatin(scalar) {
                    if !inLatinRun {
                        latin += 1
                    }
                    inLatinRun = true
                    continue
                }
                inLatinRun = false
                if Self.isKana(scalar) {
                    kana += 1
                } else if Self.isHan(scalar) {
                    han += 1
                } else {
                    other += 1
                }
            }
        }

        static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
            default: false
            }
        }

        static func isHan(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.value {
            case 0x3005, 0x3007, 0x3021...0x3029, 0x3038...0x303B: true
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: true
            case 0x20000...0x2FA1F, 0x30000...0x323AF: true
            default: false
            }
        }

        static func isKana(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.value {
            case 0x3041...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F, 0x1B000...0x1B16F: true
            default: false
            }
        }

        static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A, 0xAA, 0xBA, 0xC0...0xD6, 0xD8...0xF6, 0xF8...0x24F: true
            case 0x250...0x2AF, 0x1D00...0x1DBF, 0x1E00...0x1EFF: true
            case 0x2C60...0x2C7F, 0xA720...0xA7FF, 0xAB30...0xAB6F, 0xFB00...0xFB06: true
            case 0xFF21...0xFF3A, 0xFF41...0xFF5A: true
            default: false
            }
        }
    }

    // MARK: - Judging

    /// Judges an article by its title and excerpt, cut first.
    static func judge(title: String?, excerpt: String?, reading: ReadingLocale) -> Judgement {
        let title = cutTitle(title)
        let excerpt = cutExcerpt(excerpt)
        let texts = [title, excerpt].compactMap { $0 }.filter { Units($0).hasLetter }
        guard !texts.isEmpty else {
            return Judgement(title: title, excerpt: excerpt, decision: .keep)
        }
        let units = texts.map(Units.init)
        let decision: Decision
        switch reading {
        case .simplifiedChinese:
            if units.contains(where: { $0.kana > 0 || $0.han * 2 < $0.total })
                || probability(of: [.simplifiedChinese, .traditionalChinese], in: strippedOfASCII(texts)) < recognizerThreshold {
                decision = .send
            } else {
                let convertedTitle = title.flatMap(simplified)
                let convertedExcerpt = excerpt.flatMap(simplified)
                decision = convertedTitle == nil && convertedExcerpt == nil
                    ? .keep : .converted(title: convertedTitle, excerpt: convertedExcerpt)
            }
        case .japanese:
            let anyKana = units.contains { $0.kana > 0 }
            if units.contains(where: { $0.kana == 0 && $0.han * 2 < $0.total })
                || (!anyKana && probability(of: [.japanese], in: strippedOfASCII(texts)) < recognizerThreshold) {
                decision = .send
            } else {
                decision = .keep
            }
        case .english:
            if units.contains(where: { $0.han > 0 || $0.kana > 0 || Double($0.other) >= otherScriptShare * Double($0.total) })
                || firstLanguage(of: texts.joined(separator: "\n")) != .english {
                decision = .send
            } else {
                decision = .keep
            }
        }
        return Judgement(title: title, excerpt: excerpt, decision: decision)
    }

    /// The texts together, with ASCII letters and digits removed: what the
    /// recognizer is asked about under `zh-Hans` and `ja`. A Latin name
    /// otherwise makes it answer Turkish or English for a Chinese title
    /// (measured, F1).
    static func strippedOfASCII(_ texts: [String]) -> String {
        let joined = texts.joined(separator: "\n")
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: joined.unicodeScalars.filter { scalar in
            !(scalar.isASCII && (("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)))
        })
        return String(kept)
    }

    /// The recognizer's summed probability of `languages` for `text`.
    static func probability(of languages: [NLLanguage], in text: String) -> Double {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 50)
        return languages.reduce(0) { $0 + (hypotheses[$1] ?? 0) }
    }

    /// The recognizer's first answer for `text`, or `nil`.
    static func firstLanguage(of text: String) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage
    }

    /// `text` through the system's Traditional-to-Simplified transform, or
    /// `nil` when the transform leaves it unchanged or is unavailable (the
    /// text is then shown as it is).
    static func simplified(_ text: String) -> String? {
        guard let converted = text.applyingTransform(StringTransform("Hant-Hans"), reverse: false), converted != text else {
            return nil
        }
        return converted
    }
}
