# RD01 — Create the iOS project, the NewsPawKit package and CI; archive the Mac product

Issue: [#122](https://github.com/AlvinShenSSW/NewsPaw/issues/122) · Epic E11 #114 · Requirements N01, N13; spec sections 6 and 9.
Design version 2, 2026-11-11 (after debate round 1; see the last section). Author: Claude (driver of this AFK run, by the owner's instruction). Implementer: Claude Opus 5.5. External gate: Kimi K3.1 Pro.

## Spec review

The repository still holds the retired Mac + Telegram product and no iOS code. This issue swaps one for the other: after it, `main` contains an iOS project that builds and launches to a placeholder, a Swift package whose tests run on a Mac, CI for both, and none of the old product's code. It also retires the largest unknown in the specification — whether the four chosen libraries build and behave as assumed (spec section 10) — before any feature depends on them.

No feature is built here. The ambiguity the issue leaves is mechanical (how the project file is produced, which CI image) and is settled below.

## Acceptance criteria

1. `swift test --package-path ios/NewsPawKit` passes locally and in CI, and that exact command is in `AGENTS.md`.
2. CI builds the app for the iOS simulator with the exact command in `AGENTS.md`. Locally the app launches in the simulator and shows the placeholder in English and in Simplified Chinese.
3. FeedKit, GRDB, SwiftSoup and Mozilla's Readability script are dependencies of the package, each builds for iOS 26, and each has one representative test that passes:
   - FeedKit parses an RSS 1.0 (RDF) fixture into items;
   - GRDB opens a database and runs a migration;
   - SwiftSoup parses an HTML fixture;
   - Readability extracts the article text of a fixture page loaded in a web view with page JavaScript disabled and every subresource load blocked. The test shows that the page's own script did not run and that no subresource was requested, and a positive control in the same file shows the harness can see both: with the blocking off the two subresource requests are observed, and with page JavaScript allowed the article text is rewritten.

   The four checks pass under `swift test` on macOS and, once, locally on the iOS 26.5 simulator runtime — the stated minimum — through `xcodebuild test`; CI runs the macOS form only, and the pull request says so.
4. Every bundled or linked third-party licence is MIT, BSD or Apache 2.0, and the licence text of the vendored Readability script is in the repository beside it.
5. No Python or macOS product code is on the branch: `src/`, `tests/`, `macos/`, `packaging/`, `pyproject.toml`, `uv.lock` are gone. `git show mac-v0.6.4-final:pyproject.toml` still works.
6. The old documents are under `docs/archive/`, unchanged in content. Every reference in `docs/reader/` (outside `docs/reader/designs/`) to a moved document uses its `docs/archive/` path, and removed code paths appear there only in statements that they were removed. Status lines that say no code exists are corrected.
7. No analytics, crash reporter or other third-party SDK is in the project.
8. `README.md` describes the reader, in English.

## Frozen issue contract

**In.** The eight criteria above, and nothing else.

**Invariants.**
- The owner's private local files stay ignored: `.gitignore` keeps `data/`, `dist/`, `.env`, `.env.*`, `*.sqlite3*`, `*.log` and `.venv/`. Nothing under those paths is added, moved or deleted. `.afk/` stays untracked.
- The repository is public. After this change no file of the old product and no tool output shows as untracked in the owner's checkout, so a later `git add -A` cannot stage build products (see Archive).
- Archived documents are moved, not edited and not translated.
- The app target contains no feature code: one app entry point, one placeholder view, assets, the string catalog.
- The package's `Sources` gains only what a test or the app needs now. Harness code for the four dependency checks lives in the test target, not in `Sources`.
- If one of the four libraries cannot be made to build or pass its check, stop and report. Do not substitute another library and do not weaken the check.
- English is the base language; every user-visible string is in the string catalog with a Simplified Chinese translation.

**Allowed user-visible change.** The repository's content and README. No shipped product changes: nothing is released.

**Non-goals.** Any reader feature; database schema; signing, provisioning, TestFlight (RD22); UI tests; SwiftLint or formatting tools; a project generator.

**Causal boundary.** `ios/**`, `.github/workflows/checks.yml`, `.gitignore`, `README.md`, `AGENTS.md` (the "Checks" and "The old product is retired" bullets only), `docs/archive/**` (moves plus one new `README.md`), `docs/reader/spec.md`, `docs/reader/ux.md` and `docs/reader/README.md` (only sentences that name a moved or removed path, and the status lines saying no code has been written), and the removal of the legacy paths.

**Declared deviation from the issue.** Issue #122 and spec section 9 name three document trees to archive (`docs/planning/`, `docs/designs/specs/`, `docs/mockup/`). This design also archives `docs/testing/` and six top-level documents of the old system, because leaving them beside `docs/reader/` would present the retired design as current. `docs/source-strategy.md` is one of them and is still an input for RD05's suggested sources; the specification's reference to it is updated to the archive path.

## Assumptions

Each is unverified until the named check runs. None is to be reported as fact before then.

| Assumption | Risk if wrong | Verified by |
| --- | --- | --- |
| A hand-written `project.pbxproj` using a file-system-synchronised group builds with Xcode 27.1 | The project needs a different structure | `xcodebuild` succeeding locally and in CI |
| The hosted image `macos-26` with Xcode 26.6 builds the app for deployment target iOS 26.0 and runs the package tests, web view included, without a display | CI cannot run, or the web view check must move | The pull request's own CI run. The image list was read on 2026-11-11 (debate E7): `macos-26` carries Xcode 26.0.1–26.6 and iOS SDK 26.x; `xcode-27` matches this Mac but is a preview image |
| Code written against Xcode 27.1 / Swift 6.4 locally also compiles with Xcode 26.6 | A local pass and a CI failure disagree | CI; the manifest uses `swift-tools-version: 6.2` and no newer syntax |
| `io.newspaw.reader` is an acceptable bundle identifier | It must change before the app record is created | The owner, at RD22 at the latest; it follows the old `io.newspaw.settings` and is not in the specification |

Confirmed on this Mac by the debate's experiments (Xcode 27.1, Swift 6.4, macOS 27.0.1; a local pass proves this machine only): FeedKit 10.10.2, GRDB 7.12.0 and SwiftSoup 2.14.3 resolve and build with tools version 6.2 for iOS 26 / macOS 26; FeedKit parses an RSS 1.0 fixture; a `WebPage` test runs under plain `swift test` and on the iOS 26.5 simulator; with page JavaScript disabled the page's script does not run while the app's call runs Readability 0.6.0; a hand-written project of the shape below builds for the generic simulator destination. The implementation still has to reproduce each of these in the repository.

## Approach

**Project file.** Xcode 27 is installed; no generator is. The project is written by hand as a small `project.pbxproj` (object version 77) with one application target whose sources are a file-system-synchronised group pointing at `ios/NewsPaw/`. New files then need no project edit, which keeps later pull requests free of project-file churn. A shared scheme `NewsPaw` is committed so `xcodebuild -scheme NewsPaw` works on a clean checkout. Alternatives: XcodeGen or Tuist add a tool every contributor and the CI must install, for a project with one target; a pure Swift package cannot produce the app bundle TestFlight needs.

**App target.** Universal (iPhone and iPad), deployment target iOS 26.0, Swift 6 language mode, bundle identifier `io.newspaw.reader`, generated Info.plist (`GENERATE_INFOPLIST_FILE = YES`) with all orientations on iPad and portrait plus landscape on iPhone. The local package `../NewsPawKit` is a package dependency of the target. Contents: `NewsPawApp.swift`, `PlaceholderView.swift` (logo, app name, one line of text), `Assets.xcassets` (app icon and logo made from `assets/branding/newspaw-logo.png`), `Localizable.xcstrings` (English base, `zh-Hans`).

**Package.** `ios/NewsPawKit/Package.swift`, `swift-tools-version: 6.2`, Swift 6 language mode, platforms iOS 26 and macOS 26 (the web-page API the check uses starts there, and both the developer Mac and the CI image run macOS 26 or later). One library target `NewsPawKit` depending on FeedKit, GRDB and SwiftSoup, with the Readability script as a bundled resource; one test target. `Sources/NewsPawKit` starts with two things: `Partition` (`normal`, `adult`), a real type the next issue needs, and a small accessor for the bundled Readability script, which the test target cannot reach on its own because `Bundle.module` there is the test bundle.

**Readability.** Vendor `Readability.js` from tag `0.6.0` of `mozilla/readability` (SHA-256 `34dcab3d0832d0019f02990eed6b6124e029e8c32b9f0c6f2550544ff8dff174`; verify it) into `Sources/NewsPawKit/Reading/Resources/`, with its `LICENSE` and a short `README` giving the release tag, the source URL and the file's SHA-256. It is not fetched at build time.

**Dependency checks.** Four tests in `Tests/NewsPawKitTests/DependencyChecks/`, with synthetic fixtures in the test bundle. The Readability check loads a fixture document whose inline script would rewrite the article and whose markup references an image and a stylesheet through a test-only URL scheme; a scheme handler records every request.

Subresources are blocked with a block-all content rule list, and this is fixed, not left to choice. The two public mechanisms are not equivalent (debate C1, measured on macOS 27.0.1 and the iOS 26.5 simulator): `loadsSubresources = false` on the web-page configuration stops network loads but still lets loads through a custom scheme handler, so a scheme-handler observer would report requests that never reach the network; a block-all rule list stops both, which the scheme handler can observe. The check therefore has three cases in one file: blocked and scripts off (the article is the original, the handler saw nothing); blocking off (the handler saw both subresources); page JavaScript allowed (the article text is rewritten). The last two are the positive controls that make the first one evidence. The pull request records the non-equivalence, since RD12 builds on it.

**CI.** `.github/workflows/checks.yml` keeps its triggers, permissions and concurrency block and replaces the Python job with one job on `macos-26` with Xcode 26.6 selected explicitly: check out (same pinned action), `swift test --package-path ios/NewsPawKit`, then `xcodebuild build -project ios/NewsPaw.xcodeproj -scheme NewsPaw -destination 'generic/platform=iOS Simulator' -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO`. No secrets, no signing. `macos-26` is chosen over the `xcode-27` image because that one is still a preview with announced instability; the cost is that CI compiles with an older Xcode than the developer Mac, which the tools-version rule above absorbs.

**Pinned versions.** `swift test` reads `ios/NewsPawKit/Package.resolved`, but `xcodebuild` ignores it and keeps its own lock inside the project (debate C3). Both are committed — `ios/NewsPawKit/Package.resolved` and `ios/NewsPaw.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` — with the same versions, and the `.gitignore` entries must not exclude the second.

**Archive.** `git rm -r` the legacy code paths. `git mv` every document that describes the old system under `docs/archive/`, keeping the relative layout so links between archived documents still resolve: `docs/planning/`, `docs/designs/`, `docs/mockup/`, `docs/testing/` and the six top-level files `architecture.md`, `delivery-formats.md`, `model-routing.md`, `source-strategy.md`, `system-design.md`, `telegram-routing.md`. Add `docs/archive/README.md`: what this is, that it is not maintained or translated, the tag that holds the matching code, and one known breakage — the six redesign mock-ups reference the logo by a relative path that no longer resolves from the archive. `assets/branding/` stays.

**Leftovers on disk.** `git rm` removes tracked files only. The owner's checkout also holds ignored build products of the old product inside the removed trees (`macos/NewsPaw/.build`, `__pycache__` directories) and, at the root, `.pytest_cache/` and `.ruff_cache/`. Two measures: `.gitignore` keeps `__pycache__/`, `*.py[cod]`, `.pytest_cache/`, `.ruff_cache/` and gains unanchored `.build/`, `.swiftpm/`, `xcuserdata/` and `DerivedData/`; and after the removal the implementer lists what is left under `src/`, `tests/`, `macos/` and `packaging/` and deletes those directories only when everything left in them is a regenerable cache, a build directory or a `.DS_Store`. Anything else is left in place and reported.

## Files to change

| Path | Change | Reason |
| --- | --- | --- |
| `ios/NewsPaw.xcodeproj/project.pbxproj`, `…/xcshareddata/xcschemes/NewsPaw.xcscheme` | add | criteria 2 |
| `ios/NewsPaw/NewsPawApp.swift`, `PlaceholderView.swift`, `Assets.xcassets/**`, `Localizable.xcstrings` | add | criterion 2 |
| `ios/NewsPawKit/Package.swift`, `Package.resolved`; `ios/NewsPaw.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` | add | criteria 1, 3; pinned versions |
| `ios/NewsPawKit/Sources/NewsPawKit/Model/Partition.swift`, `Reading/ReadabilityScript.swift` | add | RD02 uses the first; the check needs the second to load the bundled script |
| `ios/NewsPawKit/Sources/NewsPawKit/Reading/Resources/{Readability.js,LICENSE,README.md}` | add | criteria 3, 4 |
| `ios/NewsPawKit/Tests/NewsPawKitTests/DependencyChecks/**`, `Fixtures/**`, `PartitionTests.swift` | add | criteria 1, 3 |
| `.github/workflows/checks.yml` | rewrite the job | criteria 1, 2 |
| `.gitignore` | add Xcode / SwiftPM entries; keep the private-file entries and the Python cache entries | invariants |
| `README.md` | rewrite | criterion 8 |
| `AGENTS.md` | two bullets | criteria 1, 2, 6 |
| `docs/archive/**` | moves + `README.md` | criterion 6 |
| `docs/reader/spec.md`, `docs/reader/ux.md`, `docs/reader/README.md` | path mentions and status lines only | criterion 6 |
| `src/`, `tests/`, `macos/`, `packaging/`, `pyproject.toml`, `uv.lock` | remove | criterion 5 |

## Execution surface

- **Written:** the paths above.
- **Read only:** `assets/branding/newspaw-logo.png` (source of the icon and logo), `docs/reader/**`, the tag `mac-v0.6.4-final`.
- **Executed:** `swift build`, `swift test`, `xcodebuild`, `xcrun simctl` (boot, install, launch, screenshot), `sips` (resize the logo), `git`, `shasum`, `curl` or `git` to obtain the Readability release once. Swift Package Manager fetches the three libraries from GitHub.
- **Generated outputs.** The app icon and logo PNGs: `sips -z 1024 1024` (and the sizes the asset catalog needs) from the branding PNG, committed. `Package.resolved`: produced by `swift package resolve`, committed. Simulator screenshots: `xcrun simctl io <device> screenshot`, saved under the run directory given in the handoff, not committed.
- **Not touched:** `data/`, `dist/`, `.env*`, `.afk/` (except the evidence directory named in the handoff), any signing identity, any remote other than fetching dependencies.

## Key implementation notes

- Do the removal and the moves with `git rm` / `git mv` so history follows the files.
- The Mac is on Swift 6.4 with the iOS 26.5 and iOS 27.0 simulator runtimes. Run the one-off package test on an iOS 26.5 simulator. Do the launch check on the simulators made for the owner's devices, all iOS 27.0: "NewsPaw iPhone 18 Pro Max" and "NewsPaw iPad Pro 11 M4" (a third, "NewsPaw iPad mini", exists; use it if time allows). Do not download runtimes. Real-device verification is the owner's and is not claimed by this issue.
- Compile the block-all rule list into a `WKContentRuleListStore` created at a temporary directory inside the test, not the default store.
- The design document is already committed on the branch by the driver.
- Launch the simulator app in each language with `xcrun simctl launch <device> io.newspaw.reader -AppleLanguages '(zh-Hans)'` (and `'(en)'`).
- Pin dependencies with `from:` on the current major version and commit both lock files.
- Tests that use a web view must run on the main actor and must not depend on the network: the fixture is loaded from a string or the test bundle.
- Keep `checks.yml`'s action pin style (commit SHA with a version comment).
- Record in the pull request: the library versions resolved, their licences, the CI image and Xcode version, the subresource finding above, that CI runs the web view check on macOS only, and what was run on which simulator runtime.

## Risk assessment

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| The hand-written project file is subtly invalid and only Xcode's interface would show it | Medium | Medium | `xcodebuild -list` and a full build locally and in CI; the scheme is committed |
| No hosted image has a new enough Xcode | Low | High | Checked first; if none, stop and report with the list of images found |
| The web view check does not run on the headless CI image although it runs locally | Medium | Medium | If so, stop and report with the CI log; do not delete or skip the check to get a green run |
| A library fails to build under Swift 6 mode | Medium | Medium | Try the library's current release; if it still fails, stop and report — no substitution |
| Removing the Python tree deletes something the owner still needs locally | Low | High | Only tracked files and regenerable caches are removed; the owner's ignored data (`data/`, `dist/`, `.env*`, `.venv/`) is untouched; the tag keeps everything |

## Out of scope

Reader features, storage schema, navigation, signing and TestFlight, UI tests, lint tooling, changing the specification beyond path mentions and the status lines, deleting the remote branches or the tag of the old product.

## Test plan

- Package: the four dependency checks with the two positive controls, and one test for `Partition` (raw values `normal` / `adult`, since the configuration file uses them). Run under `swift test`, and once on an iOS simulator with `xcodebuild test`.
- Build: `xcodebuild build` for the generic simulator destination, locally and in CI.
- Manual, by the implementer, with evidence returned: install and launch on a booted simulator in English and in Simplified Chinese; one screenshot each.
- Repository: `git ls-files` shows none of the removed paths; `git show mac-v0.6.4-final:pyproject.toml` prints the file; a search of `docs/reader/` outside `designs/` finds every moved document under its `docs/archive/` path and removed code paths only in statements that they were removed; `git ls-files --error-unmatch ios/NewsPaw.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` succeeds; the `pins` of the two lock files are identical (`-disableAutomaticPackageResolution` does not fail on a missing lock, so this is checked directly); `git status --short` shows no file of the old product and no tool output as untracked.

## Handoff notes

Work on branch `feat/rd01-ios-project` from `main`. Commit locally in logical steps; do not push, open a pull request or merge. Return the diff identity, every command with its result, the evidence paths, and anything that did not go as this document assumes.

## Debate record

**Round 1 (2026-11-11).** A critic agent attacked version 1 with experiments in a throwaway directory (Xcode 27.1, Swift 6.4, macOS 27.0.1, iOS 26.5 simulator). Ten findings; all supported, all accepted.

| ID | Severity | Finding | Resolution in version 2 |
| --- | --- | --- | --- |
| C1 | P1 | The two subresource mechanisms are not equivalent; a scheme-handler observer fails with one of them | Mechanism fixed to the block-all rule list; non-equivalence recorded |
| C2 | P2 | "Saw nothing" also passes with a broken harness | Two positive controls in the same test file |
| C3 | P2 | `xcodebuild` ignores the package's lock file | Both lock files committed; CI disables automatic resolution |
| C4 | P2 | CI image left open; "has the iOS 26 SDK" was the wrong test | `macos-26` with Xcode 26.6 named; tools version 6.2 |
| C5 | P2 | Criterion 6 could not be met inside the boundary | Criterion reworded; `ux.md` and status lines added to the boundary |
| C6 | P2 | Ignored build products become visible once their `.gitignore` is removed | Cache entries kept, unanchored `.build/`, leftovers listed and removed |
| C7 | minor | Archived mock-ups lose their logo path | Named in `docs/archive/README.md` |
| C8 | minor | The archive set is wider than the issue | Declared as a deviation |
| C9 | P2 | The web view check would run on macOS only | Also run once on a simulator locally; the pull request says CI covers macOS only |
| C10 | minor | The test target cannot load the bundled script | Accessor file added to `Sources` |

**Round 2 (2026-11-11).** The same critic revalidated version 2: C1–C10 resolved in the text, no P1 or P2 in the revised passages. Four minor wording and checklist items (C11 test plan out of step with criterion 6; C12 nothing checked that the project lock is tracked and equal; C13 no run on the minimum system version; C14 the clean-status invariant was not satisfiable as worded) were applied as clarifications without changing a decision, so no further round was run.
