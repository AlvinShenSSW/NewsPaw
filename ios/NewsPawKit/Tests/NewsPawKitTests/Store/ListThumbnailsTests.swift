import Foundation
import GRDB
@testable import NewsPawKit
import Testing

/// RD19 decision 6 and criterion 8: "Show Thumbnails in Lists" is a
/// partition setting, kept in each library's own `setting` table.
@Suite("List thumbnails setting", .serialized)
struct ListThumbnailsTests {
    @Test("criterion 8: on by default; turned off in one library only; the value survives a reopening")
    func perLibrary() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory, cacheRoot: directory.appending(path: "Images"))
        let normal = try await store.openNormal()
        let adult = try await store.createAdultLibrary()
        #expect(try await normal.listThumbnails())
        #expect(try await adult.listThumbnails())

        try await adult.setListThumbnails(false)

        #expect(try await !adult.listThumbnails())
        #expect(try await normal.listThumbnails())
        let stored = try await adult.pool.read { db in try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = 'list_thumbnails'") }
        #expect(stored == "0")

        // The next launch reads the stored value.
        try await store.closeAdultLibrary()
        let reopened = try await LibraryStore(directory: directory, cacheRoot: directory.appending(path: "Images")).openAdultLibrary()
        #expect(try await !reopened.listThumbnails())
        try await reopened.setListThumbnails(true)
        #expect(try await reopened.listThumbnails())
    }

    @Test("a stored value other than \"0\" reads as on")
    func otherValuesReadAsOn() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try await LibraryStore(directory: directory, cacheRoot: directory.appending(path: "Images")).openNormal()
        for value in ["1", "no", "", "false"] {
            try await library.pool.write { db in
                try db.execute(sql: "INSERT OR REPLACE INTO setting (key, value) VALUES ('list_thumbnails', ?)", arguments: [value])
            }
            #expect(try await library.listThumbnails(), "\(value)")
        }
    }
}
