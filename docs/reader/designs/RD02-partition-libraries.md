# RD02 — Partition libraries: one database per partition, migrations, categories

Issue: [#123](https://github.com/AlvinShenSSW/NewsPaw/issues/123) · Epic E11 #114 · Requirements N02, N04 (storage); spec section 4 and section 6 (isolation point 1).
Design version 3, 2026-11-11 (after debate rounds 1 and 2; see the last section). Author: Claude (driver of this AFK run). Implementer: Claude Opus 5.5. External gate: Kimi K3.1 Pro.

## Spec review

The reader keeps each partition's data in its own SQLite file. This issue builds that storage layer and nothing on top of it: a `Library` type that is the only way to reach one partition's data, the first schema migration, and category management. The interface arrives in RD03; sources and articles get their tables here but their behaviour in RD04 and RD05.

Core need: later issues must be able to rely on two facts — a library never sees the other partition's rows, and the schema can change without losing data.

Left open by the issue and settled here: what the app does when a database cannot be opened; what "a database written by an earlier schema version" means while only one version exists; how identifiers and times are stored; whether the app itself opens a library in this issue.

## Acceptance criteria

1. On a fresh install, launching the app creates `normal.sqlite` and no adult database file. Shown by a package test and by the app's data container in the simulator.
2. The first migration creates `category`, `source`, `article`, `article_body` and `seen` with the columns of spec section 4. A test migrates an empty database and checks tables, columns and constraints.
3. A frozen fixture of a version-1 database (schema plus sample rows) is in the test bundle. One test shows the fixture's schema equals what migrating up to `v1` produces. One test restores it and opens it through the store's opening path with `v1` plus a test-only later migration, and finds the migration applied and the rows intact — this is the "database written by an earlier schema version" the issue asks for. Later issues add real migrations and keep opening this fixture.
4. A database that carries a migration the app does not know is refused with a distinct error, and the refusal changes nothing in it: no migration is applied or removed, and its schema and rows are the same afterwards. The test builds that database the way production does (through a pool, so in WAL mode), has the store refuse it, then reopens it with the newer migrator and compares the applied migration names, the schema text, the rows and the integrity check with what they were before. A file that is not a database, and a truncated one, are refused with their own distinct error and left byte-for-byte unchanged.
5. Categories: create, rename, change icon, reorder, delete with either choice for its sources (move to another category, or delete with it), each covered by tests including its failure cases (empty or over-long name, unknown category, reordering with a list that is not a permutation, moving to the category being deleted).
6. A source address is unique inside a library: inserting a second source with the same address fails with a distinct error. The same address can be stored in both libraries.
7. Isolation: with both libraries open and the adult one holding categories, sources and articles, nothing a caller can ask of the normal library returns any of them; and a library's connections cannot attach another database at all — `ATTACH` fails on the writer and on a reader. That the `Library` API has no parameter naming a partition or another library is a review check, not something a test can prove.
8. `LibraryStore` gives out one `Library` per file: opening the same partition twice returns the same instance.
9. When the library cannot be opened, the app shows a plain message with the reason, in the interface language, and stops there. It does not delete, reset or replace the file.

## Frozen issue contract

**In.** The nine criteria.

**Invariants.**
- No table has a partition column. No SQL attaches a second database. No function compares, joins or copies between the two libraries.
- The adult file is never created as a side effect: only an explicit call creates it. In this issue the adult functions are `internal` to the package, so the app target cannot reach them; RD18 adds the public entry with device authentication in front of it.
- One file, one pool: the store never opens a second pool on a file it already has open (GRDB's first concurrency rule; a second pool makes writes fail with "database is locked").
- Opening never destroys data: no "delete and recreate on error", no automatic downgrade.
- Adding a value to one of the closed sets (`kind`, `overview`, `auto_translate`, `body_mode`, `origin`) always ships with a migration, even an empty one, so that an older build refuses the database as newer instead of failing to decode a row it does not understand.
- Schema changes are append-only migrations with stable names. The first is `v1`; nothing here edits a migration after it has merged.
- Field values follow spec section 4: UUID keys stored as lowercase text, times in UTC as GRDB's default text form, `updated_at` on `category` and `source`. Every `id` and `*_id` value in the database is lowercase text after every write path.
- Tests use temporary directories and synthetic rows only.

**Allowed user-visible change.** The placeholder screen gains one failure state (criterion 9). Nothing else is visible.

**Non-goals.** Any list or editing interface (RD03); collecting or adding sources (RD04, RD05); the adult partition's switch, authentication and gate (RD18); model slots, translations, page text, overviews, usage and settings tables (their own issues); observation streams for the interface (RD03 adds what it needs); file-protection classes; encryption.

**Causal boundary.** `ios/NewsPawKit/Sources/NewsPawKit/Model/**`, `Store/**`; `ios/NewsPawKit/Tests/NewsPawKitTests/Store/**` and `Fixtures/library-v1.sql`; `ios/NewsPaw/NewsPawApp.swift`, `PlaceholderView.swift`, `Localizable.xcstrings`. No dependency is added or changed.

## Assumptions

| Assumption | Risk if wrong | Verified by |
| --- | --- | --- |
| GRDB 7.12 offers a database pool usable from Swift 6 async code, a migrator that can tell when a database is ahead of the app, and a setting to store UUIDs as lowercase text in Codable records | A different GRDB API is needed for one of the three | The implementation compiling and the tests; read GRDB's documentation in the checkout (`ios/NewsPawKit/.build/checkouts/GRDB.swift`) rather than recalling it |
| A database in the app's Application Support directory is included in device backups and readable in the background after the first unlock | Backup or background refresh (RD24) behaves differently | Not verified here; Apple's defaults. RD24 and the owner's device checks cover it |
| WAL mode (a pool) is acceptable for a file that is later exported or deleted (RD18 "delete") | Deleting must also remove `-wal` and `-shm`; the side files stay on disk after a clean close | Stated for RD18; this issue only notes it |
| Setting the attached-database limit to zero leaves migrations, writes and temporary tables working | Isolation cannot be enforced this way | The tests. Measured in the debate to work with the limit set: migrations including table rebuilds, full-text tables, value observation, snapshots, backup, checkpoint. Known cost: `VACUUM` and `VACUUM INTO` fail on such a connection. Nothing in the specification needs them; an issue that ever does must use a separate, deliberately created connection |

Measured in the debate on this Mac (GRDB 7.12.0, system SQLite 3.54.0, macOS 27.0.1; a local pass proves this machine only): a `Sendable` class holding a pool compiles cleanly in Swift 6 mode; `hasBeenSuperseded` detects a newer database in WAL and rollback mode; foreign keys are on for writer and readers; a duplicate address fails with a distinguishable unique-constraint error; a `.dump` of a `v1` database restores to a file GRDB treats as migrated, with identical schema text; a not-a-database file fails with SQLite code 26 and a truncated one with 11, both unchanged; an interrupted migration can be retried.

## Approach

**Types.**
- `LibraryStore` is a reference type that owns a directory and hands out libraries, at most one per partition: a second open of the same partition returns the instance it already holds. Finding or creating that instance is atomic — two callers opening at the same moment get the same library and only one pool is ever created (no suspension between the lookup and the store of the result, or the in-flight open is what gets shared). Public: `init(directory:now:)` (the clock defaults to the system's and is injected in tests, as N13 requires), `defaultDirectory()`, and `openNormal()`, which creates the directory and `normal.sqlite` if missing, migrates, and returns the library. Internal in this issue: `adultLibraryExists`, `createAdultLibrary()`, `openAdultLibrary()` (fails with `LibraryError.missing` when the file does not exist), and the opening path that takes a migrator, which tests use. File names come from one private mapping of `Partition` to a name; nothing outside the store builds a path.
- `Library` is a `Sendable` final class with no public initialiser. It holds its `partition` (a label for the interface, never a query input) and a GRDB database pool that is not public. Every public method is `async throws` and works on that one pool.
- `LibraryError`: `newerSchema`, `damaged` (SQLite reports that the file is not a database or is corrupt — codes 26 and 11), `missing`, `duplicateAddress`, `emptyName`, `nameTooLong`, `unknownCategory`, `invalidOrder`, `invalidMoveTarget`, and `storage(underlying description)` for everything else.
- Every connection of a library is prepared with the attached-database limit set to zero, so SQL on it cannot reach another file.

The app's default directory is `Application Support/Libraries/` inside its container.

**Schema, migration `v1`.** Column names as in spec section 4.
- `category`: `id` text primary key, `name`, `sort_order` integer, `icon` text, `overview` text (`auto` / `manual` / `off`, default `auto`), `updated_at`.
- `source`: `id`, `category_id` references `category` (restrict on delete — the category API decides what happens to sources), `kind` (`feed` / `github` / `huggingface` / `webpage`), `url` **unique**, `name`, `site_url`, `paused`, `auto_translate` (`inherit` / `on` / `off`), `body_mode` (`auto` / `page` / `feed`), `translate_page`, `etag`, `last_modified`, `last_success_at`, `last_error`, `updated_at`.
- `article`: `id`, `source_id` references `source` (cascade), `external_id`, `url`, `title`, `excerpt`, `author`, `image_url`, `published_at`, `first_seen_at`, `language`, `read_at`, `starred_at`; unique on (`source_id`, `external_id`).
- `article_body`: `article_id` primary key references `article` (cascade), `origin` (`feed` / `extracted`), `blocks` (JSON text), `fetched_at`.
- `seen`: (`source_id`, `external_id_hash`) primary key, `source_id` references `source` (cascade), `last_seen_at`.

Nullability and defaults are part of what `v1` freezes, because SQLite cannot relax them without rebuilding a table:
- `category`: every column `NOT NULL`.
- `source`: `NOT NULL` — `id`, `category_id`, `kind`, `url`, `name`, `updated_at`, and with defaults `paused` 0, `auto_translate` `inherit`, `body_mode` `auto`, `translate_page` 0. Nullable — `site_url`, `etag`, `last_modified`, `last_success_at`, `last_error`.
- `article`: `NOT NULL` — `id`, `source_id`, `external_id`, `first_seen_at`. Nullable — `url`, `title`, `excerpt`, `author`, `image_url`, `published_at`, `language`, `read_at`, `starred_at` (feeds omit any of the first seven; N04).
- `article_body` and `seen`: every column `NOT NULL`.
- No `CHECK` constraint on the closed sets (`kind`, `overview`, `auto_translate`, `body_mode`, `origin`): a later issue adds a value (RD26 adds nothing new, but a future kind would) and a `CHECK` cannot be changed in place. The sets are validated in Swift.

Foreign keys are enforced. Indexes beyond the keys and unique constraints are left to the issues whose queries need them. Address normalisation (what counts as "the same address") is RD05's, where addresses are entered; here uniqueness is on the stored string.

**Records.** `Category`, `Source`, `Article`, `ArticleBody` value types in `Model/`, `Codable` and `Sendable`, with small enums for the closed sets (`SourceKind`, `AutoTranslate`, `BodyMode`, `OverviewMode`, `BodyOrigin`). `CategoryIcon` is a fixed set of about twenty SF Symbol names (`CaseIterable`, raw value = symbol name). The record keeps the stored icon name as text and exposes the icon as a computed value that reads an unknown name as `folder`, because configuration files from a later version may carry icons this version does not know; an update writes only the columns it changes, so renaming a category never overwrites an icon this version does not recognise.

**Identifiers in SQL.** GRDB's lowercase-text setting covers record encoding and primary-key lookups only. Anywhere else — a filter on `category_id` or `source_id`, an `UPDATE … WHERE`, any raw argument — a `UUID` value is sent as a 16-byte blob and silently matches nothing (measured in the debate). So identifiers cross into SQL as lowercase strings through one helper, and no query binds a `UUID` directly. Only category operations are public API in this issue; the other records are used by tests through `@testable import` and get their public operations in RD04 and RD05.

**Categories.** On `Library`: `categories()` (ordered by `sort_order`, then `id`); `createCategory(name:icon:)` (trimmed; empty or longer than 100 characters refused; placed last); `renameCategory`, `setCategoryIcon`; `reorderCategories(_ ids:)` (must be a permutation of the existing ids; rewrites `sort_order` 0…n−1); `deleteCategory(_:sources:)` with `.deleteSources` or `.move(to:)` — deleting sources takes their articles, bodies and seen rows with them through the cascades; moving sets the moved sources' `updated_at` as well, since their category changed. Every operation checks and writes inside one write transaction, so a concurrent create or delete cannot slip between the check and the write. Duplicate names are allowed (N10 handles them at import). Every change sets `updated_at` from the injected clock.

**Version handling.** Opening creates the pool, asks the migrator whether the database has been superseded — it records a migration this build does not have — and only then migrates. A superseded database fails with `newerSchema` before any migration runs. This is the downgrade case after restoring a backup made by a newer build.

What is promised for that case is logical, not byte, identity. Creating a GRDB pool performs a scratch write of its own when the `-wal` is missing or empty, and closing the last connection checkpoints, so the main file's bytes can change even though no row, table or migration record does (measured in the debate: in most ways of writing the check the file grows by a page; the content is identical and the integrity check passes). There is deliberately no read-only pre-check to avoid that: a read-only connection fails on a healthy WAL database whose `-shm` file is missing, which would lock the owner out of a good library, and the `immutable` variant that avoids that failure ignores a non-empty `-wal` and can answer wrongly. A file that is not a database, or is truncated, is rejected by SQLite before anything is written, so those two cases do keep the file byte-for-byte.

**The version-1 fixture.** `Fixtures/library-v1.sql` is a plain SQL script: the `v1` schema exactly as the migration creates it, the migration bookkeeping row, and a few synthetic rows in every table. Tests restore it into a temporary file. One test compares its schema with a database migrated up to `v1` (so the fixture cannot drift from `v1`, and the test keeps holding when `v2` exists); one opens it through the store's opening path with `v1` plus a test-only later migration and reads the rows back. The script is text so that a reviewer can read it; it is written once, by dumping a `v1` database, and never edited afterwards. Its rows contain no control characters, so the dump has no `unistr(` call that an older SQLite could not read. Tests restore it on a throwaway connection outside a transaction (the dump carries its own `BEGIN` / `COMMIT`) and close that connection before the store opens the file.

**App.** `NewsPawApp` opens the normal library at launch and keeps the result in its state: loading, ready, or failed with a reason. `PlaceholderView` shows the existing placeholder when ready and, when failed, a short message: "NewsPaw could not open its library." plus one of three reasons — "It was created by a newer version of the app. Update NewsPaw to open it."; "The library file is damaged or is not a NewsPaw library."; or, for anything else, "Something went wrong while opening it." with the underlying description below it in small secondary text (that description is SQLite's own English wording and is shown as technical detail, not as the reason). All strings are in the catalog with Simplified Chinese. The app cannot call the adult functions.

## Files to change

| Path | Change | Reason |
| --- | --- | --- |
| `Sources/NewsPawKit/Model/{Category,CategoryIcon,Source,Article}.swift` | add | records (criteria 2, 5, 6) |
| `Sources/NewsPawKit/Store/{LibraryStore,Library,LibraryError,Schema,Library+Categories}.swift` | add | criteria 1–8 |
| `Tests/NewsPawKitTests/Store/{LibraryStoreTests,SchemaTests,CategoryTests,IsolationTests}.swift` | add | criteria 1–8 |
| `Tests/NewsPawKitTests/Fixtures/library-v1.sql` | add | criterion 3 |
| `ios/NewsPaw/NewsPawApp.swift`, `PlaceholderView.swift`, `Localizable.xcstrings` | change | criteria 1, 9 |

Paths in the first four rows are under `ios/NewsPawKit/`.

## Execution surface

- **Written:** the paths above.
- **Read only:** `docs/reader/spec.md`, GRDB's sources and documentation in the package checkout.
- **Executed:** `swift build`, `swift test`, `xcodebuild`, `xcrun simctl` (install, launch, `get_app_container`, screenshot), `sqlite3` (to dump the fixture once and to inspect files in tests' temporary directories or the simulator container), `git`.
- **Generated output:** `library-v1.sql` — produced once by opening a `v1` database with the implementation, inserting the synthetic rows through a throwaway script or test, and running `sqlite3 <file> .dump`; inputs are synthetic; committed.
- **Not touched:** dependencies and both lock files; `.github/`; `docs/` other than this design; the owner's ignored files; `.afk/` except the evidence folder named in the handoff.

## Key implementation notes

- CI compiles with Xcode 26.6 (Swift 6.3); the Mac has Xcode 27.1. Use nothing newer than Swift 6.2 syntax or iOS 26 API.
- Do not name a source folder `Data`, `Build` or `Dist`: the repository's ignore rules for the owner's local `data/`, `dist/` and `build/` directories are unanchored and the disk is case-insensitive, so such a folder would be silently untracked.
- Criterion 4, newer schema: compare applied migration names, `sqlite_master` text, row contents and `PRAGMA integrity_check` before and after the refused open — not file bytes. Read the "before" state and build the database through a pool, and if a test variant removes the side files, checkpoint with truncate first, or the data that still lives in the `-wal` is removed with them. Criterion 4, damaged files: compare bytes.
- Make the newer-schema test able to catch "migrated before checking": build the database with `v1` plus a test migration A, and have it refused by a migrator holding `v1` plus a different test migration B. A wrong order then shows B among the applied names. The store keeps one library per partition, so the build, the refusal and the reopen each use their own store instance, released before the next step.
- The isolation tests: the behavioural one (adult rows never come back from the normal library, with the adult library actually holding categories with sources and articles), and `ATTACH` attempted on the writer and on a reader of a library, both expected to fail. Set the limit in the pool's connection preparation so every connection gets it.
- Give the move and delete tests categories that really hold sources (and articles under them), so a filter that matches nothing cannot pass. Add a test that, after each write path, every `id` / `*_id` column satisfies `typeof(x) = 'text' AND x = lower(x)`.
- For criterion 1 in the simulator: erase or freshly install on a NewsPaw simulator, launch, then list the `Libraries` directory of `xcrun simctl get_app_container <device> io.newspaw.reader data`.
- For criterion 9 in the simulator: put a file that is not a database at the library's path before launch and take a screenshot in both languages; then remove it.

## Risk assessment

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| The schema needs a change once RD04/RD05 use it | High | Low | Append-only migrations; the fixture test keeps old data openable |
| A GRDB behaviour differs from what this design assumes | Medium | Medium | Read the checkout's documentation first; report any deviation |
| The isolation test proves less than it claims | Medium | High | Two tested assertions (adult rows never come back; `ATTACH` fails on writer and reader) and one named review check (no API takes a partition or another library); the reviewer is pointed at all three |
| Opening on the main thread delays launch | Low | Low | Open asynchronously; the placeholder has a loading state |

## Out of scope

Everything under Non-goals; indexes for list queries; address normalisation; deleting or exporting database files; any setting.

## Test plan

- `LibraryStoreTests`: fresh directory → `normal.sqlite` exists, adult does not; `openAdultLibrary()` before creation fails with `missing`; `createAdultLibrary()` then both exist; a second `openNormal()` returns the same instance; two concurrent `openNormal()` calls return the same instance; a new store on the same directory (after the first store and its library are released) reads the existing data.
- `SchemaTests`: tables, columns, nullability, defaults, uniqueness and foreign-key behaviour after `v1`; the fixture's schema equals a database migrated up to `v1`; the fixture opened with `v1` plus a test-only later migration has that migration applied and its rows intact; that same database opened with the production migrator is refused with `newerSchema` and is logically unchanged (criterion 4); a not-a-database file and a truncated database are refused with `damaged` and byte-for-byte unchanged.
- `CategoryTests`: every operation and failure case in criterion 5, including the cascade on `.deleteSources` and the reassignment on `.move(to:)`.
- `IsolationTests`: criterion 6 and the testable parts of criterion 7.
- Simulator, by the implementer, with evidence: criterion 1 (container listing) and criterion 9 (two screenshots).
- Both project commands from `AGENTS.md` pass.

## Handoff notes

Branch `feat/rd02-partition-libraries` from `main` after RD01 has merged; the design document is committed there by the driver. Commit locally; do not push. Return the diff identity, each criterion with its proof, deviations, and what was not verified.

## Debate record

**Round 1 (2026-11-11).** A critic agent attacked version 1, reading GRDB 7.12.0's sources and running experiments in a throwaway package (Swift 6.4, system SQLite 3.54.0, macOS 27.0.1). Ten findings, no P1; all supported, all accepted.

| ID | Severity | Finding | Resolution in version 2 |
| --- | --- | --- | --- |
| D1 | P2 | A read-only pre-check is stricter than the real open and its "no side file" assertion cannot hold | No pre-check: pool, then `hasBeenSuperseded`, then migrate; the assertion is on the main file only |
| D2 | P2 | Outside record encoding, a bound `UUID` is a blob and silently matches nothing | One helper for identifiers in SQL; tests with real sources; a lowercase-text check on every id column |
| D3 | P2 | A second pool on a file fails writes | One `Library` per file, same instance on reopen (criterion 8) |
| D4 | P2 | Two of three isolation assertions could not fail | `ATTACH` disabled on every connection and tested; the API-shape part is named a review check |
| D5 | P2 | Adult functions had no stated access level | `internal` in this issue |
| D6 | P2 | `v1` froze nullability, defaults and checks nobody had decided | Decided in the Schema section |
| D7 | P2 | No test opened a database from an earlier schema version | The fixture is opened with `v1` plus a test-only later migration |
| D8 | minor | Dump restore details | Restore outside a transaction; no control characters in fixture rows |
| D9 | minor | The failure message was raw SQLite text | `damaged` error with its own sentence; raw text only as secondary detail |
| D10 | minor | Category semantics left open | One transaction per operation; moved sources' `updated_at`; changed columns only; injected clock |

**Round 2 (2026-11-11).** The same critic revalidated version 2. D2–D10 resolved. D1 reopened and raised to P1: creating a pool on a newer database changes the main file's bytes in most variants (GRDB's own scratch write, and the checkpoint on close), so "byte-for-byte unchanged" could not be met as written; the round-1 experiment behind that wording had covered one variant only. Three new minor findings.

| ID | Severity | Finding | Resolution in version 3 |
| --- | --- | --- | --- |
| D1 | P1 | Pool-first cannot keep a newer database byte-identical | The promise for the newer-schema case is logical identity (migrations, schema, rows, integrity); byte identity is kept only for damaged files, where SQLite rejects before writing |
| D11 | minor | Two concurrent first opens could create two pools | Find-or-create is atomic; a concurrency test |
| D12 | minor | Three passages contradicted the revised criteria | Aligned |
| D13 | minor | A new closed-set value without a migration would make an older build fail on decode | Invariant: such a value ships with a migration |

**Round 3 (2026-11-11).** D1, D11, D12 and D13 resolved in the text; nothing newly broken. One minor note (D14: the newer-schema comparison could not detect a migrate-before-check order) was applied as a test instruction without changing a decision, so no further round was run.
