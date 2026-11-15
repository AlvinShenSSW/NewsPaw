# RD18 — Adult partition: turning it on, authentication, switching, locking and the cover

Issue: [#139](https://github.com/AlvinShenSSW/NewsPaw/issues/139) · Epic E15 #118 · Requirements N09, N02; spec 6.1 (item 3), section 4 (device settings), section 6 (isolation point 1); ux section 2 (the partition switch), S7, S10, section 5 (accent), section 6.
Design version 2, 2026-11-15, frozen after one debate round (see the last section). Author: Claude (driver of this AFK run). Implementer: Claude Fable 5. External gate: Codex `gpt-6.1-sol` at high effort.

Builds on the merged code of RD02 (`LibraryStore`, whose adult functions are internal until this issue), RD03 (shell, navigation), RD06 (`Preferences`, the debug launch options), RD09 (lists, image cache per partition), and on RD10 (PR #159, the embedded browser) and RD13 (PR #160, `KeyStore`, the model settings), which are on main before this issue starts. Names below are the ones read at `feat/rd10-embedded-browser` d91d8ce and `feat/rd13-model-slots` 35d0992.

The owner's instruction for this phase (2026-11-12): one user, converge, no over-engineering. Where this design chooses the smaller of two mechanisms, that is why.

## Spec review

Today the app opens one library, the normal one, and every model object of the interface is built on it once, in `AppModel.start()`. The adult library can be created and opened only from inside the package. This issue adds the one public way to it, puts device authentication in front of that way, and makes the interface able to swap the library it is built on.

What the specification fixes: off by default; turned on in Settings › Adult partition; entering needs device authentication (Face ID, Touch ID or the device passcode); locking when the app goes to the background (default), after 1 or 5 minutes, or by hand, and locking returns to the normal partition; while locked nothing of the adult partition is shown anywhere; a cover is drawn the moment the app leaves the foreground while the adult partition is on screen; no notification, widget, Spotlight entry or Handoff carries adult content; every entry point sits behind one feature switch (spec 6.1); whether the partition is on and when it locks are device settings in the preferences store, never exported (section 4); the interface holds one library, and while locked it cannot obtain the adult one (section 6).

**Settled here**, because the issue and the specification leave it open:

1. **One feature switch.** `BuildFeatures.adultPartition` (package, a constant, `true` in this build). With it off the gate is "unavailable" whatever the preferences say: no Settings row, no partition switch, and the adult library is never opened or created. Under a UI-test library directory a debug launch option can turn it off for one launch (never on), so that the off state is testable.

2. **The gate is the only way to the adult library.** `AdultGate` (package, `Privacy/`, an actor) is made from the store, a device authenticator, the preferences, the adult key store and the feature switch. `LibraryStore`'s adult functions stay internal. The gate's states: unavailable, off, locked, unlocked. One operation runs at a time; a call made while another is running answers "busy" and does nothing. Its operations:
   - `turnOn(reason:)` — authenticates; on success creates the adult library file if it is missing (opened once to create it, then released; an existing file is not opened) and stores "on". The partition stays locked.
   - `unlock(reason:)` — only while on; authenticates; on success opens the adult library (creating the file if it is missing, which turning on already authorised) and returns it.
   - `lock()` — the store lets go of the adult library (decision 4). Never fails.
   - `authenticateForSettings(reason:)` — authenticates and changes nothing.
   - `setLockTiming(_:)`, `turnOff(deletingData:)` — decisions 8 and 9.

   Every authentication uses a new `LAContext` and the policy "device owner authentication" (biometrics, falling back to the device passcode), so one success is never reused for a later request. The authenticator is a protocol with five answers — passed, cancelled (by the owner), interrupted (by the system or because the app left), failed, unavailable (the device has no passcode) — implemented once on LocalAuthentication and once as a stub for tests. The sentence the system shows in its prompt is passed in by the app, from the string catalog.

3. **The interface is built per library and swapped whole.** One `Workspace` object holds everything the interface builds on one library: the category, source, refresh, reading and browser models and its own `NavigationModel`. `AppModel` keeps the normal workspace for the life of the app and the adult workspace only while unlocked; the root view shows exactly one and is rebuilt (`.id` of the workspace) when it changes, so that no sheet, alert, menu, pushed screen or view state of the other partition survives a switch. Because each workspace has its own navigation, a model of the workspace that is not shown — the normal one keeps refreshing while the adult one is shown — cannot close a screen or a sheet of the other partition, and no adult identifier lives in an object that outlives the lock. On a switch the workspace being shown gets the current tab and empty paths ("the root of the current tab"), its sheet and slide-over closed, and the list on screen is entered so that it is read again. Shared by both workspaces, and holding nothing of a library's content: the refresh settings (interval and retention, one observable object over `Preferences`, so that a change made in one partition is the other's too) and the normal library's `LibraryModels`. Each workspace has its own `ModelSettingsModel` on its own navigation, both on the normal library's `LibraryModels`: Settings › Models & Translation is the normal partition's in either partition (ux S8); the adult partition's models are RD19.

4. **Locking releases the library, and that is checked.** On lock the app, in one main-actor step with no suspension and with animations disabled, shows the normal workspace and drops the adult workspace after telling it to stop: its refresh run, source detection and image loads are cancelled, and its browser sessions are ended with their web views taken out of the view tree and released. Then it calls `gate.lock()`. The store then holds the adult library only weakly: when nothing else holds it, it is gone and its connections are closed. An unlock while the old object is still alive (a cancelled task that has not ended yet) gets that same object back, so there is never a second pool on the file. A debug-only element, present only under a UI-test library directory, reports whether the library object and the adult workspace's browser model are released; a package test (library) and a UI test (both) assert it after a lock. This is the evidence for "the interface layer holds no reference to the adult library". Retain cycles among a workspace's models, harmless while one workspace lived as long as the app, are found by this check and removed. Deleting does not depend on the release (decision 9).

5. **Switching.** The partition switch is a capsule with a menu (Normal, Adult; the current one checked), hidden while the gate is off or unavailable. Choosing Adult calls `unlock()`; on "passed" the adult workspace is built and loaded (categories, sources, the refresh time), and then, in one main-actor step, shown at the root of the current tab — unless the scene entered the background at any moment since the choice was made, in which case the workspace is dropped and the gate locked. The scene being merely inactive does not discard: the system's prompt itself makes it inactive. After the adult workspace is shown its refresh-on-entry rule runs. Choosing Normal, or the lock button, locks. Returning to the normal partition counts as an entry for its refresh rule.

6. **Where the switch is.** iPhone structure: at the leading edge of the navigation bar on the root screens of Today, Library and Starred. Pane structure (iPad at 700 pt and wider): at the top of the sidebar, in the pane and in the slide-over alike. In the adult partition the capsule is filled with the accent and reads "Adult", and a lock button (symbol `lock`, label "Lock") sits next to it. Both are at least 44 pt tall and are reachable by VoiceOver with their labels ("Partition: Adult", "Lock the adult partition"). This is ux section 2 as written; what it leaves open on pushed screens is "For the owner" 4.

7. **The accent follows the partition.** One environment value, set at the root from the workspace shown, gives the accent: `Palette.accent` or `Palette.adultAccent`. The root's `.tint` and every direct use of `Theme.accent` read it, including sheets (which do not inherit the root's tint).

8. **Lock timing.** A device setting with three values: immediately (default), after 1 minute, after 5 minutes. The app follows the scene through its four UIKit notifications only — will deactivate, did enter background, will enter foreground, did activate — not through `scenePhase`. While the adult workspace is shown:
   - "Away" begins at the first will-deactivate after the scene was last active (a later one does not move it) and ends at did-activate.
   - With "immediately" the app locks at did-enter-background.
   - With 1 or 5 minutes the app locks at did-activate when the time away is at least the setting or is negative (the clock was set back).
   - The time is the app's injected clock. The decision is a pure function in the package.
   - An app ended while away starts in the normal partition, as every launch does: nothing about being unlocked is stored.
   - Assumption A7 measures which notifications each way of leaving delivers. If some way of leaving the app does not deliver did-enter-background (an iPad window narrow enough for the tab structure stayed `runningForeground` after Home in RD10's measurement), "immediately" also locks at did-activate when the time away is 5 seconds or more, so that leaving the app locks and a glance at Control Centre does not. The measured table goes into the pull request.

9. **Turning off.** In Settings › Adult Partition, "Turn Off the Adult Partition" asks, as an alert: Keep Data Hidden, Delete Data, Cancel; Delete Data asks once more. The questions and the result message belong to `AppModel` and are presented at the root, so that they outlive the swap. Only after the last answer does the app lock (decision 4) and call `turnOff`.
   - Keep hidden: stores "off". The switch disappears; the file, image cache and keys stay. Turning on again brings the data back.
   - Delete: the store closes the adult library's pool explicitly (a reference still held somewhere then fails on use instead of keeping the file open) and forgets the object, removes `adult.sqlite` with its `-wal` and `-shm` files, every item of the adult key store (`KeyStore.removeAll()`, added here), and last the adult image cache directory (a thumbnail store that was ending cannot recreate it after that); only then it stores "off". A missing file or directory is not a failure. If a removal fails it stops, says so, and leaves the partition on, so that Delete can be tried again; it needs no library to be opened, so it also works when the adult library is damaged.

10. **The Settings screen (S10).** A row "Adult Partition" between Refresh and Data, present only when the feature switch is on.
    - While off: a short explanation and one switch, "Adult Partition". Switching it on calls `turnOn()`; the app stays in the normal partition and the screen changes to its "on" contents.
    - While on: opening the row calls `authenticateForSettings()` first, unless the adult partition is the one shown (it was unlocked by an authentication already). It never unlocks the partition. Contents in this issue: lock timing; Turn Off the Adult Partition. The other S10 rows (models, thumbnails, the daily limit, Clear browsing data) are RD19 and RD14.
    - The screen does not stay open across an absence: when it was opened from the normal partition it is popped by the same rule that locks the partition (decision 8, applied to the normal workspace's Settings path). Inside the adult partition the lock itself removes it.

11. **Messages.** A failed authentication, and one the owner cancelled, leave everything as it was and show an alert with one sentence and OK; an interrupted one (the app was sent away) shows nothing. When unlocking: "The adult partition is still locked."; when turning on: "The adult partition was not turned on."; when opening its settings: "Authentication is needed to open these settings."; when the device has no passcode, in all three cases: "Set a device passcode to use the adult partition." An adult library that cannot be opened after a passed authentication shows "The adult partition's library could not be opened." with the reason sentences of the launch failure screen; the app stays in the normal partition and the gate locked.

12. **The cover.** A window of its own in the scene, above the app's window, its sheets, alerts and menus: the background colour and the NewsPaw logo, nothing else. Whether it is shown is one rule — the adult workspace is shown and the scene is not active — applied synchronously at will-deactivate, at did-enter-background, and at the moment the adult workspace becomes shown (which can happen while the scene is still inactive after the system's prompt). It is hidden at did-activate, one main-loop turn after decision 8's check and any swap it caused, so that no frame of the adult partition is drawn under a cover that is already gone. It is not shown in the normal partition.

13. **What the adult partition can do in this issue.** Everything the normal one can, on its own library: categories, sources, refresh on entry and by hand, lists, stars, the reading screen, the image cache in its own directory (RD09), the browser. It has no suggested categories or sources (N02; `Library+Sources` already answers none for it). Its browser uses a non-persistent website data store in this issue, so nothing of adult browsing is written to the normal partition's store or to disk; RD19 replaces it with the adult partition's own persistent store and the Clear action. In the adult workspace's browser configuration Picture in Picture is off, and when the scene leaves the foreground (will-deactivate) while the adult workspace is shown, its pages' media are paused and their full-screen presentations closed, so that a video does not go on playing over the cover or in the system's playback controls. Nothing is sent to a model from the adult partition: no code that translates exists yet, and the only `LibraryModels` is the normal library's. While locked, adult sources are not collected (background collection is RD24).

14. **Nothing else may carry adult content.** Everything the app writes outside a library file, as read at the commits named above: the preference keys (the two refresh settings and this issue's two, none about content); `Libraries/<partition>.sqlite`; `Images/<partition>/`; the feed transport's session, which is ephemeral with no cookie store, URL cache or credential store; WebKit's default data store for the normal partition and a non-persistent one for the adult; one keychain service per partition; the pasteboard, only through the owner's own Copy actions. The app has no `@AppStorage`, `@SceneStorage`, `NSUserActivity`, notification, widget or Spotlight index. A package test scans the app's sources for those frameworks and property wrappers so that adding one fails a test. The implementer confirms this list against main as it then is and reports any difference before building on it.

15. **Under UI tests.** With a UI-test library directory the authenticator is a debug-only stand-in that answers from a launch option (a list of answers used in order; with none, "unavailable"), the adult key store's service carries the directory's name (as RD13 does for the normal one), and the real LocalAuthentication is never called. The stand-in can be told to answer only after the scene has been inactive and active again, to stand for the system's prompt.

**For the owner** (each is a choice the issue left open; none changes the specification's meaning):

1. Turning the partition on leaves you in the normal partition; the switch appears and you enter through it (one more authentication).
2. Settings › Adult Partition asks for authentication each time it is opened from the normal partition, and not when you are already inside the adult partition. Opening it does not unlock the partition, and it closes by the same timing that locks the partition.
3. "After 1 minute" and "After 5 minutes" count from the moment the app stops being in front and are checked when you come back. An app the system ended meanwhile always starts locked. A look at Control Centre or the app switcher shows the cover; whether it also locks under "Immediately" depends on what iOS reports for it (iOS 27 is said to report a fully opened Notification Centre as leaving the app), and the pull request states what was measured.
4. **A question for you.** ux section 2 puts the capsule and the lock button on the root screens of Today, Library and Starred and at the top of the iPad sidebar. On a pushed screen (an article list or an article on iPhone, or an iPad layout with the sidebar hidden) the plum accent is then the only sign of the adult partition, and locking by hand needs a step back — which ux section 6 ("never by colour alone") does not want. This design builds section 2 as written. The alternative is a lock button in the toolbar of pushed screens while in the adult partition; it is added only if you ask for it.
5. Until RD19 the adult partition's browser keeps nothing: a login made there is gone after a lock. Video in it has no Picture in Picture and pauses when you leave the app.
6. Until RD24 adult sources are collected only while the partition is unlocked. The normal partition keeps refreshing while you are in the adult one.
7. Settings › Models & Translation always shows the normal partition's models. The adult partition gets its own with RD19; until then nothing in it is translated.
8. Delete asks twice and also removes the adult partition's keys. Keep Data Hidden keeps everything; turning the partition on again shows it again.
9. A device without a passcode cannot turn the partition on.
10. Cancelling the system's prompt yourself shows the one-sentence message (the issue asks for it); a prompt the system took away shows nothing.
11. The wording under Approach is this design's.

## Acceptance criteria

| # | Criterion | Evidence |
| --- | --- | --- |
| 1 | On a fresh install there is no partition switch on any screen and no adult database file | Package test (store and gate); UI test on iPhone and iPad (no switch; the debug element reports that the file does not exist) |
| 2 | Turning on: a cancelled, failed or unavailable authentication changes nothing and shows its message; a passed one creates the file, shows the switch on Today, Library and Starred (the sidebar on iPad), and leaves the app in the normal partition | Package test; UI test |
| 3 | Choosing Adult: a cancelled or failed authentication leaves the app in the normal partition with the message; a passed one — also when the answer arrives while the scene is still inactive — shows the adult partition at the root of the current tab, with the capsule reading "Adult", filled, and the lock button | Package test; UI test, once with the stand-in that waits for inactive and active |
| 4 | In the adult partition a category and a source can be added and refreshed, an article starred, and none of it is in the normal library; the normal partition's content is not shown there | UI test with the fixture transport |
| 5 | A model of the workspace that is not shown does not change what is on screen: with an adult source's list open, and with an adult source's settings sheet open, a collection of the normal partition that ends leaves them open | UI test with a slow normal collection |
| 6 | After locking — by the button, by choosing Normal, by the timing rule — the app is at the root of the current tab of the normal partition, and a walk over Today, Library, All Unread, a category, Starred, the add-source sheet with its category picker, a category's settings and every Settings screen finds none of the adult category, source and article names | UI test on iPhone and iPad |
| 7 | After locking, the adult library object and the adult browser model are released, also when the lock came while a refresh was running and while a sheet and the browser were open | Package test of the store and gate; UI test through the debug element |
| 8 | Lock timing: the rule of decision 8 for each setting, including a negative time and repeated deactivations without an activation; the setting survives a relaunch; a relaunch always starts in the normal partition; the Settings › Adult Partition screen opened from the normal partition is closed by the same rule | Package tests of the pure rule with a stubbed clock and of the preferences; UI test for "immediately", for a short absence under "1 minute", for the relaunch and for the Settings screen |
| 9 | The cover: shown while the adult workspace is shown and the scene is not active, above an open sheet; not shown in the normal partition; after a timed lock nothing of the adult partition is visible once the cover goes | The rule as a package test; an app-switcher picture from each simulator with a sheet open; a check by hand with animations on (1-minute setting, an adult sheet open, return after the time). The real snapshot is a device check |
| 10 | Opening Settings › Adult Partition while on and locked asks for authentication; cancelled leaves the screen closed with the message; it does not unlock the partition | UI test |
| 11 | Keep Data Hidden hides the switch and keeps the data: after turning on again the category is there. Turning on does not open an existing file | Package test; UI test |
| 12 | Delete removes the database with its side files, the adult keys and the image cache directory, also when some are already missing, when the library is damaged, and when a reference to the library is still held; a failed removal leaves the partition on and says so; turning on afterwards shows an empty partition; both questions and the result are shown when Delete is chosen from inside the adult partition | Package test (in-memory key store with items, a cache directory with a file, a removal made to fail, a held reference); UI test from inside the adult partition |
| 13 | With the feature switch off there is no Settings row and no partition switch, also when the preferences say "on" and the file exists, and the gate opens nothing | Package test; UI test launched with the debug option after the partition was turned on |
| 14 | An unlock during which the scene entered the background is discarded; a gate operation requested while another runs does nothing | Package test (stub authenticator that waits); the discard in the app is read in review and listed as a device check |
| 15 | Changing a refresh setting in one partition changes it in the other: after changing the retention in the adult partition and locking, Settings › Refresh shows the new value | UI test |
| 16 | No notification, widget, Spotlight, Handoff or state-restoration API is used by the app | Source-scan package test |
| 17 | The three checks pass; every new string is in the catalog with a Simplified Chinese translation; the Face ID usage description has its Simplified Chinese localisation in the built app; the release build contains neither the stand-in authenticator nor the debug options | CI; the built app's `zh-Hans.lproj/InfoPlist.strings` read; a search of the release binary |
| 18 | Largest text size, dark appearance and Simplified Chinese: the capsule, the lock button, the Settings screen in both states, the two questions and a message show every label uncut; the accent is plum wherever it was rust; the capsule and lock button are at least 44 pt | Screenshots (iPhone, iPad Pro; default, dark, zh, largest text); UI test for labels and target sizes |

## Frozen issue contract

In scope: `BuildFeatures.adultPartition`; `DeviceAuthenticator`, its LocalAuthentication implementation and its test stub; `LockTiming` and the lock rule; `AdultGate`; the store's weak holding, explicit closing and deletion of the adult library; `KeyStore.removeAll()`; the two device settings in `Preferences`; the shared refresh settings object; `Workspace` with its own `NavigationModel` and the swap in `AppModel` and `RootView`; the partition capsule and lock button; the accent environment value; the cover; the scene notifications for the cover and the lock timing; Settings › Adult Partition with lock timing and turning off; the adult workspace's browser settings of decision 13; the Face ID usage description (English and Simplified Chinese); the debug stand-in authenticator, launch options and element; the strings; the tests and screenshots.

Out of scope: the adult partition's model slots and key use, its persistent browser data and the Clear action, the thumbnails switch, moving a category between partitions (RD19); the daily limit (RD14); the configuration file (RD20); background refresh (RD24); search (RD21); a custom lock screen; a passcode of the app's own; hiding the app's name or icon; encryption of the adult file beyond the system's file protection; a second window; a lock button on pushed screens (unless the owner asks: "For the owner" 4).

Invariants:

- Code outside the package obtains the adult library only from `AdultGate.unlock()` after a passed authentication made for that call.
- While the gate is off, locked or unavailable, the interface holds no adult library and no model built on one.
- A model built on one library reads and writes only its own workspace's navigation.
- Nothing about the adult partition's content is written to the preferences store, to the normal library, to the normal image cache or to the normal browser data store; nothing of the normal partition is written to the adult ones. There is no fallback from one partition's storage to the other's.
- A launch starts in the normal partition.
- With the feature switch off, the adult library file is neither opened nor created.
- Offline tests call neither LocalAuthentication nor the owner's keychain: package tests use the stub and the in-memory key store; under a UI-test library directory the app uses the debug stand-in.

## Approach

**Package.**

- `Model/BuildFeatures.swift`: the constant.
- `Model/Preferences.swift`: `adultPartitionIsOn` (key `adult_partition_on`, default false) and `lockTiming` (key `adult_lock_timing`, raw values `0`, `60`, `300`; another stored value reads as "immediately"). Device settings: RD20 does not export them.
- `Privacy/DeviceAuthenticator.swift`: the protocol (`authenticate(reason:) async -> AuthenticationAnswer`), `SystemDeviceAuthenticator` (a new `LAContext` per call; `canEvaluatePolicy` first, answering "unavailable" for "passcode not set"; user cancel is "cancelled"; system cancel and app cancel are "interrupted"; everything else that is not success is "failed").
- `Privacy/LockTiming.swift`: the enumeration and the pure rule of decision 8 (inputs: the setting, when away began, the current time, whether the background was entered, whether A7's fallback applies).
- `Privacy/AdultGate.swift`: decision 2. Its answers are closed enumerations; it never passes a keychain or file error's text to the interface, only "could not be opened" with the `LibraryError`, and "could not be deleted".
- `Store/LibraryStore.swift`: `releaseAdultLibrary()` (drops the strong entry, keeps a weak reference), reuse of a still-living object on the next open, `adultLibraryIsReleased`, `deleteAdultLibrary()` (closes the pool, clears the weak reference, removes the three files and then the cache directory). `Library` gets an internal `close()`. The normal library is untouched.
- `Privacy/KeyStore.swift`: `removeAll()` on the protocol, the in-memory store and `KeychainKeyStore` (one `SecItemDelete` over the store's service; "no such item" is success).

**App.**

- `AppState/Workspace.swift`: the bundle of decision 3, with `stop()`.
- `AppState/RefreshSettings.swift`: the shared interval and retention; `RefreshModel` reads them from it at each use.
- `AppState/AppModel.swift`: `start()` builds the store, the gate (feature switch, authenticator, preferences, `KeychainKeyStore(partition: .adult)`), the shared objects and the normal workspace; `status` is `.ready` without payload and `shown` is the workspace on screen; `chooseAdult()`, `lock()`, the turning-off flow with its questions and result; the scene notifications of decisions 8 and 12; `gateState` for the views. `NavigationModel` is no longer a property of `AppModel`.
- `Navigation/RootView.swift`: the environment of the shown workspace, the `.id`, the accent value, the root alerts of decisions 9 and 11.
- `Navigation/PartitionSwitch.swift`: the capsule menu and the lock button, placed by `TabContainer`'s three root screens and by `SidebarView`.
- `Navigation/CoverWindow.swift`: the window of decision 12, created with the scene.
- `Settings/AdultPartitionView.swift` and a `SettingsRoute.adultPartition`: decision 10.
- The Face ID usage description as an Info.plist build setting, with its Simplified Chinese in `ios/NewsPaw/InfoPlist.xcstrings` (the strings check reads only `Localizable.xcstrings`; criterion 17 names this one's evidence).
- Debug only, and only under a UI-test library directory: `FixtureAuthenticator`, the launch options for its answers and for the feature switch, and the element of decision 4 (which also reports whether the adult file exists).

**Strings** (English · Simplified Chinese):

- Adult Partition · 成人分区
- Normal · 普通; Adult · 成人
- Partition: Normal / Partition: Adult (VoiceOver) · 分区：普通 / 分区：成人
- Lock · 锁定; Lock the adult partition (VoiceOver) · 锁定成人分区
- The adult partition is a second, separate library. Its categories, sources and articles are shown only after Face ID, Touch ID or the device passcode, and it locks again when you leave the app. · 成人分区是另一个独立的资料库。只有通过面容 ID、触控 ID 或设备密码后，才会显示其中的分类、来源和文章；离开应用后会再次锁定。
- Lock After Leaving the App · 离开应用后锁定; Immediately · 立即; After 1 Minute · 1 分钟后; After 5 Minutes · 5 分钟后
- Turn Off the Adult Partition · 关闭成人分区
- Turn off the adult partition? · 要关闭成人分区吗？; You can keep its data hidden on this device, or delete it. · 可以把其中的数据保留在这台设备上并隐藏，也可以删除。; Keep Data Hidden · 保留数据并隐藏; Delete Data · 删除数据
- Delete everything in the adult partition? · 要删除成人分区里的所有内容吗？; Its categories, sources, articles, images and keys are removed from this device. This cannot be undone. · 其中的分类、来源、文章、图片和 Key 会从这台设备上移除，且无法恢复。; Delete · 删除
- The adult partition is still locked. · 成人分区仍处于锁定状态。
- The adult partition was not turned on. · 成人分区没有开启。
- Authentication is needed to open these settings. · 需要通过验证才能打开这些设置。
- Set a device passcode to use the adult partition. · 请先设置设备密码，才能使用成人分区。
- The adult partition's library could not be opened. · 无法打开成人分区的资料库。
- The adult partition's data could not be deleted. Try again. · 无法删除成人分区的数据，请再试一次。
- The system prompt's sentences: Unlock the adult partition · 解锁成人分区; Turn on the adult partition · 开启成人分区; Open the adult partition's settings · 打开成人分区的设置
- Face ID usage description: NewsPaw uses Face ID to unlock the adult partition. · NewsPaw 使用面容 ID 来解锁成人分区。

Reused: Cancel, OK, and the reason sentences of the launch failure screen.

## Failure handling

| Failure | Behaviour |
| --- | --- |
| Authentication failed, cancelled by the owner, or impossible (no passcode) | Nothing changes; the message of decision 11 for the action |
| Authentication interrupted (the app was sent away) | Nothing changes; no message |
| The adult file cannot be created when turning on | "The adult partition was not turned on."; the setting stays off |
| The adult library cannot be opened after a passed authentication (damaged, newer schema, storage) | Decision 11's message with the reason; normal partition; gate locked. Turning off with Delete remains possible, because it opens nothing |
| The scene entered the background while the prompt was shown or the workspace was loading | The result is discarded; the gate is locked |
| A lock arrives while the adult workspace is saving | The save's transaction commits or does not; nothing of it is shown; the workspace is dropped either way |
| A lock arrives while a refresh of the adult partition runs | The run is cancelled; what it stored stays in the adult library |
| A file, the keys or the cache directory cannot be removed when deleting | "The adult partition's data could not be deleted. Try again."; the partition stays on; what was removed stays removed, and a later unlock creates an empty file if the database was among it |
| The stored setting says "on" and the file is missing | `unlock()` creates an empty library |
| A gate operation is requested while another runs | Nothing happens |
| The feature switch is off | The gate is unavailable; nothing of the above is reachable |

## Assumptions

The implementer measures these on the simulator before building on them and reports each result. A7 comes first.

| Assumption | If it does not hold |
| --- | --- |
| A7. For Home, switching to another app, the app switcher, Control Centre, Notification Centre and locking the device — on iPhone, and on iPad full screen, in a window narrow enough for the tab structure, and beside another app — the scene delivers will-deactivate before it stops being in front and did-activate when it is back; which of them also deliver did-enter-background is recorded as a table | Decision 8's last point covers a way of leaving without did-enter-background. A way of leaving with no will-deactivate at all is reported to the driver before going on |
| A1. A second window shown from will-deactivate is in the app switcher's picture and covers an open sheet, an alert, a menu and the share sheet | Find the arrangement that does (for example dismissing presentations when the cover is shown) and report it; the criterion stays |
| A2. On the simulator, LocalAuthentication answers "passcode not set" or "not enrolled" without a prompt, and with Face ID enrolled from the Features menu a matching and a non-matching face give success and failure; the scene is inactive, not in the background, while the prompt is shown; the Face ID usage description is taken from the build setting and its localisation | Report what was seen; the real path is then covered by reading and by the device checks |
| A3. `DatabasePool.close()` (GRDB 7.12) returns once readers and the writer are done, later use of the object fails without touching the file, the three files can then be removed, and a library created afterwards is empty | Report it; deletion then waits for the release instead, with a bound, and fails when it does not come |
| A4. After `Workspace.stop()` and dropping the workspace, its models, its web views and the library are released within a second or two, also with the root rebuilt by `.id` | Find and remove the cycle or the task that holds them. A holder inside the framework that cannot be removed is reported; criterion 7 then names it |
| A5. Rebuilding the root by its `.id` with animations disabled while a sheet, an alert, a context menu or the browser is open dismisses them without a crash and without a view of the old workspace left on screen | Close presentations explicitly before the swap |
| A6. The accent set at the root reaches the tab bar, bar buttons, sheets, alerts and the browser's bars | Pass it where it does not reach |

## Risks

- The cover and the lock timing rest on the order of the scene's notifications, the system's snapshot and LocalAuthentication's reply. The simulator shows most of it; the device checks below are the proof.
- `Workspace` moves the wiring of the models and gives each its own navigation: a large mechanical change to `AppModel`, `RootView` and every view that reads the navigation from the environment. The existing UI suite is the guard for the normal partition; criteria 4 to 6 for the adult one.
- A leaked reference keeps the adult library's connections open after a lock. It is not shown to the interface, and criterion 7 fails when it happens in the tested paths.
- The 1- and 5-minute rules cannot be exercised by a UI test beyond the short absence; the rule is package-tested and the long absences are device checks.
- Media in the adult browser: pausing on leaving is requested from WebKit; what the system's playback controls show is a device check.

## Test plan

Package (`swift test`): the gate over a temporary directory with the stub authenticator and the in-memory key store — every state and operation of decision 2, each answer of the authenticator, the feature switch off, one operation at a time, turning on with an existing file, an unlock discarded by a lock; the store's release, reuse of a living object, `adultLibraryIsReleased`, deletion with missing parts, with a failing removal, with a damaged file and with a held reference; the lock rule table-driven; the preferences' defaults and unknown values; `KeyStore.removeAll()`; the source scan of criterion 16; a scan that the stand-in authenticator and the debug options exist only inside `#if DEBUG`.

UI tests (iterated with `-only-testing`; the whole suite once at the final commit; iPhone and one iPad): the criteria's UI rows. One long test builds the adult content and does the walk of criterion 6 after each of the three ways to lock. Existing tests are untouched in behaviour: with no answer configured the stand-in says "unavailable" and the partition is off.

Screenshots for criterion 18, and the app-switcher pictures of criterion 9.

Device checks owed (listed in the pull request, not done here): Face ID success and failure; Touch ID on the iPad mini; the passcode fallback, and whether its screen sends the scene to the background (decision 5 would then discard the unlock); the order of LocalAuthentication's reply and the scene becoming active; the app-switcher snapshot, with a sheet open and with the keyboard up; each lock timing, on iPhone and on iPad in a window and beside another app; the cover under Control Centre and Notification Centre; nothing adult visible after a timed lock; a video in the adult browser: paused on leaving, no Picture in Picture, nothing in the Lock Screen's playback controls; a device without a passcode.

## Handoff notes

- RD19: a `LibraryModels` and `KeychainKeyStore` for the adult library inside its workspace; the adult browser's own persistent data store and Clear; the remaining S10 rows; moving a category needs the gate unlocked; Delete must also remove the adult browser data.
- RD20: export with the adult partition is enabled only while unlocked; import asks the gate; the two device settings are not exported. A second caller of `LibraryModels` must not race the interface's operations (RD13 review R3).
- RD24: background collection of adult sources opens the adult library through the store inside the package, never through the interface; it may share the living object with the interface (the store's reuse) and must not keep it past its run (criterion 7).
- RD21: search runs on the shown workspace's library only.

## Revision record

Version 2 after debate round 1 (one fresh critic; 12 findings; code read at d91d8ce and 35d0992, GRDB 7.12 read, one SQLite experiment on macOS on stale `-wal` files; no simulator used). All admitted:

| # | Sev. | Finding | Change |
| --- | --- | --- | --- |
| D1 | P1 | One shared `NavigationModel`: a `reload()` of the workspace not shown (the normal one keeps refreshing) empties the other partition's path or closes its sheet (`SourceModel.reload`, `NavigationModel.sourcesChanged`) | Each workspace owns its navigation (decision 3); a `ModelSettingsModel` per workspace; criterion 5 |
| D2 | P1 | The lock rule assumed every way of leaving delivers did-enter-background; RD10 measured an iPad window that stays `runningForeground` after Home | "Away" starts at will-deactivate; A7 measured first; decision 8's fallback for "immediately"; "For the owner" 3 reworded |
| D3 | P2 | The system's prompt deactivates the scene; "no longer active" would discard every real unlock; a background event during the load, or the adult workspace shown while inactive, slipped through | Discard only on did-enter-background, checked in the step that shows the workspace (decision 5); the cover's one rule applied at three moments (decision 12); UIKit notifications only (decision 8); the stand-in that waits for inactive and active (decision 15); device checks named |
| D4 | P2 | Two `RefreshModel`s each copied the global refresh settings; the normal one would clean up with a stale retention | One shared settings object (decision 3); criterion 15 |
| D5 | P2 | Delete waited for the release, its questions lived in a screen the lock destroys, gate operations could interleave, and after Keep Data Hidden a damaged file made turning on fail with Delete out of reach | Explicit close (decision 9, A3); questions and result at the root, asked before locking; one gate operation at a time; `turnOn()` does not open an existing file |
| D6 | P2 | Settings › Adult Partition opened from the normal partition stayed open, and so authenticated, across any absence | Popped by the lock rule (decision 10); in criterion 8 |
| D7 | P2 | Ending a browser session does not stop a page; media could go on over the cover or in Picture in Picture; nothing checked that the web view is gone | Web views released on lock and reported by the debug element (decision 4, criterion 7); Picture in Picture off and media paused on leaving (decision 13); device checks |
| D8 | P2 | Removing the cover in the step of the timed lock could show a frame or an animated dismissal of adult content | Swap with animations disabled; cover hidden one main-loop turn later (decisions 4, 12); the check by hand in criterion 9 |
| D9 | P3 | On pushed screens the partition is told by colour alone and cannot be locked by hand; the draft presented that as what ux says, while ux section 6 says otherwise | Put to the owner as a question with the alternative ("For the owner" 4) |
| D10 | P3 | An open-ended audit left to the implementer inside a frozen contract; pieces made unnecessary by D1 and D5 | The list is written into decision 14; the wait, the open-and-close at turning on and the re-pointing of hooks are gone |
| D11 | P3 | Chinese wording left to the implementer; the prompt's sentences missing and owed by the package; the usage description's localisation outside the strings check; an alert after a system cancel | Strings written here; the reason passed in by the app; `InfoPlist.xcstrings` and its evidence named (criterion 17); "interrupted" shows nothing (decision 11) |
| D12 | P3 | "Sidebar selection set to its launch default, tab kept" contradicted itself; the list on screen after a return was a stale snapshot; the away time could be overwritten; criterion 1's directory check had no mechanism; a thumbnail store ending late could recreate the cache directory | "Tab kept, paths empty", the list entered (decision 3); first will-deactivate kept (decision 8); the debug element reports the file (criterion 1); the cache directory removed last (decision 9) |

Not re-reviewed after these changes. Not measured by anyone yet: everything in the Assumptions table.

## Post-implementation record

Added by the implementer on 2026-11-15, after the assumptions were measured. The text above is the frozen design and is unchanged; where this section differs from it, this section is what was built. Evidence is in the run's evidence directory (`rd18/assumptions.md`, `rd18/a4/`, `rd18/probe-logs/`).

### Assumption A4 as measured: UIKit keeps the adult views' environment after a lock

Measured on the iPad simulator (iOS 27.0) with the design's debug element and `leaks <pid> --trace=<the adult BrowserModel>`, with the design as frozen (the store holding the adult library weakly after a lock):

| Path in the adult partition before the lock | The library object and the browser model object after the lock | Holder |
| --- | --- | --- |
| Lists, sheets and the browser only (also with the browser on a page and a sheet open at the lock) | Gone within 1 to 4 seconds | none |
| Any menu used (a row's context menu, a toolbar menu, and therefore choosing "Normal" in the partition switch); the same with the app's animations on | Held at 40 seconds, gone by 75 seconds | An `NSTimer` of UIKit's `-[_UIMenuPresentationSourceSceneComponent scheduleClearPresentationSourceForSource…]` holds the `_UIMenuPresentationSource`, whose `_sourceView` holds SwiftUI's list coordinator and with it the views' environment |
| An article opened (the reading screen has selectable text), or a row starred by a swipe | Still held at 90, 150 and 240 seconds; not seen to end | `UIKeyboardImpl.m_markedTextOverlay._cachedTraitCollection`, and in another run `_UISystemBackgroundView._cachedTraitCollection` of bar buttons: a `UITraitCollection` whose custom trait `SwiftUIEnvironmentWrapper` is SwiftUI's environment |
| On the iPhone simulator (tab structure), the simplest path: the adult Today screen shown, then the lock button | Held at 3 and at 73 seconds; not seen to end | `_UIRefreshControlModernContentView._cachedTraitCollection` (the pull-to-refresh control of the Today screen): the same kind of trait collection |

The `Workspace` object was gone at once in every run: the app's own objects have no cycle. What is kept is UIKit's: it caches trait collections, each trait collection carries the whole SwiftUI environment of the view it came from, and the environment holds the models, which hold the library. The app has no public way to empty those caches. After the lock nothing of the adult partition is on screen or in the accessibility tree (checked by a dump of it), and the gate is locked.

### Decision 4, as built: the adult library is closed at every lock

By the driver's decision of 2026-11-15, in place of "the store then holds the adult library only weakly … an unlock while the old object is still alive gets that same object back":

- `AdultGate.lock()` has the store **close the adult library's connections explicitly and forget the object** (`LibraryStore.closeAdultLibrary()`). Deleting the partition's data closes by the same function; there is one closing path.
- The close waits for the one read and the one write in flight and for nothing else (GRDB's `DatabasePool.close()`; measured in `AdultLibraryCloseTests.closeWaitsForWhatIsInFlight`). It has no time limit of its own: its bound is the transaction in flight, and each of the app's transactions is one short group of statements. If a write did not end, the close would not return: the interface has already swapped to the normal partition and the gate already answers "locked" before the close is asked for, so nothing adult is shown or given out meanwhile; the file stays open until the write ends, and an unlock asked for meanwhile authenticates and then waits for the store. A write that was in flight is committed; one that had not started fails.
- Every later use of a reference that something still holds fails with `LibraryError.storage` and touches no file. The next unlock opens a new pool on the file, with the data as the last committed write left it. There are never two open pools: a pool that could not be closed stays the store's and is the object the next unlock gets.
- `Workspace.stop()` runs before the close and cancels the refresh run, the source detection, a running model test and the browser sessions. A save that was queued is not cancelled; it runs into the closed library and fails. A stopped workspace's models raise no alert for anything (`CategoryModel` and `SourceModel` refuse to show "The change could not be saved." once stopped), and the app writes no log, so such a failure surfaces nowhere (`AdultGateTests.keptReferenceFailsQuietly`; UI test `testASaveOverrunByALockFailsQuietly`).
- One operation at a time still holds for the gate's other operations. `lock()` is never refused, as before.

### Criterion 7, reworded

> After locking — by the button, by choosing Normal, by the timing rule — and whatever was done in the adult partition before it (lists only; a menu used; an article opened; a row swiped; a refresh running; a sheet and the browser open), the adult library's connections are closed and the adult workspace object is gone. The library object and the browser model object are gone from memory where UIKit does not keep the views' environment (lists, sheets, the browser); where it does, the holder is named.

Evidence: package tests of the store and the gate (closed at once although a reference is held; the held reference fails; the next unlock is a new pool); UI tests through the debug element, whose report is now `file=<0|1> pool=<open|closed> library=<held|released> workspace=<none|held|released> browser=<none|held|released>` — `pool=closed` and `workspace=released` are asserted after every lock on every path and on both structures; `library=released` and `browser=released` are asserted on the paths of the table's first row on the panes (iPad), and recorded everywhere else: on the tab structure (iPhone) no path was found on which UIKit lets go of them.

### Assumption A5 as measured, and decision 12 as built: the cover waits for the swap

Criterion 9's check by hand was done as a recorded run on both simulators (iOS 27.0) with the app's animations on: "After 1 Minute", the adult category's settings sheet open, Home, 64 seconds, back. With the design as frozen (the cover hidden one main-loop turn after the swap at did-activate) the recording showed adult content after the cover had gone:

| Simulator | What the frames showed after the cover went | For how long |
| --- | --- | --- |
| iPad Pro 11-inch | the adult list's title with the sheet over it, for two frames; then the normal list with the adult sheet ("Category Settings", the name field reading the adult category's name) still over it | about 0.25 s |
| iPhone 18 Pro Max | the adult sheet, full screen | about 0.3 s |

So assumption A5 does not hold with animations on: SwiftUI draws the other shell a frame or two after the change, and UIKit takes a sheet of the dropped shell away about a quarter of a second after it, without animating it. Under the UI tests, where the app's animations are off, none of this is seen.

What was built, in place of "hidden at did-activate, one main-loop turn after decision 8's check and any swap it caused":

- While the adult workspace is still the one shown, the cover is hidden one main-loop turn after did-activate, as designed.
- After a lock under the cover — by the rule at did-activate, or earlier in the background — the cover is hidden only once the swap is on screen: the root view has reported that the normal workspace's shell appeared, no window of the app presents a view controller any more, and both have held for three frames. If that has not come after 2 seconds (never seen), whatever the app's windows still present is dismissed without animation and the cover is hidden then, so that the cover cannot stay for good.
- The table's remedy for A5, "close presentations explicitly before the swap", was not what was built: closing them through SwiftUI is not done in the step of the swap (decision 4 wants one step with no suspension), and the swap's own late frame needs the cover to wait in any case. Every lock with an adult sheet, dialog or menu open happens under the cover: the lock button and the partition switch cannot be reached while one is open.
- The recorded check was repeated after the change, on both simulators, in four forms: the timed lock with the sheet open; "Immediately" with the sheet open (the lock happens in the background); the timed lock with a context menu open on the adult category; the timed lock with the system's share sheet open over the adult browser. In all eight recordings every frame after the return shows the system's picture of the cover, the cover, or the normal partition (`rd18/screenshots/criterion9-transition/`).
- What the condition counts: the windows of the app's one window scene except the cover's own, and for each whether its root view controller presents a view controller. At the check those windows were the app's window and the system's text-effects window, which presents nothing. The system's authentication prompt is not in the app's process and cannot be asked for under the cover. In every run the wait ended by the condition, never by the bound.
- What can still be presented when the bound is reached: only something of the dropped adult shell. Entering the adult partition clears the normal workspace's navigation and its shell is not in the view hierarchy while the adult one is shown; after the swap the normal shell is built at the root from that cleared state and nothing is restored; under the cover no touch reaches the app; of the root's own alerts, the question of turning off is closed by the lock rule (below), and no sentence can be up while the adult workspace is shown. The share sheet over the adult browser is the adult shell's, and UIKit removed it with the shell.
- How long the cover stays after did-activate, measured with a logging copy of the app, animations on, one run each:

  | What was open at the lock | iPhone 18 Pro Max | iPad Pro 11-inch |
  | --- | --- | --- |
  | Nothing; the lock happened in the background ("Immediately") | 57 ms | 57 ms |
  | Nothing; timed lock at the return | 142 ms | 85 ms |
  | An adult sheet; timed lock | 410 ms (UIKit removed the sheet at 354 ms) | 358 ms (at 305 ms) |
  | The system's share sheet over the adult browser; timed lock | 768 ms (removed at 710 ms) | 528 ms (at 469 ms) |

  With nothing open the condition already held at the first check; the time is the three checks, with the main thread building the normal shell between them. The owner sees the logo for about a tenth of a second after the system's opening animation ends.
- The check by hand stays the only evidence for this: the UI tests run with the app's animations off and see no frames, so they cannot show it either way.
- Device check owed, added to the design's list, and to be listed in the pull request: return after a timed lock with a sheet open, with animations on, on a real iPhone and a real iPad — nothing of the adult partition may be seen once the cover goes.

### Decision 10, added: the question of turning off closes with the screen

The questions of turning off are presented at the root so that they outlive the swap (decision 9). A question left open when the app is left was therefore still there after a lock by the rule, in the normal partition, and could be answered — Keep Data Hidden or Delete Data — with no new authentication. The lock rule now closes an open question together with the screen that asked it, in both partitions (UI test `testSettingsScreenOfTheNormalPartitionClosesByTheLockRule`).

### Known limits

- A model object that UIKit keeps after a lock still holds what it had loaded: the category and source summaries, the rows of the lists that were read, the articles that were opened. That is memory of the same process; nothing shows it, and it is not emptied. It goes when UIKit lets go of the trait collection or the menu's source view: after about a minute for a menu, and not within the four minutes measured for an opened article or a swiped row.
- Whether the browser model object, and with it the workspace's other model objects, is released after a lock is outside the app's control on those paths. Its sessions are ended and its web views are taken out of the view tree and released by `stop()` in every case.
- Assumption A7: in an iPad window that is not full screen, Home delivers no scene notification at all; the app neither shows the cover nor locks until another app is opened, the device is locked or Notification Centre is opened fully (`rd18/assumptions.md`, with what stays visible in the strip).

### Handoff notes, added

- RD24: background collection of adult sources can no longer share a living library object with the interface across a lock. A lock closes the pool under whatever holds it, so a run that is collecting when the partition locks has its later reads and writes fail. RD24 decides whether a lock waits for a run or cancels it, and opens the adult library for itself through the store.
- RD19: Delete closes by the same path as a lock; removing the adult browser's own data store joins it there.
