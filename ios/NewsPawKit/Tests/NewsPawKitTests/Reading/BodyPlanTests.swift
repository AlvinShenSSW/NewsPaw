import Foundation
@testable import NewsPawKit
import Testing
import WebKit

/// RD12 decisions 2 and 4: how much article a body holds (criterion 6) and
/// which body an opening shows (criterion 2).
@Suite("Body plan and article length")
struct BodyPlanTests {
    static let base = URL(string: "https://example.invalid/page")!

    static func blocks(_ html: String) -> [ArticleBlock] {
        ArticleBlocks.make(html: html, baseURL: base).blocks
    }

    /// Paragraphs of English running text, each about 230 characters.
    static func paragraphs(_ count: Int) -> String {
        let sentence = "The harbour pilots read the tide tables each morning, and the ferry leaves when the water is deep enough for her keel."
        return (1...count).map { "<p>Paragraph \($0). \(sentence) \(sentence)</p>" }.joined()
    }

    /// Thirty headlines with summaries, as an ordinary list page has them.
    static let listPage: String = {
        let items = (1...30).map {
            "<li class=\"item\"><h2><a href=\"/story/\($0)\">Headline number \($0) of the list page, of ordinary length</a></h2>"
                + "<p class=\"summary\">A one-sentence summary of story \($0), with a comma, as list pages have them under each headline.</p>"
                + "<time>2026-11-\($0 % 28 + 1)</time></li>"
        }.joined()
        return "<html><head><title>Latest news</title></head><body><header><nav><a href=\"/\">Home</a><a href=\"/world\">World</a></nav></header>"
            + "<main><h1>Latest</h1><ul class=\"stories\">\(items)</ul></main><footer>Footer text</footer></body></html>"
    }()

    static let sixtyLinks: String = {
        let links = (1...60).map { "<li><a href=\"/release/\($0)\">Release title number \($0), with a longer name than most releases carry</a></li>" }.joined()
        return "<html><head><title>Releases</title></head><body><main><h1>Releases</h1><ul>\(links)</ul></main></body></html>"
    }()

    static let fortyCards: String = {
        let cards = (1...40).map {
            "<div class=\"card\"><a href=\"/work/\($0)\"><img src=\"/thumb/\($0).jpg\" alt=\"Work \($0)\"><span class=\"title\">Work title \($0)</span></a>"
                + "<span class=\"date\">2026-11-01</span></div>"
        }.joined()
        return "<html><head><title>Works</title></head><body><div class=\"grid\">\(cards)</div></body></html>"
    }()

    static let threeParagraphs = "<html><head><title>Story</title></head><body><article><h1>Story</h1>\(paragraphs(3))</article></body></html>"

    /// A Japanese news item of 136 characters.
    static let japanese = "政府は15日、来年度の予算案を閣議決定した。一般会計の総額は過去最大となり、社会保障費と防衛費の増加が全体を押し上げた。"
        + "財務相は記者会見で、財政健全化の目標は維持すると述べた。野党は歳出の見直しが不十分だと批判しており、通常国会での審議は難航が予想される見通しだと伝えた。"

    static let chinese: String = {
        let paragraph = "港口的灯沿着码头依次亮起，渡船在潮水转向时回到泊位。领航员每天早晨阅读潮汐表，只有当水深足够时渡船才会离港。"
        return "<html><head><title>港口</title></head><body><article><h1>港口的夜晚</h1>"
            + (1...3).map { _ in "<p>\(paragraph)\(paragraph)</p>" }.joined() + "</article></body></html>"
    }()

    // MARK: - Criterion 6

    @Test("criterion 6: list pages of headlines, bare links and image cards are not articles")
    func listPagesAreNotArticles() {
        for (name, page) in [("list", Self.listPage), ("links", Self.sixtyLinks), ("cards", Self.fortyCards)] {
            let blocks = Self.blocks(page)
            #expect(!ArticleBlocks.isArticle(blocks), "\(name): \(ArticleBlocks.bodyTextLength(blocks))")
            #expect(ArticleBlocks.bodyTextLength(blocks) < 100, "\(name)")
            // However long it is.
            #expect(ArticleBlocks.plainTextLength(blocks) > 300, "\(name)")
        }
    }

    @Test("criterion 6: a three-paragraph article, a 136-character Japanese item and a Chinese article are articles")
    func articles() {
        #expect(ArticleBlocks.isArticle(Self.blocks(Self.threeParagraphs)))
        #expect(Self.japanese.count == 136)
        let japanese = Self.blocks("<article><h1>予算案を閣議決定</h1><p>\(Self.japanese)</p></article>")
        #expect(ArticleBlocks.bodyTextLength(japanese) == 136)
        #expect(ArticleBlocks.isArticle(japanese))
        #expect(ArticleBlocks.isArticle(Self.blocks(Self.chinese)))
    }

    @Test("the length counts running text outside links, in paragraphs long enough")
    func lengthRule() {
        let sentence = String(repeating: "word ", count: 30) // 149 characters once collapsed
        // A paragraph inside a link does not count; text beside it does.
        #expect(ArticleBlocks.bodyTextLength(Self.blocks("<p><a href=\"/x\">\(sentence)</a></p>")) == 0)
        #expect(ArticleBlocks.bodyTextLength(Self.blocks("<p>\(sentence)</p>")) == 149)
        #expect(ArticleBlocks.bodyTextLength(Self.blocks("<p>\(sentence)<a href=\"/x\">a link</a></p>")) == 149)
        #expect(ArticleBlocks.bodyTextLength(Self.blocks("<p>\(sentence)<a href=\"/x\">a link</a> and more</p>")) == 158)
        // Under 140: not counted at all.
        #expect(ArticleBlocks.bodyTextLength(Self.blocks("<p>\(String(repeating: "word ", count: 27))</p>")) == 0)
        // Headings, list items as such and code are not paragraphs of running text.
        #expect(ArticleBlocks.bodyTextLength(Self.blocks("<h2>\(sentence)</h2><pre>\(sentence)</pre>")) == 0)
        // A Chinese paragraph counts from 60 characters.
        let han = String(repeating: "港", count: 60)
        #expect(ArticleBlocks.bodyTextLength(Self.blocks("<p>\(han)</p>")) == 60)
        #expect(ArticleBlocks.bodyTextLength(Self.blocks("<p>\(han.dropLast())</p>")) == 0)
        // An article from 250 characters, 100 when mostly Han, kana or Hangul.
        #expect(!ArticleBlocks.isArticle(Self.blocks("<p>\(sentence)</p>")))
        #expect(ArticleBlocks.isArticle(Self.blocks("<p>\(sentence)</p><p>\(sentence)</p>")))
        #expect(!ArticleBlocks.isArticle(Self.blocks("<p>\(String(repeating: "港", count: 99))</p>")))
        #expect(ArticleBlocks.isArticle(Self.blocks("<p>\(String(repeating: "港", count: 100))</p>")))
    }

    @Test("criterion 6: a 300-character page against a 2,000-character feed body is not usable under either option")
    func notMoreThanTheFeed() {
        let page = Self.blocks("<p>\(String(repeating: "word ", count: 60))</p>")
        #expect(ArticleBlocks.plainTextLength(page) == 299)
        let feed = Self.blocks("<p>\(String(repeating: "feed text ", count: 200))</p>")
        #expect(ArticleBlocks.plainTextLength(feed) == 1_999)
        #expect(ArticleBlocks.isArticle(page))
        // One rule for Automatic and Always fetch: an article, and more
        // plain text than the feed's content.
        #expect(!BodyPlan.isUsable(page, over: feed))
        #expect(BodyPlan.isUsable(page, over: Self.blocks("<p>A short excerpt.</p>")))
        #expect(BodyPlan.isUsable(page, over: []))
        // More text, but not an article: not usable either.
        #expect(!BodyPlan.isUsable(Self.blocks(Self.listPage), over: []))
    }

    @Test("criterion 6: Readability's answer for the list pages is not an article either")
    @MainActor
    func listPagesThroughTheExtractor() async throws {
        let (extractor, directory) = try PageExtractorTests.extractor()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, page) in [("list", Self.listPage), ("links", Self.sixtyLinks), ("cards", Self.fortyCards)] {
            do {
                let extraction = try await extractor.extract(html: page, address: Self.base)
                let blocks = ArticleBlocks.make(html: extraction.html, baseURL: Self.base).blocks
                print("RD12 \(name) page through Readability: \(extraction.html.count) characters of HTML, "
                    + "plain text \(ArticleBlocks.plainTextLength(blocks)), body text \(ArticleBlocks.bodyTextLength(blocks))")
                #expect(!ArticleBlocks.isArticle(blocks), "\(name)")
            } catch let failure as ExtractionFailure {
                #expect(failure == .noArticle, "\(name)")
            }
        }
        let article = try await extractor.extract(html: Self.threeParagraphs, address: Self.base)
        #expect(ArticleBlocks.isArticle(ArticleBlocks.make(html: article.html, baseURL: Self.base).blocks))
    }

    // MARK: - Criterion 2: the table

    @Test("criterion 2: every row of the table")
    func table() {
        let link = URL(string: "https://example.invalid/a")
        for kind in SourceKind.allCases {
            for full in [false, true] {
                // Feed content only: never fetched.
                #expect(BodyPlan.make(kind: kind, mode: .feed, feedIsFullText: full, link: link) == .feed)
                // Always fetch: fetched, the header alone shown meanwhile,
                // also when the feed has full text.
                #expect(BodyPlan.make(kind: kind, mode: .page, feedIsFullText: full, link: link) == .fetch(showsFeedMeanwhile: false))
            }
        }
        // Automatic, a feed source.
        #expect(BodyPlan.make(kind: .feed, mode: .auto, feedIsFullText: true, link: link) == .feed)
        #expect(BodyPlan.make(kind: .feed, mode: .auto, feedIsFullText: false, link: link) == .fetch(showsFeedMeanwhile: true))
        // Automatic, GitHub or Hugging Face: never fetched.
        for kind in [SourceKind.github, .huggingface] {
            for full in [false, true] {
                #expect(BodyPlan.make(kind: kind, mode: .auto, feedIsFullText: full, link: link) == .feed)
            }
        }
    }

    @Test("criterion 2: an article without an http or https link is never fetched")
    func noLinkNoFetch() {
        for link in [nil, URL(string: "ftp://example.invalid/a"), URL(string: "mailto:a@example.invalid"), URL(string: "https://user:pw@example.invalid/")] {
            for mode in BodyMode.allCases {
                #expect(BodyPlan.make(kind: .feed, mode: mode, feedIsFullText: false, link: link) == .feed, "\(String(describing: link)) \(mode)")
            }
        }
        #expect(BodyPlan.make(kind: .feed, mode: .auto, feedIsFullText: false, link: URL(string: "http://example.invalid/a")) != .feed)
    }
}
