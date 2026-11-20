import Foundation
import GRDB
@testable import NewsPawKit
import Testing

/// RD23 where it meets RD20 in batch 4: Replace deletes categories and
/// sources, and their overviews go with them; an overview written while a
/// Replace commits stores nothing of a category the file removed. No
/// refusal or drain of the writer is needed for it: the store's own checks
/// (the category exists, every article sent exists) run inside its write.
@Suite("Overview with the configuration file (batch 4)", .serialized)
struct OverviewBatchFourTests {

    private func overviewCount(_ library: Library, category: UUID) async throws -> Int {
        try await library.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM overview WHERE category_id = ?", arguments: [category.databaseKey]) ?? -1
        }
    }

    private func record(_ category: UUID, day: String) -> OverviewRecord {
        OverviewRecord(
            categoryID: category, day: day, locale: .simplifiedChinese, state: .done, text: "Summary.", highlights: [],
            articleCount: 1, coveredUntil: nil, model: "m", failure: nil
        )
    }

    @Test("Replace deletes a category the file lacks with its overviews; a category it keeps keeps them")
    func replaceDeletesTheOverviewsOfDeletedCategories() async throws {
        let fixture = try await ConfigurationFixture.make()
        defer { fixture.remove() }
        let old = try await fixture.normal.testCategory("Old")
        let news = try await fixture.normal.testCategory("News", icon: "folder")
        let day = OverviewDay.key(for: fixture.clock.now(), calendar: OverviewFixture.utc)
        _ = try await fixture.normal.storeOverview(record(old, day: day), sent: [], slots: [:])
        _ = try await fixture.normal.storeOverview(record(news, day: day), sent: [], slots: [:])
        let document = try ConfigurationImportTests.document(ConfigurationImportTests.normalOnly)
        let review = try #require(try await fixture.preview(document).partitions.first?.replace)
        #expect(review.deletedCategories == ["Old"])

        await fixture.importDocument(document, mode: .replace)
        #expect(try await overviewCount(fixture.normal, category: old) == 0)
        #expect(try await overviewCount(fixture.normal, category: news) == 1)
    }

    @Test("a Replace that deletes the category, committed while its overview request is in flight: nothing is stored, the job answers gone")
    func replaceDuringAnOverviewRequest() async throws {
        let fixture = try await ConfigurationFixture.make()
        defer { fixture.remove() }
        let old = try await fixture.normal.testCategory("Old", overview: .manual)
        let source = try await fixture.normal.testSource("Old Feed", url: "https://old.example/feed", category: old)
        try await fixture.normal.testArticles(source: source, count: 3, starred: 0)
        let service = TranslationService(OverviewFixture.goodRule)
        let models = LibraryModels(library: fixture.normal, keys: fixture.normalKeys, http: service)
        try await models.save(
            ModelSlotDraft(role: .primary, preset: .custom, address: "https://primary.example.invalid/v1", model: "m",
                           newKey: secretKey("sk-replace-0123456789")),
            testedOutcome: nil
        )
        let clock = fixture.clock
        let writer = OverviewWriter(models: models, front: AppFront(isInFront: true), now: { clock.now() }, calendar: OverviewFixture.utc)
        await writer.configure(locale: .simplifiedChinese)
        service.hold(request: 1)
        let job = Task { await writer.write(category: old) }
        let deadline = ContinuousClock.now + TranslatorFixture.eventualBound
        while service.requests.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(service.requests.count == 1)

        let document = try ConfigurationImportTests.document(ConfigurationImportTests.normalOnly)
        await fixture.importDocument(document, mode: .replace)
        service.release(request: 1)
        #expect(await job.value == .gone)
        await writer.settled()
        #expect(try await overviewCount(fixture.normal, category: old) == 0)
        #expect(try await fixture.normal.categories().contains { $0.id == old } == false)
    }
}
