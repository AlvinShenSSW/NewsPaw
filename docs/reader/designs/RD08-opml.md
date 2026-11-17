# RD08 — OPML import and export

Issue: [#129](https://github.com/AlvinShenSSW/NewsPaw/issues/129) · Epic E12 #115 · Requirements N03 (OPML), N10 (OPML); ux S6 (address step), S8 (Data). Also touched: N02 (categories, the same address), N09 (partitions), N12 (untrusted files), N13 (offline tests).

Version 2 (2026-11-15), written against `main` at `d436d25`, after one debate round (records at the end). Frozen. By the driver's decision this issue is implemented after RD07 (#128) and RD18 (#139) have merged; the two names it takes from them (`SourceKind.isCollectedAsFeed`, the per-workspace source model) are checked against the merged code at dispatch.

## Spec review

**What the baseline says.**

- N03: "OPML import: folders in the file become categories in the current partition. Feeds outside any folder go to one category the owner picks in the preview, an existing one or a new one. Addresses that already exist in that partition are skipped and listed. An OPML file is untrusted input (N10)."
- N10: "OPML can be imported, and exported per partition. An OPML file is untrusted in the same way: at most 5 MB and 2,000 feeds, external entities are never resolved, folders nested inside folders are flattened into their top folder, and addresses must be http or https."
- ux S6: the address step of Add source lists "Import OPML" below Suggested sources. ux S8: Settings → Data holds "OPML import / export".
- Issue: export "the current partition's feed-like sources as OPML through the share sheet".

**What `main` does today.** Nothing reads or writes OPML. Sources are added one at a time through detection (`SourceDetector`, `Library.addFeedSource`, `addWebPageSource`). `source.url` is unique per library and holds the normal form of `SourceAddress`; `source.site_url` holds what `RawItem.webAddress` returned for the feed's link, which is not a normal form (`https://example.com` stays without its slash). Categories are created by `Library.createCategory` (duplicate names allowed, placed last). Settings → Data has the image cache only. The project has no unit-test target for the app; what is not in the package is tested through the interface or not at all. The feed reader (`XMLFeedReader`, RD04) reads untrusted XML with the system parser behind guards: `StartTagScan.cutOffset` before parsing, external entities off, byte limits on names.

**Measured on 2026-11-15** by the critic, with Foundation's `XMLParser` on this Mac (macOS 27.0.1; scripts and outputs in the run's evidence folder under `rd08/debate/`), not on an iOS simulator:

| Question | Answer |
| --- | --- |
| Which declaration callbacks fire with `shouldResolveExternalEntities = false`? | Internal entity, element, notation and unparsed entity: yes, before the root. **External entity: never.** A bare `<!DOCTYPE opml>`, an empty internal subset, a `SYSTEM` or `PUBLIC` external subset: no callback at all, and the parse succeeds |
| Is anything read from an external identifier? | No. An entity the external file would define arrives as empty text |
| `abortParsing()` in the internal-entity, element and notation callbacks | Ends the parse cleanly; a nested-entity sample stops at its first declaration in under 1 ms |
| The parser on 5 MiB shapes | 256 distinct attribute names on every tag: 0.78 s. 1.31 million smallest elements: 169 ms. Nesting 300,000 deep: 44 ms, no error |
| Swift on a name made of one letter and combining marks | One `Character` whatever its length. `==` on a 160 kB name: 1.5 s; hashing: 0.7 s; four times the cost for twice the length |

**Gaps the baseline leaves, and what this design decides** (each is in "Approach"; the ones the owner may want to overrule are repeated in "For the owner"):

1. Whether importing checks each feed. Decided: no request while importing; the feeds are added and one ordinary refresh follows.
2. What happens to an entry whose address is not http or https. The acceptance list refuses a file for being malformed, over a limit or declaring an external entity; it does not name a bad address. Decided: that entry is skipped and listed; the file is not refused.
3. Whether a folder named like an existing category makes a second category. Decided: it goes into the existing one, by N10's merge rule for the configuration file (first of that name in the owner's order).
4. Whether a folder with no feed becomes a category, and whether export writes a category with no feed. Decided: export writes every category; on import a top-level outline with no feed under it is a category only when it is an empty element, which is what the export writes and what other programs' settings blocks are not.
5. What "feed-like" is. Decided: kinds `feed` and `github`. Web pages are not in the file; Hugging Face accounts (RD26) are not feed addresses and will not be either.
6. What kind an imported entry gets. Decided: always `feed`. A GitHub source that is exported and imported again is an ordinary feed at the same address.
7. How "external entities are never resolved" is enforced and shown to be. Decided: a file with any document type is refused, found in its bytes before parsing.

## Acceptance criteria

1. A file with folders, a folder nested in a folder, feeds outside any folder, an address already in the library, an address listed twice and an address that is not http or https imports as: one category per top-level folder (matched to an existing category of the same name, else created, in file order after the existing ones); the nested folder's feeds in their top folder's category; the outside feeds in the category chosen in the preview; the other three entries skipped. The preview shows these numbers before anything is written, and the summary after the import lists what was added and every skipped entry with its reason.
2. Each of these files is refused with its reason and changes nothing: not well-formed; root not `opml` or no `body`; larger than 5 MB; more than 2,000 feeds; more than 500 top-level folders; any document type (a bare one, an external subset, an internal or external entity declaration); one that `StartTagScan` cuts; neither a feed nor a folder. The size is refused before more than 5 MB plus one byte is read.
3. A file whose document type names an external subset or declares an external entity causes no read of that address or file. (It is refused before parsing; the test also parses such a file with the reader's parser settings directly and asserts that the content of the named `file:` does not arrive.)
4. Cancelling the preview changes nothing. Import is one transaction: a failure while writing leaves the library as it was.
5. Imported sources have kind `feed`, the name from the file (decision 1), `site_url` from `htmlUrl` when `RawItem.webAddress` accepts it, default options, no articles and no success time; the status reads "Not updated yet" until the refresh that follows the import reaches them. The lists are reloaded as soon as the write succeeds, and the refresh starts when the summary is left, by Done or by a swipe.
6. Export writes OPML 2.0 with every category of the current library in the owner's order and, inside each, its `feed` and `github` sources in name order with `text`, `title`, `type="rss"`, `xmlUrl` and, when stored, `htmlUrl`. No web-page source is written. The file passes through the system share sheet; its temporary copy is removed when the sheet closes, before the next export and at launch.
7. Round trip: the export of a library, imported into an empty library, gives categories with the same names in the same order and, in each, feeds with the same addresses, names and site addresses. Not kept, and said so in the pull request: kinds (a `github` source comes back as `feed`), options, pause state, icons, web pages; two categories of the same name come back as one; white-space runs inside a name come back as one space and control characters are dropped; a library with more than 2,000 feeds or 500 categories exports a file this app's import refuses.
8. Partitions: import and export use only the library of the workspace they were started in. Package test: with two libraries open, an import into one leaves every table of the other unchanged, both ways round; the export of one contains no address of the other. A result that arrives after that workspace has been locked or left presents nothing.
9. Both entry points exist: "Import OPML" on the address step of Add source, and "Import OPML" / "Export OPML" in Settings → Data. Export is disabled while the library has no `feed` or `github` source.
10. A name or address from the file is bounded in bytes before any character-level operation, comparison or hash (decision 2); the combining-mark sample of the table above is read within a time bound in the reader's tests.
11. Every new string has an English base and a Simplified Chinese translation; the three checks pass; offline tests make no request.

## Frozen issue contract

**In scope:** the OPML reader and writer in the package; the plan and import transaction on `Library`; the import flow (file picker, refusal message, preview, choosing the category for outside feeds, summary); the export action and share sheet; the two entry points; the `.opml` type declaration; debug-only fixture files for UI tests; strings; tests.

**Out of scope:** the `.newspaw` configuration file and "Import configuration" (RD20). Opening an `.opml` file from another app ("Open in NewsPaw"). Checking or previewing each feed during import. Importing options, read state, kinds or articles. A lenient reader for files that are not well-formed. Choosing which folders or feeds of a file to import. Comparing GitHub addresses without regard to case, as RD07's detection does. Any change to `XMLFeedReader`, `StartTagScan`, detection or collection.

**Requirement map:** N03 (OPML) → criteria 1, 4, 5, 9. N10 (OPML) → criteria 2, 3, 6, 7. N09 → criterion 8. N12 → criteria 2, 3, 10. N13 → criterion 11.

## Assumptions

Each is checked by the implementer before the code that depends on it and reported in the hand-back.

- A1. With an imported type declaration for `.opml` (identifier `org.opml.opml`, conforming to `public.xml`) in `NewsPaw-Info.plist`, `.fileImporter(allowedContentTypes: [opml, .xml])` lets a `.opml` and a `.xml` file be chosen in Files on the iOS 27 simulator. If a `.opml` file stays greyed out, widen the allowed types to `.data` and rely on the reader's refusal; record which was needed.
- A2. The table under "Measured" holds on the iOS 27 simulator and in the iOS 26.5 package suite for the rows the reader depends on: no declaration callback for a bare document type, an external subset or an external entity; nothing read from an external identifier. The package tests of criteria 2 and 3 are the check.
- A3. The 256-attribute shape at 5 MB parses in under 2 s on the simulator (0.78 s on the Mac). If not, report the number; the driver decides.
- A4. A file URL in the app's temporary directory handed to the share sheet offers "Save to Files" and AirDrop, and the saved file can be imported again.
- A5. XCUITest can see that the share sheet is on screen. If it cannot, the UI test stops at the tap and the sheet is checked by hand.
- A6. In the adult partition with RD18's default lock setting, the Files picker and the share sheet can be used without the partition locking under them (hand check on a simulator). If either locks it, report; the driver decides.

## Approach

**1. Reader (`OPMLReader`, package, no store, no network).** `read(contentsOf: URL)` does the bounded read of decision 3 and calls `read(_ data: Data) -> Result<OPMLDocument, OPMLRefusal>`. `OPMLDocument` is the top-level entries in file order: `.feed(OPMLFeed)` or `.folder(name: String, feeds: [OPMLFeed])`; `OPMLFeed` is the `xmlUrl` text, the name and the `htmlUrl` text. The reader does not validate addresses and does not look at a library.

- An `outline` with a non-empty `xmlUrl` is a feed, whatever its `type`. Children of a feed outline are ignored.
- An `outline` without `xmlUrl` directly inside `body` is a top-level folder when its name is not empty and either a feed lies under it at any depth, or it has no child element at all (the writer's empty category). One with children and no feed under it — another program's settings block, a list of links — is ignored. A top-level outline without `xmlUrl` whose name is empty is not a folder; feeds under it count as outside any folder.
- An `outline` without `xmlUrl` at any deeper level is flattened: its feeds belong to the top-level folder above it.
- Only `outline` elements inside the one `body` of a root `opml` count. `head` is ignored. Character data is ignored.
- Names: `title`, else `text`; white-space runs collapsed, control characters removed, trimmed; cut to `Library.maximumCategoryNameLength` (folders) or `maximumSourceNameLength` (feeds). A feed with no name takes its address's host at import.

**2. Guards, in this order.**

1. The size (decision 3).
2. `StartTagScan.cutOffset(in:)` returning anything → `unreadable`. That covers a start tag with more than 256 attributes, an attribute-list declaration, UTF-16, UTF-32 and EBCDIC, an encoding label the scan does not know, and an XML declaration it cannot read. UTF-8 with or without a byte-order mark, and the labelled single- and double-byte encodings the scan knows (Shift_JIS, GBK, Big5 among them), go on.
3. A walk over the prolog bytes — byte-order mark, XML declaration, white space, comments, processing instructions — that refuses with `hasDocumentType` when `<!DOCTYPE` comes before the first start tag. After step 2 the bytes `<`, `!`, `?`, `-`, `>` are never the second byte of a character, so the walk reads bytes. This is the guard for criterion 2; the parser's declaration callbacks stay as a second one and refuse the same way.
4. `XMLParser` with `shouldResolveExternalEntities = false` and namespace processing off. Reading stops and the file is refused on: a declaration callback (`hasDocumentType`); more than 2,000 feed outlines, counted before any validation (`tooManyFeeds`); more than 500 top-level outlines without `xmlUrl` (`tooManyFolders`); a parse error (`notWellFormed(line:)`). At the end: a root that is not `opml`, or no `body` (`notOPML`); neither a feed nor a folder (`empty`). A refusal never carries part of a document.
5. Bytes before characters. Element and attribute names are compared as UTF-8 bytes with ASCII letters folded, and only when at most 16 bytes long; nothing from the file is lower-cased or hashed as a name. A `title` or `text` value is cut to 1,024 UTF-8 bytes at a scalar boundary before anything else is done to it; an `xmlUrl` or `htmlUrl` value longer than 8,192 bytes is treated as an invalid address (the entry is skipped) or as no site address.

No limit on nesting depth or on the number of elements: the measurements show the parser linear in both inside 5 MB. Known limit, stated in the pull request: these guards do not claim to bound the system parser on every 5 MB input; spec section 10 already accepts that for feeds, which are fetched automatically, while this file is chosen by hand. The parse runs off the main actor, and nothing is written before it ends.

**3. Reading the file.** In the package: take the size from the URL's resource values and refuse above 5 MB (`5 * 1024 * 1024`, the unit of the feed limit) without reading; read through a file handle up to the limit plus one byte and refuse if the extra byte is there. A read error is `unreadable`. In the app: security-scoped access is started before the call and stopped after it.

**4. Plan (`Library.opmlImportPlan(_:outsideFeeds:)`, one read) and import (`Library.importOPML(_:outsideFeeds:)`, one write).** Both run the same internal function over the database, so the summary is what the transaction did even if the library changed after the preview.

- Each feed in file order: its address through `SourceAddress.parse(_, addingScheme: false)`; a failure → skipped, `invalidAddress`. Else the normal form already in `source.url` (any kind, exact comparison) → skipped, `alreadyInLibrary(categoryName)`. Else seen earlier in this file → skipped, `repeatedInFile`. Else added.
- Each top-level folder, in file order: folders of the same name in one file are one folder; it matches the first existing category (owner's order) whose name is equal, else a category is created with the icon `folder`, placed after the existing ones in file order.
- Outside feeds go to `outsideFeeds`: `.existing(UUID)` or `.named(String)`, a typed name validated like any category name and resolved by the folder rule — the first existing category of that name, else the category this import creates for a folder of that name, else a new one placed last. The plan accepts no target (the preview before a choice); the import needs one exactly when at least one outside feed would be added, and throws `unknownCategory` for an identifier that no longer exists.
- Added sources: kind `feed`; `site_url` what `RawItem.webAddress(htmlUrl, base: nil)` returns; `paused` false, options default, validators and times empty, `updated_at` now.
- The result (`OPMLImportSummary`): categories created (names), categories matched, added count per category, and the skipped entries (name, address cut to 200 characters for display, reason).

**5. Import flow (app).** One view modifier used by both entry points: the file importer, an alert for a refusal ("Could not import this file · reason", OK), and a sheet with its own navigation stack for the preview. `OPMLImportModel` (new, `@Observable`) is owned by the workspace's source model, as Add source's model is, and holds the document, the plan, the outside-feeds choice and the stage: preview → importing → done, or failed with the storage reason and the preview still shown. The read and the plan run in a task of that model; a result is dropped when the model is no longer the one its workspace holds, so nothing is presented after a lock or a switch (confirm against RD18's merged shell at dispatch).

- Preview: "N feeds to add"; the folders with their feed counts, each marked new or existing; when there are outside feeds to add, a required "Category" row that pushes a picker of the library's categories plus "New Category…" (a name field; nothing is created until Import); "Skipped (K)" pushing the list with reasons; Cancel and Import. Import is disabled until the required category is chosen, while importing, and when the plan adds no feed and creates no category (the screen then says that everything in the file is already in the library).
- When the write succeeds: categories and sources are reloaded at once, and the sheet shows the summary (added, categories created, skipped with the same list) with Done. Leaving the summary by Done or by a swipe starts the refresh the Today pull starts (`RefreshModel.refresh(.library)`); from Add source, Done also closes Add source. The sheet cannot be swiped away while importing.

**6. Writer (`OPMLWriter`, package) and `Library.opmlExport()`.** One read: categories in the owner's order; sources for which `kind.isCollectedAsFeed` (RD07: `feed`, `github`) by name as `sourceSummaries` orders them. Output: UTF-8 with an XML declaration, no document type, `<opml version="2.0">`, `head` with `title` "NewsPaw" and `dateCreated` (RFC 822, GMT), one top-level `outline` with `text` and `title` per category (an empty element when it has no such source), feed outlines inside. Attribute values escape `&`, `<`, `>`, `"`, write tab, line feed and carriage return as character references, and drop characters XML 1.0 does not allow.

**7. Export flow (app).** "Export OPML" builds the data off the main actor, writes `NewsPaw Feeds <yyyy-MM-dd>.opml` into a directory of its own under the temporary directory (emptied first), and presents the system share sheet for that URL through a `UIActivityViewController` representable, whose completion gives a definite moment to empty the directory again. The directory is also emptied at launch. The file name and the title do not name the partition. A failure to write shows an alert.

**8. UI tests cannot drive the Files picker.** In a debug build under a UI test (the library-directory key set), a launch key names one of two fixture documents built in debug-only code (`folders`, `refused`); "Import OPML" then writes that document to a temporary file and hands its URL to the same `read(contentsOf:)` instead of presenting the picker. Feed addresses in `folders` are ones the fixture transport answers, so the refresh after the import collects them. Release builds contain none of it.

## Files to change

Package (`ios/NewsPawKit/Sources/NewsPawKit`): new `Config/OPMLReader.swift`, `Config/OPMLWriter.swift`, `Store/Library+OPML.swift`. Tests: new `OPMLReaderTests`, `OPMLWriterTests`, `LibraryOPMLTests`.

App (`ios/NewsPaw`): new `AppState/OPMLImportModel.swift`, `Settings/OPMLImportView.swift` (modifier, preview, picker, skipped list, summary), `Settings/ShareSheet.swift`; changed `AddSource/AddSourceView.swift` (the row), `Destinations/SettingsView.swift` (`DataSettingsView`: a section above Images), `AppState/SourceModel.swift` (owning the import model, the reload after a write), `NewsPawApp.swift` or the app model (emptying the export directory at launch), `AppState/DebugLaunchOptions.swift`, `UITestIdentifiers.swift`, `Localizable.xcstrings`, `NewsPaw-Info.plist` (the imported type), debug fixtures beside the existing ones. UI tests: new `OPMLTests`.

Not changed: `XMLFeedReader`, `StartTagScan` (called, not edited), `SourceDetector`, `GitHubRepository`, collection, the schema (no migration).

## Execution surface

No request is made by import or export. The import is followed by the existing refresh. No model call. No new dependency. The exported file leaves the app only through the share sheet the owner acts on.

## Failure handling

| Case | Behaviour |
| --- | --- |
| File refused (criterion 2) or unreadable | Alert with the reason on the screen that opened the picker; nothing changes |
| Picker cancelled | Nothing |
| Storage error in the plan | Alert; no preview |
| Storage error in the import | The preview stays, with the reason and Import enabled again; nothing was written |
| Chosen category deleted meanwhile | As a storage error, worded "That category no longer exists"; the choice is reset |
| The adult partition locks while the file is being read or planned | The result is dropped; nothing is presented |
| The adult partition locks while the sheet is open | RD18 dismisses presentations at a lock; the model goes with the workspace; a write that was running fails or completes as a whole |
| Entry with a bad, existing or repeated address | Skipped and listed; the rest imports |
| Export write fails | Alert; no share sheet |
| Refresh after import fails for some feeds | Ordinary source status, as after any refresh |

## Risk assessment

- The system parser on a hostile file: bounded by decision 2 and A3; residual risk stated.
- A long skipped list (up to 2,000 rows): a lazy list of plain rows.
- First refresh after a large import: up to 2,000 feeds at four at a time, every feed's current items arriving unread; the existing engine and its status line. No new mechanism.
- The share sheet and the Files picker are outside what UI tests see; both are checked by hand on a simulator (A1, A4, A6) and listed as device checks owed.
- Known and recorded, not built: an entry such as `https://github.com/Owner/Repo/releases.atom` in another reader's file is added beside an existing GitHub source of that repository, whose stored address is lower case; the owner deletes one of them.

## Test plan

Package: reader — folders, nesting three deep, feeds outside, attribute-name case, `type` absent, empty names, long names cut, a name of 160 kB of combining marks within a time bound, an address over the byte limit, an outline without `xmlUrl` inside a feed, a top-level block with children and no feed ignored, an empty top-level outline kept, every refusal of criterion 2 with its reason (each document-type shape of the measured table among them), criterion 3, exactly 2,000 and 2,001 feeds, exactly 500 and 501 folders, a file of exactly the size limit and one byte over through `read(contentsOf:)`, a byte-order mark, a Shift_JIS file read and a UTF-16 file refused. Writer — escaping, forbidden characters, empty category, order, no document type, output read by `OPMLReader`. Library — criterion 1's file against a library with a same-named category and an existing address; plan equals summary; same-named folders merged; `.existing` and `.named` targets (an existing name, a name of a folder in the file, a new name); target missing leaves nothing written; site address stored as given; round trip (criterion 7) with a `github` source and a site address without a trailing slash; two libraries (criterion 8); export excludes web pages.

UI (iPhone and iPad): import `folders` from Add source — preview numbers, choose an existing category, Import, summary, Done, the Library shows the categories and sources, and a source reaches a working status after the refresh; the same from Settings → Data with "New Category…", leaving the summary by a swipe (lists already reloaded, refresh starts); importing `folders` again shows the nothing-to-add state; Cancel changes nothing; `refused` shows the alert; Export is disabled in an empty library and presents the share sheet otherwise (A5). Screenshots: preview, picker, skipped list, summary, Data section — light and dark, English and Simplified Chinese, largest text size on iPhone.

By hand on a simulator (reported, not claimed for a device): choose a `.opml` and a `.xml` file in Files (A1); export, save to Files, import the saved file into an emptied library (A4); both in the adult partition (A6).

## Handoff notes

- RD20 (configuration file) should use the same category match (first existing category of an equal name, owner's order). It is not asked to share code.
- RD19 (adult isolation): the export's temporary file holds source addresses of the partition it came from; it is removed when the share sheet closes, before the next export and at launch. If RD19 lists temporary files to clear at a lock, this directory belongs on that list.
- RD26 (Hugging Face): its sources are not exported to OPML.

## For the owner

1. Importing does not check each feed. The feeds are added as they stand in the file and one refresh follows: up to 2,000 requests, four at a time, and every feed's current items arrive as unread. A dead feed shows afterwards as a failing source.
2. An entry whose address is not http or https (for example `feed://…`) is skipped and listed. The file is still imported.
3. A folder named exactly like one of your categories goes into that category instead of making a second one of the same name.
4. Export writes every category, also one with no feed, and import brings an empty folder back as a category. A top-level entry that holds only things that are not feeds (another reader's settings, plain links) is ignored. Web-page sources are not in the exported file.
5. A file that is not well-formed XML is refused with the line number; the app does not try to repair it. A file with any document type (`<!DOCTYPE …>`) is refused too — wider than "external entities are never resolved", and no known reader writes one.
6. Imported entries are always ordinary feeds. A GitHub source that you export and import again is collected as before but is shown as a feed, with the author's avatar on its rows. Moving between your own devices is the configuration file's job (RD20), which keeps the kind.
7. The exported file is named "NewsPaw Feeds <date>.opml" in both partitions; nothing in it says which partition it came from.
8. A library with more than 2,000 feeds or 500 categories would export a file that this app's own import refuses.

## Revision record

| Version | Date | Change |
| --- | --- | --- |
| 1 | 2026-11-15 | Draft for debate |
| 2 | 2026-11-15 | After debate round 1: the document type found in the bytes; site address stored as given; byte limits before character operations; imported kind always `feed`; reload at the write and refresh on any way out of the summary; which top-level outlines are folders, and at most 500; results dropped after a lock; `.named` target; the bounded read in the package; depth and element limits and one fixture removed; criterion 7's exclusions; three more owner items |

## Debate record

Round 1 (fresh critic, 2026-11-15; report and scripts in the run's evidence folder under `rd08/debate/`): verdict SOUND WITH CONCERNS, thirteen findings. Review cycle 1 of 6.

| # | Severity | Finding | Disposition |
| --- | --- | --- | --- |
| 1 | P1 | With external entities off the parser delivers no callback for an external entity, an external subset or a bare document type, so the designed guard never refuses them (measured) | Admitted: decision 2 step 3, criteria 2 and 3, A2 |
| 2 | P1 | `site_url` is stored as given today; storing a normal form on import breaks the round trip for a link without a trailing slash (`ParsedFeed.swift:163-170`) | Admitted: decision 4, criterion 5 |
| 3 | P2 | Names bounded in characters let megabyte names through; comparing and hashing them is quadratic (measured) | Admitted: decision 2 step 5, criterion 10 |
| 4 | P2 | The `github` kind on import leaned on a function RD07 does not have, changed the kind of a pasted feed address, and missed RD07's case rule | Admitted by removal: imported kind is always `feed` (gap 6, criterion 7, owner item 6); the case difference is recorded, not built |
| 5 | P2 | Reload and refresh happened only on Done; the summary can be swiped away | Admitted: decision 5, criterion 5 |
| 6 | P2 | Every top-level outline without `xmlUrl` became a category, settings blocks included, with no bound | Admitted: decision 1, decision 2 step 4 (500), owner item 4 |
| 7 | P2 | A result arriving after a lock could present a preview built from the adult library; picker and share sheet under the lock unknown; temporary file after a kill | Admitted: decision 5 (model owned by the workspace, late results dropped), A6, emptying at launch |
| 8 | P3 | A typed new name never matched a folder of the same file | Admitted: `.named` in decision 4 |
| 9 | P3 | The size check was in the app, where nothing can test it | Admitted: decision 3, decision 8 |
| 10 | P3 | What `StartTagScan.cutOffset` refuses was misdescribed | Admitted: decision 2 step 2 |
| 11 | P3 | Criterion 7 omitted what the reader's own rules change | Admitted: criterion 7, owner item 8 |
| 12 | P3 | Depth and element limits bound nothing measured; one fixture redundant; the stated reason against `ShareLink` was off | Admitted: limits and fixture removed, reason reworded |
| 13 | P3 | Three decisions missing from the owner list | Admitted: owner items 1, 5, 6 |
