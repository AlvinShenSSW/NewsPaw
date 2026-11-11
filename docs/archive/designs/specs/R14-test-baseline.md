# R14 / #92 — test baseline: X clock injection

## Spec review

Since 2026-11-09 `uv run pytest -q` reports 33 failures (test_x_timelines 17, test_x_digests 8, test_x_alerts 4, test_x_video 4). The fixtures pin `NOW = 2026-11-08T02:00Z` (tests/test_x_timelines.py:13) and inject it into `Timelines`, but `XDirectory._read` (src/newspaw/x/accounts.py:507-508) reserves and begins its X-read budget attempt with the real clock. The first metadata read therefore opens the X budget period for the real date; the later `Timelines` reservation at `NOW` is earlier than that period and `BudgetLedger._period` raises `clock_before_current_period` (src/newspaw/budget.py:225-226) → `budget_blocked`. Separately, `Timelines._reserve_step` reserves with `now=self.clock()` but calls `self.budget._begin_attempt(budget_id)` without it (src/newspaw/x/timelines.py:511), so the same attempt is checked against two clocks.

## Frozen issue contract

- `uv run pytest -q` passes regardless of the real system date relative to the fixture `NOW`.
- Production behaviour is unchanged: both new clock parameters default to the real UTC clock that is used today.
- One clock per budget attempt: whoever reserves an X attempt begins it with the same clock.
- Allowed changes: an optional `clock` keyword on `XDirectory`, passing `now=` at the two budget calls in `XDirectory._read`, passing `now=` to the `_begin_attempt` call in `Timelines`, and test fixtures that inject the fixture clock.
- Non-goals: no change to X behaviour, budget rules, or the string timestamps `XDirectory` writes with `_now()`; no new Swift abstractions.

**Contract correction from repository evidence (Swift part of the issue).** The issue also asked for a separate Swift "ViewModel" test target. `macos/NewsPaw/Tests/NewsPawTests` already exercises view-model-level types through `@testable import NewsPaw` (LocaleEdit, ProtectedSettings, SubscriptionDraft, XRouteInput), and `.github/workflows/checks.yml:42` already runs `swift test` on the macOS job. `EditorState` and the typed client do not exist yet; they are created by R06 (#84), which adds their tests to the existing target. A second empty target now would be an abstraction without a requirement, so it is dropped. Likewise, no repository document claims "CI passed" (the claim was in an external handover note), so there is nothing to update there.

## Approach

Inject, don't fake time globally: `faketime` is not installed and monkeypatching `datetime` would hide the real inconsistency. `XDirectory(..., clock=_utc)` mirrors `Timelines(..., clock=_utc)` that already exists.

| Path | Change | Reason |
|---|---|---|
| src/newspaw/x/accounts.py | `clock` kwarg, `now=self.clock()` on `_reserve` and `_begin_attempt` in `_read` | metadata reads use the injected clock |
| src/newspaw/x/timelines.py | `now=self.clock()` on `_begin_attempt` | same clock as the reservation |
| tests/test_x_accounts.py | `directory(..., clock=None)` passes through | fixture injection point |
| tests/test_x_timelines.py | `setup` and the restart test pass `clock=lambda: NOW` | all X fixtures share `NOW` |

Consumers of `XDirectory`: control.py:219 constructs it without `clock` → real clock, unchanged. Consumers of the `Timelines._begin_attempt` change: production passes the real clock as both arguments → unchanged.

## Test plan

- RED: the 33 current failures.
- GREEN: full `uv run pytest -q` and `uv run ruff check .`.
- Date-independence check (verification step, not committed): keep the fixture `NOW` and move the *real* clock instead, with a throwaway pytest plugin that replaces `datetime.now` in every `newspaw.*` module (excluding the CLI entry point). Changing `NOW` itself is the wrong probe: several assertions intentionally pin literals such as `'2026-11-08T02:00:01Z'` and Tokyo day boundaries of that date.
  - this branch, real clock 2026-11-01 / 2026-11-08 / 2031-06-15 → X test files 74 passed each;
  - `main`, real clock 2026-11-07 / 2031-06-15 → 35 / 33 failed (control).
