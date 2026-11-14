# RD13 — Model slots, keys and the model client

Issue: [#134](https://github.com/AlvinShenSSW/NewsPaw/issues/134) · Epic E14 #117 · Requirements N08, N11 (records), N12 (https for model services); ux S8 (Models & translation), S9, section 4 (wording). Also touched: N02 (partitions), N10 ("Key needed"), N13 (offline tests).
Design version 2, 2026-11-14, frozen after one debate round (see the last section). Author: Claude (planner, for the driver of this AFK run). Implementer: Claude Opus 5.5. External gate: Codex `gpt-6.1-sol` at high effort.

Builds on the merged code of RD02 (libraries, migrations `v1`–`v4`), RD03 (Settings, navigation) and RD06 (`setting` table, the debug launch options). Names below are the merged ones as read at main `bdf791b`. RD10 (#131) is being implemented in parallel on its own branch; it changes neither `Schema.swift` nor `SettingsView.swift`, and both branches change `AppModel.start()` and the string catalog.

The owner's instruction for this phase (2026-11-12): one user, converge, no over-engineering. Where this design chooses the smaller of two mechanisms, that is why.

## Spec review

Nothing in the app can reach a model today. Every later translation issue (RD14–RD16), the overviews (RD23) and the configuration file (RD20) need three things from this one: a place where the owner enters a service, a model and a key; one way to send texts to that model and get texts back; and a record of every request.

Core need: the owner sets up a primary model and, if wanted, a backup; can see whether the service accepts them; and the key entered is stored where only this device can read it and is sent to that one service and nowhere else.

**Settled here**, because the issue and the specification leave it open:

1. **Storage.** Migration `v5` creates `model_slot` and `usage` (spec section 4). `model_slot.role` is the primary key (`primary` / `backup`), so a library holds at most two slots. Besides the spec's fields it has `test_outcome` (decision 9). `key_ref` may be null. `usage` gets an index on `at`.
2. **Keys.** A key is a generic-password item of the device keychain. The exact attributes: class `kSecClassGenericPassword`; service `io.newspaw.reader.model-key.<partition>`; account = a random UUID (the slot's `key_ref`); on add, `kSecAttrAccessible` = `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and `kSecAttrSynchronizable` = false; on every query, `kSecUseDataProtectionKeychain` = true (so a macOS build of the package can never fall back to the file-based login keychain: there it answers -34018). "After the first unlock", not "while unlocked": title translation after a refresh (RD14) can run in the background time RD06 already asks for, after the screen has locked. The package reaches the keychain through one interface, `KeyStore` (add → reference, read, remove), with the real `KeychainKeyStore` and an in-memory one for the package tests (spec section 6 names the keychain as one of the five stand-in points). A key store is made for one partition and names only that partition's service; as with `Library`, the separation is by construction — ordinary code is handed one store — and `LibraryModels` refuses, by precondition, a store whose partition is not its library's.
3. **A stored key belongs to the service it was entered for.**
   - *Order of writes.* Save with a new key: add the keychain item under a new reference; write the row; then remove the item of the old reference. If the row cannot be written, the new item is removed and the old slot is unchanged. Removing a key or a slot: the keychain item first, then the row. "No such item" from the keychain counts as removed, everywhere.
   - *A changed address.* The stored key is usable only while the form's address has the same origin — scheme, host and port — as the saved one. Once the origin differs (another preset chosen, another host typed), the form shows "Key needed", Test and Load List do not use the stored key, and Save removes the stored item and writes the row with no reference unless a new key was typed. Changing only the path keeps the key.
   - *No key.* A slot with no reference, and a slot whose reference has no item (a restore onto another device; a failure between two steps), are the same state, **"Key needed"** (N10's wording): the row and the form say so, `send` fails with "key needed" without a request, and Test and Load List are disabled until a key is typed. There is no sending without a key.
   - An item no row names can remain after a failure between "write the row" and "remove the old item"; it is invisible and never sent. No sweep is built for it.
4. **A key is a value that does not print.** `SecretKey` wraps the string; its description, debug description and mirror show a fixed placeholder, and it is not `Codable`. The HTTP stand-in's request carries it as `authorization: SecretKey?`, apart from the other headers; the only code that reads the string is the keychain store and the one line of `URLSessionModelHTTP` that writes the `Authorization` header while building the `URLRequest`. No `URLRequest` is ever printed or dumped (its `dump` shows header values). Error types of the model code carry no text from the service (a service may echo the key in an error message): they are closed enumerations. Nothing in `AI/` or `Privacy/` logs: there is no `print`, `Logger`, `os_log` or `NSLog` in those directories, and a test scans for them.
5. **Address, model name and key are validated when saving and again when sending.**
   - Address: `https`, a host, no user name or password, no query and no fragment, at most 2,048 characters; trailing slashes are removed. In a debug build `http` is also accepted when the host is `localhost`, `127.0.0.1` or `::1`. The rule is one pure function with a flag, `ModelAddress.normalise(_:allowsLoopbackHTTP:)`; the flag's one production value is a constant that is `true` only inside `#if DEBUG`.
   - Model name: not empty after trimming, at most 200 characters, no control character.
   - Key: surrounding white space and line breaks are removed (pasted keys); what remains is 1 to 4,096 printable ASCII characters. Anything else is refused: a line break in a key would write a second header.
6. **Presets fill in the address and nothing else.** OpenAI `https://api.openai.com/v1`; DeepSeek `https://api.deepseek.com`; xAI `https://api.x.ai/v1`; MiMo `https://api.xiaomimimo.com/v1`; OpenRouter `https://openrouter.ai/api/v1`; Gemini (compatible) `https://generativelanguage.googleapis.com/v1beta/openai`; Custom: empty. Choosing a preset replaces the address field; editing the address afterwards keeps the preset's name. The addresses are the ones the services' public documentation gives (read during the debate, except OpenAI's, which is from memory); each is confirmed by its real-service check (decision 13) before the preset is called supported.
7. **The requests.** Chat: `POST <address>/chat/completions` with `{"model": …, "messages": [system, user], "stream": false}` and nothing else — no temperature, no token limit, no response format: each of those is refused by some current model, and the reply's shape is checked by the app anyway. List: `GET <address>/models`. Both carry `Authorization: Bearer <key>` and `Accept: application/json`, and the chat `Content-Type: application/json`. An ephemeral session without cookies, credential storage or cache, separate from collection's, with `tlsMinimumSupportedProtocolVersion` = TLS 1.2 (the app allows arbitrary loads for http feeds, which also lifts the system's floor for these requests). **No redirect is followed**: the delegate refuses every one, the 3xx answer is a failure, and exactly one request is made. An HTTP authentication challenge is cancelled — answering it any other way sends the request a second time — and the status that raised it is recorded first, as collection's transport does, so that a 401 with a `Basic` challenge is still a 401. Deadlines: 120 s for a chat request, 30 s for a list. Replies larger than 4 MB are a failure. Error bodies are read (up to 64 KB) to classify the failure, and are never stored or shown.
8. **The internal interface is "texts in, texts out".** `send(texts:instructions:purpose:role:)` returns the reply's texts, whether the reply was cut off, and the token counts when the service returned them. The system message is the caller's instructions followed by one fixed sentence that fixes only the reply's shape: reply with only a JSON object `{"texts": [...]}` whose members are strings. How many strings, and in what order, is for the caller's instructions to say (RD14: one per input, in order; RD23: its own). The user message is the JSON array of the input texts. Reading a reply, in this order: a `refusal`, or `finish_reason` = `content_filter`, is "refused"; content that — after removing a surrounding Markdown code fence — parses as that object or as a bare array of strings is the reply, with the cut-off flag set when `finish_reason` = `length`; content that does not parse is "cut off" when `finish_reason` = `length` and "malformed reply" otherwise. Whether the count matches and the lengths are plausible is RD14's acceptance (N06), not the client's. The prompts themselves are RD14's and RD23's. Choosing the backup after a failure is RD14's (N06): here the caller names the role.
9. **Test and Load List act on what the form shows, without saving.** Both need an address and a usable key (decision 3); Test also needs a model name. The key is the one typed, or the stored one when no new key was typed and the origin is unchanged. Test sends the texts `["Hello"]` with the instruction "Repeat the text." and passes when the service answers 200 with a chat completion that has a message — the reply's content is not judged. The result is one line under the button. It is stored with the slot (`test_outcome`) when the tested address, model and key are the saved ones — at once if they already are, at Save if the form is then saved unchanged since the test. A save that changes the address, the model or the key without such a test sets the slot back to "Not tested". Saving never sends a request.
10. **How an answer becomes an outcome.**

    | Answer | Test line | `send` failure | `usage.outcome` |
    | --- | --- | --- | --- |
    | 200, a completion | Passed | — (or refused / cut off / malformed, decision 8) | `ok`, `refused`, `cut_off`, `malformed` |
    | 401 (also when it arrives as a cancelled challenge), 403 | Key rejected | key rejected | `key_rejected` |
    | 404 whose JSON body is an object with an `error` member, or an array whose first element has one | Model not found | model not found | `model_not_found` |
    | 400, 413, 422 | Model not found | bad request | `bad_request` |
    | 402, 429 | Quota or rate limit | limited | `limited` |
    | 5xx | Could not connect | server error | `server_error` |
    | No answer, deadline, TLS failure, a redirect, a 407 challenge, 404 without such a body, any other status, a 200 that is not a chat completion, a reply over the size limit | Could not connect | unreachable | `unreachable` |
    | The calling task is cancelled | — | cancellation | `cancelled` |
    | "Key needed", or no slot for the role | — (Test is disabled) | key needed / no model set up | no row: no request was made |

    For Test, a 400 is shown as "Model not found" because Test's request is fixed by the app, so what a service objects to is in practice the model's name. For `send` it is its own failure: a real text can be too long for the model, and that must not look like a missing model or send RD14 to the backup. Services differ in these statuses and not all could be confirmed from documentation; decision 13 measures them.
11. **Usage.** Every chat request that was sent — Test included, whatever its outcome — writes one `usage` row in its library when it ends: a new id, the model name as sent, the purpose (`titles` / `body` / `page` / `overview` / `test`), `prompt_tokens` and `completion_tokens` when the reply has them as non-negative integers (null otherwise), the outcome of decision 10, the time. The row is written from a new unstructured task whose value is awaited, because the database's asynchronous write refuses to start in a cancelled task and the row of a cancelled request would otherwise be lost. A failure to write the row does not fail the request and is not reported. Load List writes no row: N11 records model requests, and a list names no model and has no purpose. The Usage screen and the daily limit are RD17 and RD14.
12. **One object per library.** `LibraryModels` is made from one `Library`, one `KeyStore` of the same partition and one HTTP stand-in point, and is the only way to read slots, save them, test, list and send. It has no parameter that names a slot of another library, and there is no default slot: with no row for the asked role it throws "no model set up". The app makes one, for the normal library; the adult partition's is RD19.
13. **The real-service check** is one package test, disabled unless `NEWSPAW_LIVE_MODEL_KEYS` names a file. The file is outside the repository (the owner's: `~/.config/newspaw/model-keys.env`) and holds, per service to check, `<NAME>_API_KEY`, `<NAME>_MODEL` and optionally `<NAME>_BASE_URL`, with `<NAME>` one of `OPENAI`, `DEEPSEEK`, `XAI`, `MIMO`, `OPENROUTER`, `GEMINI`. For each service present it makes four requests through the real session: the model list; a chat with two short English sentences and the instruction to translate them into Simplified Chinese, expecting two non-empty texts; the Test request with a deliberately wrong key (a fixed made-up string); the Test request with a model name that does not exist. It prints, per service and step, the HTTP status and the outcome only — never a body, never a key. A service absent from the file is reported as "not run". The implementer writes the test and does not run it; the driver runs it with the owner's file, and the pull request records per preset: passed, failed (which step, which status), or not run. A mapping in decision 10 that a real service contradicts is reported to the owner with the measured status; it is corrected in this issue only when the correction is a row of that table.
14. **Settings.** A first row "Models & Translation" (ux S8 order) opens a screen with two rows, "Primary Model" and "Backup Model", each showing the model's name and its state: Not set up · Key needed · Not tested · the last Test line. The reading-language and translation switches of that screen arrive with RD14. Each row opens the S9 form: preset, address, model name with "Load List", key, "Test" with its line, and "Remove Model" for a saved slot. The backup's form begins with the one sentence of ux S9.
    - The key field is a secure field. With a usable stored key the form shows "•••• " and the key's last four characters — only the dots when the key is shorter than 12 characters — with "Replace" and "Remove"; the stored key is never put into a field. "Replace" shows an empty secure field with "Cancel", which goes back to the stored key; Save is disabled while that field is empty. "Remove" asks for confirmation, removes the key at once (decision 3's order) and leaves the slot at "Key needed".
    - "Load List" shows the returned model identifiers, sorted, in a searchable list (at most 1,000); picking one fills the model field. A failure shows one line with the wording of decision 10.
    - **The backup can be set up only when a primary exists, and the primary cannot be removed while a backup exists**: the Backup row is disabled with "Set up the primary model first", and the primary's "Remove Model" is disabled with "Remove the backup model first".
    - Leaving the form with unsaved changes asks before discarding (the pattern of the category and source sheets).
15. **Wording.** The Test line uses ux S9's five labels and "Not tested"; a slot without a usable key says "Key needed" (N10). Under a failed line, the sentence of ux section 4 where it has one: key rejected → "The service rejected the key"; quota or rate limit → "The service is limiting requests. Try again later"; could not connect → "Could not reach the service". Section 4 has no sentence for "Model not found"; this design adds "The service does not have this model" (服务里没有这个模型). Every new string has a Simplified Chinese translation; "Key" stays "Key" in Chinese, as in section 4. The strings check proves only that a translation exists; that the Chinese of the section 4 sentences is section 4's own is checked by reading the catalog against it.

**For the owner** (each is a choice the issue left open; none changes the specification's meaning):

1. Test and Load List use what the form shows and do not save. The typed key is sent to the typed address when one of them is pressed.
2. A model always needs a key. Removing the key leaves the model at "Key needed"; nothing is sent without one.
3. Changing the address to another service (another host) drops the stored key: the form asks for a key again. This is what keeps a key from being sent to a service it was not entered for.
4. The backup needs a primary; remove the backup before the primary.
5. A Test result is remembered with the model and goes back to "Not tested" when the address, the model or the key changes.
6. A 400 answer to Test is shown as "Model not found"; a 404 that does not look like the service's own error is shown as "Could not connect" (usually a wrong address). Some services answer a wrong address or a wrong key with other statuses; the real-service check records what each does. On OpenRouter a moderation block (403) reads as "Key rejected".
7. Requests ask for nothing optional (no temperature, no output limit, no JSON mode); the app checks the reply's shape itself.
8. MiMo: the preset's address is the ordinary one. A Token Plan key (`tp-…` or `ttp-…`) works only at the plan's own address, which has to be typed over the preset's; with the ordinary address the Test line says "Key rejected". MiMo's own examples send the key in another header; this app sends the standard one, and the real-service check shows whether MiMo accepts it.
9. Keys can be read while the device is locked, once it has been unlocked after a restart, so that translation started by a refresh can finish after the screen locks.
10. No preset is called supported until its real-service check has run with the owner's key file (decision 13). That check sends four short requests per service, one of them with a made-up wrong key.
11. Loading the model list is not counted in Usage.
12. One new sentence that ux section 4 does not have: "The service does not have this model" / 服务里没有这个模型.
13. If the app is stopped at the wrong moment while a key is being replaced, the old key can stay in the keychain, unused and invisible, until the app is deleted.

## Acceptance criteria

| # | Criterion | Evidence |
| --- | --- | --- |
| 1 | A primary slot can be created, edited and removed from Settings; a backup likewise once a primary exists; the rules of decision 14 hold | UI test on iPhone and iPad |
| 2 | A saved key survives a relaunch, is shown only as dots and its last four characters, and is in no field | UI test (relaunch; the accessibility tree does not contain the key) |
| 3 | The key string appears in none of: any thrown error's description; the description, debug description or `dump` of the stand-in's request, of a reply or of a slot value; any row of any table; the bytes of the library's files. No logging call exists in `AI/` or `Privacy/`. (Exported data does not exist until RD20; the key is in no row, so it cannot be exported.) | Package test with a sentinel key, against stubs that echo the key in error bodies and headers; a source scan |
| 4 | A redirect answer is not followed: the service receives one request, the redirect's target none, and the result is "unreachable" | Package test on the real session class against the tests' loopback server (`LoopbackServer`); UI test for the line |
| 5 | `http` is refused by the address rule with the flag off, and for a non-loopback host with it on; the flag's only `true` is inside `#if DEBUG` | Package tests of the function; a test that scans the sources for the constant |
| 6 | Each row of decision 10's table produces its Test line, its `send` failure and its `usage.outcome`; a 401 raised as a `Basic` challenge is "key rejected" with one request | Package tests on a stubbed HTTP and, for the challenge, the loopback server; UI test showing all five lines with their wording in English; the Chinese of the section 4 sentences read against section 4 |
| 7 | A library with no slot answers "no model set up" for both roles, and no request is made; a second library with a slot does not change that | Package test with two libraries |
| 8 | A usage row is written for a successful request, for each failure of a sent request, for a cancelled one and for a Test; none for Load List, "key needed" or "no model set up" | Package tests |
| 9 | Load List fills the model field from the service's answer; a failure shows its line | Package test; UI test |
| 10 | A key with a line break or a non-ASCII character is refused when saving; the request on the wire has one `Authorization` header | Package tests (the second against the loopback server) |
| 11 | Saving sends no request; a Test result is stored and cleared as decision 9 says | Package tests; UI test for "Not tested" after an edit |
| 12 | "Key needed": a slot with no reference or with a missing item shows it, `send` fails without a request, and the slot can still be removed | Package tests (the in-memory store without the item); UI test after removing a key |
| 13 | A stored key is never sent to another origin: after the address's host changes, Test and Load List carry no stored key, and Save removes the item | Package test with a stub that records which address received which key; UI test for "Key needed" after choosing another preset |
| 14 | The real-service check exists, is skipped without its variable, and prints no key and no body | Package test run without the variable; reading the test |
| 15 | The three checks pass; every new string is in the catalog with a Simplified Chinese translation | CI |
| 16 | Largest text size, dark appearance and Simplified Chinese: the two screens and the form show every label uncut | Screenshots (iPhone, iPad Pro) |

## Frozen issue contract

In scope: migration `v5`; `ModelSlot`, `ModelPreset`, `ModelRole`, `UsagePurpose`, `UsageOutcome`, `SecretKey`, `ModelAddress`; `KeyStore`, `KeychainKeyStore`, the in-memory store; the HTTP stand-in point, its URLSession implementation and its debug fixture; the chat encoder, decoder and classifier; `LibraryModels`; the Library queries for slots and usage; the "Models & Translation" screen and the S9 form with their strings; the real-service test; the wiring in `AppModel.start()`.

Out of scope: prompts, acceptance checks, retry, choosing the backup, the daily limit (RD14); body and page translation (RD15, RD16); the Usage screen (RD17); the adult partition's slots and its key store instance (RD19); the configuration file (RD20); streaming; native Anthropic or Gemini protocols; another key header than `Authorization: Bearer`; a price table.

Invariants:

- A key is written only to the keychain item of its reference and to the `Authorization` header of a request to the origin it was entered for. It is in no table, no preference, no error, no description.
- A model request goes to `<slot address>/chat/completions` or `<slot address>/models`, over https (loopback http in debug builds), and is never redirected or repeated.
- Code holding one library cannot read or use the other library's slots or keys.
- Offline tests make no external request and never touch the real keychain: package tests use a stubbed HTTP, the loopback server and the in-memory store; under a UI-test library directory the app's model HTTP is the debug fixture.
- A release build contains neither the fixture nor the loopback exception.

## Approach

**Package.**

- `Store/Schema.swift`: `registerV5`. `Store/Library+Models.swift`: read the two slots; write a slot; delete a slot; set a test result; insert a usage row; read usage rows (for tests and RD17).
- `Model/ModelSlot.swift`: the value types. The closed sets are stored as text and validated in Swift, like `kind`.
- `Privacy/SecretKey.swift`, `Privacy/KeyStore.swift` (the interface and the in-memory store), `Privacy/KeychainKeyStore.swift`.
- `AI/ModelAddress.swift` (the rule and the origin comparison); `AI/ModelHTTP.swift` (the stand-in point: one function from a method, an address, an optional `SecretKey`, other headers and a body to a status, headers and a body, or a transport failure); `AI/URLSessionModelHTTP.swift`; `AI/ChatWire.swift` (pure functions: encode a request, decode a reply, classify an answer, decode a model list); `AI/LibraryModels.swift`; `AI/FixtureModelHTTP.swift` (debug builds only).
- The fixture answers by host under `models.example.invalid`: `passed.` (a completion that returns its input texts, with token counts; a list of three models), `rejected.` (401), `nomodel.` (404 with an error body), `limited.` (429), `down.` (503), `redirect.` (302), and every other host as no answer.

**App.** `AppState/ModelSettingsModel.swift` (main actor, observable): the two slots, the form's fields and state, the running Test or list, the unsaved-changes question; it serialises its operations — one save, removal, Test or list at a time, the form's controls disabled meanwhile. `Settings/ModelsView.swift` and `Settings/ModelSlotForm.swift`; a `SettingsRoute.models` and, under it, routes for the two forms. `AppModel.start()`: the key store is `KeychainKeyStore(partition: .normal)`; under a UI-test library directory its service name ends with the directory's name, and the model HTTP is the fixture.

## Failure handling

| Failure | Behaviour |
| --- | --- |
| The keychain refuses to add an item | The save fails with "The key could not be saved"; nothing is written |
| The row cannot be written after a new key was added | The new item is removed; the save alert of the other settings screens is shown; the form keeps its fields |
| The keychain refuses to remove an item (any answer other than success or "no such item") | Removing stops there with an alert; the row stays |
| A slot has no usable key | "Key needed" (decision 3) |
| The address, model name or key is not acceptable | Save is disabled and the field's footer says what is wrong |
| Test or Load List fails | Its line (decision 10); nothing is saved or cleared |
| The form is left while a Test or a list is running | The request is cancelled; a cancelled Test writes its usage row and stores no result |
| A usage row cannot be written | Ignored |

## Assumptions

The implementer measures the first two on the simulator before building on them and reports the result.

| Assumption | If it does not hold |
| --- | --- |
| A1. The app can add, read and remove generic-password items with decision 2's attributes in the simulator when started by a UI test (the project has no entitlements file), and an item survives a relaunch | Under a UI-test library directory the key store is a debug-only file store inside that directory; the real keychain store is then covered only by reading and by a device check, and the hand-back says so |
| A2. On iOS, as measured on macOS during the debate: a delegate that answers a redirect with no new request receives the 3xx answer with one request made; a cancelled `Basic` challenge ends the task after one request | The redirect or challenge is refused by cancelling the task and reported from the recorded reason, as collection's transport does |
| A3. The package tests never use the real keychain: with `kSecUseDataProtectionKeychain` a macOS test process is answered -34018 | — (measured during the debate; the real store is exercised through the app only) |
| A4. The services' addresses, their acceptance of `Authorization: Bearer` and of this request shape, and their statuses for a wrong key and a wrong model | Decision 13; what a service contradicts is reported to the owner with the measured status |

## Risks

- A service that needs a parameter this design leaves out, or that answers with a status outside decision 10's rows, shows a less exact line. The real-service check shows which.
- Error bodies are read into memory to be classified; the 64 KB limit bounds that.
- The keychain keeps its items when the app is deleted and reinstalled on iOS; rows do not survive, so such items are unreachable. Not handled.
- Whether the system re-sends a POST by itself on a stale connection was not measured. If it does, the same address receives the request twice (no key goes elsewhere) and one usage row is written.

## Test plan

Package (`swift test`): the address rule and the origin comparison, table-driven; key validation; `SecretKey` printing; migration `v5` from a `v4` file; slot save / replace / remove with the in-memory store, with a failing row write, a failing store and a missing item; the changed-origin rule with a stub that records address and key; `ChatWire` encoding (exact JSON), decoding (object, bare array, fenced, refusal, cut off with and without parseable content, missing usage, malformed) and the classification table; `LibraryModels.send`, `test` and `listModels` on a stubbed HTTP, with the usage rows each leaves; cancellation and its row; two libraries; the sentinel-key test of criterion 3; `URLSessionModelHTTP` against the loopback server: headers on the wire, no cookies, a redirect, a `Basic` challenge, a deadline, an oversized reply; the source scans of criteria 3 and 5; the real-service test, skipped.

UI tests (iterated with `-only-testing`; the whole suite once at the final commit): create a primary with the `passed.` fixture host, Load List, pick, Test, Save, relaunch, see the dots and four characters and "Passed"; edit the model and see "Not tested"; choose another preset and see "Key needed"; each of the other four lines; the backup rules; Replace, Cancel and Remove of the key; Remove Model; the unsaved-changes question. On iPhone and one iPad. Screenshots for criterion 16.

## Handoff notes

- RD14: `LibraryModels.send` and its failures (key needed, no model set up, key rejected, model not found, bad request, limited, server error, unreachable, refused, cut off, malformed); the instructions must say how many strings to return; the backup is the caller's choice; `usage` has no column for automatic or manual — RD14 adds what the daily limit needs with its own migration.
- RD15: the cut-off failure and flag, for shrinking chunks; "bad request" for a text the model cannot take.
- RD17: `usage` rows and the index on `at`; rows are never deleted here.
- RD19: a second `KeychainKeyStore` and `LibraryModels` for the adult library; removing the adult partition must remove its keychain items.
- RD20: slots export without `key_ref`, test result or key; an imported slot starts at "Key needed" and "Not tested"; a merged slot keeps its key only when its origin is unchanged (decision 3's rule); import applies `ModelAddress.normalise` with the flag off.
- RD24: keys are readable after the first unlock.

## Revision record

Version 2 after debate round 1 (one fresh critic; 19 findings; experiments in the session's scratch directory on macOS 27: redirect and challenge behaviour of URLSession against a loopback server, keychain adds with and without the data-protection flag, what `dump` shows of a request).

| Finding | Disposition |
| --- | --- |
| C1 (P1) a stored key followed the address to another service | Admitted: decision 3's origin rule; criterion 13 |
| C2 the key crossed the stand-in as a plain header | Admitted: `authorization: SecretKey?` on the stand-in's request (decision 4) |
| C3 keychain attributes incomplete; a macOS build could use the login keychain | Admitted: the exact attribute set (decision 2); A3 restated |
| C4 a cancelled challenge turned a 401 into "Could not connect" | Admitted: the status is recorded first (decisions 7, 10; criterion 6) |
| C5 a URL-loading stub cannot show the redirect behaviour | Admitted: the loopback server (criteria 4, 6, 10) |
| C6 a cancelled request's usage row is never written | Admitted: written from an unstructured task (decision 11) |
| C7 400 as "model not found" is wrong for `send` | Admitted: "bad request" for `send`; the Test line unchanged |
| C8 the status mapping is unverified where services differ | Admitted, sized: two more requests per service in the real-service check; the 404 body rule also accepts an array. No per-service mapping is built |
| C9 keyless slots contradict N10's "Key needed" | Admitted, the smaller alternative: no sending without a key |
| C10 a missing item made a slot unremovable | Admitted: "no such item" counts as removed |
| C11 the fixed sentence constrained RD23 | Admitted: it fixes the shape only |
| C12 phantom usage rows for a missing key | Admitted: no row without a request |
| C13 a cut-off reply was reported as malformed | Admitted: "cut off" failure and outcome |
| C14 no TLS floor under the app's transport exception | Admitted: TLS 1.2 minimum on the model session |
| C15 DeepSeek's address; MiMo's key header and `ttp-` keys | Admitted: address corrected; the note for the owner; no second header built |
| C16 the partition claim overstated | Admitted: reworded; a precondition |
| C17 `tested_at` unused | Admitted: removed |
| C18 the strings check proves less than claimed; one new sentence | Admitted: criterion 6's evidence; For the owner 12 |
| C19 "logs" not covered by criterion 3 | Admitted: a source scan; export is RD20's |
