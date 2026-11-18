import GRDB

/// The schema migrations of a library. Both partitions use the same ones.
///
/// Migrations are append-only: a migration is never edited after it has been
/// merged, and each keeps its name for good. Adding a value to one of the
/// closed sets stored as text (`kind`, `overview`, `auto_translate`,
/// `body_mode`, `origin`, from `v5` `role`, `preset`, `test_outcome`,
/// `purpose`, `outcome`, from `v6` `translation.state` and
/// `translation.error`, and from `v8` `body_translation.state` and
/// `body_translation.error`) also ships with a migration, even an empty one, so
/// that an older build refuses the database as newer.
///
/// From the search migration on, `article` and `translation` carry
/// triggers that call the SQL function `newspaw_search_fold`: only a
/// connection made by `LibraryStore` can write them (`registerSearch`).
enum Schema {
    /// The migrator the app opens libraries with.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerV1(in: &migrator)
        registerV2(in: &migrator)
        registerV3(in: &migrator)
        registerV4(in: &migrator)
        registerV5(in: &migrator)
        registerV6(in: &migrator)
        registerSearch(in: &migrator)
        registerBodyTranslation(in: &migrator)
        return migrator
    }

    /// The name of the search migration (RD25). The one place that names
    /// it: tests refer to this constant, so that renumbering it, should
    /// another migration land after `v6` first, changes one line.
    static let searchMigration = "v7"

    /// The name of the body-translation migration (RD15), after the search
    /// migration. The one place that names it.
    static let bodyTranslationMigration = "v8"

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

    /// `v6`: one translation row per article and reading language (RD14
    /// decision 2), and whether a usage row was an automatic request (N11).
    /// `state` is `none`, `done` or `failed`; `title` and `excerpt` hold
    /// what is shown in place of the originals (null: the original);
    /// `error` is the stored reason of a failed row; `model` the model's
    /// name, null when no model was called. An article without a row for
    /// the reading language is waiting. Rows go with their article.
    static func registerV6(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v6") { db in
            try db.execute(sql: """
                CREATE TABLE translation (
                    article_id TEXT NOT NULL REFERENCES article(id) ON DELETE CASCADE,
                    locale TEXT NOT NULL,
                    title TEXT,
                    excerpt TEXT,
                    state TEXT NOT NULL,
                    error TEXT,
                    model TEXT,
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY (article_id, locale)
                );
                ALTER TABLE usage ADD COLUMN automatic INTEGER NOT NULL DEFAULT 0;
                """)
        }
    }

    /// The search migration (`searchMigration`; RD25 decisions 4 to 6): the
    /// folded titles that search scans, kept current by five triggers, and
    /// the covering index that sorts the matches into a page.
    ///
    /// `search_text` is derived data: one row per article with a title
    /// (`locale` '') and one per `done` translation with a title (`locale`
    /// the translation's). `text` is `newspaw_search_fold(title)`, the SQL
    /// function every connection of a library registers
    /// (`LibraryStore.makeLibrary`); the triggers call it, so a connection
    /// without it cannot insert an article or change a translation — it
    /// fails, it never leaves an article unindexed. Rows go with their
    /// article through the foreign key's cascade.
    ///
    /// A migration that rebuilds `article` or `translation` (create, copy,
    /// drop, rename) recreates these triggers and `article_search_order`;
    /// a change of the folding rules rebuilds `search_text`. `ADD COLUMN`
    /// and `RENAME COLUMN` keep them.
    ///
    /// The backfill runs inside the migration's transaction: one pass over
    /// each table.
    static func registerSearch(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration(searchMigration) { db in
            try db.execute(sql: """
                CREATE TABLE search_text (
                    article_id TEXT NOT NULL REFERENCES article(id) ON DELETE CASCADE,
                    locale TEXT NOT NULL,
                    text TEXT NOT NULL,
                    PRIMARY KEY (article_id, locale)
                ) WITHOUT ROWID;
                CREATE INDEX article_search_order ON article(id, COALESCE(published_at, first_seen_at), first_seen_at);
                CREATE TRIGGER search_article_insert AFTER INSERT ON article WHEN new.title IS NOT NULL BEGIN
                    INSERT INTO search_text (article_id, locale, text) VALUES (new.id, '', newspaw_search_fold(new.title));
                END;
                CREATE TRIGGER search_article_title AFTER UPDATE OF title ON article BEGIN
                    DELETE FROM search_text WHERE article_id = old.id AND locale = '';
                    INSERT INTO search_text (article_id, locale, text)
                        SELECT new.id, '', newspaw_search_fold(new.title) WHERE new.title IS NOT NULL;
                END;
                CREATE TRIGGER search_translation_insert AFTER INSERT ON translation
                    WHEN new.state = 'done' AND new.title IS NOT NULL BEGIN
                    INSERT OR REPLACE INTO search_text (article_id, locale, text)
                        VALUES (new.article_id, new.locale, newspaw_search_fold(new.title));
                END;
                CREATE TRIGGER search_translation_update AFTER UPDATE ON translation BEGIN
                    DELETE FROM search_text WHERE article_id = old.article_id AND locale = old.locale;
                    INSERT INTO search_text (article_id, locale, text)
                        SELECT new.article_id, new.locale, newspaw_search_fold(new.title)
                        WHERE new.state = 'done' AND new.title IS NOT NULL;
                END;
                CREATE TRIGGER search_translation_delete AFTER DELETE ON translation BEGIN
                    DELETE FROM search_text WHERE article_id = old.article_id AND locale = old.locale;
                END;
                INSERT INTO search_text (article_id, locale, text)
                    SELECT id, '', newspaw_search_fold(title) FROM article WHERE title IS NOT NULL;
                INSERT INTO search_text (article_id, locale, text)
                    SELECT article_id, locale, newspaw_search_fold(title) FROM translation
                    WHERE state = 'done' AND title IS NOT NULL;
                """)
        }
    }

    /// The body-translation migration (`bodyTranslationMigration`, `v8`):
    /// the translations of article bodies (RD15 decision 2), one row
    /// per text sent, keyed by its article, the reading language and the
    /// SHA-256 of the text as sent (lower-case hex), so that a body that
    /// changes keeps the rows of its unchanged texts. `state` is `done` or
    /// `failed`; `text` the accepted translation, cleaned (null with
    /// `failed`); `error` the stored reason of a failed row (RD14's
    /// `TranslationFailure` values); `model` the model's name (null with
    /// `failed`). Rows go with their article.
    static func registerBodyTranslation(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration(bodyTranslationMigration) { db in
            try db.execute(sql: """
                CREATE TABLE body_translation (
                    article_id TEXT NOT NULL REFERENCES article(id) ON DELETE CASCADE,
                    locale TEXT NOT NULL,
                    source_hash TEXT NOT NULL,
                    text TEXT,
                    state TEXT NOT NULL,
                    error TEXT,
                    model TEXT,
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY (article_id, locale, source_hash)
                );
                """)
        }
    }
}
