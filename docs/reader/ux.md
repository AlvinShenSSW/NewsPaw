# NewsPaw Reader — UI / UX

Status: baseline, 2026-11-11 (adjusted to the owner's devices on iOS / iPadOS 27, with in-place page translation in S5). Companion to [spec.md](spec.md); requirement numbers (N01–N13) refer to it.
Mock-ups: <https://claude.ai/artifact/GkfmtsiAT1Vz1VWDsTPqU5> (private to the owner). The mock-ups show the Simplified Chinese localisation, which is what the owner will see; this document names things in English, the development language.

This replaces the Mac settings-app design (`docs/archive/mockup/`, `docs/archive/planning/ux-redesign/`). The NewsPaw logo is kept; nothing else of that interface carries over.

## 1 Principles

1. **Reading comes first.** The article list and the reading screen get the space. Settings are reachable but never in the way.
2. **One partition at a time.** The whole app — Today, Library, Starred, search — shows either the normal or the adult partition. Nothing from the other one appears, and the current partition is always identifiable.
3. **The original is always one tap away.** Translation is a layer over the original, never a replacement that can leave the reader with nothing.
4. **Translation state is visible.** In progress, done, failed and why — shown where the text is, in plain words.
5. **Nothing happens silently.** A source that fails, a limit that is reached, a model that refuses: each says so in place and offers the next step.
6. **Native.** Standard iOS navigation, gestures, system typefaces, SF Symbols, Dynamic Type, light and dark appearance.

## 2 Structure

### Devices

The layout is checked on the owner's three devices.

| Device | Screen in points | Layout |
| --- | --- | --- |
| iPhone 18 Pro Max | 440 × 956 | iPhone structure |
| iPad mini (8th generation) | 756 × 1158 (from third-party listings) | Portrait: two columns. Landscape: three columns |
| iPad Pro 11-inch (M4) | 834 × 1210 | Portrait: two columns. Landscape: three columns |

All three run iOS / iPadOS 27 or later. The mock-ups are drawn at these sizes: the iPhone boards at 440 × 956, one iPad Pro 11-inch board in landscape (1210 × 834, three columns) and one iPad mini board in portrait (756 × 1158, two columns). Every screen is a fluid layout; nothing is designed to an exact width.

### iPhone

A tab bar with four tabs:

| Tab | Contents |
| --- | --- |
| Today (今日) | One overview card per category of the current partition |
| Library (订阅) | All Unread, then categories with their sources |
| Starred (收藏) | Starred articles of the current partition |
| Settings (设置) | Everything configurable |

Navigation inside a tab is a stack: Library → article list → reading screen → embedded browser.

iPhone uses this structure in every orientation, landscape included; the width rule below applies to iPad only.

### iPad

A three-column split view: sidebar → article list → reading screen.

- Sidebar: partition switch; Today, All Unread, Starred; categories (each expands to its sources); Add and Settings at the bottom.
- Selecting Today shows the overview cards across the remaining width, in two columns when there is room.
- The number of columns follows the window's width, not the device:
  - 1100 pt and wider — three columns (both iPads in landscape);
  - 700 to 1099 pt — two columns, article list and reading screen; the sidebar slides over from a button, and the list can be hidden to read at full width (both iPads in portrait);
  - narrower than 700 pt — the iPhone structure (Split View, small Stage Manager windows).
- The app has one window: iPad does not offer a second NewsPaw window.
- Keyboard: `J` / `K` or arrow keys for next / previous article, `S` star, `U` toggle read, `T` cycle display mode, `R` refresh, `⌘F` search.

### The partition switch

- Hidden until the adult partition is turned on in Settings.
- A capsule at the leading edge of the navigation bar on Today, Library and Starred (top of the sidebar on iPad), showing the current partition: "Normal ▾" (普通).
- Tapping it opens a menu with the two partitions. Choosing Adult (成人) triggers device authentication; on success the whole app switches.
- In the adult partition the capsule is filled, the accent colour changes from rust to plum, and a lock button sits next to the capsule. The partition is identified by the capsule's label and the lock button, not by colour alone.
- Locking — by button, or automatically when the app goes to the background — returns to the normal partition at the root of the current tab.

## 3 Screens

### S1 Today

- Large title "Today" with the date. Under it, one status line: "Updated 5 min ago" or "Updating…", and when sources failed, "3 sources failed" as a link to their status. The link shows the category list with the failing sources' categories expanded: the Library tab's root on iPhone, the sidebar on iPad.
- One card per category that has overviews on:
  - category icon and name, unread count;
  - the overview text (up to six lines, then "More");
  - up to three highlights, each a tappable row that opens its article;
  - footnote: "Written by ⟨model⟩ from N articles · 08:12";
  - the card's header opens the category's article list.
- Card states:
  - no overview yet and new articles exist → "Write overview" button;
  - writing → progress line;
  - failed → reason and "Retry";
  - no new articles → "Nothing new today";
  - no model set up → "Set up a model to get overviews", linking to Settings.
- Categories with overviews off appear as compact rows (icon, name, unread count) below the cards.
- Pull to refresh.
- First run with no sources: an empty state with "Add a source" and "Import configuration".

### S2 Library

- "All Unread" row with the total.
- Categories in the owner's order: icon, name, unread count, disclosure chevron. Expanded, a category lists its sources: site icon, name, unread count. A web-page source shows a globe and no count. A paused source is dimmed; a failing source shows a warning mark. A source being refreshed shows an activity indicator in place of its count or mark.
- "+" in the navigation bar: Add source, New category, Import.
- Edit mode: reorder and delete categories, move sources between categories. A source is moved from Source settings (its Category row), not by dragging in edit mode.
- Long press on a category: Refresh, Mark all as read, Category settings. On a source: Refresh, Source settings, Pause, Delete.
- Tapping a feed-like source or a category opens S3. Tapping a web-page source opens S5.

### S3 Article list

- Title: the category or source name. A segmented control: Unread / All.
- For a category with overviews on, today's overview sits at the top as a collapsible card (same content and states as on Today), with "Earlier overviews" for the last 7 days.
- Rows: unread dot; title — the translation when present, in two to three lines; the original title in one secondary line (optional); source name and relative time; thumbnail on the trailing side; star when starred.
- A row whose title is still being translated shows the original with a small activity mark; a failed one shows the original with a small warning mark. Tapping the mark explains the failure.
- Swipe from the trailing edge: Star. Swipe from the leading edge: toggle read. Long press: Open in browser, Share, Copy link, Mark unread.
- Toolbar: "Mark all as read" (asks first), and a menu with Refresh and Category / Source settings.
- Empty states: "All caught up" under Unread, with a switch to All; "No articles yet" plus the source's last result under All.

### S4 Reading

- Header: the translated title (large), the original title (small, secondary), then source · author · published time.
- Body laid out natively. Images fill the column width; a tap opens a full-screen viewer.
- Display mode — Translation / Original / Side by side — switches in place without losing the scroll position. In side-by-side, each translated paragraph is followed by its original in secondary colour.
- While the body is being translated, a thin progress line under the navigation bar reads "Translating 3 of 8"; paragraphs appear as they finish and untranslated paragraphs show the original until then.
- When the full text had to be fetched from the web page, a small line under the header says "Full text from the original page". When only the excerpt is available: "Only an excerpt is available" with "Open original page".
- Failure: a banner above the body states the reason with "Retry"; when the model refused, also "Retry with the backup model" if one is configured.
- Bottom bar: display mode, star, share, open original page, next article. "Aa" in the navigation bar opens text size, line spacing, typeface. The "…" menu holds Copy translation, Article info (model, time, where the body came from) and Mark unread.
- Swiping horizontally moves to the previous or next article.

### S5 Embedded browser

- Used for web-page sources, "Open original page", and links inside articles.
- Top: page title and domain, progress line. Bottom bar: back, forward, Translate, reader mode, and a "more" menu with Reload, Share, Open in Safari, Save this page as a source, Copy link, and — for a web-page source — the switch "Always translate this source".
- **Translate** is one tap and works on any page (N06). The page's text is replaced in place; layout, images and links stay as they are.
  - While it works, a slim status line under the top bar reads "Translating…" and the text on screen changes as each batch arrives. The button shows as active.
  - When done, the status line reads "Translated to Simplified Chinese" with "Show original" at its trailing end. Tapping the button again, or "Show original", restores the page's own text at once.
  - Translation stays on while the owner follows links, until it is turned off or the browser is closed.
  - Some text failed → the status line gives the reason and "Retry"; when the model refused, also "Retry with the backup model". What was translated stays translated.
  - Nothing to translate (the page is already in the reading language) → a brief message, and the button returns to inactive.
  - No model set up → "Set up a model to translate", linking to Settings.
  - A source with "Always translate this source" on opens already translating.
- Reader mode extracts the current page's main text. On success it opens S4 with the page as a temporary article that can be translated. It is not stored and has no star; "Save this page as a source" and Share are the ways to keep it. On failure it says "This page has no readable article".
- In the adult partition the browser uses its own website data.

### S6 Add source

A sheet in two steps.

1. **Address.** A text field with "Paste", then "Continue". Below: Suggested sources (normal partition only), Import OPML, Import configuration.
2. **Confirm.** What was found — kind (Feed / GitHub / Hugging Face / Web page), name (editable), and a choice when the page declares several feeds or, for a GitHub repository, between Releases, Tags and Commits; the category picker (required; shows which partition it is in; includes "New category…"); a preview of the latest three items with their times; "Save".

- No feed found: "No feed was found at this address", with "Save as a web page" and "Try another address". A page that declares feeds can also be saved as itself: the choice list ends with "This page itself".
- Already added in the current partition: says where it is filed and offers to open it. The other partition is never consulted, so this screen cannot reveal anything about it.
- Could not connect: the reason and "Try again". When the site answered but the app could not use the answer (an HTTP error, too large, too many redirects), "Save as a web page" is offered as well.

### S7 Unlocking and the cover

- Choosing Adult in the partition switch shows the system's authentication prompt. There is no custom lock screen. A failed or cancelled authentication leaves the app in the normal partition with a brief message.
- While the adult partition is on screen and the app leaves the foreground, a plain cover with the NewsPaw logo is drawn, so the app switcher shows nothing.

### S8 Settings

A grouped list:

| Row | Contents |
| --- | --- |
| Models & translation | Reading language; translate titles automatically; translate the body when an article opens; show original titles in lists; the normal partition's primary and backup model slots |
| Refresh | Interval; background refresh; retention |
| Reading | Text size, line spacing, typeface, default display mode |
| Adult partition | See S10 |
| Data | Export configuration, Import configuration, OPML import / export, cache size and Clear |
| Usage | Requests and tokens per model and purpose; the daily automatic limit |
| About | Version, licences |

### S9 Model slot

- Preset picker (OpenAI, DeepSeek, xAI, MiMo, OpenRouter, Gemini compatible, Custom), which fills in the address.
- Address; model name with "Load list" to pick from what the service returns; key (secure field; once saved shows "•••• 1a2b" with Replace and Remove).
- "Test" with one result line: Passed · Key rejected · Model not found · Quota or rate limit · Could not connect. A slot that has never been tested says "Not tested".
- The backup slot is the same form, introduced by one sentence: it is used when the primary fails for network, rate-limit or server reasons.

### S10 Adult partition (Settings)

- Before it is turned on: a short explanation and one switch. Turning it on asks for device authentication once.
- Once on, opening this screen requires authentication. Contents: the adult partition's primary and backup model slots (same form as S9); lock timing (immediately / after 1 minute / after 5 minutes); show thumbnails in lists; the daily automatic limit; Clear browsing data; Turn off the adult partition.
- Turning it off asks whether to keep its data hidden or delete it.

### S11 Export and import

- Export: one switch, "Include the adult partition", enabled only while it is unlocked; then the system share sheet. A note states that keys are never included.
- Import: pick a file → device authentication when the file includes the adult partition and it is locked (declining continues with the normal partition only) → preview sheet. The sheet shows counts, then three groups — New, Already here, Conflicts — and a choice between Merge and Replace everything. Replace shows what will be deleted and asks again. After importing: a summary, and when slots need keys, a link to Models & translation.

### S12 First run

Three steps, each skippable:

1. Reading language (preselected from the system language).
2. A model for the normal partition: preset, key, Test. A note says what is sent to the service: titles and article text.
3. Sources: Suggested sources, Paste an address, Import configuration / OPML.

It ends on Today.

### S13 Category and source settings

- Category: name, icon, overviews (automatic / manual / off), move to the other partition (with the consequences spelled out, N02), delete.
- Source: name, address (read-only; "Copy"), category, paused, translate titles (follow global / on / off), body (automatic / always fetch the page / feed content only), status with the last result, delete. A web-page source shows name, address, category, "Translate when opened" and delete; the options about titles and bodies do not apply to it.

## 4 States and wording

Wording is given in English with the Simplified Chinese string the owner will see. No internal words (probe, slot, partition id, hold) appear in the interface.

| Situation | English | 简体中文 |
| --- | --- | --- |
| No model set up | Set up a model to translate | 设置模型后即可翻译 |
| Translating titles | Translating… | 正在翻译… |
| Translating a body | Translating 3 of 8 | 正在翻译 3 / 8 段 |
| Translate a page | Translate · Show original | 翻译 · 显示原文 |
| Page being translated | Translating… | 正在翻译… |
| Page translated | Translated to Simplified Chinese | 已翻译成简体中文 |
| Part of a page failed | Some text could not be translated · ⟨reason⟩ | 部分文字没有翻译成功 · ⟨原因⟩ |
| Page needs no translation | Nothing to translate on this page | 这个页面没有需要翻译的文字 |
| Per-source page translation | Always translate this source | 总是翻译这个来源 |
| Key rejected | The service rejected the key | 服务拒绝了这个 Key |
| Quota or rate limit | The service is limiting requests. Try again later | 服务暂时限制了请求，请稍后再试 |
| Network | Could not reach the service | 连接不上模型服务 |
| Model refused | The model declined to translate this | 模型拒绝翻译这篇内容 |
| Malformed reply | The reply could not be used | 返回的内容无法使用 |
| Daily limit | Today's automatic limit is reached. Translate manually, or raise the limit in Settings | 已达到今天的自动上限，可手动翻译，或在设置里调高 |
| Source failed | Could not update · ⟨reason⟩ · last worked ⟨time⟩ | 更新失败 · ⟨原因⟩ · 上次成功 ⟨时间⟩ |
| Nothing new | Nothing new today | 今天还没有新文章 |
| All read | All caught up | 都读完了 |
| Overview footnote | Written by ⟨model⟩ from the titles and excerpts of N articles | 由 ⟨模型⟩ 根据 N 篇文章的标题与摘要生成 |
| Excerpt only | Only an excerpt is available | 只有摘要 |
| Partition names | Normal · Adult | 普通 · 成人 |

Every failure message is followed by its next step: Retry, Open Settings, or Open original page.

## 5 Visual design

The logo is black on white, so the interface is neutral ink and paper with one accent per partition.

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| Background | `#FFFFFF` | `#121211` | Lists, reading screen |
| Grouped background | `#F5F4F1` | `#121211` | Today, Settings |
| Surface | `#FFFFFF` | `#1D1D1B` | Cards, grouped rows |
| Hairline | `#E3E1DC` | `#32322F` | Separators, card borders |
| Text | `#1B1B19` | `#F1F0EC` | Titles, body |
| Secondary text | `#5E5D58` | `#A6A59E` | Original titles, metadata |
| Accent, normal | `#B4401F` | `#F0875F` | Unread dot, links, selected controls |
| Accent, adult | `#7A3E9D` | `#C99AE6` | The same roles in the adult partition |

- Text and accent colours meet 4.5:1 against their backgrounds.
- Typeface: the system typeface (SF Pro with PingFang SC; Hiragino for Japanese originals). The reading screen offers a serif option (New York with Songti SC).
- Reading text: 17 pt at the default Dynamic Type size; line height 1.7 for Chinese and Japanese, 1.5 for Latin text; paragraph spacing 0.9 em; maximum column width 680 pt.
- Icons: SF Symbols, outline style, one weight. Category icons come from a fixed set of symbols.
- Bars: the tab bar, toolbars and the browser's bottom bar are the system's standard components and take the current system look — floating, translucent bars with content running behind them. The app draws no bar background of its own. The mock-ups approximate this with a floating capsule and a tinted pill for the selected tab.
- Corner radius 12 pt for cards and 8 pt for thumbnails. Spacing on a 4 pt grid; 16 pt side margins on iPhone.
- Motion: system transitions only. Paragraphs fade in as their translation arrives; with Reduce Motion on, they appear without animation.

## 6 Accessibility

- Dynamic Type through the largest accessibility sizes: rows grow and thumbnails move below the text.
- Every icon-only button has a VoiceOver label. An article row reads as one element: unread state, title, source, time.
- Tap targets are at least 44 × 44 pt.
- Display mode, the partition switch and every swipe action are also reachable from menus, so nothing depends on a gesture.
- State is never carried by colour alone: unread has a dot and a VoiceOver state; the adult partition has its label and lock button.
- The reading language sets the VoiceOver language of translated text, and originals keep their own language, so each is spoken with the right voice.

## 7 Out of this design

Widgets, notifications, Apple Watch, a Mac layout, sharing into the app from other apps, themes beyond light and dark. Search has a place in the navigation bar from M2 on and is not drawn in the mock-ups.
