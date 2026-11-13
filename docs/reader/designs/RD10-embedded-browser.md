# RD10 — Embedded browser and web-page sources

Issue: [#131](https://github.com/AlvinShenSSW/NewsPaw/issues/131) · Epic E13 #116 · Requirements N03 (web page), N05 (links), N12 (embedded browser); ux S5 (without Translate and reader mode), section 1 ("Library → article list → reading screen → embedded browser").
Design version 2 (frozen after one debate round), 2026-11-14. Author: Claude (planner, for the driver of this AFK run). Implementer: Claude Opus 5.5. External gate: Codex `gpt-6.1-sol` at high effort.

Builds on RD03 (containers, one sheet state), RD05 (web-page sources, Add source, `NSAllowsArbitraryLoads`) and RD09 (routes for a source and an open article, the interim reading screen, the row's menu), all merged. Names of merged code below were checked against main at `4238242`; the implementer reads the code first all the same.

The owner's instruction for this phase (2026-11-12): one user, converge, no over-engineering.

## Spec review

A web-page source can be added since RD05 and still cannot be opened: its row opens its settings. An article's "Open Original Page" leaves the app for Safari. This issue gives both a browser inside the app, and it is the surface RD12 (reader mode), RD16 (translate in place) and RD19 (the adult partition's own website data) build on.

Core need: the owner taps a web-page source or an article's original page and reads that page without leaving the app; the page cannot reach the app, save a file or start another app on its own; and the owner always sees which site is shown.

**Settled here**, because the issue and the specification leave it open:

1. **What opens the browser.** A web-page source's row (Library and sidebar), at the source's address. "Open Original Page" on the reading screen and "Open in Browser" in a row's menu, at the article's link. Links inside article bodies are RD11's. There is no address field: the browser shows what the app hands it and what links lead to.
2. **Where it is shown.** In the navigation state, not as a sheet, so that Add source can open above it and a width crossing keeps it.
   - Tab structure: pushed on the stack it was opened from (ux section 1), with the tab bar hidden; the system's back button closes it.
   - Pane structure: a web-page source selected in the sidebar fills the content area as one pane, like Today and Settings, and like them carries the Show Sidebar button below 1100 pt; an article's original page takes the reading pane, with a Close button that returns to the article.
   - "Open in Browser" on a row first opens that article (which marks it read, as opening does) and then its page, so closing the browser returns to the article everywhere.
3. **One page session per stack.** The Library stack and the Starred stack each hold at most one live page session. It is kept in a model, not in a view: crossing 700 pt or 1100 pt keeps the page and its history. It ends when its route leaves the path (back, Close, another sidebar selection, its source deleted); opening the same source again starts at the source's address.
4. **The bars** (ux S5). Top: the page's title in one line — the host while there is none — with the host under it, and a progress line while a page loads. Bottom bar: Back, Forward (each disabled when there is nowhere to go), and a "More" menu: Reload, Share, Open in Safari, Save This Page as a Source, Copy Link, and — when the browser was opened from a web-page source — Source Settings, as a feed's list has it. The places of Translate and reader mode stay empty until RD16 and RD12. Bars are the system's components.
5. **What a page may do** (N12).
   - Scripts run, as in any browser. The page gets no interface to the app: no message handler, no injected script, no custom scheme of the app's.
   - A navigation of the main frame to an `http` or `https` address is followed in the same view, also when the page asks for a new window or tab (a navigation with no target frame is cancelled and its address loaded in the page).
   - `about:`, `blob:` and `data:` addresses are WebKit's own: allowed inside a frame that exists, cancelled silently when they ask for a new window. They never raise a question and are never handed to the system.
   - Any other scheme (`mailto:`, `tel:`, an app's own scheme) is not followed. When the main frame or a new-window request asks for it, the browser asks "Open this link in another app?", naming the scheme; only on "Open" is it handed to the system, and when the system has no app for it the browser says so. Inside a subframe it is cancelled silently. One question at a time: further ones are dropped while one is shown.
   - A link the owner taps in the main frame whose host differs from the shown page's is loaded by the browser itself, so that the system does not hand an `https` link to an installed app (a universal link) without asking. A tapped link to the same host, and a navigation inside a subframe, are simply allowed. "Open in Safari" is the way out.
   - A response the web view cannot show, or one marked as an attachment, or a link marked as a download, is not loaded and nothing is saved. The browser says "This link is a file. NewsPaw does not download files." and offers Open in Safari, which opens the refused link's address.
   - Page dialogs (`alert`, `confirm`, `prompt`) are not shown in this version: an alert is dismissed, a confirm answers no, a prompt answers nothing.
   - The app declares no camera, microphone, location or photo-library use, and the session denies device-sensor requests, so a page is granted none.
   - The edge swipe closes the browser (tabs); the page's own back and forward are the bar's buttons, not gestures.
   - The question and the file notice are shown only while no sheet is open; one raised under a sheet is dropped.
6. **Website data.** The normal library's browser uses the system's default persistent store, so a site remembers a login as it does in a browser. The browser model is constructed with its store — the one place RD19 changes for the adult library. Under a UI-test library directory it is given a non-persistent store, as nothing of a UI test touches the standard stores. Clearing the store is not offered in this issue.
7. **Failures.** A page that cannot be loaded (no connection, a host that does not answer, a certificate the system refuses, the web content process ending) shows, in place of the page: "Could not open this page", the system's reason in one line, "Try Again" and "Open in Safari". The bars stay. A navigation the browser itself refused (decision 5) or that a newer load replaced is not a failure and never shows this state.
8. **"Save This Page as a Source"** opens RD05's Add source sheet with the shown address filled in, through the one sheet state. What follows is RD05's: detection, the duplicate message when it is the source being viewed, and after a save the sheet closes with the browser still shown.
9. **RD09's keyboard shortcuts do not act while a browser is shown** in that stack, and a letter typed into a page's text field reaches the field.
10. **The shown address.** The address being loaded until a page commits; the failed address while the failure state is shown; otherwise the page's own address. The host in the top bar, "Try Again", "Open in Safari", Share, Copy Link and "Save This Page as a Source" all use it — not the address the browser was opened with.

## Acceptance criteria

1. **Opening a web-page source** (UI). A web-page source's row opens the browser at its address in Library (pushed) and from the sidebar (one pane); the title and host are those of the fixture page; between 700 and 1099 pt the pane carries Show Sidebar and it opens the slide-over; RD05's settings sheet no longer opens from the tap and still opens from the row's menu and from More → Source Settings.
2. **Opening an article's page** (UI). "Open Original Page" on the reading screen and "Open in Browser" in a row's menu open the article's link in the browser; after "Open in Browser" the row is read; closing returns to the article's reading screen in both structures.
3. **Back, forward, reload** (UI, fixture pages). Following a link to a second page enables Back; Back returns to the first and enables Forward; Forward returns to the second; Reload loads the shown page again (a fixture page that shows a count of its loads). The title and host follow each page; the progress line is present while a slow fixture page loads and gone after. A tapped same-page anchor does not reload the page.
4. **Same view for new windows** (UI). A fixture link with `target="_blank"` and one that calls `window.open` each show their page in the same browser, with Back returning.
5. **Other schemes ask first** (UI, and the policy table). A fixture link to a `mailto:` address and one to an unknown scheme each show the question and load nothing; Cancel leaves the page as it was; for the unknown scheme "Open" says that no app can open it. A fixture page holding an `about:blank` frame and a frame that navigates to an unknown scheme on load shows no question. That "Open" hands a `mailto:` link to Mail is on the device list.
6. **No download** (UI, the policy table and a source scan). A fixture link answered as an attachment, one answered with a type the web view cannot show, and one marked `download` each show the file notice, leave the page as it was and do not show the failure state. The policy table has no decision that allows a download or an attachment; a source scan finds no use of a download API in the app.
7. **No interface to the app** (UI and code). A fixture page that probes a fixed list of handler names reports that posting to each throws. A test of the session's configuration finds no user script, and no scheme handler outside UI-test mode. A source scan (in RD06's badge-scan form, failing when it finds no source file) finds none of `WKScriptMessageHandler`, `addScriptMessageHandler`, `addUserScript`, `.add(` on a content controller, `callJavaScript`, `evaluateJavaScript`.
8. **Failures** (UI). An address the fixture handler fails shows the failure state with its two buttons, the failed address's host in the top bar and Copy Link giving the failed address; "Try Again" loads again (a fixture that fails once, then shows its page); the bars stay usable and Back still works. Tapping a link while a slow page is still loading shows the new page, not the failure state.
9. **Save This Page as a Source** (UI). On a second page reached by a link, it opens Add source with that page's address in the field; for the source being viewed RD05's duplicate message appears after detection; after a save of another page the sheet closes and the browser is still shown.
10. **Copy Link and Open in Safari** (UI). Copy Link is checked through Add source's Paste button, as in RD09. Share and Open in Safari exist with their labels; what they do is on the device list.
11. **The session survives the crossings** (UI on iPad). With a second page shown after a link, crossing 700 pt in both directions and rotating across 1100 pt keep the same page, with Back still enabled.
12. **Layout** (UI). On the three simulators, and on iPad at a Split View width below 700 pt: the bars are present, their buttons have labels and measure at least 44 × 44 pt, the title and host are not clipped at the largest text size (they wrap or truncate with the host still shown), and the end of a long fixture page can be scrolled clear of the bottom bar.
13. **Keyboard shortcuts stay out** (UI on iPad, in the keyboard test that runs last). With the browser shown over a list, `J` opens no article, and `j` typed into a fixture page's text field arrives in the field.
14. **Structure and regression.** Strings check; every earlier UI test still passes, changed only where this issue re-points a web-page source's tap or "Open Original Page"; a refresh that ends while a browser is pushed over an article does not re-read the list under it (RD09's snapshot rule); no test reaches a real host — under the UI tests every page comes from the fixture table and any other navigation fails without a request; debug seams inside `#if DEBUG` and absent from the Release binary; `NewsPaw-Info.plist` gains no key (`NSAllowsArbitraryLoadsInWebContent` in particular, which would switch `NSAllowsArbitraryLoads` off for the feeds).
15. **Evidence.** UI tests on the three simulators. Screenshots on iPhone and iPad: the browser with a page in light, dark, Simplified Chinese and the largest text size; once per device each of the loading state, the failure state, the More menu, the other-app question and the file notice. The hand-off and download cases are listed in the pull request with their result (the issue asks for this).

## Frozen issue contract

**In.** The fifteen criteria.

**Invariants.**
- A page gets no interface to the app: no message handler, no user script, no app scheme, in any build configuration; the fixture scheme exists only under `#if DEBUG` and only under a UI-test library directory.
- No navigation is answered with a download, and the app writes nothing a page serves into its container.
- A tapped link, another scheme and a new-window request never leave the app without the owner's "Open" or the owner's own "Open in Safari".
- The host of the shown address is always visible.
- The browser model is made with a website data store handed to it; nothing in the browser chooses between stores.
- RD03's, RD05's, RD06's and RD09's invariants hold: one sheet state, and an alert is not raised under a sheet; pane roots keep their identity across the 1100 pt crossing; a list is a snapshot; palette tokens; system components.
- No dependency added or changed; no migration; no Info.plist key.
- Only symbols available in the iOS 26.0 SDK: CI compiles with Xcode 26.6, this machine has the 27.1 SDK.

**Allowed user-visible change.** The browser; a web-page source's tap; "Open Original Page" and "Open in Browser" staying inside the app.

**For the owner.** The pull request repeats this list. (1) There is no address field: the browser opens sources and article pages and follows links. (2) A link you tap never leaves the app by itself: another app's link asks first, and an `https` link that iOS would hand to an installed app stays in the browser; "Open in Safari" is the way out. A page's own script can still be handed to an installed app by iOS — there is no switch for that. (3) Files are not downloaded; a file link says so and offers Safari. (4) Pop-up dialogs from a page are not shown in this version, and a link that wants a new window opens in the same view. (5) The browser remembers website data (logins, cookies) like a browser; this issue has no "clear browsing data" for the normal library. (6) "Open in Browser" on a row opens the article first, so it is marked read. (7) On iPad a web-page source fills the whole content area; an article's page takes the reading pane, with Close. (8) Closing the browser ends its session: opening the source again starts at the source's address, not where you left. (9) A web-page source's settings are in the browser's More menu and the row's long-press menu; tapping the row now opens the page. (10) The page's own back and forward are buttons, not swipes.

**Non-goals.** Translate (RD16) and reader mode (RD12), and their buttons. The adult library's own website data and its Clear (RD19). Links inside article bodies (RD11). An address field, tabs, bookmarks, history, find on page, desktop-site switch, content blocking. Page dialogs and file uploads. Signing in to sites that use HTTP authentication. Downloads. A user-agent change. Keeping the scroll position across a width crossing. Stopping iOS from handing a script-started navigation to an installed app.

**Causal boundary.**
- `ios/NewsPaw/**` — new: a browser model (sessions, policy, the fixture seam), the browser view and its bars; changed: `NavigationModel` (a page route; a web-page source's route showing the browser; `openArticle(on:)`), the containers, `SourceRow`, the reading screen and the row menu (re-pointed), RD09's shortcut buttons.
- `ios/NewsPawKit/Sources/NewsPawKit/` — only if a pure helper belongs there (the policy function; the shown address); `Feeds/FixtureTransport.swift` is not the browser's fixture table.
- `ios/NewsPawKit/Tests/NewsPawKitTests/**`, `ios/NewsPawUITests/**`.
- `docs/reader/ux.md` — S5, one sentence each for what this design settles: where the browser is shown on iPad; that other-app links ask and file links are refused. `docs/reader/spec.md` — N12, one sentence: links the owner taps are loaded by the browser itself so that the system does not open an app.

## Approach

**The web view.** SwiftUI's `WebView` with a `WebPage` (iOS 26; the specification's reason for the minimum version). The page object is the session and lives in the browser model. Policy is a `WebPage.NavigationDeciding` value backed by a class, because it is handed to the page's initialiser before the page exists and needs the page to load a replacement; the replacement load starts in a following main-actor turn, after `.cancel` has been returned. Both policies return only `.allow` or `.cancel`. Title, address, progress, loading state and the back-forward list are read from the page; there is no `goBack`, so Back loads the last item of the back list. Page swipe gestures and link previews are switched off with the view's modifiers.

**The policy as a pure function.** One function of (scheme class, navigation type, target frame: main / sub / none, same host as the shown page, download flag) → follow · load in place · allow silently · cancel silently · ask · refuse as a file; and for responses (can show type, content disposition) → allow · refuse as a file. A unit test covers its whole table; the decider only applies it. A response carries no frame information: a refused subframe response shows the file notice like a main-frame one unless the measurement below finds a way to tell them apart.

**Failures.** The model reads the page's navigation events in a loop that subscribes again after an error. WebKit's "frame load interrupted" (102) and "cancelled" (-999) are not failures.

**Fixtures.** Under a UI-test library directory only (debug builds): a URL scheme handler serves a fixed table of pages for one fixture scheme. One mapping is applied at two points — on the way into `load` and the policy function, and on the way out of the page's address — so that the policy function and the bars see `https` in both builds. Fixture pages use relative links and no subresource from another host; a navigation to any address outside the table fails without a request. The table answers the hosts the existing transport fixtures use for a web-page source (`nofeed.example.invalid`) and for the fixture articles' links (`example.invalid/articles/…`), and holds: two linked pages; a page counting its loads; a slow page; a long page; a page with a same-page anchor; links with `target="_blank"`, `window.open`, `mailto:`, an unknown scheme, the `download` attribute; a page with an `about:blank` frame and a frame navigating to an unknown scheme; an attachment answer; an unshowable type; an address the handler fails with `URLError(.cannotFindHost)`; an address that fails once; a page with a text field; a page that probes message-handler names.

**App.** `BrowserModel` (app-level, beside the reading model, constructed with its data store): the session of each stack; the pending question and notice; the shown address. `NavigationModel`: a `.page(URL)` route. `openArticle(on:)` answers the article under a `.page` route too, so the reading pane, the shortcut targets and `ReadingModel.runEnded`'s "a list with its article pushed is not on screen" keep holding; the Starred stack's contract becomes `[.article]` or `[.article, .page]`. A `.source` route of a web-page source shows the browser: the kind is consulted in the two containers and in `SourceRow`, and entering such a route is not a list entry (`onListEntered` is not called, `LibraryRoute.list` and `SidebarItem.list` answer nil for it). RD09's hidden shortcut buttons are absent while a `.page` route is on top of their stack. Views: the browser pane with its bars, failure state, question and notice.

## Failure handling

| Failure | Behaviour |
| --- | --- |
| The page cannot be loaded | Decision 7; "Try Again" loads the failed address |
| The web content process ends | The failure state; "Try Again" loads the shown address |
| The browser refused a navigation, or a newer load replaced one | Not a failure |
| Another scheme, from the main frame or a new-window request | The question; nothing loads |
| Another scheme inside a subframe; `about:` / `blob:` / `data:` asking for a new window | Cancelled silently |
| The system cannot open that scheme | "No app on this device can open this link." |
| A file, an attachment, a download link | The file notice; nothing is saved |
| A question or notice raised while a sheet is open, or while a question is shown | Dropped |
| The source shown is deleted | The browser closes with its route, as a deleted source's list does |
| An article's link is not `http` or `https` | No "Open Original Page" and no "Open in Browser" (RD09's rule) |

## Assumptions and risks

The implementer measures each on the simulator before building on it and reports the result. If any of the first four fails, the whole browser is built on `WKWebView` in a representable with the same policy function, and the hand-back says so.

| Assumption | If it does not hold |
| --- | --- |
| `WebPage.NavigationDeciding` is asked for link taps, new-window requests (no target frame), other schemes and download links, per frame, with `target.isMainFrame` telling frames apart, and `.cancel` stops each | `WKWebView` with its navigation and UI delegates |
| Cancelling a link-activated cross-host navigation and loading its request in the page keeps history (Back returns) and stops the system from opening an app for a universal link | Report before choosing: the alternative is to allow such navigations and list universal links for the owner |
| A `WebPage` kept in the model shows the same page after its `WebView` is rebuilt by a container switch, without a trap for a page bound to two views | `WKWebView` kept in the model and re-hosted |
| `WebPage.Configuration.urlSchemeHandlers` serves the fixture scheme with headers (type, disposition), delays and failures; the decider's response for such a reply still carries `Content-Disposition`; Back, Forward and Reload work across such pages | Fixture pages through simulated loads, with the back-forward criteria checked on the pages that allow it and the rest listed |
| `.cancel` from the response policy and a superseded load are reported as errors 102 and -999, and the navigation sequence can be read again after an error | Whatever is measured is filtered instead; `WKWebView` if failures cannot be observed |
| With no presenter, `alert` is dismissed, `confirm` answers no and `prompt` answers nothing, and no dialog hangs the page | Implement `DialogPresenting` with exactly those answers |
| `<input type="file">` and a long press on an image show nothing that needs a usage description the app lacks (camera, "Save to Photos") and nothing crashes | File prompts answered with cancel; link previews off. If "Save to Photos" remains, report before choosing: `WKWebView` with a UI delegate, or one Info.plist key by the owner's decision |
| With a hardware keyboard, letters typed into a page's text field reach the field once the shortcut buttons are absent | Report: RD09's sheet-after-slide-over problem noted beside the shortcut buttons is measured again |
| XCUITest reads a fixture page's text and taps its links through `app.webViews` | Fixture pages report through their title, which the top bar shows |
| Known harness costs (RD06, RD09): context menus can cost 60 s waits; a tab switch about 2 s; `typeKey` attaches a hardware keyboard, so a keyboard test runs last | Tests are written around them |

## Test plan

- **Package or app unit tests.** The policy table (criteria 4–6 as decisions); the configuration test and the source scans (criteria 6, 7); the shown address (decision 10).
- **UI tests (three simulators, fixture pages only).** Criteria 1–5, 6 (notice), 8–14. The implementer iterates with `-only-testing` and runs the whole suite once at its final commit; the driver runs it again at the final commit of the pull request.
- **Screenshots.** Criterion 15.
- **Not verified here, for the owner's device list:** a real site over https and one over http; a universal link (for example a YouTube or Maps link with the app installed) staying in the browser when tapped; Open in Safari, also on a page whose app is installed; `mailto:` reaching Mail after "Open"; Share; a login surviving a relaunch; a page with video; VoiceOver on the bars.
- The `AGENTS.md` commands pass; one Release build, searched for the fixture scheme and the debug keys.

## Handoff notes

- RD11: links inside article bodies open here through the same `.page` route.
- RD12: reader mode's button takes its reserved place in the bottom bar; its hidden extraction view is a separate web view with scripts off and a non-persistent store, not a browser session.
- RD16: Translate takes its reserved place; its script runs in its own content world through `callJavaScript(…contentWorld:)`; the scan of criterion 7 is then narrowed to that one world and channel.
- RD19: the adult library's browser model is constructed with its own data store; "Clear browsing data".
- RD21: whether the normal library gets a "clear browsing data" row in Settings → Data.

## Revision record

- Version 1, 2026-11-14: first draft, written while RD09 was in review.
- Version 2, 2026-11-14: after one debate round (a fresh critic, read-only; code and SDK references checked, WebKit runtime claims marked unverified and moved to Assumptions). Seventeen findings, all admitted, two in a smaller form:
  - C1 (P1): the scheme rule takes the target frame; `about:` / `blob:` / `data:` never ask; subframes never ask; one question at a time; framed fixture.
  - C2 (P1): a refused or replaced navigation is not a failure; the notice's Open in Safari opens the refused address.
  - C3 (P1): the shown address is defined for loading and failed states (decision 10); Try Again loads the failed address.
  - C4: `openArticle(on:)` answers under a `.page` route; criterion 14 gains the snapshot clause.
  - C5: after a save the browser stays (the old "For the owner" item 7 was wrong about merged code).
  - C6: the invariant and item 2 say "a tapped link"; script-started hand-offs are named as not stopped; device list gains Open in Safari with the app installed.
  - C7: Show Sidebar on the one-pane browser below 1100 pt.
  - C8: criterion 7 probes by posting; configuration test asserts what the API exposes; wider scan.
  - C9: the failing fixture fails with an error instead of never answering.
  - C10, smaller: the container file check is dropped, not sharpened — the guarantee is that no decision allows a download, asserted by the policy table and a scan.
  - C11: one address mapping at two points; relative links; the fixture hosts named.
  - C12: the real controls for long-press and file prompts; the Info.plist key only by the owner's decision.
  - C13: questions and notices are dropped under a sheet.
  - C14: a web-page `.source` route is not a list entry.
  - C15: the model is constructed with its store; non-persistent under UI tests.
  - C16, smaller: Source Settings stays in More (a feed's list has it there) and is listed for the owner, with the iPad placement and the session ending on close.
  - C17: Share to the device list; criterion 12 measures scrolling clear of the bar; scroll position across a crossing is a non-goal; screenshot sets capped.
  - The critic's measurement list is merged into Assumptions; same-host tapped links are allowed rather than reloaded, which keeps same-page anchors working.
