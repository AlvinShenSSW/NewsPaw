import GRDB

/// The schema migrations of a library. Both partitions use the same ones.
///
/// Migrations are append-only: a migration is never edited after it has been
/// merged, and each keeps its name for good. Adding a value to one of the
/// closed sets stored as text (`kind`, `overview`, `auto_translate`,
/// `body_mode`, `origin`, and from `v5` `role`, `preset`, `test_outcome`,
/// `purpose`, `outcome`) also ships with a migration, even an empty one, so
/// that an older build refuses the database as newer.
enum Schema {
    /// The migrator the app opens libraries with.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerV1(in: &migrator)
        registerV2(in: &migrator)
        registerV3(in: &migrator)
        registerV4(in: &migrator)
        registerV5(in: &migrator)
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

    /// `v2`: the feed's own HTML for each article (RD04), and an index on
    /// the article's link for the same-link rule of collection (spec N04).
    /// `content_html` is read by article identifier; list queries do not
    /// select it.
    static func registerV2(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v2") { db in
            try db.execute(sql: """
                ALTER TABLE article ADD COLUMN content_html TEXT;
                CREATE INDEX article_url ON article(url);
                """)
        }
    }

    /// `v3`: the partition's own settings and state (spec section 4; RD06),
    /// one value per key. RD06 stores `last_refresh_at` here.
    static func registerV3(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v3") { db in
            try db.execute(sql: """
                CREATE TABLE setting (
                    key TEXT NOT NULL PRIMARY KEY,
                    value TEXT NOT NULL
                );
                """)
        }
    }

    /// `v4`: the order of the article lists (RD09 decision 2) — newest first
    /// by the time a row shows (the published time, else the first-seen
    /// time), then by first-seen time, then by `rowid`, which every index
    /// carries — walked backwards by the list queries. It only creates the
    /// index.
    static func registerV4(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v4") { db in
            try db.execute(sql: """
                CREATE INDEX article_order ON article(COALESCE(published_at, first_seen_at), first_seen_at);
                """)
        }
    }

    /// `v5`: the model slots and the usage records (spec section 4; RD13
    /// decision 1). `role` is the slot table's primary key, so a library
    /// holds at most one primary and one backup. `key_ref` names the
    /// keychain item of the slot's key and may be null; the key itself is
    /// never stored here. `test_outcome` is the last Test result kept with
    /// the slot (null: not tested). `usage` is read by time (RD17).
    static func registerV5(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v5") { db in
            try db.execute(sql: """
                CREATE TABLE model_slot (
                    role TEXT NOT NULL PRIMARY KEY,
                    preset TEXT NOT NULL,
                    base_url TEXT NOT NULL,
                    model TEXT NOT NULL,
                    key_ref TEXT,
                    test_outcome TEXT,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE usage (
                    id TEXT NOT NULL PRIMARY KEY,
                    model TEXT NOT NULL,
                    purpose TEXT NOT NULL,
                    input_tokens INTEGER,
                    output_tokens INTEGER,
                    outcome TEXT NOT NULL,
                    at TEXT NOT NULL
                );
                CREATE INDEX usage_at ON usage(at);
                """)
        }
    }
}
