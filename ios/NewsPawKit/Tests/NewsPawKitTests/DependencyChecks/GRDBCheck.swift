import Foundation
import GRDB
import Testing

@Suite("GRDB")
struct GRDBCheck {
    @Test("opens a database file and runs a migration")
    func opensDatabaseAndMigrates() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "check.sqlite").path

        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "article") { table in
                table.primaryKey("id", .text)
                table.column("title", .text).notNull()
            }
        }

        let queue = try DatabaseQueue(path: path)
        #expect(try queue.read { db in try migrator.hasCompletedMigrations(db) } == false)
        try migrator.migrate(queue)

        try queue.write { db in
            try db.execute(sql: "INSERT INTO article (id, title) VALUES (?, ?)", arguments: ["a", "First"])
        }
        let (applied, title) = try queue.read { db in
            (
                try migrator.appliedIdentifiers(db),
                try String.fetchOne(db, sql: "SELECT title FROM article WHERE id = ?", arguments: ["a"])
            )
        }
        #expect(applied == ["v1"])
        #expect(title == "First")
    }
}
