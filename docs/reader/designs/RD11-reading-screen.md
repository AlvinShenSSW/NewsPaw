# RD11 — Reading screen: native layout of the feed's body, reading settings

Issue: [#132](https://github.com/AlvinShenSSW/NewsPaw/issues/132) · Epic E13 #116 · Requirements N05 (body source 1 and 3, layout, display, also); N12 (no script from an article runs); ux S4 (without translation), S8 (Reading), section 2 (the list can be hidden), section 5 (reading text), section 6.
Design version 2, 2026-11-15, frozen after one debate round (see the last section). Author: Claude (driver of this AFK run). Implementer: Claude Fable 5. External gate: Codex `gpt-6.1-sol` at high effort.

Builds on the merged code of RD04 (`article.content_html`, the transport and its rules, `HTMLText`), RD05 (`FeedDiscovery.TagScanner`), RD09 (lists, `ReadingModel`, the interim `ReadingView`, the image cache and the thumbnail loader, the `J` / `K` keys) and RD10 (PR #159, the embedded browser and `NavigationModel.openPage`), which is on main before this issue starts. Names below are the ones read at `feat/rd10-embedded-browser` af72ce0. No dependency changes.

The owner's instruction for this phase (2026-11-12): one user, converge, no over-engineering.

## Spec review

Opening an article today shows its title, a byline, the excerpt as plain text and a sentence that the layout is not there yet. The feed's own HTML is stored (`content_html`) and unused. This issue turns that HTML into a list of blocks, lays the blocks out natively, and gives the reading screen its controls: reading settings, previous and next, star, share, the original page.

What the specification fixes: the body is laid out natively — headings, paragraphs, images, lists, quotes, code blocks, links — and the reading screen runs no script from an article; links open in the embedded browser; the feed's text counts as full text at 1,000 characters of plain text, or 400 when it is mostly Chinese, Japanese or Korean, and below that the screen shows the excerpt with "Only an excerpt is available" and "Open original page"; text size, line spacing and typeface (sans / serif) are adjustable from "Aa" and from Settings › Reading, and are device settings in the preferences store (section 4); appearance follows the system; the column is at most 680 pt wide; line height 1.7 for Chinese and Japanese and 1.5 for Latin text, paragraph spacing 0.9 em, 17 pt at the default text size (ux section 5); images fill the column and open a full-screen viewer; previous and next by swipe and button.

**Settled here**, because the issue and the specification leave it open:

1. **The converter is a linear scan of the tags, not a parsed tree.** `ArticleBlocks.make(html:baseURL:)` (package, `Reading/`) reads the HTML once from start to end with the tag scanner the package already has (`FeedDiscovery.TagScanner`: quote-aware attributes, comments, raw-text elements, a cap on a tag's length; moved to a place both can use) and `HTMLText`'s entity decoder, and emits flat blocks as it goes. It builds no document tree and does not use SwiftSoup. The issue names SwiftSoup; measured during the debate, SwiftSoup 2.14.3's tree builder takes seconds, or hundreds of megabytes, for bodies of 16 to 240 KB that nest only 24 to 42 levels deep (it re-creates every open formatting element inside each new block and scans its stack of open elements per tag), and no count of tags made beforehand can tell those bodies from ordinary ones. RD05 already rules that SwiftSoup is given one tag, never a document; RD04 left this exposure to this design. A scan is linear in the input, and flat blocks need no tree: a block's start ends the block before it, and inline styles end with their block.

2. **Blocks.** A block is one of five kinds — paragraph, heading (its HTML level 1 to 6, as read), image, code, rule — and any block can carry: a quote depth (0 to 3), a list position (depth 0 to 3 and, on an item's first block, its marker: a bullet or a number), and "caption" (text of a `figcaption`). Paragraphs and headings hold inline text: runs with bold, italic, code and an optional link; a single `br` is a line break inside a run. Rules of the scan:
   - A block starts at `p`, `div`, `section`, `article`, `header`, `footer`, `main`, `aside`, `figure`, `figcaption`, `h1`–`h6`, `li`, `dt`, `dd`, `summary`, `details`, `blockquote`, `ul`, `ol`, `pre`, `hr`, `table`, `tr`, `img`, at their end tags, and at two or more `br` in a row. Text outside any of them is a paragraph too.
   - A block with no text and no image is not emitted (`<p>&nbsp;</p>`, an empty `div`).
   - `ul` and `ol` open a list context, `blockquote` a quote context; they nest, and what stands inside them — a second paragraph of an item, a `pre`, an image, a heading — carries the context's depth. `ol`'s `start` is read and kept between 1 and 9,999. The stack of contexts is capped at 32; deeper ones are counted, so that their end tags do not close a real one, and add no depth.
   - `pre` is a code block wherever it stands, its text as written with white space kept; tags inside it are dropped, their text kept.
   - An image inside a paragraph splits the paragraph. An image inside a link keeps the image; the link is dropped (a tap opens the viewer).
   - A table row is one paragraph, its cells joined by " · ", as long as its cells hold only inline content. From the first block element inside a cell on, that table is only a container: its content becomes ordinary blocks.
   - Dropped with everything inside: `script`, `style`, `noscript`, `template`, `iframe`, `object`, `embed`, `video`, `audio`, `canvas`, `svg`, `math`, `form`, `select`, `textarea`, `button`, `head`, `title`. Any other tag contributes only its text.
   - White space is collapsed outside `pre`.

3. **Nothing of the article can run or reach out by itself.** The converter produces values, never HTML: there is no web view on the reading screen. Only these attributes are read: `href`; `src`, and when `src` is not an `http` or `https` address, `data-src` and then the first address of `srcset`; `alt`; `width` and `height`; `start`. Event attributes and styles do not exist after conversion. A link is kept only when its address, resolved against the article's address, is `http` or `https`; any other link keeps its text and loses its link. An image is kept only when its resolved address is `http` or `https`; an image whose width or height attribute is 0 or 1 is dropped. An article with no address of its own has no base: its relative links and images are dropped.

4. **Limits, because a feed is untrusted.** The HTML is read from the library cut to its first 2,000,000 characters (in the query, not after loading). At most 3,000 blocks and 300 images; a paragraph's text beyond 20,000 characters continues in a further paragraph. When the input or the block count is cut, the list ends with a marker and the screen says so (decision 13). Conversion time and memory are linear in the input by construction; criterion 3 records them for the shapes that broke the tree builder.

5. **Full text or excerpt.** `ArticleBlocks.isFullText(blocks)`: the plain text of all text blocks, white space collapsed, has at least 1,000 characters, or at least 400 when more than half of its letters are Han, Hiragana, Katakana or Hangul. A body below that is an excerpt: its blocks are shown as they are, followed by "Only an excerpt is available" and "Open Original Page". A body with no block at all shows the row's plain excerpt as one paragraph. (RD12 fetches the page in that case.)

6. **Derived at every opening, not stored.** The converter is a pure function and `content_html` is never rewritten and lives as long as its article, so the same version gives the same blocks, in milliseconds. Nothing is written to `article_body` in this issue; RD12 writes it for bodies fetched from a page, where a request is being saved. `ArticleBlocks.version` (1) names the converter's output; RD15 records it with a translation and redoes or discards a translation made for another version.

7. **Where conversion runs.** Loading a body is its own task per opened article, outside `ReadingModel`'s serial queue of list reads and state changes: read the cut HTML, convert off the main actor and outside any database read or write, then show. A result whose article is no longer the open one is dropped. Only the open articles' blocks are kept in memory (one per stack). The block renderer is a view that takes blocks, the reading settings and a link handler and nothing else, so that RD12's reader mode can use it without a library row.

8. **Layout.** A scroll view with a lazy stack: header (title; source · author · time, as today), then the blocks, in a column at most 680 pt wide with 16 pt side margins.
   - Type: body 17 pt at the default Dynamic Type size, scaled with Dynamic Type and by the text-size setting. Headings by level: 1 and 2 at 1.3 times the body size, 3 at 1.15, 4 to 6 at 1.0, all semibold, each with the VoiceOver heading trait (the title is the screen's only larger heading); no text is drawn larger than 60 pt. Code in the system monospaced face at 0.9 times, in a horizontally scrolling box on the surface colour. Captions at 0.85 times in the secondary colour. A quote has a 3 pt bar in the hairline colour per depth at its leading edge and secondary text. A list block is indented 20 pt per depth with its marker in a leading column.
   - Line height: a block's line pitch is its font size times 1.7 when more than half of the block's letters are Han, Hiragana, Katakana or Hangul (Korean is treated as Chinese and Japanese are), and times 1.5 otherwise, each times the line-spacing setting's factor. It is set with the system's exact line height (`lineHeight`, iOS 26), not by adding spacing to a font's own line height. The space between blocks is 0.9 times the body size.
   - A block that contains kana is marked Japanese, so that the system draws its characters in the Japanese forms (ux section 5); other blocks are not marked.
   - A block's text can be copied as a whole (the system's selection on iOS). A link is drawn in the accent colour and underlined; tapping it opens the embedded browser on the article's stack (`navigation.openPage`), never Safari.
   - Appearance follows the system; colours are the theme's.

9. **Images.** Fetched like thumbnails — the same transport, the same partition's image cache under the image's own address, no fetched byte written as received, the same refusal of an image declaring more than 40 megapixels and the same white ground under transparency — but at most 3 at a time, at most 10 MB as received, stored reduced to at most 2,048 pixels on the longer side. A failed fetch is not remembered: the image is asked for again when the article is opened again.
   - Shown at the column's width, never larger than the image's own size, and not at all when the decoded image is under 8 pixels on a side (a tracking pixel that declared no size). Decoded to the width it is shown at, off the main actor; a block that leaves the screen lets go of its decoded image.
   - Until an image arrives its place is reserved (the attributes' aspect ratio when given, else 3:2) on the surface colour; one that fails, or that the system cannot decode (SVG among them), shows its alternative text in that place, or a small "image not available" symbol when it has none. An animated image shows its first frame.
   - Tapping a loaded image opens the viewer: full screen, black ground, a system scroll view for zoom and pan, a Close button, the alternative text as its VoiceOver label. An image is an accessibility element labelled with its alternative text, or "Image".

10. **Reading settings.** Three device settings in `Preferences`, not exported: text size (five steps: 0.85, 0.92, 1.0, 1.15, 1.3; default 1.0), line spacing (three: 0.9, 1.0, 1.15; default 1.0), typeface (the system face, or serif: New York, with Songti SC for Chinese when the system has it — assumption A7). One observable `ReadingSettings` object over them. "Aa" in the reading screen's navigation bar opens a popover (a sheet in compact width) with the three controls; Settings › Reading (a new row between Refresh and Data) has the same three. A change applies at once to the article on screen and persists. The default display mode of S8 is RD15's.

11. **Previous and next.** They follow the list the article was opened from, as `J` and `K` already do (`openNext(on:)`, `openPrevious(on:)`): the list's loaded rows in their order, the next page loaded at the end of the loaded rows. The new article starts at its top.
    - Controls that are not gestures: "Next Article" in the bottom bar and "Previous Article" in the More menu, each disabled where the list ends.
    - Swipe. On iOS 26 a swipe towards the trailing edge anywhere on a pushed screen is the system's back gesture, so on the pushed reading screen (iPhone structure) only the swipe towards the leading edge is the app's: it opens the next article; the other direction goes back to the list, as the system has it. In the iPad reading pane, which is the root of its stack, both directions work: next and previous. A swipe inside a code block scrolls the block. Assumption A4 is measured first, by hand with animations on.

12. **Bars.** Bottom bar, in ux S4's order without the display mode: Star, Share (the original link, the system sheet), Open Original Page, Next Article. Navigation bar: "Aa" (label "Reading Settings"), and a "More" menu with Previous Article and Mark as Unread. Each has a label and a 44 pt target. An article with no link has no Share and no Open Original Page.

13. **Messages.** After an excerpt: "Only an excerpt is available", then the "Open Original Page" button. After a body that was cut: "The rest of this article is on the original page.", then the same button; for an article without a link, "The rest of this article is not shown." A body that cannot be read from the library: "This article could not be shown." with Try Again, under the header.

14. **Hiding the list on iPad** (ux section 2; named for RD11 by RD03 and RD09). In the two-column layout (700 to 1099 pt) the reading pane's navigation bar has a button that hides the list column, so the article is read at full width, and shows it again. While the list is hidden: `J`, `K`, `S`, `U` and `R` still act; the list keeps its scroll position for when it is shown again; the sidebar stays reachable from the reading pane (its button moves there). The state lives in `NavigationModel`, is not stored, and resets when the layout leaves two columns, when the sidebar selection changes, and when no article is open. The button is absent in the other layouts.

15. **Left by RD09, in scope here.**
    - An open article whose source was deleted, or that the retention clean-up removed, stayed on screen in the iPad reading pane. After the lists are read again, an open article that no longer exists becomes "This article is no longer available." (the existing state), and on iPhone the pushed reading screen is popped. This is on the screen this issue rebuilds.
    - Separately, a fix for a test that fails on some simulators: "the list is at its top" (which decides whether a refresh the list did not start re-reads it) is taken from the first row's appear and disappear events, and SwiftUI sends those at distances that differed between two simulators of one type (`ArticleListTests.testRefreshFromTheList` failed on one, at main too). It is taken from the scroll position instead — the list's content offset, relative to its top inset, is within one row's height — which is ux S3's "while its first row is on screen" measured directly.

16. **What the interim screen had and loses.** Its sentence "The full article layout is not available in this version yet." and its string are removed; "Mark as Unread" moves from the bottom bar to the More menu. The Data screen's footnote about the image cache is reworded to cover article images.

**For the owner** (choices the issue left open):

1. **The converter does not use SwiftSoup**, although the issue names it: a small article built to do so can make SwiftSoup work for seconds or take hundreds of megabytes (measured), and the app would stall or be ended by the system. The body is read by a linear scan instead, as RD04 did for feeds. Odd or broken HTML is read less cleverly than a browser reads it; "Open Original Page" is always there.
2. A table of plain cells is shown as lines of text, one per row; a table used for layout is read as ordinary content.
3. Video, audio and embedded frames in a feed's body are not shown; "Open Original Page" has them.
4. A very long body is cut (2,000,000 characters, 3,000 blocks, 300 images) and says so.
5. Images are stored reduced to 2,048 pixels on the longer side, are never enlarged beyond their own size, and images declared or found to be a few pixels in size are not shown. Every other image of an article is loaded when it scrolls near, which tells its server that it was read — as in any reader.
6. Previous and next: on iPhone, swipe left for the next article; swipe right goes back to the list (iOS 26's own gesture), and "Previous Article" is in the More menu. On iPad both swipes work. `J` and `K` work as before.
7. An excerpt-only article shows the feed's short text and "Open Original Page"; fetching the full text comes with RD12.
8. Text size has five steps on top of the system's text size; line spacing three. Serif is New York; whether Chinese text gets a serif face (Songti) depends on the system having it without a download, and the pull request says what was found.
9. On iPad between 700 and 1099 pt a button hides the article list to read at full width.
10. A feed's body is not saved in a converted form; it is converted each time the article is opened (it takes milliseconds).
11. The rule for "the list is at its top" now reads the scroll position (decision 15): a small change to RD09's behaviour, made because its test failed on one simulator.

## Acceptance criteria

| # | Criterion | Evidence |
| --- | --- | --- |
| 1 | Every block kind and attribute is produced from its HTML: inline bold, italic, code and links; nested lists and quotes; a second paragraph, a `pre` and an image inside a list item and inside a quote; `<li><p>` as one item; `figure` captions; an image inside a paragraph and inside a link; text separated by double `br`; empty blocks dropped; a plain table as lines and a layout table as content; a `pre` inside a table cell; stray text; entities | Package tests, table-driven, exact blocks |
| 2 | A document with `script`, `style`, event attributes, `javascript:` and `data:` links, an `iframe`, a form, a lazy-loaded image (`data-src`) and a tracking pixel yields no script text, no such link, no frame, no control, the lazy image's real address and no pixel; relative addresses are resolved against the article's address and dropped without one | Package test; UI test: the fixture article shows its text, and tapping the text of the `javascript:` link does nothing |
| 3 | Bounded work: for each shape the debate measured against the tree builder (formatting tags reopened across thousands of paragraphs, with and without attributes; an unclosed attributed tag before thousands of paragraphs; 500 levels of `div` before hundreds of thousands of `p`; hundreds of thousands of unclosed tags; a megabyte in one attribute; 2,000,000 characters of ordinary paragraphs) the conversion ends within 1 second on the Mac, on a detached task, with at most 3,000 blocks; the cuts of decision 4 are exact and end with the marker | Package tests with recorded timings |
| 4 | Full text or excerpt at 1,000 and 400 characters, with the "more than half" rule, each at its boundary | Package tests |
| 5 | The fixture article with every block kind is laid out natively: each kind is on screen with its text, the image is shown, the link opens the embedded browser at its address and Close returns to the article | UI test on iPhone and iPad |
| 6 | An excerpt-only article shows "Only an excerpt is available" and "Open Original Page", which opens the browser; a cut body shows its line and the button | UI test |
| 7 | Reading settings apply at once and persist across a relaunch, from "Aa" and from Settings › Reading; the body scales with Dynamic Type | UI test: the same paragraph's frame height before and after each setting, after a relaunch, and across two launches with different text-size arguments |
| 8 | Line pitch 1.7 for a Chinese and a Japanese paragraph and 1.5 for a Latin one, within 3 %, in the system face and in serif, at the default and the largest text size | UI test from frame heights (the same fixture paragraph at n and n + 1 lines) |
| 9 | Previous and next follow the list's order from the bottom bar's button, the More menu and the swipes of decision 11, load the next page at the end of the loaded rows and start at the top | UI test for the buttons and the leading swipe; the swipes against the system's back gesture are checked by hand with animations on and are a device check |
| 10 | An image opens the viewer and Close returns; a failed image shows its alternative text and is asked for again when the article is reopened; an image is not drawn larger than its own size and a 1-pixel image is not drawn; body images go through the partition's image cache and Clear Image Cache removes them | UI test with fixture images; package test of the loader's limits |
| 11 | Memory: scrolling to the end of a fixture article with 100 large images and back leaves the app's memory within a stated bound of where it started | Measured once on a simulator and recorded |
| 12 | Bars: Star, Share, Open Original Page, Next Article; "Aa"; More with Previous Article and Mark as Unread; labels and 44 pt targets; an article without a link has no link actions | UI test |
| 13 | On iPad at a two-column width the list can be hidden and shown again; while hidden the keys act and the sidebar can be opened; shown again, the list is where it was; the state resets as decision 14 says; the button is absent at other widths | UI test |
| 14 | Deleting the open article's source shows "This article is no longer available." on iPad and pops the reading screen on iPhone | UI test |
| 15 | `testRefreshFromTheList` passes with the list's top taken from its scroll position, in both structures, and a list scrolled by one screen is not at its top | UI test on the three simulators |
| 16 | The interim sentence, its string and its identifier are gone; the three checks pass; every new string has a Simplified Chinese translation; the package suite also passes on an iOS simulator | CI; the strings check; the iOS 26.5 run |
| 17 | Screenshots, iPhone and iPad, in light, dark, Simplified Chinese and the largest text size: an article with every block kind, an excerpt-only article, "Aa", the viewer, Settings › Reading | Screenshots |

## Frozen issue contract

In scope: `Reading/ArticleBlocks` (the block types, the linear converter on the shared tag scanner, the limits, full text or excerpt, the version number); the Library function that reads an article's HTML cut to the limit; the three reading settings in `Preferences`; in the app `ReadingSettings`, the rebuilt `ReadingView` on a block renderer view, the body image loader and the viewer, "Aa", Settings › Reading, the bars, previous and next by button, menu and swipe, hiding the list in two columns, the two items of decision 15; fixtures (a feed whose items cover every block kind, an excerpt-only item, a hostile item, a cut item, images including a small one and a failing one, an article with 100 images); strings; tests and screenshots.

Out of scope: fetching the article's page and "Full text from the original page", and writing `article_body` (RD12); translation, display modes, the progress line, Copy translation, Article info, the VoiceOver language of a block (RD15); the translated title in the header (RD14); search (RD25); remembering the scroll position of an article; video and audio; MathML; right-to-left layout beyond what the system does by itself; downloading a font; selecting a range of text across blocks; printing.

Invariants:

- Nothing from an article is executed, and nothing of an article is given to a web view or to an HTML parser that builds a tree. (Amended by RD12 decision 1: the reading screen has no web view; the extractor's hidden one, under N12's static rule, reduces an article's page.)
- A link or an image address that leaves the converter is `http` or `https`.
- The converter is a pure function of the HTML and the base address, linear in the input: no request, no clock, no storage.
- Body images are fetched by the same transport, under the same rules, and stored in the same partition's cache as thumbnails; nothing of one partition's images is written to the other's cache.
- Offline tests make no external request: package tests use literal HTML; under a UI-test library directory images come from the fixture transport.

## Approach

**Package.** The tag scanner moves from `FeedDiscovery` to a file of its own (`Feeds/TagScanner.swift` or `Reading/`), unchanged in behaviour, with its existing tests. `Reading/ArticleBlocks.swift`: the types (`Sendable`, `Hashable`), the converter (one pass; a current-block builder; inline style flags that reset at a block's end; the capped context stack), `isFullText`, `version`. `Store/Library+Collection.swift`: `contentHTML(ofArticle:limit:)` with `substr`. `Model/Preferences.swift`: keys `reading_text_size`, `reading_line_spacing`, `reading_typeface`; an unknown stored value reads as the default.

**App.** `AppState/ReadingSettings.swift`; `ReadingModel` gains the open articles' bodies (decision 7) and the re-validation of decision 15; `Destinations/ReadingView.swift` rebuilt around `Reading/BlocksView.swift` (blocks, settings, link handler), with `Reading/BodyImageLoader.swift` (on the existing image cache and transport), `Reading/ImageViewer.swift` (a `UIScrollView` in a representable), `Reading/ReadingSettingsView.swift` (shared by "Aa" and Settings › Reading); `SettingsRoute.reading`; `NavigationModel` (the hidden-list state) and `PaneContainer` (the list pane kept in the hierarchy at zero width while hidden); `ArticleListView` and `ArticleListModel` (the top of the list by scroll position).

**Strings** (English · Simplified Chinese): Only an excerpt is available · 只有摘要 · The rest of this article is on the original page. · 文章的其余部分请在原网页查看。 · The rest of this article is not shown. · 文章的其余部分没有显示。 · This article could not be shown. · 无法显示这篇文章。 · Reading · 阅读 · Reading Settings · 阅读设置 · Text Size · 字号 · Smaller · 较小 · Larger · 较大 · Line Spacing · 行距 · Compact · 紧凑 · Standard · 标准 · Relaxed · 宽松 · Typeface · 字体 · Sans Serif · 黑体 · Serif · 宋体 · Image · 图片 · Image not available · 图片无法显示 · Hide Article List · 隐藏文章列表 · Show Article List · 显示文章列表 · the Data screen's footnote: "Images of article lists and of articles. Cleared images are fetched again when they are next shown." · 文章列表和文章中的图片。清除后，下次显示时会重新获取。 Existing and reused: Open Original Page, Next Article, Previous Article, Mark as Unread, Share, Close, Try Again.

## Failure handling

| Failure | Behaviour |
| --- | --- |
| `content_html` is empty or missing | The row's plain excerpt as one paragraph, then the excerpt line and the button |
| The HTML or the block count is past a limit | Cut, with the line of decision 13 |
| The body cannot be read from the library | "This article could not be shown." with Try Again; the header stays |
| An image fails, is too large or cannot be decoded | Its alternative text in its place; asked for again at the next opening |
| A link's address is not `http` or `https` | The text without the link |
| There is no next or previous article | The control is disabled; the swipe does nothing |
| The open article no longer exists | Decision 15 |
| Songti SC is not available without a download | Serif applies to Latin text; Chinese stays in the system face; the pull request says so |

## Assumptions

Measured by the implementer before building on them, each reported. A4 comes first.

| Assumption | If it does not hold |
| --- | --- |
| A4. On an iOS 26 or 27 simulator, by hand with animations on: on the pushed reading screen a swipe towards the leading edge can be the app's without disturbing vertical scrolling or the system's back swipe; in the iPad reading pane both directions can | Keep the button, the menu item and the keys, drop the swipe where it does not work, and say so to the owner |
| A2. `Text` with an `AttributedString` shows bold, italic, monospaced and link runs, wraps Chinese, and a link's tap can be taken by an `OpenURLAction` in the environment, also with the block's text copyable | A text view from UIKit in a representable for blocks with links |
| A3. `lineHeight` with an exact value (iOS 26) gives the asked line pitch for the system face and New York, with Chinese and Japanese fallback faces, at the default and the largest text size, within 3 % | Extra line spacing computed per face from what is measured; the criterion stays |
| A5. A lazy stack of 3,000 blocks scrolls without the screen freezing, and a block that leaves the screen can let go of its image | Report the measured bound; lower the block and image caps to what holds |
| A6. The article list's scroll position can be read (`onScrollGeometryChange`) in both structures, relative to its top inset | Keep the row events and widen the test's scroll; report |
| A7. Songti SC (or another system serif for Chinese) is usable on iOS 26 / 27 without a download | The last row of the failure table |
| A8. Marking a block Japanese changes its glyph forms and nothing else | Leave blocks unmarked; a device check then says what Japanese looks like |

## Risks

- The converter meets real feeds' HTML only through the owner's sources; fixtures cover the kinds, not the web's variety. A body that looks wrong is fixed by a converter change and a version bump.
- A linear scan has none of a browser's error recovery: misnested tags can put text in the wrong style until the block ends. Flat blocks bound the damage to one block.
- Lazy layout with images of unknown height moves the text when they arrive; the reserved place limits that.
- The swipe (A4) and the line height (A3) rest on iOS 26 behaviour read from the SDK, not yet seen.

## Test plan

Package: the converter table (criteria 1, 2), bounded work (3), full text (4), the scanner's own tests after the move, the preferences, the image loader's limits. UI (iterated with `-only-testing`; the whole suite once at the final commit; three simulators): criteria 5 to 10 and 12 to 15. One memory measurement (11). Screenshots (17). The package suite on the iOS 26.5 simulator before the external gate.

Device checks owed: real feeds of the owner's (a long article, one with many images, one in Chinese, one in Japanese); the serif face and whether Chinese has one; the swipes against the back gesture; the viewer's zoom; VoiceOver through a body; copying a block.

## Handoff notes

- RD12: uses `BlocksView` for reader mode and for the fetched body; writes `article_body` with `origin` = `extracted` (its own envelope and version); "Full text from the original page"; the excerpt state becomes the trigger for fetching. Readability's output goes through the same converter.
- RD14: the translated title in the header, the original under it.
- RD15: a translation records `ArticleBlocks.version` and the block count it was made for, and is redone or discarded on a mismatch; display modes; the VoiceOver language per block.
- RD18: the adult workspace gets its own `ReadingModel`; `ReadingSettings` is a device setting and is shared.
- RD19: "show thumbnails in lists" gates list thumbnails only; body images load in the adult partition as in the normal one, into its own cache.

## Revision record

Version 2 after debate round 1 (one fresh critic; 15 findings; SwiftSoup 2.14.3 measured on macOS in a release build, every parse on a detached task; CoreText line metrics measured on macOS; the iOS 27.1 SDK headers read; no simulator used). All admitted:

| # | Sev. | Finding | Change |
| --- | --- | --- | --- |
| D1 | P1 | The limits did not bound SwiftSoup's tree builder: 16 to 240 KB bodies nesting 24 to 42 deep took 3 to 16 seconds or 0.5 to 1.9 GB; a count of tags cannot tell them from ordinary HTML; the nesting guard was also not needed for the stack | A linear scan on the package's own tag scanner, no tree (decisions 1, 4; criterion 3 with those shapes); the nesting pre-pass, the plain-text fallback and the SwiftSoup assumption are gone; "For the owner" 1 |
| D2 | P2 | iOS 26's back swipe covers the whole content area of a pushed screen; "previous" had no control that is not a gesture | Decision 11: the swipe per structure, "Previous Article" in More; A4 first and by hand; criterion 9 |
| D3 | P2 | Exclusive list-item and quote-paragraph kinds could not hold common HTML (`<li><p>`, blocks inside items and quotes, images in paragraphs and links, double `br`, empty blocks, `pre` in tables, layout tables) | Five kinds with quote, list and caption attributes; the rules of decision 2; criterion 1's table |
| D4 | P2 | Storing derived blocks added nothing to alignment and a version bump would misalign paid translations | Not stored (decision 6); the version recorded by RD15 (handoff); the storage criterion dropped |
| D5 | P2 | Images: small images and pixels enlarged to the column, decoded memory unbounded, failures remembered until relaunch, the thumbnail loader's rules not stated | Decision 9; criteria 10 and 11 |
| D6 | P2 | Extra line spacing is fragile across faces (Songti 12 % off); Songti SC is not in the simulator runtime; Japanese drawn in Chinese forms | The system's exact line height (decision 8, A3); A7 and the failure row; kana blocks marked Japanese (A8); criterion 8 from frame heights |
| D7 | P2 | Hiding the list would drop the keys, the sidebar button and the list's place | Decision 14's three requirements and resets; criterion 13 |
| D8 | P2 | Conversion in the serial queue, or inside a write, would stall lists and state changes | Decision 7 |
| D9 | P3 | The plain-text fallback did not do what the design said | Gone with D1 |
| D10 | P3 | Heading levels ambiguous | The HTML level stored, mapped in the view, capped at 60 pt (decisions 2, 8) |
| D11 | P3 | The list-top fix is not on the rebuilt screen and was justified as if it were; the offset must be relative to the top inset | Named as a test-driven fix, with the inset, and listed for the owner (decision 15, "For the owner" 11) |
| D12 | P3 | Evidence that would pass while the behaviour is wrong (criteria 3, 8, 9, 10, 11) | Rewritten as above |
| D13 | P3 | Missing strings; a footnote that becomes false; a message without its next step; awkward Chinese | Decision 13; the strings list |
| D14 | P3 | Cuts: the pre-pass, storage, spacing arithmetic, a hand-built viewer, Copy Link in More, a per-run limit, "text can be selected" | All taken |
| D15 | P3 | `ol start` unbounded; headings over 100 pt at the largest sizes; Korean; no base address; lazy-loaded images | Decisions 2, 3, 8 |

Not re-reviewed after these changes. Not measured by anyone yet: everything in the Assumptions table, and the new converter itself.

## Post-implementation record

Written after the implementation and round 1 of the internal review (pull request #161). The decisions above are left as they were frozen; where this section differs from them, this section is what was built.

### Departures from the design, accepted by the driver

1. **The body image loader is in the package** (`NewsPawKit/Images/BodyImageLoader.swift`), not in the app as the Approach says: criterion 10 asks for a package test of its limits. The app has the view (`Reading/BodyImageView.swift`).
2. **`BlocksView` takes a fourth input**, the images of the opening (the loader, and what this opening has learnt about each address). Decision 8's "and nothing else" had no place for where images come from; a parameter keeps the view free of any library row.
3. **The converter reads a tag to its end**; the tag scanner's cap of 8,192 bytes became a parameter and is feed discovery's only. With the cap, the rest of a long attribute (an image written into its own `src`) became the article's text. The work stays linear: a tag that never ends consumes the rest of the input. A tag written as empty by an XML serialiser (`<iframe/>`, `<script/>`) has no content for the converter.
4. **Code blocks, too, continue in a further block after the limit of a block** (decision 4 names paragraphs), at a line's end where there is one, and **alternative text is bounded**: both for the reason of the paragraph limit, one text view of megabytes.
5. **The list indent grows with the text size**, from 20 pt per depth up to 32 pt (decision 8: 20 pt), so that a marker has room at the large sizes.
6. **A hairline around the code box and around an image's place.** The surface colour is the page's colour in light appearance, so a box "on the surface colour" had no edge.
7. **An image that is not in the cache is asked for after its block has been on screen for 150 ms.** At the first layout the lazy stack made every block twice and each image was requested twice; a block that only passes by makes no request either.
8. **A reading screen pushed on its list is popped for any open article that no longer exists**, also one found missing when a stale row is tapped (decision 15 names the deleted source and the clean-up).
9. **The `Line heights` fixture and two debug launch keys** (`NEWSPAW_UITEST_ARTICLE_PAGE_SIZE`, `NEWSPAW_UITEST_KEEP_ANIMATIONS`), honoured only in a debug build under a UI-test library directory: the first so that a UI test reaches the end of the loaded rows in 20 rows, the second for the checks made with animations on.

### Assumption A7

**Does not hold on the iOS 27 simulator**: the Songti SC family is not there without a download. Serif is New York for Latin text there and Chinese stays in the system face; a block with kana falls back to Hiragino Mincho. The code that puts Songti SC behind New York when the system has it has therefore never run, on a simulator or a device. The other assumptions held as measured (A4 with a UIKit swipe recogniser only, not with a SwiftUI drag gesture; A5 as far as a simulator shows).

### Changes of review round 1

- **The reader's place while an article stays open** (non-goal "remembering the scroll position of an article" made precise: it means from one opening to the next). In the reading pane the article's screen is taken away while its page is in the browser, and a change between the tab and the pane structure builds it anew; it then starts at the block that was at the top of the screen, or at the article's top with its header when it was there. The place is kept in memory beside the body (decision 7) and let go with it; nothing is stored, and an article opened again starts at its top.
- **Decision 2, emoji images.** An `img` whose `class` holds the token `wp-smiley` or `emoji` (WordPress writes every emoji so) is its alternative text in the line it stands in: no image block, no request. Without alternative text it is dropped. `class` joins the attributes read (decision 3), for this and nothing else.
- **Decision 2, block starts.** `center` and `address` start a block as `div` does. `nav` still does not.
- **Decision 4, the limits.** A block's text also ends at 80,000 bytes of UTF-8, where a scalar ends: 20,000 characters as a reader counts them do not bound a block, since one character can be of any size (a letter under any number of combining marks). Alternative text: 500 characters and 2,000 bytes. A body that ends inside an element dropped with its content (a `form`, `video` or `svg` that never closes) is marked as cut, and shows the cut line: what was dropped may be the rest of the article.
- **Decision 6, the version.** These change what the converter gives for the same HTML: `ArticleBlocks.version` is 2. Nothing has recorded version 1.
- **Decision 8, the title.** The header's title follows the text-size setting as the body does: 22 pt at the default step and the default Dynamic Type size, scaled by both, at most 60 pt. It was fixed at the text style's size, so at the larger steps a body heading was larger than the title.
- **Decision 9, the stored size of an image.** A stored image has at most 2,048 × 2,048 pixels in all (4,194,304) and at most 8,192 on a side; its shape is kept and it is never enlarged. The bound on the longer side alone (2,048) stored a long picture as a strip no zoom made readable: a screenshot of 1,080 × 6,000 was 369 pixels wide and is now 869 × 4,826. The decoded size in memory has the same bound as before. "Never larger than the image's own size" is, as built, one pixel of the stored image to one point at most; on a 3x screen that is up to three screen pixels to one of the image.
- **Decision 10, the strings.** The typeface options read "衬线" (Serif) and "无衬线" (Sans Serif) in Simplified Chinese, not "宋体" and "黑体": where the system has no Songti SC (A7), "宋体" named a face the reader did not get. English is unchanged.
- **Decision 10, "Aa" where the screen is low.** The settings have an ideal size (340 × 580 pt, the popover's size and the sheet's first detent), not a least size: on an iPhone in landscape the least height laid the settings out taller than the screen, with Close above its top edge.

### Changes of review round 2

- **Decision 4, the cut mark: unclosed raw text and comments.** The tag scanner reads the content of `script`, `style`, `noscript`, `textarea`, `title` and `iframe` as raw text up to its end tag, and passes over comments; one that has no end ran to the end of the input and the body showed no cut line. The scanner now says how a scan ended, and a body that ends inside such an element or comment is marked as cut, as one that ends inside a dropped element is; the text before it is kept. Feed discovery reads as before. An end tag in another letter case, or with white space or `/` before its `>`, still closes the element. A body that ends inside a tag that never ends — a start or end tag with an unclosed quote or no `>` before the end of the input (`<img src="…`, as feeds that shorten their content often leave it), a `<!…` or a `<?…` — is marked as cut too; a tag longer than feed discovery's cap is still skipped there as before.
- **Decision 8, list markers.** A list's marker column is as wide as the list needs: the indent of a level (decision 8, and departure 5) or, when it is wider, the list's widest marker in the body's face and size and the gap after it, a number measured as so many of the face's widest digit. Each block carries the widest marker of every list it stands in (`ArticleBlock.widestMarkers`, known when the list ends), so all items of a list, and every block of an item, have their text at one edge. Where the columns of a block together would take more than half the column's width (numbers of several digits in nested lists at the largest sizes), they are narrowed in proportion and the markers drawn smaller to fit; a marker is never drawn past the page's leading margin or cut. A bullet list and the nesting indent are unchanged at the default size; a numbered list of one-digit numbers is about 1 pt wider than the 20 pt indent there, where its marker stood that much in the margin before. `ArticleBlocks.version` stays 2: the blocks' text and kinds are unchanged and nothing has recorded a version.

Recorded for the owner, not built: after a clean-up on entry a list keeps the rows of removed articles until it is entered again, and on iPhone Next Article onto such a row drops back to the list; an image with transparency sits on white in dark appearance; the Songti cascade has never run.
