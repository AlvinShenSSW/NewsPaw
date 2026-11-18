# RD24 — Background refresh

Issue: [#145](https://github.com/AlvinShenSSW/NewsPaw/issues/145) · Epic E17 #120 · Milestone M2 · Priority P1 · Requirements N04 (background), N09 (while locked). Also touched: N06 and N11 (automatic title translation, the daily limit), N13 (offline tests, the real-device list), spec section 4 (the `background_refresh` setting); ux S8 (Refresh).
Version 2 (2026-11-17), after one debate round. Written against `main` `abab44b` (RD06, RD18 with its post-implementation record, RD11, RD12, RD13); the RD14 worktree at `c3afc62` (`TitleTranslator`, `TranslationModel`); the RD19 worktree at `800b19d`, whose fix round is still in progress (the fix this design builds on, `Library.setLastRefreshAt(_:collected:)`, is commit `07a155a`); the RD21 worktree at `38366a6`; the frozen RD20 and RD23 designs. Depends on RD06, RD14, RD18.

The owner's instruction for this phase (2026-11-12): one user, converge, no over-engineering.

## Spec review

**The baseline.** N04: "Background: the app registers for background refresh. The system decides when it runs and gives no guarantee. Background work collects and translates titles only, and sends no notification." N04 also says "Clean-up runs when the app is entered." N09: "Background refresh **may** still collect adult sources and translate titles". Section 6: "Background collection has its own channel that writes and never serves data to the interface." Section 4: background refresh on or off is a **global** setting (preferences, exported; section 5's sample: `"background_refresh": true`). M2: a delivered task, "or one triggered from Xcode, collects new articles and translates their titles without the app being opened"; the frequency is recorded as observed. Issue #145: titles only, within the daily automatic limit, no notification; the switch in Settings › Refresh; nothing adult visible; "with background refresh off, no task is scheduled"; overviews in the background are out of scope.

**The code today.** No task is registered. `AppModel.start()` runs from `RootView`'s `.task`, opens the normal library, builds the normal `Workspace` (models only) and the gate, and makes the launch entry: clean-up, then a whole-library run when due. `Workspace.load()` starts the workspace's translator (`translation.start()` → `configure` → a first pass). Each workspace has its own `Refresher` (cap 4, per-source joining) and `TitleTranslator` (one request in flight). In RD19's worktree the engine records `last_refresh_at` only when the run collected every current target (`setLastRefreshAt(_:collected:)`). The app has no entitlements file and sets no protection class, so the library files have the container's default class (readable after the device's first unlock); keychain items are `AfterFirstUnlockThisDeviceOnly`.

**Decisions where the baseline leaves a choice.**

1. **Normal partition only.** Every sentence about the adult partition in the background says "may", and the M2 acceptance and the issue's criteria are met by the normal partition alone. A background run never opens, creates or touches the adult library's file. RD18's invariant — code outside the package obtains the adult library only from `AdultGate.unlock()` — stands unchanged, and the gate is not changed. Adult sources are refreshed when the partition is next unlocked, as today (`AppModel.show` runs the adult workspace's entry). The larger option is listed under "For the owner" as not built.
2. **"Manual Only" turns background refresh off too.** The pass uses the entry's due rule, which is never due for "Manual Only", and nothing is scheduled then.
3. **A launch made in the background is not an entry.** Its launch entry is made at the scene's first activation.
4. **After collecting: titles only.** RD14's automatic pass, counted and limited (N11). No clean-up, bodies, images, overviews or notifications.
5. **The setting** asked of this issue by RD20: `background_refresh`, global, Boolean, default on, in the preferences store under that name, exported. The record of runs, `background_refresh_runs`, is device state and never exported.
6. **Seeing that it runs.** Settings › Refresh says how many times a background run ran in the last 7 days and when the last one ran. ux S8 does not have this line; it is how a TestFlight build shows that runs happen (the issue's fourth criterion), and it is listed for the owner.

## Acceptance criteria

1. **Registration.** The `fetch` background mode and the permitted identifier `io.newspaw.reader.refresh` are declared, and the app's handler is registered on every launch (decision 2).
2. **Scheduling.** With the switch on and an interval of 15, 30 or 60 minutes, one app-refresh request is pending after launch, after a change of either setting, after the scene enters the background, and after a run starts, each with earliest start "now + the interval". With the switch off or "Manual Only", no request is pending after any of those events. A submission the system refuses changes nothing else.
3. **A run collects and translates.** A delivered run with the normal library due collects it once, as an ordinary whole-library refresh (RD06, with RD19's record rule), then resumes the normal translator; automatic requests are counted and limited (N11). Not due: no collection. On every branch after a successful preparation the run waits for the normal translator to settle — including a pass started by the preparation itself on a cold launch — and ends when it has settled or the time runs out. No clean-up: an unstarred article past the retention period is still there after a run.
4. **The adult partition is untouched.** A background run never opens, creates or touches the adult library's file, whatever the partition's state; the background work is built without the store, the gate or anything adult.
5. **Nothing adult is presented, nothing is posted.** No notification, badge, activity or widget (RD06 and RD18 scans unchanged); Today and the lists after a run show the normal partition only.
6. **Time and expiry.** Collection is cut 15 seconds after the pass starts: unfinished collections are cancelled and keep their status, articles and `seen` rows (RD06 criterion 4). When the system's time runs out, the refresher is cancelled on the main actor before the task is completed, and the task is completed once.
7. **The app comes to the front during a run.** The run ends its task; its collection continues as the ordinary refresh ("Updating…" on Today); the entry waits for that collection to end before its due check, so the library is not collected twice and `last_refresh_at` is written once; the status line then shows the new time.
8. **Background launch.** A launch made for the task builds no view; a library that cannot be opened in the background leaves the app able to open it at its next foreground start (no failure screen is latched); the owner opening the app afterwards gets the launch entry.
9. **Settings.** "Background Refresh" (on by default) between Refresh Interval and Keep Articles, with its footer and the runs line; it survives a relaunch; every string has its Simplified Chinese.
10. **Evidence from Xcode and a device.** A triggered or delivered launch collects and translates; the observed frequency over several days, and how each run ended (settled or expired), are recorded as observed. The pull request says where criterion 1's "simulated background launch" was actually shown.
11. **Structure.** The three `AGENTS.md` checks pass; existing suites pass; debug seams are inside `#if DEBUG` and active only under a UI-test library directory, and absent from the release binary.

## Frozen issue contract

**In scope.** The setting and the runs record; Settings › Refresh's switch, footer and runs line; the Info.plist entries and the task handler; scheduling and its reconciliation; `BackgroundRun` and `BackgroundPass` in the package; a public `TitleTranslator.untilSettled()` (polling); splitting `AppModel.start()` into a shared preparation and the launch entry; the entry's wait for a background collection; debug seams; strings; tests; two spec sentences and one ux sentence.

**Out of scope.** The adult partition in the background, and any change to `AdultGate`, `LibraryStore` or RD18's invariant; any change to `Refresher` or `RefreshModel`'s run semantics; notifications, silent pushes, `BGProcessingTask`; overviews (RD23); bodies, images, clean-up in the background; a separate translation deadline (decision after F7's measurement); a warning when the system's Background App Refresh is off.

**Others own.** RD20: the `background_refresh` member and `background_refresh_runs` on the not-exported list (added here if RD20 merged first). RD23: overviews, and the entry trigger in the handoff below. RD22: the device list.

**Invariants.** Outside the package the adult library is obtained only from `AdultGate.unlock()`. One `Refresher` and one `TitleTranslator` per open library: the background pass uses the normal workspace's. Text of a library goes only through its own models. No automatic request at or over the daily limit. Nothing posted, no badge.

## Assumptions

| Assumption | Measured first by | If it does not hold |
| --- | --- | --- |
| A1. SwiftUI's scene modifier `.backgroundTask(.appRefresh(_:))` (iOS 16.0 and later; the app's minimum is iOS 26) registers the identifier at launch, runs its action on a background launch with no scene connected, reports expiry by cancelling the action's task, and completes the task when the action returns | The first measurement: the scheme's "Launch due to a background fetch event" plus the debugger command (A2), and on a device; log scene connections, the action's start, its cancellation | Fallback, decision 2: register with `BGTaskScheduler` in `NewsPawApp.init()` |
| A2. On the simulator `submit` succeeds and `_simulateLaunchForTaskWithIdentifier:` runs the action | Once by hand | Likely to fail (submit has been reported `unavailable` on simulators): the debug delivery (decision 9) is the simulator evidence and the debugger command is a device check; the pull request says so |
| A3. A delivered task gets about 30 seconds; the system suspends the app only after the task completes | Device: start, end and how each run ended (settled or expired), recorded over the observation days | The 15-second cut is one constant; no translation deadline is added before this is measured |
| A4. If a scene connects during a background launch, `applicationState` is `.background` when `RootView`'s `.task` runs | The same launch as A1 | Decision 7 covers both; report it |
| A5. A run while the device is locked after its first unlock reads the normal library, preferences and the normal keys | Device check | The run ends at preparation and the foreground start opens the library (criterion 8) |

## Approach

1. **The setting and the record (package `Preferences`).** `backgroundRefresh` under `background_refresh`, default `true`; a stored value that is not a truth value reads as `true`. `backgroundRuns` under `background_refresh_runs`: dates of the last 7 days, at most 100, appended by `recordBackgroundRun(at:)`. App: `RefreshSettings` gains `backgroundRefresh`; a change of it or of the interval calls the schedule reconciliation (also after RD20's re-read on import).

2. **The task.** Info.plist (`ios/NewsPaw-Info.plist`): `UIBackgroundModes` = [`fetch`], `BGTaskSchedulerPermittedIdentifiers` = [`io.newspaw.reader.refresh`]. The `WindowGroup` gets `.backgroundTask(.appRefresh("io.newspaw.reader.refresh")) { await model.backgroundRefresh() }`: SwiftUI registers it, a cancelled action is the expiry, and returning completes the task — so "complete exactly once" and the expiry hop are the framework's. If A1 fails: `NewsPawApp.init()` creates the model and registers a handler with `BGTaskScheduler` (a static flag against a second `init`); a small wrapper of `BGAppRefreshTask` sets the expiration handler, hands it to the main actor, cancels the action's task there, and calls `setTaskCompleted` once when the action returns. Only the app-refresh kind is used.

3. **Scheduling (package `Background/BackgroundSchedule.swift`).** A pure rule: switch off or "Manual Only" → *cancel*; otherwise *submit, earliest start now + interval*. A package protocol (`submit(earliest:) throws`, `cancel()`), implemented in the app over `BGTaskScheduler.shared` (`BGAppRefreshTaskRequest`, `cancel(taskRequestWithIdentifier:)`). Reconciled at the end of each preparation, when either setting changes, at did-enter-background, and when a run starts. A submission error is ignored.

4. **One run (package `Background/BackgroundRun.swift`, main actor).** Made with a `BackgroundPassControl` and the work to do. It returns when the work ends; when its task is cancelled (expiry) it calls `control.cancel()` on the main actor and returns only after that; `cameToFront()` (called from `AppModel.sceneDidActivate`) calls `control.release()` and makes the run return at once. The control: `cancel()` cancels the refresher synchronously and ends the translator wait; `release()` disarms the cut and ends the wait, cancelling nothing.

5. **The pass (package `Background/BackgroundPass.swift`, main actor).** Given the normal library (a precondition checks its partition), the normal workspace's `Refresher` and `TitleTranslator`, the interval, the control, a cut of 15 seconds and an injected sleep. Returns a payload-free `BackgroundPassResult` (`notDue`, `collected`, `cancelled`, `failed`):
   1. `library.refreshIsDue(every:)` — false (also for "Manual Only") → no collection.
   2. Due → `refresher.refresh(.library)`, unchanged: RD06's joining and RD19's record rule apply. A cut task sleeps 15 s and then, unless released or ended, calls `refresher.cancelAll()`; it is cancelled when the collection ends. Then `afterCollection()` (the app reads the recorded time again for the status line) and `translator.resume(after: .refreshEnded)`.
   3. **On every branch** — not due, collected, or cut — `translator.untilSettled()` until it returns, the run is cancelled or released. This covers the pass a cold launch's preparation already started.
   The pass never calls the clean-up, reads a body or an image, or stops the translator (it is the interface's).

6. **`TitleTranslator.untilSettled()` (package, public).** A polling form of RD14's `settled()` test helper: every 100 ms, read on the actor whether a worker or side work is running or anything is queued; return when none is, when the translator is stopped, or when `Task.isCancelled`. No continuation and no change to the work loop, the side work or `stop()`; `settled()` stays as it is.

7. **The app (`AppModel`, new `AppState/BackgroundRefresh.swift`).**
   - `prepare(inBackground:)` is today's `start()` up to the gate and the first-run decision, then a reconciliation. It is one held task that the action and the scene's `.task` share, each rechecking `status` after awaiting it. A background failure leaves `status` at `.loading` and forgets the task; a foreground failure shows the failure screen as today.
   - `start()` = `prepare` + the launch entry, made when `applicationState != .background`, otherwise at the first did-activate (a flag makes it once).
   - `backgroundRefresh()`: `prepare(inBackground: true)` (failed → return); reconcile; switch off or "Manual Only" → wait for the translator to settle and return; otherwise record the run (`recordBackgroundRun`), then run `BackgroundRun` with a `BackgroundRefreshWork` built from the normal workspace, its library, the refresh settings and the control — and nothing else: no store, gate or adult object is reachable from that file.
   - The entry (launch or return) awaits the current background collection, if one is running, before `refresh.entered()`.
   - `sceneDidActivate` calls `cameToFront()` on the current run first; `sceneDidEnterBackground` reconciles after its lock rule.

8. **Settings › Refresh.** A section between Refresh Interval and Keep Articles: a `Toggle` "Background Refresh" on `RefreshModel.backgroundRefresh`; the footer is the fixed sentence plus the runs line, read from `Preferences` when the screen appears (relative time on the library clock).

9. **Debug seams** (inside `#if DEBUG`, only under a UI-test library directory; added to `AdultScanTests.debugOnlyNames`): a recording scheduler in place of `BGTaskScheduler`; a debug control in the report area, "Deliver background refresh", which — only when the recording scheduler holds a pending request — moves the debug clock to that request's earliest start and runs `backgroundRefresh()` while the app is in front; a debug count of adult-library opens in `LibraryStore`; the report gains `scheduled=<yes|no> background=<last result|none> runs=<count> adultOpens=<n>`.

**Strings** (English · Simplified Chinese):
- Background Refresh · 后台刷新
- "When NewsPaw is not open, the system may let it collect your sources and translate new titles. The system decides when and how often. Nothing is refreshed in the background with Manual Only, and no notification is sent." · "NewsPaw 未打开时，系统可能会让它收取来源并翻译新标题。何时运行、多久一次由系统决定。选择“仅手动”时不会在后台刷新，也不会发送通知。"
- With a plural variation: "Ran in the background %lld time(s) in the last 7 days, most recently %@." · "最近 7 天在后台运行了 %lld 次，最近一次在%@。"
- "Has not run in the background yet." · "尚未在后台运行过。"

## Files to change

Package: `Model/Preferences.swift`; `Translation/TitleTranslator.swift` (`untilSettled`); new `Background/BackgroundSchedule.swift`, `Background/BackgroundRun.swift`, `Background/BackgroundPass.swift`; `Store/LibraryStore.swift` (the debug count only); RD20's settings structure and not-exported list if RD20 has merged.
App: `NewsPawApp.swift`; `AppState/AppModel.swift`; new `AppState/BackgroundRefresh.swift`; `AppState/RefreshModel.swift` and `AppState/RefreshSettings.swift` (the switch); `AppState/TranslationModel.swift` (the translator reachable inside the app); `AppState/DebugLaunchOptions.swift`; `UITestIdentifiers.swift`; `Destinations/SettingsView.swift`; `Localizable.xcstrings`; `ios/NewsPaw-Info.plist`.
Tests: package tests below; new `ios/NewsPawUITests/BackgroundRefreshTests.swift`.
Docs: spec N04's background bullet gains "With Manual Only nothing is refreshed in the background. A background run does not clean up, and the adult partition is refreshed when it is next unlocked." ux S8: the background switch shows how often it ran in the last 7 days.

## Execution surface

The action and the pass on the main actor; fetching and storing off it inside `FeedCollector` (unchanged); translation on the normal translator's actor. Requests: the transport (feeds) and the normal library's model slots. Writes: the normal library exactly as a foreground refresh and translation write it; the preferences store. A cold background launch creates the normal workspace's model objects and the gate (which opens nothing), and no window or view.

## Failure handling

| Failure | Behaviour |
| --- | --- |
| The normal library cannot be opened in the background | The action returns; `status` stays `.loading`; the foreground start tries again |
| Not due | No collection; the run waits for the translator to settle (a cold launch's pass) |
| Offline; every source fails | RD06: not counted; the next entry or run tries again |
| No model, key rejected, service failure, daily limit | RD14's blocks and pauses; the translator settles quickly; nothing stored for blocked articles |
| The 15-second cut | Unfinished collections cancelled, recording nothing; the run is not counted; what was collected is translated |
| The time runs out during translation | The refresher is cancelled and the wait ends; the task completes. The translator's request in flight is **not** cancelled: the suspension freezes it, and on resume it may end as a failed usage row (the service may already have charged, N11) and a 10-minute service pause with blocked marks, which ends when the app comes to the front. Worst case per run: one request |
| The app comes to the front | The run ends its task; its collection continues as the ordinary refresh; the entry waits for it |
| A delivery after the switch was turned off | Nothing is collected or recorded; the action waits for the translator and returns |
| `submit` refused | Ignored |

## Risk assessment

| Risk | Likelihood | Handling |
| --- | --- | --- |
| The system delivers rarely or never | High | Accepted by spec section 10 and M2; the runs line makes it visible |
| Runs with a translation backlog always end by expiry (F7) | Medium | Measured on the device (A3) before any deadline is added; the worst case is one request per run |
| SwiftUI's modifier behaves differently on a background launch | Medium | A1 first; the hand-built form is the fallback |
| Building the normal workspace in a background launch costs time | Low | Models only; measured on the device |

## Test plan

**Package** (fakes, an injected clock and sleep; interleavings held by hooks the test releases; no tight time bounds):
- Preferences: default on, round-trip, a non-Boolean reads as on; the record keeps 7 days and at most 100.
- Schedule rule and reconciliation with a fake scheduler, after each trigger. **Planted failure:** without the switch check, "no request pending while off" fails.
- `BackgroundRun`: cancellation of its task calls `cancel()` before it returns; `cameToFront()` releases and returns; a cancellation after release does nothing more.
- `BackgroundPass`: not due → no request, and it still waits for a translator pass that was running; due → collects, records, resumes and waits for the settle, with a daily limit of 1 respected; the cut (one source held, the sleep released) cancels that source, which keeps its status, articles and `seen` rows, records nothing, and the others' titles are translated; `cancel()` during collection → no further request, no wait; `release()` → returns without cancelling, and the collection completes and records; an unstarred article past retention is still there (**planted failure:** a clean-up call added to the pass fails it); `BackgroundPassResult` is `CaseIterable` (a payload breaks the build).
- `untilSettled`: returns at once when idle, after a held request is released, when stopped, and when its task is cancelled, with the translator still working.
- Scans: RD18's carrier scan and RD06's badge scan unchanged; a scan that `AppState/BackgroundRefresh.swift` and `Background/` mention no `AdultGate`, `gate`, `LibraryStore`, `.adult` or `adult` (**planted failure:** a gate reference added there fails it).

**UI tests** (fixtures and the translator fixture model; three simulators; no fixed wait — each waits on the report element with a 60-second existence bound):
1. *A run collects, translates and leaves the adult partition alone.* Add the counting fixture source (one unread, translated). Turn the adult partition on, unlock (stand-in authenticator), add an adult source, lock with the button; read `adultOpens`. Tap "Deliver background refresh"; wait for `background=collected`. The normal source shows two unread, both translated; `adultOpens` and `pool=closed` are unchanged; the walk of RD18 criterion 6 finds no adult name. **Planted failure:** a run that unlocks the gate (the stand-in answering "passed") raises `adultOpens` and fails the test, shown once.
2. *The switch.* Settings › Refresh: on, the footer, "Has not run in the background yet."; off → `scheduled=no`, Deliver does nothing, `runs=0`; on → `scheduled=yes`, Deliver, wait for a result, the line says one run; relaunch: the switch as left.
Screenshots of Settings › Refresh in light, dark, Simplified Chinese and the largest text size (iPhone, iPad Pro).

**By hand on a simulator, recorded:** A1 and A2.

**Device checks owed** (in the pull request): a delivered run collecting and translating without the app opened; the runs line read daily over several days, with how each run ended; `_simulateLaunchForTaskWithIdentifier:` and `_simulateExpirationForTaskWithIdentifier:`; a translation request in flight at expiry, then the app resumed (what Usage shows, and that the pause ends on opening); a run while the device is locked; no source failing after an expiry; Background App Refresh off and Low Power Mode.

## Handoff notes

- RD20: `background_refresh` (global, Boolean, `Preferences.backgroundRefresh`) as a member, `background_refresh_runs` on the not-exported list, if RD24 merges first.
- RD23: whichever of RD23 and RD24 merges second makes every entry into the app (launch and return) call the workspace's overview due check whether or not a refresh ran, so that an overview is not left waiting for a pull when a background run has already brought the day's articles.
- RD22: the device checks above.

## For the owner

1. **Only the normal partition is refreshed in the background.** The adult partition is refreshed when you next unlock it, as today: it shows "Updating…" for a few seconds after Face ID. *Not built, and possible later if you ask:* refreshing it in the background while locked. That needs a package-internal path through the gate that opens the adult file without your authentication and translates with the adult models. A later design would have to settle three things: an unlock during that run gets the run's own open library, so the run must end before the unlock opens it; when the system's time runs out, the task is marked finished before the adult run has closed its library; and it would only ever run under the "Immediately" lock timing (or after a lock by hand), because with 1 or 5 minutes the partition is still unlocked in the background.
2. Background Refresh is on by default.
3. "Manual Only" also turns background refresh off.
4. iOS decides when and whether it runs, maybe a few times a day, maybe never (Low Power Mode, Background App Refresh off in the system's Settings). Settings › Refresh shows how many times it ran in the last 7 days and when it last ran — a line ux S8 does not have. No warning is shown when the system has it off.
5. Old articles are removed only when you open the app, never in the background.
6. No notification, no badge; bodies, images and overviews are not fetched or written in the background.
7. A run spends about 15 seconds collecting and the rest of its short time translating; sources it did not reach are collected next time, and an unfinished run does not count, so opening the app refreshes as usual.
8. Model spending is bounded by the daily automatic limit (200 by default). When a run's time runs out mid-translation, at most one request is cut off: it may be charged, Usage shows it as failed, and translation pauses until you next open the app.
9. Opening the app during a background refresh continues it as the usual refresh ("Updating…"), and the app's own refresh waits for it instead of collecting again.

## Revision record

- Version 1, 2026-11-17: first draft.
- Version 2, 2026-11-17: after debate round 1 (below); every finding admitted by the driver.

## Debate record

Round 1, 2026-11-17: one critic, read-only (`rd24/debate/critic-r1.md`), verdict SOUND WITH FIXES. The author checked each piece of evidence against `main`, `rd14-wt`, `rd19-wt` (`07a155a`, `800b19d`) and the RD23 design before revising; all held.

| # | Sev. | Finding | Disposition |
| --- | --- | --- | --- |
| F1 | P2 | Adult background refresh is permitted, not required | Normal only (driver's decision); gate unchanged; criterion 4 and UI test 1 prove the adult file is untouched; the option and its three open points under "For the owner" 1; A5 recorded as a fact |
| F2 | P2 | Engine changes unneeded; joining revives RD19's round-1 symptom | Dropped; the pass runs an ordinary library refresh on RD19's record rule; the entry waits for a background collection in `AppModel` |
| F3 | P2 | The translator's request is not cancelled at expiry; a cold launch already starts a pass | The run waits for the settle on every branch; the failure row states the worst case; criterion 3 corrected; a device check added |
| F4 | P2 | Fixed ten-second waits; test 3 could not read zero | A debug delivery while in front, only with a pending request; waits on the report; runs recorded only after the switch check |
| F5 | P2 | `untilSettled` with continuations reopened RD14's races | A public polling form of `settled()`; no new resume points |
| F6 | P2 | RD23's handoff unanswered | Replaced by the entry due-check note |
| F7 | minor | Translation has no deadline of its own | A3 records how runs end; no deadline now |
| F8 | minor | SwiftUI's `.backgroundTask` first | A1; the hand-built form is the fallback |
| F9 | minor | A2 likely fails | The fallback stands; the pull request says where criterion 1 was shown |
