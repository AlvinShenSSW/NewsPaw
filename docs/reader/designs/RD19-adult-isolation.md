# RD19 — Adult partition isolation: models, browser data, images, moving a category

Issue: [#140](https://github.com/AlvinShenSSW/NewsPaw/issues/140) · Epic E15 #118 · Requirements N08 (partition isolation), N09 (browser data, thumbnails), N02 (moving a category), N04 (image cache); spec section 4 (partition settings, the operations that touch both libraries), section 6 (both isolation points); ux S10, S13. Also touched: N06 (no borrowing of models), N11 (usage per partition), N12, N13.
Version 2 (2026-11-16), after two debate rounds. Written against `main` at `8a6281c` (RD18, RD10, RD11, RD13 merged), the RD14 worktree `rd14-wt` at `a6e2254` and the RD12 worktree `rd12-wt` at `450399a` (both not merged), and the draft designs of RD15, RD16, RD17, RD20 and RD21. Author: Claude (planner, for the driver of this AFK run). External gate: Codex `gpt-6.1-sol` at high effort (AGENTS.md; the issue text still names Kimi K3.1 Pro, which AGENTS.md replaced on 2026-11-12).

**Order.** RD19 is implemented after RD14 merges. Preferred order: RD14 → RD19 → RD15 / RD16 / RD17. It must build before or after each of RD15, RD16, RD17 (decision 13).

The owner's instruction for this phase (2026-11-12): one user, converge, no over-engineering.

## Spec review

### What the baseline says

- N08: "text from the normal partition goes only to normal slots, text from the adult partition only to adult slots. A partition with no model has no translation and no overview; it does not borrow the other partition's model. Entering the same service and key in both partitions is allowed."
- N09: "The embedded browser in the adult partition uses its own website data (cookies and cache separate from the normal partition), with a 'Clear adult-partition browsing data' action." "List thumbnails can be turned off in Settings." "Adult-partition content never enters notifications, widgets, Spotlight or Handoff. Sharing is started by the owner and is not restricted."
- N02: "A category can be moved to the other partition after confirmation. Only the category and its sources move. Its articles, translations and overviews in the old partition are deleted, then collected again in the new partition and translated by that partition's model. Read and starred states are lost, and the confirmation says so. A source whose address already exists in the destination partition is not moved, and the confirmation lists it. Moving a category needs the adult partition unlocked."
- N04: "The image cache is also separate per partition." Section 4: list thumbnails and the daily automatic limit are partition settings in the partition's `setting` table; moving a category, exporting with the adult partition and importing one each "requires the adult partition to be unlocked before the adult library is read or written".
- Section 6: the interface holds one library; "While locked, the interface layer cannot obtain the adult library"; "the translation and overview orchestration can only use the slots of the library an article lives in. There is no default slot."
- ux S10 (once on): "the adult partition's primary and backup model slots (same form as S9); lock timing; show thumbnails in lists; the daily automatic limit; Clear browsing data; Turn off". ux S13: "move to the other partition (with the consequences spelled out, N02)".
- Issue #140's acceptance: no request for an adult article without an adult slot even with working normal slots; an adult request goes to the adult slot's address with the adult key and never appears in the normal usage records; a cookie set in one browser is absent from the other, and Clear removes the adult one only; a move leaves no article, translation or cached image of it in the old partition's files; the same service and key in both partitions stays two keychain entries.
- RD18 (frozen, post-implementation): the adult partition is unlocked exactly while it is shown; "Code outside the package obtains the adult library only from `AdultGate.unlock()`"; "While the gate is off, locked or unavailable, the interface holds no adult library and no model built on one"; every lock closes the adult library and its image cache; decision 10: Settings › Adult Partition opened from the normal partition "never unlocks the partition".

### The audit: what `main` does today, what is missing, the smallest change

| Isolation point | On `main` (`8a6281c`), and the file that does it | Missing | Closed by |
| --- | --- | --- | --- |
| Model slots and keys | `AI/LibraryModels.swift`: one object per library, `precondition(keys.partition == library.partition)`, no default slot. `Privacy/KeychainKeyStore.swift`: service `io.newspaw.reader.model-key.<partition>`. `AppModel.start()` makes one `LibraryModels`, the normal library's, in `WorkspaceParts.models`; every workspace's Settings › Models & Translation uses it (right for ux S8). The adult `KeychainKeyStore` lives only in `AdultGate`, for Delete | The adult library has no `LibraryModels` and no slot screen; RD14 (branch) builds a translator only under `parts.models.belong(to: library)`, so the adult workspace has none | Decisions 1, 2 |
| Model context | No caller but Test on `main`. RD14: `TitleTranslator` is made from one `LibraryModels` and works on its library only; one fixed prompt for both partitions; requests are independent. One `URLSessionModelHTTP` (ephemeral) | Nothing translates adult text; once it does, it would share the normal HTTP session | Decisions 1, 3 |
| Browser data and cookies | `AppModel.start()`: normal `WKWebsiteDataStore.default()`; `makeAdultBrowser` a new `.nonPersistent()` per unlock; UI tests non-persistent for both. `BrowserConfiguration.make` and `BrowserModel` take what they are handed. RD12: each extraction its own non-persistent store | The adult partition's own persistent store; Clear; removing it at Delete (RD18's handoff) | Decisions 4, 5 |
| Thumbnails and the image cache | `LibraryStore.cacheDirectory(for:)`: `<root>/<partition>/`; `Library.imageCache` the only way in; `ReadingModel`'s two loaders on its library's cache; every lock closes the adult cache; Delete removes its directory last; Settings › Data acts on the shown library's cache; RD12's reader mode never stores | No thumbnails switch; a store whose fetch began before a clear lands after it | Decisions 6, 7 |
| Snapshots and the app-switcher cover | `Navigation/CoverWindow.swift`, `CoverRule` (`Privacy/LockTiming.swift`), `AppModel`'s scene observers | Nothing. Every move confirmation is shown inside the adult partition (decision 9), under RD18's cover | — |
| Pasteboard and share | `UIPasteboard.general.string =` in `ArticleListView.swift`, `BrowserView.swift`, `SourceSettingsView.swift`; `ShareLink` in the list menu, the reading screen and the browser | Nothing: RD18 decision 14 lists "the pasteboard, only through the owner's own Copy actions" as allowed, and N09 leaves sharing unrestricted. For the owner 12 | — |
| Logs | No logging in the app or the package; `KeyLeakTests` scans `AI/` and `Privacy/` only | A scan over everything else, guarding RD18's "the app writes no log" | Decision 8 |
| Storage outside the libraries | `Preferences` (no content); the feed and model sessions (ephemeral, no cookie store, no URL cache); the keychain's per-partition services; `AdultScanTests` (no notification, widget, Spotlight, Handoff, state restoration). No `AsyncImage`, `URLCache.shared` or `URLSession.shared` anywhere | Nothing. This issue's two partition settings live in each library's `setting` | — |
| Database files | RD02: `ATTACH` impossible; one library per workspace; the adult library only through `AdultGate.unlock()` | The move is the first operation that writes both | Decisions 9–11 |

### Gaps in the baseline, and the decision taken

1. **Where the adult slots are edited.** ux S10 draws them on a screen that RD18 lets the owner open from the normal partition, with the promise to the owner (RD18 decision 10, For the owner 2) that opening it never unlocks the partition. With that promise kept, the adult library is closed there and its rows cannot be shown. **Decision:** S10's rows that live in the adult library (slots, thumbnails, the daily limit) are shown only when S10 is opened inside the adult partition; opened from the normal partition it shows lock timing, Clear Browsing Data and Turn Off and one sentence saying where the rest is. RD17 decision 7 does the same for the limit. The alternative — opening S10 from the normal partition unlocks and switches — is put to the owner (For the owner 1).
2. **Moving from the normal partition.** S13 shows only the current partition's categories, so a normal → adult move starts in the normal partition, while N02 and section 4 need the adult partition unlocked, which under RD18 means shown. **Decision:** the move unlocks and switches first, carrying the request across (decision 9); both directions then run inside the adult partition through one code path. RD20's import uses the same hand-over.
3. **A move with sources that stay behind.** **Decision:** the category stays in the old partition holding exactly those sources; a category with the same identifier, name and icon is created in the destination for the moved ones. When none stays, the category leaves.
4. **A move that fails half-way.** Two files share no transaction. **Decision:** copy first, delete second; a failure leaves nothing changed or a copy in both, never a loss, and moving again finishes.
5. **When moved sources are collected again.** **Decision:** a destination on screen (normal → adult) refreshes the new category at once; a destination not on screen (adult → normal) has its recorded refresh time removed, so the next entry refreshes it (RD06's rule; with Manual Only, the next manual refresh).
6. **"No … cached image of it in the old partition's files."** Body images are cached by addresses found only by converting each article. **Decision:** the move clears the old partition's whole image cache, after the interface has let go of the moved articles (decision 11).
7. **"No article, translation … in the old partition's files"** is read as the partition's storage: no row of the moved sources, articles, bodies, seen identifiers or translations in the old library, and no cached image in the old cache. Byte-level erasure of the database file is not built (For the owner 8).
8. **Thumbnails are a partition setting of both libraries** (sections 4, 5) but ux draws the switch only in S10. **Decision:** read from each library (`list_thumbnails`, absent = on) so a normal value imported by RD20 is honoured; only S10 has a control.
9. **The issue says moving and import are "the only operations that touch both libraries"**; section 4 names three (export too). The specification is followed.
10. **The image-cache size limit** (section 4, device setting) has no control in any issue (RD06, RD21). Not this issue's.
11. **The issue names Kimi K3.1 Pro as the gate**; AGENTS.md is followed.

## Acceptance criteria

| # | Criterion | Evidence |
| --- | --- | --- |
| 1 | With working slots in the normal library and none in the adult library, the adult library's models make no request and write no usage row in either library; RD14's `TitleTranslator` on the adult library does the same | Package (stub HTTP recording every request) |
| 2 | With different slots in each library, an adult request goes to the adult slot's address with the adult key and writes its usage row in the adult library only; the normal `usage` table has no row after adult requests; the reverse holds | Package |
| 3 | The same address, model and key saved in both partitions are two keychain items under two services; removing or replacing the adult key, and Delete of the adult partition, leave the normal key usable | Package (two in-memory stores; `KeychainKeyStore.service(for:)` differs); UI (fixture host, both slots, adult key removed, normal still shows its dots and four characters) |
| 4 | The adult workspace translates with the adult slots only: with a normal fixture slot and no adult slot, adult rows show originals; with an adult fixture slot, the fixture's mark | UI (RD14 on `main`); `Workspace`'s precondition |
| 5 | S10 inside the adult partition: Primary and Backup Model with the S9 form (create, Load List, Test, Save, Remove) on the adult library, Show Thumbnails in Lists, lock timing, Clear Browsing Data, Turn Off. From the normal partition: no slot, thumbnail or limit row, and gap 1's sentence | UI on iPhone and iPad |
| 6 | The adult workspace's store is the adult partition's own persistent store, the normal one's the default store; page data written in one is absent from the other in both directions; adult data survive a lock and an unlock; Clear removes the adult data and leaves the normal data | Package (A1); UI (`/storage` fixture page); simulator check by hand with a local `http` page setting a cookie in each partition, screenshots |
| 7 | Delete removes the adult browser store with the rest; a failure to remove it leaves the partition on and says so | Package (stub, order, failure); UI (after Delete and turning on, `/storage` reports nothing) |
| 8 | Thumbnails off: adult rows show none and none is requested or read; normal thumbnails unaffected; the value survives a relaunch | Package (per library); UI (adult Settings › Data reads zero after the image row was on screen with the switch off, then above zero after on; normal unaffected) |
| 9 | No image of a moved article is in the old cache after a move: a store whose fetch began before the clear writes nothing, and a moved article whose row and reading screen (with a body image) were on screen when the move ran adds nothing afterwards | Package (the cache's store hook holds a store in flight); UI (adult → normal with the row and the article open; the adult Settings › Data reads zero and stays zero) |
| 10 | The confirmation states the consequences and lists the sources that stay; a source whose address is in the destination under the same identifier (an interrupted move) counts as moved; a category whose every source stays moves nothing and says so | Package (plan); UI (normal → adult with one address already in the adult partition) |
| 11 | After a move: the destination holds the category and the moved sources with their options, without validators, last success or error; the old library holds no row of the moved sources, their articles, bodies, seen identifiers or translations; the category is gone there or holds exactly the staying sources; the old image cache is empty; the moved sources are collected in the destination (decision 10, gap 5) | Package (both directions, row counts per table); UI both directions with the fixture feed |
| 12 | A failure of the copy changes nothing; a failure of the deletion leaves the category in both, says so, and moving again finishes with nothing lost; cancelling the caller between the steps or inside either changes none of this; a lock during the run of a normal → adult move that returns `moved` still leaves the normal image cache empty (`AppModel` clears it, decision 11) | Package (injected failures; cancellation at each point); UI (debug option failing the deletion once, its message, a second move; a lock during a normal → adult run slowed by the debug option, then the normal Settings › Data reads zero) |
| 13 | "Move to Adult Partition…" calls `chooseAdult(pending: .move(…))`, the partition switch's own unlock: refused, cancelled or interrupted leaves the normal partition, writes nothing and drops the request (a later plain unlock shows no confirmation); passed shows the adult partition with the confirmation; Cancel leaves the owner in the adult partition with nothing written; a lock while the plan is being read or while the confirmation is shown writes nothing, presents nothing and leaves nothing of it in the normal partition; Move finishes as criterion 11 | UI (stand-in authenticator answers; the debug report's `pool=closed` after the lock) |
| 14 | No Swift source of the app or the package logs, prints or dumps | Package source scan |
| 15 | Decision 12's list holds on `main` as it then is; RD18's scans still pass | Implementer's report; package |
| 16 | The three checks pass; every new string has its Simplified Chinese; screenshots at the largest text size, dark and Simplified Chinese of S10 (both entry points), the S9 form inside S10, the move confirmation and its messages, the Clear question | CI; screenshots (iPhone, iPad Pro) |

## Frozen issue contract

**In scope.** The adult library's `LibraryModels` and its own HTTP session; a workspace's own models with the precondition; the adult slots in S10; the adult browser's persistent store, Clear Browsing Data and its removal at Delete; `list_thumbnails` per library and its S10 switch; the image cache's generation; the hand-over of an operation through the unlock, with its `.move` case; the move (`CategoryMove`, the S13 control, confirmation, messages, the app's orchestration); the logging scan; fixtures, debug options, strings, tests, screenshots.

**Out of scope.** Background collection of adult sources (RD24); the limit's control (RD17); body and page translation (RD15, RD16); the configuration file (RD20); clearing the normal browser's data and a cache-size control (RD21 decided against both); overviews (RD23); search (RD25); moving one source between partitions; local-only Copy, byte-level erasure, keyboard learning and share-sheet suggestions (For the owner 8, 12, 13); a change to `AdultGate`'s operations or to `CoverRule`.

**Other issues own.** RD14: the translator, `daily_automatic_limit`. RD15, RD16: translators built from the workspace's own models. RD17: the Usage screen and the limit control. RD20: export and import, with its own case of the hand-over. RD23: overviews of a moved category.

**Invariants.**

- RD18's stand unchanged: the adult library is obtained only from `AdultGate.unlock()`; while the gate is off, locked or unavailable, the interface holds no adult library and no model built on one; the gate's state matches what is on screen.
- Text of a library is sent only through that library's own `LibraryModels`; a workspace is built only with its library's models.
- A key is stored only under its partition's keychain service.
- The adult browser's sessions use only the adult store, the normal browser's only the default store; no file other than `BrowserDataStores.swift` and RD12's `PageExtractor.swift` constructs a website data store.
- `CategoryMove` (and RD20's import and export) are the only code that holds both libraries; it runs only while the adult partition is shown; it copies before it deletes.
- Nothing is logged. No migration.

## Assumptions

Measured by the implementer before building on them, each reported; A1 first.

| Assumption | How it is measured | If it does not hold |
| --- | --- | --- |
| A1. `WKWebsiteDataStore(forIdentifier:)` (iOS 17) is a persistent store of its own: a cookie set in one identified store (by a loopback page's `Set-Cookie` and through `httpCookieStore`) is absent from another; `removeData(ofTypes: allWebsiteDataTypes(), modifiedSince: .distantPast)` empties one and not the other; two store objects for one identifier see the same data | A package test with test-only identifiers, removed at its end (it writes under the test runner's `~/Library/WebKit`, on CI too); the same on the iOS 26.5 simulator | If identified stores cannot be made from the package test runner, the evidence is the simulator's alone, and the package keeps only the mapping test. If they do not separate or persist, report before choosing: the fallback is `main`'s non-persistent adult store, with Clear ending the sessions; the owner is told |
| A2. `WKWebsiteDataStore.remove(forIdentifier:)` succeeds after a lock on RD18's paths where UIKit keeps the adult browser model (and so its store object) alive, or fails with an error saying the store is in use | Delete after each path of RD18's A4 table | Decision 5 already counts an in-use refusal after the data were removed as success; any other error is "could not be deleted" |
| A3. A fixture page of the browser's fixture scheme can write and read `localStorage`, kept per data store (`document.cookie` is not expected to work on a custom scheme) | The `/storage` page in both partitions | The UI evidence becomes the debug report's count of each workspace store's website data records (`fetchDataRecords`); page cookies stay with the simulator check |

## Approach

1. **Each workspace has its own models.** `WorkspaceParts.models` becomes `normalModels` and serves only Settings › Models & Translation (ux S8), in either workspace. `Workspace.init` gains `models: LibraryModels` with `precondition(models.belong(to: library))` (RD14 adds `belong(to:)`). Every translator of the workspace is built from `workspace.models` unconditionally — RD14's `TranslationModel` now, RD15's and RD16's when they exist — and RD14's `parts.models.belong(to: library)` condition goes. `AppModel.chooseAdult()` makes the adult `LibraryModels` from the unlocked library, the gate's adult `KeychainKeyStore` (under the UI tests the suffixed one) and its own HTTP stand-in (decision 3); it goes with the workspace at the lock.

2. **The adult slots in S10.** The adult workspace has a second `ModelSettingsModel`, `partitionModelSettings`, on `workspace.models`, answering a new route `SettingsRoute.adultModelSlot(ModelRole)`; `ModelSettingsModel` takes its route constructor as a parameter so each model sets up only its own form, and the navigation's settings-path callback reaches both. The form is RD13's `ModelSlotForm` with that model in its environment. S10 inside the adult partition, in order: "Models" (Primary Model, Backup Model, RD13's rules); Show Thumbnails in Lists; Daily Automatic Limit (decision 12); Lock After Leaving the App; Clear Browsing Data; Turn Off. From the normal partition: lock timing, Clear Browsing Data, Turn Off, and the footer "The adult partition's models, list thumbnails and daily limit are set inside the adult partition." A Test from S10 records its usage row in the adult library (RD13 decision 11). The adult `partitionModelSettings`' slot changes resume the adult translator (RD14's `onSlotsChanged`).

3. **Model context.** Each partition's `LibraryModels` has its own `URLSessionModelHTTP`, so no connection or TLS state is shared; under the UI tests both use `FixtureModelHTTP`. Prompts are the package's fixed texts (N12); usage rows go to the models' library by construction.

4. **The adult browser's own store.** `Browser/BrowserDataStores.swift` (package) is the one place that makes a website data store for a partition: normal → `.default()`; adult → `WKWebsiteDataStore(forIdentifier: BrowserDataStores.adultIdentifier)`, a fixed UUID in the source. Under a UI-test library directory (debug builds) the normal workspace keeps RD10's `.nonPersistent()` (it lasts the process, enough for "Clear leaves the normal data"), and the adult store is identified by a UUID derived from the directory's name (the first 16 bytes of SHA-256 of `"<name>/adult"`), so the tests exercise a persistent store and never touch the real one; at such a launch the app removes every identified store other than that one and the real adult identifier. `AppModel` asks `BrowserDataStores` for the workspace's partition; `BrowserModel` and `BrowserConfiguration` still take what they are handed (RD10). A site login now survives a lock until Clear or Delete. Picture in Picture stays off and media suspended as RD18 built.

5. **Clear Browsing Data, and Delete.** `AdultBrowserData` (package protocol; `WebKitAdultBrowserData` in `Browser/`; a stub in tests): `clear()` — `removeData(ofTypes: allWebsiteDataTypes(), modifiedSince: .distantPast)` on the adult store; `removeStore()` — `clear()`, then `WKWebsiteDataStore.remove(forIdentifier:)`, an "in use" error counting as removed (A2). S10's button asks first; on Clear, if the adult workspace is shown, its browser routes are closed on both stacks (`NavigationModel.closeBrowsers()`, as another sidebar selection closes them, RD10 decision 3) so no adult page writes during or after; then `clear()`; the footer then reads "Browsing data was cleared." until the screen is left. Disabled while a gate operation runs. `AdultGate.init` gains the `AdultBrowserData`; `turnOff(deletingData: true)` removes the database files, the keys, the browser store, and last the image cache directory; a failure stops there, says "could not be deleted" and leaves the partition on.

6. **Show Thumbnails in Lists.** `Library.listThumbnails()` / `setListThumbnails(_:)` on `setting` key `list_thumbnails` (`"1"` / `"0"`; absent or anything else reads as on). `ReadingModel.showsThumbnails` is read at the workspace's load and set by the switch after a successful write (a failure shows "The change could not be saved."). `ArticleRowView` keys its thumbnail task on the flag and, when off, asks the loader for nothing and draws nothing. Body images are unaffected (RD11's handoff); cached thumbnails stay until evicted or cleared.

7. **No store lands after a clear.** `ImageCache` gains a `generation` that `clear()` raises; `store(_:for:generation:)` writes nothing when it changed since the caller read it. `ThumbnailLoader` and `BodyImageLoader` read it before their fetch. The old `store(_:for:)` reads the current one. This covers fetches already in flight; fetches that would start after the clear are prevented by decision 11's order.

8. **Logs.** A package scan in `AdultScanTests`' form finds no `print(`, `debugPrint(`, `dump(`, `NSLog(`, `os_log(`, `Logger(` or `import os.log` in any Swift source of the app or the package, except `FixtureTransport.swift` (a `print(` inside fixture text), and fails when it finds no file.

9. **An operation handed over through the unlock** (one mechanism for RD19 and RD20; the names are RD20's frozen ones). `@discardableResult AppModel.chooseAdult(pending: PendingAdultOperation? = nil)` returns the unlock's outcome (RD20 uses it to build its normal-only preview on failure; RD19 ignores it). `PendingAdultOperation` has the case `.move(categoryID: UUID)` (a normal category's identifier) and RD20's `.importConfiguration(document)`. The partition switch calls it with `nil`, as today; "Move to Adult Partition…" calls it with `.move`.
   - The pending value lives only in the `chooseAdult` call. It is dropped on every outcome other than the adult workspace being shown: refused, cancelled, interrupted, no passcode, could not open, discarded by the background (RD18 decision 5) — each with RD18's existing sentence or none, nothing read and nothing written.
   - When the adult workspace is shown, the pending value is handed to it in the same step (`workspace.begin(pending)`) and `AppModel` keeps nothing. From there it is the adult workspace's: a lock drops it with the workspace, so nothing adult outlives the lock in any object.
   - Whichever of RD19 and RD20 is implemented first builds the hand-over; the second adds its case.
   - The gate, `CoverRule`, the lock timing and RD18's invariants are unchanged: the adult library is reached only through `unlock()`, while the adult partition is shown.

10. **The move** (`Store/CategoryMove.swift`, package; `precondition(from.partition != to.partition)`).
    - `plan(category:from:to:)` reads the category and its sources (old), the destination's sources with one of their addresses, and whether a category with the identifier exists there. A source *moves* when no destination source has its address, or when the one that has it has its identifier too (an interrupted move); otherwise it *stays*. The plan holds the number of articles to be deleted.
    - `run(plan:from:to:)`. **Step 1, the copy:** one write transaction in the destination — re-reads the addresses (a source with a new twin stays); inserts the category if none has its identifier (name, icon, overview mode, placed last); inserts each moving source not already there with its identifier, kind, address, name, site address, paused, automatic translation, body mode and page translation, with no ETag, Last-Modified, last success or last error; deletes `setting` `last_refresh_at`. **Step 2, the deletion:** one write transaction in the old library — deletes the moved sources (articles, bodies, seen rows and translations follow by the cascades) and the category when no source is left in it.
    - Both steps run inside one unstructured `Task` whose value `run` awaits, as `LibraryModels.record` does: GRDB's asynchronous write checks cancellation and interrupts its statement when the calling task is cancelled, so the steps are shielded from the caller and each runs to its end.
    - `clearOldCache(from:)` is separate: the app calls it after decision 11's interface step.
    - Results: `moved(staying:categoryRemoved:)`; `nothingToMove` (nothing written); `notMoved` (step 1 failed, nothing changed); `copiedNotRemoved` (step 1 committed, step 2 failed; moving again finds the copies by identifier and finishes).
    - Left behind in the old library: usage rows (no content) and RD16's `page_text` entries. The latter are translations of page text runs keyed by host and text, not by source: a host may serve pages the old partition keeps (another source on it, an article's link, a followed link), so they are left, and entries no longer used age out after the retention period (RD16). Also left: the old browser's data for the moved web-page sources' sites (For the owner 7).

11. **The move in the interface — one path, inside the adult partition.**
    - S13's category sheet gains "Move to Adult Partition…" (normal partition) or "Move to Normal Partition…" (adult partition), shown while the gate is locked or unlocked, disabled while the sheet has unsaved changes, the category model is busy or the app is authenticating. In the normal partition it calls `chooseAdult(pending: .move(categoryID: id))`; in the adult partition it begins the move directly.
    - In the adult workspace, `CategoryModel` reads the plan through a closure `AppModel` gives it, which holds the normal library (`normal`'s, opened at start) and the adult one, and presents the confirmation at its dialog host. The confirmation is the adult workspace's, so a lock drops it unanswered; a plan that arrives after a lock stopped the model is not presented (RD18's rule: a stopped model raises no alert).
    - **The confirmation** (alert): "Move “⟨name⟩” to the adult partition?" (or normal); "Its sources move there and are collected again; new articles there are translated by that partition's model. Here, its ⟨n⟩ articles are deleted with their translations and overviews, and read and starred states are lost."; when some stay, "Already in the adult partition, so they stay here in “⟨name⟩”: ⟨first ten names⟩ and ⟨k⟩ more."; Move (destructive), Cancel. Names as plain text. On Cancel nothing is written and the owner stays in the adult partition.
    - **On Move:** `run`; then the old partition's workspace closes every route that shows the category, a moved source or an article of one — on every stack: lists, Today's, Starred, All Unread, an open reading screen with any page above it (`NavigationModel.close(showing:)`, which takes the moved source identifiers and asks `ReadingModel` for the open articles' sources) — and reads every living list again (`ReadingModel.reloadAllLists()`, awaited); only then `clearOldCache`. Both workspaces read their categories and recorded refresh time. A destination on screen (normal → adult) then refreshes the new category (`refresh.refresh(.category(id))`); an adult → normal destination is collected at its next entry (gap 5).
    - **Messages** (the adult `CategoryModel`'s, alert with OK): "Every source of “⟨name⟩” is already in the adult partition. Nothing was moved."; "The category could not be moved. Nothing was changed."; "“⟨name⟩” was copied to the adult partition but could not be removed here. Move it again to finish." (each with its normal twin). Success shows nothing.
    - A lock during `run` closes the adult library under it; the shielded steps end, failing where they touch it; the result reaches no living workspace. The libraries are left as decision 10's results say, and the next unlock shows where the category is.
    - When the old partition is the normal one (normal → adult), `AppModel` itself awaits `run` and, when it returns `moved`, runs `clearOldCache` on the normal library whatever became of the adult workspace; the normal workspace's navigation was cleared when the adult one was shown (RD18), so nothing normal is on screen to fetch into it. The reverse residue (adult → normal, a lock during the run) stays in the adult partition's own cache, which the lock closes; accepted.

12. **The daily limit in S10.** The adult limit is RD14's `daily_automatic_limit` in the adult library, so the partition's own by construction. S10 (inside) shows "Daily Automatic Limit" with the stored value, opening RD17's Usage screen, which edits the shown library's value (RD17 decision 7). If RD17 is not merged, the row is left out and RD17 adds it.

13. **Unchanged, confirmed by the implementer:** RD18 decision 14's list plus this issue's additions (the adult website data store, the two setting values). The implementer checks it against `main` as it then is and reports any difference.

14. **Order with the parallel issues.** An issue merged before RD19 follows RD14's pattern (no translator for the adult workspace) and RD19 rewires it to `workspace.models` (Files to change); an issue merged after builds on `workspace.models` directly.

## Files to change

Paths under `ios/`.

| Path | Change | Decision |
| --- | --- | --- |
| `NewsPawKit/Sources/NewsPawKit/Privacy/AdultGate.swift` | the `AdultBrowserData` parameter; Delete's order | 5 |
| `NewsPawKit/Sources/NewsPawKit/Browser/BrowserDataStores.swift` (new) | stores per partition, identifiers, `AdultBrowserData` and its WebKit implementation, the debug housekeeping | 4, 5 |
| `NewsPawKit/Sources/NewsPawKit/Store/CategoryMove.swift` (new) | plan, the two shielded steps, `clearOldCache`, results, an internal test switch failing a step | 10 |
| `NewsPawKit/Sources/NewsPawKit/Store/Library+Settings.swift` (new) | `listThumbnails`, `setListThumbnails` | 6 |
| `NewsPawKit/Sources/NewsPawKit/Cache/ImageCache.swift`; `Images/ThumbnailLoader.swift`; `Images/BodyImageLoader.swift` | generation | 7 |
| `NewsPaw/AppState/AppModel.swift` | adult models and HTTP; stores from `BrowserDataStores`; `chooseAdult(pending:)` returning the unlock's outcome, with `PendingAdultOperation`; the move's closures and the normal cache's clear after a `moved` run; Clear | 1, 3, 4, 5, 9, 11 |
| `NewsPaw/AppState/Workspace.swift` | own `models` and precondition; `partitionModelSettings`; `begin(pending)`; thumbnails at load. If RD15 or RD16 is on `main`: their translator factories (RD15's body translator, RD16's page-translator factory handed to `BrowserModel`) built from `workspace.models`, without `belong(to:)` | 1, 2, 6, 9, 14 |
| `NewsPaw/AppState/ModelSettingsModel.swift`, `NavigationModel.swift` | route parameter, `SettingsRoute.adultModelSlot`, `closeBrowsers()`, `close(showing:)` | 2, 5, 11 |
| `NewsPaw/AppState/CategoryModel.swift`, `ReadingModel.swift` | move button's call, confirmation, messages; `showsThumbnails`, `reloadAllLists()`, open articles' sources | 6, 11 |
| `NewsPaw/Settings/AdultPartitionView.swift`, `Destinations/SettingsView.swift` | S10 by entry point; the new route's destination | 2, 5, 6, 12 |
| `NewsPaw/LibraryScreen/CategorySheetView.swift`, `CategoryDialogs.swift` | the move section, confirmation, messages | 11 |
| `NewsPaw/Destinations/ArticleRowView.swift` | thumbnail gate | 6 |
| `NewsPaw/Browser/BrowserFixtures.swift`, `AppState/DebugLaunchOptions.swift`, `UITestIdentifiers.swift` | `/storage` page; options failing a move's step once and slowing a move's run; identifiers | tests |
| `NewsPaw/Localizable.xcstrings` | strings below | — |
| `NewsPawKit/Tests/NewsPawKitTests/**`, `NewsPawUITests/**` | tests below | — |

No dependency, migration, Info.plist key or entitlement.

**Strings** (English · Simplified Chinese): Show Thumbnails in Lists · 在列表中显示缩略图; When off, article lists in the adult partition show no pictures and download none. · 关闭后，成人分区的文章列表不显示、也不下载缩略图。; Daily Automatic Limit (RD17's string); Clear Browsing Data · 清除浏览数据; Clear the adult partition's browsing data? · 要清除成人分区的浏览数据吗？; Cookies, sign-ins and other website data of the adult partition's browser are removed from this device. The normal partition's are kept. · 成人分区浏览器的 Cookie、登录状态和其他网站数据将从这台设备上移除，普通分区的不受影响。; Clear · 清除; Browsing data was cleared. · 浏览数据已清除。; The adult partition's models, list thumbnails and daily limit are set inside the adult partition. · 成人分区的模型、列表缩略图和每日上限需在成人分区内设置。; Move to Adult Partition… · 移到成人分区…; Move to Normal Partition… · 移到普通分区…; Move “%@” to the adult partition? · 要把“%@”移到成人分区吗？ (and normal · 普通分区); Its sources move there and are collected again; new articles there are translated by that partition's model. Here, its %lld articles are deleted with their translations and overviews, and read and starred states are lost. · 它的来源会移到那里并重新收集，新文章由该分区的模型翻译。这里的 %lld 篇文章及其翻译和概览将被删除，已读和收藏状态也会丢失。 (plural variants); Already in the adult partition, so they stay here in “%@”: %@ · 以下来源在成人分区中已存在，因此留在这里的“%@”中：%@ (and normal); and %lld more · 等另外 %lld 个; Move · 移动; Every source of “%@” is already in the adult partition. Nothing was moved. · “%@”的所有来源在成人分区中都已存在，没有移动任何内容。 (and normal); The category could not be moved. Nothing was changed. · 无法移动这个分类，没有做任何更改。; “%@” was copied to the adult partition but could not be removed here. Move it again to finish. · “%@”已复制到成人分区，但无法从这里移除。请再移动一次以完成。 (and normal). Reused: Primary Model, Backup Model, Models, Cancel, OK, RD18's unlock sentences.

## Execution surface

- **Written:** the paths above; the design is committed by the driver.
- **Read only:** `docs/reader/`, GRDB's checkout, the iOS 26 SDK's WebKit headers.
- **Executed:** `swift test --package-path ios/NewsPawKit`; `xcodebuild build-for-testing` and `xcodebuild test` with `-derivedDataPath`; `python3 ios/Tools/check_strings.py`; `xcrun simctl` (install, launch, screenshots, criterion 6's check by hand); a local static page server on the Mac's loopback address for that check only; `git`.
- **Not touched:** dependencies and both lock files; `.github/`; the owner's private files, `~/.config/newspaw/` and `.afk/` beyond the evidence directory.

## Failure handling

| Failure | Behaviour |
| --- | --- |
| Adult library has no slot, or no usable key | RD13's "no model set up" / "key needed"; no request; RD14 shows originals |
| Saving an adult slot fails | RD13's alerts, in S10's form |
| Clearing the adult store does not finish | No footer; Clear can be tapped again |
| `remove(forIdentifier:)` says "in use" after the data were removed | Counted as removed |
| Any other failure removing the adult store at Delete | "The adult partition's data could not be deleted. Try again."; partition stays on |
| Writing `list_thumbnails` fails | "The change could not be saved."; the switch shows the stored value |
| An image fetch began before a clear | Nothing stored (decision 7) |
| The unlock of a move is refused, cancelled, interrupted, discarded, or its library cannot be opened | RD18's sentence for it, or none; the request is dropped; nothing written |
| The category was deleted meanwhile, or the plan cannot be read | "The category could not be moved. Nothing was changed." |
| Step 1 fails | `notMoved`; nothing changed |
| Step 2 fails | `copiedNotRemoved`; both libraries consistent; moving again finishes |
| The caller is cancelled during the move | Nothing: the steps run in their own task (decision 10) |
| A lock while the confirmation is shown | Dropped with the workspace; nothing written |
| A lock during `run` | The library closes under the steps; decision 10's results, shown nowhere; the next unlock shows the state |
| A refresh, translation or body fetch of a moved article ends after step 2 | Its write finds no source or article and writes nothing (RD04's check; RD14 decision 11; RD12's write fails on the foreign key and is dropped) |

## Risk assessment

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| Identified data stores behave unlike the documentation (A1, A2) | Medium | High | Measured first, with a fallback |
| A route showing a moved article is missed and loads an image after the clear | Medium | Medium | `close(showing:)` over every stack; criterion 9's on-screen case |
| RD14, RD15, RD16, RD17, RD20 change `Workspace`, `AppModel`, `AdultPartitionView` in parallel | High | Medium | Decision 14; the hand-over's rule of decision 9; each handoff names its change |
| Clearing the whole old image cache surprises the owner | Low | Low | For the owner 4 |

## Test plan

**Package** (`swift test`): `LibraryModels` on two libraries with a recording stub HTTP (criteria 1, 2) and `TitleTranslator` on the adult library (criterion 1); two in-memory key stores and `KeychainKeyStore.service(for:)` (criterion 3); `BrowserDataStores` mapping and A1's identified-store test (criterion 6); `AdultGate.turnOff` with a stub `AdultBrowserData`: order and each failure (criterion 7); `list_thumbnails` per library (criterion 8); the cache generation with the store hook (criterion 9); `CategoryMove` in both directions — row counts of `source`, `article`, `article_body`, `seen`, `translation`, `category` in the old library, the destination's rows and settings, staying sources, an interrupted move, each step failed by the test switch, and the caller cancelled between the steps and inside each (a hook that waits inside a step) (criteria 10–12); the logging scan (criterion 14); the store-constructor scan.

**UI tests** (iterated with `-only-testing`; the whole suite once at the final commit; iPhone 18 Pro Max and one iPad, both iPads for the move): `AdultIsolationTests` — same key in both (3); originals versus fixture mark (4); S10 by entry point (5); `/storage` both ways, across a lock, Clear (6); Delete then `/storage` (7); thumbnails with Settings › Data (8). `CategoryMoveTests` — adult → normal with a moved article's row and reading screen open (9, 11); normal → adult through the hand-over with an address already in the adult partition (10, 11, 13); the refused unlock then a plain unlock showing no confirmation, Cancel, a lock while the confirmation is shown (13); the deletion failed once and moving again (12). Screenshots (16).

**Planted failures.** Each "never" rule has a test that fails for the reason named; the implementer plants each once, sees that test fail, reverts, and records it in the pull request.

| Rule (never …) | Plant | Test that fails |
| --- | --- | --- |
| Adult text goes to the normal slots | In `AppModel`, build the adult workspace's translator from `parts.normalModels` (made and run with RD14 on `main`) | Criterion 4's UI test (the adult row shows the fixture mark); with the models passed to `Workspace` too, its precondition |
| A partition's key is kept under the other's service | `service(for:)` returns one name for both | Criterion 3's package test |
| Adult website data in the normal store, or the reverse | Map the adult partition to `.default()` | `BrowserDataStores`' mapping test; criterion 6's UI test |
| A store made outside `BrowserDataStores` | Add `.nonPersistent()` in `AppModel` | The store-constructor scan |
| Clear touches the normal store | In `AppModel`'s Clear, also clear the normal workspace's store | Criterion 6's UI test (the normal `/storage` value gone) |
| Delete leaves adult browser data | Drop `removeStore()` from `turnOff` | Criterion 7's package test |
| Thumbnails fetched while the switch is off | Ignore the flag in `ArticleRowView` | Criterion 8's UI test |
| An image of a moved article in the old cache | Ignore the generation | Criterion 9's package test |
| Rows of moved content in the old library | Run step 2 with `PRAGMA foreign_keys = OFF`, set on the writer outside step 2's transaction (SQLite ignores it inside one), so the cascades do not run | Criterion 11's row counts |
| A move loses a source | Delete before copying | Criterion 12 with step 1 failing |
| A move stopped by the caller's cancellation | Run the steps in the caller's task | Criterion 12's cancellation test |
| A pending move outlives a refused unlock | Keep the pending value after a refusal | Criterion 13's UI test (the later plain unlock shows a confirmation) |
| Something is logged | Add `print(title)` in a model | Criterion 14's scan |

Checked by review only: the order "close the routes and reload the lists, then clear the old cache" (decision 11). Criterion 9's UI test would not fail if the order were reversed, since nothing in it starts a new image load between the clear and the closing, and the app has no unit-test target; the implementer names the order's lines in the pull request, and the criterion's own claim (nothing is added to the old cache afterwards) stays tested.

**Device checks owed** (listed in the pull request): a real site's login kept in the adult browser across a lock and absent from the normal browser, Clear removing it; a normal → adult move with Face ID; S10's form with a real key in both partitions.

## Handoff notes

- **RD14** (if it merges after RD19 after all): build `TranslationModel` from `workspace.models`; drop `belong(to:)`'s condition; wire the adult `partitionModelSettings` to the adult translator.
- **RD15** gets `workspace.models` for body translation in both partitions. Needs to: build its translator from it (or leave the adult workspace without one if it merges first); guard every write by the article's existence, since a move deletes articles under it.
- **RD16** gets `workspace.models` and the adult browser's own store. Needs to: keep `page_text` in the workspace's library; build its factory from `workspace.models`. A move leaves `page_text` behind (decision 10).
- **RD17** gets adult usage rows in the adult library and an adult translator to resume. If it merges after RD19, it adds S10's "Daily Automatic Limit" row (decision 12).
- **RD20**: the hand-over of decision 9 — `chooseAdult(pending:)` returning the unlock's outcome, RD20's case `.importConfiguration(document)` — built by whichever of RD19 and RD20 comes first, the second adding its case; export the adult slots from the adult library; the two partition settings are `list_thumbnails` and `daily_automatic_limit`; identifiers are unique per library only (an interrupted move leaves one in both).
- **RD21**: the "Set up a model" line in the adult partition reads the adult library's own slots and opens Settings › Adult Partition.
- **RD23**: a move deletes the category's overviews in the old library — by a cascade on `overview.category_id` when the category goes, explicitly in step 2 when it stays.
- **RD25**: search rows of moved articles must go with them (a cascade or step 2), and criterion 11's row counts are extended to the index.

## For the owner

1. Settings › Adult Partition shows the adult models, the thumbnails switch and the daily limit only when opened inside the adult partition; opened from the normal partition (after Face ID) it shows lock timing, Clear Browsing Data and Turn Off. This keeps RD18's promise that opening it never unlocks the partition. The alternative is that opening it from the normal partition unlocks and switches you into the adult partition; built only if you ask.
2. "Move to Adult Partition…" asks for Face ID and switches you into the adult partition; the confirmation is shown there. After Cancel you stay in the adult partition.
3. A category whose sources partly exist in the other partition moves the others and stays, with the duplicates, where it was; the confirmation lists them.
4. A move empties the old partition's whole image cache, not only the moved category's pictures; the rest are downloaded again as they are shown.
5. After a move into the adult partition the category is collected at once; after a move into the normal partition, when you return to it (with "Manual Only", at your next refresh). Titles are then translated by that partition's model.
6. An interrupted move leaves the category in both partitions; moving it again finishes and loses nothing.
7. A move leaves behind the old partition's translations of web pages (they are kept by site, not by source, and a site may serve pages the old partition keeps; unused ones age out after the retention period) and what the old browser stored for the moved web pages' sites. The normal partition has no Clear Browsing Data (RD21).
8. Not built: erasing the deleted articles' bytes from the old database file. A move deletes the rows; SQLite may keep old bytes in free space until they are overwritten. Erasing them would take a `VACUUM` and a truncating checkpoint after the move — exclusive access to the library and free space for a copy of the file. It is off because both libraries sit in the same app container, with the same file protection and the same backup: anyone who could read those bytes could read the adult file itself. Built only if you ask.
9. Clear Browsing Data asks first and closes any adult page that is open. The adult browser now keeps sign-ins across locks, until you clear it or delete the partition's data.
10. With thumbnails off, adult lists download no pictures; cached ones stay until the cache is cleared or they age out. Pictures inside articles still load.
11. The same service and key may be set up in both partitions; each keeps its own copy, and removing one leaves the other.
12. Copy in the adult partition reaches your other devices through Universal Clipboard like any Copy (RD18 allowed the owner's own Copy). A local-only Copy for the adult partition is possible hardening, not built unless you ask.
13. Not handled: the iOS keyboard may learn words typed in the adult partition, and the share sheet may suggest recent contacts.

## Revision record

- Version 1, 2026-11-16: first draft. One measurement: deleted rows' bytes under `secure_delete` and a truncating checkpoint (Python `sqlite3`).
- Version 2, 2026-11-16, after one debate round (one critic, verdict SOUND WITH FIXES, nine findings; triaged by the driver, all admitted). Evidence checked before changing: `AppModel.swift` lines 375, 565–569, 660–667 (no `gate.lock()` while the normal partition is shown); the critic's `history.py` re-run (1 and 60 sentinel copies left); GRDB's `withTaskCancellationHandler` and `Task.checkCancellation()` in its asynchronous write; `NavigationModel.categoryDeleted` (Library path only); RD16's and RD20's drafts.

| # | Sev. | Finding | Disposition |
| --- | --- | --- | --- |
| F1 | P1 | `withAdultLibrary` broke RD18's invariants, had no lock trigger in the app, and contradicted RD20 | `withAdultLibrary`, the `CoverRule` input, A6 and their criteria, tests and handoffs removed; one hand-over through the unlock (decision 9) shared with RD20 |
| F2 | P1 | `secure_delete` and the checkpoint cannot erase old copies in a used library (measured) | Criterion 11 is rows and cache files; barrier, pragma, checkpoint, A3, byte scan and gap 6 removed; erasure is For the owner 8; `page_text` stays, with the reason (decision 10) |
| F3 | P2 | Rows and an open article could fetch into the old cache after the clear | Routes closed on every stack and lists reloaded before the clear (decision 11); criterion 9's on-screen case; generation kept |
| F4 | P2 | A cancelled caller interrupts GRDB writes | Steps in an unstructured task, as `record` does; cancellation test |
| F5 | P2 | Local-only Copy not asked by the baseline | Cut; For the owner 12 |
| F6 | P2 | Some plants would not fail | Plant table rewritten; the adult-text plant made with RD14 on `main` |
| F7 | minor | The reduced S10 follows from RD18's choice | Gap 1 reworded; For the owner 1 names the alternative |
| F8 | minor | Only the adult store needs to persist under the UI tests; A1's runner caveat | Decision 4; A1's fallback |
| F9 | minor | RD15's and RD16's factory sites when they land first | Files to change, `Workspace.swift` row |

Round 2 (same critic, verdict SOUND WITH FIXES (small); seven resolved, F3 and F6 partly, nothing new at P1). Final edits by the driver's triage, no further round:

| # | Sev. | Finding | Disposition |
| --- | --- | --- | --- |
| F3 (rest) | P2 | A lock during a normal → adult run left the normal cache uncleared | `AppModel` clears the normal cache after a `moved` run (decision 11); criterion 12's lock case; the adult-side residue accepted |
| N2 | P2 | The plant "clear before closing the routes" would not fail criterion 9's UI test | Plant dropped; the order checked by review only, named in the pull request; no app test target added, no package seam |
| F6 (minor) | — | `foreign_keys = OFF` is ignored inside a transaction | The plant sets it outside step 2's transaction |
| Hand-over | minor | A stopped model could present a late confirmation | Not presented (RD18's rule); criterion 13 covers a lock while the plan is read |
| Hand-over vs RD20 | minor | Names and return value differed from RD20's frozen text | `chooseAdult(pending:)`, `.importConfiguration(document)`, returns the unlock's outcome (`@discardableResult`) |
| `page_text` | minor | RD16 keys its cache by host and text | Decision 10 and For the owner 7 reworded; the decision unchanged |
