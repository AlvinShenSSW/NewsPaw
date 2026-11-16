# RD07 — GitHub repository sources

Issue: [#128](https://github.com/AlvinShenSSW/NewsPaw/issues/128) · Epic E12 #115 · Requirements N03 (GitHub), N12; ux S6 (confirm step). Also touched: N02 (the same address), N04 (collection rules), N13 (offline tests).

Version 2 (2026-11-15), written against `main` at `d436d25`, after one debate round (records at the end). Frozen.

## Spec review

**What the baseline says.** A GitHub repository is a source kind (spec section 3 and N03). The owner gives the repository address; the app collects one of the repository's Atom feeds — Releases (default), Tags or Commits — chosen while adding, in the picker also used when a page declares several feeds; the source stores the chosen feed address; no token (N03). Release notes are text to read; nothing in them is executed or followed (N03, N12). ux S6: the confirm step names the kind (Feed / GitHub / Hugging Face / Web page) and offers the choice between Releases, Tags and Commits. Spec section 10 lists "GitHub's Atom feeds need no token and are leniently rate-limited" as not verified.

**What `main` does today.** `SourceKind.github` exists since `v1` and nothing creates it. A typed repository address goes through ordinary detection: the page is fetched, declares no feed (measured below), and the owner is offered "Save as a Web Page". Three places collect only `kind = 'feed'`: `Library.refreshTargets`, and the two reads in `Library+Collection.swift` (the target and the store step). The app asks `kind == .feed` in four places (`SourceModel` three times, `SourceRow` once) to decide whether Refresh is offered. The embedded browser's "Save This Page as a Source" opens Add source with the shown page's address.

**Measured on 2026-11-15**, with `curl` and a neutral user agent, no cookie and no credential, against public repositories (twenty-three requests by the driver, six by the critic; records in the run's evidence folder under `rd07/probe/`):

| Question | Answer |
| --- | --- |
| Do the Atom feeds answer without a token? | Yes. `https://github.com/<owner>/<repo>/releases.atom`, `tags.atom` and `commits.atom` each answered 200, `application/atom+xml; charset=utf-8`, with an `ETag`; sizes 5–114 kB |
| Conditional requests | `If-None-Match` with the stored `ETag` answered 304 |
| What do the pages declare? | The repository's root page: no feed at all, so discovery cannot find these feeds from it. Its `/releases` page declares `releases.atom` and `tags.atom`. Its `/commits/<branch>` and `/tree/<branch>` pages declare none |
| Releases against Tags | Both list ten entries with the **same** identifiers (`tag:github.com,2008:Repository/<n>/<tag>`) and links (`…/releases/tag/<tag>`). Releases carries the notes as HTML content; Tags has empty content. A repository with tags and no published release (`torvalds/linux`) has ten entries in Releases too, each with the tag's message |
| A repository with no tag | `releases.atom` and `tags.atom` answer 200 with a feed of no entries; `commits.atom` has entries |
| Commits | `commits.atom` is the default branch's feed (its own link names `commits/master.atom`); twenty entries; identifiers `tag:github.com,2008:Grit::Commit/<sha>`; the title sits between line breaks and spaces. Another branch has its own feed at `commits/<branch>.atom` |
| Dates | Every entry has `<updated>` and no `<published>` |
| Images | Every entry of all three feeds carries `media:thumbnail` — the author's avatar, 30 points |
| Letter case | `GROUE/grdb.swift` and `groue/grdb.swift` answered 200 with the same body and `ETag` as `groue/GRDB.swift`, without a redirect |
| `www.github.com`, a renamed repository | 301 to `github.com`, and to the new owner's address |
| `<repo>.git` | 404 |
| A repository that does not exist; reserved paths (`/topics/swift`, `/trending/swift`, `/orgs/apple`, `/features/copilot`) | 404, `text/plain`, for the feed address |
| Rate limits | No rate-limit header on any answer. One request ended in a connection timeout and succeeded when repeated; the cause was not established. The limit GitHub applies to these addresses stays unknown |

The parser already does what these feeds need (read in the code by the driver and by the critic; confirmed by the fixtures in criterion 11): the entry `id` is the identity, `updated` is the fallback date, titles have their white space collapsed, an empty `content` gives no excerpt, `media:thumbnail` becomes the item's image, and a feed with no entry is still a feed.

**Settled here**, because the issue and the specification leave it open:

1. **What is recognised.** A typed address, after `SourceAddress.parse`, is a repository address when: the host is `github.com` or `www.github.com` and the normal form has no port (a default port is already removed by the normal form); the path has at least two segments; the first is an owner (1–39 ASCII letters, digits or hyphens); the second, after one trailing `.git` is removed, is a repository name (1–100 ASCII letters, digits, `.`, `_` or `-`; not `.` or `..`); and the last segment does not end in `.atom`. The query is ignored. So `github.com/o/r`, `https://github.com/o/r/`, `…/o/r.git`, `…/o/r?tab=readme-ov-file`, `…/o/r/releases`, `…/o/r/issues/3` and `…/o/r/tree/main` are all repository `o/r`. An address that ends in `.atom` is a feed address and takes the ordinary path (it is saved as a feed, as today). No list of GitHub's reserved first segments is kept: decision 4 covers them.
2. **The three feed addresses** are built, never read from a page: `https://github.com/<owner>/<repo>/releases.atom`, `tags.atom`, `commits.atom`, with owner and repository in **lower case**, whatever scheme, `www.` or case was typed. GitHub answers every case alike (measured).
3. **Detection.** For a repository address the detector does not look the typed address up and does not fetch the page. It looks each of the three feed addresses up in the library, **ignoring ASCII case** — so a feed pasted earlier as `…/GRDB.swift/releases.atom` and stored with its case is found — and fetches the ones not there, with the machinery of declared feeds (`SourceDetector.check`): at most four at once, each fetched once without validators, the phase within the candidate limit of 20 seconds, the same four states (usable, already added, failed, not checked in time). A repository address costs three requests.
4. **When it is not a repository.** If all three ended in `gone` (404 or 410), the address is not a public repository: detection continues on the ordinary path with the typed address and gives the result it gives today (its lookup, the page fetch, discovery), after those three requests. A missing or private repository therefore ends in today's "Could not read this address", and a reserved path such as `/topics/swift` in today's page result.
5. **When nothing can be offered.** If no feed is usable, already added or unchecked, and they are not all `gone`, the result is today's `failed` with the Releases feed's reason and the typed address, with `addedScheme` false (the hint about typing `http://` does not apply to built https addresses); "Save as a Web Page" is offered under today's rule (an HTTP status, too large, too many redirects).
6. **Otherwise** the result is a new case `github`, carrying the repository, the typed address's normal form and the three candidates in the order Releases, Tags, Commits. The app shows the confirm step. **Releases is chosen when it is usable** — also when it has no entries (spec: "Releases (default)") — **and otherwise nothing is chosen**: Save stays disabled until the owner picks a row. A Releases feed that is already added, failed or unchecked never makes Tags the silent default: Tags has the same links without the notes.
7. **The confirm step for a repository.** Address: `https://github.com/<owner>/<repo>` as typed (case kept; `www.`, `.git` and any deeper path removed). "Choose": three rows titled "Releases", "Tags", "Commits"; second line "Latest item 3 days ago" or "No items yet" for a usable one, and today's wording for the other states ("Already in “…”", "Could not read this address · …", "Could not check in time"). Then today's "This page itself" row, which saves the typed address's normal form as a web-page source (spec N03: a web page is any address; the browser's "Save This Page as a Source" keeps working on GitHub pages). Kind: "GitHub · Releases" (or Tags, Commits), or "Web page". Preview: unchanged, with today's "This feed has no items yet" for an empty feed. Choosing a row that was not checked in time runs the detection again on the repository address; the address field is unchanged, and decision 6's rule chooses afterwards. A web-page source already at the typed address is not looked up at detection; Save's duplicate alert answers it, as today for an address added meanwhile.
8. **The name** suggested is `<owner>/<repo>` as typed for Releases and for the page itself, and `<owner>/<repo> · Tags` or `· Commits` (the row's localised title) for the other two, so two sources of one repository can be told apart. As today, it follows the choice until the owner edits it. Article titles of these feeds are version numbers and commit messages, so the source's name has to say which repository.
9. **What is stored.** A source of kind `github` whose `url` is the chosen feed address (decision 2's lower-case form) — the row the `v1` fixture already holds. `FeedCandidate` carries the kind (`feed` by default) and `addFeedSource` stores it, so Save needs no new path in the app. No migration: `github` has been in the closed set since `v1`.
10. **Collection.** `SourceKind.isCollectedAsFeed` is true for `feed` and `github`. The three package reads and the four app checks named above use it. Everything else about collection is the feed's: limits, validators, identity, status, pausing, retention, the same-link rule.
11. **No avatar as the article image.** Items of a `github` source are stored without an image, at Save and at every collection: the only image these feeds carry is the author's avatar, 30–60 pixels in a 72-point row thumbnail, the same on every row, and each would cost a request to a third host.
12. **No credential.** Nothing is added to a request, and nothing can be: a `TransportRequest` is an address and two validators. The built addresses carry no user name or password. The transport has no cookie storage, no credential storage and declines authentication (RD04, tested on the wire by `TransportLoopbackTests.fixedHeadersOnTheWire` and `.noCookies`); GitHub's `Set-Cookie` answers are not kept.

## Acceptance criteria

Each names its evidence. "Package" is a test in `ios/NewsPawKit`; "UI" is a UI test on the fixture transport.

1. A repository address in each form of decision 1 is recognised, and each form that is not one is not: other hosts (`gist.github.com`, `raw.githubusercontent.com`, `example.com/o/r`), a port other than the scheme's default, one segment, an owner or name outside the character rules, a percent-escape in either, a last segment ending in `.atom`. The three feed addresses are https, in lower case, without user name or password; the page address keeps the typed case. — Package (table).
2. Detecting a repository address makes exactly three requests, to the three feed addresses, none with validators, and returns `github` with three usable candidates of kind `github`. The preview of each is its newest three items. A detection cancelled while the three are in flight throws, and one cancelled between the three and the ordinary path makes no further request. — Package.
3. A repository with no tag returns `github` with Releases and Tags usable and empty, and Commits usable with items. — Package. In the app, Releases is chosen and the preview says the feed has no items; choosing Commits shows its items, and Save stores a source that lists them. — UI.
4. All three `gone`: the ordinary path runs (four requests: the three and the typed address), and the result is what today's detection returns for that address — tested for a page without feeds, for a 404, and for a typed address that is already a web-page source (`duplicate`). — Package.
5. No feed usable and not all `gone` (all unreachable; all 429): `failed` with the Releases reason and `addedScheme` false; the web-page offer follows today's rule. One feed failed beside two usable ones: `github`, the failed one cannot be chosen and says why. — Package.
6. A feed address already in the library is `already added` and is not requested, also when it is stored in another letter case; the other two are requested. A web-page source at the typed repository address does not turn the result into `duplicate`. — Package.
7. Releases already added, failed or unchecked, with Tags usable: nothing is chosen and Save is disabled; the owner can choose Tags or Commits. — Package for the states; UI for "Releases says Already in “…”, nothing chosen, Save disabled, choosing Commits enables Save".
8. A candidate that does not answer within the limit is `not checked`. — Package. Choosing it in the app detects the repository again with the address field unchanged, and the row is usable afterwards. — UI, with a fixture feed that is slow on its first request only.
9. Save stores kind `github`, the lower-case feed address, the suggested name of decision 8 unless edited, the validators and the articles of the detecting fetch, in one transaction and without a request. "This page itself" stores a web-page source at the typed address's normal form, named `<owner>/<repo>` unless edited. — Package; UI for the names and the page row.
10. A `github` source is a refresh target, is collected by `FeedCollector` with a conditional request, gets new articles, keeps identity across collections, and records a failure code as a feed does; a paused one is not requested. The app offers Refresh for it wherever it does for a feed. — Package; UI (the row's menu and one refresh that brings a new item).
11. Articles of a `github` source have no image, from Save and from collection; a `feed` source reading the same bytes keeps it. The synthetic fixtures shaped like the measured feeds parse as the table says: identity from `id`, the link, the date from `updated`, a commit title without surrounding white space, no excerpt for empty content, an excerpt of text only for notes that hold a `<script>` and a link, the content stored as text, and a feed without entries. — Package.
12. The confirm step for a repository shows `https://github.com/<owner>/<repo>` in the typed case for an address typed with `www.`, `.git` or a deeper path, the three rows, the page row and the kind, in English and Simplified Chinese, light and dark, on the three simulators. — UI and screenshots.
13. The three checks of `AGENTS.md` pass; every new string has a Simplified Chinese translation. The existing Add source, source list, refresh and browser UI tests pass unchanged.

## Frozen issue contract

**In.** The thirteen criteria.

**Invariants.**
- Ordinary detection is unchanged for every address that is not a repository address. For a repository address whose three feeds are all gone it gives the same result, after three requests.
- Nothing is written before Save. Save makes no request.
- The schema, the lock files and the dependencies do not change.
- A model has no part in this issue. Feed content is untrusted text: stored, never executed, no link followed.
- The partitions stay apart: the lookups are in the library the sheet was opened for, as today.
- No test contacts an outside host.

**Allowed user-visible change.** A repository address leads to the confirm step with the Releases / Tags / Commits choice and the page itself, instead of "Save as a Web Page" alone; sources of kind GitHub appear, refresh and fail like feeds; their rows have no thumbnail.

**For the owner.**
1. The assumption of spec section 10 is checked for access: the three Atom feeds answer without a token. The rate limit is still unknown; a refused request shows as the source's ordinary failure and is tried again at the next refresh. Nothing backs off.
2. "Releases" lists every tag, not only published releases; a tag without a release shows the tag's message. Releases is empty only when the repository has no tag at all, and then Tags is empty too — Commits is the choice left. Tags is Releases without the notes.
3. Releases and Tags of one repository have the same links. If both are added to one category, the second one's items are dropped by the same-link rule (N04) and its list stays empty.
4. Any address inside a repository — its issues, a branch, a file — offers the same three feeds and the page itself. Commits is always the default branch; for another branch, paste `…/commits/<branch>.atom`, which is saved as an ordinary feed.
5. A renamed repository keeps working through GitHub's redirect; the stored address stays the old one. The same repository added under its old and its new name is two sources.
6. A pasted feed address (`…/releases.atom`) is saved as an ordinary feed, as today, with the avatar as its rows' image. Adding the repository afterwards shows that feed as already added.
7. The source's suggested name is `owner/repo`, with "· Tags" or "· Commits" for the other two feeds.
8. GitHub rows have no thumbnail (decision 11).

**Non-goals.** Issues, pull requests, stars, discussions, private repositories, tokens, GitHub Enterprise hosts, gists, a branch's commit feed chosen in the app, the REST API. Retry or back-off for a refused request. Hugging Face (RD26). OPML and configuration import and export of these sources (RD08, RD20). How the reading screen obtains a body for these sources (RD12). Changing the kind of an existing source. Remembering which unchecked row was tapped across the second detection.

**Causal boundary.** `ios/NewsPawKit/Sources/NewsPawKit/Feeds/{GitHubRepository.swift (new), SourceDetector.swift, FixtureTransport.swift}`, `Model/Source.swift` (one property), `Store/{Library+Sources.swift, Library+Collection.swift, Library+Refresh.swift}`; `ios/NewsPaw/AppState/{AddSourceModel.swift, SourceModel.swift}`, `AddSource/{AddSourceView.swift, ConfirmStepView.swift}`, `LibraryScreen/{SourceRow.swift, SourceWording.swift}`, `UITestIdentifiers.swift`, `Localizable.xcstrings`; tests and fixtures; `docs/reader/spec.md` (N03's GitHub row and section 10, two sentences) and this design. Anything else is out and is reported, not changed.

## Assumptions

Measured facts are in the table above. Still assumed, each to be confirmed by the implementer before code depends on it and written to `assumptions.md`:

- A1. The merged parser reads the synthetic fixtures as criterion 11 says, with no parser change. If it does not, stop and report: a parser change is outside this boundary.
- A2. `SourceDetector.check` can be called with three built addresses, a kind (a defaulted parameter passed on to `fetchCandidate` and `FeedCandidate`) and a case-ignoring lookup, without changing what it does for declared feeds.
- A3. The store step of collection has the source's kind at hand (it reads `kind` in the same statement today), so dropping the image there needs no second read.

## Approach

**Package: `GitHubRepository`.** A value with `owner` and `name` as typed, made by `init?(normalForm:)` from a `SourceAddress` normal form under decision 1; `pageAddress`; `feedAddress(_:)` for `GitHubFeed` (`releases`, `tags`, `commits`, in that order). Pure; no request.

**Package: detection.** `Detection` gains `case github(GitHubDetection)`; `GitHubDetection` holds the repository, the typed address's normal form and the three `DeclaredCandidate`s. In `SourceDetector.detect`, after the parse and before the typed address is looked up: if the normal form is a repository address, run `check` on the three addresses with kind `github`, the case-ignoring lookup and the repository's page address as the place they were found; apply decisions 4, 5 and 6. `FeedCandidate` gains `kind`. `Library.existingSource(atAddress:)` gains a defaulted parameter that compares with `COLLATE NOCASE`; every existing caller keeps the exact comparison.

**Package: store.** `SourceKind.isCollectedAsFeed`. `addFeedSource` stores `candidate.kind`. `refreshTargets` and the two collection reads accept every kind for which the property is true. One internal function removes the image from the items of a `github` source; `addFeedSource` and the store step of collection call it. The two existing tests that state the old rule (`RefresherTests.libraryTargets`, `FeedCollectorTests.nothingDone`) change with it: `github` moves from the kinds left alone to the kinds collected.

**App.** `AddSourceModel`: `github` joins the cases of `apply` (decision 6), `canConfirm`, the candidate list, `chosenFeed`, `webPageAddress` (the typed normal form) and the names (decision 8); `choose` on an unchecked GitHub row detects again without touching the address field. `AddSourceView`: the address step's `outcome` switch gains the case beside `feed` (nothing is shown there). `ConfirmStepView`: decision 7. `SourceModel` and `SourceRow`: `isCollectedAsFeed` in place of `== .feed`. Strings, English with Simplified Chinese: "Releases" 发行版, "Tags" 标签, "Commits" 提交, "GitHub · %@", "Latest item %@" 最新一条：%@, "No items yet" 还没有条目, "%1$@ · %2$@" for the suggested name.

**Fixtures.** Package: synthetic Atom files under `Tests/…/Fixtures/feeds/` shaped like the measured ones (element order, identifier forms, `media:thumbnail`, the commit title's line breaks, an entry with a `<script>` and a link in its notes, a feed without entries), with invented names and text — no real release note is copied. UI tests: `FixtureTransport` answers by full address for `newspaw-fixture/project` (three feeds with items; Releases adds a fresh item at every answer, like the existing counting feed), `newspaw-fixture/untagged` (Releases and Tags empty, Commits with items) and `newspaw-fixture/slow` (Tags slow on its first request only). The feed addresses are on GitHub's host because recognition is bound to it, and nothing is requested from it; item links and thumbnails inside the fixture feeds are under `example.invalid`, like every other fixture.

## Files to change

| Path | Change | For |
| --- | --- | --- |
| `Sources/NewsPawKit/Feeds/GitHubRepository.swift` | add | criterion 1 |
| `Sources/NewsPawKit/Feeds/SourceDetector.swift` | change | criteria 2–8 |
| `Sources/NewsPawKit/Model/Source.swift` | one property | criterion 10 |
| `Sources/NewsPawKit/Store/Library+{Sources,Collection,Refresh}.swift` | change | criteria 6, 9–11 |
| `Sources/NewsPawKit/Feeds/FixtureTransport.swift` | add answers | UI criteria |
| `Tests/NewsPawKitTests/Feeds/{GitHubRepositoryTests (new), SourceDetectorTests, FeedCollectorTests, RefresherTests, FeedParserTests}.swift`, `Store/SourceTests.swift`, `Fixtures/feeds/github-*.atom` | add / change | criteria 1–11 |
| `ios/NewsPaw/AppState/{AddSourceModel,SourceModel}.swift`, `AddSource/{AddSourceView,ConfirmStepView}.swift`, `LibraryScreen/{SourceRow,SourceWording}.swift`, `UITestIdentifiers.swift`, `Localizable.xcstrings` | change | criteria 3, 7–10, 12, 13 |
| `ios/NewsPawUITests/AddSourceTests.swift` (or a new `GitHubSourceTests.swift`), a screenshot test | add | criteria 3, 7–10, 12 |
| `docs/reader/spec.md` | two sentences | what was measured; Releases lists tags |

Package paths are under `ios/NewsPawKit/`.

## Execution surface

- **Executed:** the three checks; the iOS 26.5 package suite; `xcodebuild test` with `-only-testing` while iterating and the whole UI suite once by the driver; `xcrun simctl`; `git`.
- **Outside hosts.** None from any test. One manual check by the implementer, recorded as such with its date: in the simulator with the real transport, add `https://github.com/groue/GRDB.swift` (mixed case, so the lower-case address is exercised), look at the three previews, save Releases, refresh once. Three to five requests to a public host, no account, key or cookie.
- **Not touched:** the schema and its fixture, dependencies and lock files, `.github/`, the parser, the transport, the owner's ignored files.

## Failure handling

| Situation | Result |
| --- | --- |
| Not a repository address | Ordinary detection, unchanged |
| All three feeds 404 / 410 | Ordinary detection on the typed address |
| No connection, time-out, 429, 5xx on all three | "Could not read this address" with the Releases reason, without the http hint; web-page offer under today's rule |
| Some feeds fail | Their rows say why and cannot be chosen; the others can. Releases among them: nothing is chosen |
| A feed answers after the limit | "Could not check in time"; choosing it detects the repository again |
| Releases is already in the library | Its row says where; nothing is chosen |
| The chosen address was added meanwhile, or the page is already a web-page source | Save's duplicate alert, as today |
| A collection is refused later (429, 404 after deletion) | The source's ordinary failing status; tried again at the next refresh |
| Cancel or dismissal during detection | The fetches are cancelled; nothing is stored |

## Risk assessment

- **Rate limiting** is unmeasured. Three requests per added repository and one per source per refresh is small; the consequence of a refusal is a visible failing status.
- **GitHub changes the address forms.** The source fails visibly; the fix is a new build. Nothing is cached that would hide it.
- **The fallback hides a real repository** only if GitHub answers 404 for all three feeds of a public repository; then the owner sees today's behaviour.

## Test plan

Package tests first (criteria 1, 2, 4–11), each seen to fail for the right reason before the code exists; planted failures recorded for criteria 4, 7, 10 and 11 (remove the fallback; choose the first usable feed; leave `github` out of the targets; keep the image). Then the app and its UI tests (3, 7–10, 12).

## Handoff notes

- RD12 reads `kind == .github` for its body plan; this issue creates such sources and changes nothing else for it.
- RD08 and RD20 decide how these sources are exported and imported.
- RD26 (Hugging Face) can follow the same shape: a recognised address, built requests, the `github` case's confirm step.

## Revision record

**Version 1 (2026-11-15).** First draft by the driver, with the first twenty measurements.

**Version 2 (2026-11-15).** Debate round 1, below. Changed: the address step's switch joins the boundary; Releases is chosen only when usable, else nothing; the "This page itself" row stays; the lookups ignore letter case; the unchecked row's second detection is specified; the failure carries no http hint; names tell two feeds of one repository apart; the credential criterion became a statement about what a request can carry, and its loopback test and assumption A4 were dropped; criteria added for mixed states, cancellation and the shown address; fixture links moved under `example.invalid`.

## Debate record

**Round 1 (2026-11-15).** A fresh critic read version 1 against the merged code, the driver's probe records and six requests of its own. Fourteen findings: three P1, five P2, six P3. The driver checked each against the code or a measurement before acting.

| # | Severity | Finding | Disposition |
| --- | --- | --- | --- |
| 1 | P1 | `AddSourceView`'s exhaustive switch over the detection is outside the boundary; the build would break | Admitted: file added |
| 2 | P1 | "First usable" pre-chooses Tags when Releases is already added or failed; Save then makes a second source whose items the same-link rule drops | Admitted: decision 6, criterion 7 |
| 3 | P1 | Without "This page itself", no page inside a repository can be saved as a web page, also from the browser's menu; decision 5 contradicted the owner note | Admitted: the row stays (decision 7); the note was removed |
| 4 | P2 | A branch address silently gives the default branch's commits; sub-pages' declared feeds were unmeasured | Admitted in part: measured three sub-pages (table); deeper paths stay recognised, since the result contains what the `/releases` page declares; the branch case is owner note 4 and a non-goal |
| 5 | P2 | The lower-case lookup misses a feed stored earlier in its typed case | Admitted: case-ignoring lookup (decision 3, criterion 6) |
| 6 | P2 | The unchecked row's path as merged would detect the `.atom` address as an ordinary feed; the outcome after the second detection and its UI test were unspecified | Admitted: decision 7, criterion 8, the slow fixture; remembering the tapped row is a non-goal |
| 7 | P2 | The credential criterion asked for a loopback test that exists and that a GitHub address cannot reach | Admitted: decision 12, criteria 1 and 2; A4 dropped |
| 8 | P2 | No criterion for mixed states, cancellation, or the shown address | Admitted: criteria 2, 5, 12 |
| 9 | P3 | The http hint would show for a GitHub failure | Admitted: decision 5 |
| 10 | P3 | Two feeds of one repository get the same name | Admitted: decision 8 |
| 11 | P3 | "Cut to the name limit" cannot happen | Admitted: removed |
| 12 | P3 | "A port" is ambiguous | Admitted: decision 1, criterion 1 |
| 13 | P3 | Fixture item links would point at GitHub; a request-count fixture is fragile | Admitted: fixtures |
| 14 | P3 | The invariant about the fallback was not exact | Admitted: reworded |
