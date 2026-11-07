# S01 / #14 — persistent RSS evidence and source health

## Spec review
The prototype retrieves RSS afresh and stores a whole report. Add a reusable, partitioned evidence collector with durable conditional-fetch state and explicit health. Keep the existing bot API compatible. This is collection infrastructure, not full-text verification, scheduling or delivery.

## Acceptance and frozen contract
- Keep source publication, update and actual content-fetch timestamps separately, including raw date strings. A fresh result requires explicit timezone publication within the requested window; update/fetch time never substitutes. Unknown, future and old entries remain inspectable evidence but never fresh output.
- Persist normalized bounded title/excerpt/link/publisher/feed-language/image metadata and excerpt-only scope. Retain each response snapshot and rejection counts. No raw XML or images stored.
- Distinguish HTTP 200 fresh, stale-only, empty and no-eligible-date results; HTTP304 checked-not-refetched, 429 rate-limited, parse/network/HTTP failures. Health separates connectivity from content age. Each source may override persisted stale threshold; default72h, configurable1..8760h. Low-frequency sources remain healthy within their own threshold even when a24h brief has zero eligible items. Unknown latest publication means freshness unknown, not healthy.
- Same exact URL within one content partition is fetched once per collection batch even if multiple source IDs/subscriptions use it. Separate normal/adult network requests, conditional validators, snapshots, associations and queries. Reuse does not merge subscription/topic associations.
- ETag/Last-Modified conditional requests survive restart. A304 reuses the last successful body snapshot, reevaluates freshness at current time, and preserves original fetched_at; a304 without a prior snapshot is a protocol failure. A failed/new invalid200 never destroys the last good cache or installs validators. An empty valid200 replaces the current snapshot and validators. Do not serve previous data as a new successful response after failure.
- Start each attempt durably before I/O; complete snapshot/cache/associations/outcome atomically. Cancellation is recorded; interrupted attempts recovered explicitly at backend startup. Failed attempts retain requested associations and safe error codes. No raw exception text/credentials.
- Existing NewsService/parse_feed behavior stays compatible; new collector called by later scheduler/source-management tasks. No model or Telegram calls, no changes to the approved mockup. One Store/SQLite and source HTTP transport, no new service/framework/dependency.

## Assumptions and authority
Manual source preview may collect a classified configured RSS/Atom source even when disabled; it does not enable it or send anything. Subscription collection resolves current config, uses enabled classified compatible sources, and permits manual collection of a disabled subscription. Scheduler readiness remains Q03. Unclassified sources are rejected before network. URL/content-type edits select a new partition+URL cache key; old history remains its original partition. No claim that server validators are truthful; conditional freshness is based on retained source timestamps. Public internet behavior is not validated by offline fixtures.

## Approach and lifecycle
Refactor parser into a bounded normalized parse plus existing eligibility wrapper, adding optional updated_at/raw and language to Article with defaults. Preserve existing XML safety and sanitization. New evidence.py holds FeedCollector and small SQLite repository methods using Store._write; schema5 tables for attempts, immutable response snapshots/items (JSON normalized bounded rows acceptable), subscription/source associations, current cache and per-key health threshold. Keys include partition and exact configured URL; use stable hashes only for IDs, never infer article truth/independence from hashes. Source identities are stored separately from publisher metadata.

Collector resolves selected subscriptions from Store config once, validates source-category compatibility and enabled sources, groups requests by partition+URL, then fetches sequentially (single-user, no concurrency framework). A preview method resolves one configured source. Before each fetch recheck relevant current source/subscription membership to reject stale configuration; after I/O recheck before associating results. Content obtained under old partition stays old partition if config changes; report stale configuration and never attach to newly reclassified subscription. No arbitrary caller-supplied partition/URL routing. Same-key asyncio lock avoids overlap on this collector; one backend owns it.

Use bounded source_client already provided by F03; conditional headers must be accepted by its allowlist. Same-origin redirects only, max3, safe transport validates every dial. Cache validators apply only to matching final URL; if redirected to a different URL do not forward validators. Deadline30s/max2MiB/200entries existing bounds. Persist ETag/Last-Modified only bounded printable ASCII header values (<=1024); Retry-After recorded as bounded integer seconds or parsed aware HTTP date, without automatic retry. All actual I/O is GET, no provider credentials. On cancellation finish attempt cancelled then propagate; explicit recover_interrupted turns only running attempts into interrupted on owned startup. DB write failure propagates and rolls back; initial running attempt remains recoverable.

Read APIs require partition and optionally subscription/source ID; return eligible articles plus attempt outcome/coverage. A subscription association is a historical snapshot, not automatic permission to reuse after reclassification: current partition/membership is checked on access. Health query returns last_attempt result independently of latest successful publication and threshold. Future timestamps do not make health healthy. Repeated identical200 may store another bounded snapshot for audit; retention belongs O01, no silent200-report pruning. A304 points to prior immutable snapshot while its own attempt associations remain distinct.

## Files / execution surface
|Path|Write and purpose|
|---|---|
|src/newspaw/news.py|Shared bounded parser; preserve old fresh-only APIs|
|src/newspaw/evidence.py|Collector, persistent evidence/cache/health/query methods|
|src/newspaw/migrations.py|Schema5 initialization under existing backup/transaction|
|src/newspaw/control.py|Startup recovery only; user source RPCs remain S04|
|src/newspaw/transport.py|Only if conditional header allowlist needs narrow addition|
|tests/test_evidence.py, tests/test_news.py, tests/test_migrations.py|Hermetic behavioral fixtures|
|docs/designs/specs/14-rss-evidence.md|This frozen contract|
Read app_config/routing/store and source-strategy; no edits to mockup/providers/runtime bot. Run uv run pytest -q, uv run ruff check ., uv build (build produces ignored dist). Tests create disposable SQLite/HTTP fixtures, no live fetch or send. No generated production files.

## Risks / tests
- Publication/update ambiguity: RSS/Atom multilingual fixtures, missing/timezone-less/future/old published, updated-only; preserve raw fields and unknown metadata.
- Cache poisoning/staleness:200→304 after restart/time advancement; changed validators and empty200; error200/429/timeout/304withoutcache; redirects strip validators; retain fetched_at.
- Isolation/reuse: same-source two subscriptions one request/distinct associations; same URL normal/adult separate; classification/config change during I/O quarantines associations; stale history access rejected.
- Durability: failed attempts persisted, cancellation, crash recovery, transaction failure rollback and migration4→5 rollback/retry with history intact.
- Health: old200 vs empty200 vs304 vs failure, low-frequency threshold distinct from article window, missing/future publication never healthy.

## Handoff
Initial S01 allowance0/6. Mandatory same-model design debate before code. M03 external review is running; this prospective ignored plan must not change its tracked target. After M03 review, create issue branch and copy the clean design into tracked specs. Integration with paid planning, web adapters, scheduling, UI and retention remains the assigned downstream issues.
