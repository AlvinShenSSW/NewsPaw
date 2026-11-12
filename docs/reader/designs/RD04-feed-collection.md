# RD04 — Feed collection: fetch and parse RSS, Atom and JSON Feed into articles

Issue: [#125](https://github.com/AlvinShenSSW/NewsPaw/issues/125) · Epic E12 #115 · Requirements N03 (feed), N04 (collection rules, what counts as new, time), N12.
Design version 6, 2026-11-12 (versions 1–5: three debate rounds on 2026-11-11; version 6: two internal review rounds on the implementation and one more debate round; see the last section). Author: Claude (driver of this AFK run). Implementer: Claude Opus 5.5. External gate: Codex `gpt-6.1-sol` at high effort (the owner's instruction of 2026-11-12; Kimi K3.1 Pro when version 5 was frozen).

## Spec review

Given one feed source already stored in a library, fetch its address under the collection rules and turn what comes back into `article` rows, recording on the source how the attempt went. There is no interface, no scheduling and no retention here: RD05 adds sources and shows status, RD06 decides when to collect and what to clean up, RD11 lays out bodies.

Core need: one function later issues can call for any feed-like source and trust — it never throws away or duplicates articles, never lets one bad feed or one bad item spoil the rest, and treats everything it downloads as inert data.

Settled here because the issue and the specification leave it open:
- **Where the feed's body text goes.** Spec section 4 has `article_body.blocks` (laid-out blocks) but no place for the feed's own HTML, and the feed is the only moment that HTML is available. Decision: a nullable column `article.content_html` holds it; RD11 converts it when an article is opened. It holds the feed's dedicated content when there is one and otherwise the description, because many feeds carry their full text there. Spec section 4 gets the column.
- **An item the feed later edits.** Not rewritten: the first version stays.
- **A redirected feed.** Redirects are followed on every collection; the stored address is never rewritten automatically.
- **What "20 seconds" covers.** The whole exchange for one collection, redirects included. Parsing is not inside it, so parsing has to be fast on anything the 10 MB limit lets through (next point).
- **The parser.** The issue says "parsing uses FeedKit". Two debate rounds measured that FeedKit cannot do this job: its typed decoding fails a whole feed over one bad date or attribute, and its XML reader takes time that grows with the square of the number of sibling elements and of the text size (one item with a 4 MB description: 53 seconds; 31,000 small items: 23 seconds), synchronously and outside the deadline. Version 5 therefore read XML with the system's streaming parser and JSON with the system JSON parser. Reviewing that implementation showed that those two cannot be given hostile bytes either: they crashed (deep JSON nesting; an enumerated attribute type; stopping the XML parser inside one callback), took quadratic time on shapes found one after another (a repeated entity, many attributes, many namespace mappings, attribute-list defaults, many distinct names, colliding JSON keys), carried on working after an error with callbacks off, and cannot be interrupted; each guard depended on behaviour they do not document, and one guard added a crash. Decision (version 6): **no system XML or JSON parser reads feed bytes.** The package decodes the body to text, tokenises XML itself and reads JSON itself — without recursion beyond a fixed depth, in time proportional to size by construction, with fixed limits, and stopping on cancellation. FeedKit is removed from the package's dependencies, with the RD01 check that existed only to prove it builds. Spec section 6 and open-source.md are corrected.
- **Failure reasons.** Stored as short codes in `source.last_error`, which stays free text; RD05 words them.
- **Japanese encodings.** Feeds declared as Shift_JIS or EUC-JP, or declared only in the HTTP header, must parse. An acceptance criterion.
- **Dates with no time zone** are read as UTC. A feed that writes local Japanese time without a zone therefore has items up to nine hours "in the future", which the future rule turns into "no published time"; the first-seen time stands in. Recorded, not fixed.

## Acceptance criteria

1. Synthetic fixtures in RSS 2.0, RSS 1.0, Atom and JSON Feed each produce the expected feed (title, site link) and articles: identity, link, title, excerpt, author, image, published time, content.
2. Japanese text: a fixture declared as Shift_JIS, one as EUC-JP, one in Shift_JIS declared only by the HTTP header, and one in Shift_JIS whose own declaration wrongly says UTF-8 while the header is right, each produce the same articles as their UTF-8 twin. A feed that parses completely as sent is never decoded again with the header's charset: a UTF-8 feed with no declared encoding behind a header saying `ISO-8859-1` keeps its text.
3. One unusable part does not fail the feed: an item with an unparseable date, a malformed enclosure, markup where text is expected, or any other bad detail still yields that item where it can be identified (the bad field absent) and all the others; a bad value at channel level does not fail the items. When a document stops being well-formed part-way (an unescaped `&`, a reference to any entity but the five predefined ones, a byte that is invalid in UTF-8, a truncated download — also one that ends inside a character), the items completed before that point are kept and the collection counts as a success, but its validators are not stored, so the next collection fetches the whole document again.
4. A document that is not a feed is refused as not a feed, including the ones a lenient parser would accept as empty feeds: a well-formed XHTML page, RSS with no channel, JSON that is not JSON Feed. A valid feed with zero items is a success with nothing new.
5. Collecting the same feed twice adds nothing the second time. A `304 Not Modified` is handled without parsing and counts as a success. The stored validators are sent on the next request, weak validators unchanged, and are replaced after a `200`.
6. Transport limits, each tested against the real transport with no outside network: the 20-second deadline (injected shorter in the test); the 10 MB limit on decoded bytes — announced by `Content-Length`, exceeded while streaming, and reached only after decompression; exactly 5 redirects succeed and 6 fail at once (not after the deadline); a redirect to a non-http scheme; a source address or a redirect target that is not http or https or that carries a user name or password.
7. Nothing identifying is sent: no cookie is stored or sent, no credential is sent — including credentials embedded in an address — an authentication challenge is declined and recorded as the 401 it was, and the request's `User-Agent` and `Accept-Language` are fixed values, asserted on the wire.
8. Identity falls back in order — the feed's identifier (RSS `guid`, RDF `rdf:about`, Atom `id`, JSON `id`), else the link, else a hash of the raw title and raw date — and an item with none of these is skipped. Each case has a test.
9. Published time: taken from the feed when present, parseable and not later than the moment of collection; otherwise absent. First-seen is the collection's clock reading and never changes. Each case has a test.
10. Within a category, an item whose link is already held by an article of that category — from the same or another source, or earlier in the same batch — is not stored. Items without a link are never treated as duplicates of each other.
11. Titles lose no literal text: a JSON Feed title and an Atom title of type text are kept as written (white space collapsed); only titles that are HTML are reduced to text.
12. Body content: `content_html` holds the feed's content, else its description; plain-text content is escaped so that it reads as text when later treated as HTML; the excerpt comes from the description, else from the content's text. A feed whose full text is in the description keeps it.
13. Parsing does work in proportion to the document's size, not faster, on every input. Two tests. (a) A deterministic work counter: the tokenizer, the JSON reader, text reduction and the helper through which every feed-supplied string is matched count the bytes they examine, and for every document of the corpora of criterion 17 and of the shapes below the count stays under a fixed multiple of the document's size — so a shape nobody listed fails the test too. (b) Timing, as a second witness: for each shape a size N and a size 4N are parsed and the larger must take less than 8 times the smaller (proportional growth gives 4, quadratic 16), best of three, interleaved, with N chosen so that the smaller run takes at least about 0.2 seconds unless the document is refused at once. Shapes: many small items; one item with a very large escaped text; one element with very many children; very many attributes on one tag; very many namespace declarations in scope; very many distinct names; a document type with very many declarations, long literals and attribute lists; an entity referenced very many times; very deep nesting; nested table markup (text reduction); Atom XHTML content; a long run of combining marks in every position the reader inspects (element and attribute names, namespace addresses, `rel` and `type` values, an encoding label, a date, a link, an identifier, a JSON key); and for JSON: deep nesting, very many keys, long keys that share their beginning, middle and end, long strings of escapes.
14. Outcomes: each failure reason has a test and is recorded as its code, keeping the last success time and every stored article; the next success clears it. A source that fails leaves every other source untouched and is not paused or deleted. Cancelling a collection records nothing and rethrows the cancellation. Collecting a source that does not exist, is not a feed-like kind, or is deleted while the fetch is in flight ends in a "nothing done" outcome, not an error. A rename, pause or move made while a fetch is in flight is not overwritten.
15. Nothing in a feed is executed or followed: no request is made for anything a feed mentions, a document type is skipped without being interpreted (no entity is defined, no default attribute applied, nothing external read), and `content_html` is stored as text.
16. The schema change is migration `v2` on top of `v1`; the frozen `v1` fixture migrates with its rows intact. List queries do not carry `content_html`.
17. No document makes the parser crash, hold memory beyond what its fixed limits allow, or run on after its task is cancelled. Limits, each ending the document at that point as a break does in criterion 3: element nesting deeper than 256; more than 256 attributes on one start tag; a name longer than 1,024 bytes; JSON nested deeper than 64 (not a feed). Tests, run on a detached task so that the small stack of a concurrency thread applies: every fixture truncated at every byte and with single-byte edits; a generated corpus of malformed and limit-crossing documents for every construct the tokenizer and the JSON reader know; the crashing documents found in review (deep JSON objects, also as UTF-16; the namespace-mapping stop; the enumerated attribute type) as cases; each limit at the limit and one past it, with the tokenizer's high-water marks of depth and attributes asserted; random bytes decoded with every encoding of the label table; cancellation during a large document.
18. Where the system XML parser reads a document to its end without error, the tokenizer does too, with the same events. Test-only comparison (the system parser is never used outside tests): for every generated document and every single-byte edit of every XML fixture that the system parser reads to the end without error — and that is inside the limits of criterion 17 and outside the listed differences — the tokenizer must read it to the end and deliver equal events: element namespaces and names, attributes, concatenated character data. The verdict "well-formed" is the system parser's, not the generator's. Each listed difference (Approach, "Intended differences") has a test of its own.

## Frozen issue contract

**In.** The eighteen criteria.

**Invariants.**
- Everything from the network is data. The collector makes exactly the requests needed to fetch the source's own address (and its redirects) and no other.
- No feed bytes reach a system XML or JSON parser. Foundation's string converters decode legacy encodings, behind the label table; `URL` parses addresses. Both were measured linear on hostile input (10 MB in 0.2 s or less; addresses up to 8 MB in 0.04 s or less) but were not fuzzed for crashes beyond criterion 17's random-byte test.
- No feed-supplied string is hashed or compared as a `String`, anywhere in the package: Swift normalises a string to hash or compare it, and a long run of combining marks makes that quadratic (measured: one 640 KB key, 48–69 seconds). Names, namespace addresses, attribute values, JSON keys, encoding labels, dates, links and identifiers are matched as UTF-8 bytes, length first; attributes are a small array, not a dictionary; sets and dictionaries are keyed by bytes.
- One collection touches one source's articles and that source's status columns (`etag`, `last_modified`, `last_success_at`, `last_error`), in its own library. It takes a `Library`; it has no partition parameter.
- A feed-level failure is an outcome recorded on the source, not a thrown error. Only cancellation and a storage failure throw.
- `source.last_error` is free text holding a code; it is not one of RD02's closed sets and is read tolerantly (the frozen fixture already holds a value that is not a code).
- RD02's invariants hold: identifiers enter SQL as lowercase text through the one helper; migrations are append-only; no `CHECK` on closed sets.
- Tests contact no outside host: the transport is exercised through an in-process URL-loading stub and, where the stub cannot show the behaviour (cookies, decompression, a real authentication challenge, the headers actually sent, embedded credentials), through a listener on the loopback address inside the test process. The collector is tested with a fake transport.

**Allowed user-visible change.** None. Nothing in the app calls this yet.

**Non-goals.** When to collect, concurrency between sources, retention and the `seen` table (RD06); the add-source flow, feed discovery, address normalisation and status wording (RD05); GitHub and Hugging Face (RD07, RD26); fetching article pages (RD12); HTML-to-blocks conversion (RD11); language detection (RD14); thumbnails taken from inside content; rewriting a stored address after a permanent redirect; UTF-16 without a byte-order mark and ISO-2022-JP feeds; a document-level `xml:base`; entities a document declares for itself; attribute-list defaults.

**Causal boundary.** `ios/NewsPawKit/Sources/NewsPawKit/Feeds/**` (new); `Store/Schema.swift` (migration `v2`), a new `Store/Library+Collection.swift`, `Model/Article.swift` and `Model/Source.swift`; `ios/NewsPawKit/Package.swift` and both lock files (`ios/NewsPawKit/Package.resolved`, `ios/NewsPaw.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`) only to remove FeedKit — no other pin changes; `ios/NewsPawKit/Tests/NewsPawKitTests/Feeds/**`, `Fixtures/feeds/**`, the schema tests, and the removal of `DependencyChecks/FeedKitCheck.swift` with its fixture; `docs/reader/spec.md` (section 4: the new column; N04: the meaning of the 20 seconds; section 6: the parser), `docs/reader/open-source.md` and `README.md` (the library list). Nothing in `ios/NewsPaw/`.

## Assumptions

| Assumption | Risk if wrong | Verified by |
| --- | --- | --- |
| A tokenizer and a JSON reader in the package can produce every field this design maps, and agree with the system XML parser on well-formed documents | A construct real feeds use is mis-read | Criterion 18's comparison; RD05's preview meets real feeds early |
| A listener on the loopback address can run inside the test process under `swift test` locally and on the CI image | Those checks run locally only and the pull request says so | The transport tests in CI |
| Plain http to the loopback address is not blocked by App Transport Security when the package tests run on the iOS simulator | The loopback tests are skipped on the simulator run and that is reported | The one package run on the iOS 26.5 simulator |

Measured in debate round 1 on this Mac (FeedKit 10.10.2, SwiftSoup 2.14.3, Swift 6.4, macOS 27.0.1; a local pass proves this machine only):
- FeedKit's typed decoding is all-or-nothing: one unparseable date, a malformed enclosure length, a JSON item without `id`, or a bad channel-level value fails the whole feed. It also accepts an XHTML page, RSS without a channel and arbitrary JSON as empty feeds, and does not expose `rdf:about`, an Atom title's `type` or a document-level `xml:base`.
- The system XML parser decodes Shift_JIS and EUC-JP when the document declares them, using the web (CP932) mapping; a charset given only in the HTTP header is not applied; transcoding with `iconv -t SHIFT_JIS` changes several characters (〜 − ‖ ¢ £ ¬ — ¥ ‾), `iconv -t CP932` does not.
- A URL-loading stub drives redirects, deadlines, streamed bodies and announced lengths, but cannot show cookies, decompression, a real authentication challenge or the loader's default headers; a loopback listener shows all four under `swift test`.
- The loader sends credentials embedded in an address (also when a redirect supplies them) before any delegate decision; by default it adds `Accept-Language` from the device's languages and a `User-Agent` naming the process; setting both replaces them, also across redirects.
- After a refused redirect a stubbed task does not finish by itself; recording the reason and cancelling the task ends it at once on stub and real loader alike. Cancelling an authentication challenge loses the 401 status.
- Parsing time is quadratic in item count (31,000 small items, inside 10 MB: about 24 s); 5,000 items parse in under a second.
- External entities and document types cause no request; nested entity expansion is rejected at once; 26,000 corrupted inputs caused no crash.
- `ALTER TABLE article ADD COLUMN content_html TEXT` plus an index on `article(url)` applies to the `v1` fixture with rows intact, and the index is the one the same-link query uses.

Measured in round 2:
- FeedKit's XML reader is quadratic also outside its typed models: 40,000 empty siblings (160 KB) 17.5 s; one item with 1 MB / 4 MB of escaped text 3.6 s / 53 s; one Atom entry with 4 MB of XHTML 102 s. One streaming pass with the system parser over the same files takes 4–7 ms, and 0.06 s for 31,000 items in 9.4 MB.
- Header charsets: writing the header's charset into the declaration rescues a Shift_JIS feed with no or a wrong declaration, but applied to a feed that already parses it produces mojibake (UTF-8 behind `ISO-8859-1`) or failure (`US-ASCII`, unknown labels); a second declaration prepended to an existing one fails.
- Date parsers: the system date formatter does not know `JST`, `CET` or `AEDT`; the system ISO 8601 formatter in date-only mode accepts any string that merely starts with a date.
- GRDB: a record selects every column unless it declares its selection; `INSERT … ON CONFLICT (source_id, external_id) DO NOTHING` in raw SQL reports 0 changes for an existing identity and 1 for a new one.
- An empty `Accept-Language` is sent as an empty header; `*` is sent as written.

## Approach

**Layers.**
1. `Transport` — the replaceable interface N13 asks for: request in (address, validators, limits), response out (final address, status, headers, body), or one of the transport's own failure cases.
2. `URLSessionTransport` — the real one. An ephemeral session with no cookie storage, no credential storage and no cache; fixed headers — `User-Agent: Mozilla/5.0 (compatible; feed reader)` (a generic value: the app's own name would be unique to its one user and would link requests across feeds and partitions), `Accept-Language: *`, and `Accept` listing the feed media types then `*/*`. Its task delegate: counts redirects; refuses a redirect past the fifth, to a scheme other than http or https, or to an address with a user name or password — it records why and cancels the task, and the transport reports that reason before looking at any status or error; declines HTTP and proxy authentication challenges by recording the status of the answer that raised them (401 or 407) and cancelling; gives server-trust and client-certificate challenges default handling (the app holds no identity, so nothing is sent, and a server that merely offers client certificates still answers). The body is read as a stream and abandoned when decoded bytes pass the limit. The whole exchange is raced against the deadline.
3. `FeedParser` — bytes, the response's charset and the final address in; a `ParsedFeed` (format — RSS, RDF, Atom or JSON Feed — title, site link, items, and whether the document was read to its end) out, or "not a feed". It:
   - **decodes** the body to text. As sent: a UTF-8 or UTF-16 byte-order mark decides (UTF-16 without one stays a non-goal); otherwise the encoding the XML declaration names, the declaration being read exactly (`<?xml`, `version`, optional `encoding`, optional `standalone`, in that order); otherwise UTF-8. UTF-8 is validated by the package: the text up to the first invalid byte is tokenised and the document is incomplete there. A legacy encoding is decoded by Foundation as a whole or not at all; on failure the last one to three bytes are dropped (a download cut inside a character) and the document is incomplete; otherwise the attempt fails. Labels are matched exactly, without regard to case and as bytes, in a table from the WHATWG label list plus aliases seen in feeds (`cp932`, `shiftjis`, `utf_8`, `latin-1`, `euc_jp`, `cp936`, `cp949`, `cp950`): UTF-8; the ISO 8859 and Windows single-byte sets, KOI8-R / KOI8-U, macintosh, IBM866; Shift_JIS as Windows code page 932; EUC-JP; EUC-KR as Windows code page 949; GBK and gb18030 as GB 18030; Big5. An unknown label is a failed attempt. JSON is UTF-8 only;
   - **charset rule** (criterion 2, as in version 5): the as-sent attempt first. Only when it is not complete — it failed, or the document broke part-way — and the HTTP header names a charset in the table is the body decoded with that charset and read once more; the second reading is taken when it is complete, or when the first was not a feed. Two known limits, recorded and not handled: a UTF-8 document whose own declaration names a single-byte charset reads as sent into wrong text; a legacy-encoded document with an invalid byte in its middle is not read;
   - **Japanese mappings**: Shift_JIS through code page 932 gives the web's code points (measured, all nine characters where tables differ). Foundation's EUC-JP gives seven other code points (U+301C, 2212, 2016, 00A2, 00A3, 00AC, 2014 where the web gives U+FF5E, FF0D, 2225, FFE0, FFE1, FFE2, 2015); after EUC-JP decoding these seven are mapped to the web's, so that a site reads the same in either encoding. A test over every EUC-JP sequence shows each of the seven arises only from its one JIS X 0208 position; a nine-character fixture in both encodings fails on any change;
   - **tokenises XML** itself, in one pass over the text's UTF-8 bytes, without recursion: text with the five predefined entities and decimal / hexadecimal character references decoded; start, end and empty-element tags; attributes in single or double quotes; CDATA sections; comments and processing instructions, skipped; a document type declaration skipped to its end, its internal subset's literals, comments and processing instructions honoured only to find that end. Namespaces: `xmlns` and `xmlns:prefix` bind for the element's scope, `xmlns=""` undeclares the default, the `xml` prefix is bound without declaration; a name `p:a:b` has local name `a:b`. Details copied from the system parser as measured: in attribute values literal tab, CR and LF become spaces (CR LF one space) while white space written as character references is kept; in text CR LF and a lone CR become LF; raw C0 controls other than tab, LF and CR, and U+FFFE, are errors; character references to NUL, other forbidden code points, surrogates or beyond U+10FFFF (also with twenty digits) and `&#X` with a capital X are errors; `]]>` in text is an error; white space before a root with no declaration is accepted; U+FEFF inside text is dropped;
   - **stops** where the document is not well-formed — an unterminated or malformed tag, comment, CDATA section, processing instruction or document type; `<` or a bare `&` in text or an attribute value; a reference to any entity but the five predefined ones; an end tag that does not match; an attribute repeated on one tag; content after the root's end other than comments, processing instructions and white space; the end of input with elements open — or crosses a limit of criterion 17. The items completed before that point are kept and the document is incomplete; with none it is not a feed. It checks for cancellation at least every 64 KB and stops;
   - **intended differences from the system parser**, each with a test: an element or attribute with a prefix no declaration binds is read, belongs to no namespace and matches nothing (the system parser reads it too, but takes an unbound `atom:link` for RSS `link`); a reference to an entity the document type declares ends the document there (the system parser drops such text silently); attribute-list defaults are not applied; line ends are normalised inside CDATA sections as everywhere else; a byte-order mark decides the encoding against a declaration that says otherwise; `xmlns:p=""` is ignored as the system parser ignores it;
   - recognises the format by the root element and its namespace (`rss`; RDF with an RSS 1.0 channel or items; Atom `feed` with an id, title or entry) or, for JSON, by a `version` beginning `https://jsonfeed.org/version/`; RSS needs a channel; a document whose root is not a feed is not a feed;
   - matches elements by namespace, not by prefix spelling (`content:encoded`, Dublin Core, Media RSS); `rdf:about` is matched through the bindings in scope. Atom XHTML content is rebuilt as markup from the events: text and attribute values arrive decoded and are escaped again, void elements are written from a fixed list;
   - **reads JSON** itself: a parser over UTF-8 bytes with a depth limit of 64, into values of its own — objects as key-value pairs keyed by bytes (duplicate keys keep the first), arrays, strings, numbers kept as written, true, false, null. `\uXXXX` escapes are decoded with surrogate pairs; an invalid escape, an unpaired surrogate, a control character in a string, content after the root value, or nesting past the limit makes the document not JSON. Each field is read tolerantly (an `id` may be a string or a number, taken as written; a missing or wrong-typed field is absent). Cancellation is checked every 64 KB;
   - parses dates itself, each form matched against the whole string: the RFC 822 family, with numeric offsets and the abbreviations UT, GMT, Z, JST, KST, AEST, AEDT, ACST, ACDT, AWST, CET, CEST, EST, EDT, CST, CDT, MST, MDT, PST, PDT (an unknown abbreviation means "no date"); and the ISO 8601 family — date and time with `Z` or an offset, fractional seconds, or no zone (read as UTC), and date-only; anything else is "no date";
   - titles: JSON Feed titles and Atom titles of type text are kept as written; Atom titles of type html or xhtml and all RSS and RDF titles are treated as HTML and reduced to text (for RSS this can drop literal angle-bracket text, since RSS does not say which a title is — recorded);
   - resolves links and image addresses against the final address; reduces HTML titles and the excerpt to plain text (white space collapsed; excerpt cut at 500 characters) with a linear scanner of its own — tags removed, the content of `script` and `style` elements dropped, character references decoded — and not by building a document tree: SwiftSoup's tree builder takes time that grows with the square of the input on some markup (200 KB of nested table cells: 19 seconds, measured while debating RD05), and a description can be megabytes long. Character references are decoded with SwiftSoup's entity table if that call is linear, otherwise with a table in the package.
4. `FeedFetcher` — one function with no library: address and validators in; not modified, or the parsed feed with its new validators and final address, or a failure reason, out. When the answer was a document that is not a feed, the failure carries that document's bytes, media type, charset and final address, so RD05's feed discovery does not have to fetch the page a second time and can read a Japanese page's title. RD05 uses the fetcher for detection and preview, RD07 for GitHub's feeds.
5. `FeedCollector` — a library, a source identifier and a transport in; an outcome out. It reads the source, calls the fetcher, and stores the result.

**Storing.** One write transaction per collection: check the source still exists and read its category there; decide duplicates in feed order (the first item with a given link in the feed is the one kept); insert the survivors in reverse feed order with a raw `INSERT … ON CONFLICT (source_id, external_id) DO NOTHING` (not the record's own insert: the list record does not carry the content, and GRDB's ignore policy would also swallow other constraint failures); then one `UPDATE` of the four status columns only, leaving `updated_at` and everything the owner can edit alone. Feeds list newest first, so reverse feed order makes the table's row order follow feed age; RD09 may use it to break ties between items that share a time. One clock reading stamps `first_seen_at` for the batch and `last_success_at`.

**Identity.** As criterion 8. The hash is SHA-256 over the raw title and raw date strings, stored as `sha256:` plus the digest; a title with no date still identifies an item. An item with no link whose identifier is a permalink (RSS `guid` not marked otherwise, an http or https address) takes it as its link.

**Images, authors, language.** `image_url` from an image enclosure, `media:thumbnail`, an image `media:content`, or JSON Feed's `image` / `banner_image`; otherwise `NULL`. `author` from the item's author or creator. `language` stays `NULL` (RD14).

**Status codes written to `last_error`.**

| Situation | Code |
| --- | --- |
| No answer: name lookup, connection, TLS failure, and any other transport error (connection lost mid-body, undecodable content, a load the system blocks) | `unreachable` |
| The 20-second deadline passed | `timed_out` |
| 404, 410 | `gone` |
| Any other status that is not 200 or 304, including a redirect answer without a target and a declined 401 or 407 | `http:<status>` |
| Not a feed | `not_a_feed` |
| More than 10 MB decoded | `too_large` |
| More than 5 redirects | `too_many_redirects` |
| Source address or redirect target not http / https, or carrying a user name or password — including a redirect the loader itself refuses before the delegate is asked (a `file:` target) | `unsupported_address` |

**Paused sources.** The collector does not look at `paused`: whether a paused source is collected is the caller's rule (RD06 skips them; RD05 offers no manual update for them).

**Outcome.** Not modified; collected with the number of new articles and whether the document was complete; failed with the code; or nothing done (unknown source, a kind this collector does not handle, source deleted meanwhile). After an incomplete document the stored validators are cleared rather than replaced.

**Schema `v2`.** `ALTER TABLE article ADD COLUMN content_html TEXT`; `CREATE INDEX` on `article(url)`. The `Article` record used for lists declares its column selection without the new column (a record selects every column otherwise); the content is read by article identifier. The test checks the prepared statement's column names.

**For RD06, recorded now.** A `304` lists no items, so per-item last-seen times cannot be refreshed from it; because one clock reading stamps both `first_seen_at` and `last_success_at`, RD06 can relate rows to the collection that produced them. An item suppressed by the same-link rule leaves no trace and will be evaluated again on every collection. The insert path needs no rewrite to add the `seen` check.

## Files to change

| Path | Change | Reason |
| --- | --- | --- |
| `Sources/NewsPawKit/Feeds/` — transport, fetcher, collector, outcome, parsed feed, dates, text reduction; decoding with the label table; the XML tokenizer; the XML reader (events to fields); the JSON parser and reader; the byte-matching helper with the work counter | add | criteria 1–15, 17, 18 |
| `Package.swift`, both `Package.resolved` files | remove FeedKit | the parser decision |
| `Tests/NewsPawKitTests/DependencyChecks/FeedKitCheck.swift`, `Fixtures/rss1.rdf` | remove (the fixture moves under `Fixtures/feeds/` if still useful) | FeedKit is gone |
| `Sources/NewsPawKit/Store/Schema.swift` | change | `v2` |
| `Sources/NewsPawKit/Store/Library+Collection.swift` | add | storing a batch with status |
| `Sources/NewsPawKit/Model/{Article,Source}.swift` | change | list selection without content; failure codes with a tolerant reader |
| `Tests/NewsPawKitTests/Feeds/**` (parser, tokenizer, JSON, decoding, dates, hostile corpus and work counter, comparison with the system parser, timing, transport with stub, transport with loopback listener, fetcher, collector, test support) | add | criteria 1–15, 17, 18 |
| `Tests/NewsPawKitTests/Fixtures/feeds/**` | add | synthetic feeds |
| `Tests/NewsPawKitTests/Store/SchemaTests.swift` | change | `v2` from the `v1` fixture |
| `docs/reader/spec.md`, `docs/reader/open-source.md`, `README.md` | sentences | the column; the 20 seconds; the parser and the library list |

Paths in all but the last row are under `ios/NewsPawKit/` (the project-level lock file is under `ios/NewsPaw.xcodeproj/`).

## Execution surface

- **Written:** the paths above.
- **Read only:** GRDB's sources in the package checkout; `docs/reader/spec.md`.
- **Executed:** `swift build`, `swift test`, `swift package resolve` and `xcodebuild -resolvePackageDependencies` (to rewrite the two lock files after FeedKit is removed — a hand-edited lock keeps a stale hash, and a build passes even with the removed pin still present), `xcodebuild` with `-derivedDataPath` under the scratchpad (the simulator build; one package run on the iOS 26.5 simulator), `iconv` once for the Japanese fixtures, `git`.
- **Generated output:** the Japanese fixtures — `iconv -f UTF-8 -t CP932` and `-t EUC-JP` from the UTF-8 fixture, with the XML declaration changed to match (and removed for the header-only one) — committed.
- **Not touched:** the versions of the remaining dependencies (GRDB, SwiftSoup), `ios/NewsPaw/`, `.github/`, `.gitignore`, the owner's ignored files. No test contacts an outside host.

## Key implementation notes

- Version 6: `StartTagScan`, its label table and proof tests, and the entity, attribute-list, namespace-mapping and distinct-name guards of the first two fix rounds are removed with the system parser; their tests become cases of criteria 13 and 17. `XMLParser` and `JSONSerialization` must not appear under `Sources/`; a test or a search in the pull request shows it.
- The work counter is a plain integer the parsing code increments wherever it examines input bytes or matches a feed string; it exists in the build the tests run. Matching a feed string anywhere else than through the counting helper is a defect by the invariant above.
- The decoding tests run on the iOS 26.5 simulator as well as on macOS: Foundation's converters differ between systems for some encodings outside the table (code pages 936 and 950; Shift_JIS X0213 is missing on iOS).
- CI compiles with Xcode 26.6; nothing newer than iOS 26 / macOS 26 API and Swift 6.2 syntax.
- Fixtures are synthetic: `example.invalid` addresses, invented headlines. The Japanese fixture has kana, kanji, half-width kana and characters whose second byte is 0x5C, and avoids the characters `iconv` maps differently from the web mapping (〜 − ‖ ¢ £ ¬ — ¥ ‾) so that a fixture artefact cannot fail the test.
- The deadline is injectable so its test runs in well under a second.
- The in-batch same-link check must not treat two link-less items as the same; do not key it on an optional.
- The debate's probes are in the scratchpad (`rd04-critic`): the streaming pre-pass (`pkg/Sources/Sax`), the stub and loopback transports, the delegate shape that compiles in Swift 6 mode, the charset cases, the date traps. They are probes to read, not code to copy.
- After removing FeedKit: neither lock file mentions it, the GRDB and SwiftSoup pins are unchanged and identical in both, and the simulator build passes with `-disableAutomaticPackageResolution`. Documents: `README.md`, `docs/reader/spec.md` (section 6, and one line in section 10 that the package's own parser has not met real feeds yet), `docs/reader/open-source.md` (the library list and the sentence giving the reason for the original choice). `docs/reader/designs/RD01-ios-project.md` is a frozen record and stays as it is.
- The pull request and a comment on issue #125 state the departure from "parsing uses FeedKit" and its measured reason, for the owner.
- In the debate's probe the reduction of titles and excerpts, done there with SwiftSoup, dominated parsing time (30,000 ordinary items: about 2.4 s in a debug build). The design now uses its own linear reduction; SwiftSoup is not used anywhere in this issue's parsing path unless a call is shown to be linear by the criterion-13 test.
- The system date formatters have the two traps listed under "Measured in round 2"; parse dates by hand or prove each formatter use against whole-string matching and the zone table.
- Keep the parser free of the network and the store, and the fetcher free of the store.

## Risk assessment

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| The package's own tokenizer mis-reads a construct real feeds use | Medium | Medium | Criterion 18's comparison with the system parser on generated documents and edited fixtures; fixtures for every mapped field; RD05's preview meets real feeds early |
| A defect in the package's own parsing code traps on hostile input (Swift turns an index error into a crash) | Low | High | Criterion 17's corpora and byte edits on a small stack; no unchecked buffer access |
| A feed that uses entities declared in its own document type loses everything after the first use | Low | Low | Recorded; RD05 can add the HTML named entities if real feeds show the need |
| A real feed uses a construct the fixtures do not | High | Low | Every field is optional by construction and a broken document keeps its completed items; RD05's preview shows real feeds early |
| The loopback listener does not work on CI | Low | Medium | Reported, with those checks kept local |
| Storing content HTML bloats the database | Low | Low | Bounded per collection by the response limit; lists do not read it; retention (RD06) removes old rows. Deleted rows do not shrink the file, since `VACUUM` is unavailable on library connections (RD02) |

## Out of scope

As Non-goals.

## Test plan

- Parser: the four formats; the Japanese fixtures, the nine-character fixture and the charset rule both ways (criterion 2); one unusable part per kind, and documents that break part-way — unescaped `&`, an entity reference, an invalid UTF-8 byte, truncation inside a character — keeping their completed items and reported incomplete (criterion 3); not-a-feed documents (criterion 4); the work counter over all corpora and the timing shapes (criterion 13); the hostile corpora, limits, random-byte decoding and cancellation, on a detached task (criterion 17); the comparison with the system parser and one test per intended difference (criterion 18); elements matched by namespace under an unusual prefix; unbound prefixes; Atom XHTML content rebuilt with text and attributes escaped; relative links and image addresses; titles of each kind (criterion 11); content and excerpt sources (criterion 12); each identity fallback; link-less items.
- Dates: each accepted form with numeric offsets and with each listed abbreviation; an unknown abbreviation; zone-less; date-only; strings that merely start with a date; rejected forms; the future rule.
- Transport, stubbed loading: success with validators; `304`; deadline; announced and streamed size limits; 5 and 6 redirects; refused redirect schemes.
- Transport, loopback listener: cookies; decompressed size; a real 401 recorded as `http:401`; embedded credentials in the address and in a redirect; a redirect to a `file:` address; the exact headers on the wire.
- Fetcher: each outcome without a library.
- Collector (fake transport, injected clock): first and second collection; `304`; an incomplete document stores its items, counts as success and clears the validators; dates; same link across sources and within a batch; each failure code recorded and cleared; a failing source beside a healthy one; cancellation; missing, wrong-kind and deleted-meanwhile sources; a rename during the fetch survives; `content_html` stored verbatim including a script element, with nothing fetched.
- Schema: `v2` on the `v1` fixture; the list record does not read `content_html`.
- Both `AGENTS.md` commands pass; the package suite passes on the iOS 26.5 simulator, the decoding and hostile-input tests included.

## Handoff notes

Branch `feat/rd04-feed-collection` from `main`; the design is committed there by the driver. Commit locally; do not push.

## Debate record

**Round 1 (2026-11-11).** A critic agent attacked version 1 with FeedKit, SwiftSoup, a URL-loading stub and a loopback listener in a throwaway package. Nineteen findings; all supported, all accepted.

| ID | Severity | Finding | Resolution in version 2 |
| --- | --- | --- | --- |
| F1 | P1 | FeedKit decodes all-or-nothing | Own minimal shapes behind a lossy wrapper; own date parsing (criterion 3) |
| F2 | P1 | Credentials embedded in an address are sent whatever the delegate answers | Such addresses and redirect targets are refused (criteria 6, 7) |
| F3 | P1 | Full text carried in the description was lost for good | `content_html` falls back to the description; plain text escaped (criterion 12) |
| F4 | P2 | The stub cannot show cookies, decompression or a real 401 | Loopback listener inside the test process |
| F5 | P2 | Default headers disclose the device's languages and the process name | Fixed headers, asserted on the wire (criterion 7) |
| F6 | P2 | A refused redirect hung until the deadline under the stub | The delegate records the reason and cancels the task |
| F7 | P2 | "Declines challenges" was unspecified; cancelling loses the 401 | Record 401 and cancel for HTTP and client-certificate challenges; default handling for server trust |
| F8 | P2 | Cancellation, missing sources, lost updates and the conflict clause were unspecified | Criterion 14; the Storing paragraph |
| F9 | P2 | Parse time is quadratic in item count | 5,000-item cap (criterion 13) |
| F10 | P2 | RD05 could not reuse the parser and the classification | `ParsedFeed`; `FeedFetcher` without a library |
| F11 | P2 | Fixture recipe trap; header-only charsets failed | CP932 fixtures avoiding the divergent characters; header charset written into the declaration (criterion 2) |
| F12 | P2 | Non-feeds were accepted as empty feeds | Root and minimum checks (criterion 4) |
| F13 | P2 | Reducing every title deleted literal text | Only HTML titles are reduced (criterion 11) |
| F14 | P2 | Failure codes inconsistent; fixture holds a non-code | Free-text column, tolerant reader, mapping table |
| F15 | minor | `content_html` on the list record made every fetch carry bodies | List record does not select it (criterion 16) |
| F16 | minor | Identity and same-link details open | `rdf:about`; raw strings hashed; link-less items; permalink identifiers; insert order |
| F17 | minor | FeedKit's date parsing is silently wrong in places | Own date parsing; zone-less dates as UTC, recorded |
| F18 | minor | Notes RD06 needs | Recorded under "For RD06" |
| F19 | minor | Smaller mapping gaps | `media:content`; addresses resolved; document-level `xml:base` a non-goal |

**Round 2 (2026-11-11).** The same critic probed version 2's parser design and revalidated. F2–F6, F8, F12, F14–F19 resolved; F1 resolved in direction; F7, F9, F10, F11, F13 partly or reopened through the findings below. Nine new findings.

| ID | Severity | Finding | Resolution in version 3 |
| --- | --- | --- | --- |
| F20 | P1 | Applying the header's charset whenever the document declares none corrupts or fails feeds that parse as sent | Parse as sent first; the header charset only after a failure, written correctly, once (criterion 2) |
| F21 | P2 | The item cap did not bound parse time: FeedKit's reader is quadratic in siblings and in text size | The package parses with the system's streaming parser; FeedKit removed; criterion 13 is now a linear-time test |
| F22 | P2 | Own shapes on FeedKit's reader needed per-field tolerance, a specific text overload and no nested containers | Moot: that reader is not used; every field is tolerant by construction |
| F23 | P2 | Cancelling client-certificate challenges breaks servers that merely offer them; "401" was recorded for statuses never sent | Default handling for client-certificate challenges; the real status (401 or 407) recorded |
| F24 | minor | Two transport outcomes had no row | Added |
| F25 | P2 | Two traps in the system date parsers | Zone table, whole-string matching, tests |
| F26 | minor | Insert order versus "earlier in the batch" | Duplicates decided in feed order, survivors inserted in reverse feed order |
| F27 | minor | "Does not select `content_html`" needed a mechanism | Declared selection; raw insert; test on the statement's columns |
| F28 | minor | `User-Agent: NewsPaw` is unique to one person | A generic value |

Also from round 2: the fetcher returns a non-feed document to its caller (F10); RSS and RDF titles are stated to be treated as HTML (F13).

**Round 3 (2026-11-11).** The critic revalidated version 3 and checked the streaming parser's events for namespaces, attributes, CDATA, XHTML and Shift_JIS. F20–F28 resolved; everything in the parser approach is achievable in one pass. Five new findings, no P1.

| ID | Severity | Finding | Resolution in version 4 |
| --- | --- | --- | --- |
| F29 | minor | The one charset retry can turn a clean failure into wrong text | Recorded as a known limit |
| F30 | P2 | "Not well-formed is not a feed" discarded items already read | Completed items are kept, the collection succeeds, validators are not stored (criterion 3) |
| F31 | minor | Criterion 13 as an absolute bound would flake or be too loose | A ratio test, N against 4N |
| F32 | minor | FeedKit's removal: documents and lock files | Lock files rewritten by the resolvers and checked; document list completed; issue comment |
| F33 | minor | Leftover wording from the item cap and the wrapper | Removed |

Version 4 changes only what round 3 measured or decided, so no further round was run.

**After freezing (2026-11-11), from planning RD05.** Three additions RD05 needs, none changing a decision: the parsed feed carries its format; a non-feed answer carries its charset; the deadline has its own code `timed_out` (the mock-up words a timeout separately); and the collector is stated not to look at `paused`.

**Version 5 (2026-11-11).** RD05's debate measured that SwiftSoup's tree builder is quadratic on nested table markup (50 KB 1.2 s; 200 KB 19 s; release build). RD04 would have fed it descriptions of any size. Text reduction is now a linear scanner in the package, with a fourth shape in criterion 13. No other decision changed; no further debate round was run for this hardening, and the implementer must show linearity by test. The same exposure exists for RD11 (HTML to blocks) and RD05 (discovery) and is handled in their designs.


**Implementation review of version 5 (2026-11-12).** The internal reviewer attacked the implementation in two rounds, and the driver probed the first repair. All findings were reproduced.

| ID | Severity | Finding | Outcome |
| --- | --- | --- | --- |
| R1, R14 | P1 | About 480 nested JSON objects overflow the stack inside the system JSON parser; after a byte pre-scan was added, UTF-16 input passed it | Version 6: own JSON reader, depth limit 64 |
| R2 | P1 | An internal entity referenced many times: quadratic (320 KB, 3.8 s) | Version 6: the document type is not interpreted |
| R3, D2, D3 | P1 | Many attributes on one tag (4.3 MB, 41 s) and many namespace mappings: quadratic before any callback; the byte pre-scan added against it was bypassed through encoding labels the system parser knows and the scan did not (`pck`, `ibm-942`), and through unreadable declarations | Version 6: own tokenizer with an attribute limit; labels only select a decoder |
| R11 | P1 | After an error the system parser stops its callbacks but parses on to the end of the current megabyte, which defeats every guard that waits for a callback (64.6 KB, 3.25 s; 337 KB, over 5 minutes) | Version 6 |
| R12 | P1 | Stopping the system parser inside the namespace-mapping callback is a use-after-free (a 12 KB document crashes the process); introduced by a guard | Version 6 |
| R13 | P1 | An enumerated attribute type with 20,000 values overflows the stack inside the system parser before any callback | Version 6 |
| R15 | P1 | Long JSON keys colliding in the system string hash: quadratic (11.3 MB, 23 s) | Version 6: own values keyed by bytes |
| R4 | P2 | An exchange that ended before it started never returned | Fixed in fix round 1 (kept) |
| R8, D1 | minor | Test gaps; a timing test that failed under load | Fixed in fix round 1 (kept) |
| R5, R6, R7, R9, R10, R16, R17 | minor | Atom XHTML wrapper; namespaces dropped in rebuilt XHTML; declared-entity text dropped; which of two same-identity items is kept; white space before `<?xml`; false refusals of the first repairs; memory on deep nesting | R7, R16, R17 are overtaken by version 6; R5, R6, R9 deferred; R10 handed to RD05 |

**Debate on version 6 (2026-11-12).** The same reviewer attacked the proposal with measurements. Posture: sound with changes; it advised against going back to patching. Eight findings, all accepted.

| ID | Severity | Finding | Resolution in version 6 |
| --- | --- | --- | --- |
| V1 | P1 | Swift's `String` hashing and comparison are quadratic on a long run of combining marks (640 KB key: 48–69 s); the mapping code kept from version 5 compares feed strings | Invariant: no feed-supplied string is hashed or compared as a `String`; byte matching through a counting helper; the shape added to criterion 13 |
| V2 | P1 | Strict decoding of the whole body would break criterion 3 (a download cut inside a character) and the proposal's retry condition weakened criterion 2 | Package-side UTF-8 validation up to the first invalid byte; version 5's selection rule kept; legacy encodings all-or-nothing with a truncation retry |
| V3 | P2 | An unbound prefix would end the document; the system parser reads such feeds | Tolerated; listed as an intended difference |
| V4 | P2 | Criterion 18 could not hold as worded: the system parser is not a clean oracle, and the generator's idea of well-formed would hide false stops | The system parser's verdict decides; listed differences with their own tests |
| V5 | P2 | Criteria 13 and 17 could pass while their property is false | The work counter; corpora on a small stack; high-water marks asserted |
| V6 | P2 | Foundation's EUC-JP gives seven code points that differ from the web's | Mapped to the web's after decoding, with an exhaustive test |
| V7 | minor | XML details the specification must state | Stated under Approach |
| V8 | minor | "No system parser" overstated: Foundation's converters and `URL` still see hostile input | Worded exactly; measured linear; random-byte decoding in criterion 17 |

Version 6 is frozen with these resolutions; no further debate round was run, since each resolution is the critic's own accepted change.