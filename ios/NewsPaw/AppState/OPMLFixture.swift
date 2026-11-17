#if DEBUG
import Foundation
import NewsPawKit

/// The OPML documents a debug build reads under the UI tests in place of a
/// file chosen in the picker, which XCUITest cannot drive (RD08 decision
/// 8). Release builds contain none of this.
enum OPMLFixture: String {
    /// Criterion 1's shape: two folders, a folder nested in one, feeds
    /// outside any folder, an address listed twice, one that is not http or
    /// https, one the UI tests add first, and a settings block that is
    /// ignored. Every feed address is one the fixture transport answers.
    case folders
    /// A file with a document type naming an external subset: refused.
    case refused

    var text: String {
        switch self {
        case .folders:
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <opml version="2.0">
              <head><title>Fixture subscriptions</title></head>
              <body>
                <outline text="News" title="News">
                  <outline text="Fixture Feed" title="Fixture Feed" type="rss" xmlUrl="\(FixtureTransport.Address.feed)" htmlUrl="https://feed.example.invalid/"/>
                  <outline text="World" title="World">
                    <outline text="Two Feeds News" title="Two Feeds News" type="rss" xmlUrl="https://twofeeds.example.invalid/news.xml"/>
                  </outline>
                  <outline text="Articles" title="Articles" type="rss" xmlUrl="\(FixtureTransport.Address.articles)"/>
                </outline>
                <outline text="Tech" title="Tech">
                  <outline text="One Feed" title="One Feed" type="rss" xmlUrl="https://onefeed.example.invalid/feed.xml"/>
                  <outline text="Fixture Feed (again)" title="Fixture Feed (again)" type="rss" xmlUrl="\(FixtureTransport.Address.feed)"/>
                </outline>
                <outline text="Two Feeds Updates" title="Two Feeds Updates" type="rss" xmlUrl="https://twofeeds.example.invalid/atom.xml"/>
                <outline text="Fast Feed" title="Fast Feed" type="rss" xmlUrl="https://slowfeeds.example.invalid/fast.xml"/>
                <outline text="Old Scheme" title="Old Scheme" type="rss" xmlUrl="feed://oldscheme.example.invalid/rss.xml"/>
                <outline text="tt-rss-prefs" schema-version="1">
                  <outline pref-name="ALLOW_DUPLICATE_POSTS" value="false"/>
                </outline>
              </body>
            </opml>
            """
        case .refused:
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE opml SYSTEM "file:///etc/hosts">
            <opml version="2.0"><body><outline text="Fixture Feed" xmlUrl="\(FixtureTransport.Address.feed)"/></body></opml>
            """
        }
    }

    /// Writes the document to a file of its own in the temporary directory
    /// and returns it, so that it goes through the same bounded read as a
    /// chosen file.
    func writeToTemporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OPML Fixture", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(rawValue).opml")
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }
}
#endif
