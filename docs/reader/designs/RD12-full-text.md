# RD12 — Full text from the article page, and reader mode in the browser

Issue: [#133](https://github.com/AlvinShenSSW/NewsPaw/issues/133) · Epic E13 #116 · Requirements N05 (body source 2), N03 (reader mode; the per-source body option), N12 (static extraction); ux S4 (the two lines under the header), S5 (reader mode), S13 (body). Also touched: N04 (collection rules for the fetch), N02 (partitions), N13 (offline tests).
Design version 2, 2026-11-15, frozen after one debate round (see the last section). Author: Claude (planner, for the driver of this AFK run). Implementer: Claude Fable 5. External gate: Codex `gpt-6.1-sol` at high effort.

Builds on RD11 (#132, being implemented: `ArticleBlocks`, `BlocksView`, the body task of the reading model, the excerpt state), RD10 (merged: the embedded browser, its sessions, `BrowserScanTests`), RD04 (merged: `Transport`, its limits, `FeedDiscovery.decode` and `isHTML`) and RD01 (merged: `Readability.js` 0.6.0 in the package, and `ReadabilityCheck`, a test that already runs it in a web view with page scripts off and every load blocked, on macOS and the iOS 26.5 simulator). Names of RD11 are its design's; the implementer reads the merged ones. This issue starts after RD11 is merged.

The owner's instruction for this phase (2026-11-12): one user, converge, no over-engineering.

## Spec review

RD11 shows the feed's own content, and for a feed that carries only an excerpt it stops at "Only an excerpt is available". This issue fetches the article's page in that case and reduces it to its main text without letting the page do anything; the same fetch and reduction give the browser a reader mode.

### Decisions

1. **One extractor, static by construction** (`PageExtractor`, in the package's `Reading/`, main actor; built the way `ReadabilityCheck`'s harness is, whose core moves into it). Input: an HTML string and the address it came from. It refuses a string of more than 3,000,000 characters before anything else. It makes a web view for this one extraction and discards it afterwards:
   - a non-persistent website data store, made for this extraction;
   - page JavaScript off;
   - a content rule list that blocks every load (`url-filter` ".*"), compiled once and reused; the compiled list is kept by the system's rule-list store outside any library and holds nothing of any page;
   - no message handler, no user script;
   - exactly one navigation allowed — the initial load of the string with its address as the base — and every other cancelled, in any frame (a link, a `meta` refresh, a form, a frame's content);
   - when that load finishes, one evaluation in a content world of the app's own: it counts the document's elements and stops above 50,000; else it evaluates the bundled Readability source and calls it on a clone made with `Document.prototype.cloneNode` (a page cannot replace that by naming an element); it returns the article's HTML and its title, each built as a string, which the app checks to be strings.

   The whole extraction has 10 seconds; a web content process that ends, a script error, a null result and the element bound are failures. The returned HTML is cut to 2,000,000 characters and is nothing but input for RD11's converter (`ArticleBlocks.make(html:baseURL:)`): untrusted HTML like a feed's. `BrowserScanTests` is narrowed in this issue: the rule list's `add` and the evaluation are allowed in `Reading/PageExtractor.swift` and nowhere else; every other file, the browser's included, still fails the scan, and the scan gets a test that a second file with the same calls fails. RD11's sentence that nothing of an article is given to a web view becomes: the reading screen has no web view; the extractor's hidden one is N12's.

2. **How much article there is** (`ArticleBlocks.bodyTextLength(_:)`, pure). The characters of paragraph blocks that are not inside a link, counted only for paragraphs with at least 140 such characters — 60 when more than half of the paragraph's letters are Han, kana or Hangul. A page of headlines, cards or links has almost none, however long it is: Readability returns an "article" for ordinary list pages (measured in the debate: 4,741 characters for thirty headlines with summaries), so its answer alone decides nothing. An extraction is *an article* when this length is at least 250 — 100 when most of its letters are Han, kana or Hangul.

3. **The envelope.** `article_body` gets a row per article whose page was extracted: `origin` = `extracted`, `fetched_at`, and in `blocks` a JSON envelope `{"v":1,"html":…,"address":…}` holding the extracted HTML and the address that answered. Blocks are derived from it at every opening, as RD11 derives the feed's. An envelope of an unknown version is treated as absent. The row goes with its article (the cascade). No migration: the table exists since `v1`.

4. **Which body an opening shows** (`BodyPlan`, pure). With the source's kind and body option (S13) and the feed's blocks as RD11 made them:

   | Option | Feed's content | Shown at once | Then |
   | --- | --- | --- | --- |
   | Feed content only | any | the feed's (RD11) | nothing |
   | Automatic, a feed source | full text | the feed's | nothing |
   | Automatic, a feed source | an excerpt | a usable stored extraction with "Full text from the original page"; else the excerpt with "Loading the full text…" | without one: fetch; on success the extraction replaces the excerpt, on failure RD11's excerpt state |
   | Automatic, a GitHub or Hugging Face source | any | the feed's | nothing: their short entries are the content, and their pages are an interface |
   | Always fetch the page | any | a usable stored extraction with the line; else the header and "Loading the full text…" | without one: fetch; on success the extraction, on failure the feed's content as RD11 shows it |

   An article without an http or https link is never fetched. An extraction is *usable* — when fetched and again when read from the store — when it is an article (decision 2) and has more plain text than the feed's content, under either option. "Loading the full text…" stands under the header, where the full-text line then stands; the replaced body starts at its top.

5. **Loading a body is one package type** (`BodyLoader`: a library, a transport and an extractor in; a body or a failure out), so that its rules are tested without the app. The fetch is one request through the app's transport — the one collection uses, which carries no credentials and no cookies — under the collection rules (N04: 20 seconds, 10 MB decoded, 5 redirects, http or https), when the article is opened and never at refresh. Only a 2xx answer that `FeedDiscovery.isHTML` accepts is used; its whole body is decoded with `FeedDiscovery.decode`. The workspace's reading model owns one loader; the body task belongs to the model, not to a view, so a change of width neither cancels nor repeats it. Leaving the article cancels the task, and nothing is stored from a cancelled one. One extraction runs at a time per workspace.

6. **Failures are not stored; some are remembered for a while.**

   | What happened | Remembered | Next opening |
   | --- | --- | --- |
   | Cancelled; any failure while the app is not in front | no | fetches |
   | No answer, the deadline, status 408, 429 or 5xx | no | fetches |
   | Any other status, too large, too many redirects, an address or a challenge the transport refuses, not HTML, over the extractor's bounds, its 10 seconds, its process ended, a null result, not usable | for one hour, in the workspace's memory | shows the fallback without a request |

   The memory is emptied when a source's settings are saved and when the app is relaunched. Every failure ends in the state decision 4 names, with "Open Original Page" as its next step (RD11's wording); there is no separate error text.

7. **Reader mode** (ux S5) is the same fetch and the same extraction, for the address the browser shows. A button in the browser's bottom bar between Forward and More, enabled while a page with an http or https address is shown and has not failed. Tapping it asks the session's own loader call — it is handed the transport and the extractor and no library — for that address; the button shows activity meanwhile, and a navigation, Back or Close cancels it. The page is fetched again, without the owner's sign-in and without its scripts: N12's rule holds for reader mode as it does for articles, and the browser still runs no script of the app's (RD10's invariant is untouched). On an article (decision 2) the session shows a *temporary article* in place of its page: the extraction's title, the page's host and the blocks in RD11's `BlocksView`, with a bar of Close, Share (the page's address) and "Aa". It is a state of the browser session, not a route: it lives in memory, ends with the session, is dropped with the workspace, survives a change of width, and writes nothing. It has no star, no read state and no previous or next; the browser keeps the keys as it does for a page. Opening it pauses the page's media; Close shows the page again, as it was, with its history; a link tapped in it is loaded by the session, which leaves reader mode. On anything else an alert says "This page has no readable article".

8. **Partitions.** Each extraction has its own non-persistent store and web view, discarded with it; the extraction row is in the library of its article; the failure memory, the loader and a temporary article belong to their workspace and go with it (RD18's lock). The transport and the compiled rule list are shared and hold nothing of either library.

9. **Strings.** "Full text from the original page" / 全文来自原网页 (ux S4); "Loading the full text…" / 正在载入全文… (new); "Reader Mode" / 阅读模式; "This page has no readable article" / 这个页面没有可阅读的文章 (ux S5). The source settings' footnote ("Saved now; used once translation and full-text reading are available.") keeps only what is still missing when this merges: "Saved now; used once translation is available." / 现在保存，翻译功能可用后生效。, or nothing when RD14 is merged.

10. **Tests without the network.**
    - *The static rule* is a package test on a loopback listener: the article page — 2,000 characters of text, a `script` that would rewrite it, a `meta` refresh, an image, a style sheet, a font, a frame, `prefetch` and `preconnect` links — is given to the extractor with an `http://127.0.0.1` base, and the listener must receive nothing; the same test with the rule list left out through an internal switch must receive requests (measured in the debate: seventeen and a connection). A counting scheme handler is not used: under an `https` base it sees only images. `ReadabilityCheck` is rewritten to call the extractor.
    - *The loader* is tested in the package with a stubbed transport and a stubbed extractor.
    - *The UI tests* use the fixture transport, which gains: an article page whose text carries a number that changes with every request (so a second fetch shows), a page whose text only its script would build, an ordinary list page (thirty headlines with summaries), a page over the limit, one that never answers and one that is not HTML. Two of these addresses are also pages of the browser's fixtures, for reader mode. The timeout test injects a deadline; it does not spin a web view.

### For the owner

1. A page is fetched when its article is opened, not at refresh: an excerpt-only article you never opened while online has no full text offline.
2. The fetch carries no cookies and no sign-in, and identifies itself as the app's collection does. A paywalled page gives its teaser. A short teaser is refused and the article stays an excerpt; a teaser longer than the excerpt and longer than about 250 characters of running text is taken, kept, and shown as "Full text from the original page". For a source that does this, "Feed content only" is the remedy.
3. **Reader mode fetches the shown page again, without your sign-in and without its scripts**, as the specification's static rule says. So a page that needs a sign-in, or builds its text with scripts, has no reader mode. Reading the page as the browser shows it would lift both limits, at the price of the app running a script of its own in browser pages — which RD16's page translation brings anyway. Say so if you want reader mode to do that then.
4. With "Always fetch the page" the screen shows a loading line until the page arrives (about a second on a good connection, up to 30 seconds on a dead one) instead of the feed's text first.
5. GitHub and Hugging Face sources fetch a page only under "Always fetch the page".
6. A page that cannot become an article is not tried again for an hour; a network failure is tried again at the next opening. There is no "Try Again" on the excerpt state: ux S4 gives it "Open Original Page" only.
7. A very large or deliberately built page can keep the hidden web view's process busy and use much memory before the 10 seconds end (measured on a Mac: a 635 KB page took 10.5 seconds and 2.4 GB in that process, not in the app). The input is bounded at 3,000,000 characters and one extraction runs at a time; what iOS does with such a process is a device check.
8. The extracted text is kept with its article and removed with it by retention; it is not part of the image cache and "Clear" does not remove it.
9. One new sentence that ux section 4 does not have: "Loading the full text…" / 正在载入全文….
10. A reader-mode article cannot be starred or kept; "Save This Page as a Source" and Share are the ways to keep it (ux S5). Its translation is RD15's and starts on your tap.
11. `article_body.blocks` holds the extracted HTML in a small envelope, not block JSON as section 4 of the specification says: blocks are derived at opening, as RD11 does for a feed's content.
12. Success on your real sources is observed on the device, not assumed: no per-site rules exist.

## Acceptance criteria

| # | Criterion | Evidence |
| --- | --- | --- |
| 1 | An excerpt-only item whose page is the fixture article shows the extracted text with "Full text from the original page"; reopening it, also after a relaunch, shows the same number in its text (no second request) | UI |
| 2 | `BodyPlan`'s table, every row; "Feed content only" never requests; "Always fetch the page" requests when the feed has full text and shows the feed's content when the fetch fails; a GitHub source under Automatic never requests | Package; UI for the first two |
| 3 | Decision 6's table, every row: what is shown, whether it is remembered, that the hour and a saved source setting end the memory (injected clock) | Package; UI for a page over the limit and one without an article |
| 4 | The static rule: the article page is extracted with the markup's text (its script did not run), without navigating (the `meta` refresh) and with nothing received by the listener; with the rule list left out the listener receives requests | Package, on macOS and on the iOS 26.5 simulator |
| 5 | A page whose text only its script would build is not an article and falls back; a `script`, an event attribute and a `javascript:` link in an extraction come out of `ArticleBlocks` as RD11 says | Package |
| 6 | `bodyTextLength`: the list page of thirty headlines with summaries, sixty bare links and forty image cards are not articles; a three-paragraph article, a 136-character Japanese item and a Chinese article are; a 300-character page against a 2,000-character feed body is not usable under either option | Package |
| 7 | Reader mode on the browser's article page shows the temporary article; on the list page the alert appears; the reader's call is handed no library (it cannot write one) | UI; package (the call's signature and a library whose rows are unchanged) |
| 8 | The temporary article has Close, Share and "Aa" and no star; Close shows the page again with its history (Back still goes where it went); a link in it loads in the browser; a change of width keeps it; iPhone and iPad | UI |
| 9 | Leaving an article during its fetch stores nothing; one extraction at a time; an input over 3,000,000 characters and a document over 50,000 elements are refused without a clone; the injected deadline ends an extraction and discards its web view | Package |
| 10 | The envelope: an unknown version reads as absent; a stored extraction is checked again when read | Package |
| 11 | `BrowserScanTests` allows the two calls in `Reading/PageExtractor.swift` only, and a planted second file fails it; the extractor's settings are asserted (page scripts off, non-persistent store, the rule list attached, no message handler) | Package |
| 12 | The three checks; every string translated | CI |
| 13 | Largest text, dark, Simplified Chinese: the loading line, the full-text line, a temporary article, the alert; iPhone and iPad | Screenshots |

## Frozen issue contract

In scope: `PageExtractor` (with `ReadabilityCheck` rewritten on it and `BrowserScanTests` narrowed for it), `ArticleBlocks.bodyTextLength`, the envelope and its `Library` queries, `BodyPlan`, `BodyLoader` and its failure memory, the body task's use of it, the two lines under the header, the loading state, reader mode's button, the session's temporary article and its alert, the fixtures, the strings.

Out of scope: per-site rules; fetching at refresh or in the background; a sign-in or cookies for the fetch; reading the browser's live page; any script of the app's in a browser page (RD16); translation of any body (RD15); Article info (RD15); keeping or starring a reader-mode article; a "fetch again" for a stored extraction; a setting for the thresholds; another identity for the page request.

Invariants:

- The extracting web view runs no script of the page, requests nothing from the network, navigates once, and has a store of its own that is discarded with it.
- What the extractor returns is used only as input of `ArticleBlocks`.
- Every page request, for an article and for reader mode, goes through the transport under the collection rules and carries no credentials.
- The browser's web views run no script of the app's and have no message handler (RD10, unchanged).
- A reader-mode article writes nothing to a library.
- Offline tests request nothing outside the process.

## Approach

RD11's body task reads the feed's HTML and converts it. This issue puts `BodyLoader` behind that task: it applies `BodyPlan`, reads the envelope when the plan may use it, else fetches, decodes, extracts, checks and stores. The browser session uses the loader's fetch-and-extract half only. The extractor is one small type with one call (`extract(html:address:) async throws -> Extraction`) behind a protocol, so that the loader's tests stub it.

## Failure handling

Decision 6's table, and:

| Failure | Behaviour |
| --- | --- |
| The rule list cannot be compiled | Extraction fails for every page (it never runs without the list); the screens show their fallbacks |
| The extraction cannot be stored | It is shown for this opening; the next opening fetches again |
| The article is deleted during its fetch | The result is dropped |
| The workspace stops during an extraction | Cancelled; nothing stored; the web view discarded |
| The reader's fetch fails for any reason | Reader mode's alert; nothing is remembered |

## Assumptions

`ReadabilityCheck` (merged, macOS 27 and the iOS 26.5 simulator) and the debate's measurements (macOS 27) already show: page scripts and event attributes do not run with page JavaScript off while the app's evaluation does; the block-everything rule list stops seventeen kinds of load and the connection of `preconnect`; every later navigation reaches the delegate; a web view in no window loads and answers; Readability is defined only in the app's world and took 0.03 seconds on the fixture; a web view works under `swift test`. What is left for the implementer to measure, each reported:

| Assumption | If it does not hold |
| --- | --- |
| A1. The same holds on the iOS 27 simulator, and under `swift test` with CI's Xcode 26.6 | Report to the driver before going on; for CI alone: the extractor's tests run in the simulator package suite (driver, before the gate) and the pull request says so |
| A2. A web view in no window finishes the load and the evaluation on iOS while the app is in front | Attach it, hidden and 1 point large, to the scene's window for the extraction |
| A3. After the deadline discards a web view whose process is busy, the process ends within a minute on the simulator | Report the measured time; "For the owner" 7 then carries it |
| A4. Showing `BlocksView` in the browser's pane in place of the page keeps the page's web view alive underneath, and `pauseAllMediaPlayback` pauses its media | Keep the web view in the hierarchy, hidden; report what media does |

## Risks

- The static rule stands on WebKit behaviour. Criterion 4 runs on both systems, and its second half proves the test can see a load.
- Readability on real pages, and the two lengths of decision 2 on real articles, are unknown until the owner's sources are tried; they are constants.
- A hidden web view per opening costs memory and a process start; one at a time bounds the number, not the size of what one page can do within 10 seconds ("For the owner" 7).
- A teaser kept as full text ("For the owner" 2) has no way back short of the source's option.

## Test plan

Package: criteria 2 to 6 and 9 to 11, and 7's second half. UI (iterated with `-only-testing`; the whole suite once at the final commit; iPhone and one iPad): criteria 1, 2, 3, 7, 8. Screenshots (13). The package suite on the iOS 26.5 simulator before the external gate.

Device checks owed: five of the owner's excerpt-only sources, recorded as observed (extracted, refused, failed); a paywalled page; a site that answers the app's request identity differently from a browser's; reader mode on an article page and on a script-built page; a large page's time and what becomes of the web view's process; memory while flipping through ten excerpt-only articles.

## Handoff notes

- RD15: translates an extracted body like a feed's, and only once the body plan has settled (not the excerpt first, then the full text); the envelope's `fetched_at` and origin for Article info; a temporary article's translation starts on the owner's tap and lasts while it is open.
- RD16: the bottom bar's order (Back, Forward, Translate, Reader Mode, More); it brings the app's script into browser pages and narrows the scan for itself — reader mode from the live page (owner's item 3) can be decided then.
- RD18 / RD19: the compiled rule list is written outside both libraries and holds nothing of a page; Delete need not remove it. The adult workspace has its own loader, memory and sessions.
- RD24: background refresh does not fetch pages.

## Revision record

Version 1 → 2, 2026-11-15: one debate round with an independent critic (Claude Fable 5), 22 findings (3 P1, 7 P2, 12 P3), with WebKit measured on macOS 27 (`scratchpad/rd12-debate/`). The static rule held against everything tried. All admitted; the largest change is the driver's own answer to F2, F3, F9, F11, F14 and F15 together: reader mode no longer reads the browser's live page.

| Finding | Resolution |
| --- | --- |
| F1 (P1) Readability returns an article for ordinary list pages | Decision 2: running text outside links in paragraphs of a minimum length; the list fixture is an ordinary list; criterion 6 |
| F2 (P1) The merged scan forbids the calls the design needs, and RD10 froze "no injected script" for the browser | Decision 1: the scan narrowed to one file, in scope, with its own test. Decision 7: reader mode fetches again, so the browser gets no script and RD10's invariant stands |
| F3 (P1) A reading screen pushed above the browser's route ends the session | Decision 7: the temporary article is a state of the session, shown in its pane |
| F4 (P2) The failure classes were not total, and "until relaunch" had no way out | Decision 6's table; one hour; emptied by a saved source setting |
| F5 (P2) The cost of a large or hostile page was understated | Decision 1 (input bound, element count before the clone, no `maxElemsToParse`); "For the owner" 7; assumption A3; the timeout test injects a deadline |
| F6 (P2) The acceptance rule ended wrong for short and Chinese or Japanese articles, for "Always fetch" with a good feed body, and the owner was told paywalls are refused | Decisions 2 and 4 (scaled lengths; "more than the feed's" under both options); "For the owner" 2 |
| F7 (P2) The planted run could not see most loads; RD01's check was not cited | Decision 10: a loopback listener with an `http` base; `ReadabilityCheck` rewritten on the extractor; the assumptions list what is already shown |
| F8 (P2) Evidence named where it cannot be produced | Decision 5 (`BodyLoader` in the package); criterion 1's changing number; criterion 7's structural half |
| F9 (P2) The live read was underspecified | Gone with the live read; decision 7 states the button's enabling, activity and cancelling |
| F10 (P2) GitHub and Hugging Face sources under Automatic | Decision 4's row |
| F11, F18 (P3) Amendments not listed; "blocks every load" not literal | Decision 1 (RD11's sentence), "For the owner" 11, the handoff to RD18; the invariant says "requests nothing from the network" |
| F12, F13 (P3) Decoding, the HTML test, the request's identity, "the workspace's transport" | Decision 5; the identity is told to the owner (item 2) and is a device check |
| F14, F15 (P3) | Gone with the live read; decision 1 builds and checks the returned strings and calls `cloneNode` from the prototype |
| F16 (P3) | Handoff to RD15 |
| F17 (P3) | Decision 9's sentences |
| F19, F20 (P3) | The envelope loses the byline; a stored extraction is checked when read; `maxElemsToParse` dropped |
| F21, F22 (P3) | Decision 7 ("Aa", keys, media); decisions 4 and 5 (where the line stands; the task belongs to the model) |

## Post-implementation record

2026-11-16, internal review round 1 of the pull request. Two refinements, within the design's decisions:

- **Decision 7, "writes nothing".** The images of a temporary article are fetched through the transport like a body's, by a body image loader that reads the partition's image cache and never stores to it (`BodyImageLoader(stores: false)`). The first build used the reading model's loader, which stored them in the partition's cache. The article's own body images (RD11) are stored as before. A cache hit still refreshes that item's modification time, which is how the cache orders what it removes first.
- **Decision 6, the memory of failures.** A failure of a page load during which the app left the front at any moment (the scene began to deactivate) is not remembered, even if the app is in front again when the failure comes. The extractor's 10-second deadline counts time the app was suspended, so such a load could otherwise come back as a timeout remembered for an hour.

2026-11-16, external gate round 1 of the pull request. Two further refinements:

- **Decision 1, the output cut.** The extractor says when it cut the HTML at 2,000,000 characters. The converter's limit is the same, so it would see nothing cut. A body the extractor cut is therefore marked cut, with RD11's cut line and "Open Original Page", when it is fetched and when it is read back. The mark is kept in the envelope as `"cut":true` (absent when not cut; still version 1, so an envelope without it reads as not cut).
- **Decision 7, the address reader mode works for.** Reader mode's fetch and extraction belong to the address shown when it was asked for. A change of the page's address without a navigation (an anchor, `history.pushState`, `replaceState`) cancels the work, and a result for an address the page has left, article or alert, is not shown.
