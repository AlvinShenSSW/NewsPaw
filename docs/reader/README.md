# NewsPaw Reader

On 2026-11-11 the owner redirected NewsPaw from a Mac app that sends Telegram digests to a reading app for iPhone and iPad. This directory is the new baseline.

**Status: baseline approved by the owner on 2026-11-11. No code has been written.** The result of the Kimi K3.1 Pro design review is in spec.md, section 12.

| Document | Contents |
| --- | --- |
| [spec.md](spec.md) | Product specification: scope, requirements N01–N13, data model, configuration file, technical approach, milestones, what changes from the old system, assumptions, settled decisions |
| [ux.md](ux.md) | Structure on iPhone and iPad, every screen, states and wording, visual design, accessibility |
| [backlog.md](backlog.md) | Epics E11–E18 and issues RD01–RD26 with their GitHub numbers, dependencies and requirement coverage |
| [open-source.md](open-source.md) | Survey of open-source readers, the decision not to fork, libraries chosen, what to borrow |
| [Mock-ups](https://claude.ai/artifact/GkfmtsiAT1Vz1VWDsTPqU5) | Design canvas with the main screens (private to the owner) |

Scope in one paragraph: a TestFlight build for the owner alone. Feeds, GitHub / Hugging Face and bookmarked web pages, filed into categories; a normal and an adult partition with separate storage and separate models; titles translated automatically, bodies when opened and web pages in place with one tap, using the owner's own model keys; a daily overview per category; configuration moved between devices by file. No Telegram, no Mac app, no server, no sync. An App Store edition is a distant epic and out of scope.

Everything outside this directory — `docs/planning/`, `docs/designs/specs/`, `docs/mockup/`, the Python and macOS code, and the product lines of `AGENTS.md` — describes the old system. The old product's final state is tagged `mac-v0.6.4-final`; its files leave `main` in the issue that creates the iOS project (RD01; spec.md, sections 9 and 11).

Project language: code, documentation, issues, epics and pull requests are written in English. Conversation with the owner about requirements is in Chinese.
