# RD25 — Search

Issue: [#146](https://github.com/AlvinShenSSW/NewsPaw/issues/146) · Epic E17 #120 · Milestone M2 · P1 · Requirements N05 (search); ux section 7 (and section 1 principle 2, section 2 keyboard). Also touched: N02 and N09 (search results come from the current partition only), N04 (retention), N12 (no external request). Depends on RD14.

Version 2 (2026-11-17), after one debate round (critic round 1, `.afk/runs/2026-11-11-newspaw-reader-backlog/rd25/debate/critic-r1.md`; debate record at the end). Version 1 was written against `main` at `abab44b` (RD01–RD07, RD09–RD13, RD18 merged), RD14 at `c3afc62` (`rd14-wt`, migration `v6`, the `translation` table and the row's `translation`), RD15 at `4b61d2a` (`rd15-wt`), RD19 at `800b19d` (`rd19-wt`, `CategoryMove`), and GRDB 7.12.0 at `92a554c` (the checkout under `scratchpad/dd-rd14-generic/SourcePackages/checkouts/`). Author: Claude (planner).

The owner's instruction for this phase (2026-11-12): one user, converge, no over-engineering.

## Spec review

**What the baseline says.**

- N05: "Search (M2): titles, original and translated, within the current partition."
- N02: "The interface only ever shows the current partition: categories, unread counts, articles, overviews, starred items and search results all come from it." N09: "While locked, nothing from the adult partition is shown: … search results."
- ux section 1, principle 2: "The whole app — Today, Library, Starred, search — shows either the normal or the adult partition." Section 2 (iPad keyboard): "`⌘F` search." Section 7: "Search has a place in the navigation bar from M2 on and is not drawn in the mock-ups."
- Spec section 7, M2 acceptance: "Search finds an article by its original and by its translated title."
- Issue #146: "Search article titles, original and translated, within the current partition, from the search field described in ux. Results use the article row and open the reading screen. `Cmd-F` focuses search on iPad." Criteria: Chinese, Japanese and Latin text; never the other partition's articles, in either direction; "stays responsive with 30 days of articles from 50 sources". Out of scope: "Searching bodies; saved searches."
- Handoffs: RD09 — "`⌘F` RD25's"; "a text field in a pane keeps itself visible (RD03's note)", where RD03's `paneRoot` note exempts a field that "sits in the bar". RD14 — "search may read `translation.title`". RD15 — "`body_translation` is not searched". RD18 — "search runs on the shown workspace's library only" (filed there under RD21 by mistake). RD19 — "search rows of moved articles must go with them (a cascade or step 2), and criterion 11's row counts are extended to the index."

**What the code does today.** Nothing searches. Each partition is one `Library` with one `DatabasePool` whose connections cannot attach another file (`SQLITE_LIMIT_ATTACHED` 0). The shell shows one `Workspace`; another workspace is another shell (`.id(workspace.id)`), and `Workspace.stop()` clears its navigation at a lock, when the adult pool is closed. Lists are `ArticleListModel` snapshots owned by `ReadingModel`, read in pages of 200 through `Library.articleRows(_:filter:after:limit:translationsIn:)` in one serial queue (`enqueue`). Article titles are written once, by `Library.insertArticles` (`ON CONFLICT DO NOTHING`; never updated). Articles are deleted by retention (`cleanUp`), by deleting a source or a category, and by RD19's move (step 2 deletes the moved sources; articles never move). RD14 upserts `translation` rows (`ON CONFLICT … DO UPDATE`) and deletes failed rows when a slot changes; rows cascade with their article. Single-letter list shortcuts (`J K S U R`) are hidden zero-size buttons without modifiers.

**Gaps and contradictions, with the decision taken.**

1. *What is searched.* The task brief that started this design lists excerpts, bodies and body translations as well; the baseline (N05, the issue's scope and its "Out of scope: Searching bodies", RD15's handoff) says titles. **Decision:** original titles and translated titles, nothing else. Excerpts are not searched either: N05 names titles only. (For the owner 1.)
2. *Which translated titles.* `translation` holds a row per article and reading language. A row shows the translation in the current reading language only (RD14 decision 11), so a match on another language's title would list a row whose visible title does not contain the query. **Decision:** the original title and the translated title stored for the current reading language with state `done`; with no reading language (`translationLocale()` is `nil`), originals only.
3. *Scope.* The baseline names only the partition. The brief asks whether a search is per list, per category or the whole library; ux draws no scope control. **Decision:** the whole library of the partition shown — every article, read or unread, starred or not, of paused sources too. No scope bar. (For the owner 2.)
4. *Where the field is.* ux gives "a place in the navigation bar" and draws nothing; the iPhone tab bar has four tabs. **Decision:** a Search button in the navigation bar of the Library root (iPhone) and of the sidebar (iPad, both forms), and `⌘F` anywhere; each opens a Search screen whose field sits in that screen's navigation bar. No fifth tab and no iOS 26 search-role tab: ux fixes four tabs. (For the owner 3.)
5. *Result row and order.* The issue says "the article row". **Decision:** RD09's row as RD14 shows it, with its swipes and menu; newest first in the list order of RD09 decision 2, not by relevance. (For the owner 6.)
6. *Index technology.* `open-source.md` names GRDB's full-text search as a reason for GRDB, and the brief calls SQLite FTS5 "the obvious tool". Measured (Assumptions, "Measurements"): FTS5 is enabled (GRDB's package defines `SQLITE_ENABLE_FTS5`; the system SQLite is built with it), but neither built-in tokenizer serves the owner's languages at the query lengths the owner types. `unicode61` makes a whole run of Chinese or Japanese one token, so "苹果", "人工智能" and "東京" find nothing inside a title. `trigram` finds nothing for a one- or two-character query, which is the usual length of a Chinese or Japanese word ("苹果", "東京", "日本"); its `LIKE` form falls back to a scan for those. A plain table of folded titles scanned with bound substring tests answers every query length in 10–45 ms over 80,000 titles on this machine, at 9.8 MB. **Decision:** no FTS5; a derived table of folded title texts (`search_text`) and a substring scan, with a covering index on `article` so that a page reads only its own 200 article rows (decision 7). FTS5 stays available if a later issue (body search) needs it. The critic re-measured the tokenizers and agreed: an FTS5 design would still need the app's fold, a sync of its own, and a scan for one- and two-character terms.
10. *Library size.* The issue sizes the library at "30 days of articles from 50 sources" — about 50,000 articles here. N04 also allows 90 days and "forever". **Decision:** criterion 7 gates at 50,000; the design states the 200,000-article figures (A1) so that a long retention's cost is known, and builds nothing more for it. (For the owner 8.)
7. *Data model.* Spec section 4 lists no search table. `search_text` is derived data, rebuilt from `article` and `translation`; it is not configuration and is not exported (spec section 5 carries no articles). The spec's table list is not changed by this design; the post-implementation record names the table.
8. *Keyboard learning.* RD19 For the owner 13 left "the iOS keyboard may learn words typed in the adult partition" unhandled. The search field is the place the owner types most in the adult partition. **Decision:** the field turns off autocorrection, as search fields usually do; no other measure. The residual stays with RD19's note. (For the owner 7.)
9. *Gate model.* The issue text names Kimi K3.1 Pro; AGENTS.md (from 2026-11-12) names Codex `gpt-6.1-sol` at high effort. AGENTS.md governs.

## Acceptance criteria

1. **Matching** (package). A query matches an article when one of its texts — the original title, or the `done` translated title in the reading language given — contains every term of the query, after both are folded (decision 3). Shown with: a two-character and a four-character Simplified Chinese query inside a longer title; a two-kanji Japanese query; a katakana query against a half-width-katakana title; `ai` against a title with full-width `ＡＩ`; `APPLE` against `Apple`; a one-character query; two English terms in either order; a term found only in the translated title; a Traditional Chinese original ("蘋果發佈新款晶片") with the Simplified `done` row RD14's conversion stores for `zh-Hans`, found by "苹果", and the same original without that row not found by it; no match for a term found only in a translation of another language, in a `failed` or `none` row, or (with no reading language) in any translation.
2. **Untrusted query text** (package). Each of these returns results or none and never throws: `*`, `"`, `"abc`, `'`, `%`, `_`, `\`, `NEAR(a b)`, `AND`, `OR`, `NOT`, `a:b`, `^x`, `(`, `)`, `-x`, an emoji with a skin-tone modifier, a combining-mark sequence, a string with an embedded NUL, and 10,000 characters of one letter; `%` and `_` match only those characters. Whitespace only (including U+3000) is no query. A query uses at most its first 100 characters; repeated terms count once.
3. **Index is current on every write path** (package). After each of these, `search_text` equals what decision 5 derives from `article` and `translation` (an invariant helper compares the two sets): collection through `insertArticles` (also for a source added with its first articles); an article inserted through the record (the tests' path); a title changed in SQL; a translation inserted as `done`, as `failed`, as `none`; upserted from `done` to `failed` and back; deleted as RD14 deletes failed rows; retention `cleanUp`; deleting a source; deleting a category with its sources; `CategoryMove.run` in both directions (the old library holds no `search_text` row of the moved sources' articles — RD19 criterion 11's row counts extended).
4. **Migration** (package). A library at the migration before this one, holding articles with and without titles and translations in each state and two languages, migrates; `search_text` then equals the derivation; earlier migrations are not edited; the migrated schema holds the table, its five triggers and the index `article_search_order`. Opening a library registers the fold function on every connection (an article inserted through the opened library is indexed); an article inserted through a raw `DatabaseQueue` on the migrated file **without** the function fails with an error rather than leaving the article unindexed (planted failure for "never silently unindexed").
5. **Order and pages** (package). Results come in the list order of RD09 decision 2, in pages of 200 through the same cursor; a run of more than 200 matches sharing one time straddles a page boundary without a repeat or a gap; rows carry the stored translation in the reading language (RD14) and never `content_html`. A queued search read checks, before it touches the database, that its query is still the one wanted and that its page is not already applied, and again after its read before applying (decision 11): with the queue held by a hook while reads for three successive queries are queued, releasing it runs exactly one database read, for the last query, and applies its page once (package, `SearchReads`).
6. **Partitions** (package). With the normal and the adult library open from one `LibraryStore`: a word present only in the adult library's titles and translations returns nothing from the normal library and is found in the adult one, and the reverse; a control word present in both is found in each (so the empty results mean something). The search API takes no second library and no partition.
7. **Responsive at volume** (package). Over a library of 50,000 articles in 50 sources spread over 30 days, each with a body of about 3 KB in `content_html`, and 30,000 `done` translations: the first page for "苹果", "人工智能", "東京", "アップル", "apple", "election", "the", "e" and a 20-term query is recorded, and each is under 500 ms (about ten times the slowest measured on the author's machine; recorded, so the margin is visible). Two checks that do not depend on the file cache: the page query's plan shows the inner select using `COVERING INDEX article_search_order` and no other access to `article` than by `rowid` for the page's rows (no per-match lookup through `sqlite_autoindex_article_1`); and on a fresh connection the first page for "e" reads fewer pages (`SQLITE_DBSTATUS_CACHE_MISS`) than twice the pages of `search_text` plus 200 (measured: 3,733 against a 2,401-page `search_text`; the version-1 shape read 22,749). The migration's backfill over the same library is recorded and under 10 s.
8. **The Search screen** (UI, every simulator). iPhone: the Library root has a Search button; it pushes Search with the field already focused (typing needs no tap). Typing "芯片" lists exactly the fixture row with that title; replacing it with "ai" lists the Japanese row with `ＡＩ`; a query only a translated title contains lists that row. Opening a result shows the reading screen; going back shows the same query and rows. Clearing the field shows the prompt; a query with no match shows "No Results". iPad (pane layouts): the sidebar's Search button and `⌘F` from All Unread show Search in the list pane with the field focused; a result opens in the reading pane.
9. **Letters reach the field** (UI, iPad simulators). With the field focused, typing "kestrel" (it holds `k`, `s`, `e`, `r`) enters the text and opens, stars, marks or refreshes nothing; after a drag on the results ends the field's focus (decision 10), `J` opens the first result in the reading pane.
10. **Partitions in the interface** (UI, iPhone simulator). In the adult partition (fixture authenticator), a word found only in an adult fixture title is found and a normal-only word is not; after locking, Search in the normal partition opens with an empty field, the adult word finds nothing and the normal word is found.
11. **Nothing is kept or sent** (review and package). No query text is written to preferences, the database or a file; the search path has no transport or model (package: the search API is a `Library` method with no transport parameter; the UI tests run under the fixture transport, whose request log shows no request made by a search).
12. The three `AGENTS.md` checks pass; every new string has its Simplified Chinese translation.

## Frozen issue contract

**In scope.** The `search_text` table, its triggers, the fold function and the migration with its backfill; `SearchQuery`; the `matching:` parameter of `articleRows`; the Search list kind, route and screen in both structures; the Search buttons and `⌘F`; the prompt, no-results and failure states; the tests above, including the extension of RD06's retention and RD19's move tests to the index; a search fixture feed.

**Out of scope.** Excerpts, bodies, body translations, page translations, source and category names; relevance ranking, highlighting of the matched text, fuzzy or phonetic matching, pinyin or romaji input matching, Simplified–Traditional or kanji–hanzi equivalence in the index (a Traditional title is reached through RD14's converted title only), stemming; a scope control or filters; a result count; saved or recent searches; search suggestions; Spotlight (N09 forbids adult content there and nothing asks for it); the Today and Starred tabs' own search buttons; any model call.

**Owned by other issues.** RD24 collects in the background through the same `Library` and so through the same triggers; it needs nothing from here. RD23's overviews are not searched. A search over bodies, if the owner ever asks, is a new issue and would need its own index (Handoff notes).

## Assumptions

Measurements behind this design (run 2026-11-17 on an M4 Pro with macOS's SQLite 3.54.0; scripts and data generator in `scratchpad/rd25-design/`: `gen.py` writes 50,000 synthetic articles — 40 % Simplified Chinese, 20 % Japanese, 40 % English titles, ~3 KB `content_html`, 100 sources over 30 days — and 30,140 Simplified Chinese translations; `base.sql` loads them into RD14's schema; `variant_b.sql`, `variant_c.sql`, `triggers.sql` and `q.sh` build and time the options; `fold.swift` times the folding):

| Option | Size | Build | First page, warm (range over 9 queries) | Two-character CJK |
| --- | --- | --- | --- | --- |
| No index: `instr` over `article.title` and a `translation` subquery | — | — | 0.6–100 ms; slowest for rare matches (full scan of the 133 MB table) | found |
| `search_text` table, `instr` scan (chosen) | 9.8 MB | 0.27 s (SQL), +0.08 s folding 80,140 titles in Swift | 10–25 ms; 45 ms for "e" (20,006 matches); 36 ms for 50 terms | found |
| FTS5 `trigram`, external content, `MATCH` | 23 MB in all | 0.6 s | 0.2–13 ms for ≥ 3 characters | **0 rows**, no error |
| FTS5 `trigram`, `LIKE` | same | same | 11–62 ms | found (by scan) |
| FTS5 `unicode61` | — | — | — | "苹果", "人工智能", "東京" all **0 rows** inside a title |

Also measured: the five triggers keep `search_text` exact through insert, upsert to `failed` and to `done`, translation delete, source delete (cascades fire), and a 10,000-article retention delete (+70 ms over the same delete without the table: 220 ms against 150 ms); 2,000 inserted articles take 31 ms with the trigger against 19 ms without. FTS5 query syntax raises errors for `*` ("unknown special query"), `"abc` ("unterminated string") and `AND` ("syntax error") — none of which can reach the chosen design, which binds plain text.

The table above is warm. The critic measured the page query cold (a copy written and read under `F_NOCACHE`, standing in for the first search after a launch; `critic-r1/timing-cold*.out`, `misses.out`), at 50,000 and at 200,000 articles, best of three. Version 1's shape looked up every matching article's row before sorting; version 2's (decision 7) sorts on the covering index and reads only the page's rows:

| Library | Query (matches) | Version 1, cold / warm | Version 2, cold / warm | Pages read, v1 / v2 |
| --- | --- | --- | --- | --- |
| 50,000 | 量子 (0) | 0.02–0.07 s / 8 ms | 0.06 s / 8 ms | 2,401 / 2,401 |
| 50,000 | 人工智能 (83) | 0.06 s / 9 ms | 0.09 s / 11 ms | 2,623 / 2,639 |
| 50,000 | 苹果 (6,452) | 0.54–0.68 s / 22 ms | 0.07–0.09 s / 13 ms | 9,520 / 3,737 |
| 50,000 | e (20,006) | 0.83–0.91 s / 43 ms | 0.08–0.10 s / 17 ms | 22,749 / 3,733 |
| 200,000 | 苹果 (26,023) | 2.35 s / 89 ms | 0.42 s / 69 ms | 41,472 / 14,434 |
| 200,000 | e (80,048) | 3.56 s / 230 ms | 0.48 s / 87 ms | 101,488 / 14,443 |

I re-ran the version-2 shape on my own 50,000-article library and got the same pages read (3,733 for "e", 3,737 for "苹果", 2,401 for the scan of `search_text` alone), and found one thing the critic's report leaves out but its script (`cold-v1.sh`) does: without `ANALYZE` — the app never runs it — SQLite answers `a.id IN (…)` through the unique `sqlite_autoindex_article_1` and **not** through the covering index, so the per-match row lookups come back. With `INDEXED BY article_search_order` the plan is `SEARCH a USING COVERING INDEX article_search_order (id=?)`; `INDEXED BY` a missing index fails the statement ("no such index"), so a lost index is loud. Decision 7 therefore names the index. The index costs 4.7 MB at 50,000 articles and 19 MB at 200,000; `search_text` is 39 MB at 200,000.

A1. **Latency on the device** (library size: gap 10). Not measured on a device. Published single-core figures put the owner's devices at about this M4 Pro's speed, and two to three times slower under heat or Low Power Mode; phone flash has random-read latency of the same order as this SSD. So the honest device assumption is the warm numbers above times 1.5–3, while the cold column, bound by storage, moves less: at 50,000 articles a warm first page within about 100 ms and the first search after a cold launch within about 0.1–0.3 s; at 200,000 articles warm about 100–260 ms and cold about half a second or more. "Within about 100 ms" holds only for this shape, warm, at 50,000 articles; version 1's shape would have taken 0.5–0.9 s cold at 50,000 and 2–3.5 s at 200,000. *Measure first:* the implementer runs criterion 7 and records the numbers; the device check in the pull request is the **first** search after a cold launch (app killed, a minute's wait, relaunch, no list browsed first), a two-character Chinese word on the owner's real library, with the library's article count, recorded as observed. *If it fails* (the owner finds the pause too long): put to the owner — keeping the order key in `search_text` so the scan needs no second table, or a shorter retention; an FTS5 index would not help one- and two-character queries.

A2. **The field in the bar.** `.searchable(text:isPresented:placement: .navigationBarDrawer(displayMode: .always), prompt:)` on the Search screen shows the field in that screen's bar when it is pushed on the Library stack (tabs) and as the root of the list pane's stack (panes), and setting `isPresented` to true on appear focuses it. *Measure first:* a throwaway run on the iPhone 18 Pro Max and iPad mini simulators. *If it fails:* a plain `TextField` with a clear button in a `safeAreaInset(edge: .top)` of the list (as the Unread / All control is placed), focused through `@FocusState`; the rest of the design is unchanged.

A3. **Shortcuts and the field.** SwiftUI shortcut buttons without modifiers take letters even while a text field has focus (RD10 decision 9 removed them under the browser for this reason). Removing the Search list's `ArticleShortcuts` from the hierarchy while the field is focused lets every letter reach the field, and a `⌘F` button in the shell fires while the focus is in a pane. *Measure first:* criterion 9's test. *If `⌘F` does not fire* in some state, that state is listed in the pull request as not delivered, as RD09 did with the arrow keys; nothing else is built.

A4. **Backfill on the device.** The migration's backfill over 50,000 articles takes at most a few seconds on the owner's devices (this machine: about 0.4 s). It runs inside the migration's transaction in the detached open task, while the app shows its loading background. *Measure first:* criterion 7 records it. *If it is much slower* (over 5 s on the volume test here, which would mean far worse on a phone): batch the backfill by `rowid` ranges inside the same transaction; it stays atomic.

A5. **Folding is stable.** `folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)` followed by `precomposedStringWithCanonicalMapping` does not depend on the device's locale (measured: `ＡＩ`→`ai`, `ｱｯﾌﾟﾙ`→`アップル`, `ＧＰＴ－５`→`gpt-5`, `Straße`→`strasse`, `がん` unchanged, Chinese unchanged). *Measure first:* criterion 1's examples pin it. A later iOS that folds a rare character differently leaves that one character unmatched until the article is gone; accepted.

A6. **Rows under the keyboard in a pane.** Panes ignore the keyboard's safe area (RD03 F1), so on an iPad with the software keyboard up the lower results sit behind it. `.scrollDismissesKeyboard(.immediately)` on the Search list lets a drag hide the keyboard and reach every row, also when the results do not fill the pane (a list always bounces). *Measure first:* by hand on the iPad mini simulator with the software keyboard shown (UI tests usually run with the hardware keyboard). *If it fails:* the Search screen in a pane uses `paneRoot(…, avoidsKeyboard: true)` like RD13's form.

A7. **iOS's SQLite runs the app's function inside a trigger.** A function used by a trigger is refused when `trusted_schema` is off and the function is not marked innocuous; GRDB registers with `SQLITE_UTF8 | SQLITE_DETERMINISTIC` and no `SQLITE_INNOCUOUS`. The critic measured macOS's libsqlite3 3.54.0 (`critic-r1/trusted-schema.out`): `trusted_schema` is 1 by default, and the function works in the trigger and in the backfill with GRDB's flags. iOS's build was not measured. *Measure first:* the first UI test that collects a fixture feed on the simulator (every UI test that adds a source does) — if iOS refuses, collection fails loudly with a storage error and that test fails. *If it fails:* the connection sets `PRAGMA trusted_schema = ON` in `prepareDatabase` beside the function (the critic measured that form too); the schema is the app's own, so trusting it is correct.

## Approach

1. **What is searched** (gaps 1–3). For the library shown: each article's original title, and its translated title in the current reading language when that translation's state is `done`. Every article of the library, whatever its read or starred state or its source's paused state. Nothing of the other library is opened, read or counted: the search is a query on the shown workspace's own `Library`.

2. **Terms.** `SearchQuery(_ text: String)` (package, `Store/SearchQuery.swift`, `Sendable, Hashable`): trims white space and newlines (U+3000 included), keeps the first 100 characters (`Character`s), splits on white space, folds each part (decision 3), drops empty and repeated parts, and returns `nil` when none is left. `terms: [String]` are the folded parts in typed order. It has no syntax: quotes, `*`, `%`, `_`, `\`, `NEAR`, `AND` are characters like any other.

3. **Folding.** `SearchQuery.fold(_:)`: `text.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil).precomposedStringWithCanonicalMapping`. Case and width are folded, so `APPLE`, `ａｐｐｌｅ` and `apple` are one, and half-width katakana is full-width. Diacritics are not folded: Foundation's diacritic folding strips the dakuten from kana (`が`→`か`), which would merge different Japanese words. No Simplified–Traditional or hanzi–kanji mapping in the fold. With Simplified Chinese as the reading language, RD14 stores a Traditional title converted to Simplified as a `done` translation (`TextLanguage.judge`, `TitleTranslator`), so a Simplified query finds a Traditional title through that row once the translator has judged the article, and not before; a Japanese original is reachable through its translated title the same way. Adding `Hant-Hans` to the fold was measured by the critic (`critic-r1/fold-check.out`) and rejected: it costs eleven times the fold (0.89 s against 0.08 s for 80,140 titles), rewrites Japanese kanji (東京→东京, 国際→国际) and merges distinct characters (乾杯→干杯, 後天→后天), and ties the stored index to ICU's transform tables.

4. **The index table** (gap 6). In the migration after those merged when this is implemented (expected after RD14's `v6`, RD15's and RD16's; RD23 or RD24 may add theirs first):

   ```sql
   CREATE TABLE search_text (
       article_id TEXT NOT NULL REFERENCES article(id) ON DELETE CASCADE,
       locale TEXT NOT NULL,   -- '' for the original title, else the translation's locale
       text TEXT NOT NULL,     -- the folded title
       PRIMARY KEY (article_id, locale)
   ) WITHOUT ROWID;
   ```

   ```sql
   CREATE INDEX article_search_order ON article(id, COALESCE(published_at, first_seen_at), first_seen_at);
   ```

   The table's primary key serves the cascade and the triggers' deletes; the scan needs no other index on it. Rows exist only for a non-null title and for `done` translations with a non-null title. `article_search_order` is a covering index for decision 7's inner select: it holds the identifier the matches are joined on, the list order's two time columns and (implicitly) the `rowid`, so the matches are sorted and cut to a page without reading an article row (4.7 MB at 50,000 articles).

5. **Keeping it current: triggers and one SQL function.** The fold of decision 3 is registered as the SQL function `newspaw_search_fold(text)` (`DatabaseFunction`, one argument, `pure: true`; `NULL` in, `NULL` out) in `LibraryStore.makeLibrary`'s `prepareDatabase`, beside the attach limit, so every connection of every library has it, the migration's writer included. The migration creates five triggers, so that no write path — collection, a source added with its first articles, the tests' record inserts, RD14's upserts and deletions, RD24's background collection — can forget the index:

   ```sql
   CREATE TRIGGER search_article_insert AFTER INSERT ON article WHEN new.title IS NOT NULL BEGIN
       INSERT INTO search_text (article_id, locale, text) VALUES (new.id, '', newspaw_search_fold(new.title));
   END;
   CREATE TRIGGER search_article_title AFTER UPDATE OF title ON article BEGIN
       DELETE FROM search_text WHERE article_id = old.id AND locale = '';
       INSERT INTO search_text (article_id, locale, text)
           SELECT new.id, '', newspaw_search_fold(new.title) WHERE new.title IS NOT NULL;
   END;
   CREATE TRIGGER search_translation_insert AFTER INSERT ON translation
       WHEN new.state = 'done' AND new.title IS NOT NULL BEGIN
       INSERT OR REPLACE INTO search_text (article_id, locale, text)
           VALUES (new.article_id, new.locale, newspaw_search_fold(new.title));
   END;
   CREATE TRIGGER search_translation_update AFTER UPDATE ON translation BEGIN
       DELETE FROM search_text WHERE article_id = old.article_id AND locale = old.locale;
       INSERT INTO search_text (article_id, locale, text)
           SELECT new.article_id, new.locale, newspaw_search_fold(new.title)
           WHERE new.state = 'done' AND new.title IS NOT NULL;
   END;
   CREATE TRIGGER search_translation_delete AFTER DELETE ON translation BEGIN
       DELETE FROM search_text WHERE article_id = old.article_id AND locale = old.locale;
   END;
   ```

   Deleting an article (retention, a source or category deletion, RD19's step 2) removes its rows through the foreign key's cascade; its translations' cascade fires the delete trigger as well, which then finds nothing or the same row — either order is correct (measured). `translation.locale` is never `''`, so an original and a translation never share a key. The function name and these triggers are part of the schema from then on: a later change of the folding rules ships a migration that rebuilds `search_text` (Handoff notes).

   Explicit writes from Swift were the alternative: today exactly two writers (`insertArticles`, RD14's `storeTranslations`) and the cascade would do, but every write path a later issue adds would have to remember the index. The title trigger has no writer today (titles are inserted once, `ON CONFLICT DO NOTHING`); it stays, because a later writer of titles would otherwise leave the index stale without a sound, and it costs nothing until then.

   **Which connections write, and what one without the function can do.** The only connections that write a library are its pool's, made in one place (`LibraryStore.makeLibrary`), which registers the function on each. Tests open raw queues only to read or to migrate up to `v1`. A connection without the function (the critic's `nofunction.out`): reads, `UPDATE article SET read_at` and similar, and deletes with their cascades work; every `INSERT` into `article` fails with "no such function" — even one with a null title, because a trigger is compiled whatever its `WHEN` — and so do every `UPDATE` of `translation` and every title update, and the transaction rolls back; `ALTER TABLE … ADD COLUMN` and `RENAME COLUMN` work and keep the triggers. The one silent mode is a table rebuild of `article` or `translation` (create, copy, drop, rename), which leaves no trigger: the Handoff notes bind any such migration (criterion 4 plants the raw-connection insert).

6. **The backfill.** Inside the same migration, after the table and triggers: `INSERT INTO search_text SELECT id, '', newspaw_search_fold(title) FROM article WHERE title IS NOT NULL`, then the same from `translation WHERE state = 'done' AND title IS NOT NULL`. It is atomic (GRDB runs each migration in one transaction; an interrupted launch leaves the old schema and runs it again), it runs off the main actor in `LibraryStore.open`'s detached task, and it does bounded work: one pass over each table (A4). The adult library is migrated when it is next opened, at an unlock.

7. **The query** (F1). `Library.articleRows(_:filter:after:limit:translationsIn:matching:)` gains `matching query: SearchQuery? = nil`. With a query, the page's rows are chosen by an inner select that touches only `search_text` and the covering index, with the cursor condition and the limit **inside** it; the outer query keeps the lists' columns, joins and order and gets no cursor or limit of its own:

   ```sql
   SELECT <articleRowColumns>
   FROM article JOIN source ON source.id = article.source_id
   LEFT JOIN translation ON translation.article_id = article.id AND translation.locale = ?   -- RD14, when a locale is given
   WHERE article.rowid IN (
       SELECT a.rowid FROM article a INDEXED BY article_search_order
       WHERE a.id IN (SELECT article_id FROM search_text
                      WHERE locale IN ('', ?) AND instr(text, ?) > 0 [AND instr(text, ?) > 0 …])
         [AND (COALESCE(a.published_at, a.first_seen_at), a.first_seen_at, a.rowid) < (?, ?, ?)]   -- the cursor
       ORDER BY COALESCE(a.published_at, a.first_seen_at) DESC, a.first_seen_at DESC, a.rowid DESC
       LIMIT ?)
   ORDER BY <articleOrderSQL>
   ```

   Plan (measured): `SEARCH a USING COVERING INDEX article_search_order (id=?)` over the list of matches, a temporary sort of the matches' keys, then `SEARCH article USING INTEGER PRIMARY KEY (rowid=?)` for the 200 rows of the page. `INDEXED BY` is required: without `ANALYZE`, which the app never runs, SQLite picks the unique `sqlite_autoindex_article_1` for `a.id IN (…)` and reads every matching row again (measured); a missing index makes the statement fail rather than slow. Arguments, in order: the join's locale (RD14), the reading locale's raw value (or `''` when there is none), one per term, the cursor's three, the limit; a test covers the order with a cursor and a locale. Search calls it with scope `.library` and filter `.all` (no other scope condition exists for it); the order, the cursor values, the page size of 200, the translation join and the row record are the lists' own. All terms must be in the same text. Every argument is bound; `instr` has no pattern syntax; the work is one scan of `search_text` (at most 100 characters of terms, short-circuited per row), a sort of the matches' index entries and 200 row reads — measured cold at 0.08–0.10 s and warm at 13–17 ms for 6,452 and 20,006 matches on 50,000 articles (Assumptions). A result has no total count.

8. **Where search is, in the navigation model** (gap 4). `LibraryRoute.search`, `SidebarItem.search` and `ArticleListKind.search` are added. `ArticleListKind.search`: scope `.library`, fixed filter `.all`, no filter control, no "Mark All as Read", browser stack `.library`; `list(of: .search)` is `.search`; `sidebarSelection` is `.search` when the Library stack's list is Search (no sidebar row carries that tag, so no row is highlighted); `select(.search)` sets the Library path to `[.search]` like any list; an article opened from it is `[.search, .article(id)]`, its page `[.search, .article(id), .page(url)]`, exactly as for other Library lists, so `J`/`K`, previous and next, the reading pane and RD10's browser need no change. `PaneContainer` shows `.search` with the list pane and the reading pane, as the other lists. Every `switch` over these enums gains its case; the compiler lists them.

9. **Opening Search.** `NavigationModel.openSearch()`:
   - when Search is not on the Library stack: the reading model drops the Search list's model (decision 11: a new search starts empty), then tabs: `currentTab = .library`, `libraryPath = [.search]`, Search entered; panes: `select(.search)`;
   - when Search is on the stack but not on top (an article or page above it): the path becomes `[.search]` and the text is kept;
   - in both cases it asks the Search screen to focus its field (an observed request counter the screen watches).

   Entry points: a "Search" button (`magnifyingglass`) in the Library root's navigation bar (tabs, trailing, before the Add menu); a "Search" button in the sidebar's navigation bar (both forms, trailing, before Edit; in the slide-over it closes the slide-over first, as other choices there do); and `⌘F`, a hidden button in `ShellView` titled "Search" (it appears in the system's shortcut list), which acts only when no sheet, slide-over, dialog or confirmation is open (asked when pressed, like `keysMayAct`). Opening Search replaces the Library stack, so a browser on it ends as with any other list selection (RD10 decision 3). Today, Starred and Settings get no button (For the owner 3).

10. **The Search screen.** `ArticleListView(kind: .search)` with, for that kind only: the title "Search"; `.searchable(text:isPresented:placement: .navigationBarDrawer(displayMode: .always), prompt: "Titles, Original or Translated")` with autocorrection off (gap 8); no `.refreshable`, no toolbar menu, no "Mark All as Read", no filter control; `.scrollDismissesKeyboard(.immediately)` (A6); the list's `ArticleShortcuts` without `R`, and absent while the field is focused (A3). Rows, swipes, the row menu, thumbnails, the footer's "Could not load" / "Try Again" and the paging spinner are the lists' own. States:
    - no query (empty or white space only): an empty state "Search Article Titles" with "Finds articles by their original or translated title.";
    - a query being read for the first time: nothing new — the previous rows stay until the new page replaces them; a first read ever shows the list's usual loading;
    - no match: "No Results" with "No article title contains “⟨text⟩”." (the text as typed, trimmed);
    - a failed read: the lists' failure footer, or the list's failed state when nothing is shown.

    The screen is a pushed screen in the tab structure (keyboard avoidance as usual) and a pane root in the panes (`paneRoot` ignores the keyboard; the field is in the bar, which RD03's note allows).

11. **Typing and reading** (lesson 1). The Search list's `ArticleListModel` gains `text: String` (what the field shows) and `query: SearchQuery?` (what its rows were read for). `ReadingModel.setSearchText(_:)` stores the text and computes the query:
    - unchanged query (for example a trailing space): nothing;
    - `nil`: the pending debounce is cancelled, the rows are cleared and the prompt shown, no read;
    - otherwise the pending debounce task is cancelled and a new one sleeps 300 ms; **after the await** it goes on only if it was not cancelled, the reading model is not stopped, the Search model is still the one in `lists[.search]` (`===`) and its text still gives the same query; then it sets `query` and calls `reload`.
    - Submitting the field (Return) does the same at once, without the sleep.

    `reload` of the Search model with no query reads nothing: it clears the rows and shows the prompt (this covers an entry, a tab selection and a run's end before anything was typed). `reload` and `loadNextPage` pass `model.query` to `articleRows` when the kind is `.search`; they run in the reading model's serial queue, so reads land in the order they were asked. That queue also carries list reads and read and star saves, so a search read that is no longer wanted must not hold it up (F2). The bookkeeping is a small package value, `SearchReads` (beside `SearchQuery`), kept by the Search model: each first-page read asked for (by the debounce, Return, an entry or a run's end) starts a new **generation** with its query; a read carries its query, its generation and its cursor (`nil` for the first page). `mayRead(_:)` is true only when the read's generation and query are the current ones and no page for its cursor has been applied in this generation; `mayApply(_:)` asks the same, and `didApply(_:)` records the cursor. The queued operation calls `mayRead` **before** it touches the database and returns at once when it is false; after its await it calls `mayApply`, checks that the model is still the live one, and only then applies the page. So typing in bursts queues several reads but only the newest runs its scan; a next-page read of an older generation is dropped the same way, and a duplicate page is never applied. At `stop()` the debounce task is cancelled; a queued read then runs into the closed library and fails, shown nowhere, as RD18 arranged for all list reads. Typing never waits for the database: reads run on the pool's reader connections and only their results come to the main actor. While a Chinese or Japanese input method is composing, the field's text may hold the uncommitted letters; those searches are superseded when the text is committed, and do no harm.

12. **Snapshot rules.** RD09 decision 3 holds for Search: a row whose read or starred state changes stays where it is; returning from the reading screen, a sheet closing or a width crossing reads nothing (the text and rows live in the reading model, so crossing 700 pt keeps them); selecting the Library tab while Search is its top re-reads the same query; a refresh run that ends while Search's first row is on screen re-reads the same query (new matches appear). Entering another Library list drops the Search model as it drops any other list's, so the next Search starts empty. RD14's translation updates reach Search's rows as they reach every living list; a changed reading language re-titles rows in place and the match set follows at the next read.

13. **Partitions** (N02, N09). The Search model, its text and its rows belong to the shown workspace's `ReadingModel`; nothing of them is stored. At a lock, `Workspace.stop()` stops the reading model and clears the navigation, the adult shell is replaced (`.id(workspace.id)`), and the adult library is closed: the adult text and rows are gone, and nothing can search the adult library until the next unlock. The normal workspace's Search never touches the adult library: it has no reference to it. Each library has its own `search_text`, written by its own triggers — also while locked, when RD24 collects adult sources, which writes and serves nothing to the interface (spec section 6). No count or sign of the other partition appears anywhere in Search.

14. **No model, no network.** The search path is a `Library` read; it holds no transport, slot or key, and no request leaves the device.

15. **Strings** (English, with the Simplified Chinese the catalog adds): "Search" 搜索 (button, title, shortcut); "Titles, Original or Translated" 原标题或译文标题 (prompt); "Search Article Titles" 搜索文章标题; "Finds articles by their original or translated title." 按原标题或译文标题查找文章。; "No Results" 没有结果; "No article title contains “%@”." 没有文章标题包含“%@”。. New accessibility identifiers: the two Search buttons, the Search list, its prompt and no-results states.

## Files to change

Package (`ios/NewsPawKit`):

- `Sources/NewsPawKit/Store/Schema.swift` — the new migration: table, covering index, triggers, backfill (decisions 4–6).
- `Sources/NewsPawKit/Store/LibraryStore.swift` — register `newspaw_search_fold` in `prepareDatabase` (and, only if A7 fails, `trusted_schema`).
- `Sources/NewsPawKit/Store/SearchQuery.swift` (new) — `SearchQuery`, `fold`, the function's definition and name, the inner select's SQL, `SearchReads`.
- `Sources/NewsPawKit/Store/Library+Articles.swift` — `matching:` and the nested page query (decision 7).
- `Sources/NewsPawKit/Feeds/FixtureTransport.swift` — two search fixture feeds (Test plan).
- Tests: `Store/SearchTests.swift` (new: criteria 1–6 and 11), `Store/SearchReadsTests.swift` (new: criterion 5's queue line), `Store/SearchVolumeTests.swift` (new: criterion 7), `Store/SchemaTests.swift` (the new migration's schema and the migration test), `Store/RetentionTests.swift` and RD19's `Store/CategoryMoveTests.swift` (the index invariant after clean-up and after a move), a shared helper `expectSearchTextMatchesDerivation(_:)`.

App (`ios/NewsPaw`):

- `AppState/NavigationModel.swift` — the three cases, `openSearch()`, the focus request (decisions 8–9).
- `AppState/ArticleListModel.swift` — `text`, `query`.
- `AppState/ReadingModel.swift` — `setSearchText`, `submitSearch`, the debounce and its guards, query-aware `reload` / `loadNextPage` with `SearchReads` checked before and after the read, the drop on opening, `stop()` (decisions 11–12).
- `Destinations/ArticleListView.swift` — the Search variant and its states; `ArticleShortcuts` without `R` for Search and absent while its field is focused.
- `LibraryScreen/LibraryRootView.swift`, `Navigation/SidebarView.swift` — the Search buttons.
- `Navigation/PaneContainer.swift`, `Navigation/TabContainer.swift` — `.search` routing.
- `Navigation/RootView.swift` (`ShellView`) — the `⌘F` button.
- `Localizable.xcstrings`, `UITestIdentifiers.swift`.
- `NewsPawUITests/SearchTests.swift` (new).

## Execution surface

- SQLite on the library's own pool: the scan on reader connections; the triggers and the fold function on the writer, inside the transactions that already write articles and translations; the backfill in the migration, in `LibraryStore.open`'s detached task.
- Swift on the main actor: the field's text, the debounce task, applying pages. No new actor.
- No network, no model, no keychain, no new preference, no new file, no new dependency, no entitlement. The search table lives in each partition's existing database file and is part of its backup like the titles it copies.

## Failure handling

| Situation | What happens | Shown |
| --- | --- | --- |
| The query is white space only | No read | The prompt |
| The query holds FTS, `LIKE` or SQL syntax, a NUL, or 10,000 characters | Bound as text; at most 100 characters used | Results or "No Results" |
| The read fails (storage error) | Rows already shown stay | "Could not load" · "Try Again" (RD09 footer), or the failed state |
| A read for an older query is still queued when a newer one is asked | It returns before touching the database (`mayRead`) | Nothing |
| A read for an older query completes after a newer one was asked | Its page is dropped (`mayApply`) | Nothing |
| The covering index is missing (a later migration dropped it) | The page query fails ("no such index") | "Could not load" · "Try Again"; criterion 4 and 7's plan check catch it in tests |
| The adult partition locks during typing or a read | Debounce cancelled; queued read fails into the closed library; the shell is replaced | Nothing (the normal partition at its root) |
| A result's article is deleted (retention, source deleted) before it is opened | RD09's vanished-article path | The row leaves the list |
| The migration fails (disk full, interrupted) | Its transaction rolls back; the library does not open | RD02's library failure screen; the next launch runs it again |
| A connection without the fold function writes an article or translation | The statement fails ("no such function") and the transaction rolls back | The collection's or translator's existing storage-error path; no such connection exists in the app (criterion 4) |
| `⌘F` while a sheet, the slide-over or a dialog is open | Nothing | Nothing |
| The field is focused and a letter that is a list shortcut is typed | The letter is typed | The text |

## Risk assessment

- **The first search after a cold launch** (A1, F1). With the covering index, 0.08–0.10 s cold on this Mac at 50,000 articles and about 0.45 s at 200,000; the device is not measured. Version 1's shape was 0.5–0.9 s and 2–3.5 s and held the reading model's queue that long. The remaining cost is the cold scan of `search_text` itself (2,401 pages at 50,000), which grows with the library; the owner is told the large-library figure (For the owner 8).
- **The SQL function is now part of the schema.** Any future tool or issue that writes `article` or `translation` from a connection without it fails loudly; a table rebuild of either table silently drops the triggers unless it recreates them (Handoff notes). Accepted for completeness of the index; documented in the schema's comment and the handoff. iOS refusing the function in a trigger (A7) is caught by the first collecting UI test.
- **`INDEXED BY`** ties the query to the index's name; a migration that renames or drops it makes search fail loudly rather than slowly.
- **Index drift.** Triggers cover writes; criterion 3's invariant helper checks every known write path, so a new path added later can reuse the helper.
- **Navigation surface.** A new case in three enums touches every exhaustive `switch`; the compiler finds them, and RD09–RD11's UI tests guard the existing lists.
- **Single-letter shortcuts versus typing** (A3) — the one interaction most likely to break silently; criterion 9 tests it.
- **Privacy.** The query is never stored; the keyboard's own learning is outside the app (gap 8).
- **Startup.** One extra second or so at the first launch after the update, measured (A4).

## Test plan

**Package tests** (`swift test --package-path ios/NewsPawKit`), offline:

- `SearchTests`: criteria 1, 2, 5, 6 with small libraries made through `LibraryStore` in a temporary directory; translations written through RD14's `storeTranslations` (and through SQL for the `failed` / `none` shapes); criterion 3 by applying each write path and then `expectSearchTextMatchesDerivation`, which reads `article` and `translation`, folds in Swift and compares with `search_text` as sets; criterion 4's planted failure — a raw `DatabaseQueue` (no function) on a migrated file, inserting an article, must throw; criterion 11's package half (the API's signature is checked by compilation: no transport parameter exists — reviewed, not tested).
- Planted failures for the rules that say "never": *never the other partition* — the control word (found in both) shows the empty result is meaningful, and the adult-only word is asserted absent from the normal library's `search_text` table as well as from its results; *never throws on query text* — the hostile list of criterion 2 including the FTS5 strings measured to raise errors in FTS5; *never silently unindexed* — the raw-connection insert above.
- `SchemaTests`: the migration test of criterion 4; the expected-columns table extended.
- `RetentionTests`, `CategoryMoveTests`: the invariant after `cleanUp` and after a move in both directions (RD19's handoff).
- `SearchReadsTests` (criterion 5's queue line): a stand-in serial queue built like `ReadingModel.enqueue`, held by a continuation the test releases (lesson 2); reads for three successive queries are queued while it is held, with a counting read closure; on release exactly one read runs, for the third query, and its page is applied once. Also: a next-page read of an older generation does not read; a second first-page read of the same query after a run's end (a new generation) does read; a page for an already-applied cursor is not applied twice.
- `SearchVolumeTests` (criterion 7): seeds 50,000 articles in one transaction (as RD09's volume test does), times each listed query's first page three times and keeps the fastest, prints all timings, asserts each under 500 ms; asserts the page query's plan (`EXPLAIN QUERY PLAN` contains `COVERING INDEX article_search_order` and no `sqlite_autoindex_article_1`); opens a fresh read-only `DatabaseQueue` on the file and asserts the pages read for "e" (`sqlite3_db_status(SQLITE_DBSTATUS_CACHE_MISS)` on `db.sqliteConnection`) under twice `search_text`'s pages plus 200 — a check that does not depend on the OS file cache; seeds a library at the previous migration, opens it with the full migrator and asserts the backfill under 10 s. The time bounds are wide margins over recorded numbers (lesson 2), not tight ratios.

**UI tests** (local, `xcodebuild test` on iPhone 18 Pro Max, iPad mini, iPad Pro 11-inch). Fixture: `FixtureTransport` gains `https://search.example.invalid/rss.xml` with "東京で新型ＡＩ発表", "苹果发布新款芯片" and "Kestrel sightings rise in spring" (an hour apart), and `https://search.example.invalid/private.xml` with "Nightjar observatory notes"; with RD14's fixture translator, translated titles read "译[zh-Hans]：…", which no original contains. Three tests:

1. `testSearchFindsOriginalAndTranslatedTitles` (all three simulators, in the structure each starts in: the Library root's button on iPhone, the sidebar's on the iPads): criterion 8.
2. `testCommandFAndLettersInTheField` (iPad simulators; skipped on iPhone): `⌘F` from All Unread (`typeKey("f", modifierFlags: .command)`), focused field, "kestrel" typed, nothing starred, marked, opened or refreshed (the rows' accessibility labels, the empty reading pane and the refresh status line are unchanged), then a drag on the results and `J`, which opens the first result in the reading pane (criterion 9).
3. `testSearchStaysInItsPartition` (iPhone simulator): criterion 10, with RD18's fixture authenticator and the private feed added in the adult partition.

**By hand / on the device** (listed in the pull request as checked or not): A1's first search after a cold launch — a two-character Chinese word on the owner's real library on the iPhone, with the article count — recorded as observed; pinyin and kana input composing into the field; A6 on the iPad mini simulator with the software keyboard; VoiceOver reads the field's prompt and the states.

## Handoff notes

- **RD24 (background refresh):** collection writes the index through the triggers; the background path must open its library through `LibraryStore` (as it will), so the fold function is registered.
- **A later body search** (not planned): bodies are too long for a scan; it would add an FTS5 `trigram` index over body text in its own table, with the app's fold and a scan fallback for queries shorter than three characters.
- **Changing the folding rules** needs a migration that drops and rebuilds `search_text` (and keeps the function name, or replaces the triggers in the same migration).
- **A migration that rebuilds `article` or `translation`** (create, copy, drop, rename) recreates the five triggers — and `article_search_order` with the other indexes — in the same migration, and its test runs criterion 3's invariant. `ALTER TABLE … ADD COLUMN` and `RENAME COLUMN` keep them.
- **Any new writer of `article.title` or `translation`** needs nothing — the triggers cover it — but should add its path to criterion 3's invariant test.
- **RD18's design** names RD21 for search in two places (Out of scope; Handoff notes); it means RD25.

## For the owner

1. Search looks at titles only: the original title, and the translated title in your reading language. Excerpts and article text are not searched (the issue leaves bodies out).
2. It searches everything in the partition you are in — read and unread, starred or not — not just the list you are looking at. There is no scope switch.
3. On iPhone the Search button is in the Library tab's top bar; on iPad it is at the top of the sidebar, and `⌘F` opens it from anywhere. Today and Starred have no button of their own.
4. Every word you type must appear in the same title, in any order; capital letters and full-width letters (ＡＩ) match their ordinary forms. With Simplified Chinese as your reading language, a Traditional Chinese title is found with Simplified characters once the app has converted it (which happens when titles are translated); one not yet converted is found only with Traditional characters. A Japanese article is found through its Chinese translated title in the same way; the search itself does not treat 东 and 東 as the same.
5. Search starts empty each time you open it and remembers nothing: no history, no saved searches. Going into an article and back keeps your search.
6. Results are newest first, not "best match" first, and the matched words are not highlighted.
7. The search box has autocorrect off. The iPhone keyboard may still learn words you type in the adult partition (as noted for RD19); the app cannot prevent that.
8. Search is built for about 50,000 articles (30 days from 50 sources). There, results should appear in well under a second even for the first search after opening the app. With 90-day or "forever" retention and around 200,000 articles, the first search after opening the app may take about half a second or more; later searches are quicker. The first launch after this update spends about a second preparing search (longer on a very large library); the adult partition does the same at its next unlock.
9. Search adds about 15 MB to a library of 50,000 articles (about 60 MB at 200,000).
10. Search results have no pull-to-refresh; they update when you change the text, and new matches appear after a refresh if you are at the top of the results.

## Revision record

- Version 1, 2026-11-17: first draft. Measurements with the system `sqlite3` (3.54.0) and a compiled Swift script on a 50,000-article synthetic library (`scratchpad/rd25-design/`): FTS5 `unicode61` and `trigram` against Chinese and Japanese queries, a plain folded-title table with `instr`, the triggers through inserts, upserts, deletes and cascades, a 10,000-article retention delete, folding cost and examples. No simulator was run.
- Version 2, 2026-11-17, after debate round 1: the covering index `article_search_order` and the nested page query with `INDEXED BY` (decision 7), cold and 200,000-article figures and an honest device bound (A1, gap 10), cache-independent checks in criterion 7; `SearchReads` checked before and after a queued read (decision 11, criterion 5); the Traditional-Chinese example and the corrected owner note (decision 3, criterion 1, For the owner 4); the trigger failure modes, the rebuild handoff and the title trigger kept (decision 5); A7 (`trusted_schema` on iOS). Re-measured on my 50,000-article library: the version-2 plan and pages read (3,733 for "e"), and that without `INDEXED BY` the planner does not use the covering index.

## Debate record

Round 1 (critic: Claude, independent; verdict SOUND WITH FIXES; report `rd25/debate/critic-r1.md`, scripts in `critic-r1/`).

| ID | Severity | Finding | Disposition |
| --- | --- | --- | --- |
| F1 | P2 | The page query looks up every matching article before sorting, so the first search after a cold launch takes 0.5–0.9 s at 50,000 articles and 2–3.5 s at 200,000, holding the reading model's queue; the warm-only test cannot see it | Admitted. Covering index and nested page query (decision 7), with `INDEXED BY`, which the critic's script used and its report's SQL omitted — without it the planner picks the unique id index (re-measured); plan and pages-read checks in criterion 7; A1 restated with the cold launch and 200,000-article figures |
| F2 | minor | Superseded search reads still run in the shared queue | Admitted. `SearchReads`: checked before the read and before applying; tested with a held queue (criterion 5) |
| F3 | minor | For the owner 4 was wrong: RD14's conversion makes Traditional titles findable by Simplified text | Admitted. Note corrected, example added to criterion 1; the fold stays without `Hant-Hans`, for the critic's measured reasons (decision 3) |
| F4 | minor | Trigger failure modes need a rebuild handoff; the title trigger has no writer | Admitted. Handoff line added; connections and the no-function behaviour stated (decision 5); the title trigger kept for later writers |
| — | — | iOS's `trusted_schema` not measured | Recorded as A7 with its check and fallback |
