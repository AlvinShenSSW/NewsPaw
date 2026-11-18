# RD22 — TestFlight build and M1 verification on the owner's devices

Issue: [#143](https://github.com/AlvinShenSSW/NewsPaw/issues/143) · Epic E16 #119 · Milestone M1 · Priority P0 · Requirements N13 (distribution, the real-device list); spec section 7 (M1 acceptance). Also touched: N08 (no loopback http in a TestFlight build), N09 (what the device checks cover), spec section 6.1 (nothing personal hard-coded), section 10 (TestFlight assumptions).

Version 2 (2026-11-19), after one debate round. Written against `main` at `44da16e` (every issue except RD22 merged; migrations `v1`–`v10`). Read: `AGENTS.md`; spec N01, N08–N13, sections 6–8 and 10; ux.md; backlog.md; issue #143; the bodies of pull requests #150–#184; the driver's facts for batches 2–4 (section "Owed on a real device"); the frozen designs RD10, RD20, RD21, RD24; the project file, `NewsPaw-Info.plist`, `InfoPlist.xcstrings`, the asset catalog, the scheme, `ios/Tools/check_strings.py`, `.github/workflows/checks.yml`, `.gitignore`, every `#if DEBUG` block of the app and the package; GRDB 7.12.0's and SwiftSoup 2.14.3's checkouts; `xcodebuild -help` of the Mac's Xcode 27.1 (27A9275). Author: Claude (planner, for the driver of this AFK run).

**The repository is public** (`gh repo view`: `PUBLIC`). Anything committed — a team identifier in the project file, entitlements pasted into a pull request, a source address in a results table — is published. The hygiene decisions below follow from that.

The owner's instruction for this phase (2026-11-12): one user, converge, no over-engineering. This issue is preparation and documentation: three small scripts, two documents, a handful of project files.

Statements about Xcode, App Store Connect, TestFlight or upload validation that could not be checked in the tree or in `xcodebuild -help` are marked **(to verify at the first upload)**.

## Spec review

**The baseline.** N13: "Things only a real device can verify are kept as a separate list, each marked done or not done: authentication and locking, background refresh, TestFlight install and upgrade, a configuration file sent by AirDrop and imported on a second device." "Distribution: TestFlight internal testing, on the owner's devices." Section 7: "Every milestone must work on a real device", and M1's acceptance walk (seven steps, decision 10). Section 6.1 (2): "The repository and the app bundle contain none of the owner's source lists, keys or account names." Section 10: TestFlight internal testing needs no review and builds expire after 90 days, "not verified on this project's account". Issue #143: signing, archive, upload to internal testing; the owner's steps written down; "no build is uploaded without the owner's authorisation for that upload"; `docs/reader/device-checks.md` with its families; the M1 walk on three devices; four criteria. AGENTS.md: "Nothing is deployed and no build is uploaded automatically."

**The tree today.**

| Item | Present | Missing |
| --- | --- | --- |
| Configurations | Debug and Release; Release: whole-module, `dwarf-with-dsym`, `VALIDATE_PRODUCT`, no testability; the scheme archives Release | Never archived for a device in this run (RD24: "Release binary not built or inspected"); earlier Release searches were by hand |
| Signing | `CODE_SIGN_STYLE = Automatic` | No team, no xcconfig, no export options. On the Mac: no Xcode account, one Apple Development certificate of unknown team, no distribution certificate, no API key |
| Version | `io.newspaw.reader`, `0.1.0`, build `1`; About shows both (`SettingsView.swift:529`) | No rule for the build number |
| Icon, launch screen, orientations | One 1024 PNG without alpha; generated launch screen; all four iPad orientations, no `UIRequiresFullScreen` | Nothing. No scene manifest (generation off since RD05); validation's view of that: (to verify at the first upload) |
| Face ID, background refresh, ATS, types | `NSFaceIDUsageDescription` (both languages); `fetch` and `io.newspaw.reader.refresh`; `NSAllowsArbitraryLoads`; `.newspaw` and `.opml` type declarations | Nothing |
| Encryption declaration | — | **`ITSAppUsesNonExemptEncryption` missing.** The app uses only the system's HTTPS and keychain plus SHA-256 hashing; without the key each build waits on a compliance question (to verify at the first upload) |
| Entitlements | None; keys are data-protection keychain items in the default access group | Nothing (the signed app's entitlements are read at the first archive) |
| Privacy manifest | GRDB 7.12.0 ships one declaring no API; SwiftSoup 2.14.3 ships none and uses no required-reason API | **The app has none.** It uses `UserDefaults` (`Preferences`, `AppModel`) and file timestamps (`ImageCache`: `attributesOfItem`, `contentModificationDateKey`, `setAttributes(.modificationDate)`). `BoundedFileRead.swift:18` reads `.fileSizeKey` of files the owner picks: file size is not in Apple's file-timestamp list, so no declaration (if judged in category, the reason would be `3B52.1`, not `C617.1`) |
| Licences (6.1) | The four notice files in `NewsPawKit_NewsPawKit.bundle`, covered by `ThirdPartyNoticesTests` | Nothing |
| Debug seams | 30 Swift files hold `#if DEBUG` blocks | No standing check that a Release binary is free of them |
| Hygiene | No certificate, profile, key, `.opml` or `.newspaw` tracked | `.gitignore` has no signing pattern; `.afk/` is excluded only by this clone's `.git/info/exclude` |

**Contradictions and gaps, with the decision taken.**

1. **The issue asks for an upload; only the owner can make one possible.** The pull request delivers what needs no account (part A) and refers to #143 without closing it; #143 stays open until the owner's install, upgrade and walk are recorded (part B). The pull request meets criteria 3 and 4 and the structure of 2; criterion 1 and 2's results are the owner's.
2. **The issue's families omit background refresh; N13 includes it.** Both lists are carried.
3. **"A second device" with three devices.** Step 7 is recorded per receiving device in the cycle iPhone → iPad mini → iPad Pro → iPhone.
4. **The issue's delivery text** (Kimi as gate, "leave open unless the owner authorises the merge") is superseded by AGENTS.md (Codex `gpt-6.1-sol`, standing merge authorisation); #143 stays open by item 1.
5. **The team identifier** names the owner's account and the repository is public: it lives only in a git-ignored local file, and the hygiene check fails if it appears in any tracked file.
6. **Results in a public document** could leak private data: `device-checks.md` and the build log carry pass / fail, device model, system version, build, date and a neutral note only (decision 9).
7. **README's status line** is stale; corrected in passing.

## Acceptance criteria

Of this pull request (part A):

1. **Release check.** `python3 ios/Tools/check_release.py --derived-data <dir>` builds an unsigned Release archive for `generic/platform=iOS` and exits 0, having checked: no needle of the seam table in any file of the app bundle; no `*.debug.dylib` or `__preview.dylib`; `ITSAppUsesNonExemptEncryption` false; `PrivacyInfo.xcprivacy` at the bundle's root, parsing, with tracking false and the declarations of decision 2; hygiene (criterion 4).
2. **The control: a Release archive with DEBUG forced.** `check_release.py --control <dir>` builds the same unsigned Release archive with DEBUG defined for the app and the package, and exits 0 only if **every** needle is found in it; a needle not found is named. This archive is the planted failure for "a Release binary contains no debug seam": run through the criterion-1 search it fails.
3. **No seam file unlisted.** The script compares the set of Swift files under `ios/NewsPaw` and `ios/NewsPawKit/Sources` containing `#if DEBUG` (a plain text search) with its needle table plus its exempt list, and fails naming any file in one set and not the other.
4. **Hygiene.** Fails when: a tracked path matches `*.p12`, `*.p8`, `*.cer`, `*.mobileprovision`, `*.provisionprofile` or is `ios/Config/Signing.local.xcconfig`; `project.pbxproj` contains `DEVELOPMENT_TEAM`, `DevelopmentTeam`, `PROVISIONING_PROFILE` or `CODE_SIGN_IDENTITY`; or, when the local signing file exists, `git grep -F <its team>` finds the team in any tracked file.
5. **Planted failures**, each exit 1 naming the cause: the forced-DEBUG archive (criterion 2); a copy of the archive without `PrivacyInfo.xcprivacy`; a copy with `ITSAppUsesNonExemptEncryption` true; a copy whose manifest lacks the `UserDefaults` declaration; a new file with `#if DEBUG` in a scratch clone; in a scratch clone with a local signing file, the team written into a tracked document, `DevelopmentTeam = …` in `project.pbxproj`, and a tracked `*.p12`.
6. **Signing without the team in the repository.** Both configurations are based on the committed `ios/Config/Signing.xcconfig`, which optionally includes the git-ignored `Signing.local.xcconfig`; `xcodebuild -showBuildSettings` shows the local team when the file exists and none when it does not; AGENTS.md's three checks pass in both states.
7. **`archive.sh` refuses** (exit 1, nothing built): a dirty work tree; a shallow clone; HEAD not `origin/main` or an ancestor of it (after a fetch); a missing or malformed local signing file. An interrupted run leaves nothing at the final archive path.
8. **`upload.sh` refuses**, before its upload command: without `--confirm`; with a `--confirm` different from the archive's `<version>-<build>`; with `CI` or `GITHUB_ACTIONS` set; an archive without `build-info.txt` or whose recorded commit is not an ancestor of `origin/main`; an archive failing `check_release.py --inspect`. Each refusal is shown with `--dry-run`, which runs every check and prints the upload command instead of running it. `upload.sh` is not run without `--dry-run` in this pull request.
9. **Export options** (`ios/Config/ExportOptions.plist`): `method` `app-store-connect`, `destination` `export`, `signingStyle` `automatic`, `manageAppVersionAndBuildNumber` false, `testFlightInternalTestingOnly` true, `uploadSymbols` true; no `teamID`.
10. **`.gitignore`** adds `ios/Config/Signing.local.xcconfig`, `*.p12`, `*.p8`, `*.cer`, `*.mobileprovision`, `*.provisionprofile`, `*.xcarchive`, `*.ipa`, `.afk/`.
11. **The owner's guide** `docs/reader/testflight.md` (decision 8), every unverified click path marked, an empty build log.
12. **The device-checks document** `docs/reader/device-checks.md` (decisions 9–11): rules, the M1 sheet with every cell empty, the upgrade check, every appendix row with status "not done", the known gaps.
13. **AGENTS.md** "Checks" gains decision 7's paragraph; README lists the two documents.
14. **No secret** in the repository at the final commit (criterion 4 run there, and a reading of the diff and the pull request body).

Of the issue, after the pull request (the owner's; not claimed by the pull request):

15. A TestFlight build installs on the three devices and a later one upgrades over it without losing data.
16. Every M1 step has a result per device; each failure is an open issue named in its cell.

## Frozen issue contract

**In scope (pull request).** `ITSAppUsesNonExemptEncryption`; the app's privacy manifest; `ios/Config/Signing.xcconfig`, `ExportOptions.plist` and the project's base-configuration references; `ios/Tools/check_release.py`, `archive.sh`, `upload.sh`; `.gitignore`; the two documents; AGENTS.md "Checks"; README.

**In scope (later, under this issue).** The owner's steps; the first archive; uploads on the owner's authorisation; recording results and the build log in documentation-only pull requests; one issue per failed M1 step.

**Out of scope.** App Store submission; external or public testing; an API key; any CI job that archives, signs or uploads; fastlane or any new tool or dependency; crash-reporting or analytics SDKs; "Open in" for `.newspaw`; fixing what the walk finds (each its own issue); changing the minimum system or the marketing version. The bundle identifier changes only if A6 fails.

**Others own.** Each merged issue: the fixes its device checks find. The App Store edition (spec section 8): store privacy answers, the encryption declaration, the scene manifest.

**Invariants.** A build is uploaded (by `upload.sh` or the Organizer) only on the owner's authorisation naming that build. No signing material and no team identifier in a tracked file. A Release binary contains no debug seam. CI's three checks are unchanged.

## Assumptions

In the order the implementer measures them; A1–A5 before anything is written, A6–A12 at the first archive and upload.

| Assumption | Measured first by | If it does not hold |
| --- | --- | --- |
| A1. `SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG` on the `xcodebuild archive` command line reaches the NewsPawKit package targets as well as the app | The control archive: `FixtureTransport` (package) and `DebugLaunchOptions` (app) both found | `OTHER_SWIFT_FLAGS=-DDEBUG`; if neither reaches the package, report to the driver before going on |
| A2. A project-level base configuration with `#include? "Signing.local.xcconfig"` gives both targets the local team and is silent without the file; the synchronised groups are undisturbed | `-showBuildSettings` and AGENTS.md's checks in both states | `archive.sh` passes `DEVELOPMENT_TEAM` on the command line from the local file; report |
| A3. `ios/NewsPaw/PrivacyInfo.xcprivacy` lands at the bundle's root | `check_release.py` | Add it to the target's resources explicitly |
| A4. The package's and the app's `#if DEBUG` blocks are compiled out of a Release archive | `check_release.py` | Stop; the leak is a defect of its issue |
| A5. An unsigned archive has the bundle content of a signed one apart from signatures | `archive.sh` inspects the signed archive too | The signed inspection counts |
| A6. `io.newspaw.reader` can be registered under the owner's team (App IDs are unique across teams) | The first `archive.sh` run, or the owner at Identifiers › "+" | The owner picks another identifier **before any install**: `PRODUCT_BUNDLE_IDENTIFIER` changes for both targets (UI tests `<id>.uitests`); the keychain service, the background-task identifier and the UTType are plain strings that need not change |
| A7. The first automatic-signing archive registers the App ID and may need one registered device (to verify at the first upload) | The first `archive.sh` run | Owner step O2 |
| A8. Export with automatic signing obtains an Apple Distribution certificate for the Account Holder without a manual step (to verify at the first upload) | The first export | Xcode › Settings › Accounts › Manage Certificates › "+" › Apple Distribution, by the owner |
| A9. `xcodebuild -exportArchive` with `destination` `upload` uploads under the account signed in to Xcode, with no API key (to verify at the first upload) | The first authorised upload | The owner uploads from the Organizer |
| A10. App Store Connect accepts the build: Xcode 27.1 (27A9275) is a release toolchain; icon; no scene manifest; the privacy manifest (whether ITMS-91053 blocks or warns); build numbers near 1,000; internal-only flag; with the encryption key, no compliance question; no review for internal testing; 90-day expiry (to verify at the first upload) | The upload's result, the e-mails, App Store Connect's TestFlight page | Packaging causes fixed under this issue; others become issues |
| A11. No purpose-string warning (ITMS-90683): RD10 declares no camera, microphone, location or photo use and cancels file prompts (to verify at the first upload) | The upload's e-mail | Report; a key only by the owner's decision (RD10) |
| A12. A development install from Xcode over a TestFlight install keeps the app's container and keychain items (to verify) | The first Debug build run on a device under decision 9's rule | Record it; the rule keeps the owner's library safe either way |

## Approach

**1. The split.** Part A is implemented, checked and reviewed like any issue. Part B is the owner's (For the owner, O1–O8). The driver does the steps between (writing the local signing file, running `archive.sh`, uploading on authorisation, recording results).

**2. Release readiness.**
- `NewsPaw-Info.plist`: `ITSAppUsesNonExemptEncryption` false (the owner's declaration as account holder; For the owner 3).
- `ios/NewsPaw/PrivacyInfo.xcprivacy`: tracking false; no tracking domains; no collected data types (text goes only to services the owner configures; revisited by the App Store edition); `NSPrivacyAccessedAPICategoryUserDefaults` `CA92.1`, `NSPrivacyAccessedAPICategoryFileTimestamp` `C617.1`. The implementer re-searches the app and package for Apple's categories (user defaults; file timestamp APIs; boot time `systemUptime`, `mach_absolute_time`; disk space; active keyboards) and declares exactly what is found, recording `BoundedFileRead.swift:18` and the reasoning above in the pull request.
- Nothing else in the plist changes; App Store Connect validates the rest at upload with a precise message (A10).

**3. Debug seams.** The rule: a seam is compiled only in debug builds and active only under a UI-test library directory. The check searches the bytes of every regular file inside the Release `NewsPaw.app` for needles. A needle must be of a kind that survives an archive's stripping and `-O`: a **type name**, a **stored instance property name**, a **string literal of 16 bytes or more**, or an **Objective-C selector**. Function names, argument labels and static names live only in the symbol table and are not needles. The control (criterion 2) proves each needle would be found if its seam leaked; the file-set comparison (criterion 3) makes a new seam file fail until it is listed.

Needles known now (the implementer completes the table under the rule):

| File | Needle |
| --- | --- |
| `UITestIdentifiers.swift` | `NEWSPAW_UITEST_LIBRARY_DIRECTORY`, `debug.deliverBackgroundRefresh` (literals) |
| `DebugLaunchOptions.swift` | `DebugLaunchOptions` |
| `NewsPawKit/Feeds/FixtureTransport.swift` | `FixtureTransport` |
| `NewsPawKit/AI/FixtureModelHTTP.swift` | `FixtureModelHTTP` |
| `FixtureAuthenticator.swift`, `OPMLFixture.swift`, `ConfigurationFixture.swift`, `PageTranslationFixtures.swift` | their type names |
| `BrowserFixtures.swift` | `BrowserFixtures`, `_didPerformRedirection:newRequest:` |
| `BackgroundRefresh.swift` | `DebugClock`, `RecordingBackgroundScheduler` |
| `NewsPawApp.swift` | `setAnimationsEnabled` |
| `LibraryStore.swift` | `adultOpensForUITests` (stored instance property) |
| `AppModel.swift` | `showsDebugReport` |
| `CategoryModel.swift`, `SourceModel.swift`, `ReadingModel.swift` | `failNextSave`, `failNextSearch`; `Simulated failure for a UI test`, `The UI tests' failing search read` |
| `ImageCache.swift` | `storeWillWrite` |

Exempt (no surviving needle; listed in the script with the reason): `ModelAddress.swift` (chooses a value; Release behaviour is device check A4), `KeychainKeyStore.swift` (a debug-only `init`), `BrowserDataStores.swift` (a static function); any further file the implementer finds of this kind, each with its reason in the pull request. Exempt files are still in the file set of criterion 3.

**4. Signing: the team from a local file.** `ios/Config/Signing.xcconfig` (committed) explains the local file and its one line `DEVELOPMENT_TEAM = <ten characters>`, warns never to pick a team in Xcode's Signing & Capabilities pane (Xcode writes it into the project file), and ends with `#include? "Signing.local.xcconfig"`. It is the project-level base configuration of Debug and Release; the targets keep automatic signing. It is the template; no other template file. CI is unaffected. The Team ID comes **only from developer.apple.com › Account › Membership details of the owner's paid account**; when Xcode lists several teams, the one whose role is Account Holder for that membership. It is never read from a certificate on the Mac. The driver writes the local file after the owner sends the Team ID.

**5. Build numbers.** `CFBundleVersion` = `git rev-list --count HEAD`, passed as `CURRENT_PROJECT_VERSION=<n>` (957 at `44da16e`); nothing committed per build. `archive.sh` archives only `origin/main` or an ancestor of it, so the number names a commit on `main` and grows along it. `manageAppVersionAndBuildNumber` false keeps Xcode from renumbering. The marketing version stays `0.1.0` through M1.

**6. Scripts.**
- `check_release.py` (standard library, the style and exit codes of `check_strings.py`): `--derived-data <dir>` (build and check), `--control <dir>` (forced-DEBUG archive, every needle found), `--inspect <archive>` (check an existing archive, used by the other two scripts). Unsigned archives: `xcodebuild archive -project ios/NewsPaw.xcodeproj -scheme NewsPaw -configuration Release -destination 'generic/platform=iOS' -archivePath … -derivedDataPath … -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO` (plus `SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG` for the control, A1).
- `archive.sh` (bash 3.2, `set -euo pipefail`): the refusals of criterion 7; a fresh temporary derived-data folder; archive into a temporary path with `-allowProvisioningUpdates CURRENT_PROJECT_VERSION=<n>`; `check_release.py --inspect`; on success move it to `~/Library/Developer/Xcode/Archives/<date>/NewsPaw <version> (<build>).xcarchive` (where the Organizer lists it) and write `build-info.txt` beside it (version, build, full commit, date, `xcodebuild -version`); export locally with the committed options; print the signed app's entitlements **with the team prefix masked** (`<team>.io.newspaw.reader`), failing when `get-task-allow` is true. Nothing is written into the repository.
- `upload.sh`: `upload.sh <archive> --confirm <version>-<build> [--dry-run]`. The refusals of criterion 8; a temporary copy of the export options with `destination` `upload`; `xcodebuild -exportArchive … -allowProvisioningUpdates`. The `--confirm` value is **copied from the owner's message** naming the build, never derived from the archive by the driver; the script cannot tell who typed it, so the authority is the message, quoted with its date in the build log. Default route: the driver runs it after that message. Fallback: the owner uploads the same archive from the Organizer.

**7. AGENTS.md "Checks".** One paragraph: `python3 ios/Tools/check_release.py --derived-data <dir>` builds an unsigned Release archive and checks it for debug seams, the encryption key, the privacy manifest and signing material in the repository; `--control <dir>` builds a Release archive with DEBUG forced and confirms every needle is found there; both run locally with the Mac's Xcode (CI does not run them) for a pull request that changes a debug seam, `NewsPaw-Info.plist`, the privacy manifest, `ios/NewsPaw.xcodeproj/`, `ios/Config`, `ios/Tools` or `.gitignore`, and before every archive. And: "A build is uploaded (by `upload.sh` or the Organizer) only on the owner's authorisation naming that build." No CI job, no package or UI test: no behaviour changes.

**8. The owner's guide (`docs/reader/testflight.md`).** Numbered, plain English; every click path marked (to verify at the first upload).
1. *Who does what* — decision 12's order.
2. *Sign in to Xcode* — Xcode › Settings… › Accounts › "+" › Apple Account; send the driver the Team ID from developer.apple.com › Account › Membership details (the paid membership); never pick a team in Signing & Capabilities; accept any agreement waiting on developer.apple.com.
3. *If asked: register the iPhone* — connect by cable, unlock, Trust.
4. *Check the identifier, create the app record* — if the driver's first archive could not register `io.newspaw.reader`, decide the replacement identifier before anything is installed (A6). App Store Connect › Apps › "+" › New App: iOS; name "NewsPaw" (else "NewsPaw Reader"); English (U.S.); bundle ID; SKU `newspaw-reader`; Full Access.
5. *Add yourself as an internal tester* — TestFlight › Internal Testing › "+" › group "Owner", automatic distribution on › add yourself.
6. *Authorise the upload* — a message "upload <version>-<build>"; or upload from Xcode › Window › Organizer › Archives › Distribute App › TestFlight Internal Only.
7. *Install* — TestFlight app on each device › Install. The first install on each device is the M1 walk's fresh install; if NewsPaw was ever run there from Xcode, delete it first.
8. *Upgrade* — TestFlight › NewsPaw › Update, never delete and reinstall; then the upgrade check.
9. *Debug builds on your devices* — decision 9's rule 6.
10. *What to send back* — per device: model, system version, the build from Settings › About, per step pass or fail with one neutral sentence; for a crash, send TestFlight's crash feedback when it offers it (the driver reads it in Xcode › Organizer › Crashes, to verify); never a source address, site name, key, model name, Apple ID, device name or screenshot of adult content. Chinese is fine.
11. *Build log* — version, build, commit, archived, uploaded (date and the authorising message), processing result, expiry, notes. Entitlements are never pasted unmasked. Empty in the pull request.

**9. `docs/reader/device-checks.md`.** Rules at the top:
1. Done only on a real device with a TestFlight build, or a Debug build where the row says so (rule 6); never the simulator.
2. Status: `not done`, `done`, `failed → #<issue>`, `declined` (with the reason). `done` names device model, system version, build and date.
3. Nothing private: no source address, site name, account, key, model name beyond the service preset, adult content, team identifier, Apple ID, device name or serial, or tester's e-mail. The build log follows the same rule.
4. The driver records results from the owner's reports in documentation-only pull requests; a failure gets its issue first.
5. An item owed by several pull requests is one row naming each; nothing owed is dropped (the appendix is the derivation).
6. A Debug build on an owner's device is built from the commit of the TestFlight build installed there (`build-info.txt`), only after that device's M1 walk and upgrade check, and the TestFlight build is reinstalled from TestFlight afterwards. A Debug build from a later commit could carry a newer migration and leave the library unreadable by the TestFlight build (`LibraryError.newerSchema`). Whether the container survives a development install is A12.

Sections: 1, the M1 sheet; 2, install and upgrade; then the appendix's families as tables (ID, check, source, devices, steps in one or two lines, status per device); last, the known gaps that are not device checks.

**10. The M1 sheet.** Rows: spec section 7's seven steps — (1) on a fresh install, enter a normal-partition key and pass Test; (2) add or import a few feeds; (3) the list shows translated titles; (4) open an excerpt-only article, read the extracted full text and get its translation; (5) open a web-page source, translate it with one tap, follow a link and find the next page translated, then show the original; (6) turn on the adult partition, add one feed and one web-page source, lock, and find no trace in the normal partition; (7) export the configuration and import it on another device (the cycle of Spec review 3), keys entered again. Columns: iPhone 18 Pro Max, iPad mini (8th generation), iPad Pro 11-inch (M4); cells empty, later `pass` or `fail → #n` with build, system and date. "Open failures" lists each failing cell with its issue. #143 can close with failures open (its criterion 2); **M1 is done only when every cell passes**, and the sheet says so.

**11. Upgrade without data loss.** Protected by: the same bundle identifier and team (local file, hygiene check); the container surviving an update (libraries in Application Support `Libraries/`, preferences, the adult browser's own data store; Caches may be purged, which is not data loss); keys as data-protection keychain items `AfterFirstUnlockThisDeviceOnly` in the default access group, kept by an update; migrations `v1`–`v10` with `SchemaTests` migrating older fixtures with rows and refusing a newer database. The device check, on each device: on build N after the walk, note Usage's counts, the numbers of categories, sources and starred articles, one read article, one translated title; update to N+1 in TestFlight; then: no first run; the same categories, sources, starred and read states; translated titles shown; Test passes in the normal slot without re-entering the key; the adult partition still on, asking for authentication, its feed and web-page source there, its Test passing, a site signed in to in its browser still signed in; Usage's earlier rows there. A migration between two TestFlight builds is covered by the package tests unless N+1 adds one.

**12. Order after the pull request.** O1 → driver writes the local file and runs `archive.sh` (O2 if asked; A6 settled here) → O3 → O4 → O5 → O6 walk and report → driver records results (the next commit on `main`) and opens issues → O7 build N+1 and the upgrade check → device checks at the owner's pace → #143 closes when criteria 15 and 16 are recorded.

## Files to change

| File | Change |
| --- | --- |
| `ios/NewsPaw-Info.plist` | `ITSAppUsesNonExemptEncryption` false |
| `ios/NewsPaw/PrivacyInfo.xcprivacy` | New |
| `ios/Config/Signing.xcconfig`, `ios/Config/ExportOptions.plist` | New |
| `ios/NewsPaw.xcodeproj/project.pbxproj` | A `Config` group with the xcconfig's reference; project-level `baseConfigurationReference` for Debug and Release (made in Xcode, diff checked) |
| `ios/Tools/check_release.py`, `archive.sh`, `upload.sh` | New |
| `.gitignore` | Criterion 10 |
| `docs/reader/testflight.md`, `docs/reader/device-checks.md` | New |
| `AGENTS.md` | Decision 7's paragraph |
| `docs/reader/README.md` | Status line; two rows |

No Swift source, string catalog, manifest or lock file changes.

## Execution surface

`check_release.py`: local unsigned archives in the given folder; no network beyond resolving pinned packages. `archive.sh`: Apple's developer services under the owner's Xcode account; writes in `~/Library/Developer/Xcode/Archives` and temporary folders; run only after O1. `upload.sh`: App Store Connect; run only on the owner's authorisation. CI: unchanged.

## Failure handling

| Failure | Behaviour |
| --- | --- |
| A needle found in the Release app | Exit 1 naming needle and file; `archive.sh` stops before export; the seam's issue gets a defect |
| A needle not found in the control | Exit 1 naming it; the needle is replaced by one of a surviving kind or the file exempted with its reason |
| A seam file not in the table or the exempt list | Exit 1 naming it |
| Encryption key or manifest wrong | Exit 1 naming it |
| Signing material or the team in a tracked file | Exit 1 naming the path (the team itself is not printed) |
| Dirty tree, shallow clone, HEAD off `main`, local file missing or malformed | `archive.sh` exits 1 before building |
| `archive.sh` interrupted | Only the temporary path is left; the next run starts clean |
| Identifier taken (A6) | The owner chooses another before any install; one pull request changes it |
| Signing needs a device or a certificate (A7, A8) | `xcodebuild`'s error; O2 or the certificate fallback |
| Upload refused by Apple | Message recorded in the build log; packaging causes fixed here, others become issues |
| `upload.sh` without or with a wrong `--confirm`, in CI, foreign archive | Exit 1 before the upload command |
| An M1 step fails | Issue opened; cell `fail → #n`; the walk continues where it can |
| A crash during the walk | TestFlight's crash feedback; the driver reads it in the Organizer and opens an issue |
| The owner declines a check | `declined` with the reason; the row stays |

## Risk assessment

- **Apple steps not verifiable here** (A6–A12): corrected in the guide after the first run, which the owner and the driver do together.
- **The project-file edit**: caught by AGENTS.md's checks in both states of the local file.
- **A team identifier published** by the public repository: the `git grep` check, masked entitlements, the documents' rule.
- **The owner's real library** harmed by a Debug build from a later commit: rule 6.
- **Mac Xcode 27.1 versus CI's 26.6**: archives use the Mac's; CI keeps 26.6 compiling the code.
- **Upload by accident**: the committed export options only export; `upload.sh` needs the exact `<version>-<build>` and refuses in CI.

## Test plan

- **Package and UI tests:** none added. AGENTS.md's three checks pass with and without the local signing file.
- **Runs reported in the pull request:** `check_release.py --derived-data` → 0; `--control` → 0 (every needle found); `-showBuildSettings` both states.
- **Planted failures:** criterion 5's list; `archive.sh`'s refusals of criterion 7 in scratch clones; `upload.sh --dry-run` showing each refusal of criterion 8 and, on a valid archive with a matching `--confirm`, printing the upload command without running it.
- **Not run in the pull request:** `archive.sh`'s signed path and any upload (no account on the Mac).

## Handoff notes

- A later issue that adds a debug seam adds a needle of a surviving kind (or an exempt entry) — criterion 3 fails until it does — and runs `--control`. A new required-reason API adds a manifest entry.
- After the first run the driver corrects `testflight.md`, resolves the "to verify" marks, and updates spec section 10's TestFlight sentence.
- Fixes found by the walk are new issues; RD22's record is updated when they pass on a device.
- The whole UI suite on `main` at `44da16e` belongs to the batch process, not RD22.

## For the owner

Steps only you can do, in order:

- **O1. Sign in to Xcode** with the paid Apple Developer account and send the driver the Team ID from Membership details of that account. Unblocks signing; the driver's first archive also tells whether `io.newspaw.reader` is free.
- **O2. Only if asked:** connect the iPhone by cable once and trust the Mac. Unblocks the first signed archive.
- **O3. Create the App Store Connect record** (after choosing another identifier if `io.newspaw.reader` is taken). Unblocks uploads.
- **O4. Add yourself as an internal tester.** Unblocks installing.
- **O5. Authorise the upload of build N** in a message naming it. Unblocks the walk.
- **O6. Install on the three devices and walk the M1 sheet**; report per device.
- **O7. Authorise build N+1, update over N,** run the upgrade check.
- **O8. Device checks** at your pace; any you do not want are "declined".

Choices you would notice, with the default taken:

1. **Who uploads.** The driver, after your message naming the build; or you, from the Organizer.
2. **Builds are "TestFlight internal only"** (no external testers, no App Store). On.
3. **Export compliance:** "no non-exempt encryption" (only the system's HTTPS and keychain); your declaration as account holder. Declared "no".
4. **Build numbers** are the commit count on `main` (around 1,000), shown in About as "0.1.0 (1012)"; the version stays 0.1.0 through M1.
5. **App Store Connect name** "NewsPaw", or "NewsPaw Reader" if taken; the home screen shows "NewsPaw". SKU `newspaw-reader`.
6. **If `io.newspaw.reader` is taken**, you choose another identifier before anything is installed; nothing you see in the app changes.
7. **Your Team ID** stays on your Mac only; the repository is public.
8. **The privacy manifest declares no data collection.**
9. **Debug symbols go to Apple** with each upload, so TestFlight crash reports are readable. On.
10. **What the documents record:** pass or fail, device model, system, build, date, a neutral sentence; never your sources, sites, keys, model names, Apple ID or device names.
11. **Two uploads** are needed for the upgrade check.
12. **Debug builds on your devices** only from the installed build's commit, only after that device's walk and upgrade check, and TestFlight's build reinstalled afterwards.
13. **Heavier checks** (a device without a passcode, a backup restore, a network log, Instruments, Xcode's background-task commands) can be "declined".

## Revision record

- Version 1, 2026-11-19: first draft against `44da16e`.
- Version 2, 2026-11-19: after critic round 1 (SOUND WITH FIXES, no P1), with the driver's triage. The repository's being public is stated in the header and carries the hygiene decisions; the documents' private-data rule now also excludes the team identifier, Apple IDs, device names and serials, and testers' e-mails.

| Finding | Outcome |
| --- | --- |
| F1 (P2) the Debug-app control proves nothing about a stripped Release archive; some needles would not survive | Admitted: the control is a Release archive with DEBUG forced (criterion 2, A1 with its fallback); needles only of surviving kinds; exempt list with reasons; file-set comparison (criterion 3); AGENTS.md names the forced-DEBUG archive (decisions 3, 7) |
| F2 (P2) public repository: `DevelopmentTeam` missed, project file not a trigger, entitlements print the team | Admitted: `git grep -F` of the local team, `DevelopmentTeam` pattern (criterion 4); `ios/NewsPaw.xcodeproj/` and `.gitignore` trigger the check (decision 7); masked entitlements and the build-log rule (decisions 6, 8); `.afk/` ignored (criterion 10) |
| F3 (P2) identifier availability; Team ID from the wrong account | Admitted: A6 with what changes if taken; Team ID only from Membership details of the paid account (decision 4); both under "For the owner" |
| F4 (P2) Debug builds can break the owner's TestFlight library | Admitted: rule 6 (decision 9), guide section 9, A12 |
| F5 build number off `main` | Admitted: `archive.sh` refuses unless HEAD is `origin/main` or an ancestor (criterion 7, decision 5) |
| F6 confirmation is a typo guard; AGENTS.md should cover both routes | Admitted in part, by the driver's decision: `upload.sh` kept as small as it can be — `--confirm` required and copied from the owner's message, refusals for mismatch, CI and archives not from `archive.sh` on `main`; the interactive prompt and the stand-in `xcodebuild` tests dropped for `--dry-run`; AGENTS.md's sentence covers both routes |
| F7 plist checks restate the project | Admitted: the archive checks keep the encryption key, the manifest, the debug dylibs, the seams and hygiene; the rest and the licence check (covered by `ThirdPartyNoticesTests`) dropped |
| F8 A6's quotation out of context | Admitted: the quotation dropped; now A8 with its fallback |
| F9 30 files; `BoundedFileRead.swift:18`; release toolchain | Admitted: corrected; recorded with the reasoning (decision 2); toolchain in A10 and `xcodebuild -version` in `build-info.txt` |
| F10 interrupted archive; crash route | Admitted: temporary path moved on success; crash feedback in "What to send back" |
| Appendix slip (#169's Pinyin check with the software keyboard) | Fixed: K2 |

## Appendix: the device checks owed

Derived from the "Not verified", "Device checks owed" and "Verified on a real device" sections of pull requests #150–#184 (the members #172–#180 point to the batches #181–#184), the driver's facts for batches 2–4, N13's list, the issue's families and spec section 10. Every item that needs a real device, network or service, real hardware, or a person's eyes and hands is a row; one row per item, naming each source. #150, #158, #166 and #171 owe nothing device-specific. The implementer copies these rows; a row may be split, never dropped. Devices: P = iPhone 18 Pro Max, M = iPad mini (8th generation), I = iPad Pro 11-inch (M4); "any" = one of the owner's choice.

**A. Install and upgrade (N13)**

| ID | Check | Source | Devices |
| --- | --- | --- | --- |
| A1 | Build N installs from TestFlight; About shows version and build | RD22 | P M I |
| A2 | Build N+1 updates over N without losing data (decision 11) | RD22 criterion 1 | P M I |
| A3 | TestFlight shows the build without a review, expiring about 90 days out | spec §10 | any |
| A4 | A model address `http://127.0.0.1…` is refused in the TestFlight build | N08; RD13 #160 | any |
| A5 | Whether the libraries are in a device backup and come back on restore (observed) | RD02 #151 | any |

**B. Authentication and locking (N09)**

| ID | Check | Source | Devices |
| --- | --- | --- | --- |
| B1 | Face ID: success, failure, passcode fallback | RD18 #162 | P I |
| B2 | Touch ID: success, failure, passcode fallback | RD18 #162 | M |
| B3 | A device without a passcode: turning on and entering the adult partition | RD18 #162 | any |
| B4 | Each lock timing (on leaving, 1 min, 5 min, manual) on iPhone, and on iPad full screen, in a window and beside another app | RD18 #162 | P M I |
| B5 | Return after a timed lock with a sheet, the share sheet or a context menu open, animations on: no adult content visible at any moment | RD18 #162 | P I |
| B6 | Home in an iPad window that is not full screen locks | RD18 #162 | M I |
| B7 | Video and Web Audio in the adult browser stop when leaving and at a lock | RD18 #162 | any |
| B8 | Moving a normal category to the adult partition with Face ID | RD19 #182 | P |
| B9 | The real prompt right after the Files picker, and two prompts in a row ("Turn On and Unlock"), on Face ID and Touch ID | RD20 #182 (A5) | P M |
| B10 | Keychain: add, read, remove a key; read after the screen locks; no "Save Password?" sheet, no Passwords bar | RD13 #160 | P |
| B11 | A real key in both partitions: two keychain items; removing one leaves the other | RD19 #182 (S10) | any |
| B12 | Whether UIKit releases the adult model objects after a lock (Debug build under rule 6, memory graph) | RD18 #162 | any |

**C. The app-switcher cover (N09)**

| ID | Check | Source | Devices |
| --- | --- | --- | --- |
| C1 | With the adult partition shown, the app switcher shows the cover: plain, with a sheet open, with the keyboard up | RD18 #162 | P M I |
| C2 | The same in an iPad window and beside another app | RD18 #162; RD03 #152 | M I |

**D. Configuration file and OPML between devices (N10)**

| ID | Check | Source | Devices |
| --- | --- | --- | --- |
| D1 | AirDrop a `.newspaw` file, save in Files, import from Settings › Data: same categories and sources; keys entered again | RD20 #182 (A6); N13; M1 step 7 | P→M, M→I, I→P |
| D2 | Inside the adult partition: Export, Save to Files, import again | RD20 #182; RD08 #169 | any |
| D3 | On iPad: Import Configuration from Add Source closes the sheet and opens the import; the delay before the picker | RD20 #182 (A3) | M I |
| D4 | OPML: the Files picker on iPad; AirDrop from the share sheet; Save to Files and import again | RD08 #169 | M I, P |
| D5 | An OPML exported by another reader imports | RD08 #169 | any |
| D6 | OPML export in the adult partition from start to finish | RD08 #169 | any |

**E. Sources, refresh and reading on real feeds (N03–N05)**

| ID | Check | Source | Devices |
| --- | --- | --- | --- |
| E1 | An http-only feed is added and refreshed | RD05 #154; RD04 #153 | any |
| E2 | Paste pastes without a permission prompt | RD05 #154 | P |
| E3 | The owner's feeds — long, many images, Chinese, Japanese, cut content — on the reading screen; a long article's open time in this build | RD11 #161; RD04 #153 | P M |
| E4 | Thumbnails from real feeds in the lists | RD09 #156 | P I |
| E5 | Refresh on opening after the interval; a return from Control Centre is not an entry; "Updated …" moves on while open | RD06 #155 | P |
| E6 | Leaving during a refresh (also long enough to reach the background-time expiry) leaves no source falsely failing | RD06 #155 (criterion 15) | P |
| E7 | Pull to refresh on Today and in a list, iPhone and iPad, portrait and landscape; "Updating…" while pulling; on the iPad Pro in portrait Today's pull starts a run | RD06 #155; RD09 #156; RD23 #184 | P M I |
| E8 | GitHub: add a repository over a real network; it refreshes a day later | RD07 #163 | P I |
| E9 | Hugging Face: add `huggingface.co/DeepSeek-AI`, compare the preview, refresh; an account answering with a redirect | RD26 #181 | any |
| E10 | Search: a cold first search on a large library | RD25 #181 | any |
| E11 | Scrolling a long list by hand | RD09 #156 | P M |
| E12 | Open Original Page and Open in Browser reach Safari; Share from a row | RD09 #156 | P |
| E13 | Reading screen: serif face for Chinese; swipes against the back gesture; image zoom with fingers; selecting and copying; "Aa" in iPhone landscape; the hidden tab bar on iPhone; the reader's place after the browser on iPad | RD11 #161; RD09 #156 | P I |
| E14 | With list thumbnails off, no thumbnail request reaches the network (needs a network log) | RD19 #182 | any |

**F. Extraction and the browser on real pages (N05, N12)**

| ID | Check | Source | Devices |
| --- | --- | --- | --- |
| F1 | Five excerpt-only sources: full text extracted; a paywalled page, a news article, a Chinese blog, a page needing JavaScript (falls back), a site answering the app differently from a browser | RD12 #164 | P |
| F2 | Reader mode on an article page and a script-built page; a large page's extraction time; a page left under a temporary article for minutes | RD12 #164 | P I |
| F3 | Browser: a real https and a real http site; an attachment ("This link is a file"); a universal link (YouTube or Maps) stays in the browser; Open in Safari; `mailto:` reaches Mail after "Open"; Share; a login survives a relaunch; a page with video; a web content process that ends ("The page stopped working.") | RD10 #159 | P I |
| F4 | The bottom bar is legible over light and dark pages | RD10 #159 | P |
| F5 | A file input's options: nothing needing a usage description, no crash (camera) | RD10 #159 | P |

**G. Page translation on the owner's sources (N06)**

| ID | Check | Source | Devices |
| --- | --- | --- | --- |
| G1 | Five web-page sources: translate with one tap, follow a link, the next page translated, show the original | RD16 #183; M1 step 5 | P M I |
| G2 | A signed-in page, an infinite list, a single-page site | RD16 #183 | any |
| G3 | A page restored from the back-forward cache after translation was turned off | RD16 #183 | any |
| G4 | A search field with live suggestions, software and hardware keyboard | RD16 #183 | I |
| G5 | A real tap on a radio tab (limit 16) | RD16 #183 | any |
| G6 | A real page that stops responding while translated (A7) | RD16 #183 | any |
| G7 | The status line at the largest text size on the iPad mini | RD16 #183 | M |

**H. Real model services (N06–N08, N11)** — one status per service the owner uses (presets: OpenAI, DeepSeek, xAI, MiMo, OpenRouter, Gemini). OpenAI and DeepSeek passed body and page translation against the real services in the simulator at `b1dec86`; recorded as a note, not counted.

| ID | Check | Source | Devices |
| --- | --- | --- | --- |
| H1 | Test: passed; wrong key → key rejected; wrong model → model not found | RD13 #160; spec §10 | any, per service |
| H2 | Titles in a real refresh, in each reading language; Traditional Chinese sources | RD14 #167 | any, per service |
| H3 | One long article's body: time to the first chunk, paragraphs arriving | RD15 #183 | any, per service |
| H4 | Page translation | RD16 #183 | any, per service |
| H5 | The daily overview from a real refresh, in each reading language; how it reads | RD23 #184 | any, per service |
| H6 | The first run on a fresh install with a real model | RD21 #181; M1 step 1 | P M I |
| H7 | Usage with real rows; number grouping in the device's region | RD17 #168 | any |
| H8 | Leaving during a refresh: no overview request afterwards; leaving while an overview request is refused: no second request | RD23 #184 | any |
| H9 | An adult Replace that repairs a model clears the overview card's error | RD23 #184 | any |

**I. Background refresh (N04)**

| ID | Check | Source | Devices |
| --- | --- | --- | --- |
| I1 | A delivered run collects and translates without the app opened; the runs line read daily over several days with how each run ended (observed) | RD24 #182 | P |
| I2 | Debug build under rule 6: `_simulateLaunchForTaskWithIdentifier:` with the app in the background; `_simulateExpirationForTaskWithIdentifier:` during a run and during a cold launch's opening | RD24 #182 (A1, G1) | P |
| I3 | A translation request in flight at expiry, then the app resumed: Usage, the pause ends on opening | RD24 #182 (R1) | P |
| I4 | A run while the device is locked after its first unlock reads the library and keys | RD24 #182 (A5); RD02 #151 | P |
| I5 | No source left failing after an expiry | RD24 #182 | P |
| I6 | Background App Refresh off; Low Power Mode | RD24 #182 | P |
| I7 | Opening the app during a run: "Updating…" continues, no second collection | RD24 #182 (G3) | P |
| I8 | A delivered run, then opening: the overview written once without a pull; a background launch sends no overview request | RD23 #184 | P |

**J. The adult browser's data (N09)**

| ID | Check | Source | Devices |
| --- | --- | --- | --- |
| J1 | A real sign-in in the adult browser survives a lock, is absent from the normal browser, and is removed by Clear and by Delete (and whether a store remains after Delete) | RD19 #182 | P |
| J2 | A page writing on a timer, left, then Clear: nothing written back | RD19 #182 (F1) | P |
| J3 | Criterion 6's cookie check by hand | RD19 #182 (F5) | P |

**K. Keyboard, VoiceOver, text size, contrast**

| ID | Check | Source | Devices |
| --- | --- | --- | --- |
| K1 | Hardware keyboard: list shortcuts on iPad and iPhone, J once per press, J loads the next page; `T` on the reading screen; search; the model form (with rotation); Done on New Category during an unfinished Pinyin composition | RD09 #156; RD15 #183; RD25 #181; RD13 #160; RD08 #169 | P I |
| K2 | Software keyboard: Pinyin and kana in search; Done on New Category during an unfinished Pinyin composition | RD25 #181; RD08 #169 | P |
| K3 | VoiceOver: a source row with its state and a category's disclosure; Today's status line, failure button, updating row; list rows and actions; the browser bars; the model form; an article body; a translated and a failed row; the GitHub rows; the reader-mode button and bar; the reading screen's header, a translated block, Side by Side; a translated page and the Translate toggle; an overview card (does the reading language reach VoiceOver); the first run, Hugging Face and search screens; Full Keyboard Access and VoiceOver during a save | RD05 #154; RD06 #155; RD09 #156; RD10 #159; RD13 #160; RD11 #161; RD14 #167; RD07 #163; RD12 #164; RD15, RD16 #183; RD23 #184; #181; RD03 #152 | P I |
| K4 | The largest text size: Today's status line, lists | RD06 #155; RD09 #156 | P M |
| K5 | Translation marks' tap targets by finger | RD14 #167 | P |
| K6 | Contrast of system-drawn parts (tab bar, sidebar selection, backgrounds), light and dark, by eye | RD03 #152 | P I |

**L. Layout on the real screens**

| ID | Check | Source | Devices |
| --- | --- | --- | --- |
| L1 | Split View and Stage Manager widths | RD03 #152 | M I |
| L2 | Overview cards at the iPad mini's real width | RD23 #184 | M |

**M. Animated transitions by hand** (off under the UI tests)

| ID | Check | Source | Devices |
| --- | --- | --- | --- |
| M1 | The translation activity mark and rows updating in place; reader mode; body paragraphs arriving with their fade and mode switches; Usage; OPML and configuration sheets; the first run, Hugging Face and search screens; overview Expand / Collapse and More / Less | RD14 #167; RD12 #164; RD15 #183; RD17 #168; RD08 #169; #181; RD23 #184 | P I |

**N. Memory and stability**

| ID | Check | Source | Devices |
| --- | --- | --- | --- |
| N1 | Memory with 100 images (Instruments; Debug build under rule 6, or the TestFlight build if Instruments attaches) | RD11 #161 | any |
| N2 | Memory over ten excerpt-only articles and over ten translated articles | RD12 #164; RD15 #183 | any |
| N3 | Scroll stability while chunks arrive and across mode switches, including the half-second pull-back | RD15 #183 | P |

**Known gaps that are not device checks** (the document's last section): RD03 — the swipe-to-dismiss lock during a save has no test; RD04 — the proxy 407 path and client certificates; RD05 — UI-test gaps (failed candidate row, "The first 5 are shown", "Not updated yet", Cancel's wiring, the tab-switch test's weakness); RD09 — row images shown by screenshot, not asserted; RD10 — a form with `enctype="text/plain"` or a file posted to a new window, a form post redirected or failing after its page began to show; RD11 — right-to-left layout; RD13 — a TLS 1.1 server refused, whether the system re-sends a POST on a stale connection; RD06 — the expiry handler on the main thread, relied on from Apple's documentation; the "by reading only" items of #181–#184; UI-suite classes not run at the batches' commits.
