PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;
CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
INSERT INTO grdb_migrations VALUES('v1');
CREATE TABLE category (
    id TEXT NOT NULL PRIMARY KEY,
    name TEXT NOT NULL,
    sort_order INTEGER NOT NULL,
    icon TEXT NOT NULL,
    overview TEXT NOT NULL DEFAULT 'auto',
    updated_at TEXT NOT NULL
);
INSERT INTO category VALUES('86c879a6-8a0d-4a2c-b4d9-7420a4134cc3','World',0,'globe','auto','2027-01-15 08:00:00.000');
INSERT INTO category VALUES('13ff79fd-e779-4329-9fdb-80f05c193baa','Tech',1,'cpu','auto','2027-01-15 08:01:00.000');
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
INSERT INTO source VALUES('36ea305a-7228-413a-86b0-3cadeb3e4b75','86c879a6-8a0d-4a2c-b4d9-7420a4134cc3','feed','https://news.example.com/rss.xml','Example News','https://news.example.com/',0,'on','page',0,'"abc123"','Tue, 10 Nov 2026 08:00:00 GMT','2027-01-15 08:02:00.000',NULL,'2027-01-15 08:02:00.000');
INSERT INTO source VALUES('0c358bdf-5b88-4b2f-acff-ffab476d5766','13ff79fd-e779-4329-9fdb-80f05c193baa','github','https://github.com/example/project/releases.atom','Example releases',NULL,1,'inherit','auto',0,NULL,NULL,NULL,'Could not connect','2027-01-15 08:02:00.000');
INSERT INTO source VALUES('99772d95-3b95-4d33-b8ae-b04426fd8596','13ff79fd-e779-4329-9fdb-80f05c193baa','webpage','https://example.org/changelog','Changelog page',NULL,0,'off','feed',1,NULL,NULL,NULL,NULL,'2027-01-15 08:02:00.000');
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
INSERT INTO article VALUES('5da36897-42f2-48c9-915d-3b01f3f56700','36ea305a-7228-413a-86b0-3cadeb3e4b75','https://news.example.com/1','https://news.example.com/1','First headline','A short excerpt.','A. Writer','https://news.example.com/1.jpg','2027-01-15 07:02:00.000','2027-01-15 08:02:00.000','en','2027-01-15 08:02:00.000','2027-01-15 08:02:00.000');
INSERT INTO article VALUES('4dcb2809-b8f9-4161-89ca-c4ee40e809ac','36ea305a-7228-413a-86b0-3cadeb3e4b75','https://news.example.com/2',NULL,NULL,NULL,NULL,NULL,NULL,'2027-01-15 08:02:00.000',NULL,NULL,NULL);
INSERT INTO article VALUES('de1e8bde-d19e-4195-a2e5-ec831ea974af','0c358bdf-5b88-4b2f-acff-ffab476d5766','tag:github.com,2008:Repository/1/v1.0','https://github.com/example/project/releases/tag/v1.0','v1.0',NULL,'example',NULL,'2027-01-15 08:02:00.000','2027-01-15 08:02:00.000',NULL,NULL,NULL);
CREATE TABLE article_body (
    article_id TEXT NOT NULL PRIMARY KEY REFERENCES article(id) ON DELETE CASCADE,
    origin TEXT NOT NULL,
    blocks TEXT NOT NULL,
    fetched_at TEXT NOT NULL
);
INSERT INTO article_body VALUES('5da36897-42f2-48c9-915d-3b01f3f56700','extracted','[{"text":"First paragraph.","type":"paragraph"},{"text":"A heading","type":"heading"}]','2027-01-15 08:02:00.000');
CREATE TABLE seen (
    source_id TEXT NOT NULL REFERENCES source(id) ON DELETE CASCADE,
    external_id_hash TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    PRIMARY KEY (source_id, external_id_hash)
);
INSERT INTO seen VALUES('36ea305a-7228-413a-86b0-3cadeb3e4b75','5f2b51ca2fdc5baa31ec02e002f69aec','2027-01-15 08:02:00.000');
COMMIT;
