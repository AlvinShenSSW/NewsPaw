# Archive: the retired Mac + Telegram product

These documents describe NewsPaw's previous product, a macOS menu-bar app with a Python backend that sent news digests through Telegram. That product was retired on 2026-11-11 in favour of the iPhone / iPad reader specified in [`docs/reader/`](../reader/README.md).

- **Not maintained.** Nothing here is current. Do not take requirements, designs or test plans from these files; the reader's baseline is `docs/reader/`.
- **Not translated.** Many of these documents are in Chinese and stay that way; the project is written in English from the reader onwards.
- **Moved unchanged.** The files were moved here as they were, keeping their relative layout, so links between archived documents still resolve.
- **The matching code** — `src/`, `tests/`, `macos/`, `packaging/`, `pyproject.toml`, `uv.lock` — was removed from `main` and is kept at the tag `mac-v0.6.4-final` (for example, `git show mac-v0.6.4-final:pyproject.toml`). Paths to code in these documents refer to that tag.

| Path | Contents |
| --- | --- |
| `planning/` | Requirements, audits, roadmap and backlog of the old product |
| `designs/specs/` | Per-issue implementation designs |
| `mockup/` | The five-page settings-app mock-up and its later redesign (`redesign/`) |
| `testing/` | Verification and release records |
| `architecture.md`, `system-design.md`, `source-strategy.md`, `model-routing.md`, `delivery-formats.md`, `telegram-routing.md` | System-level design documents |

Known breakage: the six redesign mock-ups in `mockup/redesign/` (`connect.html`, `digests.html`, `overview.html`, `settings.html`, `setup.html`, `x-accounts.html`) load the logo through the relative path `../../../assets/branding/newspaw-logo-preview.jpg`, which no longer resolves from this directory. The image itself is still at `assets/branding/newspaw-logo-preview.jpg`.
