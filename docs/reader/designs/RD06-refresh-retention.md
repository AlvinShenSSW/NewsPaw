# RD06 — Refresh, retention and the image cache

Issue: [#127](https://github.com/AlvinShenSSW/NewsPaw/issues/127) · Epic E12 #115 · Requirements N04 (foreground refresh, retention, storage, no badge); ux S1 (status line), S2 (Refresh in the long-press menus), S8 (Refresh). Also touched: N02 (partitions), N13 (offline tests).
Design version 2, 2026-11-13, frozen after one debate round (see the last section). Author: Claude (planner, for the driver of this AFK run). Implementer: Claude Opus 5.5. External gate: Codex `gpt-6.1-sol` at high effort.

Builds on the merged code of RD02 (libraries, migrations), RD04 (`FeedCollector`, `Library.storeCollection`, `insertArticles`) and RD05 (`SourceModel`, `SourceSummary`, `FixtureTransport`, the single sheet state). Names below are the merged ones as read at main `ad6640e`.

The owner's instruction for this phase (2026-11-12): one user, converge, no over-engineering. Where this design chooses the smaller of two mechanisms, that is why.

## Spec review

After RD05 a source is collected twice in its life: when it is added, and when the owner presses "Update Now" in its settings. Nothing refreshes the library by itself, nothing ever deletes an article, and the `seen` table is written by nobody.

Core need: when the owner opens the app the library is fresh without being asked, old articles go away on the schedule the owner chose and do not come back, and Today says truthfully when the library was last updated and whether anything failed.

**Settled here**, because the issue and the specification leave it open:

1. **One engine, one cap.** A library has one `Refresher`. At most **4** collections of that library are in flight at any moment, whatever started them (entry, pull, a category's or a source's Refresh, "Update Now"). A source that a run already holds is joined, not requested a second time. The cap is on collections; Add source's detection requests (RD05) are outside it.
2. **What a refresh collects.** Scopes: the whole library, one category, one source. In each, the sources of kind `feed` that are not paused, chosen by one query. Paused and web-page sources get no request; nothing else decides that.
3. **Entry.** "Entering the app" is the launch — called once the library is open, at the end of `AppModel.start()`, not from the first `active` scene phase, which arrives while the library is still opening — and every later change of the scene phase from `background` to `active` (a return from `inactive` alone, such as after Control Centre, is not an entry). On entry the app first cleans up (decision 7), then refreshes the whole library if a refresh is due. Two entries may overlap; joining makes that harmless.
4. **Due.** Never when the interval is "manual only". Otherwise due when the library has no recorded refresh time, when that time is at least the interval ago, or when it lies in the future (the clock was changed).
5. **The recorded refresh time** is the moment a whole-library run ended. It is recorded unless the run was cancelled, or attempted at least one source and every attempt failed. A run with no source to attempt counts. A category or source run records nothing. So a refresh made while offline is not "Updated just now", and the next entry tries again. The time is stored in the library's own database: a new `setting` table (spec section 4 already names it), key `last_refresh_at`. It is not a preference: a preference would put a trace of adult-partition activity outside the adult database. (Deriving it from the sources' success times was considered: the newest one makes a single "Update Now" look like a refresh of everything; the oldest one makes a permanently failing source turn every entry into a refresh.)
6. **Leaving the app during a run.** The app asks the system for background time while any run is in flight. In the expiry handler it cancels the engine — synchronously, which is why the engine lives on the main actor — and then ends the assertion; the later "last run ended" path must not end the same assertion a second time. A cancelled collection records nothing (RD04), so sources do not turn "failing" because the app was suspended in the middle of a request.
7. **Clean-up runs on entry, and only there.** Articles that are not starred and were first seen more than the retention period ago are deleted with their bodies; each leaves its identifier in `seen` with the clean-up's time. "Forever" deletes nothing. A retention change therefore takes effect at the next entry, not the moment the picker changes; the picker's footer says so.
8. **`seen` holds every identifier that must not be inserted, and a collection decides each listed item in this order:**
   1. Its identifier is an article of this source already: nothing to do.
   2. Its identifier is in `seen` for this source: the row's last-seen time becomes the collection's time; its link, if it has one, joins the batch's links; it is not inserted.
   3. Its link is one of the batch's links, or an article of the category holds it (RD04's same-link rule): it is not inserted, **and its identifier is put into `seen`** with the collection's time. Without this, the suppressed twin would be inserted as new on the first collection after clean-up removed the article that held the link — within one feed, and between two feeds of one category.
   4. Otherwise it is inserted, and its link joins the batch's links.

   After the items of a **complete** feed have been handled, the source's `seen` rows last seen more than 30 days ago are deleted, in the same transaction; refreshing before deleting means a feed that answered `304` for 40 days and still lists the item keeps its row. An incomplete feed refreshes the rows of the items it did list and deletes none. A `304` and a failure change no `seen` row. The hash is the lowercase hexadecimal SHA-256 of the external identifier's UTF-8 bytes. The 30 days are fixed and independent of the retention setting. A consequence, accepted: deleting a source does not release the twins its articles suppressed in other sources; they stay remembered until their feeds drop them.
9. **Preferences.** `refresh_minutes` (15, 30, 60; 0 means manual only; default 30) and `retention_days` (7, 30, 90; 0 means forever; default 30), in the system preferences store under the names the configuration file uses (spec section 5). A stored value outside the set reads as the default. Under a UI-test library directory the app uses a preferences suite named after that directory, never the standard one.
10. **The image cache belongs to its library.** `library.imageCache` is the only way to reach it. `LibraryStore` is given a cache root (default: `Images/` in the system caches directory; a temporary directory in package tests; inside the test's library directory under UI tests) and gives each library the directory `<root>/<partition>/`, so the two partitions' caches are separate directories and nothing takes a partition to choose one. Limit 500 MB, least recently used first. File names are hashes of the address. This issue delivers the cache and its tests; nothing fills it and no screen shows it yet (decision 14).
11. **Today's status line.** Shown when the library has at least one feed-like source. Exactly one of: "Updating…" while any collection is in flight; "Updated ⟨relative time⟩" from the recorded refresh time; "Not updated yet" when there is none. The relative time is computed against the same clock the library uses and is redrawn every minute, so it neither goes stale while the app stays open nor disagrees with a test's clock. Beside it, when feed-like sources that are not paused have a failing status, "N sources failed" — a count of stored statuses, so it always agrees with the rows — as a button that shows the category list with those sources' categories expanded: the Library tab's root in the tab structure, the sidebar pane from 1100 pt, the slide-over below it (the rule of RD05's "Show in Library").
12. **Where Refresh is offered.** Pull to refresh on Today and on the Library root list of the tab structure (whole library). "Refresh" in a category's long-press menu when the category has a source to collect, and in a source's menu when it is a feed and not paused. "Update Now" stays in Source settings and goes through the same engine. The sidebar has the menus but no pull.
13. **A source being collected shows it.** Its row shows a small activity indicator in place of the count or mark, with the VoiceOver value "Updating", from the start of the run that includes it until its own collection has ended. Without it a Refresh chosen from a menu in Library would show nothing. The lists are read again as each source's collection ends, so one stalled source does not hold back the others' new counts.
14. **Settings gets the row that works.** "Refresh": Interval and Retention. The background switch arrives with RD24. The "Data" row with the image cache's size and Clear arrives with RD09, the issue that first puts an image into the cache: until then the row could only read zero beside a disabled button.
15. **No badge.** A package test scans the Swift sources of the app and the package for `applicationIconBadgeNumber`, `setBadgeCount`, a `badge` assignment on notification content and `UNAuthorizationOptions.badge`, and fails when one appears — or when it finds no app source file to scan. In-app counts (`.badge(…)` on a tab or row) are not what it looks for.

## Acceptance criteria

1. **Targets and cap.** With a fake transport that logs requests and counts those in flight: a whole-library refresh requests every feed source that is not paused exactly once; paused and web-page sources get no request; never more than 4 are in flight, also with several hundred sources; with six sources of which one never answers and one fails, the other four have completed and stored their results while the stalled one is still in flight. A category refresh requests only that category's targets; a source refresh only that source; a paused source's refresh requests nothing.
2. **Joining.** A second refresh requested while a run holds the same source makes no second request for it and returns after that collection ends; with two overlapping runs the total in flight never exceeds 4.
3. **Due and the recorded time** (injected clock). The table of decision 4: nothing recorded → due; younger than the interval → not due; exactly the interval or older → due; manual → never; a recorded time in the future → due; each for 15, 30 and 60 minutes. A whole-library run records its end time; a category run and a source run record nothing; a run in which every attempted source failed records nothing; a cancelled run records nothing; a run with no source to attempt (an empty library; a library of paused and web-page sources only) records its time.
4. **Cancellation.** Cancelling the engine during a run leaves, for every source whose collection had not ended, its status columns, its articles and its `seen` rows exactly as they were; sources that had ended keep their results; the call returns; sources still waiting for a slot make no request. A refresh started after the cancellation collects normally.
5. **Retention** (injected clock). For 7, 30 and 90 days: an unstarred article first seen more than the period ago is deleted with its body; one first seen exactly the period ago, or later, stays; a starred article stays whatever its age; read or unread makes no difference; the published time plays no part (published years ago but first seen today stays; published yesterday but first seen 40 days ago goes at 30 days). "Forever" deletes nothing. Every deleted article leaves one `seen` row with the hash of its identifier and the clean-up's time. The clean-up is one transaction: with a trigger that aborts a `seen` insert, no article is deleted. It returns how many articles it deleted.
6. **Seen identifiers.**
   - After a clean-up, collecting a feed that still lists the item inserts nothing for it and sets its row's time to the collection's time; a new item of the same feed is inserted.
   - A collection of unchanged items adds no `seen` row for an article that exists (step 1 of decision 8).
   - **Same link, one feed.** A feed lists two items with one link. The first is stored, the second is not and has a `seen` row. After a clean-up removes the first, the next collection of the same feed inserts neither.
   - **Same link, two feeds of one category.** Source A holds the article; source B lists an item with the same link, which is not stored and has a `seen` row for B. After a clean-up removes A's article, B's next collection does not insert it. The same when B is added (RD05's path) while A holds the article.
   - A `304` and a failed collection change no `seen` row. An incomplete feed refreshes the rows of the items it listed and deletes none.
   - When a complete feed no longer lists the item and its row was last seen more than 30 days ago, that collection deletes the row; a row last seen 30 days ago or less stays. A feed that still lists the item after 40 days of `304` keeps the row and still does not insert the item.
   - Adding a feed source with no duplicate link behaves as before (RD05's tests pass unchanged).
7. **Migration.** `v3` creates `setting` (`key` primary key, `value`). A `v2` database with rows in every table migrates and keeps every row; `v1` and `v2` are not edited; the newer-schema refusal still holds. Reading and writing `last_refresh_at` round-trips a time.
8. **Preferences.** Defaults 30 minutes and 30 days; every value of both sets round-trips; a stored value outside the set reads as the default. UI test: change both pickers, relaunch, both are as chosen. UI test: with "Manual Only" and the counting fixture source (Test plan) at one unread, a relaunch with the clock a day ahead leaves it at one.
9. **Today's status line.** The three states and the failure count of decision 11, in English and Simplified Chinese; no line when the library has no feed-like source. UI test: a pull on Today with the slow fixture source shows "Updating…", which then gives way to an "Updated" line. UI test: with the sequenced source made to fail by a pull, "1 source failed" is shown; activating it shows the category list with that category expanded and the failing row — at the Library tab's root (iPhone), and in the sidebar pane or the slide-over (iPad).
10. **Entry, end to end** (UI tests, fixtures, the clock key and the counting fixture source of the Test plan). (a) Not due: add the counting source (one unread), relaunch at once — still one. (b) Due: relaunch with the clock a day ahead — two, without any action. (c) Clean-up and seen: add the fixture feed (three unread) and the counting source (one unread), relaunch with the clock 40 days ahead — after the entry the fixture feed's row has no count although its three items were collected again, and the counting source's row shows one: its old article was cleaned up and the entry refresh brought one new.
11. **Menus and the row.** A category's "Refresh" collects that category's targets only and is absent when it has none; a source's "Refresh" is absent for a paused and for a web-page source. UI test with the slow fixture source: after "Refresh" from the source's menu the row shows the activity indicator, then its count again.
12. **"Update Now"** behaves for the owner as in RD05 (its UI test passes unchanged) and makes no second request for a source a run already holds.
13. **Image cache** (package, temporary directories). Store then read returns the same bytes; a read makes the item the most recently used; when a store takes the total over the limit, least recently used items are removed until it is within the limit; an item larger than the limit is not stored and removes nothing; Clear leaves size zero; the size is the sum of the stored files' sizes and is zero for a directory that does not exist; every file in the directory is named by a hash, whatever the address; the two libraries of one store have different cache directories under the root the store was given, and storing in or clearing one changes nothing in the other; opening a library creates no cache directory.
14. **No badge.** The scan test of decision 15 passes, and fails when a line setting the application badge is added to an app source (shown once in the evidence).
15. **Leaving the app.** The app holds a background-time assertion while a run is in flight; its expiry handler cancels the engine and ends the assertion, which is never ended twice. Verified by reading the code and by criterion 4; it is not automated and is on the owner's device list.
16. **Structure and regression.** Every new string is in the catalog with Simplified Chinese and the strings check passes. New icon-only controls have labels; new controls measure at least 44 × 44 pt; at the largest text size the status line and the Settings rows wrap and nothing is clipped. Every RD03 and RD05 UI test still passes. No test reaches a real host. The debug key is inside `#if DEBUG` and absent from the Release binary.
17. **Evidence.** Package tests; UI tests on the three simulators; screenshots of Today with each status-line state and the failure count, and of Settings → Refresh — one set each in light, dark, Simplified Chinese and the largest text size.

## Frozen issue contract

**In.** The seventeen criteria.

**Invariants.**
- A collection still touches one source's articles, that source's `seen` rows and its four status columns, and nothing the owner can edit (RD04 criterion 14). Clean-up touches `article`, `article_body` (by cascade) and `seen`. Neither changes `updated_at` of anything.
- A starred article is never deleted by clean-up.
- Every function added to `Library` works on that library alone; nothing takes a `Partition`, a `LibraryStore` or a second `Library`. The image cache is reached only through its library. The recorded refresh time lives in the library's database. Preferences hold the two settings and nothing about a partition's content.
- The app makes requests only through its one transport; a refresh requests only the stored addresses of the library's own sources. Under a UI-test library directory the transport is the fixture transport.
- Migrations are append-only: `v1` and `v2` are not edited; this issue adds `v3` and no other.
- Nothing sets the application badge and nothing posts a notification.
- RD03's and RD05's invariants hold: storage only through `Library`'s public API; no `@testable import` in the app; system components for bars, lists and sheets; palette tokens only; one sheet state; debug seams inside `#if DEBUG`.
- No dependency is added or changed.

**Allowed user-visible change.** The status line on Today; pull to refresh on Today and on the Library root list; "Refresh" in the category and source menus; the activity indicator on a source row; the Settings row "Refresh" with its screen; the app now refreshes on entry and deletes articles past the retention period.

**For the owner.** Eight things here go beyond what ux.md, the specification or the issue say; the pull request repeats this paragraph. (1) "N sources failed" opens the category list with the failing sources' categories expanded, rather than a separate status screen — ux S1 says only "a link to their status". (2) A whole-library refresh in which every source failed does not count as a refresh: the line keeps its earlier time and the next entry tries again. (3) Articles past the retention period are removed when the app is opened, so a shorter retention takes effect at the next opening, not when the picker changes. (4) A source row shows an activity indicator while it is collected. (5) At most 4 sources are collected at once. (6) The issue puts the cache's size and its Clear action here; this issue delivers the cache itself, tested, and leaves the Settings row to RD09, which is the first to put an image into it. Settings likewise has no background switch until RD24. (7) A refresh still running when the app leaves the foreground continues for the short time the system allows and is then cancelled; the sources it had not reached keep their previous status. (8) An item dropped because another article of the category has the same link is remembered like a cleaned-up item, so it does not turn up as new later — the specification's `seen` table is described as holding cleaned-up items only.

**Non-goals.** Background refresh and its switch (RD24). Article lists, their pull to refresh, their toolbar's Refresh and "Mark all as read" (RD09). Fetching, validating or showing images, and the cache's row in Settings (RD09, RD11). A control for the cache limit. Shrinking the database file. Retry or back-off for failing sources; per-source intervals. Collecting GitHub or Hugging Face sources (RD07, RD26). Anything adult in the interface (RD18). Exporting the two settings (RD20). The date under Today's title and the overview cards (RD09, RD15). A status screen for failed sources. A link reissued under a new identifier by a second feed after the first feed's article was cleaned up (the remembered identifier carries no link).

**Causal boundary.**
- `ios/NewsPawKit/Sources/NewsPawKit/` — new: `Feeds/Refresher.swift`; `Store/Library+Refresh.swift` (targets, the recorded time, due); `Store/Library+Retention.swift`; `Cache/ImageCache.swift`; `Model/Preferences.swift` (the two value sets and the reader/writer over a `UserDefaults` handed to it). Changed: `Store/Library+Collection.swift` (decision 8 inside the existing transaction); `Store/Schema.swift` (`v3`); `Store/Library.swift` and `Store/LibraryStore.swift` (the cache root and `imageCache`); `Feeds/FixtureTransport.swift` (the counting address of the Test plan).
- `ios/NewsPawKit/Tests/NewsPawKitTests/**`.
- `ios/NewsPaw/**` and `ios/NewsPawUITests/**`.
- `docs/reader/spec.md` — N04, three sentences: clean-up runs when the app is entered; the time of the last whole-library refresh is kept in the partition's database (`setting`); an item dropped by the same-link rule is remembered in `seen` as a cleaned-up item is. `docs/reader/ux.md` — one sentence each: S1, what "N sources failed" opens; S2, a source being refreshed shows an activity indicator.

## Assumptions

| Assumption | Risk if wrong | Verified by |
| --- | --- | --- |
| The scene phase reports `background` before `active` on every return from the background | An entry is missed or doubled | The implementer logs the phases once in the simulator and says what was seen; a doubled entry is harmless (decision 3) |
| `.refreshable` on a scroll view inside RD03's pane and tab containers shows the system indicator and keeps it until the action returns | Pull to refresh needs another host view | Criterion 9's UI test on the three simulators |
| `UIApplication.beginBackgroundTask`'s expiry handler runs on the main thread, and ending the assertion there is in time | The app is terminated instead of suspended, or sources turn failing | Apple's documentation, read by the implementer; not automated (criterion 15) |
| A file's modification date, set on every read, orders the cache by recency with enough resolution | Least recently used is wrong | Criterion 13; if two dates tie in a test the implementer says so and sets the date explicitly |
| `CryptoKit` builds for the package on macOS and iOS under Xcode 26.6 | The hash needs another source | CI |
| `UserDefaults(suiteName:)` with a per-test name keeps values across a relaunch in the simulator | Criterion 8's relaunch test cannot pass | That test |
| Up to three point lookups and one single-row write per listed item are cheap enough for a feed of over a thousand items | A collection's transaction is slow | A package test stores a 1,500-item feed against 1,500 `seen` rows and records the time in the evidence (no threshold; a figure above one second is reported) |

Measured in the debate (critic's probe in the scratchpad, `rd06-critic`; a local pass proves that machine only): a slot gate that frees a slot and then wakes a waiter reached 5 in flight with a limit of 4 over 400 tasks, because a newcomer takes the freed slot before the woken waiter runs; a gate that hands the slot to the waiter stayed at 4. GRDB 7.12's asynchronous reads and writes throw `CancellationError` on a cancelled task, and `LibraryError.wrapping` passes it through.

## Approach

**Package: the engine.** `Refresher` is a main-actor, observable class made with a library, a transport and a limit (default 4). Its own state — the task held for each source, the slot count, the waiters, the set of sources in flight — is small; fetching and storing run off the main actor inside `FeedCollector` as they do now. `refresh(_ scope:)` reads the targets (decision 2), then for each either joins the task already held for that source or starts one that waits for a slot, collects, and passes its slot on. It returns each source's result: the collector's outcome, a storage error, or cancelled. For the whole-library scope it then records the time under decision 5. `cancelAll()` is synchronous: it cancels every held task and wakes the waiters, which then end without a request. **The slot gate hands a freed slot directly to the first waiter** (the count is not lowered and raised around the wake-up); the debate measured that the other form exceeds the cap. The in-flight set is observable, so rows and the status line read it directly.

**Package: the library.** `refreshTargets(_:)`; `lastRefreshAt()` and its writer over `setting`; `refreshIsDue(every:)` using the library's clock; `cleanUp(keeping:)`. `insertArticles` implements decision 8's four steps in feed order with prepared statements; `storeCollection` deletes the source's old `seen` rows after a complete feed. The hash function is one internal helper used by the clean-up and the collection.

**Package: preferences and the cache.** `RefreshInterval` and `Retention` are closed sets with the integer forms of decision 9. `Preferences` reads and writes them in the `UserDefaults` it is given. `ImageCache` is an actor over one directory with a limit: `data(for:)`, `store(_:for:)` (returns whether it stored), `size()`, `clear()`. It creates its directory on the first store. I/O errors make a read return nothing and a store return false; Clear removes what it can and the size then shows what is left.

**App.** A `RefreshModel` at app level beside `CategoryModel` and `SourceModel` owns the engine: `entered()` (clean-up, then the due check and the run), `refresh(_:)` for the pull and the menus, the recorded time for the status line, the background-time assertion, and reading the lists again as each source ends. It is given the same clock closure as the `LibraryStore`. `SourceModel.updateNow` calls it; `updating` becomes a view of the engine's in-flight set. A storage error in a refresh the owner started shows the existing "could not be saved" alert once; on entry it is silent and the next entry tries again. `NavigationModel` gets the settings route and the function that shows the category list (taken out of `closeSheetAndShowCategoryList`).

**Debug key** (in `DebugLaunchOptions`, UI tests only): a clock offset in days, added to the one clock closure handed to the store and the refresh model, which makes a refresh due and ages articles for criteria 8 and 10.

## Failure handling

| Failure | Behaviour |
| --- | --- |
| A source fails, is slow or never answers | Recorded on that source by RD04; the others proceed within the cap; RD04's 20-second limit ends a stalled one |
| The device is offline | Every source fails with its reason; nothing is recorded as a refresh; the next entry or pull tries again |
| A storage error while storing a collection | That source's result is an error; the run goes on; decision 5 counts it as a failure; alert only for a refresh the owner started |
| The targets cannot be read | The run ends with the error and records nothing; alert only for a refresh the owner started |
| The clean-up fails | Nothing is deleted (one transaction); silent; it runs again at the next entry; the due check and the run still follow |
| The recorded time cannot be written | The run is not recorded; the next entry refreshes again |
| The app is suspended during a run | Decision 6 |
| A source is deleted, paused or moved while its collection is in flight | RD04: nothing is written for a deleted source; a pause set meanwhile takes effect from the next run; a move changes nothing for the collection |
| A preference holds a value outside its set | The default is used; the picker shows the default |
| The cache directory cannot be written or listed | Reads return nothing, stores return false, the size reads zero |

## Risks

| Risk | Likelihood | Effect | Handling |
| --- | --- | --- | --- |
| The slot gate or the joined tasks leak a slot or never wake a waiter after cancellation | Medium | A refresh never ends | Criteria 1, 2 and 4 (several hundred sources; a refresh after a cancellation) under the suite's time limits |
| An entry refresh in existing UI tests changes what they see | Low | RD03 and RD05 tests fail | A fresh test library has no source at first launch, so its run records a time and later relaunches are not due; no existing test sends the app to the background; the clock key is the only way a test makes a refresh due |
| The first clean-up after the retention period deletes many rows at once | Low | A pause at entry | One transaction off the main actor; the lists are read again afterwards |
| Deleted rows do not shrink the database file | Certain | The file keeps its size | Accepted (RD04's note); a non-goal here |

## Test plan

- **Fixture.** `FixtureTransport` gains one fixed address, the counting feed: every request is answered with a feed of one item whose identifier and link are new for that request. A request therefore shows as one more unread article, also across relaunches — the sequenced address cannot show that, because its counter starts again in every process.
- **Engine (package, fake transport).** Criteria 1–4, with the clock injected through the store.
- **Retention and seen (package).** Criteria 5 and 6, each line; the trigger test; the 1,500-item timing.
- **Schema (package).** Criterion 7, with a `v2` database built by the `v1` and `v2` migrations and rows in every table.
- **Preferences (package).** Criterion 8's value tests over a throwaway suite.
- **Image cache (package).** Criterion 13 in temporary directories.
- **No badge (package).** Criterion 14.
- **UI tests (three simulators, fixtures only).** Criteria 8–12 and 16; RD03's and RD05's suites unchanged.
- **Screenshots.** Criterion 17, by the screenshot test.
- **Not verified here, for the owner's device list:** the app refreshes when it is opened after the interval on a device; a refresh interrupted by leaving the app leaves no source falsely failing; pull to refresh by hand.
- The `AGENTS.md` commands pass; one Release build, searched for the debug key.

## Handoff notes

Branch `feat/rd06-refresh` from `main`; the design is committed there by the driver as `docs/reader/designs/RD06-refresh-retention.md`. Commit locally; do not push. Read the merged RD04 and RD05 code first; if a role this design relies on is missing, stop and report rather than building a substitute.

For later issues, recorded now:
- RD09: article lists get `.refreshable` and a toolbar Refresh through `RefreshModel`; thumbnails are fetched through the app's transport and kept in `library.imageCache` (the loader, its size limits and what it accepts as an image are RD09's); **RD09 adds Settings → Data with the cache's size and Clear, and the UI test of Clear on a cache that holds something** (issue #127 listed them; decision 14 moved them); the status line becomes the first row of Today's list.
- RD07, RD26: their collectors plug into `Refresher` beside `FeedCollector`; `refreshTargets` then includes their kinds.
- RD18: the adult library gets its own `Refresher`, its own recorded time and its own cache directory without further work; the cache row in Settings must act on the current partition's cache only; deleting the adult partition also deletes its cache directory.
- RD20: exports `refresh_minutes` and `retention_days` from `Preferences` and decides how "manual only" and "forever" are written in the file (0 here); `last_refresh_at` in `setting` is state, not a setting, and is not exported.
- RD24: background refresh reuses `Refresher`; it must not run the clean-up while the adult library is locked.

## Revision record

- Version 1, 2026-11-13: first draft.
- Version 2, 2026-11-13: after debate round 1 (below). Frozen.

## Debate record

Round 1, 2026-11-13: one fresh critic, read-only, with a package-level probe (`rd06-critic` in the scratchpad). The driver confirmed the causal path of C1 and C2 by reading `insertArticles` and `FixtureTransport` before admitting them.

| # | Severity | Finding | Disposition |
| --- | --- | --- | --- |
| C1 | P1 | After clean-up, an item suppressed by the same-link rule is inserted as new — within one feed (version 1 kept a seen item's link out of the batch) and between two feeds of a category | Decision 8 rewritten as four ordered steps: a suppressed item is remembered in `seen`; a seen item's link joins the batch. Criterion 6 gains both sequences. The driver added step 1 (an existing article's item is left alone): without it the same-link query, which matches an article's own row, would put every stored item into `seen` |
| C2 | P1 | Criteria 8, 10(a) and 10(b) relied on the sequenced fixture address, whose counter restarts in every process: two could not fail and one could not pass | The counting fixture address; the criteria assert counts |
| C3 | P2 | Criterion 10(c) passed without the entry refresh running | It now also requires the counting source's new article |
| C4 | P2 | A free-then-wake slot gate exceeds the cap (measured: 5 of 4) | The gate hands the slot over; stated in Approach; criterion 1 runs several hundred sources |
| C5 | P2 | An actor engine cannot be cancelled synchronously from the expiry handler | The engine is a main-actor class; `cancelAll()` is synchronous; decision 6 and criterion 15 state the order and the single end; criterion 4 adds a refresh after cancellation |
| C6 | P2 | A fixed cache directory would put package tests in the developer's home and share one cache between UI tests | The store is given a cache root (decision 10) |
| C7 | P2 | The first `active` phase arrives before the library is open, so an entry keyed to it is lost at launch | Decision 3: the launch entry is called at the end of `start()` |
| C8 | P2 | "Updated …" went stale while the app stayed open and disagreed with a test's clock | Decision 11: the library's clock, redrawn every minute |
| C9 | minor | An incomplete feed: Approach and decision 8 disagreed | It refreshes what it lists and deletes nothing |
| C10 | minor | A run with no source to attempt was ambiguous | Decision 5 and criterion 3 |
| C11 | minor | `entered()` was skipped behind any run | No skipping; overlapping entries are harmless (decision 3) |
| C12 | minor | `last_refresh_at` would be exported with the partition's settings | RD20 handoff note |
| C13 | minor | The badge scan could pass by finding nothing | Decision 15 |
| C14 | minor | The `../` check could not fail; the cache-seeding key served one test of a row with no producer | The check is now "every file is named by a hash"; the key is gone and the cache's Settings row moved to RD09 (decision 14, "For the owner" 6) |
| C15 | minor | Lists reloaded only at a run's end; the cap's wording; criterion 9's "then Updated" was already true | Decisions 13 and 1; criterion 9 |

Checked by the critic and found sound: the `setting` table against its alternatives; refreshing `seen` rows before deleting old ones; retention's rules and its ordering with a concurrent collection; the existing UI tests under an entry refresh; joining through stored tasks under a cancelled pull; the partition separation of the new state. Not checked by anyone before implementation: the scene-phase order on a cold launch, `.refreshable` inside the containers, the preferences suite across a relaunch, and `URLSession` across suspension — each is an assumption above with its check.
