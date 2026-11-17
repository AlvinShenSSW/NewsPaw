import Foundation
import GRDB
@testable import NewsPawKit
import Synchronization
import Testing

/// RD20 decisions 4 and 5: the preview, Merge, Replace, and the write
/// across the two libraries (criteria 4 to 9, 12 and 13).
@Suite("Configuration import")
struct ConfigurationImportTests {
    typealias J = ConfigurationJSON

    static func document(_ mutate: (inout [String: Any]) -> Void = { _ in }) throws -> ConfigurationDocument {
        try readDocument(J.with(mutate))
    }

    /// The base file without its adult partition.
    static func normalOnly(_ object: inout [String: Any]) {
        object["includes_adult"] = false
        object["categories"] = (object["categories"] as! [[String: Any]]).filter { $0["partition"] as? String == "normal" }
        object["sources"] = (object["sources"] as! [[String: Any]]).filter { $0["category_id"] as? String != J.adultCategory }
        object["partition_settings"] = (object["partition_settings"] as! [[String: Any]]).filter { $0["partition"] as? String == "normal" }
        object["model_slots"] = (object["model_slots"] as! [[String: Any]]).filter { $0["partition"] as? String == "normal" }
    }

    static func plan(_ result: ConfigurationPartitionOutcome?) -> ConfigurationPlan? {
        if case .imported(let plan, _)? = result {
            return plan
        }
        return nil
    }

    // MARK: - Criterion 4: preview, then Merge

    @Test("criterion 4: the preview groups each partition and writes nothing; Merge adds only what is new and leaves the rest as it was")
    func previewThenMerge() async throws {
        let fixture = try await ConfigurationFixture.make()
        defer { fixture.remove() }
        let news = try await fixture.normal.testCategory("News", icon: "newspaper")
        let tech = try await fixture.normal.testCategory("Tech", icon: "cpu")
        let local = try await fixture.normal.testCategory("Local")
        // Alpha: filed differently and named differently here.
        try await fixture.normal.testSource("Alpha Here", url: "https://alpha.example/feed", category: tech, paused: true)
        try await fixture.normal.testSource("Beta", url: "https://beta.example/", category: tech, kind: .webpage)
        try await fixture.normal.testSource("Delta", url: "https://delta.example/feed", category: local)
        _ = news
        try await fixture.models(.normal).save(
            ModelSlotDraft(role: .primary, preset: .custom, address: "https://api.openai.com/v1", model: "other-model", newKey: secretKey("sk-normal-primary-0001")),
            testedOutcome: .passed
        )
        let document = try Self.document { object in
            var slots = object["model_slots"] as! [[String: Any]]
            slots.append(J.slot(partition: "normal", role: "backup", address: "https://backup.example/v1", model: "backup-model"))
            object["model_slots"] = slots
        }
        let normalBefore = try await fullDump(fixture.normal)
        let adultBefore = try await fullDump(fixture.adult)

        let preview = try await fixture.preview(document)
        #expect(try await fullDump(fixture.normal) == normalBefore)
        #expect(try await fullDump(fixture.adult) == adultBefore)

        let normal = try #require(preview.partitions.first { $0.partition == .normal }?.merge)
        #expect(normal.fileCategoryCount == 2)
        #expect(normal.fileSourceCount == 2)
        #expect(normal.newCategories.isEmpty)
        #expect(normal.categoriesAlreadyHere == ["News", "Tech"])
        #expect(normal.newSources.isEmpty)
        #expect(normal.sourcesAlreadyHere.map(\.name) == ["Beta"])
        #expect(normal.sourceConflicts.map(\.address) == ["https://alpha.example/feed"])
        #expect(normal.sourceConflicts.first?.differences == [.name, .category, .options])
        #expect(normal.slotConflicts.map(\.role) == [.primary])
        #expect(normal.slotConflicts.first?.differences == [.model])
        #expect(normal.newSlots.map(\.role) == [.backup])
        #expect(normal.settingDifferences.map(\.setting) == [.dailyAutoLimit, .listThumbnails])
        let adult = try #require(preview.partitions.first { $0.partition == .adult }?.merge)
        #expect(adult.newCategories == ["Private"])
        #expect(adult.newSources.map(\.name) == ["Gamma"])
        #expect(adult.newSlots.map(\.role) == [.primary])
        #expect(preview.settingDifferences.map(\.setting) == [.refreshMinutes, .retentionDays, .readingLocale, .autoTranslateTitles, .showOriginalTitles])
        #expect(preview.mergeWritesSomething)

        let result = await fixture.importDocument(document, mode: .merge)
        #expect(result.settingsReplaced == false)
        // Every row that was here is here, unchanged.
        let normalAfter = try await fullDump(fixture.normal)
        #expect(keepsEveryRow(normalBefore, in: normalAfter) == [])
        // Only the backup slot was added; no source, no category.
        #expect(normalAfter.rows["source"]?.count == 3)
        #expect(normalAfter.rows["category"]?.count == 3)
        #expect(normalAfter.rows["model_slot"]?.count == 2)
        let statuses = try await fixture.models(.normal).statuses()
        #expect(statuses[.primary]?.slot.model == "other-model")
        #expect(statuses[.primary]?.slot.testOutcome == .passed)
        #expect(statuses[.backup]?.key == .missing)
        #expect(statuses[.backup]?.slot.testOutcome == nil)
        // No setting changed: global or partition.
        #expect(fixture.preferences.refreshInterval == .thirtyMinutes)
        #expect(fixture.preferences.readingLocale == .simplifiedChinese)
        #expect(try await fixture.normal.dailyAutomaticLimit() == 200)
        #expect(try await fixture.normal.listThumbnails())
        // The adult partition got its new content.
        #expect(try await fixture.adult.sourceSummaries().map(\.name) == ["Gamma"])
        // The summary says what was already here.
        let summary = try #require(Self.plan(result.normal))
        #expect(summary.sourcesAlreadyHere.map(\.name) == ["Beta"])
        #expect(summary.sourceConflicts.map(\.name) == ["Alpha"])
        #expect(summary.deletedSources.isEmpty && summary.deletedCategories.isEmpty)
        if case .imported(_, let keysNeeded) = result.normal {
            #expect(keysNeeded == 1)
        } else {
            Issue.record("the normal partition was not imported")
        }
    }

    @Test("criterion 4: Merge writes nothing when everything is already here")
    func mergeNothingNew() async throws {
        let fixture = try await ConfigurationFixture.make()
        defer { fixture.remove() }
        let document = try Self.document(Self.normalOnly)
        await fixture.importDocument(document, mode: .merge)
        let preview = try await fixture.preview(document)
        #expect(!preview.mergeWritesSomething)
        let before = try await fullDump(fixture.normal)
        await fixture.importDocument(document, mode: .merge)
        #expect(try await fullDump(fixture.normal) == before)
    }

    @Test("Merge fills an empty backup beside a primary here, and both roles of an empty library")
    func mergeFillsSlots() async throws {
        let fixture = try await ConfigurationFixture.make()
        defer { fixture.remove() }
        let document = try Self.document { object in
            Self.normalOnly(&object)
            object["model_slots"] = [
                J.slot(partition: "normal", role: "primary", address: "https://file.example/v1"),
                J.slot(partition: "normal", role: "backup", address: "https://file-backup.example/v1"),
            ]
        }
        await fixture.importDocument(document, mode: .merge)
        let filled = try await fixture.models(.normal).statuses()
        #expect(filled[.primary]?.slot.baseURL == "https://file.example/v1")
        #expect(filled[.backup]?.slot.baseURL == "https://file-backup.example/v1")
        #expect(filled.values.allSatisfy { $0.key == .missing && $0.slot.testOutcome == nil })

        let other = try await ConfigurationFixture.make()
        defer { other.remove() }
        try await other.models(.normal).save(
            ModelSlotDraft(role: .primary, preset: .openAI, address: "https://api.openai.com/v1", model: "kept", newKey: secretKey("sk-kept-0000000001")),
            testedOutcome: nil
        )
        await other.importDocument(document, mode: .merge)
        let statuses = try await other.models(.normal).statuses()
        #expect(statuses[.primary]?.slot.model == "kept")
        #expect(statuses[.primary]?.key != .missing)
        #expect(statuses[.backup]?.slot.baseURL == "https://file-backup.example/v1")
    }

    // MARK: - Criterion 5: same-named categories

    @Test("criterion 5: Merge files a category of a shared name into the first in the owner's order, on every run, also after a reorder and back")
    func sameNamedCategories() async throws {
        let fixture = try await ConfigurationFixture.make()
        defer { fixture.remove() }
        let first = try await fixture.normal.testCategory("News")
        let second = try await fixture.normal.testCategory("News")
        func file(_ url: String) throws -> ConfigurationDocument {
            try Self.document { object in
                Self.normalOnly(&object)
                object["categories"] = [J.category(J.normalCategory, "News", partition: "normal", order: 0)]
                object["sources"] = [J.source(category: J.normalCategory, kind: "feed", name: url, url: url)]
            }
        }
        func category(of url: String) async throws -> UUID? {
            try await fixture.normal.sourceSummaries().first { $0.address == url }?.categoryID
        }
        await fixture.importDocument(try file("https://one.example/feed"), mode: .merge)
        #expect(try await category(of: "https://one.example/feed") == first)
        await fixture.importDocument(try file("https://two.example/feed"), mode: .merge)
        #expect(try await category(of: "https://two.example/feed") == first)
        // The second moved before the first: it is now the first.
        try await fixture.normal.reorderCategories([second, first])
        await fixture.importDocument(try file("https://three.example/feed"), mode: .merge)
        #expect(try await category(of: "https://three.example/feed") == second)
        // And back.
        try await fixture.normal.reorderCategories([first, second])
        await fixture.importDocument(try file("https://four.example/feed"), mode: .merge)
        #expect(try await category(of: "https://four.example/feed") == first)
        #expect(try await fixture.normal.categories().count == 2)
    }

    @Test("decision 4: under Merge, two file categories of one name are one; under Replace they pair in order and the rest are made")
    func samenamedPairing() async throws {
        let document = try Self.document { object in
            Self.normalOnly(&object)
            object["categories"] = [
                J.category(J.normalCategory, "News", partition: "normal", order: 0, icon: "globe"),
                J.category(J.secondNormalCategory, "News", partition: "normal", order: 1, icon: "star"),
            ]
        }
        let merge = try await ConfigurationFixture.make()
        defer { merge.remove() }
        let existing = try await merge.normal.testCategory("News")
        try await merge.normal.testCategory("Old")
        await merge.importDocument(document, mode: .merge)
        #expect(try await merge.normal.categories().map(\.name) == ["News", "Old"])
        #expect(Set(try await merge.normal.sourceSummaries().map(\.categoryID)) == [existing])

        let replace = try await ConfigurationFixture.make()
        defer { replace.remove() }
        let kept = try await replace.normal.testCategory("Old")
        let paired = try await replace.normal.testCategory("News")
        _ = kept
        await replace.importDocument(document, mode: .replace)
        let categories = try await replace.normal.categories()
        #expect(categories.map(\.name) == ["News", "News"])
        #expect(categories.map(\.iconName) == ["globe", "star"])
        #expect(categories.first?.id == paired)
        #expect(categories.map(\.sortOrder) == [0, 1])
    }

    // MARK: - Criterion 6: Replace

    @Test("criterion 6: Replace's review lists every effect; afterwards the partition is the file's and kept sources keep their articles")
    func replace() async throws {
        let fixture = try await ConfigurationFixture.make()
        defer { fixture.remove() }
        let old = try await fixture.normal.testCategory("Old")
        let news = try await fixture.normal.testCategory("News", icon: "folder")
        let alpha = try await fixture.normal.testSource("Alpha Here", url: "https://alpha.example/feed", category: old, paused: true)
        let gone = try await fixture.normal.testSource("Gone", url: "https://gone.example/feed", category: news)
        try await fixture.normal.testArticles(source: alpha, count: 4, starred: 2)
        try await fixture.normal.testArticles(source: gone, count: 3, starred: 1)
        try await fixture.normal.testUsage()
        try await fixture.normal.setDailyAutomaticLimit(200)
        let document = try Self.document(Self.normalOnly)
        let alphaArticles = try await fixture.normal.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM article WHERE source_id = ? ORDER BY id", arguments: [alpha.databaseKey]).map { $0.description }
        }
        let alphaBodies = try await fixture.normal.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT article_body.* FROM article_body JOIN article ON article.id = article_body.article_id WHERE source_id = ? ORDER BY article_id", arguments: [alpha.databaseKey]).map { $0.description }
        }
        let alphaTranslations = try await fixture.normal.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT translation.* FROM translation JOIN article ON article.id = translation.article_id WHERE source_id = ? ORDER BY article_id", arguments: [alpha.databaseKey]).map { $0.description }
        }
        let usage = try await fixture.normal.rows("usage")

        let before = try await fullDump(fixture.normal)
        let review = try #require(try await fixture.preview(document).partitions.first?.replace)
        #expect(try await fullDump(fixture.normal) == before)
        #expect(review.deletedCategories == ["Old"])
        #expect(review.deletedSources == [ConfigurationDeletedSource(name: "Gone", address: "https://gone.example/feed", articleCount: 3, starredCount: 1)])
        #expect(review.deletedArticleCount == 3)
        #expect(review.deletedStarredCount == 1)
        #expect(review.changedSources.map(\.name) == ["Alpha"])
        #expect(review.newCategories == ["Tech"])
        #expect(review.newSources.map(\.name) == ["Beta"])
        #expect(review.newSlots.map(\.role) == [.primary])
        #expect(review.settingDifferences.map(\.setting) == [.dailyAutoLimit, .listThumbnails])

        let result = await fixture.importDocument(document, mode: .replace)
        #expect(result.settingsReplaced)
        let categories = try await fixture.normal.categories()
        #expect(categories.map(\.name) == ["News", "Tech"])
        #expect(categories.first?.id == news)
        #expect(categories.first?.iconName == "newspaper")
        let sources = try await fixture.normal.sourceSummaries()
        #expect(Set(sources.map(\.address)) == ["https://alpha.example/feed", "https://beta.example/"])
        let kept = try #require(sources.first { $0.id == alpha })
        #expect(kept.name == "Alpha")
        #expect(kept.categoryID == news)
        #expect(!kept.paused)
        // The kept source's articles, read and starred times, bodies and
        // translations, its validators and status.
        #expect(try await fixture.normal.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM article WHERE source_id = ? ORDER BY id", arguments: [alpha.databaseKey]).map { $0.description }
        } == alphaArticles)
        #expect(try await fixture.normal.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT article_body.* FROM article_body JOIN article ON article.id = article_body.article_id WHERE source_id = ? ORDER BY article_id", arguments: [alpha.databaseKey]).map { $0.description }
        } == alphaBodies)
        #expect(try await fixture.normal.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT translation.* FROM translation JOIN article ON article.id = translation.article_id WHERE source_id = ? ORDER BY article_id", arguments: [alpha.databaseKey]).map { $0.description }
        } == alphaTranslations)
        let keptRow = try await fixture.normal.pool.read { db in try Source.fetchOne(db, key: alpha.databaseKey) }
        #expect(keptRow?.etag == "\"etag\"")
        #expect(keptRow?.siteURL == "https://site.example/")
        #expect(keptRow?.lastSuccessAt != nil)
        // The deleted source's articles went with it.
        #expect(try await rowCounts(fixture.normal)["article"] == 4)
        // The file's settings are in effect; usage rows are untouched.
        #expect(fixture.preferences.refreshInterval == .fifteenMinutes)
        #expect(fixture.preferences.retention == .sevenDays)
        #expect(fixture.preferences.readingLocale == .english)
        #expect(!fixture.preferences.autoTranslateTitles)
        #expect(fixture.preferences.showOriginalTitles)
        #expect(try await fixture.normal.dailyAutomaticLimit() == 50)
        #expect(try await fixture.normal.listThumbnails() == false)
        #expect(try await fixture.normal.rows("usage") == usage)
        let summary = try #require(Self.plan(result.normal))
        #expect(summary.deletedSources.map(\.name) == ["Gone"])
        #expect(summary.newSources.map(\.name) == ["Beta"])
    }

    @Test("decision 4: Replace keeps the device's kind and gives a matched source the options of that kind")
    func replaceKeepsKind() async throws {
        let fixture = try await ConfigurationFixture.make()
        defer { fixture.remove() }
        let category = try await fixture.normal.testCategory("News")
        let id = try await fixture.normal.testSource("Alpha", url: "https://alpha.example/feed", category: category, kind: .webpage, translatePage: true)
        let document = try Self.document { object in
            Self.normalOnly(&object)
            J.change(&object, "sources", at: 0) { $0["paused"] = true }
        }
        let preview = try #require(try await fixture.preview(document).partitions.first)
        #expect(preview.merge.sourceConflicts.first { $0.address == "https://alpha.example/feed" }?.differences == [.kind, .options])
        await fixture.importDocument(document, mode: .replace)
        let source = try #require(try await fixture.normal.sourceSummaries().first { $0.id == id })
        #expect(source.kind == .webpage)
        #expect(!source.translatePage)
        #expect(!source.paused)
    }

    @Test("decision 4: a source whose only difference is its kind is a conflict that Replace does not change")
    func kindOnly() async throws {
        let fixture = try await ConfigurationFixture.make()
        defer { fixture.remove() }
        let news = try await fixture.normal.testCategory("News", icon: "newspaper")
        try await fixture.normal.testSource("Alpha", url: "https://alpha.example/feed", category: news, kind: .github)
        let document = try Self.document(Self.normalOnly)
        let replace = try #require(try await fixture.preview(document).partitions.first?.replace)
        #expect(replace.sourceConflicts.first?.differences == [.kind])
        #expect(replace.changedSources.isEmpty)
    }

    // MARK: - Criterion 7: keys under Replace

    @Test("criterion 7: Replace removes a key whose address differs and the slot the file lacks; an equal address keeps its key")
    func keysUnderReplace() async throws {
        let fixture = try await ConfigurationFixture.make()
        defer { fixture.remove() }
        let normalModels = fixture.models(.normal)
        let adultModels = fixture.models(.adult)
        func draft(_ role: ModelRole, _ address: String, _ model: String, _ key: String) -> ModelSlotDraft {
            ModelSlotDraft(role: role, preset: .custom, address: address, model: model, newKey: secretKey(key))
        }
        try await normalModels.save(draft(.primary, "https://api.openai.com/v1", "gpt-test", "sk-normal-primary-0001"), testedOutcome: .passed)
        try await normalModels.save(draft(.backup, "https://backup.example/v1", "b", "sk-normal-backup-00002"), testedOutcome: .passed)
        try await adultModels.save(draft(.primary, "https://adult-old.example/v1", "a", "sk-adult-primary-00003"), testedOutcome: nil)
        try await adultModels.save(draft(.backup, "https://adult-backup.example/v1", "ab", "sk-adult-backup-000004"), testedOutcome: nil)
        let references = (
            normal: try await fixture.normal.configurationSlotReferences(),
            adult: try await fixture.adult.configurationSlotReferences()
        )
        // Same origin, another path: an address that differs.
        let document = try Self.document { object in
            object["model_slots"] = [
                J.slot(partition: "normal", role: "primary", address: "https://api.openai.com/v1", model: "gpt-test"),
                J.slot(partition: "normal", role: "backup", address: "https://backup.example/v2", model: "b"),
                J.slot(partition: "adult", role: "primary", address: "https://adult.models.example/v1"),
            ]
        }
        let preview = try await fixture.preview(document)
        let normalReview = try #require(preview.partitions.first { $0.partition == .normal }?.replace)
        let adultReview = try #require(preview.partitions.first { $0.partition == .adult }?.replace)
        #expect(normalReview.removedKeys == [.backup])
        #expect(normalReview.removedSlots.isEmpty)
        #expect(adultReview.removedKeys == [.primary, .backup])
        #expect(adultReview.removedSlots == [.backup])

        let result = await fixture.importDocument(document, mode: .replace)
        let normal = try await normalModels.statuses()
        #expect(normal[.primary]?.key == .present(lastFour: "0001"))
        #expect(normal[.primary]?.slot.testOutcome == .passed)
        #expect(normal[.backup]?.key == .missing)
        #expect(normal[.backup]?.slot.baseURL == "https://backup.example/v2")
        #expect(normal[.backup]?.slot.testOutcome == nil)
        let adult = try await adultModels.statuses()
        #expect(adult[.primary]?.key == .missing)
        #expect(adult[.backup] == nil)
        // The rows no longer name the removed items, and the items are gone.
        let normalReference = try #require(references.normal[.backup] ?? nil)
        #expect(!fixture.normalKeys.references.contains(normalReference))
        #expect(fixture.normalKeys.references == [try #require(references.normal[.primary] ?? nil)])
        #expect(fixture.adultKeys.references.isEmpty)
        #expect(try await fixture.normal.configurationSlotReferences()[.backup] == .some(nil))
        if case .imported(_, let needed) = result.normal, case .imported(_, let adultNeeded)? = result.adult {
            #expect(needed == 1)
            #expect(adultNeeded == 1)
        } else {
            Issue.record("not imported")
        }
    }

    @Test("criterion 7: a keychain item that cannot be removed is ignored; its row no longer names it")
    func keyRemovalFailure() async throws {
        let fixture = try await ConfigurationFixture.make()
        defer { fixture.remove() }
        try await fixture.models(.normal).save(
            ModelSlotDraft(role: .primary, preset: .custom, address: "https://old.example/v1", model: "m", newKey: secretKey("sk-old-key-000000001")),
            testedOutcome: nil
        )
        fixture.normalKeys.refuseRemovals = true
        let result = await fixture.importDocument(try Self.document(Self.normalOnly), mode: .replace)
        guard case .imported = result.normal else {
            Issue.record("not imported")
            return
        }
        #expect(try await fixture.normal.configurationSlotReferences()[.primary] == .some(nil))
        #expect(fixture.normalKeys.references.count == 1)
    }

    // MARK: - Criterion 8: the partition the file does not contain

    @Test("criterion 8: Replace with a normal-only file, given the adult target, leaves every row of the adult library identical")
    func partitionNotInFile() async throws {
        let fixture = try await ConfigurationFixture.make()
        defer { fixture.remove() }
        let category = try await fixture.adult.testCategory("Private")
        let source = try await fixture.adult.testSource("Gamma", url: "https://gamma.example/feed", category: category)
        try await fixture.adult.testArticles(source: source, count: 2, starred: 1)
        try await fixture.adult.testUsage()
        try await fixture.models(.adult).save(
            ModelSlotDraft(role: .primary, preset: .custom, address: "https://adult.example/v1", model: "m", newKey: secretKey("sk-adult-key-0000001")),
            testedOutcome: nil
        )
        try await fixture.adult.setDailyAutomaticLimit(3)
        let before = try await fullDump(fixture.adult)
        let keys = fixture.adultKeys.references
        let document = try Self.document(Self.normalOnly)
        let job = ConfigurationImport(document: document, normal: fixture.normalTarget, adult: fixture.adultTarget)
        #expect(!job.includesAdult)
        let result = await ConfigurationTransfer.run(job, mode: .replace, preferences: fixture.preferences, completion: { _ in })
        #expect(result.adult == nil)
        #expect(try await fullDump(fixture.adult) == before)
        #expect(fixture.adultKeys.references == keys)
    }

    // MARK: - Criterion 9: declining the adult partition

    @Test("criterion 9: on the decline path the adult library is never opened — its file's bytes are unchanged and no side file appears")
    func declinePath() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory, cacheRoot: directory.appending(path: "Images"))
        let normal = try await store.openNormal()
        // The partition is on: its file exists, closed.
        try await store.createAdultLibraryFileIfMissing()
        let adultFile = store.fileURL(for: .adult)
        // The database and its side files, as they are: present or not,
        // and their bytes.
        let files = { () -> [String: Data?] in
            Dictionary(uniqueKeysWithValues: ["", "-wal", "-shm"].map { suffix in
                (suffix, FileManager.default.contents(atPath: adultFile.path + suffix))
            })
        }
        let before = files()
        #expect(before[""] != nil)
        let suite = "NewsPawConfigurationDecline.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults)

        // The file has both partitions; the owner declined.
        let document = try Self.document()
        #expect(document.includesAdult)
        let preview = try await ConfigurationTransfer.preview(document, normal: normal, adult: nil, preferences: preferences)
        #expect(preview.partitions.map(\.partition) == [.normal])
        let job = ConfigurationImport(
            document: document, normal: ConfigurationTarget(library: normal, keys: InMemoryKeyStore(partition: .normal)), adult: nil
        )
        #expect(!job.includesAdult)
        #expect(job.holdsNoAdultPart)
        let result = await ConfigurationTransfer.run(job, mode: .replace, preferences: preferences, completion: { _ in })
        #expect(result.adult == nil)
        guard case .imported = result.normal else {
            Issue.record("the normal partition was not imported")
            return
        }
        #expect(files() == before)
        #expect(await store.adultLibraryIsClosed)
        #expect(await store.adultLibraryObjectIsReleased)
    }

    @Test("decision 5: the job lets go of the adult target and part once its adult steps have ended")
    func adultPartReleased() async throws {
        let fixture = try await ConfigurationFixture.make()
        defer { fixture.remove() }
        let job = ConfigurationImport(document: try Self.document(), normal: fixture.normalTarget, adult: fixture.adultTarget)
        #expect(job.includesAdult)
        #expect(!job.holdsNoAdultPart)
        let heldDuringNormal = Mutex<Bool?>(nil)
        let hooks = ConfigurationTransfer.Hooks(insideNormalTransaction: { [job] in
            heldDuringNormal.withLock { $0 = !job.holdsNoAdultPart }
        })
        await ConfigurationTransfer.run(job, mode: .merge, preferences: fixture.preferences, hooks: hooks, completion: { _ in })
        #expect(heldDuringNormal.withLock { $0 } == false)
        #expect(job.holdsNoAdultPart)
    }

    // MARK: - Criterion 12: atomic per partition

    /// A trigger that aborts the insert of the source at `url`.
    static func plantTrigger(_ library: Library, url: String) async throws {
        try await library.pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER planted_abort BEFORE INSERT ON source WHEN NEW.url = '\(url)'
                BEGIN SELECT RAISE(ABORT, 'planted'); END
                """)
        }
    }

    @Test("criterion 12: an insert that fails in a partition leaves that partition as it was")
    func atomicPartition() async throws {
        let fixture = try await ConfigurationFixture.make()
        defer { fixture.remove() }
        try await fixture.normal.testCategory("Old")
        try await Self.plantTrigger(fixture.normal, url: "https://beta.example/")
        let before = try await fullDump(fixture.normal)
        let result = await fixture.importDocument(try Self.document(Self.normalOnly), mode: .replace)
        guard case .failed = result.normal else {
            Issue.record("the normal partition was imported")
            return
        }
        #expect(!result.settingsReplaced)
        #expect(result.changedNothing)
        #expect(try await fullDump(fixture.normal) == before)
        #expect(fixture.preferences.refreshInterval == .thirtyMinutes)
    }

    @Test("criterion 12: with the normal transaction failing, the adult partition is imported and the normal partition and global settings are unchanged")
    func partialImport() async throws {
        let fixture = try await ConfigurationFixture.make()
        defer { fixture.remove() }
        try await Self.plantTrigger(fixture.normal, url: "https://alpha.example/feed")
        let before = try await fullDump(fixture.normal)
        let result = await fixture.importDocument(try Self.document(), mode: .replace)
        #expect(result.isPartial)
        #expect(!result.settingsReplaced)
        #expect(try await fixture.adult.sourceSummaries().map(\.name) == ["Gamma"])
        #expect(try await fixture.adult.dailyAutomaticLimit() == 10)
        #expect(try await fullDump(fixture.normal) == before)
        #expect(fixture.preferences.refreshInterval == .thirtyMinutes)
        #expect(fixture.preferences.readingLocale == .simplifiedChinese)
    }

    @Test("criterion 12: with the adult transaction failing, nothing is written anywhere")
    func adultFails() async throws {
        let fixture = try await ConfigurationFixture.make()
        defer { fixture.remove() }
        try await Self.plantTrigger(fixture.adult, url: "https://gamma.example/feed")
        let normalBefore = try await fullDump(fixture.normal)
        let adultBefore = try await fullDump(fixture.adult)
        let result = await fixture.importDocument(try Self.document(), mode: .replace)
        guard case .failed? = result.adult, case .notTried = result.normal else {
            Issue.record("unexpected result \(result)")
            return
        }
        #expect(result.changedNothing)
        #expect(try await fullDump(fixture.normal) == normalBefore)
        #expect(try await fullDump(fixture.adult) == adultBefore)
        #expect(fixture.preferences.refreshInterval == .thirtyMinutes)
    }

    // MARK: - Criterion 13: a lock during the write

    @Test("criterion 13: the adult library closed by the lock path while its transaction runs: it commits, the normal partition and the settings are written, then the completion runs once")
    func lockDuringAdultTransaction() async throws {
        let fixture = try await ConfigurationFixture.make()
        defer { fixture.remove() }
        let entered = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        let hooks = ConfigurationTransfer.Hooks(insideAdultTransaction: {
            entered.withLock { $0 = true }
            release.wait()
        })
        struct Seen: Sendable {
            let normalSources: Int
            let refresh: RefreshInterval
            let partial: Bool
        }
        let completions = Mutex<[Seen]>([])
        let normal = fixture.normal
        let preferences = fixture.preferences
        let document = try Self.document()
        let run = Task {
            await fixture.importDocument(document, mode: .replace, hooks: hooks) { result in
                let count = (try? await normal.sourceSummaries().count) ?? -1
                completions.withLock { $0.append(Seen(normalSources: count, refresh: preferences.refreshInterval, partial: result.isPartial)) }
            }
        }
        // The transaction is held.
        for _ in 0..<1_200 where !entered.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(entered.withLock { $0 })
        let closeCalled = Mutex(false)
        let closing = Task.detached {
            closeCalled.withLock { $0 = true }
            try await fixture.store.closeAdultLibrary()
        }
        for _ in 0..<1_200 where !closeCalled.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        release.signal()
        try await closing.value
        let result = await run.value
        #expect(fixture.adult.isClosed)
        if case .imported? = result.adult, case .imported = result.normal {} else {
            Issue.record("unexpected result \(result)")
        }
        #expect(result.settingsReplaced)
        #expect(completions.withLock { $0.count } == 1)
        #expect(completions.withLock { $0.first?.normalSources } == 2)
        #expect(completions.withLock { $0.first?.refresh } == .fifteenMinutes)
        // The adult transaction committed: a new open sees its rows.
        let reopened = try await fixture.store.openAdultLibrary()
        #expect(try await reopened.sourceSummaries().map(\.name) == ["Gamma"])
    }

    @Test("criterion 13: the adult library closed before its transaction begins: nothing is written and the completion says so")
    func lockBeforeAdultTransaction() async throws {
        let fixture = try await ConfigurationFixture.make()
        defer { fixture.remove() }
        let normalBefore = try await fullDump(fixture.normal)
        try await fixture.store.closeAdultLibrary()
        let calls = Mutex(0)
        let result = await fixture.importDocument(try Self.document(), mode: .replace) { result in
            calls.withLock { $0 += 1 }
            #expect(result.changedNothing)
        }
        guard case .failed? = result.adult, case .notTried = result.normal else {
            Issue.record("unexpected result \(result)")
            return
        }
        #expect(calls.withLock { $0 } == 1)
        #expect(try await fullDump(fixture.normal) == normalBefore)
        #expect(fixture.preferences.refreshInterval == .thirtyMinutes)
    }

    // MARK: - Criterion 15: versions

    @Test("criterion 15: under Replace, a setting the file does not have stays as it is here")
    func absentSettingStays() async throws {
        let fixture = try await ConfigurationFixture.make()
        defer { fixture.remove() }
        fixture.preferences.retention = .ninetyDays
        fixture.preferences.showOriginalTitles = true
        try await fixture.normal.setDailyAutomaticLimit(77)
        let document = try Self.document { object in
            Self.normalOnly(&object)
            object["settings"] = ["refresh_minutes": 60]
            object["partition_settings"] = [["partition": "normal", "list_thumbnails": false]]
            object["unknown_future_member"] = ["refresh_minutes": 0]
        }
        await fixture.importDocument(document, mode: .replace)
        #expect(fixture.preferences.refreshInterval == .sixtyMinutes)
        #expect(fixture.preferences.retention == .ninetyDays)
        #expect(fixture.preferences.showOriginalTitles)
        #expect(try await fixture.normal.dailyAutomaticLimit() == 77)
        #expect(try await fixture.normal.listThumbnails() == false)
    }

    // MARK: - Replace's order

    @Test("Replace makes the partition's order the file's")
    func replaceOrder() async throws {
        let fixture = try await ConfigurationFixture.make()
        defer { fixture.remove() }
        try await fixture.normal.testCategory("Tech")
        try await fixture.normal.testCategory("News")
        let document = try Self.document(Self.normalOnly)
        let review = try #require(try await fixture.preview(document).partitions.first?.replace)
        #expect(review.writesSomething)
        await fixture.importDocument(document, mode: .replace)
        let categories = try await fixture.normal.categories()
        #expect(categories.map(\.name) == ["News", "Tech"])
        #expect(categories.map(\.sortOrder) == [0, 1])
    }
}
