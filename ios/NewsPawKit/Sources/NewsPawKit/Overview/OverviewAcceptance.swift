import Foundation

/// Whether a model's reply is an overview that can be used (spec N07; RD23
/// decision 5). Pure. The reply is untrusted: only its summary and the
/// highlights that name a number of the request are kept, as plain text.
/// There is no check of the output's language.
enum OverviewAcceptance {
    /// The most characters a summary may have.
    static let summaryLimit = 600
    /// The most characters a highlight's sentence may have.
    static let highlightLimit = 200
    /// The most highlights kept.
    static let maximumHighlights = 5

    /// An accepted reply: the summary and the highlights kept, each with
    /// the number of the request's article it names (1…N), in the reply's
    /// order.
    struct Accepted: Sendable, Hashable {
        let summary: String
        let highlights: [Highlight]
    }

    struct Highlight: Sendable, Hashable {
        let number: Int
        let text: String
    }

    /// Accepts `reply` for a request of `count` articles, or names why not:
    /// `cutOff` for a reply cut off, `malformed` for a reply without text,
    /// `empty` for a summary with nothing left once cleaned, `length` for
    /// one over `summaryLimit` characters.
    static func check(reply: ModelReply, count: Int) -> Result<Accepted, TranslationFailure> {
        guard !reply.isCutOff else { return .failure(.cutOff) }
        guard let first = reply.texts.first else { return .failure(.malformed) }
        let summaryText: String
        var candidates: [(number: Int?, sentence: String)] = []
        if reply.texts.count == 1 {
            (summaryText, candidates) = split(first)
        } else {
            summaryText = first
            for text in reply.texts.dropFirst() {
                let cleaned = clean(text)
                // A highlight among separate texts: `[n]`, `(n)`, `n.`, `n:`,
                // `n：` or `n、` before the sentence.
                if let match = cleaned.wholeMatch(of: /\s*(?:\[(\d{1,3})\]|\((\d{1,3})\)|(\d{1,3})[.:：、])\s*(.+)/) {
                    let digits = match.output.1 ?? match.output.2 ?? match.output.3
                    candidates.append((digits.flatMap { Int($0) }, String(match.output.4)))
                } else {
                    candidates.append((nil, cleaned))
                }
            }
        }
        let summary = clean(summaryText)
        guard !summary.isEmpty else { return .failure(.empty) }
        guard summary.count <= summaryLimit else { return .failure(.length) }
        var used = Set<Int>()
        var kept: [Highlight] = []
        for candidate in candidates where kept.count < maximumHighlights {
            guard let number = candidate.number, number >= 1, number <= count, !used.contains(number) else { continue }
            let sentence = clean(candidate.sentence)
            guard !sentence.isEmpty, sentence.count <= highlightLimit else { continue }
            used.insert(number)
            kept.append(Highlight(number: number, text: sentence))
        }
        return .success(Accepted(summary: summary, highlights: kept))
    }

    /// A one-text reply: the part before the first `[n]` line is the
    /// summary; the text is split at each such line, and each part is one
    /// candidate highlight. With no such line the whole text is the
    /// summary.
    private static func split(_ text: String) -> (String, [(number: Int?, sentence: String)]) {
        var summaryLines: [Substring] = []
        var candidates: [(number: Int?, sentence: String)] = []
        var current: (number: Int?, lines: [Substring])?
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            // Where a one-text reply is split: a line that starts with `[n]`,
            // the form the prompt asks for, so that a numbered list inside a
            // summary is never read as highlights.
            if let match = line.wholeMatch(of: /\s*\[(\d{1,3})\](.*)/) {
                if let current {
                    candidates.append((current.number, current.lines.joined(separator: "\n")))
                }
                current = (Int(match.output.1), [match.output.2])
            } else if current != nil {
                current?.lines.append(line)
            } else {
                summaryLines.append(line)
            }
        }
        if let current {
            candidates.append((current.number, current.lines.joined(separator: "\n")))
        }
        return (summaryLines.joined(separator: "\n"), candidates)
    }

    /// A text as it is kept: line breaks and tabs turned into spaces, other
    /// control characters removed, trimmed.
    static func clean(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029:
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
