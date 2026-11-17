# RD26 — Hugging Face account sources

Issue: [#147](https://github.com/AlvinShenSSW/NewsPaw/issues/147) · Epic E17 #120 · Milestone M2 · P2 · Requirements N03 (Hugging Face), N12; ux S6 (confirm step). Also touched: N02 (the same address), N04 (collection rules), N13 (offline tests). Depends on RD05; built like RD07.

Version 2 (2026-11-17), after two debate rounds. Frozen. This issue changes two conditions in RD08's files: it is implemented only once RD08 is on `main`; if it is not, the implementer stops and reports. Written against `main` at `abab44b` (RD07, RD05's detection, RD04's collection), RD08's worktree at `9d27185` (its OPML export, expected on `main` before this is implemented) and RD20's frozen design.

## Spec review

**What the baseline says.** A source kind is "Hugging Face account" (spec section 2). N03: input "An organisation or user address"; collection "The Hub's public API, listing that account's models by creation time"; produces articles; "GitHub and Hugging Face content (READMEs, model cards, release notes) is text to read. Nothing in it is executed or followed." N12: model cards are untrusted data; collection requests "carry no credentials"; an answer may be "an API reply". M2: "A Hugging Face account can be added and lists its newest models." Spec section 10: ordering by creation time "not verified". The issue: no token; datasets, Spaces and private repositories out; if the ordering is not offered, report back first; "an account with no models, and an address that is not an account, each say so".

So an **account source** is one user's or organisation's **public models**; an **item** is one model; its **link** opens the model's page on the Hub.

**What `main` does today.** `SourceKind.huggingface` is in the closed set since `v1`; nothing creates one. `isCollectedAsFeed` is false for it (not refreshed, no Refresh); `BodyPlan` already treats it like `github`. A typed `huggingface.co/<name>` is an ordinary page with no feed, so "Save as a Web Page" is offered. `FeedParser` reads no Hub answer. RD08 exports to OPML every source whose kind `isCollectedAsFeed` (`Library+OPML.swift:145`, its button at `SettingsView.swift:200`), and decides that Hugging Face accounts are not exported (RD08 decision 5).

**Measured on 2026-11-17** (22:01–22:27 UTC on 11-16), no token, no cookie. Raw answers: **P** = `…/scratchpad/rd26-design/probe/`, **P2** = `…/scratchpad/rd26-design/probe2/` (the app's headers), **C** = the critic's `rd26/debate/critic-r1-probe/` (the app's headers). Rows without a raw answer were dropped or are assumptions.

| Question | Answer | Raw |
| --- | --- | --- |
| A feed? | Account pages declare none; `/blog` declares `/blog/feed.xml` | P `page-google.html`, `page-julien-c.html`, `page-blog.html` |
| Models by creation time, no token | `/api/models?author=<name>&sort=createdAt&direction=-1&limit=N` → 200 JSON array, newest `createdAt` first | P `h1.txt`, `b1.json`; C r1, r13 (a user) |
| Reduced shape | `&expand=createdAt` → elements `{_id,id,createdAt}`, 3,435 B for 30; byte-identical to the `expand%5B%5D` form, same ETag; the Hub's own `Link` header spells it `expand=createdAt`. Without it, the full shape (`likes`, `downloads`, `tags`, `pipeline_tag`, …) | C r1, r3; P `hx.txt`, `b30.json` |
| Validators | Weak `ETag`; `If-None-Match` → 304. No `Cache-Control`, no `Last-Modified` | C r2; P `h1.txt`, `hx.txt` |
| Rate limit | `"fixed window";"api";q=500;w=300` | P `h1.txt`; C r1 |
| Letter case | `author` is case-sensitive: `author=qwen` → `[]`, `author=Qwen` lists models | C r4, r5 |
| No account / no models | A missing name → 200 `[]`, ETag `W/"2-l9Fw…"`; an organisation with no models (`webhooks-explorers`, overview `numModels: 0`) → the same | C r6; P2 p1, p2 |
| Organisation overview | `/api/organizations/<n>/overview`, any case → 200 with `"name"` in the Hub's case (`DeepSeek-AI` → `deepseek-ai`); 404 for a user | C r7, r9; P2 p3 |
| User overview | `/api/users/<n>/overview`, another case → 307, relative `Location`; followed → 200 with `"user"`, `"type":"user"`; 15 kB with 69 nested `orgs` | C r8, r12; P `julien.json`, `app.tmp` |
| Reserved path | `blog`: both overviews 404 | C r10, r11 |

**Gaps, and what this design decides.**

1. *Which addresses are accounts.* Only the account's own page `huggingface.co/<name>` (decision 1). A model's page takes the ordinary path and stays savable as a web page.
2. *What is stored.* The account page, `https://huggingface.co/<Hub's spelling>`, as `url` and `site_url`. The list address is built from it at every fetch, so the build owns the query, Source Settings shows the account, and a configuration file naming an account the natural way works.
3. *"Not an account" against "no models".* The list cannot tell them apart; the two overviews can, and give the Hub's spelling, which the list needs.
4. *An item.* The model's name, creation time and built link; nothing else is requested: no model card, README, configuration, `SKILL.md` or repository file.
5. *"This page itself".* Not offered: only the account root is recognised, so every other Hub page stays savable as a web page.

## Acceptance criteria

"Package" is a test in `ios/NewsPawKit`; "UI" is a UI test on the fixture transport.

1. An account address is recognised in each form of decision 1 and not otherwise: another host (`hf.co.example.com`, `cdn-avatars.huggingface.co`), a non-default port, zero or two or more segments, a name outside the rule, a percent-escape. — Package (table).
2. The built addresses are https on `huggingface.co` without user name or password: the two overviews with the typed name; the page and `…/api/models?author=<name>&sort=createdAt&direction=-1&limit=30&expand=createdAt` with the given name. The page address is its own `SourceAddress` normal form. — Package.
3. Detecting `huggingface.co/Org-Name` for an organisation spelt `org-name` makes exactly three requests — the two overviews and the list with `author=org-name` — none with validators, and returns `huggingFace` with that spelling and one usable candidate of kind `huggingface` at `https://huggingface.co/org-name`, previewing its newest three models. The same for a user found by the user overview. A detection cancelled during either phase throws and makes no further request. — Package.
4. A library source whose address equals `https://huggingface.co/<typed name>` ignoring ASCII case — any kind — gives `duplicate` with no request, also with a transport that fails everything. — Package.
5. Both overviews 404: the ordinary path runs on the typed address; a page answering 404 gives `failed` with `gone` and `missingHuggingFaceAccount`; a page declaring a feed gives today's `page` result. — Package.
6. Overview failures (both unreachable; 429; 500; a 200 that is not a JSON object or whose name differs other than in ASCII case) give `failed` with decision 3's reason, `addedScheme` false, the web-page offer under today's rule. A failed list gives `failed` with its reason; one not answered within the candidate limit, `timedOut`. — Package.
7. An account with no models gives `huggingFace` with a usable, empty candidate. — Package. The confirm step says "This account has no public models yet"; Save is enabled and stores a source with no articles. — UI.
8. The list reader, on synthetic fixtures: identity from `_id`, else `id`; title `id`; link `https://huggingface.co/<id>`; time from `createdAt`, none when missing or unparseable; no excerpt, image, author or content; an element whose `id` breaks the rule (`a/../b`, `a/b?x=1`, `a/b#c`, `a/b/c`, `https://x.example/a`, a number) is skipped; only the first 30 elements are read; the full-shape fixture reads to the same items as the reduced one; `[]` is a list with no items; an object, a JSON Feed, non-JSON and a document past `JSONFeedReader`'s limits are not a list. A feed source answering this JSON is "not a feed"; a Hugging Face source whose list answers Atom is "not a feed". The large user-overview fixture is read. — Package.
9. Save stores kind `huggingface`, `url` and `site_url` the page in the Hub's spelling, the Hub's name as suggested name unless edited, the validators and the articles of the detecting fetch, in one transaction and without a request. — Package; UI for the name and kind.
10. A Hugging Face source is a refresh target; `FeedCollector` requests the list built from its stored page, with its validators (304 → not modified); new models become articles; identity holds across collections; failures are recorded as for a feed; a paused one is not requested; a stored address that is not an account page fails `unsupportedAddress` with no request. The app offers Refresh for it wherever it does for a feed. — Package; UI (the row's menu, one refresh bringing a new model).
11. An OPML export of a library holding a Hugging Face source does not contain it; the export button's condition counts only `feed` and `github` sources. — Package (`LibraryOPMLTests`).
12. The confirm step shows `https://huggingface.co/<Hub's name>`, kind "Hugging Face" and the preview; the address step for a missing account adds "There is no Hugging Face account with this name."; English and Simplified Chinese, light and dark, three simulators. — UI and screenshots.
13. The three checks of `AGENTS.md` pass; new strings are translated. Existing tests pass, except `RefresherTests.libraryTargets` and `FeedCollectorTests.nothingDone`, which state the old rule and change with it.

## Frozen issue contract

**In.** The thirteen criteria.

**Invariants.**
- Ordinary detection is unchanged for every other address, and for an account address whose overviews both answer 404 (after those two requests), apart from the missing-account flag.
- Nothing is written before Save; Save makes no request.
- Requests are only the two overviews and the list (plus today's on the fallback). Nothing else of the Hub — model card, README, `SKILL.md`, configuration, avatar — is requested, at detection, collection or for a thumbnail. No token, header or credential is added.
- The schema, lock files and dependencies do not change.
- Answers are untrusted text: stored as text, never executed, no link in them followed; links are built.
- Partitions: lookups in the sheet's library; requests through the shared transport under N04's rules; validators only in the partition's `source` row; no new cache.
- No test contacts an outside host.

**Allowed user-visible change.** An account address leads to the confirm step with kind "Hugging Face" and a preview of models; such sources appear, refresh and fail like feeds, without thumbnails; a missing account says so; OPML export is unchanged.

**Non-goals.** Datasets, Spaces, papers, posts, collections, likes; private or gated repositories; tokens and sign-in; a model's card, files or counts; a model address as input; following a renamed account; more than the newest 30; "This page itself"; changing a source's kind; a body beyond RD12's rules.

**What other issues own.** RD12 (body plan), RD14 (title translation), RD20 (configuration file; no change needed), RD24 (background refresh collects these like any target). RD08 is merged first; this issue switches its two conditions (decision 8) and changes nothing in RD08's pull request.

**Causal boundary.** `ios/NewsPawKit/Sources/NewsPawKit/Feeds/{HuggingFaceAccount.swift (new), HuggingFaceModels.swift (new), SourceDetector.swift, FeedFetcher.swift, FeedCollector.swift, ParsedFeed.swift (one case), XMLFeedReader.swift (one line: `case .json, .huggingFace: break`), FixtureTransport.swift}`, `Model/Source.swift` (two properties), `Store/{Library+Collection.swift, Library+OPML.swift (one condition)}`; `ios/NewsPaw/AppState/AddSourceModel.swift`, `AddSource/{AddSourceView, ConfirmStepView}.swift`, `LibraryScreen/SourceWording.swift`, `Destinations/SettingsView.swift` (one condition), `UITestIdentifiers.swift`, `Localizable.xcstrings`; tests and fixtures; `docs/reader/spec.md` (section 10 only) and this design. Anything else is reported, not changed.

## Assumptions

Each re-measured by the implementer before code depends on it (about ten requests, no token, recorded with date and raw answers):

- **A1. The overview addresses still exist.** Measure: `organizations/DeepSeek-AI/overview` and `users/Julien-C/overview`. If both answer 404 for real accounts, every account address would fall back to "Save as a Web Page": stop and report.
- **A2. Ordering, case-sensitive `author` and the reduced shape hold.** Measure: the list for `deepseek-ai` and `Qwen`. If the ordering is gone: stop and report to the owner before choosing another, as the issue requires. If `expand` is ignored, nothing changes: the reader takes the full shape (criterion 8).
- **A3. The 304.** Measure: a conditional request with the answer's `ETag`. If it stops: harmless — a 200 at every refresh, and identity stores nothing twice.

The rate-limit figures are informational; nothing encodes them. Read in the code, not assumed: `FeedDate.parse` reads fractional seconds and `Z`; `JSONFeedReader.exceedsLimits` is internal; `FeedFetcher.reason(for:)` is private and becomes internal; the transport follows a relative redirect (`TransportLoopbackTests`, `/hop`).

## Approach

1. **Recognition (`HuggingFaceAccount`, pure).** `init?(normalForm:)`: scheme http or https; host `huggingface.co`, `www.huggingface.co` or `hf.co`; no port; exactly one non-empty path segment (trailing slash allowed) that is a **name** — 1–96 ASCII letters, digits, `-`, `_` or `.`, not `.` or `..`. The query is ignored; `name` is as typed.
2. **Addresses.** `organizationOverviewAddress`, `userOverviewAddress`: `https://huggingface.co/api/{organizations|users}/<name>/overview`. `pageAddress`: `https://huggingface.co/<name>`. `modelsAddress`: `https://huggingface.co/api/models?author=<name>&sort=createdAt&direction=-1&limit=30&expand=createdAt`. Thirty is three times a GitHub feed's ten.
3. **Detection (in `SourceDetector`, before the ordinary lookup).** (a) Look up `pageAddress` of the typed name ignoring ASCII case: found → `duplicate`, no request. (b) Fetch both overviews at once (plain `TransportRequest`s, no validators, each within the transport's 20 s). Each is *found* (200, a JSON object within `exceedsLimits`, whose `name` or `user` passes the name rule and equals the typed name ignoring ASCII case), *gone* (404, 410) or *failed* (`FeedFetcher`'s reason; a 200 that is not *found* is `notAFeed`). Either found → that spelling, the organisation first; both gone → decision 5; else `failed` with the organisation's reason if it failed, else the user's, the typed normal form, `addedScheme` false. (c) `check([pageAddress with the Hub's spelling], declaredOn: same, kind: .huggingface, ignoringCase: true)`: *usable* → `.huggingFace(HuggingFaceDetection(account, candidate))`; *already added* → `duplicate`; *failed* → `failed`; *not checked* → `failed` with `timedOut`.
4. **The reader (`HuggingFaceModels.read(_:)`, pure).** `nil` unless `exceedsLimits` passes and the root is an array. The first 30 elements only; each object with a string `id` of the form `<name>/<model>` (both parts under decision 1's rule) gives a `ParsedItem`: `externalID` = `_id` when it is 1–64 ASCII letters and digits, else `id`; `title` = `id`; `url` = `"https://huggingface.co/" + id`; `publishedAt` = `FeedDate.parse(createdAt)`. Other elements and members are ignored. Result: format `.huggingFace`, no title or site, complete.
5. **Not an account.** Both overviews gone → the ordinary path on the typed address, unchanged (`/blog` keeps its feed). If it ends in `failed` with `gone`, the failure has `missingHuggingFaceAccount = true` (`var … = false` on `DetectionFailure`, so existing expectations compile).
6. **Fetching by kind.** `FeedFetcher.fetch` gains `kind: SourceKind = .feed`. For `.huggingface` it requests `HuggingFaceAccount(normalForm: address)?.modelsAddress` — or returns `failed(.unsupportedAddress)` without a request — and reads the body with `HuggingFaceModels.read`; every other kind is read by `FeedParser` as today. Status, validators and failures are shared. No fallback between readers.
7. **Collection.** `isCollectedAsFeed` is true for `huggingface`: `refreshTargets`, the two collection reads and the app's Refresh checks include it. `CollectionTarget` gains `kind` (already selected); `FeedCollector` passes it on; the store step also requires the re-read kind to equal it (one line, as its comment already says). Everything else is the feed's.
8. **Not a feed address.** `SourceKind.storesFeedAddress` (true for `feed`, `github`). RD08's export filter and its button's condition use it instead of `isCollectedAsFeed`.
9. **App.** `Detection` gains `case huggingFace(HuggingFaceDetection)` (`account` in the Hub's spelling, `candidate`). `AddSourceModel`: `apply` chooses the candidate and shows the confirm step; `canConfirm` true; `chosenFeed` the candidate; no declared candidates, no web-page address; suggested name `account.name`. `AddSourceView`: the outcome switch gains the case; the failure section shows decision 5's line. `ConfirmStepView`: address `account.pageAddress`, kind `Text(verbatim: "Hugging Face")`, empty preview "This account has no public models yet". `SourceWording.format(.huggingFace)` = "Hugging Face". Strings: "This account has no public models yet" 这个账号还没有公开的模型; "There is no Hugging Face account with this name." 没有这个名字的 Hugging Face 账号。
10. **Await guards.** The detector holds no state; each await is followed by `Task.checkCancellation()`; nothing is written; the app applies a result only from an uncancelled task (RD05). Collection's one write re-reads the source in its transaction.
11. **Fixtures.** Synthetic, invented names, shaped like the raw answers: a reduced list, a full-shape list of the same models, an empty list, an organisation overview, a user overview as large and nested as `julien.json`, a 404 body. UI (`FixtureTransport`, by full address): organisation `newspaw-fixture` typed `huggingface.co/NewsPaw-Fixture` (three models; each list answer adds one), user `newspaw-empty` (organisation 404, user 200, list `[]`), `newspaw-missing` (both 404, page 404). Links are built on `huggingface.co`, so no UI test opens a model or taps "Open original page".
12. **Where `source.url` is read for these sources.** Collection: builds the list from it (decision 6). The store step: compares it, unchanged. Source Settings: shows and copies the account page. OPML: not exported (decision 8). RD20's file: exports and imports the page as `url`; an imported account page in the Hub's spelling collects; one in another letter case lists nothing, as `author` is case-sensitive; one that is not an account page fails `unsupportedAddress` visibly. Duplicate check: `url` is `UNIQUE`, so a web-page source at the same page address and the account cannot both exist (owner note 9).

## Files to change

| Path | Change | For |
| --- | --- | --- |
| `Sources/NewsPawKit/Feeds/HuggingFaceAccount.swift`, `HuggingFaceModels.swift` | add | 1, 2, 8 |
| `Sources/NewsPawKit/Feeds/{SourceDetector, FeedFetcher, FeedCollector, ParsedFeed, XMLFeedReader}.swift` | change | 3–8, 10 |
| `Sources/NewsPawKit/Model/Source.swift` | two properties | 10, 11 |
| `Sources/NewsPawKit/Store/{Library+Collection, Library+OPML}.swift` | change | 10, 11 |
| `Sources/NewsPawKit/Feeds/FixtureTransport.swift` | add answers | UI |
| `Tests/NewsPawKitTests/…/{HuggingFaceAccountTests, HuggingFaceModelsTests (new), SourceDetectorTests, FeedCollectorTests, RefresherTests, FeedFetcherTests, LibraryOPMLTests}.swift`, `Fixtures/huggingface/*.json` | add / change | 1–11 |
| `ios/NewsPaw/AppState/AddSourceModel.swift`, `AddSource/{AddSourceView, ConfirmStepView}.swift`, `LibraryScreen/SourceWording.swift`, `Destinations/SettingsView.swift`, `UITestIdentifiers.swift`, `Localizable.xcstrings` | change | 7, 9–12 |
| `ios/NewsPawUITests/HuggingFaceSourceTests.swift`, a screenshot test | add | 7, 9, 10, 12 |
| `docs/reader/spec.md` | section 10: the assumption measured (date, no token) | the measurement |

Package paths are under `ios/NewsPawKit/`.

## Execution surface

- **Executed:** the three checks; the package suite; `xcodebuild test -only-testing` for the new UI tests; the whole UI suite once per simulator by the driver; `xcrun simctl`; `git`.
- **Outside hosts.** None from any test. A1–A3's re-measurement and one manual check, recorded as such with the date: in the simulator with the real transport, add `huggingface.co/DeepSeek-AI`, compare the preview with the Hub, save, refresh once; type `huggingface.co/Julien-C` (a user, through the real 307) and cancel.
- **Not touched:** the schema, dependencies and lock files, `.github/`, the transport, the parsers except `XMLFeedReader`'s one line, the owner's ignored files.

## Failure handling

| Situation | Result |
| --- | --- |
| Not an account address | Ordinary detection, unchanged |
| The account's page is already a source | "Already in …", no request |
| Both overviews 404 | Ordinary detection; a 404 page adds the missing-account line |
| An overview fails and the other does not find the account | "Could not read this address" with that reason; web-page offer under today's rule |
| The list fails or is too slow | "Could not read this address" with its reason |
| No models | Confirm step, "This account has no public models yet", Save allowed |
| A malformed element | Skipped; the others are kept |
| Not a JSON array, or past the limits | "Not a recognisable feed", at detection or as the status |
| A stored address that is not an account page | `unsupportedAddress` status, no request |
| A later collection refused (429, 5xx) | The ordinary failing status; tried at the next refresh |
| The account renamed or deleted | `[]` once, then 304: no new models and no failure (owner note 7) |
| Cancel during detection | Fetches cancelled; nothing stored |

## Risk assessment

- **The Hub changes its API.** A failing status or an empty list; the fix is a new build, which also fixes saved sources, since the query is built, not stored. A1–A2 re-measure.
- **Quiet after a rename.** A renamed or deleted account answers `[]` once and 304 after, so it never fails. Noticing it needs no extra request (owner note 7's alternative); the default accepts the quiet.
- **Rate limit.** Detection costs three requests, a refresh one per source, against 500 per 5 minutes. A refusal is a visible status.
- **Title translation.** Model names go to the model like any title; the per-source switch turns it off.

## Test plan

Package tests first (criteria 1–11), each seen to fail for the right reason before the code exists. Detector and collector tests use the existing recording transports and assert every requested address and the absence of validators; cancellation is held by a stub the test releases; the candidate-limit test injects a short limit with a stub that never answers. Then two UI tests — add, preview, save, refresh brings a new model; the empty and the missing account — and the screenshot test for criterion 12.

Planted failures, recorded with their failing test:
- *No request beyond the three* — add a request for `…/<id>/raw/main/README.md`: criterion 3's request list fails.
- *No link from the answer* — drop the `id` rule: criterion 8's hostile ids fail.
- *No untrusted spelling* — drop the overview name comparison: criterion 6's mismatch fails.
- *No reader fallback* — let `FeedFetcher` try `FeedParser` after the list reader: criterion 8's last cases fail.
- *Never in OPML* — restore `isCollectedAsFeed` in the export: criterion 11 fails.
- *No request for a duplicate* — move the lookup after the overviews: criterion 4 fails.

## Handoff notes

- RD20: no change; an account source round-trips as its page address (decision 12).
- RD24: background refresh collects these sources; one request each.
- Datasets or Spaces, if ever wanted: a sibling of `modelsAddress` (`/api/datasets?author=…`, `/api/spaces?author=…`, not measured) and a choice like RD07's.

## For the owner

1. Listing an account's models by creation time works through the Hub's public API, without a token (measured 2026-11-17). Default: no token support. The anonymous limit is 500 requests per 5 minutes; adding an account costs three, a refresh one per account.
2. Only the account's own address is recognised — `huggingface.co/<name>`, also `hf.co/<name>`, any letter case. A model's address is handled as a page.
3. Models only: no datasets, Spaces, papers or posts.
4. Each article is one model: title the full model name (`deepseek-ai/DeepSeek-V4.1-Flash`), time its creation; no excerpt or thumbnail. "Open original page" opens the model's page. The model card is fetched only if the source's body option is "Always fetch the page".
5. Each refresh reads the newest 30 models; more than 30 between two refreshes and the rest are missed.
6. The suggested name is the account's name as the Hub writes it (`deepseek-ai`), not its display name; editable before Save.
7. A renamed or deleted account goes quiet: no new models and no failure. Default: accepted. Alternative, at no extra request: when a complete empty answer arrives for a source that has articles, show it as failing ("address gone") until the account lists models again.
8. Unlike GitHub, there is no "This page itself" row for an account address.
9. If the account's page was saved earlier as a web-page source, adding the account says it is already in that category (one address, one source). Delete the web-page source first, then add the account.
10. Model names are translated automatically like any title; the source's own switch turns it off.
11. Source Settings shows the account's page. OPML export leaves these sources out; the configuration file carries them. A Hugging Face account written by hand in a configuration file must use the Hub's spelling: in another letter case it lists nothing and shows no failure.

## Revision record

**Version 1 (2026-11-17).** First draft, with the measurements.

**Version 2 (2026-11-17).** Debate round 1. The source stores the account page and the list address is built at every fetch; the duplicate lookup comes before any request; `expand=createdAt`; the reader takes 30 elements; criterion 11 is unconditional and RD08's two conditions join the boundary with `XMLFeedReader`'s one line; measurements cite raw answers (three new ones in `probe2/`), unrecorded rows dropped; assumptions reduced to the critic's three; the kind-change test, the loopback test and the N03 edit dropped; the rename risk corrected and its alternative put to the owner; owner note 9 added.

## Debate record

**Round 1 (2026-11-17).** The critic read version 1 against the code and repeated 13 requests (verdict SOUND WITH FIXES). The author checked each piece of evidence (`XMLFeedReader.swift:333–386`, `Schema.swift:42`, `TransportLoopbackTests.swift:27`, `cmp r1.json r3.body`, the empty-list ETag in r4 and r6, `hx.txt`'s `Link`); all held. Every finding was admitted by the driver.

| # | Severity | Finding | Disposition |
| --- | --- | --- | --- |
| F1 | P1 | `XMLFeedReader` switches over `ParsedFeed.Format` outside the boundary | Boundary gains its one line |
| F2 | P2 | Storing the API address freezes the query into sources and files | The account page is stored; the list is built (decisions 2, 6, 12; owner note 9) |
| F3 | P2 | OPML would export these sources if RD08 merged second | Criterion 11 unconditional; RD26 switches RD08's two conditions |
| F4 | P3 | A duplicate cost two requests | Lookup first, offline (criterion 4) |
| F5 | P3 | Bracket spelling of `expand` | `expand=createdAt`; A2 of version 1 dropped |
| F6 | P3 | Wrong cost of noticing a dead account | Risk corrected; alternative in owner note 7 |
| F7 | P3 | Kind-change test guards an unreachable state | One-line check kept; test and plant dropped |
| F8 | P3 | Items unbounded | First 30 elements only |
| F9 | P3 | Rows without raw answers | Cited; unrecorded rows dropped; three new answers in `probe2/` |
| F10 | P3 | A3 settled by an existing test | Dropped |
| F11 | P3 | Fixtures should pin the full shape and a large overview | Added (decision 11, criterion 8) |
| F12 | P3 | N03's row edited | Section 10 only |

Round 2 (2026-11-17, the same critic): all twelve findings resolved; nothing new at P1 or P2. Two sentences added by the driver at the freeze, from the critic's closing notes: the stop condition if RD08 is not on `main` (header), and the owner's note that a hand-written account must use the Hub's spelling (For the owner 11).
