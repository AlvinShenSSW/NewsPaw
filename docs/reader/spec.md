# NewsPaw Reader — Product Specification (iPhone / iPad)

Status: **baseline, 2026-11-11.** The owner approved it as the basis for the new backlog ([backlog.md](backlog.md)). RD01 created the iOS project in `ios/`; no reader feature has been built yet. Kimi K3.1 Pro design review: see section 12.
This file replaces `docs/archive/planning/requirements.md` (the Mac + Telegram baseline, now archived). Screens and interaction are in [ux.md](ux.md); open-source research and library choices are in [open-source.md](open-source.md).

## 0 Source

The owner's instructions on 2026-11-11, in their words:

- 「看了一圈都很糟糕，没有合适的。我还是想自己做一下，但是计划有变。我想做一个 ipad/ios 端的阅读应用，我可以按照分类订阅不同的 rss 的新闻，或者其他格式的。我可以把他们分类。分类还是有普通和成人，需要翻译这些都不变。然后不需要 telegram，也不需要 mac 端应用了。暂时也不需要做云端同步，就是每个设备一个配置即可。未来通过导入配置文件实现不同设备间的同步。重构整个 NewsPaw App 的 Spec，以及 UI/UX，先不要开始编码」
- 「然后如果 github 有开源的项目可以在基础上改的也可以借鉴」
- 「然后这个项目我想未来能按照一个独立商家 apple store 的小产品的方向来开发，架构设计的时候注意一下」
- 「成人相关的只有我自己的 testflight 的版本有」「上架版会通用化」「可以作为远期的 epic，不在你这次的 spec 的主要范围内，这次还是先做一个只给我一个人用的 testflight 的版本」
- 「然后整个项目用英文开发、用英文写文档，和 issue 和 epic，只有和我沟通需求的时候用中文」
- 「然后网页也需要有一键翻译的功能，让我决定的按你的判断来，设备是 iphone 18 pro max，ipad mini 8，ipad pro 11 M4」
- 「都是 iOS 27 以上，确认合并 113，2 按你的建议 4 按你的判断，UI/UX 根据新的调整，然后重新拆 Epic 和 issues，旧的 epic 和 issues 关掉」

In short: an iPhone / iPad reading app; subscriptions organised into categories; a normal and an adult partition; translation as before, including one-tap translation of web pages; no Telegram, no Mac app, no cloud sync; devices are aligned by importing a configuration file; open-source projects may be borrowed from; this specification covers a TestFlight build for the owner alone; an App Store edition is a distant epic that the architecture should only leave room for; the project is written in English; the decisions that were left open are delegated (section 11).

Four points the owner confirmed the same day:

| Question | The owner's choice |
| --- | --- |
| How news is read | An article stream, plus a daily overview |
| Sources beyond RSS | Feeds; GitHub / Hugging Face; and an embedded browser for bookmarked pages that update (examples given: AV研究所, a studio's release-list page) |
| When translation happens | Titles automatically; the body when an article is opened |
| Installation | The owner has a paid Apple Developer account and installs through TestFlight |

## 1 Product

A news reader for iPhone and iPad that runs entirely on the device. The owner subscribes to feeds and web pages, files them into categories, and each category belongs to either the normal or the adult partition. Titles and article bodies are translated with the owner's own model keys, and each category gets a short daily overview written by a model. There is no server, no account and no cloud sync; subscriptions move between devices by exporting and importing a configuration file.

This specification covers one build: **a TestFlight build used by the owner only.** The adult partition exists in this build. An App Store edition is out of scope (section 8).

### Non-goals

- Telegram, scheduled pushes, sending messages of any kind.
- The macOS menu-bar app, the Python backend, the local control socket.
- Servers, accounts, cloud sync, sharing between people.
- X accounts; per-site web scrapers (CNN sitemap, Zaobao, structured AV研究所 items); OpenAI web search.
- AI newspaper images, speech (ElevenLabs / `say`), voice and image questions.
- Event clustering, source-conflict notes, per-item evidence citation checks (the old editorial pipeline).
- The budget ledger's reserve / settle / outcome-unknown bookkeeping (N11 describes what replaces it).
- Anything needed only for an App Store release (section 8).

## 2 Terms

| Term | Meaning |
| --- | --- |
| Partition | `normal` or `adult`. The interface is in exactly one partition at any moment. |
| Category | A folder the owner creates. It belongs to one partition. |
| Source | Belongs to one category. Kinds: feed (RSS / Atom / JSON Feed), GitHub repository, Hugging Face account, web page (a bookmarked page). |
| Article | One item collected from a feed-like source. Web-page sources produce no articles. |
| Translation | An article's title, excerpt and body in one reading language, with the model and time that produced it. |
| Overview | A model-written summary of one category for one day, with a few highlights that point at articles. |
| Model slot | The primary or backup model of one partition: service address, model name, key. |
| Configuration file | An exported JSON file holding categories, sources, settings and model slots (without keys). |

## 3 Requirements

Requirements are numbered N01–N13. Later issues freeze their scope against these numbers.

### N01 Platform and runtime

- One universal app for iPhone and iPad, written in SwiftUI. iPhone is designed portrait-first and also works in landscape. iPad supports every orientation, Split View and the narrow widths of Stage Manager.
- The owner's devices: iPhone 18 Pro Max, iPad mini (8th generation), iPad Pro 11-inch (M4), all on iOS / iPadOS 27 or later. Layout is checked at these three sizes (ux.md, section 2).
- Minimum system version: iOS / iPadOS 26. It is the first version with SwiftUI's own web view and with a translation session that needs no visible view (the M3 candidate in open-source.md), and nothing in this specification needs 27. Real-device verification happens on 27 only (section 10).
- Everything happens on the device. The app itself makes four kinds of network request: source addresses, article web pages, images, and the model services the owner configured. It contains no analytics, crash reporting or third-party SDK. A page open in the embedded browser is ordinary web browsing: it loads whatever that page loads, third-party scripts and trackers included, and the app does not filter it.
- The app works without a model key: the owner can subscribe, refresh and read originals. Places that would show a translation or an overview say that no model is set up and link to the setting.
- Interface language: English is the development language and Simplified Chinese ships as a localisation. Every string goes through the string catalog.

### N02 Partitions and categories

- Two partitions: normal and adult. The adult partition is off by default and its entry point appears only after it is turned on in Settings (N09).
- The owner creates categories: name, partition, order, and an icon chosen from a fixed set. First launch offers a set of suggested normal categories (World, Japan, Australia, China, Tech, AI), all optional. The adult partition has no preset categories or sources.
- A source belongs to exactly one category, and an address can be added only once within a partition. Two addresses are the same when their normal forms are equal: white space trimmed, `https://` put in front when no scheme is typed, scheme and host in lower case, a default port and the fragment removed, an empty path written `/`; nothing else is rewritten (http and https, `www.`, a trailing slash and the query stay as typed). The two partitions are never checked against each other: a check across them would let the add-source screen reveal what the locked adult partition holds. The same address may therefore exist in both partitions, each collected and translated on its own; that is the owner's choice.
- A category can be renamed, reordered and deleted. Deleting asks whether its sources move to another category in the same partition or are deleted with it.
- A category can be moved to the other partition after confirmation. Only the category and its sources move. Its articles, translations and overviews in the old partition are deleted, then collected again in the new partition and translated by that partition's model. Read and starred states are lost, and the confirmation says so. A source whose address already exists in the destination partition is not moved, and the confirmation lists it. Moving a category needs the adult partition unlocked. Moving a source between categories of the same partition changes nothing else.
- The interface only ever shows the current partition: categories, unread counts, articles, overviews, starred items and search results all come from it.

### N03 Sources

| Kind | Input | Collection | Produces articles |
| --- | --- | --- | --- |
| Feed | A feed address, or a site address (feeds declared in the page are discovered) | RSS 2.0 / RSS 1.0 / Atom / JSON Feed | Yes |
| GitHub repository | The repository address | One of the repository's Atom feeds — Releases (default), Tags or Commits — chosen while adding, in the picker also used when a page declares several feeds. The source stores the chosen feed address. No token | Yes |
| Hugging Face account | An organisation or user address | The Hub's public API, listing that account's models by creation time | Yes |
| Web page | Any address | Not collected. Opened in the embedded browser | No |

- Adding a source: paste an address → the kind is detected (when a page declares several feeds, the owner picks) → choose a category (required; the category decides the partition) → preview the latest few items (for a web page, its title) → save. When no feed is found there are two ways out: save it as a web page, or try another address. Discovery reads only `<link rel="alternate">` declarations of RSS, Atom, RDF and JSON Feed types (`application/feed+json`); a JSON feed declared only as `application/json` is added by pasting its own address.
- Web-page sources have a name, an address and a category. They open in the embedded browser with back, forward, reload, translate, open in Safari, share, and "save this page as a new source". Translate replaces the page's text in place with one tap (N06). The browser also offers a reader mode: it extracts the main text of the current page and, when that succeeds, opens the same reading and translation screen that articles use (N05, N06). Such a page is a temporary article: it is not stored, cannot be starred, and its translation lasts only while it is open. To keep a page the owner saves it as a source or shares its link.
- OPML import: folders in the file become categories in the current partition. Feeds outside any folder go to one category the owner picks in the preview, an existing one or a new one. Addresses that already exist in that partition are skipped and listed. An OPML file is untrusted input (N10).
- Suggested sources: a short built-in list of public feeds for the normal partition, taken from the entries already verified in `docs/archive/source-strategy.md`, offered only while adding. It contains no adult sources and nothing from the owner's private lists.
- Per-source options: paused; translate titles automatically (follows the global setting by default); how the body is obtained (automatic / always fetch the page / feed content only). A web-page source has one option of its own: translate when opened (off by default).
- Source status is visible: working, the last failure and its reason (could not connect, address gone, not a recognisable feed, too large), paused, time of the last success, time of the newest item. Repeated failures never delete or pause a source automatically.
- GitHub and Hugging Face content (READMEs, model cards, release notes) is text to read. Nothing in it is executed or followed.

### N04 Refresh and storage

- Foreground: on entering the app, refresh when the last refresh is older than the chosen interval (15 / 30 / 60 minutes / manual only; default 30). Pull to refresh at any time. A single category or source can be refreshed on its own.
- Background: the app registers for background refresh. The system decides when it runs and gives no guarantee. Background work collects and translates titles only, and sends no notification. (Milestone M2.)
- Collection rules: a cap on simultaneous requests; a 20-second limit on each collection's whole exchange, redirects included (parsing comes after it and is not counted); a 10 MB response limit, counted on the decoded body; at most 5 redirects, http / https only; conditional requests (ETag / Last-Modified); one failing source does not affect the others.
- What counts as new: the identifier the feed provides; without one, the link; without that, a hash of title and date. Within a category, two items with the same link keep only the first.
- Time: the published time from the feed. When it is missing, unparseable or later than the moment of collection, the time the item was first seen is used and never changes afterwards.
- Retention: articles are kept 30 days by default (7 / 30 / 90 days / forever), counted from the time an article was first seen, not from its published time. Starred articles are never cleaned up. A cleaned-up item keeps its identifier, so it does not come back as new while it is still in the feed. The identifier's last-seen time is refreshed by every collection in which the feed still lists the item, and the identifier is deleted once the feed has not listed it for 30 days.
- Storage: one SQLite database file per partition, with the same structure, inside the app container. The image cache is also separate per partition, each with a size limit (500 MB by default; least recently used images go first). Databases are part of the device backup. The configuration file is the only way to carry subscriptions to another device.
- Unread counts are shown only inside the app. The app sets no icon badge: a badge would reveal adult-partition activity on the Home Screen, and the two partitions' counts must not be added together.

### N05 Lists and reading

- Lists: Today, All Unread, Starred, a category, a source. Newest first. Filter: unread / all.
- A row shows: the title (the translation when there is one; the original title as secondary text, switchable in Settings), source name, relative time, thumbnail when available, unread mark, star, and translation state (in progress, or a small mark on failure).
- Actions: opening marks an article read. Swipes toggle read / unread and star. A long press opens a menu (open in browser, share, copy link, mark unread). "Mark all as read" asks first.
- Where the body comes from, tried in order:
  1. the full text in the feed, when its plain text has at least 1,000 characters, or at least 400 when it is mostly Chinese, Japanese or Korean;
  2. the article's web page, fetched by the app under the collection rules of N04 and reduced to its main text statically — the page's own scripts do not run and nothing further is loaded for it (N12). Automatic when the feed has only an excerpt; can be turned off per source;
  3. when both fail, the excerpt plus "Open original page".
- The body is laid out natively: headings, paragraphs, images, lists, quotes, code blocks, links. The reading screen runs no script from an article. Links open in the embedded browser.
- Display modes: translation / original / side by side (paragraph by paragraph, translation above original). Text size, line spacing and typeface (sans / serif) are adjustable. Appearance follows the system light / dark setting. On iPad the text column has a maximum width.
- Also: previous / next article; star; share the original link; open the original page in the embedded browser; copy the translation.
- Search (M2): titles, original and translated, within the current partition.

### N06 Translation

- The reading language is a global setting: Simplified Chinese (default) / English / Japanese. After a change, existing translations are kept but no longer shown, and articles are translated again in the new language as needed.
- Language detection happens on the device. An original already in the reading language is not translated. When the reading language is Simplified Chinese and the original is Traditional Chinese, the system's script conversion is used and no model is called.
- Titles and excerpts: translated automatically after a refresh brings new articles, in batches of at most 20. Each refresh translates the newest 50 items per category; older untranslated items are translated when they scroll onto the screen. Automatic translation can be turned off globally or per source.
- Body: translation starts when an article is opened (Settings can change this to a manual "Translate" button). The body is sent in paragraph chunks and each chunk appears as it finishes. Leaving the screen stops the work; finished chunks are kept and the rest continues on the next visit. Translations are cached on the device, so rereading calls no model.
- The model receives an array of plain-text paragraphs and must return an array of the same length. The app displays what comes back as plain text only, never as HTML or Markdown. Names of people, brands and works may stay in the original script.
- A translation is accepted when four things hold: the count matches, no entry is empty, the reply was not cut off, and each entry's length is plausible. An entry is implausible when it is longer than six times its original plus 40 characters, or when the original has more than 40 characters and the entry is shorter than a tenth of it. A failure is retried once automatically, then recorded as failed. **The old output-language character check is gone** — it used to reject whole summaries that kept a name in its original script.
- On failure the original stays readable, with the reason and a "Retry" action: no model set up, key rejected, quota or rate limit, network problem, the model refused, malformed reply, today's automatic limit reached.
- Primary and backup: on a network error, a rate limit or a server error from the primary model, the backup model of the same partition is used automatically when one is configured. When the primary model refuses to translate, nothing switches automatically; the screen says the model refused and the owner may choose "Retry with the backup model". The other partition's models are never used.
- Each translation records the model and the time, visible from the article's info.

**Web pages in the embedded browser.** The rules above apply; these are added.

- Any page in the embedded browser can be translated in place with one tap: the text the page displays is replaced by its translation in the reading language, and the page keeps its layout, images and working links. "Show original" puts the page's own text back at once, without reloading. This is separate from reader mode: reader mode suits one long article; in-place translation suits lists and pages that reader mode cannot parse.
- Once on, translation stays on for the pages the owner navigates to in that browser session, until it is turned off or the browser is closed. A web-page source with "translate when opened" starts its sessions with translation on.
- What is sent: the text the page displays, as plain text, to the current partition's model slots — same primary and backup behaviour, same acceptance checks, one automatic retry. Not sent: the page address, cookies, anything typed into a form, hidden text, scripts, styles. A page the owner is signed in to may display personal details as text, and those are sent like any other visible text. That is why translation starts only on the owner's tap or the owner's per-source choice, never by itself.
- Order and amount: text in and near the visible area is translated first; the rest follows as the owner scrolls, so the cost follows what is actually read. Text the page adds later (more results, an opened tab) is translated while translation is on. A request carries at most 40 entries or 4,000 characters.
- Not translated: text already in the reading language (Traditional Chinese is converted on the device, as for articles), text with no letters (numbers, dates, prices), text inside images or video, and frames the system web view does not let the app's script enter.
- The unit is a run of text between the page's elements. Runs that belong to one block are sent next to each other in one request, so the model sees the sentence around them. The app changes text only: it never adds, removes or re-creates the page's elements, and writes each translation as plain text.
- A translated run is cached on the device by original text and reading language, in the partition's database, when it is the whole text of its block — a title, a label, a list entry — so a page opened every day only costs its new text. A run that is only part of a longer block is not cached: its meaning depends on its neighbours, and it is translated with them each time. Entries unused for the retention period are cleaned up.
- The browser shows the state: translating with progress; translated; some text could not be translated, with the reason and "Retry" (and "Retry with the backup model" when the model refused); nothing to translate; no model set up.

### N07 Daily overview

- At most one automatically generated overview per category, per local day and per reading language. Each category's overviews are set to automatic, manual or off.
- Input: the titles and excerpts of the category's new articles since its previous overview in the current reading language, or, when there is none in that language, the articles first seen in the last 24 hours — the newest 40 at most, numbered in the request. Output: a summary of at most 600 characters and up to 5 highlights, each naming one of those numbers.
- Acceptance: the summary is non-empty and within the limit; each highlight names a number that was in that request. A highlight that names anything else is dropped. A bad summary is retried once, then recorded as failed.
- Trigger: for a category set to automatic, after the first refresh of the day that brings it new articles; for automatic and manual categories alike, when the owner taps "Write overview" / "Rewrite". With no new articles nothing is generated and the screen says there is nothing new today.
- Shown at the top of the category's article list and, on Today, as one card per category of the current partition. Under it: "Written by ⟨model⟩ from the titles and excerpts of N articles · time". Tapping a highlight opens its article.
- An overview rests on titles and excerpts only and is not verification. That sentence is always present in the overview's info.
- The last 7 days of overviews are kept and can be browsed.
- After the reading language changes, overviews in the old language are kept but not shown. Nothing is rewritten automatically for a day that already has one; the card offers "Write overview", which produces that day's overview in the new language.

### N08 Models and keys

- Each partition has a primary model slot and an optional backup slot — four slots in all. A slot holds: a service preset (OpenAI, DeepSeek, xAI, MiMo, OpenRouter, Gemini's compatible endpoint, custom), the service address, the model name, the key. A preset only fills in the address. The model name can be typed or picked from the list the service returns.
- The first version implements the OpenAI-compatible chat interface only. Other protocols can be added later behind the same internal interface (section 6).
- Keys live only in the device keychain (this device only, not synced through iCloud Keychain). They never appear in the configuration file, logs, diagnostics or error text. The interface shows only the last characters.
- "Test" sends one very short request to verify address, model and key. Results: passed, key rejected, model not found, quota or rate limit, could not connect. Saving does not test automatically.
- A service address must be https. Debug builds also accept http to the device's own loopback address, for local testing; TestFlight builds do not. A key is sent only to the address configured in its slot. Model requests do not follow redirects.
- Partition isolation: text from the normal partition goes only to normal slots, text from the adult partition only to adult slots. A partition with no model has no translation and no overview; it does not borrow the other partition's model. Entering the same service and key in both partitions is allowed — that is the owner's choice.

### N09 Protecting the adult partition

- Off by default. Turning it on in Settings › Adult partition makes the partition switch appear.
- Entering the adult partition requires device authentication (Face ID / Touch ID / device passcode).
- Locking again: when the app goes to the background (default; alternatively after 1 or 5 minutes), or manually. Locking returns to the normal partition.
- While locked, nothing from the adult partition is shown: category names, unread counts, articles, overviews, starred items, search results. Background refresh may still collect adult sources and translate titles — the data stays in the device's database and the text goes only to the adult slots.
- While the adult partition is on screen, a cover is drawn the moment the app leaves the foreground, so the system's app switcher shows no content.
- Adult-partition content never enters notifications, widgets, Spotlight or Handoff. Sharing is started by the owner and is not restricted.
- The embedded browser in the adult partition uses its own website data (cookies and cache separate from the normal partition), with a "Clear adult-partition browsing data" action.
- Images in the adult partition display normally. List thumbnails can be turned off in Settings.

### N10 Exporting and importing configuration

- Export produces a JSON configuration file (section 5), handed to the system share sheet to save in Files or AirDrop to another device. Contents: the global settings and each included partition's settings (section 4 says which settings are which), categories, sources, and the non-secret part of the model slots. The owner chooses whether to include the adult partition; that choice is available only while it is unlocked.
- Not exported: keys, articles, read and starred states, translations, overviews, usage records, and the device settings of section 4.
- Import previews first — how many categories and sources, and which are new, already present or in conflict — then offers "Merge" or "Replace everything". Merge works inside each partition. A category in the file matches an existing category of the same name; when several share the name, the first in the owner's order is used; an unmatched category is created. A source is matched by address. A source already on the device is left exactly as it is — name, category and options unchanged — and is listed as already here, or as a conflict when the file files it differently or gives it different options. Merge fills empty model slots and leaves existing slots alone. Merge deletes nothing. Replace applies only to the partitions the file contains: a file without the adult partition leaves every adult category, source and article untouched, and replacing the adult partition is possible only while it is unlocked. Within an included partition, Replace deletes the categories and sources that are not in the file, with their articles, translations and overviews. Sources that are in both keep their articles, reading state and translations and take the file's name, category and options. The file's settings replace the device's. A model slot takes the file's address and model; its stored key is kept only when the address is unchanged and is removed otherwise, so a key is never left attached to a new address. Usage records are kept. Before anything changes, Replace lists every one of these effects — what is deleted, with counts, and which keys are removed — and asks a second time.
- When the file contains the adult partition and it is off or locked on this device, the app asks to turn it on and authenticate before it builds the preview. Until that succeeds the adult library is not read and nothing in the file is compared with it. If the owner declines, the preview and the import cover the normal partition only, and the app says the adult part of the file was skipped.
- After an import, a model slot with no stored key — a new slot, or one whose key Replace removed — shows "Key needed"; slots that kept their key stay configured. Importing never calls a model.
- Versions: the file carries `schema_version`. A higher version than the app supports is refused with a prompt to update the app; a lower one is upgraded before the preview. An imported file is untrusted data: its structure and field lengths are validated, source addresses must be http or https, and model service addresses must satisfy N08. A file is at most 5 MB with at most 500 categories and 5,000 sources, and these limits are checked before any preview is built. A file that breaks a rule is refused as a whole, with the reason, and changes nothing.
- OPML can be imported, and exported per partition. An OPML file is untrusted in the same way: at most 5 MB and 2,000 feeds, external entities are never resolved, folders nested inside folders are flattened into their top folder, and addresses must be http or https.

### N11 Usage and limits

- Every model request is recorded: model, purpose (titles / body / page / overview / test), input and output token counts as returned by the service (blank when not returned), time, outcome. Records live in the database of the partition they belong to.
- Settings › Usage shows request and token counts per model and purpose for today / 7 days / 30 days. Nothing is converted to money; when a price is unknown no bill is invented.
- Each partition has a daily limit on automatic calls (200 requests by default). Once reached, titles are no longer translated automatically and overviews are no longer generated automatically that day, and the interface says why. Translations and overviews the owner starts by hand are not limited. Opening an article and translating a web page count as started by the owner, including for a source set to translate when opened.
- The old reserve / settle / outcome-unknown bookkeeping is not carried over. When a reply is lost on the network the service may already have charged for the request, and a retry may be charged again. The app accepts that risk and bounds it: one piece of work gets at most one automatic retry and one attempt on the backup model. Every attempt is recorded as its own request with its outcome, so the repeats are visible in Usage.

### N12 Security and untrusted content

- Feeds, web pages, READMEs, model cards, OPML files and configuration files are untrusted data. The model has no tools: it cannot change subscriptions or settings or make requests, and its output is only ever shown as text.
- Prompts tell the model that the content to translate is material, and that instructions inside it are not to be followed. Both partitions use the same neutral translation and overview prompts; the only difference is which slot the text is sent to.
- The reading screen runs no script from articles. Main-text extraction is static: the app loads the HTML it fetched into a hidden web view with page JavaScript disabled, subresource loading off and a non-persistent data store, refuses every navigation after that initial load (a redirect written into the page's markup included), and runs only the bundled Readability script there. Pages that build their text with scripts therefore fail extraction and fall back to the excerpt.
- The embedded browser is an ordinary system web view. Pages get no interface to the app. The script that reads and replaces text for in-place translation (N06) runs in its own script world, which page scripts cannot call; it is active only while translation is on; and what it reads is untrusted text like any article. The separation covers the app's script and its channel to the app, not the page's content: page scripts can see the translated text once it is in the page. Files are not downloaded automatically, and the app asks before handing off to another app.
- http is allowed for feeds and web pages, because some sources have no https. Model service addresses must be https (N08 states the one exception, in debug builds).
- Collection requests carry no credentials. Redirects to private-network addresses are not specially blocked. Feed discovery requests the feeds a page declares, at most five, under the same rules as collection (http or https only, no credentials, the same limits). The owner enters the addresses and requests carry no credentials, but the risk is real and accepted: a response from such an address is handled like any other — parsed as a feed, as a page for feed discovery or main-text extraction, or as an API reply — and titles and excerpts taken from it can go to the partition's model through automatic translation. This is a deliberate change from the old system.

### N13 Delivery and testing

- The project lives in `ios/`. Core logic — parsing, collection, storage, the orchestration of translation and overviews, configuration import and export — is in a Swift package that runs `swift test` on a Mac. The interface is in the app target.
- Offline tests make no external request: network, model, clock, device authentication and keychain are injected through replaceable interfaces. Tests that call a real model are enabled separately.
- Test material is synthetic feeds and pages. The owner's private sources, keys and raw media stay out of the repository.
- CI: GitHub Actions on a macOS runner runs the package tests and builds the app for the iOS simulator. The exact commands go into `AGENTS.md` once the project exists; until then no non-existent check is described as passing.
- Things only a real device can verify are kept as a separate list, each marked done or not done: authentication and locking, background refresh, TestFlight install and upgrade, a configuration file sent by AirDrop and imported on a second device.
- Distribution: TestFlight internal testing, on the owner's devices.

## 4 Data model

Each partition has its own database file (`normal.sqlite`, `adult.sqlite`) with an identical structure; every table below exists once in each file. Settings come in three kinds. Global settings — reading language, refresh interval, background refresh on or off, retention, the two automatic-translation switches, original titles shown in lists — are stored in the system preferences store and exported. Partition settings — the daily automatic limit, list thumbnails — are stored in that partition's database (`setting`) and exported with the partition. Device settings — text size, line spacing, typeface, default display mode, the image-cache size limit, whether the adult partition is on and when it locks — are stored in the system preferences store and never exported. The cache size shown in Settings and its Clear action apply to the current partition's image cache only.

Primary keys are UUID strings. Times are UTC. Configuration entities carry `updated_at`, unused for now, which leaves room for sync later.

| Table | Main fields |
| --- | --- |
| `category` | id, name, sort_order, icon, overview (`auto` / `manual` / `off`), updated_at |
| `source` | id, category_id, kind (`feed` / `github` / `huggingface` / `webpage`), url, name, site_url, paused, auto_translate (inherit / on / off), body_mode, translate_page (web pages only), etag, last_modified, last_success_at, last_error, updated_at |
| `article` | id, source_id, external_id, url, title, excerpt, author, image_url, published_at, first_seen_at, language, read_at, starred_at, content_html (the feed's own content, else its description, kept as text and read only when the article is opened) |
| `article_body` | article_id, origin (`feed` / `extracted`), blocks (JSON: paragraphs, headings, images …), fetched_at |
| `translation` | article_id, locale, title, excerpt, body_blocks (JSON, may be partial), state, error, model, updated_at |
| `page_text` | text_hash, locale, translated, model, updated_at, last_used_at (cache for in-place page translation) |
| `overview` | id, category_id, day, locale, text, highlights (JSON: article id + one sentence), article_count, model, state, created_at |
| `seen` | source_id, external_id_hash, last_seen_at (identifiers of cleaned-up items) |
| `usage` | id, model, purpose, input_tokens, output_tokens, outcome, at |
| `model_slot` | role (`primary` / `backup`), preset, base_url, model, key_ref, updated_at |
| `setting` | key, value (partition settings) |

No table has a partition column; the file a row lives in decides its partition. Separate files are a convention, not a guarantee the database enforces: the protection is that ordinary code is handed one library with one connection (section 6). Three operations touch both libraries, and each requires the adult partition to be unlocked before the adult library is read or written: moving a category between partitions, exporting a configuration that includes the adult partition, and importing or replacing one that includes it. Address uniqueness is checked inside one library only.

## 5 Configuration file

Extension `.newspaw`; UTF-8 JSON.

```json
{
  "schema_version": 1,
  "exported_at": "2026-11-11T09:30:00Z",
  "app_version": "1.0.0",
  "includes_adult": false,
  "settings": {
    "reading_locale": "zh-Hans",
    "refresh_minutes": 30,
    "auto_translate_titles": true,
    "translate_body_on_open": true,
    "retention_days": 30,
    "background_refresh": true,
    "show_original_titles": false
  },
  "categories": [
    { "id": "…", "name": "Japan", "partition": "normal", "sort_order": 1, "icon": "globe", "overview": "auto" }
  ],
  "sources": [
    { "id": "…", "category_id": "…", "kind": "feed", "name": "NHK", "url": "https://…", "paused": false, "auto_translate": "inherit", "body_mode": "auto" },
    { "id": "…", "category_id": "…", "kind": "webpage", "name": "Release list", "url": "https://…", "paused": false, "translate_page": true }
  ],
  "partition_settings": [
    { "partition": "normal", "daily_auto_limit": 200, "list_thumbnails": true }
  ],
  "model_slots": [
    { "partition": "normal", "role": "primary", "preset": "openai", "base_url": "https://api.openai.com/v1", "model": "…" }
  ]
}
```

No keys and no reading state.

## 6 Technical approach

SwiftUI plus one local Swift package, with few dependencies. The libraries and the reasons for them are in [open-source.md](open-source.md): GRDB for SQLite, SwiftSoup for HTML, Mozilla's Readability script for main-text extraction, and a small model client of our own. Feeds are parsed by the package itself, on the system's streaming XML parser and JSON decoder: FeedKit, chosen first, failed a whole feed over one bad value and took time growing with the square of the document's size (RD04).

```
ios/
  NewsPaw.xcodeproj
  NewsPaw/                 App target: interface, navigation, lifecycle, background task registration
  NewsPawKit/              Swift package (runs `swift test` on a Mac)
    Sources/NewsPawKit/
      Model/               value types, configuration file structure
      Store/               SQLite and migrations
      Feeds/               collection, parsing, feed discovery, GitHub / Hugging Face
      Reading/             main-text extraction → paragraph blocks; the page script for in-place translation
      AI/                  model interface, OpenAI-compatible implementation, translation (articles and pages) and overview, usage
      Config/              configuration import and export, OPML
      Privacy/             partition gate, keychain
    Tests/NewsPawKitTests/
```

Interfaces exist only where a test needs a stand-in: network transport, model, clock, device authentication, keychain. Everything else is a concrete implementation. There is no generic source plug-in system and no service registry.

Partition isolation rests on two points, both inside the package and unit-testable:

1. **Reading.** The interface holds one object, the library of the current partition, which maps to one database file. While locked, the interface layer cannot obtain the adult library. Background collection has its own channel that writes and never serves data to the interface.
2. **Sending.** Model slots are stored in their partition's library, and the translation and overview orchestration can only use the slots of the library an article lives in. There is no default slot; a library with no slot answers "no model set up".

### 6.1 Room left for an App Store edition

The owner wants the project to be able to grow into a small App Store product later. That edition is a distant epic (section 8) and is not built now. The architecture keeps to five habits that cost almost nothing today and avoid rework then:

1. **Licences.** Dependencies are MIT / BSD / Apache 2.0 only. No code is copied from GPL / AGPL projects.
2. **Nothing personal is hard-coded.** The repository and the app bundle contain none of the owner's source lists, keys or account names. The adult partition ships empty.
3. **The adult partition is one switch.** Every entry point to it — the Settings section, the partition switch, the second database — sits behind a single feature switch, which is on in this build. A store edition can turn it off or reshape it without touching the rest.
4. **Strings are localised from the start.** English is the base language and Simplified Chinese is a localisation, so further languages are only translation work.
5. **Narrow internal interfaces.** The orchestration depends on one model interface ("send an array of texts, receive an array of texts, with usage"), so other protocols or the system's on-device translation can be added without changing callers. Entities use stable UUIDs with modification times and the configuration file is versioned, so a later sync has something to work with.

## 7 Milestones

Every milestone must work on a real device. A module existing, or a mock-up demonstrating a state, does not count as done.

**M1 — A usable reader.** N01, N02, N03 (feeds, GitHub, web pages, OPML, suggested sources), N04 (foreground refresh and retention), N05 (without search), N06, N08, N09, N10, N11, N12, N13.
Acceptance: on a fresh install, enter a normal-partition key and pass the test → add or import a few feeds → the list shows translated titles → open an article whose feed has only an excerpt, read the extracted full text and get its translation → open a web-page source, translate the page with one tap, follow a link and find the next page translated too, then show the original → turn on the adult partition, add one feed and one web-page source, lock, and find no trace of them in the normal partition → export the configuration and import it on a second device to get the same categories and sources (keys entered again).

**M2 — Overviews and background.** N07 daily overview, N04 background refresh, N05 search, N03 Hugging Face sources.
Acceptance: with a model set up and new articles collected in two categories set to automatic, the day's first refresh writes one overview for each and their highlights open their articles; a category with nothing new says so and makes no request. A background task that the system actually delivers, or one triggered from Xcode, collects new articles and translates their titles without the app being opened; how often the system delivers one on the owner's devices is recorded as observed and is not a pass criterion. Search finds an article by its original and by its translated title. A Hugging Face account can be added and lists its newest models.

**M3 — Candidates, not committed.** A "changed since you last looked" mark on web-page sources; a glossary that fixes the translation of chosen names; the system's on-device translation as a way to translate without a key (see open-source.md); system text-to-speech; native Anthropic / Gemini protocols; iCloud sync. Each needs the owner's decision.

## 8 Future epic: App Store edition (out of scope)

Recorded so the direction is not lost. None of this is designed or scheduled.

- **Generalise or remove the adult partition.** App Review guideline 1.1.4 excludes overtly sexual or pornographic material, and 1.2 says apps that end up being used primarily for pornographic content do not belong on the App Store. The store edition would not ship the adult partition as such; whether it becomes a neutral locked space or disappears is a decision for that epic.
- **Disclosure and consent before article text goes to a model service** (guideline 5.1.2(i): sharing with third-party AI must be clearly disclosed and permitted), a privacy policy page (5.1.1(i)), and a privacy manifest.
- **Age rating.** An embedded browser counts as unrestricted web access, which places an app at 16+ in Apple's current questionnaire.
- **Reaching people without a model key.** Bring-your-own-key limits the audience; the system's on-device translation is one candidate answer.
- **Purchases**, further interface languages, store assets, and checking that the name "NewsPaw" is available.

## 9 Relation to the old system

| Old (Mac + Telegram, 0.6.x) | New |
| --- | --- |
| Normal / adult partitions, no fallback across them | Kept, and enforced at two points: reading and sending |
| Primary / backup model per partition, keys in the keychain | Kept; protocol narrowed to OpenAI-compatible |
| Global output language | Kept, renamed reading language |
| Source content and READMEs are untrusted; the model has no tools | Kept |
| Configuration export without credentials, import previews first | Kept, and now the only way to move between devices |
| Digests (scheduled, selected, frozen, delivered) | Removed; replaced by an article stream and a daily overview |
| Evidence citations, number checks, output-language character check | Removed; translations get structural checks only and the original is always readable |
| Budget ledger, outcome-unknown bookkeeping | Removed; replaced by usage records and a daily automatic limit |
| Telegram bots, pairing, commands, `/listen` | Removed |
| X, web adapters, web search, AI newspaper, ElevenLabs, voice input | Removed |
| Sources and categories many-to-many | A source belongs to one category |
| Three interface languages | English base plus Simplified Chinese |
| Python backend + Swift menu-bar app | Removed; one iOS / iPadOS app |
| Documentation and issues in Chinese | English from here on; the old documents are archived untranslated |

Handling of the repository (settled on 2026-11-11; section 11, items 1 and 2):

- Done: PR #113 is merged (`2f9c868`) and that state is tagged `mac-v0.6.4-final`. Done in RD01, the issue that created the iOS project: `src/`, `tests/`, `macos/`, `packaging/`, `pyproject.toml` and `uv.lock` were removed from `main`. History and the tag keep them retrievable. Doing this in the milestone that creates the iOS project avoids two unrelated codebases living side by side.
- Done in RD01: the old specifications and the other documents of the old system were moved, unchanged, to `docs/archive/` (among them `docs/archive/designs/specs/`, `docs/archive/planning/` and `docs/archive/mockup/`; see `docs/archive/README.md`).
- `AGENTS.md` lines to rewrite: product scope points at this directory; "keep the five-page design", "single-user system: one Mac, several Telegram bots" and the Python baseline commands are replaced by their equivalents for the new product; the project-language rule (English artefacts, Chinese only when talking with the owner) is added. The review process (Codex leads, Kimi K3.1 Pro as the external gate), the AFK rules, and keeping keys and private data on the device stay as they are. `AGENTS.md` has not been changed in this draft; it changes together with the approval of this specification.
- Close the E01–E10 epics and their child issues on GitHub as superseded. A new backlog, in English, is cut from N01–N13 and the milestones after approval.

## 10 Assumptions and things not verified

- All three of the owner's devices run iOS / iPadOS 27 or later, so nothing will be verified on a device running 26, the stated minimum; 26 is covered by the simulator at most. The iPad mini's screen size in ux.md comes from third-party listings, not from Apple's specification page.
- In-place page translation has not been tried on the pages the owner follows. Pages that draw their text into images, or that keep rebuilding their content, will translate poorly or not at all. Translating run by run can read less smoothly than a translated article, and a longer translation can overflow a page's fixed-size boxes; the app does not restyle pages.
- TestFlight internal testing needs no beta review, and builds expire after 90 days: Apple's general rules, not verified on this project's account.
- GitHub's Atom feeds need no token and are leniently rate-limited: not verified. The old connector used GitHub's REST API, not Atom.
- Hugging Face's public API can list an account's models by creation time: not verified. The old connector sorted by last modification.
- All four of the owner's current model services accept the OpenAI-compatible chat interface and can be asked for JSON output: not verified. The old system called them through the Responses interface, which is no evidence for the chat interface. Each preset is checked against its real service (RD13) before it is called supported.
- None of the four libraries has been built for this project; open-source.md records that nothing was cloned or built. RD01 builds all four for iOS 26 and runs one representative call of each.
- The package's own feed parser (RD04) has been tested on synthetic feeds only; it has not met real feeds yet. RD05's preview is the first place it does. The eleven suggested feeds were each fetched, parsed and previewed once through the app in the iOS 27 simulator on 2026-11-12 (RD05); a later change at a source can still break one.
- Known limit (RD04, accepted by the owner on 2026-11-12): a feed document built on purpose can still make the system XML or JSON parser stall for seconds to minutes, or crash the app; the guards close the shapes that were found, not the class. Ordinary feeds are unaffected. To be revisited before any wider distribution (section 8).
- Static extraction (N12) relies on the system web view still running the app's own script when page JavaScript is disabled and subresource loading is off, and on the app being able to refuse every later navigation. That is taken from Apple's documentation and has not been tried.
- How often main-text extraction succeeds on the sites the owner actually follows, adult-partition sites in particular, is unknown. On failure the app falls back to the excerpt and the original page.
- Whether a model refuses adult-partition content depends on the service the owner chooses. The app only reports the refusal.
- The real frequency of background refresh is decided by the system and may be far lower than the chosen interval.

## 11 Decisions

The owner delegated the open decisions on 2026-11-11 (「让我决定的按你的判断来」). They are settled as follows.

1. **PR #113** (Mac version 0.6.4; approved by Kimi K3.1 Pro at `f1bec85`, CI green): merged on 2026-11-11 with the owner's confirmation (`2f9c868`) as the final state of the Mac version, tagged `mac-v0.6.4-final`.
2. **Old code and documents:** removed from `main` and archived as section 9 describes, in the same change that creates the iOS project. Nothing is removed before then.
3. **Devices and minimum version:** iPhone 18 Pro Max, iPad mini (8th generation), iPad Pro 11-inch (M4), all on iOS / iPadOS 27 or later; minimum iOS / iPadOS 26 (N01).
4. **Open source:** a new SwiftUI app on permissively licensed libraries, no fork ([open-source.md](open-source.md)).

The owner then asked for the backlog to be cut from this specification and the old epics and issues to be closed. The backlog is in [backlog.md](backlog.md). Creating it authorises no development: each issue is started only when the owner hands it over.

## 12 Design review

Reviewer: Kimi K3.1 Pro (`kimi-code/k3.1-pro`), an independent model, in design mode on this file with ux.md and open-source.md as companions. The author of the documents is Claude. The review was read-only by request, not by construction.

**Round 1 (2026-11-11): RETHINK, 19 findings.** Each was checked against the text and, for DR-14, against the old code. All were accepted and corrected in this revision; none changed the scope.

| ID | Severity | Finding | Correction |
| --- | --- | --- | --- |
| DR-01 | P1 | A whole-app duplicate check would let the add-source screen reveal a locked adult source | Uniqueness is per partition; the partitions are never checked against each other (N02, section 4, ux S6) |
| DR-02 | P1 | "Replace everything" could delete the adult partition through a file that does not contain it | Replace applies only to the partitions in the file; replacing adult needs it unlocked (N10) |
| DR-03 | P1 | Import validation allowed an http model address | Model addresses must satisfy N08 on import; https rule stated in N08 with its one debug-build exception |
| DR-04 | P2 | Merge matching per partition contradicted whole-app uniqueness | Resolved by DR-01 |
| DR-05 | P2 | A starred reader-mode page had nowhere to be stored | Temporary articles are not stored and cannot be starred (N03, ux S5) |
| DR-06 | P2 | Overview mode and per-partition limits had no storage or export | `category.overview`, the `setting` table, `partition_settings` in the file; three kinds of setting defined (sections 4 and 5) |
| DR-07 | P2 | A retry after a lost reply may be charged twice | Stated as an accepted, bounded risk; every attempt is recorded (N11) |
| DR-08 | P2 | The hidden extraction web view had no execution policy | Extraction is static: page JavaScript off, no subresources, non-persistent store (N05, N12) |
| DR-09 | P2 | Highlights were only checked for pointing at an existing article | Input articles are numbered; a highlight must name one of those numbers (N07) |
| DR-10 | P2 | Overviews after a reading-language change were undefined | One per category, day and language; old-language overviews hidden; manual rewrite (N07) |
| DR-11 | P2 | M2 acceptance contradicted the no-new-articles case and depended on system scheduling | Acceptance rewritten with prepared input; scheduling frequency is observed, not a criterion (section 7) |
| DR-12 | P2 | Retention clock, "long enough" and "absurd length" were undefined | First-seen time; 1,000 / 400 characters; explicit length bounds (N04, N05, N06) |
| DR-13 | P2 | GitHub's Tags / Commits choice had no place in the data or the interface | The choice is the feed picker; the source stores the chosen Atom address (N03, ux S6) |
| DR-14 | P2 | The old system does not show chat-interface support, nor Hugging Face sorting by creation time | Section 10 corrected; both stay unverified until checked against the real services |
| DR-15 | P2 | OPML had no untrusted-input limits | Size, count, entity and address rules (N10, N12) |
| DR-16 | P2 | The private-network risk was justified by a wrong claim about parsing | Rationale rewritten to name every parser and the model path (N12) |
| DR-17 | P2 | "Four kinds of request" ignored what web pages load in the browser | App-made requests distinguished from page-made ones (N01) |
| DR-18 | P2 | "No single query can read both" overstated what separate files give | Reworded: one library, one connection; two named operations touch both (section 4) |
| DR-19 | P2 | Section 10 did not list the unbuilt libraries | Added; RD01 builds all four and runs a representative call of each |

**Round 2 (2026-11-11): SOUND WITH CONCERNS.** DR-01 to DR-17 and DR-19 closed. DR-18 was reopened as P2 and nine new P2 findings were raised; no P1. All were accepted and corrected in this revision.

| ID | Severity | Finding | Correction |
| --- | --- | --- | --- |
| DR-18 | P2 | Export with the adult partition also reads both libraries but was not in the list | Three operations listed, each gated on unlock (section 4) |
| DR-20 | P2 | The import preview could compare against the locked adult library before authentication | Authentication comes before the preview; declined means no comparison at all (N10, ux S11) |
| DR-21 | P2 | Merge conflicts and what Replace deletes per entity were undefined | Deterministic matching; per-entity keep / delete rules; a key is removed when its slot's address changes (N10) |
| DR-22 | P2 | Three exposed settings were in no category | Classified; cache size and Clear apply to the current partition (section 4) |
| DR-23 | P2 | Configuration files had no size or count limits | 5 MB, 500 categories, 5,000 sources, checked before the preview (N10) |
| DR-24 | P2 | Static extraction did not forbid navigation | Every navigation after the initial load is refused (N12) |
| DR-25 | P2 | OPML feeds outside a folder had no category | The owner picks one category for them in the preview (N03) |
| DR-26 | P2 | Identifiers of cleaned-up items had no lifecycle | Refreshed while the feed lists the item; deleted after 30 days absent (N04) |
| DR-27 | P2 | The first overview in a language had no starting point | Articles first seen in the last 24 hours (N07) |
| DR-28 | P2 | The page-translation cache ignored context | Only whole-block runs are cached (N06) |

**Round 3 (2026-11-11): SOUND WITH CONCERNS.** All ten round-2 findings closed by name. One new P2, no P1.

| ID | Severity | Finding | Correction |
| --- | --- | --- | --- |
| DR-29 | P2 | "After an import, model slots show Key needed" contradicted the round-2 rule that some slots keep their key | Only slots without a stored key show it (N10) |

The last verdict covers revision `f83e672`. The one-sentence correction for DR-29 was made after it and has not been reviewed again; RD20 carries the same rule and is reviewed when it is implemented.
