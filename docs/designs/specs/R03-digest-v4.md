# R03 / #81 — digest settings (schema v4), scheduling defaults and budget defaults

Implements [contract.md](../../planning/ux-redesign/contract.md) §1–§2 on the backend, plus the "send one now" operation the interaction spec assigns to R03 (§5.6, §9).

## Frozen issue contract

1. **Schema v4.** `categories` keep only `id/name/partition`. Each subscription gains nullable `primary_profile_id` / `backup_profile_id` and a non-null `style`. `group_styles` is removed. Style precedence is request > single-send X account > subscription; model slots are subscription override > partition default. Cross-partition and wrong-role overrides are rejected on the subscription.
2. **Upgrade.** `upgrade_v3` writes each subscription's v3 *effective* style (subscription > category > partition group style > `text`) and copies its category's model overrides; one `upgrade_config()` chains v1→v4 for both the database migration (DATABASE_VERSION 24) and settings import. Migration keeps the existing backup / `BEGIN IMMEDIATE` / rollback path and bumps the config revision.
3. **Scheduling.** New databases: scheduling on, holds $0.50 per partition, `activated_at` NULL until the first `plan()` (or an explicit `configure`) so activation is the first scan, not database creation. Upgrades fill empty holds; they turn scheduling on only when no subscription is enabled (otherwise it would start delivering digests the owner enabled while it was off). Stable slot IDs and completed-occurrence identity are unchanged (spec 29).
4. **Budget and time zones.** New databases: monthly cap $20, X 200 reads/day, budget / alert / video policy time zones equal to the configuration time zone, which is the system IANA zone (`TZ`, then the `/etc/localtime` link, else Tokyo). Existing databases keep their values; secondary limits are untouched. Unknown prices already proceed as an unpriced manual hold (`model_runner.py:321-324`) — no change needed.
5. **`subscriptions.send_now(subscription_id)`** queues one extra edition of an enabled digest through the normal schedule path (slot 0 = manual, target now + 2 minutes, normal catch-up window). One per digest per local day; repeating returns the same occurrence. Errors: `digest_not_enabled`, `scheduling_paused`. The manual occurrence survives retiming of the digest's configured slots and expires only after its catch-up window or when the digest is disabled.
6. **Compatibility.** Partial subscription drafts that omit the model overrides keep the saved values. The current Swift app's two writers of removed fields are adapted: the group-style sheet is removed (style is per digest in the subscription editor, whose "inherit" option disappears) and the category routing sheet writes overrides to every digest of the category until R09 replaces it.

Non-goals: no new tables or renamed keys; no change to outbox keys, partition isolation or `outcome_unknown`; no built-in prices; no immediate-send for X special accounts.

## Contract correction (repository evidence)

Contract §2 says budget periods "follow" the global time zone. Spec 21 forbids a policy edit from changing an already-open period, and budget periods persist their own zone, so live following would need a period-splitting mechanism. New databases therefore *start* with the same zone everywhere; later global changes do not rewrite budget periods. This matches contract §2's own wording for alert/video ("新库与全局时区取同一个系统时区").

## Consumers of removed fields

`routing.py` (style + slots), `operations.py` (export scrub, import, fresh-instance check), `app_config.py` legacy import, Swift `RuntimePolicyWorkspace` (group styles) and `CapabilityRouting` (category overrides). Swift decoding already treats the removed keys as optional.

## Verification

- `tests/test_app_config.py`: effective-style table, override move, idempotent `upgrade_config`, system time zone resolution.
- `tests/test_migrations.py`: v1/v2 fixtures built from a genuine v3 document; v24 schedule upgrade both ways; new-database time zone and limits.
- `tests/test_scheduler.py`: lazy activation; `send_now` idempotence, retiming survival, catch-up expiry, error paths.
- `tests/test_subscriptions.py`: partial drafts keep overrides.
- Full `uv run pytest -q`, `uv run ruff check .`, `swift build`, `swift test`.
