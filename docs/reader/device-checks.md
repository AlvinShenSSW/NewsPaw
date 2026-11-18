# Device checks

Everything about NewsPaw Reader that only a real device can verify (spec N13; issue RD22 #143), with its status. The list was derived on 2026-11-19 from the "Not verified", "Device checks owed" and "Verified on a real device" sections of pull requests #150–#184, N13's list, issue #143's families and spec section 10 (the derivation is in the appendix of [designs/RD22-testflight.md](designs/RD22-testflight.md)). How a build reaches the devices is in [testflight.md](testflight.md).

Devices: **P** = iPhone 18 Pro Max, **M** = iPad mini (8th generation), **I** = iPad Pro 11-inch (M4); "any" = one device of the owner's choice.

## Rules

1. A check is done only on a real device with a TestFlight build, or with a debug build where the row says so (rule 6). The simulator never counts.
2. Status values: `not done`; `done` with device model, system version, build and date; `failed → #<issue>`; `declined` with the reason (the owner chose not to do it).
3. Nothing private, ever — the repository is public: no source address, site name, account, key, model name beyond the service preset, content of the adult partition, team identifier, Apple ID, device name or serial number, or tester's e-mail. A quoted error message has the team masked as `<team>`. A note is one neutral sentence.
4. The driver records results from the owner's reports, in documentation-only pull requests. A failure gets its issue before it is recorded.
5. An item owed by several pull requests is one row naming each source. Nothing owed is dropped; a row may be split.
6. A debug build on an owner's device is built from the commit of the TestFlight build installed there, only after that device's M1 walk and upgrade check, and the TestFlight build is reinstalled from TestFlight afterwards. A debug build from a later commit could carry a newer migration and leave the library unreadable by the TestFlight build. Whether a development install keeps the app's data is not yet known.

## 1. M1 acceptance (spec section 7)

Each cell: `pass` or `fail → #<issue>`, with build, system version and date. Issue #143 can close with failures listed as open; **M1 is done only when every cell passes.**

| Step | iPhone 18 Pro Max | iPad mini (8th generation) | iPad Pro 11-inch (M4) |
| --- | --- | --- | --- |
| 1. On a fresh install, enter a normal-partition key and pass Test | | | |
| 2. Add or import a few feeds | | | |
| 3. The list shows translated titles | | | |
| 4. Open an article whose feed has only an excerpt, read the extracted full text and get its translation | | | |
| 5. Open a web-page source, translate the page with one tap, follow a link and find the next page translated too, then show the original | | | |
| 6. Turn on the adult partition, add one feed and one web-page source, lock, and find no trace of them in the normal partition | | | |
| 7. Export the configuration and import it on this device from another one (iPhone from iPad Pro, iPad mini from iPhone, iPad Pro from iPad mini): the same categories and sources, keys entered again | | | |

**Open failures:** none recorded yet.

## 2. Install and upgrade (N13)

| ID | Check | Source | Devices | Steps | Status |
| --- | --- | --- | --- | --- | --- |
| A1 | Build N installs from TestFlight; About shows its version and build | RD22 | P M I | testflight.md section 7 | P: not done · M: not done · I: not done |
| A2 | Build N+1 updates over N without losing data | RD22 criterion 1 | P M I | On N after the walk, note Usage's counts, the numbers of categories, sources and starred articles, one read article and one translated title. Update in TestFlight. Then: no first run; the same categories, sources, starred and read states; translated titles shown; normal Test passes without re-entering the key; the adult partition still on, asks for authentication, its feed and web-page source there, its Test passes, a site signed in to in its browser still signed in; Usage's earlier rows there | P: not done · M: not done · I: not done |
| A3 | TestFlight shows the build without a review, expiring about 90 days out | spec §10 | any | Read App Store Connect's TestFlight page after processing | not done |
| A4 | A model address `http://127.0.0.1…` is refused in the TestFlight build | N08; RD13 #160 | any | Settings › model slot › address `http://127.0.0.1:8080/v1` › Save: refused | not done |
| A5 | Whether the libraries are in a device backup and come back on restore (observed, not a pass criterion) | RD02 #151 | any | Back up, restore to the same device, open NewsPaw | not done |

## 3. Authentication and locking (N09)

| ID | Check | Source | Devices | Steps | Status |
| --- | --- | --- | --- | --- | --- |
| B1 | Face ID: success, failure, passcode fallback | RD18 #162 | P I | Enter the adult partition with Face ID; fail it (cover the camera); fall back to the passcode | P: not done · I: not done |
| B2 | Touch ID: success, failure, passcode fallback | RD18 #162 | M | As B1 with Touch ID | not done |
| B3 | A device without a passcode: turning on and entering the adult partition | RD18 #162 | any | Remove the passcode temporarily; try to turn on and enter; restore the passcode | not done |
| B4 | Each lock timing (on leaving, 1 minute, 5 minutes, manual) | RD18 #162 | P M I | iPhone; iPad full screen, in a window, and beside another app | P: not done · M: not done · I: not done |
| B5 | Return after a timed lock with a sheet, the share sheet or a context menu open, animations on: no adult content visible at any moment | RD18 #162 | P I | Open each, leave, wait past the timing, return; watch the transition | P: not done · I: not done |
| B6 | Home in an iPad window that is not full screen locks | RD18 #162 | M I | NewsPaw in a window with the adult partition shown; go Home; return | M: not done · I: not done |
| B7 | Video and Web Audio in the adult browser stop when leaving and at a lock | RD18 #162 | any | Play a video or audio page in the adult browser; leave; lock | not done |
| B8 | Moving a normal category to the adult partition with Face ID | RD19 #182 | P | Category › move to the adult partition; authenticate | not done |
| B9 | The real prompt right after the Files picker, and two prompts in a row ("Turn On and Unlock") | RD20 #182 (A5) | P M | Import a configuration file containing the adult partition with the partition off; on Face ID and on Touch ID | P: not done · M: not done |
| B10 | Keychain: add, read and remove a key; read it after the screen locks; no "Save Password?" sheet and no Passwords bar | RD13 #160 | P | Save a key, Test, lock the screen, unlock, Test, remove | not done |
| B11 | A real key in both partitions: two keychain items; removing one leaves the other working | RD19 #182 (S10) | any | Same service and key in both; remove the normal one; Test in the adult one | not done |
| B12 | Whether UIKit releases the adult model objects after a lock | RD18 #162 | any | Debug build (rule 6); Xcode memory graph after a lock | not done |

## 4. The app-switcher cover (N09)

| ID | Check | Source | Devices | Steps | Status |
| --- | --- | --- | --- | --- | --- |
| C1 | With the adult partition shown, the app switcher shows the cover: plain, with a sheet open, with the keyboard up | RD18 #162 | P M I | Open the app switcher in each state | P: not done · M: not done · I: not done |
| C2 | The same with NewsPaw in an iPad window and beside another app | RD18 #162; RD03 #152 | M I | As C1, in Split View and Stage Manager | M: not done · I: not done |

## 5. Configuration file and OPML between devices (N10)

| ID | Check | Source | Devices | Steps | Status |
| --- | --- | --- | --- | --- | --- |
| D1 | AirDrop a `.newspaw` file, save it in Files, import it from Settings › Data: same categories and sources; keys entered again | RD20 #182 (A6); N13; M1 step 7 | P→M, M→I, I→P | Export, AirDrop, save in Files on the receiver, import with Merge | P→M: not done · M→I: not done · I→P: not done |
| D2 | Inside the adult partition: Export, Save to Files, import again | RD20 #182; RD08 #169 | any | Settings › Data in the adult partition | not done |
| D3 | On iPad: Import Configuration from Add Source closes the sheet and opens the import; the delay before the picker | RD20 #182 (A3) | M I | Library › "+" › Add Source › Import Configuration | M: not done · I: not done |
| D4 | OPML: the Files picker on iPad; AirDrop from the share sheet; Save to Files and import again | RD08 #169 | P M I | Export OPML, AirDrop and save; import it again | P: not done · M: not done · I: not done |
| D5 | An OPML exported by another reader imports | RD08 #169 | any | Import that file; compare the preview | not done |
| D6 | OPML export in the adult partition from start to finish | RD08 #169 | any | Export OPML inside the adult partition and save it | not done |

## 6. Sources, refresh and reading on real feeds (N03–N05)

| ID | Check | Source | Devices | Steps | Status |
| --- | --- | --- | --- | --- | --- |
| E1 | An http-only feed is added and refreshed | RD05 #154; RD04 #153 | any | Add an `http://` feed; refresh | not done |
| E2 | The Paste button pastes without a permission prompt | RD05 #154 | P | Copy an address elsewhere; Add Source › Paste | not done |
| E3 | The owner's feeds — long, many images, Chinese, Japanese, cut content — read on the reading screen; a long article's open time in this build | RD11 #161; RD04 #153 | P M | Open several articles of each kind | P: not done · M: not done |
| E4 | Thumbnails from real feeds in the lists | RD09 #156 | P I | Scroll lists of image-rich feeds | P: not done · I: not done |
| E5 | Refresh on opening after the interval; a return from Control Centre is not an entry; "Updated …" moves on while open | RD06 #155 | P | Leave longer than the interval and return; pull Control Centre down and back | not done |
| E6 | Leaving during a refresh (also long enough to reach the background-time expiry) leaves no source falsely failing | RD06 #155 (criterion 15) | P | Start a refresh of many sources; leave at once; return later | not done |
| E7 | Pull to refresh on Today and in a list, portrait and landscape; "Updating…" while pulling; on the iPad Pro in portrait Today's pull starts a run | RD06 #155; RD09 #156; RD23 #184 | P M I | Pull on Today and in a list in each orientation | P: not done · M: not done · I: not done |
| E8 | GitHub: add a repository over a real network; it refreshes a day later | RD07 #163 | P I | Add a repository's page; check it the next day | P: not done · I: not done |
| E9 | Hugging Face: add `huggingface.co/DeepSeek-AI`, compare the preview, refresh; an account that answers with a redirect | RD26 #181 | any | Add Source with that address; refresh | not done |
| E10 | Search: a cold first search on a large library | RD25 #181 | any | After a relaunch, search once | not done |
| E11 | Scrolling a long list by hand | RD09 #156 | P M | Scroll All Unread with hundreds of rows | P: not done · M: not done |
| E12 | Open Original Page and Open in Browser reach Safari; Share from a row | RD09 #156 | P | Row menu actions | not done |
| E13 | Reading screen: the serif face for Chinese; swipes against the back gesture; image zoom with fingers; selecting and copying text; "Aa" in iPhone landscape; the hidden tab bar on iPhone; the reader's place after the browser on iPad | RD11 #161; RD09 #156 | P I | Each on a long article | P: not done · I: not done |
| E14 | With list thumbnails off, no thumbnail request reaches the network | RD19 #182 | any | Needs a network log (a proxy on the Mac) | not done |

## 7. Extraction and the browser on real pages (N05, N12)

| ID | Check | Source | Devices | Steps | Status |
| --- | --- | --- | --- | --- | --- |
| F1 | Five excerpt-only sources: full text extracted; a paywalled page, a news article, a Chinese blog, a page that needs JavaScript (falls back), a site that answers the app differently from a browser | RD12 #164 | P | Open an article of each | not done |
| F2 | Reader mode on an article page and on a script-built page; a large page's extraction time; a page left under a temporary article for minutes | RD12 #164 | P I | Browser › reader mode | P: not done · I: not done |
| F3 | Browser: a real https and a real http site; an attachment ("This link is a file"); a universal link (YouTube or Maps) stays in the browser; Open in Safari; `mailto:` reaches Mail after "Open"; Share; a login survives a relaunch; a page with video; a web content process that ends ("The page stopped working.") | RD10 #159 | P I | Each in the embedded browser | P: not done · I: not done |
| F4 | The bottom bar is legible over light and dark pages | RD10 #159 | P | A light and a dark site, light and dark appearance | not done |
| F5 | A file input's options: nothing needing a usage description, no crash (camera) | RD10 #159 | P | A page with an image upload field | not done |

## 8. Page translation on the owner's sources (N06)

| ID | Check | Source | Devices | Steps | Status |
| --- | --- | --- | --- | --- | --- |
| G1 | Five web-page sources: translate with one tap, follow a link, the next page translated, show the original | RD16 #183; M1 step 5 | P M I | Open each source; Translate; follow a link; Original | P: not done · M: not done · I: not done |
| G2 | A signed-in page, an infinite list, a single-page site | RD16 #183 | any | Translate each and scroll or navigate | not done |
| G3 | A page restored from the back-forward cache after translation was turned off | RD16 #183 | any | Translate, turn off, follow a link, go back | not done |
| G4 | A search field with live suggestions, with the software and a hardware keyboard | RD16 #183 | I | Type in a translated page's search field | not done |
| G5 | A real tap on a radio tab (limit 16) | RD16 #183 | any | A translated page with radio-button tabs | not done |
| G6 | A real page that stops responding while translated | RD16 #183 | any | A heavy page; translate; wait | not done |
| G7 | The status line at the largest text size | RD16 #183 | M | Largest Dynamic Type; translate a page | not done |

## 9. Real model services (N06–N08, N11)

One status per service the owner uses (presets: OpenAI, DeepSeek, xAI, MiMo, OpenRouter, Gemini). Note: OpenAI and DeepSeek passed body and page translation against the real services in the simulator at `b1dec86` (batch 3); that does not count here.

| ID | Check | Source | Devices | Steps | Status |
| --- | --- | --- | --- | --- | --- |
| H1 | Test: passed; a wrong key → key rejected; a wrong model → model not found | RD13 #160; spec §10 | any, per service | Model slot › Test with the right, a wrong key, a wrong model | not done (each service) |
| H2 | Titles in a real refresh, in each reading language; Traditional Chinese sources | RD14 #167 | any, per service | Refresh; change the reading language; refresh | not done (each service) |
| H3 | One long article's body: time to the first chunk, paragraphs arriving | RD15 #183 | any, per service | Open a long article; Translate | not done (each service) |
| H4 | Page translation | RD16 #183 | any, per service | Translate a web-page source | not done (each service) |
| H5 | The daily overview from a real refresh, in each reading language; how it reads | RD23 #184 | any, per service | A category set to automatic; the day's first refresh | not done (each service) |
| H6 | The first run on a fresh install with a real model | RD21 #181; M1 step 1 | P M I | Fresh install; the first run's three steps | P: not done · M: not done · I: not done |
| H7 | Usage with real rows; number grouping in the device's region | RD17 #168 | any | Settings › Usage after a day's use | not done |
| H8 | Leaving during a refresh: no overview request afterwards; leaving while an overview request is refused: no second request | RD23 #184 | any | Usage, or the service's own log | not done |
| H9 | An adult Replace that repairs a model clears the overview card's error | RD23 #184 | any | Import with Replace in the adult partition | not done |

## 10. Background refresh (N04)

| ID | Check | Source | Devices | Steps | Status |
| --- | --- | --- | --- | --- | --- |
| I1 | A delivered run collects and translates without the app being opened; the runs line read daily over several days with how each run ended (observed) | RD24 #182 | P | Settings › Refresh, once a day | not done |
| I2 | `_simulateLaunchForTaskWithIdentifier:` with the app in the background; `_simulateExpirationForTaskWithIdentifier:` during a run and during a cold launch's opening | RD24 #182 (A1, G1) | P | Debug build (rule 6), Xcode's debugger | not done |
| I3 | A translation request in flight at expiry, then the app resumed: Usage; the pause ends on opening | RD24 #182 (R1) | P | Debug build (rule 6) | not done |
| I4 | A run while the device is locked after its first unlock reads the library and keys | RD24 #182 (A5); RD02 #151 | P | Leave the device locked; read the runs line later | not done |
| I5 | No source left failing after an expiry | RD24 #182 | P | After I2 or a real expiry, Library | not done |
| I6 | Background App Refresh off; Low Power Mode | RD24 #182 | P | Turn each on in Settings; observe the runs line | not done |
| I7 | Opening the app during a run: "Updating…" continues, no second collection | RD24 #182 (G3) | P | Open NewsPaw while a run is in progress | not done |
| I8 | A delivered run, then opening the app: the overview written once without a pull; a launch in the background sends no overview request | RD23 #184 | P | Usage after a delivered run | not done |

## 11. The adult browser's data (N09)

| ID | Check | Source | Devices | Steps | Status |
| --- | --- | --- | --- | --- | --- |
| J1 | A real sign-in in the adult browser survives a lock, is absent from the normal browser, and is removed by Clear and by Delete (and whether a store remains after Delete) | RD19 #182 | P | Sign in; lock; unlock; open the same site in the normal partition; Clear; sign in again; Delete | not done |
| J2 | A page that keeps writing on a timer, left, then Clear: nothing written back | RD19 #182 (F1) | P | Leave such a page open; Clear | not done |
| J3 | Criterion 6's cookie check by hand | RD19 #182 (F5) | P | As in RD19's design | not done |

## 12. Keyboard, VoiceOver, text size, contrast

| ID | Check | Source | Devices | Steps | Status |
| --- | --- | --- | --- | --- | --- |
| K1 | Hardware keyboard: list shortcuts on iPad and iPhone, J once per press, J loads the next page; `T` on the reading screen; search; the model form (with rotation); Done on New Category during an unfinished Pinyin composition | RD09 #156; RD15 #183; RD25 #181; RD13 #160; RD08 #169 | P I | A keyboard attached | P: not done · I: not done |
| K2 | Software keyboard: Pinyin and kana in search; Done on New Category during an unfinished Pinyin composition | RD25 #181; RD08 #169 | P | Chinese and Japanese input methods | not done |
| K3 | VoiceOver: a source row with its state and a category's disclosure; Today's status line, failure button, updating row; list rows and their actions; the browser bars; the model form; an article body; a translated and a failed row; the GitHub rows; the reader-mode button and bar; the reading screen's header, a translated block, Side by Side; a translated page and the Translate toggle; an overview card (does the reading language reach VoiceOver); the first run, Hugging Face and search screens; Full Keyboard Access and VoiceOver during a save | RD05 #154; RD06 #155; RD09 #156; RD10 #159; RD13 #160; RD11 #161; RD14 #167; RD07 #163; RD12 #164; RD15, RD16 #183; RD23 #184; #181; RD03 #152 | P I | VoiceOver on, each screen | P: not done · I: not done |
| K4 | The largest text size: Today's status line, lists | RD06 #155; RD09 #156 | P M | Largest Dynamic Type | P: not done · M: not done |
| K5 | Translation marks' tap targets by finger | RD14 #167 | P | Tap the marks in a list | not done |
| K6 | Contrast of system-drawn parts (tab bar, sidebar selection, backgrounds), light and dark, by eye | RD03 #152 | P I | Both appearances | P: not done · I: not done |

## 13. Layout on the real screens

| ID | Check | Source | Devices | Steps | Status |
| --- | --- | --- | --- | --- | --- |
| L1 | Split View and Stage Manager widths | RD03 #152 | M I | Resize NewsPaw's window through its widths | M: not done · I: not done |
| L2 | Overview cards at the iPad mini's real width | RD23 #184 | M | Today with overviews, both orientations | not done |

## 14. Animated transitions by hand (animations are off under the UI tests)

| ID | Check | Source | Devices | Steps | Status |
| --- | --- | --- | --- | --- | --- |
| M1 | The translation activity mark and rows updating in place; reader mode; body paragraphs arriving with their fade and mode switches; Usage; OPML and configuration sheets; the first run, Hugging Face and search screens; overview Expand / Collapse and More / Less | RD14 #167; RD12 #164; RD15 #183; RD17 #168; RD08 #169; #181; RD23 #184 | P I | Watch each | P: not done · I: not done |

## 15. Memory and stability

| ID | Check | Source | Devices | Steps | Status |
| --- | --- | --- | --- | --- | --- |
| N1 | Memory with 100 images | RD11 #161 | any | Instruments; a debug build under rule 6, or the TestFlight build if Instruments attaches | not done |
| N2 | Memory over ten excerpt-only articles and over ten translated articles | RD12 #164; RD15 #183 | any | Open them in a row; read memory | not done |
| N3 | Scroll stability while chunks arrive and across mode switches, including the half-second pull-back | RD15 #183 | P | Scroll during a body translation; switch modes | not done |

## Known gaps that are not device checks

Owed by merged pull requests but not a property of a device; listed so that nothing vanishes:

- RD03 #152: the swipe-to-dismiss lock during a save has no test.
- RD04 #153: the proxy 407 path and client certificates.
- RD05 #154: UI-test gaps — a failed candidate row, "The first 5 are shown", "Not updated yet", Cancel's wiring, the tab-switch test's weakness.
- RD06 #155: the expiry handler running on the main thread is relied on from Apple's documentation.
- RD09 #156: row images shown by screenshot, not asserted.
- RD10 #159: a form with `enctype="text/plain"` or a file posted to a new window; a form post that is redirected, or that fails after its page began to show.
- RD11 #161: right-to-left layout.
- RD13 #160: a TLS 1.1 server being refused; whether the system re-sends a POST on a stale connection.
- The "by reading only" items of #181–#184.
- UI-suite classes not run at the batches' commits (a simulator matter).
