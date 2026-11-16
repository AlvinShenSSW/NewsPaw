import Foundation

/// How much article a body holds (RD12 decision 2). Readability returns an
/// "article" for ordinary list pages (thirty headlines with summaries gave
/// 4,741 characters when measured), so what it returns is weighed here, by
/// running text alone: a page of headlines, cards or links has almost none,
/// however long it is.
extension ArticleBlocks {
    /// The running text a paragraph needs to count, and the lower figure
    /// for a paragraph whose letters are mostly Han, kana or Hangul.
    public static let paragraphCharacters = 140
    public static let paragraphCharactersCJK = 60
    /// The counted text a body needs to be an article, and the lower figure
    /// for a body whose letters are mostly Han, kana or Hangul.
    public static let articleCharacters = 250
    public static let articleCharactersCJK = 100

    /// The characters of the paragraph blocks that are not inside a link,
    /// white space collapsed, counted only for paragraphs with at least 140
    /// such characters (60 when more than half of the paragraph's letters
    /// are Han, kana or Hangul).
    public static func bodyTextLength(_ blocks: [ArticleBlock]) -> Int {
        var total = 0
        for block in blocks {
            guard case .paragraph(let runs) = block.kind else { continue }
            let running = collapsedLength(runs.lazy.filter { $0.link == nil }.map(\.text))
            let threshold = isMostlyCJK(runs.map(\.text).joined()) ? paragraphCharactersCJK : paragraphCharacters
            if running >= threshold {
                total += running
            }
        }
        return total
    }

    /// Whether `blocks` are an article: their `bodyTextLength` is at least
    /// 250, or at least 100 when most of their letters are Han, kana or
    /// Hangul.
    public static func isArticle(_ blocks: [ArticleBlock]) -> Bool {
        let length = bodyTextLength(blocks)
        let text = blocks.compactMap(\.plainText).joined(separator: " ")
        return length >= (isMostlyCJK(text) ? articleCharactersCJK : articleCharacters)
    }

    /// The plain text of the text blocks, white space collapsed, in
    /// characters, a block's end separating words: what "more text than
    /// the feed's" compares.
    public static func plainTextLength(_ blocks: [ArticleBlock]) -> Int {
        collapsedLength(blocks.lazy.compactMap { $0.plainText.map { $0 + " " } })
    }

    /// The characters of `pieces` read one after another, with every run of
    /// white space, also across pieces, counted as one space between words
    /// and none at the ends.
    private static func collapsedLength(_ pieces: some Sequence<String>) -> Int {
        var characters = 0
        var pendingSpace = false
        for piece in pieces {
            for character in piece {
                if character.isWhitespace {
                    pendingSpace = true
                    continue
                }
                if pendingSpace, characters > 0 {
                    characters += 1
                }
                pendingSpace = false
                characters += 1
            }
        }
        return characters
    }
}
