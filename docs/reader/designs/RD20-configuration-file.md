# RD20 — Export and import the configuration file

Issue: [#141](https://github.com/AlvinShenSSW/NewsPaw/issues/141) · Epic E16 #119 · Requirements N10; spec section 4 (settings kinds), section 5 (the file); ux S11, S8 (Data), S6 (address step). Also touched: N02 (categories, the same address), N08 (model addresses, keys), N09 and spec section 4's "three operations touch both libraries" (partitions), N12 (untrusted files), N13 (offline tests).

Version 2 (2026-11-16), after one debate round (record at the end). Written against `main` at `8a6281c` (RD02, RD05, RD07, RD13 and RD18 merged), the RD14 worktree at `a6e2254` (title translation, not merged; it takes migration `v6`), the frozen RD08 design version 2 and RD08's worktree (OPML, being implemented). Names from RD08, RD14, RD19 and RD21 are the roles they play; the implementer reads the merged code first.

## Spec review

**What the baseline says.**

- N10: "Export produces a JSON configuration file (section 5), handed to the system share sheet … Contents: the global settings and each included partition's settings (section 4 says which settings are which), categories, sources, and the non-secret part of the model slots. The owner chooses whether to include the adult partition; that choice is available only while it is unlocked." "Not exported: keys, articles, read and starred states, translations, overviews, usage records, and the device settings of section 4."
- N10, import: preview first (counts; new, already present, in conflict), then "Merge" or "Replace everything". Merge works inside each partition; a category matches an existing category of the same name, the first in the owner's order when several share it; a source is matched by address and an existing one "is left exactly as it is … listed as already here, or as a conflict when the file files it differently or gives it different options"; "Merge fills empty model slots and leaves existing slots alone. Merge deletes nothing." Replace "applies only to the partitions the file contains … replacing the adult partition is possible only while it is unlocked"; it deletes categories and sources not in the file "with their articles, translations and overviews"; sources in both "keep their articles, reading state and translations and take the file's name, category and options"; "The file's settings replace the device's. A model slot takes the file's address and model; its stored key is kept only when the address is unchanged and is removed otherwise … Usage records are kept. Before anything changes, Replace lists every one of these effects … and asks a second time."
- N10, adult: "When the file contains the adult partition and it is off or locked on this device, the app asks to turn it on and authenticate before it builds the preview. Until that succeeds the adult library is not read and nothing in the file is compared with it. If the owner declines, the preview and the import cover the normal partition only, and the app says the adult part of the file was skipped."
- N10, after: "a model slot with no stored key … shows 'Key needed'; slots that kept their key stay configured. Importing never calls a model."
- N10, untrusted: "A higher version than the app supports is refused with a prompt to update the app; a lower one is upgraded before the preview. … its structure and field lengths are validated, source addresses must be http or https, and model service addresses must satisfy N08. A file is at most 5 MB with at most 500 categories and 5,000 sources, and these limits are checked before any preview is built. A file that breaks a rule is refused as a whole, with the reason, and changes nothing."
- N08: keys "never appear in the configuration file, logs, diagnostics or error text." Spec section 5 ends: "No keys and no reading state." Spec section 4: global settings (preferences, exported), partition settings (`setting`, exported with the partition), device settings (preferences, never exported); and "Three operations touch both libraries, and each requires the adult partition to be unlocked before the adult library is read or written: moving a category …, exporting a configuration that includes the adult partition, and importing or replacing one that includes it."
- ux S11: export is one switch "Include the adult partition", enabled only while unlocked, then the share sheet, with a note that keys are never included. Import: pick a file → authentication when the file includes the adult partition and it is locked (declining continues with the normal partition only) → preview sheet with counts, New / Already here / Conflicts, Merge or Replace everything; Replace shows what will be deleted and asks again; afterwards a summary and, when slots need keys, a link to Models & translation. ux S6 lists "Import configuration" on the address step of Add source; ux S8 lists Export and Import configuration under Data; ux S1 and S12 list "Import configuration" on Today's empty state and in the first run.

**What the code does today.** Nothing reads or writes a configuration file. `Settings › Data` holds the image cache only, with the comment "Export and import arrive with RD20". Global settings in `Preferences` on `main`: `refresh_minutes`, `retention_days`; RD14 adds `reading_locale`, `auto_translate_titles`, `show_original_titles` under exactly the file's names. Device settings in `Preferences`: `reading_text_size`, `reading_line_spacing`, `reading_typeface`, `adult_partition_on`, `adult_lock_timing`. The `setting` table holds `last_refresh_at` (state, not a setting) and, with RD14, `daily_automatic_limit`. Model slots: `model_slot` rows (`role`, `preset`, `base_url`, `model`, `key_ref`, `test_outcome`) whose keys live in the keychain of the slot's partition; the slot functions on `Library` (`modelSlots`, `saveModelSlot`, `deleteModelSlot`, `clearModelKey`) are package-internal, and `LibraryModels` pairs one library with a key store of the same partition by a precondition (RD13 decision 12). The adult library is reachable only through `AdultGate.unlock()`, and **the adult partition is unlocked exactly while it is shown**: unlocking shows the adult workspace, choosing Normal or any lock drops it and closes the adult library (RD18 decisions 4–5 and its post-implementation record); `AppModel.lock()` returns at once when no adult workspace is shown. The adult library has no `LibraryModels` until RD19; `AppModel.start()` makes the adult `KeychainKeyStore` and gives it to the gate. RD14 resumes the normal translator after a slot change through `WorkspaceParts.slotsChanged()`.

**Measured on 2026-11-16** with Foundation's `JSONDecoder` on this Mac (macOS 27.0.1, `swiftc -O`), by this author (scratch folder `rd20-design/probe.swift`) and again by the critic (run evidence `rd20/debate/critic-r1-probe-output.txt`), not on an iOS simulator:

| Input | Result |
| --- | --- |
| `{"a":1,"a":2}`, also with a second value of another type | Decoded, first value wins; no error |
| `true` where an `Int` is read; `1` where a `Bool` is read | Type mismatch |
| `1.0`, `1e2`, `-0` where an `Int` is read | Decoded as 1, 100, 0 |
| `1.5`, `9223372036854775808` (2^63), an integer of 30 digits, where an `Int` is read | "Not valid JSON" (data corrupted), not a type mismatch |
| An integer of 30 digits in a member the type does not read | Decoded; the member is ignored |
| `"schema_version": 1.0`; `"schema_version": "1"` | Read as 1; type mismatch |
| A lone surrogate escape; text after the object | "Not valid JSON" |
| A top-level array | Type mismatch with an empty coding path |
| `"a\u0000b"` | Decoded with the NUL character |
| `null` for an optional member | Read as absent |
| A byte-order mark before the object | Decoded |
| 511 nested arrays inside the top object; 512 or more, up to 1,000,000 | Decoded; "not valid JSON", in under 1 ms |
| 3.6 MB holding 1.2 million empty objects in a member the type does not read | Decoded in about 30 ms |

**Gaps and contradictions, and what this design decides** (each is in Approach; those the owner would notice are repeated under "For the owner"):

1. *"Address unchanged" for a kept key.* N10 keeps a key "only when the address is unchanged"; RD13's handoff to RD20 says "only when its origin is unchanged". Decided: the specification's rule — the key is kept only when the file's address, in `ModelAddress` normal form, equals the stored one. It is the stricter reading and what the issue's acceptance criterion tests; the cost is a key typed again.
2. *Settings under Merge.* N10 says what Replace does with settings and nothing about Merge. Decided: Merge does not change settings; the settings that differ are listed under Conflicts, and Replace replaces them as N10 says. Merge's rule is then one rule for everything that already exists here: it is left as it is.
3. *A slot the file does not have, under Replace.* Not stated. Decided: removed, with its key, and listed among the effects. "Replace everything" makes the slots of an included partition what the file says.
4. *Kind under Replace.* N10 lists "name, category and options"; RD07 keeps changing a source's kind a non-goal. Decided: Replace keeps the device's kind; a source whose kind differs is listed as a conflict.
5. *Same-named categories under Replace.* N10's matching rule ("the first in the owner's order") is written for Merge; applied to Replace it folds two same-named categories of the file into one. Decided: Merge uses N10's rule exactly (RD08 does the same); Replace pairs them in order — each file category takes the first same-named existing category no earlier file category took — so that a Replace reproduces the file.
6. *The "lower version".* Version 1 is the first; nothing is lower. Decided: a value below 1 is refused as not a configuration file; the decoder dispatches on the version with one case, and the issue that defines version 2 adds the step that upgrades a version-1 document before validation.
7. *How a later setting or member joins the file.* Section 5 is a sample. Decided (Approach 2): `settings` and `partition_settings` are typed structures with one optional member per setting; a member this version does not know is ignored, a known one that is absent leaves the device's value as it is. `schema_version` changes only when a member is removed, renamed, changes type or meaning, or a setting moves between kinds.
8. *A partition-setting name.* Section 5 writes `daily_auto_limit`; RD14 stores the limit under the `setting` key `daily_automatic_limit`. Decided: the file uses the specification's name as the member's name; RD14's key and value rule store it. No data changes.
9. *Settings that do not exist yet.* Section 4 lists `background_refresh` (RD24), `translate_body_on_open` (RD15) and `list_thumbnails` (RD19) as exported settings; none exists in the code. Decided: each becomes a member with its issue (handoff notes); until then this version neither writes nor reads it.
10. *Unlocked means shown.* Under RD18 the adult partition is unlocked only while it is on screen. Decided: export with the adult partition is possible only from inside it; an import whose file contains it, started from the normal partition, switches into the adult partition through the partition switch's own unlock and builds its preview there. RD20 adds no gate operation and relies on none from RD19. This is the one mechanism the driver set for both issues: an operation that needs the adult library and starts in the normal partition is "unlock and switch, with a pending operation handed over by `AppModel`" — `.move(categoryID)` for RD19, an import case for RD20; whichever of the two is implemented first builds the hand-over and the second adds its case.
11. *"Turn it on and authenticate".* RD18's `turnOn` authenticates and leaves the partition locked; `unlock` authenticates again. Decided: when the partition is off the app calls both, so the owner answers two prompts; the gate is not changed.
12. *Web pages and "paused".* Section 5's sample writes `"paused": false` for a web page; RD05 forbids pausing one. Decided: written as `false`, ignored on import.
13. *Limits per file or per partition.* Decided: per file, both partitions together (500 categories, 5,000 sources). The export refuses to write a file this app would refuse to import.
14. *Further entry points.* ux S2 puts "Import" in Library's "+" menu; RD08 did not add one. Decided: not added — Add source, one tap from that menu, has the row. ux S1 (Today's empty state) and S12 (the first run) are added by whichever of RD20 and RD21 merges second. An import started from the first run brings the normal partition only (driver's decision, F9): no question about the adult partition is asked there.
15. *Hugging Face sources.* `huggingface` has been in the closed set since `v1`; nothing creates one before RD26. Decided: imported and exported like any source; until RD26 such a source is listed and not collected.

## Acceptance criteria

1. **Round trip.** A package test fills two libraries (both partitions; categories with icons, overview modes and an order; feed, GitHub and web-page sources with non-default options; a paused source; primary and backup slots with keys in the in-memory key stores; every exported global and partition setting set to a non-default value), exports, and imports the file into an empty store with fresh preferences, once by Merge and once by Replace. Both give, per partition, the same categories (name, icon, overview, order), the same sources (address, name, kind, category by name, options) and the same slots (preset, address, model; no key reference, no Test result). Replace also gives the same settings; Merge leaves the target's settings unchanged and its preview listed the differing ones under Conflicts. Device settings and `last_refresh_at` of the target are unchanged either way.
2. **No secret, no device setting.** With sentinel keys stored for all four slots, the exported bytes contain none of the key strings, none of the `key_ref` values, no Test result, and no member named after a device setting or `last_refresh_at`, also when every device setting holds a non-default value. A source scan finds every `static let …Key = "…"` constant of the package's sources to be either a coding key of the settings structures or on the not-exported list, exactly once; its failure message states that rule. An unclassified key fails it (planted once).
3. **Validation before anything.** Each of these files is refused, with its reason, before any library is read, and changes nothing: larger than 5 MB (refused before more than the limit plus one byte is read); not JSON; a top-level array or other non-object (both "not a configuration file"); nested 512 deep; no `schema_version`, or `schema_version` `1.5` or `"1"`; `schema_version` 2 ("update the app"); `schema_version` 0; `1.5` or 2^63 in an integer member such as `sort_order` ("not a configuration file", as the decoder reports it); 501 categories; 5,001 sources; a name empty after cleaning, or over its byte or character limit; an address over its limit, not http or https, with a user name, or without a host; a model address that is `http` (also in a debug build, also to loopback), has a query, or is malformed; a model name over its limit; an unknown kind, overview, option value, preset, role or partition; a known setting with a value outside its set; a source naming a category that is not in the file; two categories with one identifier; one address twice in one partition; two slots for one role and partition; a backup without a primary; an adult entry while `includes_adult` is false. Exactly 5 MB, 500 categories and 5,000 sources are accepted, and a test records that `"schema_version": 1.0` is accepted as 1.
4. **Preview, then Merge.** Into a library that already holds some of the file: the preview shows per partition the counts and the New, Already here and Conflicts groups (a conflict names what differs), and the settings and models that differ; nothing is written until Merge. Merge adds only what is new, deletes nothing, fills empty slots, and leaves every existing source, category, slot and every setting exactly as it was (compared row by row and value by value); the summary lists what was already here.
5. **Same-named categories.** With two existing categories named alike, Merge files the file's category of that name into the first in the owner's order, on every run, also after the second one is moved before it and back.
6. **Replace.** Replace shows a review of every effect — categories and sources deleted with their names and counts, articles deleted with the number of starred among them, sources changed, slots removed, keys removed and settings replaced — then asks a second time; nothing changes before the second answer. Afterwards each included partition holds exactly the file's categories in the file's order and the file's sources; sources in both kept their articles, read and starred times, bodies and translations; the file's settings are in effect; usage rows are untouched.
7. **Keys under Replace.** A slot whose address differs from the file's loses its key (row reference cleared, keychain item removed), and the review listed that key; a slot whose address is equal keeps its key and stays configured; a slot the file does not have is removed with its key. Afterwards every slot without a usable key shows "Key needed".
8. **The partition the file does not contain.** Replace with a normal-only file, started inside the adult partition, leaves every row of every table of the adult library identical (compared by a full dump before and after).
9. **Declining the adult partition.** From the normal partition, a file with the adult partition asks first. Declining, cancelling or failing the authentication builds the preview and imports the normal partition only, and the preview and the summary say the adult part was skipped. Package test: on that path the adult library is never opened — its file's bytes are unchanged and no `-wal` or `-shm` file appears. App: after declining, and after a discarded unlock, the normal workspace's model holds a document with no adult entry and `AppModel` holds none. UI test: the debug report reads `pool=closed` throughout.
10. **Accepting it.** From the normal partition with the adult partition locked, "Unlock" authenticates once, shows the adult partition, and the preview covers both partitions; with the partition off, "Turn On and Unlock" authenticates twice and does the same. From inside the adult partition no question is asked.
11. **Export.** Settings › Data has Export Configuration and Import Configuration. "Include the Adult Partition" is hidden while the adult partition is off or unavailable, shown disabled and off in the normal partition while it is on, and enabled (off by default) inside the adult partition. The file is named `NewsPaw Configuration <yyyy-MM-dd>.newspaw` whatever it contains, reaches the share sheet, and its temporary copy is removed when the sheet closes, before the next export, at launch, and at every lock. A library over the file's limits is refused with the reason and no file is written.
12. **Atomic per partition.** With a SQLite trigger planted on a test library that aborts the insert of one source, an import into that partition writes nothing in it; with the trigger on the normal library and a file with both partitions, the adult partition is imported, the normal partition and the global settings are unchanged, and the summary says so. Cancelling the preview, the review or the second question changes nothing.
13. **A lock during the write.** Package test: with the adult library closed by the store's lock path while the adult transaction runs (a test hook holds the transaction), the adult transaction commits, the normal partition and `Preferences` are written, and the completion handed in is called once after them — the step that in the app reloads the normal workspace, re-reads the shared settings objects and calls `slotsChanged()`. Closed before the adult transaction begins: nothing is written and the completion reports it.
14. **No request.** Reading, previewing and importing make no network request and no model request (a transport and a model stand-in that count requests stay at zero). The ordinary refresh starts only when the summary is left.
15. **Versions.** A version-1 file without some setting member leaves that setting as it is here under Replace; a member this version does not read is ignored and changes nothing.
16. **First run** (when RD21 has merged). An import started from the first run with a file that holds both partitions asks no question about the adult partition, imports the normal partition only, and its summary says in one line that the file's adult partition was not imported and can be imported from Settings › Data.
17. **Interface and checks.** Every new string has an English base and a Simplified Chinese translation; the three checks of `AGENTS.md` pass; the preview, the review, the question, the summary and the Data section are captured in light and dark, English and Simplified Chinese, and at the largest text size on iPhone, with every label uncut.

## Frozen issue contract

**In scope:** the file's reader, validator and writer, with the typed settings structures and the not-exported list, in the package; the snapshot, plan and import transaction on `Library`; the export and import coordinators over one `(Library, KeyStore)` pair per partition and `Preferences`; the Configuration section of Settings › Data; the "Import Configuration" row of Add source; the import flow (file picker, refusal, the adult question, preview, review before replacing, second question, summary); the completion step owned by `AppModel`; the share-sheet export; emptying the export directory at launch and at a lock; the `.newspaw` exported type; debug fixtures for UI tests; strings; tests; the spec sentences listed under Files.

**Out of scope:** sync of any kind; exporting keys, Test results, articles, reading state, translations, overviews, usage, source status, validators or site addresses; encryption of the file; opening a `.newspaw` file from another app or from AirDrop directly into NewsPaw ("Open in"); choosing which entries of a file to import; editing conflicts one by one; changing a source's kind; a third entry point in Library's "+" menu; a `LibraryModels` for the adult library; any gate operation; the adult partition's model screens (RD19); settings that do not exist yet (their issues).

**Shared with RD19:** the pending-operation hand-over on `AppModel` (decision 7); whichever of RD19 and RD20 is implemented first builds it, and the second adds its case.

**Shared with RD21:** whichever of RD20 and RD21 merges second adds the "Import Configuration…" rows to the first run (ux S12) and to Today's empty state (ux S1), both calling this issue's import entry with the origin of decision 8.

**What other issues own:** RD08 — OPML, and the share sheet, bounded read and emptying at launch this issue reuses. RD14 — its three global settings and the daily limit (members added here if RD14 has merged, else by RD14). RD15, RD19, RD24 — `translate_body_on_open`, `list_thumbnails`, `background_refresh`. RD19 — the adult partition's `LibraryModels`, its slot screens and the link to them from the summary. RD22 — the AirDrop check on two devices.

**Requirement map:** N10 → criteria 1–16. N08 → 2, 3, 7. N09 and spec section 4 → 8–11, 13, 16. N12 → 3, 14. N13 → 14, 17.

**Invariants.**

- No key, key reference, Test result or device setting is ever written to the file; nothing from the file is ever written to the keychain.
- The file is validated as a whole before any library is read; a library is written only after the owner chose Merge, or Replace and confirmed twice.
- The adult library is read or written only by a workspace that holds it because the partition is unlocked and shown, and by the write task that workspace started after the owner's confirmation; no path reads it before a passed authentication, and no gate operation is added.
- Every function added to `Library` works on that library alone; each partition's library and key store are paired by the precondition `LibraryModels.init` has.
- Nothing in the file is followed, fetched or executed; no request is made by export or import.
- Offline tests make no external request and use the in-memory key store.

## Assumptions

Each is checked by the implementer before the code that depends on it and reported in the hand-back.

| Assumption | If it does not hold |
| --- | --- |
| A1. The measured table holds in the iOS 26.5 package suite and in the iOS 27 simulator for the rows the reader relies on: the depth refusal at 512, the `Bool`/`Int` type mismatch, the "not valid JSON" answer to over-long or fractional integers and to lone surrogates. The package tests of criterion 3 are the check | If a deep file crashes or stalls anywhere, add a string-aware byte scan that refuses nesting deeper than 64 before decoding, and report it |
| A2. With an exported type declaration for `.newspaw` (`io.newspaw.reader.configuration`, conforming to `public.json`) in `NewsPaw-Info.plist`, `.fileImporter(allowedContentTypes: [configuration, .json])` lets a `.newspaw` file be chosen in Files on the iOS 27 simulator | Widen to `.data` and rely on the reader's refusal; record which was needed |
| A3. The workspace root's `.fileImporter` and RD08's importers (attached at Add Source and Settings › Data) each present when asked, in both structures; closing Add Source and then presenting the picker from the root works without a delay the owner notices | Merge them into one importer at the workspace root whose allowed types and destination follow the row tapped, and tell the driver (RD08's code changes) |
| A4. As RD08's A4 and A6: a file URL in a directory of the temporary directory handed to the share sheet offers Save to Files and AirDrop; the saved file can be imported again; neither the picker nor the share sheet locks the adult partition | Report; the driver decides |
| A5. After the file picker closes, the system's authentication prompt can be shown at once, and two prompts in a row (turn on, then unlock) both appear | Wait for did-activate before the first prompt; report |
| A6. An AirDropped `.newspaw` file of a type no app opens is offered for saving in Files on the receiving device | Device check only (the simulator has no AirDrop); the pull request lists it as not done until the owner tries it |

## Approach

**1. The file, version 1.** UTF-8 JSON, one object, `schema_version` 1, written by `JSONEncoder` with sorted keys, pretty printing and slashes unescaped; times as ISO 8601 UTC with whole seconds. The members this version writes and reads (required members in bold; an optional member that is absent takes the default shown):

| Where | Member | Rule on import | Default |
| --- | --- | --- | --- |
| top | **`schema_version`** | integer; 1 decoded; above 1 refused as newer; below 1 refused | — |
| top | **`exported_at`** | ISO 8601 date, at most 64 bytes | — |
| top | **`app_version`** | 1–64 printable ASCII characters | — |
| top | **`includes_adult`** | Boolean | — |
| top | **`settings`** | object; decision 2 | — |
| top | **`categories`** | array, at most 500 | — |
| top | **`sources`** | array, at most 5,000 | — |
| top | **`partition_settings`** | array, at most 2, one per included partition | — |
| top | **`model_slots`** | array, at most 4 | — |
| category | **`id`** | UUID text, unique among the file's categories | — |
| category | **`name`** | category name rule after cleaning (decision 3) | — |
| category | **`partition`** | `normal` or `adult`; `adult` only when `includes_adult` | — |
| category | `sort_order` | integer | position in the file |
| category | `icon` | 1–64 characters of `a`–`z`, `0`–`9`, `.`; a name this version does not know is stored as given and shows as `folder` (RD02) | `folder` |
| category | `overview` | `auto`, `manual`, `off` | `auto` |
| source | **`id`** | UUID text | — |
| source | **`category_id`** | the `id` of a category in the file; the source belongs to that category's partition | — |
| source | **`kind`** | `feed`, `github`, `huggingface`, `webpage` | — |
| source | **`name`** | source name rule after cleaning | — |
| source | **`url`** | at most 8,192 bytes; `SourceAddress.parse(_, addingScheme: false)` succeeds (http or https, a host, no credentials, at most 2,048 characters); stored as its normal form; unique per partition | — |
| source | `paused`, `auto_translate`, `body_mode` | Boolean; `inherit`/`on`/`off`; `auto`/`page`/`feed`; read for feed-like kinds, ignored for a web page | `false`, `inherit`, `auto` |
| source | `translate_page` | Boolean; read for a web page, ignored otherwise | `false` |
| partition settings | **`partition`** | an included partition, once | — |
| partition settings | setting members | decision 2 | — |
| model slot | **`partition`**, **`role`** | an included partition; `primary` or `backup`; once per pair; a backup only beside a primary of its partition | — |
| model slot | **`preset`** | one of RD13's seven | — |
| model slot | **`base_url`** | at most 8,192 bytes; `ModelAddress.normalise(_, allowsLoopbackHTTP: false)` succeeds — https only in every build (RD13 handoff) | — |
| model slot | **`model`** | at most 1,024 bytes; `ModelName.validate` succeeds | — |

Every file contains the global settings and the normal partition, possibly empty (a Replace then empties it, after the review says so); it contains the adult partition exactly when `includes_adult` is true, also when that partition is empty. Every other member is ignored, whatever it holds — a member called `key` included: nothing in the file is ever written to the keychain. The export writes every member above for every entity (a web page's `paused` as `false`, as in section 5's sample), category `sort_order` as 0, 1, 2… per partition in the owner's order, sources by category order and then by name as `sourceSummaries` orders them. It writes no `site_url`: nothing in the app reads it today and collection does not restore it. Identifiers in the file are the library's; on import, created rows get new identifiers (matching is by name and address, never by identifier).

**2. Settings: typed structures and the not-exported list (package).** `settings` decodes into one `Decodable`/`Encodable` struct with one optional member per global setting, and each `partition_settings` entry into one struct with `partition` and one optional member per partition setting. The export fills every member from the existing typed accessors (`Preferences.refreshInterval`, `.retention`, RD14's `.readingLocale`, `.autoTranslateTitles`, `.showOriginalTitles`; RD14's `Library.dailyAutomaticLimit()`), writing the value in effect. The import validates a present member against the accessor's set (a value outside it refuses the file), and Replace applies it through the same typed setter (`Preferences`' setters; for the daily limit, RD14's statement run inside the partition's transaction — RD14's `setDailyAutomaticLimit` and the import share one function of a `Database`). An absent member leaves the device's value as it is; a member this version does not know is ignored by the decoder. Members:

| Member | Kind | Values | Typed accessor | Present when RD20 is implemented |
| --- | --- | --- | --- | --- |
| `refresh_minutes` | global | 0, 15, 30, 60 | `Preferences.refreshInterval` | yes (RD06) |
| `retention_days` | global | 0, 7, 30, 90 | `Preferences.retention` | yes (RD06) |
| `reading_locale` | global | `zh-Hans`, `en`, `ja` | `Preferences.readingLocale` | if RD14 has merged |
| `auto_translate_titles` | global | Boolean | `Preferences.autoTranslateTitles` | if RD14 has merged |
| `show_original_titles` | global | Boolean | `Preferences.showOriginalTitles` | if RD14 has merged |
| `daily_auto_limit` | partition | integer 0–100,000 | RD14's limit (`setting` key `daily_automatic_limit`) | if RD14 has merged |
| `translate_body_on_open` | global | Boolean | — | RD15 adds the member |
| `background_refresh` | global | Boolean | — | RD24 adds the member |
| `list_thumbnails` | partition | Boolean | — | RD19 adds the member |

The not-exported list names the device settings (`reading_text_size`, `reading_line_spacing`, `reading_typeface`, `adult_partition_on`, `adult_lock_timing`; later the default display mode of RD15 and any stored image-cache size limit) and the `setting` state keys (`last_refresh_at`). A package test scans the package's sources for `static let …Key = "…"` and requires every value to be a coding key of the two settings structures or on that list, exactly once; its failure message says: "a stored key named …Key must be exported (a member of the configuration's settings) or listed as not exported" (criterion 2). Keys not named `…Key` are not seen; the naming convention is the rule.

How a setting added later joins: its issue adds one optional member, one line in the export and one in Replace's apply (and the preview's list of differing settings), or one entry on the not-exported list. The file's format, `schema_version` and the rest of this issue's code do not change. An older app ignores the new member in a newer file; a newer app reading an older file leaves the new setting as it is. Version policy, written beside the version constant: a new optional member keeps version 1; removing or renaming a member, changing its type or meaning, or moving a setting between kinds raises it. A closed-set value an older version does not know is refused by that version with "A value is not one this version of NewsPaw knows" and does not need a version change.

**3. Reading (`ConfigurationFile.read(contentsOf:)` and `read(_ data:)`, package, no store, no network).** In this order, each stopping with a `ConfigurationRefusal` that carries no part of the file:

1. Size: the bounded read RD08 built for OPML (in RD08's worktree, `OPMLReader.boundedRead`) — the size from the resource values, refused above 5 MB (`5 * 1024 * 1024`) without reading; read up to the limit plus one byte, refused if that byte is there. If RD08 has merged, RD20 calls it, moving it to a shared file in `Config/` only as a move without change; if RD08 has not merged, RD20 writes the same read in its own reader and whichever merges second makes the two one.
2. `JSONDecoder` into the wire types, every member optional. Mapping: a `typeMismatch` at a non-empty coding path of a member the reader reads → `invalid(.wrongType, at:)`; everything else — data corrupted (also `1.5` or 2^63 in an integer member, which the decoder reports this way), a type mismatch with an empty path (a top-level array or other non-object) → `notAConfiguration`.
3. `schema_version` (decision 1's rule).
4. Counts: categories, sources, partition settings and slots, before any member is looked at.
5. Byte limits on every string before any character operation (names 4,096 bytes, addresses 8,192, model names 1,024, the rest as in decision 1), then cleaning of names — control characters (Unicode category Cc) removed, then trimmed — then the app's own rules (`Library.categoryNameProblem`, `sourceNameProblem`, `SourceAddress`, `ModelAddress`, `ModelName`), the closed sets and the settings' sets.
6. Cross-checks: identifiers, references, the partition of each source, duplicates per partition, slot pairs, `includes_adult` against the entries.

The result is a `ConfigurationDocument`: the version, export time, app version, the global settings, and per partition the categories, sources, slots and partition settings, all typed and normalised, with `withoutAdult` giving the same document without its adult part. A refusal has a reason and, for an entry, which list and which position (1-based) — "source 12" — never its text. Version 1 is the only case of the dispatch on `schema_version`. A duplicate member name is accepted silently with its first value (measured); that is harmless here because the preview and the write use this one decoded document and the file is never read again.

**4. Planning (package, pure).** `ConfigurationPlan.make(document part, snapshot, mode)` for one partition, where the snapshot is one read of that library (`Library.configurationSnapshot()`: categories in the owner's order; every source's identity, address, kind, name, category and options; the article count and starred count per source; the slot rows; the partition settings). The preview and the import run this same function, the import inside its own write transaction over a fresh snapshot, so the summary is what the transaction did.

- *Categories, Merge:* each file category in file order matches the first existing category of an equal name in the owner's order; else it matches a category this import creates for an earlier file category of that name; else it is created after the existing ones, in file order, with the file's icon and overview. Existing categories are not changed.
- *Categories, Replace:* file categories in their order (sort order, then position); each takes the first existing category of an equal name not taken by an earlier one, which then takes the file's icon, overview and place; the rest are created. Existing categories not taken are deleted. The partition's order becomes the file's.
- *Sources:* matched by normal form, exactly, against every source of the library. New → created in its mapped category, kind and options from the file, no status, no articles. In both: *already here* when name, mapped category, kind and the options of its kind are equal; otherwise a *conflict* that names what differs (name, category, kind, options). Merge leaves both as they are. Replace gives a matched source the file's name, category and the options of the device's kind, keeps its kind, articles, reading state, bodies, translations, validators and status; and deletes every source of the partition the file does not have, with its articles, bodies, seen identifiers and translations (the cascades).
- *Slots, per role:* Merge fills a role that is empty here (no key: "Key needed", "Not tested") and leaves an existing one; a file backup is filled only if a primary exists here or is filled by the same import. Replace writes the file's preset, address and model; the key reference stays only when the normal-form address is equal, and the Test result only when address, model and key all stay; a role the file does not have is removed with its key. Equal / new / differing are the preview's already here / new / conflict.
- *Settings:* a present member whose value differs from the value in effect here is a conflict; an equal one is already here. Merge writes none. Replace writes every member the file has.

**5. Writing (`ConfigurationTransfer.importDocument`, package).** Takes the document, the mode, `Preferences`, a completion, and for each partition it may write one `ConfigurationTarget` — that partition's `Library` and `KeyStore`, checked by the precondition `LibraryModels.init` has. A partition the file contains but that has no target here (adult declined or unavailable) is skipped, structurally: the function never sees that library. `LibraryModels.swift` is not changed; slot rows are written inside the import's transaction through the package-internal slot functions of `Library+Models.swift`. In this order:

1. The adult partition, when included: plan from a fresh snapshot and, in one write, create and update categories, insert and update sources, delete sources, delete categories, rewrite the order, write slot rows (primary before backup, backup removed before primary), write partition settings (Replace). If RD14 has merged, a changed slot also runs its `deleteFailedTranslations` statement in that transaction, as a slot save does. Then the keychain items of references the transaction cleared or whose slot it removed are removed through the adult key store (a failure is ignored). The task then lets go of the adult target and the adult part of the document.
2. The normal partition's transaction, the same way.
3. The global settings (Replace), only after step 2 committed (every file contains the normal partition, so step 2 always runs).
4. The normal partition's keychain removals.
5. The completion, once, with the summary or the failure: what was written, per partition.

Rows before items is the reverse of RD13's order for removing a key; it is chosen because the database steps are all-or-nothing and a key whose row no longer names it is never read or sent (RD13 decision 3 accepts such an orphan). **What partial state is possible:** each partition is all or nothing. If the adult transaction committed and the normal one then failed, the adult partition is imported and the normal partition and global settings are unchanged; the summary says exactly that. A keychain item can survive its removal, invisible and unused. An app ended between steps leaves one of these two states. Nothing else.

**6. Exporting (`ConfigurationTransfer.export`, package).** Takes the normal partition's target, the adult partition's or none, `Preferences`, the app version and the clock; reads each library once and never its key store; refuses with `tooLarge` when the categories exceed 500, the sources 5,000, or the encoded file 5 MB; returns the bytes.

**7. The adult partition (app).**

- *Targets.* The normal target is the normal library with the normal `KeychainKeyStore` `AppModel.start()` already makes. `AppModel` keeps the adult `KeychainKeyStore` it makes for the gate and, when it builds the adult workspace at unlock, gives the adult library and that store to the adult workspace's `ConfigurationModel` as its adult target. If RD19 has merged, the pair is taken from the adult workspace's own models instead. The normal workspace never holds an adult target.
- *Export.* Settings › Data's switch "Include the Adult Partition" is hidden while the gate is off or unavailable; in the normal partition while the gate is on it is shown disabled and off, with the footnote "To include the adult partition, export from inside it."; inside the adult partition it is enabled and off each time the screen opens. So a file exported from the normal partition contains nothing of the adult partition — not a name, a count or `includes_adult: true`; a file exported from the adult partition always contains the normal partition and the global settings, and contains the adult partition only with the switch on.
- *Import.* The file is read and validated in the workspace where the import began. If the document contains the adult partition and that workspace is the normal one: with the gate unavailable, or when the import began in the first run (decision 8's origin), the adult part is dropped at once; otherwise an alert asks — title "This file also contains the adult partition.", buttons "Unlock" (gate locked) or "Turn On and Unlock" (gate off), "Normal Partition Only", Cancel. The question names no adult content. On Unlock the hand-over is a **pending operation on `AppModel`**, shared with RD19: the partition switch's own unlock is called with it (`chooseAdult(pending:)`, after `turnOnAdult()` when the gate is off), and the pending operation is `.importConfiguration(document)` here (`.move(categoryID)` is RD19's case). The normal model **moves** the document into that case and keeps no reference to it, and the call **returns the unlock's outcome**. On `.unlocked`, `AppModel` hands the pending operation to the adult workspace once it is shown; that workspace's `ConfigurationModel` takes the document and presents the preview from its root, and `AppModel` keeps nothing. On every other outcome — refused, cancelled, failed, interrupted, discarded, busy, could not open, or turning on refused — `AppModel` drops the pending operation and returns only `withoutAdult` to the normal model, which builds the normal-only preview; after a `couldNotOpen`, the preview opens only once RD18's notice is dismissed. So nothing adult is kept in an object that outlives a lock: `AppModel` holds the pending operation only while the unlock runs, and the normal workspace never holds the adult part after the question is answered. Whichever of RD19 and RD20 is implemented first builds this hand-over (the `pending` parameter, the enum, the hand-to-the-shown-workspace step, the drop on every other outcome); the second adds its case. "Normal Partition Only" also keeps only `withoutAdult`. Cancel drops everything. If the document contains the adult partition and the import began inside it, nothing is asked.
- *Locking and the completion.* The preview, review and summary of an import with the adult partition belong to the adult workspace, so a lock removes them with the shell (RD18). Once the owner has confirmed, the write task is not cancelled by `Workspace.stop()`: it runs to its end. Its completion is a closure `AppModel` hands to the `ConfigurationModel`, run on the main actor, whether or not the adult workspace still exists: it always reloads the normal workspace (categories, sources, model settings), makes the shared `RefreshSettings` (and RD14's `TranslationSettings`, if merged) re-read `Preferences` so that a changed value acts as a change made in Settings, and calls `WorkspaceParts.slotsChanged()` (RD14, if merged); it reloads the adult workspace only if that workspace is still the one shown, and only then is the summary shown. If the lock closed the adult library before the adult transaction began, that transaction fails and the import stops before the normal one: nothing is written. The refresh the lock starts (`normal.refresh.entered()`) may run beside the normal transaction; that is the failure table's case of a source deleted while a refresh collects it. The export directory is emptied at every lock.

**8. The import flow (app).** `ConfigurationModel` (`@MainActor @Observable`, one per workspace, owned by it): the export state (switch, writing, the file URL, an error) and the import stage — reading → asking about the adult partition → preview → review before replacing → importing → summary, or refused / failed — and the import's origin (`settings`, `addSource`, `firstRun`). Its UI is one modifier at the workspace root: the file importer, the refusal alert ("Could not import this file" with the reason sentence), the adult question, and the preview as the root's single sheet (`AppSheet.configurationImport`, so RD05's one-sheet rule holds). This root presenter is RD20's own choice, made for the hand-over across an unlock (the preview has to appear at the adult workspace's root); it differs from RD08's modifier attached at each entry point, which presents OPML's picker and preview over Add Source. So on Add Source's address step, "Import OPML" opens over the sheet while "Import Configuration" closes Add Source and starts this flow from the root; Settings › Data starts it in place. The preview sheet has its own navigation stack:

- Header: "Exported ⟨date⟩ by NewsPaw ⟨version⟩"; "The adult partition in this file was skipped." when it was (in the first run, "The file's adult partition was not imported. You can import it from Settings › Data.").
- Per included partition ("Normal" / "Adult"): "⟨n⟩ categories · ⟨m⟩ sources", then rows New (k), Already Here (k), Conflicts (k), each pushing a plain lazy list of categories, sources and models (a conflict's second line says what differs). A "Settings" row pushes the settings that differ, with this device's value and the file's, footnoted "To take the file's settings, use Replace Everything."
- Merge and Replace Everything. Merge is disabled, with "Everything in this file is already here.", when it would write nothing. Under Conflicts: "Merge keeps these as they are on this device."
- Replace Everything pushes "Before Replacing": per partition, the categories deleted (names), the sources deleted (count, pushing their names), "⟨n⟩ articles, ⟨s⟩ of them starred", sources changed, models removed, keys removed (by partition and role), settings replaced; "Only the normal partition is replaced." when the adult one is not included; then "Replace" → alert "Replace now?" / "This cannot be undone." → Replace or Cancel.
- Summary: per partition, categories and sources added, changed and deleted; the adult part skipped or not imported; "⟨n⟩ models need a key." with "Set Up Keys" opening Models & Translation for the normal partition (the adult partition's link is RD19's); the partial state of decision 5 when it happened; Done. The sheet cannot be swiped away while importing. Leaving the summary by Done or a swipe starts the ordinary refresh (`RefreshModel.refresh(.library)`) of each workspace whose library was written and that still exists.
- A storage failure keeps the preview with the reason and its buttons enabled again; nothing of that partition was written.

**9. Export flow (app).** "Export Configuration" builds the bytes off the main actor, writes `NewsPaw Configuration <yyyy-MM-dd>.newspaw` into `tmp/Configuration/` (emptied first), and presents RD08's share sheet (a `UIActivityViewController` representable, `Settings/ShareSheet.swift` in RD08's worktree) for it; its completion empties the directory. The directory is also emptied at launch, beside RD08's OPML export directory, and at every lock (decision 7). The file name and the share sheet name no partition. Footnote of the section: "Categories, sources, settings and models, for your other devices. Keys are never included." With the switch on, a second footnote: "The file is not encrypted: anyone who has it can read the adult partition's categories and sources."

**10. UI tests cannot drive the Files picker or the share sheet.** A debug launch key of its own (`NEWSPAW_UITEST_CONFIGURATION_FIXTURE`, a `ConfigurationFixture` type beside RD08's OPML fixture type, following its pattern) names one of three configuration fixtures built in debug-only code: `both` (normal and adult partitions, a slot on the fixture model host, sources the fixture transport answers), `normal`, `refused` (an `http` model address). Under a UI-test library directory "Import Configuration" writes the named fixture to a temporary file and hands it to the same reader instead of presenting the picker. Release builds contain none of it.

**11. Wording** (English · Simplified Chinese). Reused: Cancel, Done, OK, Normal · 普通, Adult · 成人, the settings' own row titles, "Key needed".

| English | 简体中文 |
| --- | --- |
| Configuration (section) | 配置 |
| Export Configuration | 导出配置 |
| Import Configuration | 导入配置 |
| Include the Adult Partition | 包含成人分区 |
| Categories, sources, settings and models, for your other devices. Keys are never included. | 分类、来源、设置和模型，用于你的其他设备。Key 永远不会包含在内。 |
| To include the adult partition, export from inside it. | 要包含成人分区，请在成人分区里导出。 |
| The file is not encrypted: anyone who has it can read the adult partition's categories and sources. | 文件没有加密：拿到文件的人都能看到成人分区的分类和来源。 |
| The configuration could not be exported. | 无法导出配置。 |
| Your library has more than 500 categories or 5,000 sources, which a configuration file cannot hold. | 资料库的分类超过 500 个或来源超过 5,000 个，配置文件无法容纳。 |
| Could not import this file | 无法导入这个文件 |
| It is not a NewsPaw configuration file. | 这不是 NewsPaw 配置文件。 |
| It was made by a newer version of NewsPaw. Update the app to import it. | 它由更新版本的 NewsPaw 生成，请先更新应用再导入。 |
| It is larger than 5 MB. | 文件超过 5 MB。 |
| It has more than 500 categories. / It has more than 5,000 sources. | 分类超过 500 个。/ 来源超过 5,000 个。 |
| A name is empty or too long (%@). | 有名称为空或过长（%@）。 |
| An address is not an http or https address (%@). | 有地址不是 http 或 https 地址（%@）。 |
| A model service address is not https (%@). | 有模型服务地址不是 https（%@）。 |
| A value is not one this version of NewsPaw knows (%@). | 有取值是这个版本的 NewsPaw 不认识的（%@）。 |
| An entry refers to a category that is not in the file (%@). | 有条目引用了文件中不存在的分类（%@）。 |
| An address is listed twice in one partition (%@). | 同一分区中有地址重复出现（%@）。 |
| A backup model has no primary model (%@). | 有备用模型没有对应的主模型（%@）。 |
| The file's adult partition entries do not match its header. | 文件中的成人分区条目与文件头不一致。 |
| The file could not be read. | 无法读取这个文件。 |
| category %lld · source %lld · model %lld · settings (the %@ above) | 第 %lld 个分类 · 第 %lld 个来源 · 第 %lld 个模型 · 设置 |
| This file also contains the adult partition. | 这个文件还包含成人分区。 |
| Unlock the adult partition to compare and import that part. Otherwise only the normal partition is imported. | 解锁成人分区后才能比较并导入这一部分；否则只导入普通分区。 |
| Unlock · Turn On and Unlock · Normal Partition Only | 解锁 · 开启并解锁 · 只导入普通分区 |
| The adult partition in this file was skipped. | 这个文件中的成人分区已跳过。 |
| The file's adult partition was not imported. You can import it from Settings › Data. | 文件中的成人分区没有导入，可以之后在“设置 › 数据”中导入。 |
| Exported %1$@ by NewsPaw %2$@ | 由 NewsPaw %2$@ 于 %1$@ 导出 |
| %lld categories · %lld sources | %lld 个分类 · %lld 个来源 |
| New · Already Here · Conflicts · Settings · Models | 新增 · 已存在 · 有冲突 · 设置 · 模型 |
| Merge keeps these as they are on this device. | 合并会保留这台设备上的现状。 |
| To take the file's settings, use Replace Everything. | 要采用文件中的设置，请使用“全部替换”。 |
| Everything in this file is already here. | 文件里的内容都已存在。 |
| Merge · Replace Everything | 合并 · 全部替换 |
| Before Replacing | 替换前确认 |
| Deleted · Changed · Models removed · Keys removed · Settings replaced | 将删除 · 将修改 · 将移除的模型 · 将移除的 Key · 将替换的设置 |
| %lld articles, %lld of them starred | %lld 篇文章，其中 %lld 篇已收藏 |
| Only the normal partition is replaced. | 只替换普通分区。 |
| Replace · Replace now? · This cannot be undone. | 替换 · 现在替换吗？· 此操作无法撤销。 |
| Imported | 已导入 |
| Added · Changed · Deleted (row labels of the summary) | 已添加 · 已修改 · 已删除 |
| %lld models need a key. · Set Up Keys | 有 %lld 个模型需要 Key。· 设置 Key |
| The adult partition was imported. The normal partition and the settings could not be, and are unchanged. | 成人分区已导入；普通分区和设置未能导入，保持不变。 |
| The import could not be completed. Nothing was changed. | 导入没有完成，没有任何改动。 |
| Name differs · Category differs · Kind differs · Options differ · Address differs · Model differs · Value differs | 名称不同 · 分类不同 · 类型不同 · 选项不同 · 地址不同 · 模型不同 · 取值不同 |

## Files to change

Package (`ios/NewsPawKit/Sources/NewsPawKit`): new `Config/ConfigurationFile.swift` (wire types including the two settings structures, reader, refusal, document), `Config/ConfigurationWriter.swift`, `Config/ConfigurationSettings.swift` (export and apply of the settings members through the typed accessors; the not-exported list), `Config/ConfigurationPlan.swift`, `Config/ConfigurationTransfer.swift` (targets, export, preview, import), `Store/Library+Configuration.swift` (snapshot, the write transaction); RD08's bounded read called or shared as decision 3 says. If RD14 has merged: its daily-limit statement made a function of a `Database` shared by its setter and the import. Tests: new `ConfigurationFileTests`, `ConfigurationWriterTests`, `ConfigurationSettingsTests` (with the source scan), `ConfigurationImportTests`, `ConfigurationExportTests`, `ConfigurationRoundTripTests`. Not changed: `LibraryModels.swift`, `Preferences.swift`, `AdultGate.swift`, `LibraryStore.swift`.

App (`ios/NewsPaw`): new `AppState/ConfigurationModel.swift`, `AppState/ConfigurationFixture.swift` (debug only), `Settings/ConfigurationImportView.swift` (root modifier, preview, lists, review, summary); changed `Destinations/SettingsView.swift` (`DataSettingsView`: the Configuration section above Images), `AddSource/AddSourceView.swift` (the row), `AppState/Workspace.swift` (the model), `AppState/AppModel.swift` (keeps the adult key store for the adult target; the pending-operation hand-over — `chooseAdult(pending:)` returning its outcome and the `.importConfiguration` case, the hand-over itself only if RD19 has not built it; the completion closure; emptying the export directory at launch and at a lock), `AppState/NavigationModel.swift` (`AppSheet.configurationImport`), `Navigation/RootView.swift` (the modifier), `AppState/RefreshSettings.swift` (`reload()`), RD14's `AppState/TranslationSettings.swift` (`reload()`, if merged), `AppState/DebugLaunchOptions.swift`, `UITestIdentifiers.swift`, `Localizable.xcstrings`, `NewsPaw-Info.plist` (the exported type); RD08's share sheet used unchanged. If RD21 has merged and RD20 merges second: its first-run step and Today's empty state gain the rows. UI tests: new `ConfigurationTests`.

Docs: `docs/reader/spec.md` — N10, one sentence (Replace removes a slot the file does not have, with its key); section 5, one paragraph (members this version does not read are ignored; what changes `schema_version`; limits are per file).

No migration, no dependency, no change to either lock file, collection or detection.

## Execution surface

No network request and no model request from export or import; the refresh that follows is the existing one. The exported file leaves the app only through the share sheet the owner acts on. Executed: the three checks, the iOS 26.5 package suite, `xcodebuild test` with `-only-testing` while iterating and the whole UI suite once by the driver, `xcrun simctl`, `git`. Not touched: the schema, dependencies, `.github/`, the owner's ignored files.

## Failure handling

| Case | Behaviour |
| --- | --- |
| Picker cancelled | Nothing |
| File refused or unreadable | Alert with the reason; nothing read from a library, nothing changed |
| The adult question cancelled | Nothing; no library read; the document dropped |
| Authentication declined, cancelled, failed, interrupted, discarded or busy; turning on refused; gate unavailable | `AppModel` drops the document; preview of the normal partition with "The adult partition in this file was skipped." |
| The adult library cannot be opened after a passed authentication | RD18's notice; once it is dismissed, the normal-only preview, saying the adult part was skipped |
| Storage error while building the preview | Alert; no preview |
| Preview, review or second question cancelled | Nothing changes |
| Storage error in the adult transaction | Nothing written; the preview stays with "The import could not be completed. Nothing was changed." |
| Storage error in the normal transaction after the adult one committed | Summary with the partial-state sentence; global settings unchanged |
| A keychain item cannot be removed | Ignored; the row no longer names it (decision 5) |
| A lock while reading, asking or previewing | The adult workspace's state goes with it; nothing presented afterwards; in the normal partition nothing is affected |
| A lock after the confirmation | The write runs to its end; `AppModel`'s completion reloads the normal workspace, re-reads the settings objects and calls `slotsChanged()`; no summary is shown; an adult transaction not yet begun fails and nothing is written |
| A source is deleted by Replace while a refresh collects it (also the refresh a lock starts) | As when the owner deletes a source during a refresh |
| Export: storage error, over the limits, or the file cannot be written | Alert with the reason; no share sheet; no file left |
| A `huggingface` source imported before RD26 | Stored and listed; not collected until RD26 |

## Risk assessment

- **Partial import across two databases.** Bounded to the two states of decision 5 and said in the summary; the adult transaction goes first so that a lock never leaves the normal partition imported without the adult one the owner confirmed together.
- **A write that outlives a lock.** It holds the adult library and the adult part of the document only until its adult steps end, then lets go; its completion belongs to `AppModel`, so the normal partition and the settings are never left stale. No summary is shown after such a lock.
- **A Replace that deletes more than the owner expected.** Two confirmations, the review lists names and counts, and Merge never deletes. The counts are those of the preview: articles collected between the preview and the write are deleted with their source too.
- **Hostile files.** Bounded by the 5 MB read, the counts before anything else, byte limits before character operations, the decoder's depth limit (A1) and whole-file refusal. Nothing in a file causes a request.
- **Plain-text adult content in a file.** Only from inside the adult partition, with a switch that is off by default and a footnote; encryption is put to the owner, not built.
- **Two file importers in one window** (A3), and the two Add Source rows that behave differently; the share sheet and picker under UI tests: hand checks on a simulator, listed.

## Test plan

Package (`swift test`; the size and depth cases inside `TimedAndHeavySuites`): the reader — each refusal of criterion 3 with its reason and position, `1.0` accepted as 1, the exact limits and one over, a byte-order mark, ignored members (a `key` member among them), a missing optional member taking its default, a web page's options ignored, an unknown icon kept as text, a name of 4,096 bytes of combining marks within a time bound, control characters removed from names, a duplicate member taking its first value; the writer — exact JSON for a small library, sorted keys, no device setting, read back by the reader; the settings members through the typed accessors and the source scan; planning — Merge and Replace tables (new, already here, each kind of conflict, same-named categories both ways, pairing under Replace, a kind that differs, slot fill, slot equal / changed address / changed model / absent, settings equal and differing); import — criteria 4–8, 12 and 13 with two libraries from one `LibraryStore` and in-memory key stores (criterion 13 holds the adult transaction with a test hook and closes the adult library through the store's lock path); the decline path of criterion 9 (no adult target given; adult file bytes unchanged; no side files); `withoutAdult` leaving no adult entry; export with and without the adult part, and over the limits; the round trip of criterion 1; zero requests on a counting transport and model stand-in (criterion 14).

Planted failures, each made once, seen to fail, and recorded in the hand-back: write `key_ref` into the slot's encoding (criterion 2 fails); add an unclassified `static let fooKey = "foo"` (the scan fails); hand the importer the adult target on the decline path (criterion 9 fails); let Replace touch a partition the file lacks (criterion 8 fails); compare the model address by origin instead of equality (criterion 7 fails); accept `http` model addresses in a debug build (criterion 3 fails); let Merge write a differing setting (criterion 4 fails); call the completion from the adult workspace's model instead of `AppModel`'s closure (criterion 13's app check: after a lock the normal list is stale); drop the second question (criterion 6's UI test fails).

UI (iPhone and iPad): export from the normal partition with the gate off (no switch) and on (switch disabled) and from inside the adult partition (switch enabled), each reaching the share sheet (RD08's A5 applies); import `both` into a fresh install by Merge — the adult question, Unlock, the preview in the adult partition, the summary with "models need a key", Set Up Keys; the same with "Normal Partition Only" — the skipped sentence, `pool=closed`, and (debug element) no document held by `AppModel`; Replace with `normal` from inside the adult partition — review, second question, the adult content unchanged after locking and unlocking; Settings › Refresh shows the imported interval after Replace and not after Merge; `refused` shows the alert; Cancel at each step changes nothing. If RD21 has merged: `both` from the first run imports the normal partition with the one-line note. Screenshots for criterion 17.

By hand on a simulator, recorded as such: choose a `.newspaw` and a `.json` file in Files (A2); both Add Source rows (A3); export, Save to Files, import the saved file into an emptied install (A4); both inside the adult partition (A4); the two prompts in a row (A5); a Replace confirmed inside the adult partition with the app sent to the background at once ("Immediately"): back in the app, the normal partition shows the result and no summary is shown.

Device checks owed, listed in the pull request as not done: AirDrop a file from one of the owner's devices to another and import it (A6, N13's list); the two authentication prompts on Face ID and on Touch ID.

## Handoff notes

- RD14: if it merges after this issue, it adds its three global settings and `daily_auto_limit` as members of the settings structures (export line, apply line, preview line), shares its daily-limit statement with the import's transaction, has the import's slot writes run its `deleteFailedTranslations` statement, and `AppModel`'s import completion calls `slotsChanged()`.
- RD15, RD24, RD19: add `translate_body_on_open`, `background_refresh` and `list_thumbnails` as members; RD15 adds the default display mode, and whoever stores an image-cache size limit adds it, to the not-exported list.
- RD17: may narrow `daily_auto_limit`'s accepted range in its member's validation.
- RD19: RD20 relies on no gate operation of RD19's; an import with the adult partition enters it through the partition switch's unlock with a pending operation on `AppModel`, the mechanism RD19's move uses too. Whichever is implemented first builds the hand-over; the second adds its case (`.move(categoryID)` or `.importConfiguration(document)`). Once RD19 builds the adult workspace's `LibraryModels`, the adult target is taken from it, and RD19 adds "Set Up Keys" for the adult partition to the summary. The export directory is emptied at every lock already.
- RD21: whichever of RD20 and RD21 merges second adds "Import Configuration…" to the first run (ux S12) and to Today's empty state (ux S1). An import started from the first run uses the origin `firstRun`: it brings the normal partition only, asks nothing about the adult partition, and its summary says in one line that the file's adult partition was not imported and can be imported from Settings › Data.
- RD22: the AirDrop check between two devices.
- RD23: overviews must be deleted with their category or source (a cascade, or Replace's transaction deletes them), since Replace deletes categories and sources.
- RD26: Hugging Face sources already round-trip; they are collected once RD26 lands.

## For the owner

1. **What a round trip between two of your devices restores:** categories (name, icon, overview setting, order) and sources (name, address, kind, category, paused, translate-titles and body options, translate-when-opened) in each partition the file contains; the model slots' service, address and model name; and, with Replace Everything, the global settings (refresh interval, retention, and the reading language and translation switches once they exist) and each partition's daily automatic limit. **What it does not:** keys (each imported model says "Key needed" until you type the key again), Test results ("Not tested"), articles, read and starred state, translations, overviews, usage, image caches, browsing data and logins, source status, and the device settings — text size, line spacing, typeface, the adult partition's on/off and lock timing. Articles come back with the first refresh, as unread, as far as each feed still lists them.
2. **Settings and Merge.** Merge never changes your settings; it lists the ones that differ. To take the file's settings, use Replace Everything. The other choice, if you prefer it: Merge takes every setting the file has.
3. A file exported from the normal partition never contains anything of the adult partition. To include it, export from inside the adult partition and turn on "Include the Adult Partition" (off each time). Such a file is plain text: anyone who has it can read the adult categories, sources and model services (never keys). It is not encrypted — say if you want encryption with a password; it is not built.
4. The file is always named "NewsPaw Configuration ⟨date⟩.newspaw"; the name never says whether the adult partition is inside.
5. Importing a file with the adult partition from the normal partition asks first. "Unlock" (or "Turn On and Unlock", two Face ID prompts, when the partition is off) switches you into the adult partition, where the preview covers both partitions. Declining imports the normal partition only and says so. From the first run of a new device, only the normal partition is imported, without asking; the summary says the adult part can be imported later from Settings › Data.
6. Merge adds what is new and changes nothing you have: existing sources keep their category and options even when the file differs (listed as conflicts), and existing models keep theirs.
7. Replace Everything makes each partition in the file exactly the file's: categories and sources not in the file are deleted with their articles (you see the names and counts, then confirm twice); a model whose address differs in any way — even only its path — loses its stored key; a model the file does not have is removed with its key. A partition not in the file is not touched. A source keeps its kind even if the file says another.
8. If you leave the app right after confirming an import inside the adult partition and it locks, the import still finishes, but no summary is shown anywhere; the normal partition may already show the result when you come back.
9. Two of your categories with the same name: Merge files into the first; Replace keeps them as two.
10. A file is refused as a whole, with the reason, when anything in it breaks a rule — including a model address that is not https. Nothing is half-imported from a bad file.
11. A file made by a newer NewsPaw asks you to update; a file made by an older one leaves settings it does not mention as they are.
12. After an import the usual refresh starts when you leave the summary; with a model and its key in place, new titles are translated as after any refresh. The import itself sends nothing anywhere.
13. AirDrop: the receiving device saves the file in Files, and you import it from Settings › Data or Add Source. Opening it straight into NewsPaw from AirDrop is not built. On Add Source, "Import Configuration" closes the sheet and opens the import, while "Import OPML" opens over it.
14. The rare case of an import that fails half way: the adult partition can be imported while the normal partition and the settings are not; the summary says so.

## Revision record

| Version | Date | Change |
| --- | --- | --- |
| 1 | 2026-11-16 | Draft for debate |
| 2 | 2026-11-16 | After debate round 1: no adult `LibraryModels` (one library and key store per partition); the unlock route as a pending operation on `AppModel`, one mechanism with RD19's move and no gate operation; the write's completion moved to `AppModel`; the hand-over's exits; Merge leaves settings; typed settings structures instead of a registry; the measured table and criterion 3 corrected; RD08 named by roles, the root presenter explained, a fixture key of its own; the first-run origin and the shared RD21 rows rule |

## Debate record

Round 1 (fresh critic, 2026-11-16; report, probe and output in the run's evidence folder under `rd20/debate/`): verdict SOUND WITH FIXES, nine findings, no P1. The driver admitted every one; each piece of evidence was checked against the code (`AppModel.swift:374–375`, `Library+Models.swift`, rd14-wt `Workspace.swift:86–90` and `AppModel.swift:214`, rd08-wt `OPMLReader.swift:124`, `OPMLImportView.swift:10`, `UITestIdentifiers.swift:350`, the critic's probe output).

| # | Severity | Finding | Disposition |
| --- | --- | --- | --- |
| F1 | P2 | An adult `LibraryModels` is not needed and contradicts RD14's and RD18's statements | Admitted: one `(Library, KeyStore)` pair per partition with `LibraryModels.init`'s precondition; `LibraryModels.swift` unchanged (Approach 5–7, contract, files, handoff) |
| F2 | P2 | RD19's draft lends the adult library to RD20 by a gate operation | Admitted (driver's decision for both issues): unlock and switch with a pending operation handed over by `AppModel`; no gate operation; whichever of RD19 and RD20 comes first builds the hand-over (gap 10, decision 7, contract, handoff) |
| F3 | P2 | A write that outlives a lock had no defined completion | Admitted: `AppModel`'s completion closure; adult references dropped after the adult steps; the lock's refresh is the existing row; owner item 8; criterion 13 |
| F4 | minor | The hand-over's exits were unstated | Admitted: the document is moved into the pending operation; `chooseAdult(pending:)` returns its outcome; dropped on every outcome but `.unlocked`; preview after the notice; criterion 9 |
| F5 | P2 | Merge's "never set" settings rule was invented and defeated by RD21's first run | Admitted: Merge leaves settings and lists them as conflicts; the `Preferences` query and the N10 sentence dropped; owner item 2 |
| F6 | minor | A registry was more than six settings need | Admitted: typed structures and typed accessors; the not-exported list and the scan kept; the closed-set clause dropped |
| F7 | minor | Decoder facts and criterion 3's cases | Admitted: table and criterion 3 corrected; the step-2 mapping; why a duplicate key is harmless |
| F8 | minor | RD08 described loosely | Admitted: the root presenter explained as RD20's choice; own fixture key; the bounded read conditional on RD08's merge |
| F9 | minor | An import from RD21's first run | Admitted (driver's decision): the `firstRun` origin brings the normal partition only, with a one-line note; criterion 16; RD21 handoff |
