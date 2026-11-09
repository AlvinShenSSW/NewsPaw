# R04 / #82 — check keys when saved, verify media capabilities on demand, first Bot as default target

Implements the R04 rows of [contract.md](../../planning/ux-redesign/contract.md) §2 ("能力探测", "报纸预留", "图片 / 语音提问预留", "目标 Bot").

## Frozen issue contract

1. **Key saved → text checked.** After `credentials.set(kind="model_profiles")` succeeds, the backend checks the `text` capability of that profile in the background with a built-in $0.01 hold. The RPC returns immediately; the app sees the result through `models.status` / `setup.readiness`. A failed or rejected key is recorded by the existing probe path (status `failed` with the provider error kind).
2. **No double charge.** The automatic probe ID is `auto.<profile>.<capability>.g<generation>`. The profile generation changes whenever the key (credential reference) or another identity field changes, so a new key is always checked once, and a repeated save or configure with the same key reuses the earlier result through the registry's existing idempotency. A capability that is already `verified` is not checked again.
3. **On-demand capabilities.** Turning the newspaper on fills empty `generation_hold` / `vision_hold` / `task_limit` with $0.40 / $0.05 / $1.00 and checks `image` for the generation and backup profiles and `vision` for the vision profile. Choosing a vision or transcription profile for Telegram media fills an empty hold with $0.05 and checks that capability. Existing amounts are never overwritten.
4. **`tts` removed** from the capability list (speech output is macOS `say`, never a provider).
5. **First Bot.** When a Bot completes pairing and no other Bot is paired, it is added to every ordinary-partition subscription whose `bot_ids` is empty, in the same transaction as the pairing. Adult subscriptions and any later Bot are never assigned automatically.
6. **`models.health`** returns the runtime model health rows (failures, cooldown) that previously only appeared in support snapshots.

Non-goals: no change to probe accounting, cross-partition rules or the explicit `models.probe` op; no automatic assignment of X special accounts (they inherit their subscription's targets).

## Approach

- `ControlServer._verify_soon(profile_id, capabilities)` runs probes in a tracked background task; `close()` cancels and awaits them, so shutdown keeps the probe service's existing cancellation semantics (in-flight paid calls become `outcome_unknown`). Errors from a background check are logged by type only.
- Hold defaults live next to their policies (`paper_service.DEFAULT_HOLDS`, `input_service.DEFAULT_HOLD`) and are applied inside `configure` before validation, so the returned policy shows the stored values.
- `_assign_first_bot` runs inside `BotRegistry._consume`, the transaction that records the pairing, so the target and the pairing commit or roll back together.

## Verification

`tests/test_control.py`: key save triggers exactly one text check with the auto ID and $0.01 hold, a failed credential save triggers none; enabling the newspaper and choosing a media profile fill the default holds and check image/vision; an already verified capability is not checked; `models.health` is served. `tests/test_telegram_registry.py`: first pairing fills only empty ordinary subscriptions; a second Bot's pairing assigns nothing. Full suite, ruff.
