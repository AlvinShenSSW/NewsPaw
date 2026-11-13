# RD09 — Article lists, read state and stars

Issue: [#130](https://github.com/AlvinShenSSW/NewsPaw/issues/130) · Epic E13 #116 · Requirements N05 (lists, rows, actions); ux S1 (without overview cards), S2 (counts, a source's tap), S3, Starred, section 6. Also touched: N04 (image cache), ux S8 (Data), N12 (images are untrusted), N13.
Design version 2, frozen 2026-11-13 after one debate round. Author: Claude (planner, for the driver of this AFK run). Implementer: Claude Opus 5.5. External gate: Codex `gpt-6.1-sol` at high effort.

Builds on the merged code of RD03 (containers, one sheet state), RD05 (sources, summaries, fixture transport) and RD06 (main `63c52aa`): `RefreshModel` (`refresh(_:)`, `entered()`, `lastRefreshAt`, `engine.collecting`, `onListsChanged`), `Refresher`, `library.imageCache` (`data(for:)`, `store(_:for:)`, `size()`, `clear()`), Today as a scroll view with `.refreshable` and `TodayStatusLine`, `InterimUnreadView` still in place. The implementer reads that code first.

The owner's instruction for this phase (2026-11-12): one user, converge, no over-engineering.

## Spec review

After RD06 the library fills and stays fresh, and the app still cannot show a single article: the list destinations say how many unread articles there are and that lists are not available yet. This issue replaces that sentence with the lists, lets the owner mark articles read and starred, and gives an article somewhere to open.

Core need: every stored article can be found in the list where the owner expects it, in a stable order; what is read and what is starred is true everywhere at once and survives a relaunch; and a list does not rearrange itself while the owner is reading down it.

**Settled here**, because the issue and the specification leave it open:

1. **The lists and their filter.** All Unread (the whole library, unread only, no filter control); Starred (every starred article, no filter control); a category and a source (a segmented control Unread / All, Unread by default, remembered per list until the app is closed). Today is not an article list (decision 10).
2. **Order.** Newest first by the time the row shows — the published time, else the first-seen time — then by first-seen time, then by the table's row order (`rowid`), all descending. RD04 stores a collection's items in reverse feed order for exactly this, so items that share a time list in feed order. Migration `v4` adds the one index this order needs.
3. **A list is a snapshot.** It is read in pages of 200 as the owner scrolls. A row whose state changes is updated where it stands and stays there even when it no longer matches the list — a read article stays in an unread list without its dot, an unstarred one stays in Starred without its star — until the list is read again. A list is read again:
   - when it is **entered**: its route is pushed, the sidebar selection changes to it, or its tab is selected while it is the top of that tab's stack;
   - when its filter changes;
   - when a refresh the owner started from it ends (a pull, its toolbar's Refresh, `R`);
   - when any other refresh run ends while the list's first row is on screen.

   Not an entry, and no reload: returning from the reading screen pushed on the list, a sheet or dialog closing, a width crossing (the snapshot is kept in the model, not in the view). A list scrolled away from its top is left alone when a run ends. The open article stays open across a reload even if it has left the snapshot.
4. **Read.** Opening an article marks it read at once. A swipe from the leading edge toggles read; "Mark as Unread" / "Mark as Read" is also in the row's menu and in the reading screen's bar.
5. **Starred.** A swipe from the trailing edge toggles the star; also in the row's menu and the reading screen's bar. Retention never deletes a starred article (RD06).
6. **The row's menu** (long press): Open in Browser, Share, Copy Link — the three absent when the article has no link — Mark as Read / Unread, Star / Unstar. So every swipe is also in a menu (ux section 6).
7. **"Mark All as Read"** is in the toolbar of All Unread, a category and a source, and in a category's long-press menu in Library (ux S2). It first asks, naming the number, and applies to the unread articles of the scope that were first seen up to the moment it was asked — also those not loaded in the list — so an article a refresh inserts while the dialog is open is not marked unseen. It is not offered in Starred.
8. **Counts.** Library's root and the sidebar show the unread count on each category row and on the All Unread row, as source rows already do; zero shows no number. They are read again after every read-state change and after every run, so they agree with the stored state at once. (A list is a snapshot, so a count can be ahead of the rows shown until the list is read again.)
9. **What an article opens to, before RD11.** A reading screen with the header of ux S4 (title; source · author · time), the excerpt as plain text, one sentence that the full article layout is not available in this version yet, and "Open Original Page" when the article has a link. Its bar has star, share and mark unread. RD11 replaces the body and removes the sentence. Until RD10 brings the embedded browser, "Open Original Page" and "Open in Browser" hand the link to the system (Safari).
10. **Today, until overviews exist.** The date under the title (ux S1; left to this issue by RD06), RD06's status line, then one compact row per category that has unread articles: icon, name, unread count. A row shows that category's list: it selects the category exactly as the sidebar or Library does, in both structures (on iPhone this moves to the Library tab). With no unread article anywhere: "Nothing new today".
11. **A source's tap.** A feed-like source's row opens its article list (RD05 opened its settings), in Library and in the sidebar, where it is selected like a category and closes the slide-over. Source Settings stays in the row's menu and is in the list's toolbar menu. A web-page source keeps opening its settings until RD10.
12. **The list's toolbar.** "Mark All as Read", and a menu with Refresh and Category Settings or Source Settings. Refresh and pull to refresh collect the list's scope: the category, the source, or the whole library for All Unread and Starred.
13. **Thumbnails.** A row shows the item's image when the feed gave one. The loader fetches it through the app's one transport under the collection rules, refuses an image that declares more than 40 million pixels before decoding it, decodes with the system's image decoder, reduces it to at most 288 pixels on its longer side, flattens it onto white and keeps that reduced JPEG in `library.imageCache` under a key of its own (`thumbnail:` and the address), so that a later issue caching the full image at the same address does not get the thumbnail. At most 4 image requests are in flight; a row that scrolls away cancels its request; an address that failed is not asked again until the app is closed. A row whose image is loading or unusable is laid out without one; nothing animates while it loads. At the accessibility text sizes the thumbnail sits below the text.
14. **Settings → Data** (moved here from RD06): the image cache's size, read each time the screen is shown, and Clear, for the current library's cache only.
15. **Keyboard**, with a hardware keyboard, while a list or the reading screen opened from it is shown and no sheet or "Mark All as Read" dialog is open: `J` next article, `K` previous (each opens it, so it is marked read), `S` star, `U` toggle read, `R` refresh the list. `J` with nothing open, or when the open article is no longer in the snapshot, opens the first row; at the last loaded row it loads the next page and opens its first row; `K` at the first row, and `S` / `U` with nothing open, do nothing. ↓ and ↑ do what `J` and `K` do if the system delivers them to a SwiftUI shortcut without a UIKit responder; otherwise they are left out and said so (the issue asks for "`J` / `K` or the arrow keys"). Each key calls the same model function as the matching swipe or tap. (`T` is RD15's, `⌘F` RD25's.)
16. **Empty states.** A scope that holds no article at all: "No articles yet" whatever the filter, and in a source's list the source's status sentence under it. Unread filter with articles but nothing unread: "All caught up", with "Show All" in a category or source list. Starred with none: "No starred articles". The reading pane with nothing open: "No article selected". RD03's identifiers `empty.category`, `empty.allUnread`, `empty.starred`, `empty.today` and `empty.reading` stay on the corresponding states.
17. **An article without a title** shows the first line of its excerpt, else "Untitled".
18. **Where the open article lives.** In the navigation state, so crossing 700 pt keeps the list, its filter and the open article. `LibraryRoute` gains `.source` and `.article`; the tab structure pushes the article on its list (`[list, .article]`); the Starred tab's stack gets a path of its own. There is one open article for the Library lists and one for Starred; selecting another list clears the first. `SidebarItem` gains `.source`. Code that reads "the list shown" from the path's last element reads the last list route instead.
19. **A deleted source or category closes its lists.** Deleting a source while its list is shown (Source Settings is reachable from the list's own menu) returns to the category list, as deleting a category already does; deleting a category also closes a list of one of its sources.

## Acceptance criteria

1. **Queries** (package). For each scope — all unread, starred, a category, a source — and each filter that applies: exactly the right articles, in the order of decision 2, with articles of paused sources included and nothing from another category or source; a dateless feed's items list in feed order; pages of 200 that never repeat or skip a row, tested with a run of more than 200 articles sharing one time that straddles a page boundary; the row record carries the source's name and never the stored HTML. Timing, recorded and not gated: page 1 and page 2 of every scope and `sourceSummaries()` over a library of 50,000 articles in 100 sources whose rows carry bodies of a few kilobytes.
2. **Migration `v4`** (package). A `v3` database with rows migrates and keeps them; the order index exists; `EXPLAIN QUERY PLAN` of the all-unread page query names it; `v1`–`v3` are not edited.
3. **State changes** (package). Mark read, mark unread, star, unstar: each changes only its one column of its one article, is idempotent, and throws `unknownArticle` for an article that does not exist. Mark all as read for a scope and a moment touches exactly that scope's unread articles first seen up to that moment and returns their number; one first seen later stays unread. Each survives closing and reopening the library.
4. **Snapshot behaviour** (UI; a row's unread state is read from its accessibility label). In a category's unread list, opening an article and going back shows the row still there, read; leaving the list and entering it again shows it gone; the filter chosen for a list is still chosen after visiting another list and returning; the same list under All shows the read article.
5. **Everything agrees at once** (UI). After marking an article read from a source's list, that source's count, its category's count, the All Unread count and Today's row for the category are each one lower without any further action; after a relaunch they and the row's state are the same. For a star: Starred is visited first (empty), the article is starred elsewhere, and on returning to Starred it is there; still there after a relaunch.
6. **Swipes and menu** (UI; at most two context-menu presentations). Leading swipe toggles read; trailing swipe toggles the star; the long-press menu holds decision 6's actions, without the three link actions for the fixture article with no link. Copy Link is checked through the app: after it, Add source's Paste button fills the address field with the article's link.
7. **Mark all as read** (UI; package for the rows not loaded). The dialog names the number; Cancel changes nothing; confirming leaves no unread row in the list and the scope's counts at zero; from a category's long-press menu in Library it does the same. "More than 200" is covered by criterion 3.
8. **The reading screen, interim** (UI). Opening shows the header, the excerpt, the sentence and "Open Original Page"; the article is read; the bar's star and "Mark as Unread" act on it and the list row follows. The article with no link shows no "Open Original Page". That the link is handed to Safari is on the device list.
9. **Today** (UI). The date line exists; rows for exactly the categories with unread articles, with their counts; a tap shows that category's list; "Nothing new today" when none; the status line stays above the rows.
10. **Navigation** (UI). A feed-like source's row opens its list, titled with its name; a web-page source's row still opens its settings. On iPad the list is in the list pane and the open article in the reading pane; crossing 700 pt in both directions keeps the list, the filter and the open article. Deleting the source from its list's Source Settings returns to the category list.
11. **Refresh from a list** (UI, fixtures). In the list of the long counting source: a pull adds a row at the top; the toolbar menu's Refresh does the same. A run the list did not start is made with Source Settings → Update Now opened from the list's toolbar menu: with the list at its top the new row is there when the sheet closes; with the list scrolled down, scrolling back to the top shows no new row until the list is pulled.
12. **Thumbnails** (package and UI). The loader: a valid image is reduced to at most 288 pixels and cached under the thumbnail key, and a second request is answered from the cache with no transport request; something that is not an image, an image declaring more than 40 million pixels, and a failed fetch each yield nothing and cache nothing; a transparent image comes out on white; never more than 4 requests in flight, also after many requests were cancelled while waiting; a cancelled request stores nothing. UI: after the fixture article with an image has been on screen, Settings → Data shows a size above zero (the test re-enters the screen until it does, within the usual timeout); at the largest text size the row with an image is taller than the same list's row without one by at least the thumbnail's height, and at the default size it is not. That the image shows and that a row without one has no gap are shown by named screenshots.
13. **Image cache total** (package). `ImageCache` keeps a running total instead of listing its directory on every store (measured in the debate: one store into 20,000 files took about 100 ms); the total is taken from a listing at first use and again whenever an eviction is needed. Tests: storing over an existing key counts the difference; eviction still removes the least recently used; Clear leaves zero; files removed behind its back are noticed at the next eviction. RD06's cache tests pass unchanged.
14. **Settings → Data** (UI). Covered with criterion 12: a size above zero, then Clear makes it zero and disables itself.
15. **Accessibility.** A row is one VoiceOver element whose label holds the unread state, title, source and time, plus "Starred" when starred (UI test, asserted by its parts, not by equality, because the time is relative); category and All Unread rows have their count as value; new icon-only controls have labels and measure at least 44 × 44 pt. That the swipe actions are offered as the element's actions is on the device list.
16. **Keyboard** (UI on an iPad simulator, by `typeKey`). Each key of decision 15 does what it says; with a sheet open none does anything. See Assumptions for the fallback.
17. **Empty states.** Each of decision 16, in English and Simplified Chinese; "Show All" switches the filter.
18. **The interim state is gone.** The catalog key `%lld unread articles — article lists are not available in this version yet.`, `AccessibilityID.interimUnread`, `InterimUnreadView` and its uses no longer exist; a catalog key this issue leaves unused (such as `No articles in this category`, if it is) is removed.
19. **Structure and regression.** Strings check; every RD03, RD05 and RD06 UI test still passes, changed only where this issue re-points a tap, replaces the interim sentence or an empty-state string, or adds a count to a row's value. `openSourceSettings` for a feed source goes row → list → the toolbar menu's Source Settings (not the row's context menu). No test reaches a real host; debug seams inside `#if DEBUG` and absent from the Release binary.
20. **Evidence.** Package tests; UI tests on the three simulators; screenshots of a list (unread with a thumbnail row and a row without, all, empty), Today with rows, Starred and Settings → Data, on iPhone and iPad — one set each in light, dark, Simplified Chinese and the largest text size — and the interim reading screen once per device.

## Frozen issue contract

**In.** The twenty criteria.

**Invariants.**
- A read or star change writes one column of one article and nothing else; mark all as read writes `read_at` of the scope's unread articles and nothing else; no list query selects `content_html`.
- Every function added to `Library` works on that library alone; the thumbnail loader is handed one library's cache and never chooses between caches.
- Image bytes are untrusted: they are decoded only by the system's image decoder into a bitmap, reduced, and re-encoded before they are stored; no fetched byte is written to disk as received; nothing is fetched for a row except the one image address the feed gave, through the app's transport.
- Titles, excerpts and source names from feeds are shown as plain text.
- List reads and state changes of the reading model run one at a time in the order they were started, so a read begun before a change cannot land after it; a source-summary read that finishes after a newer one is dropped.
- RD03's, RD05's and RD06's invariants hold: one sheet state; storage only through `Library`'s public API; palette tokens; system components; pane roots keep their identity across the 1100 pt crossing; panes ignore the keyboard safe area.
- One migration, `v4`, that only creates the order index; no dependency added or changed.

**Allowed user-visible change.** The list destinations with rows, filter, swipes, menus and toolbars; the interim reading screen; Today's date and category rows; counts on category and All Unread rows; a source's tap; Settings → Data; keyboard shortcuts.

**For the owner.** The pull request repeats this list. (1) All Unread and Starred have no Unread / All control: the first is unread by definition, the second shows everything starred — N05 lists the filter for every list. (2) A list does not rearrange itself while it is being read: a read article keeps its place until the list is entered again. New articles from a refresh you did not start from the list (for instance the one made when the app is opened) appear by themselves only if the list is at its top; scrolled down, they wait for a pull or the next visit, while the counts already include them. (3) Opening an article shows its excerpt with "Open Original Page" until RD11 lays out the body; the link opens in Safari until RD10 brings the embedded browser. (4) Today lists only the categories that have unread articles (the issue says "the categories"), and on iPhone a row there moves to the Library tab's list for that category. (5) "Mark All as Read" is not offered in Starred, and it marks what existed when you asked: articles that arrive while the question is open stay unread. (6) Thumbnails are stored reduced (at most 288 pixels, on white), not as the original image. (7) The database gains one index (migration `v4`) so that lists stay fast with tens of thousands of articles.

**Non-goals.** The reading screen's body, display modes, text settings, previous and next by swipe (RD11, RD15). The embedded browser (RD10). Translated titles and their marks (RD14). Overview cards and Today's two-column layout (RD23). Search (RD25). Hiding the list pane to read at full width (RD11). The adult partition's thumbnail setting (RD18). Images inside article bodies (RD11). Remembering a list's scroll position across a reload or a relaunch. Restoring the open list after a relaunch. Showing zero-unread categories on Today. A further index for the summary query.

**Causal boundary.**
- `ios/NewsPawKit/Sources/NewsPawKit/` — new: `Model/ArticleRow.swift` (the public row record), `Store/Library+Articles.swift` (queries, state changes), `Images/ThumbnailLoader.swift`. Changed: `Store/Schema.swift` (`v4`), `Store/LibraryError.swift` (`unknownArticle`), `Cache/ImageCache.swift` (the running total), `Feeds/FixtureTransport.swift` (fixtures below), `Model/SourceSummary.swift` (a stale comment).
- `ios/NewsPawKit/Tests/NewsPawKitTests/**`.
- `ios/NewsPaw/**` and `ios/NewsPawUITests/**`.
- `docs/reader/ux.md` — one sentence each where this design settles what ux.md leaves open: S3 (which lists have the filter; a list is a snapshot), S1 (which categories Today lists and what a row opens). `docs/reader/spec.md` — N05, one sentence: the filter applies to category and source lists.

## Approach

**Package.** `ArticleRow`: identifier, source identifier and name, title, excerpt, author, link, image address, the shown time, read, starred. `Library+Articles`: `articleRows(_ scope:, filter:, after cursor:, limit:)` by keyset on (shown time, first-seen time, `rowid`); `article(_ id:)` for the reading screen; `setRead(_:_:)`, `setStarred(_:_:)`, `unreadCount(in:firstSeenThrough:)`, `markAllRead(in:firstSeenThrough:)`. `v4`: `CREATE INDEX article_order ON article(COALESCE(published_at, first_seen_at), first_seen_at)`, walked backwards. `ThumbnailLoader` is an actor made with a transport and an image cache: cache first, else fetch, check the declared size, reduce with ImageIO's thumbnail function, flatten, re-encode as JPEG, store, return the data; a gate of 4 in which a freed slot goes to the first waiter and a cancelled waiter leaves the queue.

**Fixtures** (debug-only `FixtureTransport`). An "articles" feed whose items include one without a link and one naming an image; the image's answer (a small PNG built in code); a "long counting" feed of 40 fixed items plus one new item per request, long enough to scroll.

**App.** An `ArticleListModel` per shown list (scope, filter, loaded rows, cursor, whether the first row is on screen), owned by an app-level `ReadingModel` that also holds the per-list filters, the one loader and the serial queue of the invariant. Row view, list view, interim reading view, Today's date and rows, counts on category and All Unread rows, Settings → Data. `NavigationModel` gains the routes of decision 18. `RefreshModel` tells the reading model when a run ends. `SourceModel.reload` carries a token so that an older read does not replace a newer one.

## Failure handling

| Failure | Behaviour |
| --- | --- |
| A list page cannot be read | The rows already shown stay; a "Could not load" row with "Try Again" ends the list |
| A read or star change cannot be saved | The row returns to its stored state and the existing "could not be saved" alert is shown |
| The article no longer exists (`unknownArticle`: its source was deleted, or clean-up ran) | No alert. Its row leaves the list; if it was being opened or is open, the reading screen says the article is no longer available |
| An image cannot be fetched, decoded or stored | The row has no thumbnail; nothing is shown about it |
| An article has no link | The link actions and "Open Original Page" are absent |
| "Mark All as Read" fails | Nothing changes (one transaction); the alert is shown |
| The shown list's source or category is deleted | Decision 19 |

## Assumptions and risks

The implementer measures each before building on it and reports the result.

| Assumption | If it does not hold |
| --- | --- |
| `typeKey` delivers an unmodified letter key to a SwiftUI keyboard shortcut on an iPad simulator | Criterion 16 is verified by a UI test of the same model functions through their taps and swipes, and the keys go to the device list; say so in the hand-back |
| ↓ / ↑ reach a SwiftUI shortcut without taking over the system's own scrolling | The arrows are left out (decision 15) |
| A leading swipe on a row of a pushed list on iPhone does not start the system's back swipe | The row's swipe starts inside the row's content; if still unreliable, report before changing the interaction |
| `.refreshable` works on a list showing only an empty state | The empty state is placed inside the scrollable list |
| ImageIO decodes and reduces in the package tests on macOS as on iOS | The loader's image tests run in the iOS 26.5 simulator package suite only |
| The system Paste button fills Add source's field without a prompt (RD05 measured it) | Copy Link is asserted only as present; the pasteboard goes to the device list |
| Known harness costs (RD06): a pull keeps the harness busy until the refresh returns; a context menu can cost 60 s waits; a tab switch about 2 s | Tests avoid reading transient states during them and cap context menus as the criteria say |

## Test plan

- **Package.** Criteria 1–3, 7 (rows not loaded), 12 (the loader, with a fake transport and images made in the test), 13.
- **UI tests (three simulators, fixtures only).** Criteria 4–12, 14–19.
- **Screenshots.** Criterion 20.
- **Not verified here, for the owner's device list:** the shortcuts on a real hardware keyboard; VoiceOver reading a row and offering its actions; scrolling a long list by hand; thumbnails from real feeds; "Open Original Page" and "Open in Browser" reaching Safari; Share.
- The `AGENTS.md` commands pass; one Release build, searched for the debug keys.

## Handoff notes

For later issues, recorded now:
- RD10: re-points "Open Original Page", "Open in Browser" and a web-page source's tap to the embedded browser.
- RD11: replaces the interim reading body and its sentence; adds hiding the list pane; previous and next; images in bodies through the same cache under the plain address (thumbnails use their own key).
- RD14: the translated title, the original-title line and the translation marks in the row.
- RD18: the adult library's lists get their own models; the "show thumbnails in lists" setting gates the loader.
- RD23: Today's cards above the compact rows.
- RD25: search; a text field in a pane keeps itself visible (RD03's note).

## Revision record

- Version 1, 2026-11-13: first draft, written while RD06 was in implementation; checked against RD06's merged code (63c52aa) the same day.
- Version 2, 2026-11-13: after debate round 1 (critic's findings C1–C24, each verified by the driver against the code or accepted on its reasoning).
  - C1 (P1) admitted: the tie-break was a random identifier; now `rowid`, with a feed-order test.
  - C2 (P1) admitted: a one-element row hides the dot and the thumbnail from a UI test; criteria 4 and 12 now say what is read (label, Settings → Data, row heights, screenshots).
  - C3 (P1) admitted: "entered" defined in decision 3; criterion 5 visits Starred before starring.
  - C4 admitted: counts on category and All Unread rows are new work (decision 8, criterion 15).
  - C5 admitted: `v4` order index decided now (measured: category page 90–121 ms without it, 3–13 ms with it, at 50,000 articles); timing recorded for every scope, not gated.
  - C6 admitted: fixtures named; "more than 200" stays in the package test; the foreign run is Update Now.
  - C7 admitted: `LibraryError.unknownArticle`; boundary lists `Schema.swift`, `LibraryError.swift`, `SourceSummary.swift`.
  - C8 admitted: routes and one open article per stack decided (decision 18); a deleted source closes its list (decision 19).
  - C9 admitted: Copy Link checked through the Paste button.
  - C10 admitted: key semantics decided; assumptions and fallbacks listed.
  - C11 admitted: mark all as read takes a moment (decision 7).
  - C12 admitted: one serial queue for a model's reads and changes.
  - C13 admitted: pixel bound, thumbnail key, running total unconditionally (criterion 13), cancelled waiters, white ground, static placeholder; the size-limit clause dropped from the loader test.
  - C14 admitted: `openSourceSettings`' new path named; RD03's identifiers kept; unused keys removed.
  - C15 admitted: an unknown article raises no alert and its row leaves the list.
  - C16 rejected: reloading a list at its top when a foreign run ends is kept, because without it the refresh made on opening the app never shows in the list the owner is looking at; its verification was made concrete (criterion 11) and it is item 2 for the owner.
  - C17 admitted: Today's date delivered; unread-only categories listed for the owner.
  - C18–C24 admitted: accessibility actions to the device list; labels asserted by parts; a tie run across a page boundary; this Assumptions section; a scope with no article says "No articles yet"; the interim reading screen has one screenshot per device and context menus are capped; wording of the invariant and of Refresh's scope.
