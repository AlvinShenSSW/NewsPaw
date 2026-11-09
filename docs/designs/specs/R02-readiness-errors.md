# R02 / #80 — setup.readiness and structured control errors

## Spec review

The settings app cannot tell the owner what is still missing before the first digest arrives, and every control failure reaches the UI as one flat string; anything outside five exception families becomes `invalid_request`, which also hides real internal faults (control.py:620-623). The pipeline folds evidence/editorial/provider/runner failures into `preparation_failed` (pipeline.py:657-660), so the overview cannot say why a job stopped. R02 adds one cheap aggregate (`setup.readiness`) and a structured error envelope, and keeps specific job failure codes.

## Frozen issue contract

1. New op `setup.readiness` (no params) returns
   `{"complete": bool, "next": step|null, "scheduling_enabled": bool, "steps": [{"step","state","blocker_code","entity_id","fix_op"}]}`
   with the fixed order `bot → model → digest → first_delivery`; `state ∈ {done, pending}`; for `pending` steps `blocker_code` is a stable code and `fix_op` names the existing control op that resolves it (or `null`); `done` steps carry `null` blocker/fix and the satisfying `entity_id`.
   - **bot**: no bots → `no_bot` / `credentials.set`; a bot exists but none verified → `bot_unverified` / `bots.verify`; verified but none paired → `bot_unpaired` / `bots.pair_code`; done when `owner_id` is set and a bot is verified and paired.
   - **model**: the ordinary primary profile (`partition=normal, role=primary`): none configured → `missing_primary` / `null`; no `credential_ref` → `missing_primary_credential` / `credentials.set`; text probe `failed` → `model_failed` / `models.probe`; any other non-verified state → `model_unverified` / `models.probe`; done when the text probe is `verified`. (The probe record is read directly: `capabilities` is only its projection and is recomputed on every config save.)
   - **digest**: no enabled subscription → `no_enabled_digest` / `subscriptions.save`; enabled ones all blocked → first enabled subscription's first route blocker / `route.preview`, `entity_id` = that subscription; done when one enabled subscription resolves with no blockers.
   - **first_delivery**: done when any delivery target part has been delivered or owner-confirmed; else `no_delivery_yet` / `null`.
   - Read-only, no network, no Keychain access (polled every 3 s by the app).
2. Error envelope: replies keep `{"ok": false, "error": "<code>"}` unchanged and add `"error_detail": {"code", "domain", "retryable", "field"?}`.
   - `domain` = the op namespace (`bots`, `models`, `x`, …); `protocol` for frame/shape errors before an op is known.
   - `field` present for request-shape errors (first missing, else first unexpected key) and for any raised error carrying a `field` attribute.
   - `retryable` true only for transient codes where repeating the same request can succeed: `rate_limited`, `transport_error`, `timeout`.
3. Unknown exceptions (not `CredentialError`/`BudgetError`/`ProviderError`/`TelegramError`/`SourceError` and not a code-shaped `ValueError`) return `internal_error` and are logged with op and exception type only (no message — messages may carry secrets). A malformed frame or JSON still returns `invalid_request`. A plain `ValueError` whose message is a code identifier (`[a-z][a-z0-9_]{0,63}`) returns that code; other `ValueError` text returns `invalid_request`.
4. `Pipeline._step` stores the raised code as the job `error_kind` when it is code-shaped, else `preparation_failed`; `storage_failed` keeps its current escalation. Scheduler workers already keep `CredentialError` codes (scheduler.py:772-776) — unchanged.
5. `service.status` adds `"operations": [sorted op names]`; `protocol_version` stays **1**.

**Contract correction (repository evidence).** The issue text asked for `protocol_version 2`. The shipped Swift client rejects anything but 1 (`BackendModel.swift:235, 330`), so a bump would mark the installed app incompatible although every change here is additive. The version stays 1; the op list lets the R06 client detect new ops.

Non-goals: no socket framing change, no new transport, no Swift change (R06), no long-running op rework (R05), no new readiness steps beyond the four the overview shows.

## Approach

- `src/newspaw/errors.py` (new, ~30 lines): `CODE` regex, `code_of(exc, fallback)`, `RETRYABLE`, `detail(code, domain, field=None)`. One helper shared by control and pipeline instead of two copies.
- `src/newspaw/readiness.py` (new): `readiness(store, profiles)` — pure reads of `store.load_config()`, `ProfileRegistry.status(profile_id)`, `resolve_route(...)`, scheduler policy row, one `EXISTS` query on `delivery_targets.parts`.
- `control.py`: register op, wire it, build envelope in `_handle`, request-shape `field`, unknown-exception logging.
- `pipeline.py`: one-line change in `_step`.

Consumers: Swift `BackendRPC.send` reads only `error` (BackendModel.swift:53) — unaffected by the added key. Tests asserting `{"ok": false, "error": ...}` equality need checking (grep tests for `"error":`).

## Test plan

- readiness: empty DB; bot added unverified; verified unpaired; paired + no key; key without probe; probe failed; probe verified + no enabled subscription; enabled subscription with `no_sources`; fully routable; one delivered part → `complete`.
- errors: unknown op, missing key (`field`), extra key (`field`), injected `sqlite3.Error` / `KeyError` → `internal_error` + log record without message, code-shaped `ValueError` → code, free-text `ValueError` → `invalid_request`, `rate_limited` → retryable true.
- pipeline: `EditorialError("no_publishable_items")` → job `error_kind == "no_publishable_items"`; free-text message → `preparation_failed`.
- service.status lists `setup.readiness`.
