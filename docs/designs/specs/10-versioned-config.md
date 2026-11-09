# F01 / #10 — Single-user configuration and SQLite migration

## Spec review / frozen contract
One owner, one local backend and database, multiple Bot targets. Implement versioned configuration with stable IDs for sources, categories, subscriptions, accounts, model profiles and bots; migrate only non-secret legacy values. F04 later imports actual secrets into Keychain. Preserve prototype APIs and accepted mockup. No ORM, generic plugin system, cloud synchronization or per-bot database.

Acceptance:
1. A validated JSON configuration document has schema version 1, separate zh-Hans/en/ja UI/news locales, Tokyo default timezone, user-confirmed four text models/URLs, stable built-in category/subscription/profile IDs and generated IDs for user entities. Config stores credential references only; defaults/migration contain none, all subscriptions initially disabled. Bots start unverified/unpaired.
2. SQLite has an explicit schema version, a single current configuration row and monotonic revision. Compare-and-swap save prevents two stale UI/worker writes from silently overwriting each other. Reads/writes reject a future schema before making schema changes. Existing Store entrypoints check supported schema versions too; this cannot retroactively add checks to historical binaries.
3. Existing database upgrade backs up before any schema/data mutation, then executes schema/init migration atomically. Failure leaves original schema/data usable; retries do not duplicate entities. Empty database initialization needs no backup. Concurrent initializers serialize, recheck the version after lock acquisition and do not overwrite successful migration.
4. Legacy migration is explicit, reading a provided .env path and existing SQLite settings, never os.environ/private data paths implicitly. Only known non-secret preferences migrate. Database settings override corresponding .env preferences. Credentials and API-key-bearing URLs never enter the new document. Default model IDs remain the confirmed current defaults; explicit legacy model customization may be preserved only as a validated user override, never silently replacing confirmed defaults with stale prototype defaults.
5. IR-04: old deliveries/deliveries_v2 receipts and briefs remain in their original tables for audit and existing legacy deduplication. They are not converted into new runnable jobs, outbox rows or completed new subscription editions. old last_slot stays only legacy state; migration records a cutover timestamp and disables new subscriptions. Q01 must start new edition eligibility no earlier than that cutover when subscriptions are explicitly enabled; it must not replay old prepared briefs. No historical messages are sent by migration.

## Chosen shape and boundaries
A small `app_config.py` module owns defaults/validation/JSON encode-decode and explicit non-secret import. Use plain dictionaries with strict field allowlists, bounded lists/text and dedicated validators rather than an extensible schema framework. Required relationships (source-category, subscription-category/bots, account overrides, category profile overrides) are validated before save; routing and partition policy execution belong to F02. Defaults are drafts, not operational readiness claims. Credential references use a private `keychain:<UUID>` identifier; existence/readiness verification belongs to F04/M01/T01, not syntax validation.

`migrations.py` owns supported SQLite user_version and migration entrypoint. Extend existing Store with `load_config`, `save_config(expected_revision=...)`, and explicit `import_legacy_config(env_path)`, leaving legacy get/set/receipt/audit behavior intact. A single row is sufficient for this one-user app; no event-sourcing/config-history system. Return revision plus immutable-by-copy data to callers. Legacy import runs once, atomically with its import marker, and requires no enabled subscriptions so it cannot overwrite a running setup.

SQLite upgrade uses BEGIN IMMEDIATE to serialize writers, then a separate source connection's SQLite backup API to copy the committed pre-migration database into a private adjacent unique backup file while the first connection holds the writer reservation. This backup/lock interaction is a claim to verify in a disposable fixture before implementation relies on it. Apply individual schema statements under the same transaction (not executescript implicit commit). Set user_version last and commit. Backup failure or migration exception rolls back; remove incomplete backup artifacts, retain completed backup. Existing version-zero prototype initialization is folded into migration so corrupt/future databases are rejected before table DDL; new databases get the same legacy tables for compatibility.

## Allowed edits and consumers
| Path | Change | Consumer |
| --- | --- | --- |
| src/newspaw/app_config.py | add defaults, validation, explicit import | later routing/control/UI |
| src/newspaw/migrations.py | add migration/backup/version guard | Store startup |
| src/newspaw/store.py | replace initialization DDL with migration; config read/CAS/import methods | legacy Bot plus future backend |
| tests/test_app_config.py, tests/test_migrations.py | fixtures and fault injection | offline pytest |
| docs/designs/specs/10-versioned-config.md | frozen design | reviewers |

Read: config.py, bot.py, existing Store tests and requirements. Execute only uv pytest/Ruff/build and disposable SQLite experiments. No actual data/, service install, model call, Keychain mutation or Telegram. Backups are generated only beside a caller-supplied test database during validation. Production startup backup uses same private application directory; O01 later owns retention.

## Assumptions / risk
SQLite backup while a writer reservation exists must be experimentally verified without deadlock; if invalid, correct this contract with evidence before coding. Original unversioned binary has no schema guard; use the current version guard going forward and document that downgrades must restore a matching backup rather than open a newer database. No claim that arbitrary old software is magically prevented from opening a file. Mid-migration crashes rely on SQLite transactional recovery; explicit fault fixture validates the visible before/after schema. Stable default IDs are deterministic; arbitrary entity IDs are UUIDs generated once and persisted.

## Tests and handoff
RED tests for absent config/migration APIs, then defaults/independent locales/model IDs; strict unknown/secret fields, reference relationships and malformed URLs; migration from old populated DB including receipts/last_slot; repeat initialization/import; future schema rejection; corrupt file unchanged; backup success/failure; injected migration failure rollback and retry; concurrent writers/CAS; explicit secret-bearing .env imports omit secrets and remain disabled/unpaired. Disposable backup/transaction probe before implementation. Preserve existing full Store/config suite. No business job scheduler is added here. Debate must close before coding; implementation/internal/Kimi/final-suite/CI follow, per active run policy.

## Superseded by E10 (2026-11-10)

The Tokyo default timezone is replaced: new databases default to the system IANA timezone. See [docs/planning/ux-redesign/contract.md](../../planning/ux-redesign/contract.md) §5 for the replacement clause; the rest of this contract stays in force.
