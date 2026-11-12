# RD03 — App shell: navigation on iPhone and iPad, Library with categories

Issue: [#124](https://github.com/AlvinShenSSW/NewsPaw/issues/124) · Epic E11 #114 · Requirements N01, N02, N05; ux section 2, S2 (categories), S13 (category), sections 5 and 6.
Design version 4, 2026-11-11 (after three debate rounds; see the last section). Author: Claude (driver of this AFK run). Implementer: Claude Opus 5.5. External gate: Kimi K3.1 Pro.

## Spec review

After RD02 the app opens its library and shows a placeholder. This issue replaces the placeholder with the navigation skeleton of ux section 2 and the first feature a person can use: managing categories. Today, Starred, All Unread and Settings become real destinations that say truthfully that they are empty.

Core need: every later interface issue plugs a screen into this skeleton, so its structure, width rule, tokens, localisation and accessibility baseline have to be right once.

Settled here because the issue and ux.md leave it open:
- **iPhone in landscape.** ux section 2 says the column count follows the window's width, and its device table says iPhone uses the iPhone structure; an iPhone 18 Pro Max is 956 pt wide in landscape. Decision: the width rule applies on iPad; on iPhone the tab structure is used in every orientation. ux.md gets one sentence.
- **One window.** The generated scene manifest currently allows several windows on iPad. The specification asks for Split View and Stage Manager widths, not for several windows, and several windows would let two windows show different partitions once RD18 exists. Decision: the app supports one window. ux.md gets one sentence.
- **What empty destinations show.** Text only; no button that does nothing.
- **Settings.** Only About (the version) exists now; each later issue adds its own row.
- **Deleting a category that has sources.** N02's question is implemented now, although no interface can add a source until RD05.

## Acceptance criteria

1. iPhone: a bottom tab bar with Today, Library, Starred, Settings, in portrait and landscape.
2. iPad, by window width:
   - 1100 pt and wider — the sidebar pane, always shown, and beside it the destination. A list destination (All Unread, Starred, a category) shows its list pane and the reading pane side by side, so three panes are on screen. Today and Settings use the whole width beside the sidebar.
   - 700 to 1099 pt — no sidebar pane; a button in the leading pane's bar slides the sidebar over the content from the leading edge, and choosing a destination or tapping outside closes it. A list destination shows list pane and reading pane side by side, tiled, never one covering the other, at 744 pt as well as at 834 pt. Today and Settings use the whole width.
   - below 700 pt — the tab structure, with the bottom tab bar.
   Each pane has its own navigation bar, title and toolbar, and navigating inside one pane leaves the others as they were. The layout is a function of the window's width alone, so it is right after rotation, Split View and Stage Manager changes, and it does not change when the keyboard appears.
3. Crossing 700 pt keeps the current destination, and an open category editor keeps what was typed.
4. Library lists the categories in the owner's order with icon and name. A category can be created, renamed, given another icon from the fixed set, reordered and deleted, and every change is still there after a relaunch. With no category yet, the list says so and the New category control works.
5. Deleting a category with no sources asks for confirmation. Deleting one with sources asks whether to move them to another category (choosing which) or delete them with it; with no other category, only deletion is offered and the dialog says so. Deleting the category that is currently shown moves the selection to All Unread.
6. Name rules are enforced in place with a message, using the package's own rule: an empty or over-long name cannot be saved. Duplicate names are allowed.
7. When a change cannot be saved for any other reason, the interface says so, the list is reloaded from storage so that it shows what is really there, and an open editor stays open with its text.
8. Today, All Unread, Starred and a selected category are real destinations with a truthful empty state. Settings shows About with the app version.
9. Colour, type and spacing tokens of ux section 5 are defined once. A test computes the contrast of every text and accent token on every background it is used on, and of the on-accent token on the accent, in light and dark, and requires at least 4.5:1. No control is filled with the accent unless its label uses the on-accent token; the list's Edit / Done control is the app's own unfilled text button for that reason (the system's Done button is a white glyph on the accent, 2.5:1 in dark).
10. Every icon-only control has an accessibility label; the identified interactive controls measure at least 44 × 44 pt; a selected icon in the icon grid is marked by more than colour; at the largest accessibility text size category rows grow and nothing is clipped.
11. Every string the app can show is in the catalog with a Simplified Chinese translation, and the catalog has no unused key. A script checks this against the build's extracted strings, locally and in CI.
12. Evidence: UI tests that assert criteria 1–8 (criterion 7 through a debug-only switch that makes the next save fail) and the measurable parts of 10 on the iPhone and on both iPads in both orientations, plus one run or screenshot below 700 pt on iPad; screenshots on the three NewsPaw simulators in portrait and landscape, one in dark appearance, one at the largest accessibility text size, one in Simplified Chinese; and a short accessibility record in the pull request, which lists as not verified by automation, for the owner's device check: VoiceOver staying inside the open slide-over, the VoiceOver escape gesture closing it, and a hardware Escape key closing it.

## Frozen issue contract

**In.** The twelve criteria.

**Invariants.**
- The interface holds one library — the normal one. Nothing in this issue shows, hints at or leaves a visible slot for the adult partition.
- All storage goes through `Library`'s public API. The app target writes no SQL, builds no path to a database, and never uses `@testable import` (in a debug build that would expose the package's internal adult functions).
- System components provide bars, lists, sheets and materials; the app draws no bar background.
- No asset-catalog colour set duplicates a palette value: the palette in the package is the only definition, and the tested values are the displayed values.
- Debug-only seams are compiled out of release builds and are used only by the UI tests.
- English base strings; Simplified Chinese for each. No third-party dependency is added.

**Allowed user-visible change.** The interface described above replaces the placeholder. The failure screen from RD02 is kept. iPad no longer offers a second window.

**Non-goals.** Source rows under a category; unread counts; articles; the partition switch; overview settings and "move to the other partition" in category settings; search; article keyboard shortcuts; Settings rows other than About; licences in About (RD21); first run and suggested categories (RD21); hiding the list pane to read at full width (RD11); running UI tests in CI.

**Causal boundary.**
- `ios/NewsPaw/**`; `ios/NewsPawUITests/**`; `ios/NewsPaw.xcodeproj/**` (UI-test target, scheme test action, single-window setting).
- `ios/NewsPawKit/Sources/NewsPawKit/Model/Palette.swift` and `Model/WindowLayout.swift` (new: the palette, and the pure width rule); `Store/Library+Categories.swift` for three additions only — category summaries with source counts, the public name rule, and one `#if DEBUG` function that inserts synthetic sources for UI tests; their package tests.
- `ios/Tools/check_strings.py` (new) and one step in `.github/workflows/checks.yml` that runs it, with the build step switched to `build-for-testing` so the UI-test target is compiled in CI.
- `docs/reader/ux.md` (two sentences: iPhone landscape; one window) and `AGENTS.md` ("Checks": the changed build command, the strings check, the UI-test command).

## Assumptions

| Assumption | Risk if wrong | Verified by |
| --- | --- | --- |
| Sibling navigation stacks placed side by side, with no split view around them, are independent panes: each has its own bar, title and toolbar, and a push stays in its pane | The container must be built differently | Measured in debate round 2 on iPad mini and iPad Pro 11 simulators; then the UI tests' frame and bar assertions |
| A full-screen cover with a clear background, holding the dimmed layer and the sidebar panel, behaves as a modal layer and can replace the system's presentation animation with a slide from the leading edge | The sidebar below 1100 pt needs another presentation | Measured in debate round 3 for touch, keyboard, rotation, edit mode and frames; VoiceOver containment, the escape gesture and the Escape key cannot be driven from UI tests and are left to the owner's device check |
| A tab container given a compact horizontal size class shows the bottom tab bar on iPad below 700 pt | A 33 pt band shows the system's top bar instead | Measured in round 1 (U5); UI test or screenshot below 700 pt |
| One window can be enforced with a generated Info.plist | A partial Info.plist is needed | The built Info.plist |
| `python3` exists on the CI image and the build leaves its extracted strings where the script can find them | The strings check runs locally only | The pull request's CI run |

Measured in debate round 1 on iOS 27.0 simulators (a local pass proves this machine only): a UI-test target can be added by hand to the project and run with `xcodebuild`; XCUITest can rotate iPad and iPhone; `simctl ui` sets dark appearance and the largest text size on a booted simulator; a dynamic colour built from palette values renders the right value in each appearance; `#if DEBUG` code in the package is present in Xcode debug builds and absent from release; a `@MainActor @Observable` model awaiting the library compiles in Swift 6 mode; a three-column split view cannot tile two columns at 744 pt. Measured in round 2: two navigation stacks inside a split view's detail share one bar and one navigation context, and no split-view style overlays the sidebar below 1100 pt while tiling it from 1100 pt — which is why this design uses no split view at all; three sibling stacks do give independent panes; setting `INFOPLIST_KEY_UIApplicationSceneManifest_Generation = NO` removes the scene manifest, leaves the app single-window and still resizable; a sheet presented from the root keeps its text across the 700 pt switch; an alert presented from the root closes a sheet presented from the root. Measured in round 3: a hand-built overlay is not modal for the keyboard (typing reaches the pane behind), while the same panel inside a clear full-screen cover is; a tap outside the panel closes it without triggering what is underneath; rotating to 1100 pt or more while it is open ends in the pane form; a sheet asked for from inside a cover stays pending until the cover closes; tapping a row in edit mode still selects it.

## Approach

**State.** An app model (`@MainActor @Observable`) owns the startup state and the library. A category model at app level owns the category list and every category operation. A navigation model owns where the user is, in one form that both containers read:

| Navigation state | Tab container | Pane container |
| --- | --- | --- |
| tab Today | Today tab | sidebar: Today |
| tab Library, empty path | Library tab at its root (the category list) | sidebar: All Unread |
| tab Library, path [All Unread] | Library tab, All Unread pushed | sidebar: All Unread |
| tab Library, path [category] | Library tab, that category pushed | sidebar: that category |
| tab Starred | Starred tab | sidebar: Starred |
| tab Settings | Settings tab | sidebar: Settings |

The state is the tab and the Library path; the sidebar selection is derived from it and writes back to it, so a width change needs no translation step.

**Presentations above the containers.** The New category sheet and the Category settings sheet are presented from the root view, above the container switch, and what is typed in them lives in the category model, so a container switch cannot dismiss them or lose a draft. An alert or dialog that can appear while a sheet is open (the error alert, the delete dialogs started from Category settings) is attached to that sheet's content — one attached to the root would close the sheet. The root keeps only the alert and dialogs for when no sheet is open (delete from edit mode; an error after a reorder).

**Containers.** The root measures width and idiom and shows the tab container (iPhone always; iPad below 700 pt) or the pane container (iPad from 700 pt). The rule is one pure function in the package (`WindowLayout`: idiom and width in; structure, whether the sidebar is a pane, and the list pane's width out) with a unit test; the root recomputes it when the width changes and at no other time.
- **Tab container.** Today, Library, Starred, Settings, each a navigation stack; given a compact horizontal size class so the bottom tab bar is used on iPad too.
- **Pane container.** Sibling navigation stacks side by side, separated by hairlines, with no split view. From 1100 pt: a sidebar pane 280 pt wide, then the destination. Below 1100 pt: the destination only, and a sidebar button at the leading edge of the leading pane's bar. A list destination is a list pane (300 pt wide when list and reading together have less than 800 pt, otherwise 340 pt) and a reading pane taking the rest; Today and Settings are one pane. In this issue the list pane shows the destination's empty state and the reading pane shows "No article selected".
- **Sidebar.** The same content in both forms: Today, All Unread, Starred; the categories, with edit mode for reorder and delete; New category and Settings at the bottom. As a pane it is always shown. As a slide-over it is presented in a full-screen cover with a clear background, so that the system makes it modal (the keyboard is dismissed and typing cannot reach what is behind): inside the cover, a dimmed layer and a 320 pt panel at the leading edge holding the same standard list in its own navigation stack. The cover's own animation is switched off and the panel slides in from the leading edge instead, or simply appears with Reduce Motion. A tap on the dimmed layer closes it; choosing a destination closes it; a width change that makes the sidebar a pane closes it. New category and Category settings chosen in the slide-over close it first and then open their sheet from the root, because a sheet asked for from inside a cover would wait until the cover closed. Delete confirmations started in the slide-over attach to its content. The app draws the dimmed layer and nothing else; the panel's background is the system's.
- **In both forms:** while the category list is in edit mode a tap on a row does not navigate — only the reorder handle and the delete control act. The sidebar button is on the root of the leading pane only; after a push in that pane the back button takes its place and the user goes back first.

**Library on iPhone.** The Library tab root is the category list: the All Unread row, then the categories; an Edit control for reorder and delete; a New category control; a context menu with Category settings. The same category-list component is used in the sidebar.

**One window.** The project stops generating a scene manifest (`INFOPLIST_KEY_UIApplicationSceneManifest_Generation = NO`); the built Info.plist then has none and the app has a single, still resizable, window.

**Category editing.** New category is a sheet: name field, icon grid, Save, Cancel. Rename and icon change happen in the Category settings sheet (name, icon grid, Delete), reached from the context menu. The name rule comes from the package (`trimmed, 1…100 characters`) through one public function, used by both sheets; Save is disabled for an empty name and the over-long message appears under the field. Reordering updates the list on screen first, then saves; changes are saved one after another in the order made; on failure the list is reloaded and the error alert shown.

**Deletion.** As criterion 5, with system confirmation dialogs; the "move to" choice lists the other categories.

**Tokens.** `Palette` in the package holds every token of ux section 5 with its light and dark value, plus an on-accent token (white on the light accent, the dark ink on the dark accent — white on the dark accent is 2.5:1), a contrast function and the test of criterion 9. The app builds dynamic colours from it and sets the tint in code. Spacing, radii and type sizes are constants in the app target.

**Localisation.** Every string goes in `Localizable.xcstrings` with Simplified Chinese; destination names follow ux section 2 (今日 / 订阅 / 收藏 / 设置). The placeholder's strings are removed with the placeholder. `ios/Tools/check_strings.py` compares the keys the build extracted with the catalog: every extracted key present and translated, no catalog key unused. The build does not warn about either (measured in round 1), so the script is the check. It takes the build's derived-data path, reads only the app target's extracted-strings files (not the package's or the UI tests'), and de-duplicates across architectures. It can only see literal keys, so the app never builds a key at run time.

**UI tests.** A `NewsPawUITests` target, run locally with `xcodebuild test` on the simulators; CI compiles it (`build-for-testing`) and does not run it. Debug builds accept three launch-environment values, used only by the UI tests: a single path component naming a subdirectory of the app's temporary directory to use as the library directory (anything that is not a single component is ignored); a number of synthetic sources to insert into the first category through the package's debug-only function (it does nothing when there is no category or when that category already has sources, so a relaunch is harmless); and a switch that makes the next category save fail, for criterion 7. Tests assert the window width before any structure assertion (the simulator remembers window sizes between launches), and judge structure by element existence, frames and navigation bars — list pane's trailing edge at or left of the reading pane's leading edge, one bar per pane — not by hit-testing.

## Files to change

| Path | Change | Reason |
| --- | --- | --- |
| `ios/NewsPaw/NewsPawApp.swift` | change | root wiring |
| `ios/NewsPaw/AppState/**` (app model, category model, navigation model, debug launch options) | add | criteria 2–7 |
| `ios/NewsPaw/Navigation/**` (root, tab container, pane container, sidebar pane and slide-over, list and reading panes) | add | criteria 1–3, 8 |
| `ios/NewsPaw/LibraryScreen/**` (category list, row, new-category sheet, category settings sheet, icon grid, delete flow) | add | criteria 4–7 |
| `ios/NewsPaw/Destinations/**` (Today, All Unread, Starred, category, Settings, About, startup failure) | add | criterion 8 |
| `ios/NewsPaw/Theme/**` | add | criterion 9 |
| `ios/NewsPaw/Localizable.xcstrings` | change | criterion 11 |
| `ios/NewsPaw/PlaceholderView.swift` | remove (its failure view moves to `Destinations/`) | replaced |
| `ios/NewsPawKit/Sources/NewsPawKit/Model/Palette.swift`, `Model/WindowLayout.swift` | add | criteria 9, 2 |
| `ios/NewsPawKit/Sources/NewsPawKit/Store/Library+Categories.swift` | change | summaries, public name rule, debug seeding |
| `ios/NewsPawKit/Tests/NewsPawKitTests/**` | add | palette contrast, window layout, summaries, name rule |
| `ios/NewsPawUITests/**`, `ios/NewsPaw.xcodeproj/**` | add / change | criterion 12; one window |
| `ios/Tools/check_strings.py`, `.github/workflows/checks.yml` | add / change | criterion 11; UI tests compiled in CI |
| `docs/reader/ux.md`, `AGENTS.md` | sentences | decisions; checks |


## Execution surface

- **Written:** the paths above.
- **Read only:** `docs/reader/ux.md`, `docs/reader/spec.md`.
- **Executed:** `swift test`, `xcodebuild build-for-testing` / `test` / `test-without-building` on simulators (always with `-derivedDataPath`, so nothing lands in the user's default derived-data folder and the strings script knows where to look), `xcrun simctl` (boot, install, launch, ui appearance and content size, screenshot, get_app_container), `python3 ios/Tools/check_strings.py`, `git`.
- **Generated output:** screenshots and logs under the run's evidence folder; nothing generated is committed.
- **Not touched:** dependencies and lock files, `.gitignore`, the owner's ignored files.

## Key implementation notes

- CI compiles with Xcode 26.6; nothing newer than iOS 26 API and Swift 6.2 syntax.
- No source folder named `Data`, `Build` or `Dist`.
- `Category` from the package collides with an Objective-C runtime type in a module that imports Foundation; give the app one type alias and use it.
- Build the container and the slide-over sidebar first and prove criterion 2 on both iPads — frames, one bar per pane, a push staying in its pane, the slide-over opening and closing — before building anything else; if either cannot be made to work, stop and report.
- That the debug-only code is absent from release builds is a review check: every seam sits inside `#if DEBUG`, and a release-configuration build must still succeed.
- Simulators must be booted before `simctl ui` is used, and `xcodebuild` shuts down simulators it booted itself.
- Put every accessibility identifier the UI tests rely on in one file.
- The accessibility audit API is noisy on system components; assert frames and labels on the identified controls instead, or give the audit an explicit ignore list.

## Failure handling

| Situation | What the interface does |
| --- | --- |
| Empty or over-long name | Save disabled / message under the field; nothing is sent to storage |
| Any other error from a category operation (including a category or move target that no longer exists) | Alert "The change could not be saved."; the list reloads from storage; open sheets stay open with their text |
| The shown category is deleted | Selection moves to All Unread (panes) or the Library root (tabs) |
| No category exists | "No categories yet" with the working New category control |
| The library failed to open | RD02's failure screen, unchanged |

## Risk assessment

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| The slide-over is less polished or less accessible than the system's sidebar | Medium | Medium | Hosted in a system full-screen cover so modality is the system's; standard list and navigation stack inside; three accessibility behaviours listed for the owner's device check |
| Later screens need something the pane container cannot do | Low | High | Each pane is an ordinary navigation stack, measured to keep its own bar, toolbar, bottom bar and pushes |
| UI tests are flaky on the simulator | Medium | Medium | Wait on existence, no fixed sleeps, width preconditions; run three times before hand-back |
| Hand-editing the project for a second target breaks the build | Low | Medium | Done once in the debate's probe; `xcodebuild -list`, clean build, CI |
| The strings script reads a build layout that differs on CI | Medium | Low | The pull request's CI run; if it cannot work there, report and keep it local |

## Out of scope

As Non-goals; also drag and drop between categories and state restoration across launches.

## Test plan

- Package: palette contrast for every pairing in light and dark; category summaries with and without sources; the name rule (empty, white space only, 100 and 101 characters); the debug seeding function exists only in debug.
- Window layout (package): 699 / 700 / 799 / 800 / 1099 / 1100 pt on iPad, including the list pane's width on each side of its switch; iPhone at any width.
- UI tests (local): structure by frames on iPhone 18 Pro Max, iPad mini and iPad Pro 11 simulators, portrait and landscape, including Today at full width; rotation re-establishes the layout; one navigation bar per pane; the slide-over sidebar opens, selects a destination and closes, closes on an outside tap without triggering the control underneath, dismisses the keyboard when it opens, ends in the pane form after rotating to landscape while open, and does not navigate on a row tap in edit mode; a forced save failure shows the alert, reloads the list and leaves the sheet open with its text; category walk-through with relaunch; empty library; both deletion dialogs; deleting the shown category; name validation; a draft surviving the 700 pt switch if the window can be resized from the test, otherwise a recorded manual check; control sizes and labels.
- Strings script: passes on the final build; fails when a key is removed from the catalog (shown once).
- Screenshots and the accessibility record as criterion 12.
- The `AGENTS.md` commands pass.

## Handoff notes

Branch `feat/rd03-app-shell` from `main` after RD02 has merged; the design is committed there by the driver. Commit locally; do not push.

## Debate record

**Round 1 (2026-11-11).** A critic agent attacked version 1 with a probe app and UI tests on three throwaway iOS 27.0 simulators. Sixteen findings; all supported except where noted, all accepted.

| ID | Severity | Finding | Resolution in version 2 |
| --- | --- | --- | --- |
| U1 | P1 | A three-column split view overlays instead of tiling two columns at 744 pt | Two-column split view; list and reading panes side by side inside the detail |
| U2 | P1 | Today and Settings would sit in a 340 pt column beside "Select an article" | They use the full detail width |
| U3 | P2 | Switching containers tears down everything but the selection | Presentations hosted above the switch; drafts in a model; paths in the navigation model |
| U4 | P2 | The destination enum could not express the iPhone Library root | One navigation state with a mapping table |
| U5 | P2 | Between about 667 and 699 pt the tab container showed a top bar | Compact size class forced on the tab container |
| U6 | P1 | No way to seed sources inside the boundary; `@testable import` in the app would expose adult functions | One debug-only package function, in the boundary; `@testable import` forbidden in the app |
| U7 | P2 | iPad allowed several windows, so "nothing else writes categories" was false | One window; category model at app level |
| U8 | P2 | Failure cases of the category flows were missing | Failure handling table |
| U9 | minor | The name rule would be duplicated in the interface | One public rule in the package |
| U10 | minor | Rename had two interfaces and one had no entry | Sheet for create only; rename and icon in Category settings |
| U11 | P2 | The contrast test could not fail for accent-filled controls | On-accent token and pairing; non-colour selection mark; no duplicate colour sets |
| U12 | P2 | Nothing checked the localisation criterion (criterion 9 in version 1, 11 now); the build does not warn | A strings script, local and in CI |
| U13 | P2 | Test-plan gaps (width persistence, hit-testing, CI never compiled the UI tests, missing accessibility record) | Width preconditions, frame assertions, `build-for-testing` in CI, criterion 12 |
| U14 | minor | `Category` is ambiguous in the app target | Type alias |
| U15 | minor (unverified) | Reorder snaps back; overlapping reloads | Optimistic update, serialised saves, reload on failure |
| U16 | minor | The accessibility criterion (8 in version 1, 10 now) had no check beyond screenshots | Frame and label assertions |

**Round 2 (2026-11-11).** The same critic probed version 2's container on iPad mini and iPad Pro 11 simulators. U2–U7 and U9–U16 resolved; U1 resolved only as to tiling and U8 in part. Nine new findings.

| ID | Severity | Finding | Resolution in version 3 |
| --- | --- | --- | --- |
| U17 | P1 | Two navigation stacks inside a split view's detail are one navigation context: one bar, merged toolbars, a push replaces both panes | No split view: sibling navigation stacks, measured to be independent |
| U18 | P1 | No split-view style overlays the sidebar below 1100 pt and tiles it from 1100 pt | The app shows the sidebar as a pane from 1100 pt and slides it over below |
| U19 | P2 | An alert on the root closes a sheet on the root | Alerts and dialogs that can appear over a sheet attach to the sheet's content |
| U20 | P2 | Nothing could make a save fail, so criterion 7 could not be exercised | A third debug-only switch |
| U21 | minor | The layout rule's test had no home | `WindowLayout` in the package |
| U22 | minor | "Every size change" included the keyboard | The layout depends on width only |
| U23 | minor | The strings script's inputs were not pinned down | Derived-data path, app target only, de-duplicated, literal keys |
| U24 | minor | Seeding seam details | Idempotent; nothing without a category; release absence is a review check |
| U25 | minor | Two rows of the round-1 table used version-1 criterion numbers | Marked |

**Round 3 (2026-11-11).** The critic built the slide-over as version 3 specified and three native alternatives, on iPad mini and iPad Pro 11 simulators. U1, U8 and U17–U25 resolved; the pane container held. Six new findings, no P1.

| ID | Severity | Finding | Resolution in version 4 |
| --- | --- | --- | --- |
| U26 | P2 | A hand-built overlay is not modal for the keyboard | The panel is hosted in a clear full-screen cover (measured: identical frames, keyboard dismissed) |
| U27 | P2 | VoiceOver containment, the escape gesture and the Escape key cannot be verified by UI tests | Modality comes from the system cover; the three are listed for the owner's device check |
| U28 | P2 | A row tap in edit mode navigated and closed the slide-over | Row taps do not navigate in edit mode |
| U29 | minor | The sidebar button vanished after a push | Stated: on the pane's root only |
| U30 | minor | The system's Done button is white on the accent, 2.5:1 in dark | The app's own unfilled Edit / Done control |
| U31 | minor | Three leftovers from earlier versions | Reworded |

Version 4 changes only what round 3 measured, so no further round was run.
