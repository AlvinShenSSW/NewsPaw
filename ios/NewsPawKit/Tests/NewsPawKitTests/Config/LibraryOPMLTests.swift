import Foundation
import GRDB
@testable import NewsPawKit
import Testing

/// RD08 decision 4 and 6: the plan, the import transaction and the export
/// of one library (criteria 1, 4, 5, 6, 7, 8, 10).
@Suite("OPML import and export", .serialized)
struct LibraryOPMLTests {
    struct Fixture {
        let directory: URL
        let clock: TestClock
        let store: LibraryStore
        let library: Library

        static func make() async throws -> Fixture {
            let directory = try makeTemporaryDirectory()
            let clock = TestClock()
            let store = LibraryStore(directory: directory, now: clock.now)
            return Fixture(directory: directory, clock: clock, store: store, library: try await store.openNormal())
        }

        func close() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static func snapshot(_ library: Library) async throws -> DatabaseSnapshot {
        try await library.pool.read { try DatabaseSnapshot.read($0) }
    }

    static func document(_ text: String) throws -> OPMLDocument {
        try OPMLReader.read(Data(text.utf8)).get()
    }

    /// Criterion 1's file: two top-level folders, one with a folder nested
    /// in it, feeds outside any folder, an address already in the library,
    /// an address listed twice and one that is not http or https.
    static let criterionOneFile = #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0"><head><title>Another reader</title></head><body>
          <outline text="News" title="News">
            <outline text="Alpha" type="rss" xmlUrl="https://alpha.example/feed" htmlUrl="https://alpha.example"/>
            <outline text="World">
              <outline text="Beta" type="rss" xmlUrl="HTTPS://Beta.Example:443/feed#top"/>
            </outline>
            <outline text="Known" type="rss" xmlUrl="https://known.example/feed"/>
          </outline>
          <outline text="Tech" title="Tech">
            <outline text="Gamma" type="rss" xmlUrl="https://gamma.example/feed"/>
            <outline text="Alpha again" type="rss" xmlUrl="https://alpha.example/feed"/>
          </outline>
          <outline text="Delta" type="rss" xmlUrl="https://delta.example/feed"/>
          <outline text="Old scheme" type="rss" xmlUrl="feed://epsilon.example/feed"/>
          <outline text="" type="rss" xmlUrl="http://zeta.example/rss"/>
        </body></opml>
        """#

    /// A library with "Tech" (the same name as a folder of the file), and
    /// "Existing" holding the source at https://known.example/feed.
    static func prepare(_ library: Library) async throws -> (tech: NewsPawKit.Category, existing: NewsPawKit.Category) {
        let existing = try await library.createCategory(name: "Existing", icon: .star)
        let tech = try await library.createCategory(name: "Tech", icon: .cpu)
        _ = try await library.createCategory(name: "Tech", icon: .laptop)
        try await library.insert(Sample.source(in: existing.id, url: "https://known.example/feed", name: "Known", at: Date(timeIntervalSince1970: 1)))
        return (tech, existing)
    }

    static let expectedSkipped = [
        OPMLSkippedEntry(name: "Known", address: "https://known.example/feed", reason: .alreadyInLibrary(categoryName: "Existing")),
        OPMLSkippedEntry(name: "Alpha again", address: "https://alpha.example/feed", reason: .repeatedInFile),
        OPMLSkippedEntry(name: "Old scheme", address: "feed://epsilon.example/feed", reason: .invalidAddress),
    ]

    // MARK: - Criterion 1

    @Test("criterion 1: the preview's numbers, then the import as the plan said")
    func criterionOne() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        let library = fixture.library
        let (tech, existing) = try await Self.prepare(library)
        let document = try Self.document(Self.criterionOneFile)

        let before = try await Self.snapshot(library)
        let plan = try await library.opmlImportPlan(document)
        // The preview reads only; cancelling it changes nothing.
        #expect(try await Self.snapshot(library) == before)
        #expect(plan.categories == [
            OPMLCategoryResult(name: "News", isNew: true, addedFeeds: 2),
            OPMLCategoryResult(name: "Tech", isNew: false, addedFeeds: 1),
        ])
        #expect(plan.outsideFeeds == 2)
        #expect(plan.addedFeeds == 5)
        #expect(plan.needsOutsideCategory)
        #expect(plan.skipped == Self.expectedSkipped)

        fixture.clock.advance()
        let summary = try await library.importOPML(document, outsideFeeds: .existing(existing.id))

        #expect(summary.categories == [
            OPMLCategoryResult(name: "News", isNew: true, addedFeeds: 2),
            OPMLCategoryResult(name: "Tech", isNew: false, addedFeeds: 1),
            OPMLCategoryResult(name: "Existing", isNew: false, addedFeeds: 2),
        ])
        #expect(summary.createdCategories == ["News"])
        #expect(summary.addedFeeds == 5)
        #expect(summary.skipped == Self.expectedSkipped)

        let categories = try await library.categories()
        #expect(categories.map(\.name) == ["Existing", "Tech", "Tech", "News"])
        let news = try #require(categories.last)
        #expect(news.icon == .folder)
        #expect(news.sortOrder == 3)
        #expect(news.updatedAt == fixture.clock.now())

        let sources = try await library.sources()
        let byAddress = Dictionary(uniqueKeysWithValues: sources.map { ($0.url, $0) })
        #expect(byAddress.keys.sorted() == [
            "http://zeta.example/rss", "https://alpha.example/feed", "https://beta.example/feed", "https://delta.example/feed",
            "https://gamma.example/feed", "https://known.example/feed",
        ])
        // The nested folder's feed in its top folder's category, matched
        // "Tech" is the first of that name.
        #expect(byAddress["https://alpha.example/feed"]?.categoryID == news.id)
        #expect(byAddress["https://beta.example/feed"]?.categoryID == news.id)
        #expect(byAddress["https://gamma.example/feed"]?.categoryID == tech.id)
        #expect(byAddress["https://delta.example/feed"]?.categoryID == existing.id)
        #expect(byAddress["http://zeta.example/rss"]?.categoryID == existing.id)
        // A feed without a name takes its address's host.
        #expect(byAddress["http://zeta.example/rss"]?.name == "zeta.example")
        #expect(byAddress["https://beta.example/feed"]?.name == "Beta")
        try await expectIdentifiersAreLowercaseText(library)
    }

    @Test("the plan with a target equals the summary of the import that follows")
    func planEqualsSummary() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        let library = fixture.library
        _ = try await Self.prepare(library)
        let document = try Self.document(Self.criterionOneFile)

        for target in [OPMLOutsideFeeds.named("Loose"), .named("News")] {
            let plan = try await library.opmlImportPlan(document, outsideFeeds: target)
            let other = try await Fixture.make()
            defer { other.close() }
            _ = try await Self.prepare(other.library)
            let summary = try await other.library.importOPML(document, outsideFeeds: target)
            #expect(plan == summary, "\(target)")
        }
    }

    // MARK: - Criterion 5: what an imported source is

    @Test("criterion 5: kind feed, the file's name, the site address as given, default options, no articles, not updated yet")
    func importedSource() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        let library = fixture.library
        let document = try Self.document(#"""
            <opml version="2.0"><body><outline text="Folder">
              <outline text="Plain" xmlUrl="https://a.example/feed" htmlUrl="https://a.example"/>
              <outline text="Bad site" xmlUrl="https://b.example/feed" htmlUrl="javascript:alert(1)"/>
              <outline text="Relative site" xmlUrl="https://c.example/feed" htmlUrl="/home"/>
              <outline text="Site with fragment" xmlUrl="https://d.example/feed" htmlUrl="HTTPS://D.example/#x"/>
            </outline></body></opml>
            """#)

        _ = try await library.importOPML(document, outsideFeeds: nil)

        let summaries = try await library.sourceSummaries()
        #expect(summaries.map(\.name) == ["Bad site", "Plain", "Relative site", "Site with fragment"])
        for summary in summaries {
            #expect(summary.kind == .feed)
            #expect(summary.paused == false)
            #expect(summary.autoTranslate == .inherit)
            #expect(summary.bodyMode == .auto)
            #expect(summary.translatePage == false)
            #expect(summary.articleCount == 0)
            #expect(summary.lastSuccessAt == nil)
            #expect(summary.status == .notUpdatedYet)
        }
        let sites = Dictionary(uniqueKeysWithValues: summaries.map { ($0.name, $0.siteURL) })
        #expect(sites["Plain"] == .some("https://a.example"))
        #expect(sites["Bad site"] == .some(nil))
        #expect(sites["Relative site"] == .some(nil))
        #expect(sites["Site with fragment"] == .some(RawItem.webAddress("HTTPS://D.example/#x", base: nil)))
        let stored = try await library.sources()
        #expect(stored.allSatisfy { $0.etag == nil && $0.lastModified == nil && $0.lastError == nil })
        #expect(stored.allSatisfy { $0.updatedAt == fixture.clock.now() })
    }

    // MARK: - Folders and targets (decision 4)

    @Test("folders of the same name in one file are one folder")
    func sameNamedFoldersMerged() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        let library = fixture.library
        let document = try Self.document(#"""
            <opml version="2.0"><body>
              <outline text="News"><outline text="A" xmlUrl="https://a.example/feed"/></outline>
              <outline text="Tech"/>
              <outline text="News"><outline text="B" xmlUrl="https://b.example/feed"/></outline>
            </body></opml>
            """#)

        let summary = try await library.importOPML(document, outsideFeeds: nil)

        #expect(summary.categories == [
            OPMLCategoryResult(name: "News", isNew: true, addedFeeds: 2),
            OPMLCategoryResult(name: "Tech", isNew: true, addedFeeds: 0),
        ])
        let categories = try await library.categories()
        #expect(categories.map(\.name) == ["News", "Tech"])
        #expect(try await library.sources().allSatisfy { $0.categoryID == categories[0].id })
    }

    static let outsideFile = #"""
        <opml version="2.0"><body>
          <outline text="News"><outline text="A" xmlUrl="https://a.example/feed"/></outline>
          <outline text="Loose" xmlUrl="https://loose.example/feed"/>
        </body></opml>
        """#

    @Test("a typed name resolves to an existing category, else to a folder of the file, else to a new category placed last",
          arguments: [
              ("Existing", ["Existing", "News"], "Existing"),
              ("  News ", ["Existing", "News"], "News"),
              ("Loose Feeds", ["Existing", "News", "Loose Feeds"], "Loose Feeds"),
          ])
    func namedTarget(typed: String, order: [String], expected: String) async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        let library = fixture.library
        _ = try await library.createCategory(name: "Existing", icon: .star)

        let summary = try await library.importOPML(Self.document(Self.outsideFile), outsideFeeds: .named(typed))

        let categories = try await library.categories()
        #expect(categories.map(\.name) == order)
        let loose = try #require(try await library.sources().first { $0.url == "https://loose.example/feed" })
        #expect(categories.first { $0.id == loose.categoryID }?.name == expected)
        #expect(summary.addedFeeds == 2)
        #expect(Set(summary.createdCategories) == Set(order.filter { $0 != "Existing" }))
    }

    @Test("an existing target takes the outside feeds; a typed name is validated like any category name")
    func existingAndInvalidTargets() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        let library = fixture.library
        let target = try await library.createCategory(name: "Target", icon: .star)
        let document = try Self.document(Self.outsideFile)

        let before = try await Self.snapshot(library)
        await #expect(throws: LibraryError.emptyName) { try await library.importOPML(document, outsideFeeds: .named("  ")) }
        await #expect(throws: LibraryError.nameTooLong) {
            try await library.importOPML(document, outsideFeeds: .named(String(repeating: "n", count: 101)))
        }
        #expect(try await Self.snapshot(library) == before)

        _ = try await library.importOPML(document, outsideFeeds: .existing(target.id))
        let loose = try #require(try await library.sources().first { $0.url == "https://loose.example/feed" })
        #expect(loose.categoryID == target.id)
    }

    @Test("criterion 4: no target, or one that no longer exists, writes nothing")
    func missingTarget() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        let library = fixture.library
        _ = try await library.createCategory(name: "Other", icon: .star)
        let document = try Self.document(Self.outsideFile)
        let before = try await Self.snapshot(library)

        await #expect(throws: LibraryError.unknownCategory) { try await library.importOPML(document, outsideFeeds: nil) }
        await #expect(throws: LibraryError.unknownCategory) { try await library.importOPML(document, outsideFeeds: .existing(UUID())) }
        await #expect(throws: LibraryError.unknownCategory) { try await library.opmlImportPlan(document, outsideFeeds: .existing(UUID())) }

        #expect(try await Self.snapshot(library) == before)
    }

    @Test("no target is needed when no outside feed would be added")
    func noTargetNeeded() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        let library = fixture.library
        let other = try await library.createCategory(name: "Other", icon: .star)
        try await library.insert(Sample.source(in: other.id, url: "https://loose.example/feed", at: fixture.clock.now()))

        let summary = try await library.importOPML(Self.document(Self.outsideFile), outsideFeeds: nil)

        #expect(summary.outsideFeeds == 0)
        #expect(summary.needsOutsideCategory == false)
        #expect(summary.addedFeeds == 1)
    }

    @Test("criterion 4: a failure while writing leaves the library as it was")
    func failureWhileWriting() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        let library = fixture.library
        let target = try await library.createCategory(name: "Target", icon: .star)
        // The third source written fails inside the transaction, after a
        // category and two sources were written.
        try await library.pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER planted_failure BEFORE INSERT ON source WHEN NEW.url = 'https://fail.example/feed'
                BEGIN SELECT RAISE(ABORT, 'planted'); END
                """)
        }
        let document = try Self.document(#"""
            <opml version="2.0"><body>
              <outline text="News">
                <outline text="A" xmlUrl="https://a.example/feed"/><outline text="B" xmlUrl="https://b.example/feed"/>
                <outline text="Fail" xmlUrl="https://fail.example/feed"/>
              </outline>
              <outline text="Loose" xmlUrl="https://loose.example/feed"/>
            </body></opml>
            """#)
        let before = try await Self.snapshot(library)

        await #expect(throws: LibraryError.self) { try await library.importOPML(document, outsideFeeds: .existing(target.id)) }

        #expect(try await Self.snapshot(library) == before)
    }

    @Test("importing the same file again adds nothing and creates nothing")
    func importAgain() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        let library = fixture.library
        let document = try Self.document(Self.criterionOneFile)
        _ = try await library.importOPML(document, outsideFeeds: .named("Loose"))

        let plan = try await library.opmlImportPlan(document)

        #expect(plan.addedFeeds == 0)
        #expect(plan.createdCategories.isEmpty)
        #expect(plan.changesSomething == false)
        #expect(plan.needsOutsideCategory == false)
    }

    // MARK: - Export (criterion 6)

    @Test("criterion 6: every category in the owner's order, feed and GitHub sources by name, no web page")
    func export() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        let library = fixture.library
        let news = try await library.createCategory(name: "News & \"Views\" <1>", icon: .newspaper)
        let empty = try await library.createCategory(name: "Empty", icon: .folder)
        let code = try await library.createCategory(name: "Code", icon: .cpu)
        try await library.reorderCategories([code.id, news.id, empty.id])
        try await library.insert(Sample.source(in: news.id, url: "https://b.example/feed", name: "beta", at: fixture.clock.now()))
        var site = Sample.source(in: news.id, url: "https://a.example/feed?x=1&y=2", name: "Alpha\tTab", at: fixture.clock.now())
        site.siteURL = "https://a.example"
        try await library.insert(site)
        var github = Sample.source(in: code.id, url: "https://github.com/owner/repo/releases.atom", name: "Repo", at: fixture.clock.now())
        github.kind = .github
        try await library.insert(github)
        var page = Sample.source(in: code.id, url: "https://page.example/", name: "A page", at: fixture.clock.now())
        page.kind = .webpage
        try await library.insert(page)
        _ = empty

        let data = try await library.opmlExport()
        let text = try #require(String(data: data, encoding: .utf8))

        #expect(text == """
            <?xml version="1.0" encoding="UTF-8"?>
            <opml version="2.0">
              <head>
                <title>NewsPaw</title>
                <dateCreated>Fri, 15 Jan 2027 08:00:00 GMT</dateCreated>
              </head>
              <body>
                <outline text="Code" title="Code">
                  <outline text="Repo" title="Repo" type="rss" xmlUrl="https://github.com/owner/repo/releases.atom"/>
                </outline>
                <outline text="News &amp; &quot;Views&quot; &lt;1&gt;" title="News &amp; &quot;Views&quot; &lt;1&gt;">
                  <outline text="Alpha&#9;Tab" title="Alpha&#9;Tab" type="rss" xmlUrl="https://a.example/feed?x=1&amp;y=2" htmlUrl="https://a.example"/>
                  <outline text="beta" title="beta" type="rss" xmlUrl="https://b.example/feed"/>
                </outline>
                <outline text="Empty" title="Empty"/>
              </body>
            </opml>

            """)
        #expect(!text.contains("page.example"))
    }

    @Test("RD26 criterion 11: a Hugging Face source is not exported; only feed and GitHub sources store a feed address")
    func exportLeavesHuggingFaceOut() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        let library = fixture.library
        let models = try await library.createCategory(name: "Models", icon: .cpu)
        var hub = Sample.source(in: models.id, url: "https://huggingface.co/lamplight-lab", name: "lamplight-lab", at: fixture.clock.now())
        hub.kind = .huggingface
        hub.siteURL = "https://huggingface.co/lamplight-lab"
        try await library.insert(hub)
        try await library.insert(Sample.source(in: models.id, url: "https://b.example/feed", name: "beta", at: fixture.clock.now()))

        let text = try #require(String(data: try await library.opmlExport(), encoding: .utf8))
        #expect(text.contains(#"xmlUrl="https://b.example/feed""#))
        #expect(!text.contains("huggingface.co"))
        #expect(!text.contains("lamplight-lab"))

        // The export button's condition.
        #expect(SourceKind.allCases.filter(\.storesFeedAddress) == [.feed, .github])
        #expect(SourceKind.allCases.filter(\.isCollectedAsFeed) == [.feed, .github, .huggingface])
    }

    // MARK: - Criterion 7: round trip

    @Test("criterion 7: an export imported into an empty library gives the same categories and feeds")
    func roundTrip() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        let library = fixture.library
        let news = try await library.createCategory(name: "News", icon: .newspaper)
        let code = try await library.createCategory(name: "Code", icon: .cpu)
        _ = try await library.createCategory(name: "Empty", icon: .folder)
        var noSlash = Sample.source(in: news.id, url: "https://a.example/feed", name: "Alpha", at: fixture.clock.now())
        noSlash.siteURL = "https://a.example"
        try await library.insert(noSlash)
        var query = Sample.source(in: news.id, url: "http://b.example/rss?a=1&b=%20", name: "Beta <b>", at: fixture.clock.now())
        query.siteURL = "http://b.example/home?x=1&y=2"
        try await library.insert(query)
        var github = Sample.source(in: code.id, url: "https://github.com/owner/repo/releases.atom", name: "Repo", at: fixture.clock.now())
        github.kind = .github
        github.siteURL = "https://github.com/owner/repo"
        try await library.insert(github)
        var page = Sample.source(in: code.id, url: "https://page.example/", name: "A page", at: fixture.clock.now())
        page.kind = .webpage
        try await library.insert(page)

        let data = try await library.opmlExport()
        let target = try await Fixture.make()
        defer { target.close() }
        let document = try OPMLReader.read(data).get()
        let summary = try await target.library.importOPML(document, outsideFeeds: nil)

        #expect(summary.skipped.isEmpty)
        #expect(try await target.library.categories().map(\.name) == ["News", "Code", "Empty"])
        func feeds(_ library: Library) async throws -> Set<[String?]> {
            let categories = Dictionary(uniqueKeysWithValues: try await library.categories().map { ($0.id, $0.name) })
            return Set(try await library.sources().filter { $0.kind != .webpage }.map {
                [categories[$0.categoryID], $0.url, $0.name, $0.siteURL]
            })
        }
        #expect(try await feeds(target.library) == feeds(library))
        // Not kept: the kind; web pages are not in the file.
        #expect(try await target.library.sources().allSatisfy { $0.kind == .feed })
        #expect(try await target.library.sources().count == 3)
    }

    // MARK: - Criterion 8: partitions

    @Test("criterion 8: an import into one library leaves every table of the other unchanged, both ways round")
    func importTouchesOneLibrary() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        let normal = fixture.library
        let adult = try await fixture.store.createAdultLibrary()
        for library in [normal, adult] {
            let category = try await library.createCategory(name: "News", icon: .newspaper)
            try await Sample.fill(library, category: category.id, prefix: library === normal ? "normal" : "adult", at: fixture.clock.now())
        }
        let document = try Self.document(Self.criterionOneFile)

        for (into, other) in [(normal, adult), (adult, normal)] {
            let before = try await Self.snapshot(other)
            fixture.clock.advance()
            let summary = try await into.importOPML(document, outsideFeeds: .named("Loose \(into === normal ? "normal" : "adult")"))
            #expect(summary.addedFeeds == 6)
            #expect(try await Self.snapshot(other) == before)
        }
    }

    @Test("criterion 8: the export of one library contains no address of the other")
    func exportOfOneLibrary() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        let normal = fixture.library
        let adult = try await fixture.store.createAdultLibrary()
        let normalCategory = try await normal.createCategory(name: "Normal", icon: .newspaper)
        let adultCategory = try await adult.createCategory(name: "Adult only", icon: .newspaper)
        try await Sample.fill(normal, category: normalCategory.id, prefix: "normal", at: fixture.clock.now())
        try await Sample.fill(adult, category: adultCategory.id, prefix: "adult", at: fixture.clock.now())

        let normalText = try #require(String(data: try await normal.opmlExport(), encoding: .utf8))
        let adultText = try #require(String(data: try await adult.opmlExport(), encoding: .utf8))

        #expect(normalText.contains("https://normal.example.com/feed0"))
        #expect(!normalText.contains("adult"))
        #expect(adultText.contains("https://adult.example.com/feed0"))
        #expect(!adultText.contains("normal"))
        // Nothing in either file names the partition.
        #expect(!normalText.lowercased().contains("partition"))
        #expect(!adultText.lowercased().contains("partition"))
    }
}
