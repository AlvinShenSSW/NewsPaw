# R08 / #86 — Overview page

Implements interaction-spec §4 on top of the R06 shell. Data comes only from existing operations: `setup.readiness` (R02), `schedule.status`, `delivery.status`, `budget.get`, `sources.list`, and `subscriptions.send_now` (R03).

## Frozen issue contract

1. **Setup checklist** — shown while `setup.readiness.complete` is false: "N more steps", a progress bar, the four steps with done / current / pending markers, and one button per step: done → View; current bot/model step → Connect; current digest step → Turn On (Digests page); current first-delivery step → Send a Trial Now (`subscriptions.send_now` on the first enabled ordinary digest). It disappears when readiness is complete.
2. **Today's deliveries** — today's occurrences from `schedule.status` (limit 100, local civil date), sorted by target time, each with time, digest name in the interface language, a note, a status dot plus words, and its action. "Last 7 days" expands the six previous days in place.
3. **States and actions** follow contract §3: waiting / preparing / late / sent / partly sent / skipped (with the reason: no news, superseded, digest turned off, retimed, missing local time, missed catch-up) / paused / resend abandoned / result unknown / needs your decision / not sent (reason copy from `FailureCopy`). Model-unknown → `jobs.resume(acknowledge_duplicate_charge)`; delivery-unknown or partly sent → `delivery.resolve` retry with `acknowledge_duplicate_send`, or skip ("Don't Resend"); held → `schedule.resolve` continue / stop. Every duplicate-risk or irreversible action is confirmed first. A part resolved with skip shows "Resend abandoned" and no further action.
4. **This month's spending** — dollars from the current model budget period (`known_settled + held`) against its cap, falling back to the policy cap before the first paid call; image spending and unpriced calls when present; X reads today against the daily cap.
5. **Worth a look** — ordinary key failed its check, a Bot waiting to pair, a stale source with its age, spending cap reached, X reads without a daily cap, no backup model key; each links to the page that fixes it. Hidden when empty.
6. **Toolbar** — "Send One Now…" lists enabled digests (`subscriptions.send_now`, once per digest per day).
7. **Backend down** — the R06 "backend not running" group replaces the page.

Non-goals: history beyond 7 days, per-part delivery inspection, editing anything on this page.

## Verification

`swift test` 40 tests: today/week split and dollar spending from a scripted backend; policy-cap fallback; state vocabulary for every status; each recovery sends exactly its operation and acknowledgement; skip resolution shows abandoned; skip reasons; digest names localized unless split; copy completeness. Offscreen snapshots against an isolated backend seeded with delivered / held / model-unknown / skipped occurrences in three languages, light and dark.
