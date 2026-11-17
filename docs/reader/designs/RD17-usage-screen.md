# RD17 — Usage screen and the daily automatic limit setting

Issue: [#138](https://github.com/AlvinShenSSW/NewsPaw/issues/138) · Epic E14 #117 · Priority P1 · Requirements N11 (Usage, the daily automatic limit); ux S8 (Usage row); spec section 4 (partition settings). Also touched: N02 (partitions), N13 (offline tests).
Design version 2 (2026-11-16), after one debate round (see the last section). Written against main `8a6281c` and the RD14 branch `feat/rd14-title-translation` at `a6e2254` (worktree `rd14-wt`), whose names this design uses. Author: Claude (planner, for the driver of this AFK run). External gate: Codex `gpt-6.1-sol` at high effort.

The owner's instruction for this phase (2026-11-12): one user, converge, no over-engineering. This issue adds one screen over data that already exists. It adds no table, no migration, no new kind of record and no change to the translator.

## Spec review

**What the baseline says.**

- N11: "Settings › Usage shows request and token counts per model and purpose for today / 7 days / 30 days. Nothing is converted to money; when a price is unknown no bill is invented." "Each partition has a daily limit on automatic calls (200 requests by default). Once reached, titles are no longer translated automatically and overviews are no longer generated automatically that day, and the interface says why." "Every attempt is recorded as its own request with its outcome, so the repeats are visible in Usage." Records "live in the database of the partition they belong to"; purposes are "titles / body / page / overview / test"; token counts are "blank when not returned".
- Spec section 4: "Partition settings — the daily automatic limit, list thumbnails — are stored in that partition's database (`setting`) and exported with the partition."
- ux S8: the Usage row holds "Requests and tokens per model and purpose; the daily automatic limit". ux S10 (adult settings) also lists "the daily automatic limit".
- Issue #138: "for the current partition"; "Token counts the service did not return are shown as unknown, not as zero"; acceptance: counts match the records per period with boundaries on the local day; requests without token counts are counted and shown with unknown tokens; changing the limit takes effect at once, including lowering it below today's count; while the adult partition is locked, no adult usage is visible. Out of scope: prices, budgets, alerts.

**What the code does today** (RD14 branch).

- `usage` (migration `v5`, index `usage_at`; `v6` added `automatic INTEGER NOT NULL DEFAULT 0`) is written by `LibraryModels.chat` for every sent request — Test included, cancelled and failed included — in the library of the `LibraryModels` that sent it. `UsagePurpose` is the closed set `titles`, `body`, `page`, `overview`, `test`; tokens are null when not returned.
- The limit is a partition setting as section 4 says: `setting` key `daily_automatic_limit` in each library (`Library.dailyAutomaticLimit()`, 200 when absent or not a non-negative whole number; `setDailyAutomaticLimit(_:)` clamps to 0 or more). `Library.automaticRequestCount(since:)` (internal) counts `automatic = 1` rows.
- A changed limit already takes effect at once, in both directions. `TitleTranslator.attempt` reads the count and the limit before every automatic request, so a lowered limit stops the next one. After a raise, rows ask again by themselves: `ArticleListView` calls `TranslationModel.rowAppeared` in each row's `.onAppear`, which asks for any row without a stored translation, and a row blocked by the limit has none. Settings replaces the list in both layouts (`NavigationModel`: "Settings | Settings tab | sidebar: Settings"), so while Usage is open no row is on screen, and the list's rows appear — and ask — again when the list is shown after it. The pass over each category's newest 50 runs at the next refresh end or return to the front, as RD14 decided.
- Each `Workspace` (RD18) is built on one library. Its `ModelSettingsModel` is built on the *normal* library's `LibraryModels` in both workspaces (ux S8: Models & Translation is the normal partition's). The adult workspace has no `TranslationModel` and its library no `LibraryModels` until RD19, so adult usage is always empty today. The adult workspace exists only while unlocked; locking stops it and clears its navigation.
- Settings has no Usage row; `DataSettingsView` is the pattern of a screen reading the current workspace's library.

**Gaps, each with its decision.**

| Gap | Decision |
| --- | --- |
| Whose usage the screen shows | The library of the workspace on screen, never another (decision 1) |
| What "7 days" and "30 days" are | Local days: today plus the 6 / 29 days before (decision 2) |
| How unknown tokens are counted and shown | Counted as requests; token sums add only what was reported; the number of requests without counts is shown (decision 3) |
| How the limit is edited, and which values | An inline picker of fixed values, plus the stored value when it is not one of them (decision 5) |
| Whether a changed limit needs anything to restart translation | No: the limit is read before every request and rows ask again when shown (decision 6; assumption A4) |
| ux S10 also shows the adult limit, from a workspace that may not hold the adult library | Left to RD19 with S10's other adult-library rows; RD17's screen edits the adult limit while the adult workspace is shown (decision 7) |
| A migration | None: the columns, the index and the setting exist |

## Acceptance criteria

| # | Criterion | Evidence |
| --- | --- | --- |
| 1 | For each period, the totals per model and purpose equal a count over the inserted rows; a row at exactly the period's start is included and one a millisecond before is not; boundaries follow the injected calendar's local midnight, also across a daylight-saving change | Package (injected clock and calendar) |
| 2 | A request with a null input or output count is counted as a request, adds only its reported count to the sums, and is counted in "tokens unknown"; a group whose requests all lack counts shows "Tokens unknown" and no sums | Package; UI |
| 3 | Rows of all five purposes, failed and cancelled ones included, are totalled; two rows with input `Int.max` total to `Int.max` without trapping | Package |
| 4 | The screen shows, per period, the seeded rows' models, purposes, request counts, token sums and unknown counts; a purpose with no request in the period has no row; the empty period says so | UI (seeded rows) |
| 5 | The limit section shows the stored limit selected — an off-list stored value as its own row — and "Automatic requests today: n of limit"; choosing a value stores it at once and survives leaving and reopening the screen | UI |
| 6 | The value chosen on the screen is the one the next automatic request reads: launched with a stored limit of 0, the feed's rows show the daily-limit mark and no request is sent; after 200 is chosen on the screen, the rows, asked for again when the list is shown, are sent and translated without a pull or any other trigger | UI with the translator fixture (iPhone tab structure and iPad panes) |
| 7 | Partitions: in the adult workspace the screen shows only the adult library's rows and limit, in the normal workspace only the normal library's; locking while the adult Usage shows the adult rows leaves no adult row anywhere, at once and after the normal Usage is opened; a limit chosen in one partition does not change the other's | UI (seeded rows per partition); package (two libraries of one store) |
| 8 | Planted failure: building the screen's model on the normal library in the adult workspace makes criterion 7's UI test fail | UI, run once with the plant and recorded in the pull request |
| 9 | A read failure shows "Usage could not be read." and no picker; a write failure shows "The change could not be saved." and the stored value again | Package for the queries; reading for the view |
| 10 | The three checks pass; every new string has a Simplified Chinese translation | CI |
| 11 | Largest text size, dark appearance, Simplified Chinese: the screen with rows and the limit section, uncut, on iPhone and iPad | Screenshots |

## Frozen issue contract

In scope: `UsagePeriod`, `UsageTotal` and `Library.usageTotals(since:)`; `automaticRequestCount(since:)` made public; `UsageModel`, `UsageView`, the Settings row and route; the workspace wiring; the debug seeding option; strings; the tests above.

Out of scope: prices, budgets, alerts, charts, cost estimates (issue, owner's steer); an outcome or automatic/manual breakdown; deleting or exporting usage rows; any change to the translator or a new resume trigger; 0 among the picker's fixed values (owner's question 1); the adult library's models and S10's rows, the adult limit in S10 included (RD19); the configuration file's `daily_auto_limit` (RD20); an "Open Settings" action on the daily-limit alert.

Other issues own: RD15, RD16 and RD23 write rows with purposes `body`, `page`, `overview` through `LibraryModels.send` — the screen shows them with no change; RD23 checks the same count and limit; RD19 gives the adult library its `LibraryModels`, after which adult rows appear in the adult workspace's Usage with no change here.

Invariants:

- The screen's model reads and writes exactly the library of its workspace; it is never given `WorkspaceParts.models` or another library.
- Nothing is converted to money; no number is invented for a token count the service did not return.
- The daily limit is stored only in the `setting` table of its partition's library.

## Assumptions

| Assumption | How it is measured first | If it does not hold |
| --- | --- | --- |
| A1. `at >= ?` with a `Date` argument compares in the stored text format (RD14's count already relies on it) | Criterion 1's boundary test, before the view is built | Bind the start through the same `DatabaseValue` encoding explicitly and report it |
| A2. The segmented period picker's three labels fit at the largest text size on iPhone in both languages | A screenshot at the largest size before the UI tests are written | An inline picker of three rows, as Settings › Refresh |
| A3. An inline `Picker` whose options are the fixed values plus an off-list stored value shows the stored value selected | Criterion 6's launch with a stored 0 | Report; show the stored value as a text row above the picker instead |
| A4. A list's rows run `.onAppear` again, and so ask again, when the list is shown after Settings: on iPhone on returning to the Library tab, on iPad on re-selecting the list in the sidebar | Criterion 6's UI step, run with no trigger of any kind | The implementer stops that part and reports to the driver; no trigger is built as a fallback in this issue |

## Approach

1. **The current workspace's library.** `UsageModel` (`@MainActor @Observable`, app) is made in `Workspace.init` from the `library` the workspace is built on, the workspace's clock and `Calendar.current`, and is injected into the environment by `RootView` with the workspace's other models. In the normal workspace the screen shows the normal library; in the adult workspace, which exists only while unlocked, the adult library. Locking stops the adult workspace (`Workspace.stop()` calls `usage.stop()`: no read or write starts afterwards and a result that arrives is dropped) and RD18 clears its navigation, so no adult number outlives the unlock. A Test run from Models & Translation in either workspace is recorded in the normal library, the slot's own (RD13), and so appears in the normal Usage.

2. **Periods** (package, pure): `UsagePeriod` `today`, `sevenDays`, `thirtyDays`, with `start(now:calendar:)` = `calendar.startOfDay(for: now)` moved back 0, 6 or 29 days with `calendar.date(byAdding: .day, …)`. A period has no upper bound: a row stamped later than now (a clock set back) is included, as RD14's count includes it.

3. **Totals** (package): `Library.usageTotals(since:) -> [UsageTotal]`, one query over the `usage_at` index:

   ```sql
   SELECT model, purpose, COUNT(*) AS requests,
          TOTAL(input_tokens) AS input, TOTAL(output_tokens) AS output,
          SUM(input_tokens IS NULL OR output_tokens IS NULL) AS unknown
   FROM usage WHERE at >= ? GROUP BY model, purpose
   ```

   `UsageTotal` holds `model: String`, `purpose: UsagePurpose`, `requests: Int`, `inputTokens: Int`, `outputTokens: Int`, `requestsWithoutTokens: Int`. `TOTAL` is a real number, so a service that reports huge counts cannot make the query fail; it is converted to `Int` saturating at `Int.max`. A `purpose` outside `UsagePurpose` is skipped (it cannot occur: a new case needs a migration and an older app refuses a newer schema). Every request counts, whatever its outcome or `automatic` flag. `automaticRequestCount(since:)` becomes public; "today's automatic requests" is that count since `UsagePeriod.today`'s start, the translator's own rule.

4. **The screen** (`UsageView`, Settings › Usage, row after Data as in ux S8, icon `chart.bar`).
   - Section 1: a segmented picker Today / 7 Days / 30 Days (default Today, not remembered). Then one section per model, ordered by its total requests (most first), then by name; the header is the model name, drawn with `Text(verbatim:)`. Within it one row per purpose with at least one request, in `UsagePurpose` order: the purpose's name; "n requests" (plural); "n input tokens · n output tokens" unless every request of the row lacks counts, then "Tokens unknown"; and, when only some lack them, "Tokens unknown for n requests". Numbers use the locale's grouping. With no row in the period: "No model requests in this period."
   - Footer of the last usage section: "Days begin at midnight on this device. Tokens are counted as each service reported them."
   - Purpose names: `titles` "Titles and Summaries" / 标题和摘要; `body` "Article Text" / 正文; `page` "Web Pages" / 网页; `overview` "Overviews" / 概览; `test` "Model Tests" / 模型测试. All five exist now, so RD15, RD16 and RD23 need no change to the screen.
   - The model reads totals, limit and today's count when the screen appears, when the period changes and after a limit is stored. It does not follow new requests while it stays on screen.

5. **The limit** (same screen, section "Daily Automatic Limit"). An inline picker (rows, as Settings › Refresh) of 50, 100, 200, 500, 1,000 and 2,000, plus the stored value as its own row, in order, when it is none of these (a stored 0 or 300 from the debug launch option now, an imported file after RD20). Above it: "Automatic requests today: n of m", and, when n ≥ m, "Today's automatic limit is reached". Footer: "When today's automatic requests reach this number, nothing more is sent automatically until tomorrow. Translations you start yourself are not limited." Choosing a value writes it at once with `setDailyAutomaticLimit`; the picker is disabled while one write runs, so writes are applied in the order chosen. After a successful write the model re-reads the limit and today's count.

6. **The limit takes effect at once without a trigger.** The translator reads the limit before every automatic request: after a lower value, the next automatic request is refused (one already in flight completes and is recorded); after a higher one, the rows ask again when the list is shown after Settings (spec review; assumption A4) and are sent under the new value. Nothing is added to `TitleTranslator`, `TranslationTrigger` or `TranslationModel`, and `UsageModel` has no callback into translation.

7. **The adult limit.** It is edited on this screen inside the adult partition, which is the only place its library is open. ux S10's copy of it, which can be opened from the locked normal partition, is RD19's, together with S10's model slots, which have the same need.

8. **Seeding for the UI tests** (debug builds only). Launch key `NEWSPAW_UITEST_SEED_USAGE` = "1", honoured only with a UI-test library directory. `Library.insertUsageForUITests(calendar:)` (package, `#if DEBUG`, beside `insertSyntheticSourcesForUITests`) inserts, unless a row of that model exists already, five rows of model `seed-<partition>`: now, `titles`, 100 / 20 tokens, automatic, `ok`; now, `titles`, no tokens, automatic, `unreachable`; noon 3 days ago, `body`, 300 / 50, manual; noon 20 days ago, `page`, 1,000 / 200, manual; noon 40 days ago, `overview`, 5,000 / 500, manual. `AppModel` runs it on the normal library at start and on the adult library in `chooseAdult` before the workspace loads. Without the adult rows, criterion 7's "no adult usage while locked" would pass with nothing to hide.

## Files to change

Package (`ios/NewsPawKit`):

- `Sources/NewsPawKit/Store/Library+Usage.swift` (new): `UsagePeriod`, `UsageTotal`, `usageTotals(since:)`, the debug seeding.
- `Sources/NewsPawKit/Translation/Library+Translation.swift`: `automaticRequestCount(since:)` public.
- `Tests/NewsPawKitTests/Store/UsageTotalsTests.swift` (new).

App (`ios/NewsPaw`):

- `AppState/UsageModel.swift`, `Settings/UsageView.swift` (new).
- `AppState/Workspace.swift` (the model and `stop()`); `Navigation/RootView.swift` (environment); `AppState/NavigationModel.swift` (`SettingsRoute.usage` and any switch over the routes); `Destinations/SettingsView.swift` (row and destination).
- `AppState/DebugLaunchOptions.swift`, `UITestIdentifiers.swift`, `AppState/AppModel.swift` (seeding; identifiers of the row, the period picker, the limit picker, the today line).
- `Localizable.xcstrings`.
- `Settings/AdultPartitionView.swift`: its comment's "RD19 and RD14" for the daily limit becomes "RD19".
- `NewsPawUITests/UsageTests.swift` (new).

No change to `Schema.swift`, the translator, the project's dependencies or either `Package.resolved`.

## Execution surface

Package tests (`swift test --package-path ios/NewsPawKit`), the simulator build and the strings check of `AGENTS.md`, and the UI tests on the three simulators (`-only-testing:NewsPawUITests/UsageTests` while iterating, plus `TranslationTests` and `TranslationPartitionTests` once at the final commit). No real model service, no network: model requests in the UI tests go to the debug fixture. Nothing is uploaded or deployed.

## Failure handling

| Failure | Behaviour |
| --- | --- |
| Totals, limit or today's count cannot be read | Both sections show "Usage could not be read." and no picker; the next appearance or period change tries again |
| The limit cannot be stored | "The change could not be saved." (the existing alert sentence); the stored value is read again and shown |
| The stored limit is not a non-negative whole number | Shown and used as 200 (RD14); choosing a value replaces it |
| The workspace is dropped while the screen is open or a read is running | `stop()`: the result is dropped, nothing new starts; RD18 clears the navigation |
| The limit is lowered while an automatic request is in flight | That request completes and is recorded; the next is refused |
| A service reported token counts near `Int.max` | Sums saturate at `Int.max` |

## Risk assessment

Low. The screen reads; its one write goes through RD14's existing setter, and the translator is not touched. The partition risk is the wiring — building the model on `WorkspaceParts.models.library`, the object `ModelSettingsModel` is rightly built on — and criteria 7 and 8 guard it. The raise path rests on rows asking again when shown (A4), measured by criterion 6. Usage rows are never deleted (RD13), so the 30-day query reads a growing table through its index; at a few hundred rows a day that stays small.

## Test plan

Package:

- `UsagePeriod.start` in two time zones (Asia/Shanghai, America/New_York) at a few instants, including the day after a daylight-saving change, against hand-computed instants.
- `usageTotals` over a fixed set of rows: per period, boundary rows (exactly at the start, one millisecond before), all five purposes, failed and cancelled outcomes, null input only, null output only, both null, `Int.max` twice; `automaticRequestCount` agrees with the `automatic` rows of today.
- Two libraries of one `LibraryStore`: rows and a limit written in the adult library are absent from the normal library's totals and limit, and the other way round.

No new translator test: lowering is RD14's (`TitleTranslatorTests`, `TranslationTests`).

UI (`UsageTests`, iPhone and one iPad):

- Seeded periods and partitions (criteria 4, 5, 7): launch with seeding and the authenticator answers. Normal Usage, Today: `seed-normal`, Titles and Summaries 2 requests, 100 / 20, unknown for 1 request, no other purpose, "2 of 200"; 7 Days adds Article Text; 30 Days adds Web Pages; Overviews never. Choose 500, leave and reopen: 500. Turn the adult partition on and enter it: Usage shows `seed-adult`, not `seed-normal`, and 200 selected; choose 50. With the adult Usage open and `seed-adult` showing, lock: at once `seed-adult` exists nowhere in the app; open the normal Usage: `seed-normal` only, and 500.
- The chosen limit is read (criteria 5, 6; A3, A4): launch with the translator fixture's primary and the debug limit 0; add the translation feed; its rows show the daily-limit mark and the fixture's request count stays 0. Usage shows a row "0" selected, "0 of 0" and the reached line; choose 200; show the list again (Library tab on iPhone, the list in the sidebar on iPad): its rows are translated without a pull. No trigger exists to help it.
- Planted failure (criterion 8): build `UsageModel` on `parts.models.library`; the seeded partition test fails at the adult step; the plant is reverted and the run recorded in the pull request.
- Screenshots (criterion 11).

Device checks owed: none specific; the screen is read on the owner's device with real rows during RD22.

## Handoff notes

- RD15, RD16, RD23: record with purposes `body`, `page`, `overview`; nothing else to do for Usage. RD23's automatic overviews pass `automatic: true` and are limited by the same setting; the footer's wording already covers them.
- RD19: once the adult library has its `LibraryModels` and `TranslationModel`, the adult workspace's Usage shows its rows with no change here. S10's daily-limit row (and its models) need the adult library from the normal workspace while locked; it writes the same `setting` key `daily_automatic_limit` through `setDailyAutomaticLimit`.
- RD20: the configuration file names the setting `daily_auto_limit` (spec section 5); the library's key is `daily_automatic_limit`. Usage rows are not exported (N10). An imported limit that is not one of the picker's values is shown as its own row.

## For the owner

1. **A question, with "no" as the default.** Should 0 — no automatic translation in this partition — be offered? Built without it: the limit is chosen from 50, 100, 200 (default), 500, 1,000 and 2,000, and turning translation off stays with the global switch and each source's setting. At 0, every waiting row of the partition would carry the "limit reached" warning all day. A value that came from elsewhere (a file imported later) is shown too.
2. Usage shows the partition you are in: the adult partition's own requests and limit inside it (empty until its models arrive with RD19), the normal one's outside it. A model Test is counted in the partition the model belongs to.
3. Counts are per model name: the same model name used through two services is counted together.
4. Every request is counted, including failed, cancelled and retried ones; the screen does not split them by outcome or into automatic and manual (only today's automatic count is shown, beside the limit).
5. A request whose service did not report both token counts is shown as "tokens unknown"; the token totals add only what the services reported.
6. "7 days" is today and the six days before, from local midnight; "30 days" likewise.
7. No money, no chart, no estimate. The numbers update when the screen is opened or the period changed, not while you watch.
8. After you raise the limit, rows are translated as you look at them again; the batch of each category's newest 50 waits for the next refresh or the next time the app comes to the front.
9. The daily-limit message on a row keeps only Retry; it has no button that opens this screen.
10. Usage records are never deleted; the screen looks back 30 days.

## Revision record

Version 1, 2026-11-16: first draft.

Version 1 → 2, 2026-11-16: one debate round with an independent critic (verdict sound with fixes; 4 findings, 1 P2 and 3 minor), triaged by the driver; all admitted. F1's evidence was checked against `a6e2254` before cutting (`ArticleListView` `.onAppear` → `TranslationModel.rowAppeared`; `NavigationModel`'s layout table; `TitleTranslator.attempt`).

| Finding | Disposition |
| --- | --- |
| F1 (P2) `dailyLimitChanged` rested on a wrong reading: rows ask again when shown, and no row is on screen while Usage is open | Admitted: trigger, `TranslationModel.dailyLimitChanged()`, `onLimitChanged` and the translator test removed; spec review corrected; decision 6 rewritten; A4 added with no fallback trigger |
| F2 (minor) 0 in the fixed values was not asked for and leaves every row warned | Admitted: values 50–2,000; a stored 0 shows as the off-list row; "choose 0 again" dropped; owner's question 1, default no |
| F3 (minor) the lock step could not fail | Admitted: lock with the adult Usage showing `seed-adult`; assert it nowhere at once and after opening the normal Usage; seeding kept |
| F4 (minor) criterion 6 re-tested RD14 | Admitted: criterion 6 is "the value chosen on the screen is the one the next automatic request reads"; the new translator package test dropped |
