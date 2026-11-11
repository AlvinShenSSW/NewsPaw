# NewsPaw Reader — Backlog

Cut on 2026-11-11 from [spec.md](spec.md) (requirements N01–N13, milestones M1 and M2) at the owner's request. It replaces the closed E01–E10 backlog of the Mac + Telegram product.

The backlog authorises no development. An issue is started only when the owner hands it over; it is then worked alone, in dependency order: freeze its design against the requirement numbers, implement, internal check, Kimi K3.1 Pro external gate, final check, leave open.

Issue numbers are GitHub issue numbers in `AlvinShenSSW/NewsPaw`. Labels: `reader`, `epic` or `task`, a priority (`P0`–`P2`) and a milestone (`M1`, `M2`, `Later`).

## Epics

| Epic | Title | Milestone | Issues |
| --- | --- | --- | --- |
| E11 #114 | Foundation: project, storage and app shell | M1 | RD01–RD03 |
| E12 #115 | Sources and refresh | M1 | RD04–RD08 |
| E13 #116 | Lists and reading | M1 | RD09–RD12 |
| E14 #117 | Models and translation | M1 | RD13–RD17 |
| E15 #118 | Adult partition | M1 | RD18–RD19 |
| E16 #119 | Configuration, settings and TestFlight | M1 | RD20–RD22 |
| E17 #120 | Overviews, background refresh, search and Hugging Face (M2) | M2 | RD23–RD26 |
| E18 #121 | App Store edition (future, out of scope) | Later | none (placeholder) |

## Issues

| Issue | Title | Epic | Milestone | Priority | Requirements | Depends on |
| --- | --- | --- | --- | --- | --- | --- |
| RD01 #122 | Create the iOS project, the NewsPawKit package and CI; archive the Mac product | E11 | M1 | P0 | N01, N13; spec sections 6 and 9 | — |
| RD02 #123 | Partition libraries: one database per partition, migrations, categories | E11 | M1 | P0 | N02, N04 (storage); spec section 4 and section 6 (isolation point 1) | RD01 |
| RD03 #124 | App shell: navigation on iPhone and iPad, Library with categories | E11 | M1 | P0 | N01, N02, N05; ux section 2, S2 (categories), S13 (category), sections 5 and 6 | RD02 |
| RD04 #125 | Feed collection: fetch and parse RSS, Atom and JSON Feed into articles | E12 | M1 | P0 | N03 (feed), N04 (collection rules, what counts as new, time), N12 | RD02 |
| RD05 #126 | Add a source: detection, feed discovery, category, preview; source status and settings | E12 | M1 | P0 | N03; ux S6, S2 (sources), S13 (source) | RD03, RD04 |
| RD06 #127 | Refresh, retention and the image cache | E12 | M1 | P0 | N04 (foreground refresh, retention, storage, no badge); ux S8 (Refresh) | RD05 |
| RD07 #128 | GitHub repository sources | E12 | M1 | P1 | N03 (GitHub), N12 | RD05 |
| RD08 #129 | OPML import and export | E12 | M1 | P1 | N03 (OPML), N10 (OPML) | RD05 |
| RD09 #130 | Article lists, read state and stars | E13 | M1 | P0 | N05 (lists, rows, actions); ux S1 (without overview cards), S3, Starred, section 6 | RD05 |
| RD10 #131 | Embedded browser and web-page sources | E13 | M1 | P0 | N03 (web page), N05 (links), N12 (embedded browser); ux S5 (without Translate and reader mode) | RD05 |
| RD11 #132 | Reading screen: native layout of the feed's body, reading settings | E13 | M1 | P0 | N05 (body source 1 and 3, layout, display, also); ux S4 (without translation), S8 (Reading) | RD09, RD10 |
| RD12 #133 | Full text from the article page, and reader mode in the browser | E13 | M1 | P0 | N05 (body source 2), N03 (reader mode), N12; ux S4, S5 (reader mode) | RD11 |
| RD13 #134 | Model slots, keys and the model client | E14 | M1 | P0 | N08, N11 (records), N12 (https for model services); ux S8 (Models & translation), S9 | RD03 |
| RD14 #135 | Title and excerpt translation | E14 | M1 | P0 | N06 (reading language, detection, titles, acceptance, failure, primary and backup), N11 (daily automatic limit); ux S3 (row states), section 4 | RD09, RD13 |
| RD15 #136 | Body translation and display modes | E14 | M1 | P0 | N06 (body, failure, primary and backup, record); ux S4 | RD11, RD12, RD14 |
| RD16 #137 | Translate a web page in place with one tap | E14 | M1 | P0 | N06 (web pages in the embedded browser), N11, N12; ux S5 (Translate), S13 (web-page source) | RD10, RD14 |
| RD17 #138 | Usage screen and the daily automatic limit setting | E14 | M1 | P1 | N11; ux S8 (Usage) | RD14 |
| RD18 #139 | Adult partition: turning it on, authentication, switching, locking and the cover | E15 | M1 | P0 | N09, N02; spec 6.1 (item 3); ux section 2 (partition switch), S7, S10 | RD03, RD09 |
| RD19 #140 | Adult partition isolation: models, browser data, images, moving a category | E15 | M1 | P0 | N08 (partition isolation), N09 (browser data, thumbnails), N02 (moving a category), N04 (image cache); spec section 6 (both isolation points); ux S10, S13 | RD18, RD10, RD13 |
| RD20 #141 | Export and import the configuration file | E16 | M1 | P0 | N10; spec section 5; ux S11 | RD05, RD13, RD18 |
| RD21 #142 | First run and the remaining Settings | E16 | M1 | P1 | N01 (works without a key), N02 (suggested categories); ux S12, S8 | RD05, RD13 |
| RD22 #143 | TestFlight build and M1 verification on the owner's devices | E16 | M1 | P0 | N13 (distribution, real-device list); spec section 7 (M1 acceptance) | RD12, RD15, RD16, RD17, RD19, RD20, RD21, RD07, RD08, RD06 |
| RD23 #144 | Daily overview per category | E17 | M2 | P1 | N07; ux S1 (cards), S3 (overview card), S13 (overviews on / off) | RD14 |
| RD24 #145 | Background refresh | E17 | M2 | P1 | N04 (background), N09 (while locked) | RD06, RD14, RD18 |
| RD25 #146 | Search | E17 | M2 | P1 | N05 (search); ux section 7 | RD14 |
| RD26 #147 | Hugging Face account sources | E17 | M2 | P2 | N03 (Hugging Face), N12 | RD05 |

## Order

One workable order that respects every dependency: RD01 → RD02 → RD03 → RD04 → RD05 → RD06 → RD07 → RD08 → RD09 → RD10 → RD11 → RD12 → RD13 → RD14 → RD15 → RD16 → RD17 → RD18 → RD19 → RD20 → RD21 → RD22 for M1, then RD23 → RD24 → RD25 → RD26 for M2. Issues with no dependency between them (for example RD07 and RD08, or RD13 beside the E12 and E13 issues) can be reordered.

## Requirement coverage

| Requirement | Issues |
| --- | --- |
| N01 | RD01, RD03, RD21 |
| N02 | RD02, RD03, RD18, RD19, RD21 |
| N03 | RD04, RD05, RD07, RD08, RD10, RD12, RD26 |
| N04 | RD02, RD04, RD06, RD19, RD24 |
| N05 | RD03, RD09, RD10, RD11, RD12, RD25 |
| N06 | RD14, RD15, RD16 |
| N07 | RD23 |
| N08 | RD13, RD19 |
| N09 | RD18, RD19, RD24 |
| N10 | RD08, RD20 |
| N11 | RD13, RD14, RD16, RD17 |
| N12 | RD04, RD07, RD10, RD12, RD13, RD16, RD26 |
| N13 | RD01, RD22 |

## Not in the backlog

- The M3 candidates of spec section 7 (change marks on web-page sources, a glossary, the system's on-device translation, text-to-speech, native Anthropic / Gemini protocols, iCloud sync). Each needs the owner's decision before an issue exists.
- The App Store edition: E18 #121 is a placeholder epic with no issues.
