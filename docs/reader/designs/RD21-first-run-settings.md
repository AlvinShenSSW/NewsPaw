# RD21 — First run and the remaining Settings

Issue: [#142](https://github.com/AlvinShenSSW/NewsPaw/issues/142) · Epic E16 #119 · Priority P1 · Requirements N01 (works without a key), N02 (suggested categories); ux S12, S8. Also touched: ux S1 (the empty state "first run with no sources"), S3 (the row mark), spec section 4 (setting kinds).

Version 2 (2026-11-16), after one debate round. Written against `main` at `8a6281c`, the RD14 worktree at `a6e2254` (not merged; read only), and the frozen RD08 design (version 2). Author: Claude (planner, for the driver of this AFK run).

**Dependencies.** RD05 and RD13 are merged. RD21 is implemented after RD14 merges, because the baseline needs RD14 here: step 1 sets RD14's reading language, the issue asks for "titles translating" at the end of the first run, and N01's message in lists is RD14's row mark. RD08, RD17 and RD20 do not block it.

The owner's instruction for this phase (2026-11-12): one user, converge, no over-engineering. This issue is mostly interface, and the design is sized to match.

## Spec review

**Baseline.**
- ux S12: "Three steps, each skippable: 1. Reading language (preselected from the system language). 2. A model for the normal partition: preset, key, Test. A note says what is sent to the service: titles and article text. 3. Sources: Suggested sources, Paste an address, Import configuration / OPML. It ends on Today."
- N02: "First launch offers a set of suggested normal categories (World, Japan, Australia, China, Tech, AI), all optional. The adult partition has no preset categories or sources."
- N03 and S6: a source is added by detection, category, preview and save, and suggested sources are "offered only while adding". S12's step 3 is S6's address step.
- N01: "Places that would show a translation or an overview say that no model is set up and link to the setting." The issue repeats it for "everywhere a translation would appear".
- ux S1: "First run with no sources: an empty state with 'Add a source' and 'Import configuration'." ux S8 About: "Version, licences"; the issue: "About lists the licence of every bundled library, including the Readability script."

**Settings inventory (ux S8).** Only the rows marked RD21 are this issue's.

| Row | Setting or item | Kind (spec 4) · storage | Built by / owned by |
| --- | --- | --- | --- |
| Models & translation | Reading language; translate titles automatically; show original titles | Global · Preferences; applies at once | RD14 (`Settings/ModelsView.swift`, `AppState/TranslationSettings.swift`) |
| | Translate the body when an article opens | Global · Preferences | RD15 |
| | Normal primary and backup slots | Partition data · normal library; keys in the keychain | RD13, merged (`Settings/ModelsView.swift`, `ModelSlotForm.swift`) |
| Refresh | Interval; retention | Global · Preferences; next entry | RD06, merged (`RefreshSettingsView`, `Destinations/SettingsView.swift`) |
| | Background refresh | Global · Preferences | RD24 (M2) |
| Reading | Text size, line spacing, typeface | Device · Preferences; applies at once | RD11, merged (`Reading/ReadingSettingsView.swift`) |
| | Default display mode | Device · Preferences | RD15 |
| Adult partition | On / off, lock timing, turn off | Device · Preferences | RD18, merged (`Settings/AdultPartitionView.swift`) |
| | Adult slots, thumbnails, daily limit, clear browsing data | Partition · adult library | RD19 (limit screen with RD17) |
| Data | Image cache size and Clear | — | RD09, merged (`DataSettingsView`) |
| | OPML import / export; configuration export / import | — | RD08; RD20 |
| Usage | Requests and tokens; daily automatic limit | Partition · `setting` | RD17 |
| About | Version | — | RD03, merged (`AboutView`) |
| | **Licences** | — | **RD21** |
| — | **First-run flag** | **Device · Preferences `first_run_done`** | **RD21** |

RD21 builds the two rows marked RD21 and, beyond S8, the first run (S12) with the suggested categories (N02), Today's no-source empty state (S1; RD09 did not build it) and N01's message in lists.

**Code today.** A launch shows the shell on Today; an empty Today says "Nothing new today". Add source offers the eleven suggested feeds under the six category names (`SuggestedSourceGroup`, localised: 世界, 日本, 澳大利亚, 中国, 数码, AI). About shows the version. The package excludes Readability's `LICENSE`, which is only the project's Apache header. RD14's `TranslationModel.mark(for:)` hides the mark for one reason: `if let block = blocked[row.id], block != .setUp(.noModelSetUp)`, recorded as "nothing nags".

**Contradictions and gaps, with defaults.**
1. *N01 against RD14.* An article list is a place that would show a translation (N05 rows), so N01 and the issue require it to say that no model is set up and link to the setting. This overrides RD14's "nothing nags". Default: RD14's own mark and alert, the form ux S3 and N06 draw (decision 7). One line at the top of each list is the owner's alternative.
2. *Issue criterion "each Settings row of ux S8 leads to a working screen".* Usage (RD17) and Data's import, export and OPML rows (RD20, RD08) may not exist when RD21 merges. Default: RD21 walks the rows that exist; whichever of RD21, RD17, RD20, RD08 merges last verifies the full list, and RD22 again.
3. *Issue criterion "nothing in it mentions or creates the adult partition" against N10*, which asks to turn the adult partition on when an imported file holds it. Decided by the driver for RD20 and RD21: an import started from the first run brings the normal partition only, asks nothing about the adult partition, and its summary says in one line that the file's adult partition was not imported and can be imported from Settings › Data (RD20: an origin flag on its import). The criterion holds as written; that line, shown only when the owner's own file has an adult part, is the only mention.
4. *Where the suggested categories go.* S12 has no category step and more onboarding is out of scope: step 3, beside "Add a Source…".
5. *The first-run key* is not in section 4: a device setting plus the library's content (decision 2).
6. *Licences.* Apache 2.0 §4(a) asks for a copy of the licence and MIT for its notice: About shows the full texts.
7. *Not added:* an image-cache limit control (section 4 lists the limit as a device setting; S8 has no row; the code uses 500 MB) and clearing the normal partition's browsing data (RD10's handoff; N09 asks for it in the adult partition only). Both go to the owner.

## Acceptance criteria

1. When the flag is absent and the normal library's categories load and are empty, the shell shows the first run in place of its containers (no tab bar, sidebar or partition switch), on iPhone and both iPads in both orientations: Reading Language, Translation Model, Sources, each with "Step N of 3" and Skip; Back on steps 2–3.
2. Step 1 preselects the reading language by decision 4; Continue stores it globally; Skip stores nothing.
3. Step 2 shows decision 5's note and a "Primary Model" row with RD13's state. The row pushes RD13's unchanged form; Save or Cancel returns to step 2 with the state updated. Continue and Skip go on.
4. Step 3 lists the six suggested categories with their icons, all off. Ticked rows are created, localised name and icon, when "Add a Source…" or Done is tapped; a created row, or one whose name an existing category has, shows "Added" and cannot be unticked. A failed creation shows the category model's alert and the first run stays.
5. "Add a Source…" opens S6 with its suggested sources; "Import OPML…" is present when RD08 has merged, "Import Configuration…" when RD20 has.
6. The first run ends on Today (tab or sidebar item). If the library has a feed-like source, a library refresh starts at once; with the fixture model saved in step 2 and BBC World added in step 3, World's titles appear translated.
7. Skipping every step ends on Today with "No sources yet" and "Add a Source"; a fixture feed added through it opens an article showing the original.
8. `first_run_done` is written when the first run ends, and at a launch that finds it absent while a category exists. A relaunch after completing, after skipping, or after an interruption that created a category shows the shell; after an interruption that created none, the first run again. A failed category read shows the shell.
9. The first run's screens name no adult partition, and afterwards the adult file does not exist (RD18's report `file=0`). The adult partition's first opening shows no first run, Today shows "No sources yet", and its Add source has no Suggested Sources row. When RD20 has merged: a fixture configuration file holding both partitions, imported from step 3, imports the normal part, asks nothing about the adult partition, leaves `file=0`, and its summary shows the one line of contradiction 3.
10. With no normal model, foreign rows of a source that translates automatically show RD14's warning mark; tapping it says "Set up a model to translate" with "Open Settings", which opens Models & Translation; after a primary is saved, the marks go and the titles translate. The adult partition shows no mark.
11. About shows Version and Licences — GRDB.swift (MIT), SwiftSoup (MIT), Readability (Apache 2.0) — each opening its full text, Readability's with the whole Apache License 2.0. A package test fails when a `Package.resolved` pin has no notice.
12. Every Settings row present at merge opens a screen with its title (one UI test walks them); missing rows are named in the pull request with their issue.
13. Every new string has Simplified Chinese; the three `AGENTS.md` checks pass.
14. Screenshots of steps 1–3, Today's empty state, the no-model alert, About and one licence — default size, dark, Simplified Chinese, largest accessibility size — on the iPhone 18 Pro Max and the iPad mini (portrait); step 3 also on the iPad Pro 11-inch in landscape.

## Frozen issue contract

**In.** The first run (S12) with the suggested categories; Today's no-source empty state (S1); the change to RD14's mark condition; About's licences; the flag; "Import OPML…" in step 3 if RD08 has merged at implementation (expected); "Import Configuration…" in step 3 and S1 if RD20 has; one sentence each in spec section 4 (the flag is a device setting) and ux S12 (step 3 offers the suggested categories).

**Out.** Usage (RD17); translation settings (RD14); the body switch and default display mode (RD15); background refresh (RD24); OPML (RD08); the configuration file (RD20); adult settings (RD19); the "no model" states of the reading body (RD15), the browser (RD16) and overview cards (RD23); a bulk add of suggested feeds, a welcome page or tour, re-running the first run, an image-cache limit control, clearing the normal partition's browsing data.

**Other issues own.** RD20: if RD21 merges first, the configuration rows in step 3 and S1; the first-run origin of an import (contradiction 3); never exporting `first_run_done`. The driver carries this into RD20's design. RD19: the adult translation model, and with it the mark there.

**Invariants.** The first run is shown only on the normal workspace and never touches the gate. No new package write path, no dependency change, no `@testable import` in the app; debug seams under `#if DEBUG`. RD13's form and `ModelSettingsModel` are unchanged.

## Assumptions

| Assumption | Measured first by | If it fails |
| --- | --- | --- |
| A1. RD14 is merged with `TranslationSettings`, `ReadingLocale`, `TranslationModel.mark(for:)` and `navigation.openModelSettings()` as read at `a6e2254` | Reading `main` at dispatch | Stop and report |
| A2. RD13's form, pushed on `settingsPath` from the first run's stack, saves and pops back to step 2 | Step 2 with the fixture model host | Report before building step 3 |
| A3. `-AppleLanguages (ja)` in a UI test reaches `Locale.preferredLanguages` | Step 1's UI test | Cover the rule by its package test only and say so |
| A4. GRDB's and SwiftSoup's `LICENSE` at the pins are MIT; Readability has no `NOTICE` at tag 0.6.0 | The checkouts at the pins and the tag | Ship a `NOTICE` with its licence; report another licence |

## Approach

1. **Where it lives.** A branch of `ShellView`'s content switch, after `width == 0` and before the containers: `else if model.showsFirstRun { FirstRunView() }`. The shell's sheet, dialogs, `sheetDismissed()`, RD14's `translationDialogs()`, RD20's root modifier, `navigation.layout` and `shellDidAppear` apply unchanged. `AppModel.start()` sets `showsFirstRun` once the normal workspace has loaded: flag absent and `CategoryModel` loaded with no category; flag absent with a category → write the flag, show nothing. On iPad the content is at most 640 pt wide, centred. Under a UI-test library directory it appears only with `UITestLaunchKey.firstRun = 1`, so existing suites are unaffected.

2. **The flag.** `Preferences.firstRunIsDone` (`first_run_done`; anything but `true` reads as not done): a device setting, per device, never exported, restored with the libraries from a device backup. Second launch → shell on Today. Interrupted → shown again only with no category (step 2 then shows the saved slot). Upgrade or restore over a library with content → written silently (restored slots read "Key needed", RD13). App deleted → libraries and preferences go together, so a first run. Deleting every category later never brings it back.

3. **Steps.** `FirstRunView` is one `NavigationStack(path: $navigation.settingsPath)` with `.navigationDestination(for: SettingsRoute.self) { SettingsDestination(route: $0) }`, as in `TabContainer` and `PaneContainer` (whose stacks are not in the hierarchy meanwhile). The step changes the root content in place. Each step: title, "Step N of 3", Skip at the bar's trailing end, Back on steps 2–3, and a bottom primary button (Continue; Done on step 3) with the on-accent label (RD03). Step 1 shows the NewsPaw logo.

4. **Step 1.** RD14's languages as an inline picker, preselected by a package function `ReadingLocale.preselected(from: Locale.preferredLanguages)`: `zh…` → Simplified Chinese, `ja…` → Japanese, `en…` → English, else the standard (Simplified Chinese). Continue sets `TranslationSettings.readingLocale`.

5. **Step 2.** Note: "Titles, excerpts and article text, and the text of pages you translate, are sent to this service. The key stays on this device. You can skip this and set it up later in Settings." (wider than ux's "titles and article text": N06 sends page text). One row, "Primary Model", with `ModelWording`'s state, pushing `.modelSlot(.primary)`: RD13's form, its Cancel question and Save are unchanged, and Save pops back. A slot saved stays saved whether the owner continues or skips.

6. **Step 3.**
   - *Suggested Categories:* six rows in `SuggestedSourceGroup` order, each one button with the selected trait; name from `String(localized:)` on the catalog's keys "World" … "AI"; icon from a new `SuggestedSourceGroup.icon` (World `globe`; Japan, Australia, China `globeAsia`; Tech `laptop`; AI `cpu`, as the mock-up's AI card). Ticked rows are created through `CategoryModel.createCategory(name:icon:)` (its serial queue) when "Add a Source…" is tapped — so Add source's picker offers them — or at Done, whichever is first.
   - *Add Your Own:* "Add a Source…" (`SourceModel.beginAddSource()`; the shell's sheet shows S6 with Suggested Sources, Paste and its import rows); "Import OPML…" and "Import Configuration…" call RD08's and RD20's entries when merged.
   - The adult guard is already structural: `Library.suggestedSources` is empty outside the normal library (`Library+Sources.swift`), and the first run runs only on the normal workspace.

7. **N01 in lists, default (a).** In RD14's `ios/NewsPaw/AppState/TranslationModel.swift`, `mark(for:)`: `if let block = blocked[row.id], block != .setUp(.noModelSetUp)` becomes `if let block = blocked[row.id]`, and the comment "A library with no model set up shows no mark." goes. The rest exists: the translator blocks a set-up pause's articles, including rows asked for while it lasts; RD14's alert maps every `.setUp` block to "Set up a model to translate" with "Open Settings" (`TranslationWording.steps`, `TranslationSteps.take` → `openModelSettings()`); saving a slot ends the pause and resumes. Only foreign rows of automatically translated sources are marked. The adult workspace has no `TranslationModel` until RD19, so no mark there. Version 1's line, and the trigger questions it raised, are gone.

8. **Ending.** `AppModel.finishFirstRun()`: write the flag; `normal.navigation.showAtRoot(of: .today, layout: nil)` (clears `settingsPath`, the sheet, and whatever "Show in Library" set); `showsFirstRun = false`; if `sources.hasFeedLikeSource`, `refresh.refresh(.library)` — the launch's entry refresh ran on the empty library and recorded its time (RD06). RD14 translates the new titles when that run ends.

9. **Licences.** Package: `Notices/` (new resource directory) with `GRDB.swift-LICENSE` and `SwiftSoup-LICENSE` verbatim from the pinned checkouts and `Apache-2.0.txt` verbatim from apache.org; `Reading/Resources/LICENSE` leaves `exclude:` and is copied as a resource. `Model/ThirdPartyNotices.swift` lists identifier, name, licence name, project address as text, and text (Readability: its notice, a blank line, the Apache text), with provenance (source, revision or tag, SHA-256) in a comment. App: About gains "Licences" (footer "NewsPaw is built with these open-source libraries."), rows pushing `SettingsRoute.licence(id)`: scrolling, selectable `Text(verbatim:)`, not localised.

10. **Today's empty state.** No source at all → `EmptyStateView` titled "No sources yet" with the action "Add a Source" (`beginAddSource()`), plus "Import Configuration" if RD20 has merged; with sources and nothing unread, "Nothing new today" as now. The identifier `todayEmpty` stays on the title; the button has its own.

## Files to change

| Path | Change |
| --- | --- |
| `NewsPawKit/Sources/NewsPawKit/Model/Preferences.swift` | `firstRunIsDone` |
| `NewsPawKit/Sources/NewsPawKit/Model/Translation.swift` (RD14's) | `ReadingLocale.preselected(from:)` |
| `NewsPawKit/Sources/NewsPawKit/Feeds/SuggestedSources.swift` | `SuggestedSourceGroup.icon` |
| `NewsPawKit/Sources/NewsPawKit/Model/ThirdPartyNotices.swift`, `Notices/*` | new |
| `NewsPawKit/Package.swift` | resources: `Notices`; Readability's `LICENSE` out of `exclude:` (lock files untouched) |
| `NewsPawKit/Tests/NewsPawKitTests/**` | package tests below |
| `NewsPaw/AppState/AppModel.swift`; `Navigation/RootView.swift` (`ShellView`); `FirstRun/*.swift` (new) | decisions 1–6, 8 |
| `NewsPaw/AppState/TranslationModel.swift` (RD14's) | decision 7 |
| `NewsPaw/Destinations/TodayView.swift` | decision 10 |
| `NewsPaw/Destinations/SettingsView.swift`, `Settings/LicenceView.swift` (new), `AppState/NavigationModel.swift` | About; `.licence` route |
| `NewsPaw/AppState/DebugLaunchOptions.swift`, `UITestIdentifiers.swift`, `Localizable.xcstrings` | launch key, identifiers, strings |
| `NewsPawUITests/FirstRunTests.swift`, `FirstRunScreenshotTests.swift`, `SettingsRowTests.swift` (new); `TranslationTests.swift` (RD14's) | UI tests |
| `NewsPawUITests/PaneStructureTests.swift` | only if its 30 pt centring check of `todayEmpty` (`:93`) fails with the button below the title: centre title and button together |
| `docs/reader/spec.md` (section 4), `docs/reader/ux.md` (S12) | one sentence each |

**Existing tests on `todayEmpty`.** The identifier stays on the title, so none changes: `TabStructureTests:98`, `SlideOverTests:31, :101`, `ScreenshotTests:60`, `AddSourceTests:443, :445`, `RefreshTests:32, :40, :373`, `PaneStructureTests:54, :92–93`, `ArticleListTests:236, :248, :271–272`. Only `ArticleListTests:272` reads the label, in a library with sources, where it stays "Nothing new today" (as at `RefreshTests:40`, a web-page source).

## Execution surface

- **Written:** the paths above. **Executed:** `swift test`; `xcodebuild build-for-testing` / `test` with `-derivedDataPath`; `python3 ios/Tools/check_strings.py`; `xcrun simctl`.
- **Read once by hand:** the checkouts' licence files at the pins, and the Apache text (one request, SHA-256 recorded).
- **Tests make no network request:** fixture transport, RD14's fixture model host, RD05's fixture answer for BBC World.
- **Not touched:** dependencies, both `Package.resolved` files, `.afk/`, the owner's key file.

## Failure handling

| Situation | What happens |
| --- | --- |
| Category read fails at launch | Shell (RD03's failure path); no first run; flag not written |
| A category creation fails in step 3 | `CategoryModel`'s alert "The change could not be saved."; step 3 stays |
| Model save, Test or Load List fails | RD13's alert or line, in the pushed form |
| The app is killed during the first run | Flag absent; shown again only if no category exists |
| "Show in Library" from Add source during the first run | Closes the sheet; the ending's `showAtRoot` replaces what it set |
| A notice missing from the bundle | Caught by the package test |

## Risk assessment

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| Existing UI tests start seeing the first run | Low | High | Opt-in launch key; the whole suite once at the final commit |
| Marks on every foreign row feel like nagging to an owner without a key | Medium | Low | Turning automatic title translation off hides them; option (b) offered |
| `settingsPath` shared by the first run and the Settings stacks | Low | Medium | Only one is in the hierarchy; `showAtRoot` clears it at the end |

## Test plan

**Package.** `firstRunIsDone` absent, `true`, not a truth value. `ReadingLocale.preselected(from:)` for `zh-Hans-CN`, `zh-Hant-TW`, `zh-HK`, `ja-JP`, `en-GB`, `de-DE`, empty. `SuggestedSourceGroup.icon` for every case. `ThirdPartyNotices`: identifiers equal `Package.resolved`'s pin identities plus `readability`; texts non-empty; the MIT texts contain "Permission is hereby granted"; Readability's contains the Arc90 notice and "Version 2.0, January 2004". **Planted failure:** the check is a function over the file's contents; a copy with one extra pin fails it.

**UI tests** (fixtures only; iPhone 18 Pro Max, iPad mini, iPad Pro 11-inch).
- *Complete path:* step 1 with `-AppleLanguages (ja)` shows Japanese; step 2 → Primary Model → fixture host, key, Test passes, Save, the row shows "Passed"; step 3 → tick World → Add a Source… → Suggested Sources → BBC World → World → Save → Done; Today; World's titles fixture-translated; Models & Translation shows Japanese.
- *Skip path:* Skip ×3; "No sources yet"; Add a Source with the fixture feed; an article shows the original.
- *Step 3:* tick and untick; a ticked row becomes "Added" after Add a Source… and stays; with the debug save failure on, Done shows the alert and stays.
- *Keying:* relaunch after completing and after skipping → shell; terminated after a category was created → shell; before → first run again.
- **Planted failure, "the first run mentions or creates no adult partition":** adult feature on, both paths: no element of the first run has a label containing "Adult" or "成人", no partition switch, RD18's report `file=0` afterwards. When RD20 has merged: criterion 9's two-partition file from step 3.
- *Adult first opening:* turn on and unlock: no first run, "No sources yet", no Suggested Sources row.
- *No model:* foreign rows marked; the alert's "Open Settings" lands on Models & Translation; after saving the fixture primary the marks go and titles translate. **Planted failure, "never in the adult partition":** an adult category with foreign rows shows no mark.
- *Settings walk:* every present row opens its screen; About's three rows open texts containing "Copyright".
- *Screenshots:* criterion 14.

**By hand:** step changes and the pushed form with animations on; VoiceOver on step 3. **Real-device list (RD22):** the first run after a fresh TestFlight install; a TestFlight upgrade over a library with content shows none.

## Handoff notes

- **RD20.** If RD21 has merged, add "Import Configuration…" to step 3 and Today's empty state. An import started from step 3 carries the first-run origin: normal partition only, no adult question, and one summary line that the file's adult partition was not imported and can be imported from Settings › Data. An import from Today's empty state is outside the first run and follows N10. Never export `first_run_done`; an import neither sets nor clears it.
- **RD19.** The adult `TranslationModel` brings the mark to the adult partition; its "Open Settings" should open Settings › Adult partition.
- **RD15** (body banner) and **RD16** (browser line, no link in the adult partition until RD19) agree with decision 7. RD15's premise "RD14 decided lists show nothing" no longer holds; nothing in RD15 depends on it.
- **RD17, RD20, RD08.** Whichever merges last re-walks every S8 row; RD22 checks the full list.

## For the owner

1. **"No model set up" in lists — the one open question.** Default (a): a foreign title in a source that translates automatically shows a small warning mark; tapping it says "Set up a model to translate" with "Open Settings". The marks go once a model is saved, or when "Translate Titles Automatically" is off. This is the form ux draws, and it replaces RD14's "nothing nags". Alternative (b): one line at the top of each article list.
2. **A configuration import from the first run brings the normal partition only** (decided). If your file also holds the adult partition, nothing about it is asked or created; the summary says in one line that it was not imported and can be imported from Settings › Data.
3. **Suggested categories start unticked**, are created when you tap "Add a Source…" or Done, are named in the interface language at that moment (世界, 日本, 澳大利亚, 中国, 数码, AI on a Chinese device) and can be renamed. Icons: a globe, three Asia-Pacific globes, a laptop, a chip.
4. **Suggested feeds are added one at a time** through Add source, with its preview, into the category you choose.
5. **Reading language preselection:** Chinese → Simplified Chinese; Japanese → Japanese; English → English; any other → Simplified Chinese. Skip keeps Simplified Chinese.
6. **The first run comes back** only after an interruption before any category existed; it is per device and not in the configuration file.
7. **Today with no source** shows "Add a Source", and "Import Configuration" once RD20 exists.
8. **About** lists GRDB.swift, SwiftSoup and Readability with their full licence texts, in English.
9. **"Every Settings row works"** is fully checked once Usage (RD17) and Data's import rows (RD08, RD20) exist, and again in RD22.
10. **Not added:** an image-cache limit control (it stays 500 MB) and "Clear browsing data" for the normal partition (the specification asks for it only in the adult one).
11. **Step 2's note** also names excerpts and translated page text, beyond ux's "titles and article text".

## Revision record

- Version 1, 2026-11-16: first draft.
- Version 2, 2026-11-16: after critic round 1 (SOUND WITH FIXES, no P1). Each piece of evidence was checked in the code; every finding was admitted.

| Finding | Disposition |
| --- | --- |
| F1 (P2) host in `ShellView`, not `RootView` | Admitted: a branch of `ShellView`'s content switch (decision 1); version 1's A3 gone |
| F2 (P2) push RD13's form unchanged | Admitted: one stack on `settingsPath`, a "Primary Model" row (decisions 3, 5); RD13's code unchanged; A2 narrowed to the push and pop |
| F3 (P2) no second way of adding sources | Admitted: `addSuggestions`, the feed tick list and its adult refusal dropped; categories through `CategoryModel`, feeds through S6 (decision 6). Created at "Add a Source…" as well as Done, so that Add source's picker offers them |
| F4 (P2) the ux-drawn form for "no model" | Admitted: default (a), RD14's condition changed (decision 7); (b) to the owner |
| F5 (P2) two issue criteria narrowed silently | Admitted: contradiction 2 with its default; contradiction 3 by the driver's rule across RD20 and RD21 (normal partition only from the first run, one summary line), so the issue's criterion holds as written |
| F6 (P2) import-row ownership | Admitted: contract and handoff; RD20's design amended by the driver |
| F7 (minor) tests on Today's empty state | Admitted: identifier kept; every test listed (the critic's list missed `ArticleListTests:236, :248` and `RefreshTests:373`, also unaffected); only `PaneStructureTests:93` may need adjusting |
| F8 (minor) the line's trigger | Moot under (a) |
| F9 (minor) the Readability copy | Admitted: `LICENSE` out of `exclude:`; byte-equality test dropped; full Apache text kept |
| F10 (minor) names | Admitted: `String(localized:)`; `notAvailable` gone with F3 |
