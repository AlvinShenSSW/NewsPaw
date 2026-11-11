import Foundation
import SwiftSoup
import Testing

@Suite("SwiftSoup")
struct SwiftSoupCheck {
    @Test("parses an HTML page")
    func parsesHTMLPage() throws {
        let document = try SwiftSoup.parse(Fixture.text("article", "html"))

        #expect(try document.title() == "Synthetic article")
        let paragraphs = try document.select("article p")
        #expect(paragraphs.count == 3)
        #expect(try paragraphs.first()?.text().hasPrefix("ORIGINAL-MARKER") == true)
        #expect(try document.select("article img").attr("src") == "newspaw-test://fixture/image.png")
    }
}
