# R06 / #84 — native settings shell, typed client, shared editor state

Implements interaction-spec §0.3, §1 and §2 for the window shell. Page content is R07–R12.

## Frozen issue contract

1. **Shell.** One window (`id: settings`, default 1180×820, minimum 900×600) with a `NavigationSplitView`: a 200pt sidebar listing Overview, Digests, X Accounts, Connections and Settings as coloured 20pt symbol tiles, ⌘1–⌘5 to switch, the page name as the window title, a toolbar refresh, and the backend state in words at the bottom of the sidebar. While the backend is unreachable every page except Settings shows a "backend not running" group with the login-item controls.
2. **Typed client.** `BackendClient` sends `Operation` cases and decodes typed results; failures are `BackendError {code, domain, field, retryable}` read from R02's `error_detail` (older replies fall back to the bare code). Socket timeouts for slow operations are set in one function.
3. **Shared editor.** `EditorState.apply(change)` loads the newest record, applies the change and saves with that revision; one background conflict is merged by reloading and applying the same change again; only a second conflict in a row, or any other failure, is reported. The language pickers and the pause switch use it.
4. **Words.** `Words(zh, en, ja)` cannot be built without all three; new copy lives in `L10n` namespaces; `FailureCopy` turns a code into "what happened, what to do" plus at most one action, with a fallback that names the code.
5. **Failures.** No screen shows "Language was not saved to the backend" for an unrelated failure: views written before the redesign display the actual failure's copy through `AppModel.text(.saveFailed)`, and the shell shows a `FailureNote`.
6. **Menu bar.** Status, Open NewsPaw (⌘O), Pause/Resume All Deliveries, Quit window. Stopping the backend moved to Settings behind a confirmation.

Non-goals: page content (R07–R12), socket security, new sheets.

## Contract correction (repository evidence)

The issue asks that no view uses operation strings. About 4,000 lines of pre-redesign settings views (15 sheets) do, and R07–R12 delete each of them when its page is rebuilt. Converting them first would be throw-away work. R06 therefore routes every request — including those views' — through the one `BackendClient` (single envelope parser, error type and timeout table), uses typed operations for the shell and everything new, and keeps a clearly marked `AppModel.request(String:)` bridge that disappears with the last legacy view. Likewise, background-revision merging is guaranteed for editors built on `EditorState`; the legacy sheets keep their behaviour until they are replaced.

## Verification

- `swift test`: 30 tests — failure envelope and fallback, timeout table, status/readiness decoding, editor merge of one conflict, report of a repeated conflict and no retry for other failures, offline → `backend_unreachable`, completeness of every `Words`, failure copy, legacy views showing the real failure, language save with 0/1/2 conflicts through a real socket fixture, five distinct page titles per language.
- Offscreen window snapshots against an isolated backend for 5 pages × 3 languages × light/dark (`WindowSnapshots.swift`, opt-in by environment). Offscreen drawing cannot reproduce the sidebar's translucent material, so tile colours and the selected row look flat in those images; the tiles render correctly outside the sidebar. A live-window check of the sidebar needs screen recording permission or the owner's eyes.
