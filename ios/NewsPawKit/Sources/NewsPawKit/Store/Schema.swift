import GRDB

/// The schema migrations of a library. Both partitions use the same ones.
///
/// Migrations are append-only: a migration is never edited after it has been
/// merged, and each keeps its name for good. Adding a value to one of the
/// closed sets stored as text (`kind`, `overview`, `auto_translate`,
/// `body_mode`, `origin`) also ships with a migration, even an empty one, so
/// that an older build refuses the database as newer.
enum Schema {
    /// The migrator the app opens libraries with.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerV1(in: &migrator)
        return migrator
    }

    /// `v1`: categories, sources, articles, article bodies and seen
    /// identifiers (spec section 4). The closed sets have no `CHECK`
    /// constraint, because one cannot be changed in place; Swift validates
    /// them.
    static func registerV1(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE category (
                    id TEXT NOT NULL PRIMARY KEY,
                    name TEXT NOT NULL,
                    sort_order INTEGER NOT NULL,
                    icon TEXT NOT NULL,
                    overview TEXT NOT NULL DEFAULT 'auto',
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE source (
                    id TEXT NOT NULL PRIMARY KEY,
                    category_id TEXT NOT NULL REFERENCES category(id) ON DELETE RESTRICT,
                    kind TEXT NOT NULL,
                    url TEXT NOT NULL UNIQUE,
                    name TEXT NOT NULL,
                    site_url TEXT,
                    paused INTEGER NOT NULL DEFAULT 0,
                    auto_translate TEXT NOT NULL DEFAULT 'inherit',
                    body_mode TEXT NOT NULL DEFAULT 'auto',
                    translate_page INTEGER NOT NULL DEFAULT 0,
                    etag TEXT,
                    last_modified TEXT,
                    last_success_at TEXT,
                    last_error TEXT,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE article (
                    id TEXT NOT NULL PRIMARY KEY,
                    source_id TEXT NOT NULL REFERENCES source(id) ON DELETE CASCADE,
                    external_id TEXT NOT NULL,
                    url TEXT,
                    title TEXT,
                    excerpt TEXT,
                    author TEXT,
                    image_url TEXT,
                    published_at TEXT,
                    first_seen_at TEXT NOT NULL,
                    language TEXT,
                    read_at TEXT,
                    starred_at TEXT,
                    UNIQUE (source_id, external_id)
                );
                CREATE TABLE article_body (
                    article_id TEXT NOT NULL PRIMARY KEY REFERENCES article(id) ON DELETE CASCADE,
                    origin TEXT NOT NULL,
                    blocks TEXT NOT NULL,
                    fetched_at TEXT NOT NULL
                );
                CREATE TABLE seen (
                    source_id TEXT NOT NULL REFERENCES source(id) ON DELETE CASCADE,
                    external_id_hash TEXT NOT NULL,
                    last_seen_at TEXT NOT NULL,
                    PRIMARY KEY (source_id, external_id_hash)
                );
                """)
        }
    }
}
