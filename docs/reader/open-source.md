# Open-Source Survey and Library Choices

Status: draft, 2026-11-11. Companion to [spec.md](spec.md).

Source: the owner's words 「如果 github 有开源的项目可以在基础上改的也可以借鉴」 (open-source projects on GitHub may be built on or borrowed from), and the later note that an App Store edition is a distant direction.

Method: on 2026-11-10/11 each repository's GitHub metadata, README, licence file and selected source files were read, along with Apple's developer documentation. **Nothing was cloned or built**, so "builds with the current Xcode" is unverified for every candidate, and effort estimates are judgement rather than measurement.

## Conclusion

**Write a new SwiftUI app on existing libraries, and borrow specific approaches from three MIT projects. Do not fork an existing app.**

- No candidate has both a hidden second partition and translation with the user's own key. Whichever is forked, those two parts are written from scratch.
- The only fork worth considering is NetNewsWire (MIT, mature, local-only). Its iOS interface is UIKit, its reader view depends on a private service key that is not in the repository, every new screen would be UIKit, and its upstream moves fast.
- GPL / AGPL projects (Folo, Twine) are ruled out. Whether those licences are compatible with App Store distribution is disputed, and the owner wants to keep an App Store edition possible.
- Our interface and data model — one partition at a time, visible translation state, daily overviews — differ enough from a traditional reader that writing the interface ourselves is the shorter path.

The cost: the reader polish NetNewsWire has built up over years (list performance, typography, tolerance for malformed feeds) has to be earned step by step. Feed parsing was first left to a mature library (FeedKit) to remove the hardest part of that; RD04 measured that FeedKit fails a whole feed over one bad value and takes time growing with the square of the document's size, so the package now parses feeds itself on the system's streaming XML parser, and tolerance for malformed feeds is earned through its tests.

## Candidate apps

| Project | Licence | iOS interface | iPhone / iPad | Last activity | Local-only | AI / translation | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- |
| [NetNewsWire](https://github.com/Ranchero-Software/NetNewsWire) | MIT | Swift, UIKit | Both, iOS 18+ | 2026-11-10 | Yes | None | Best fork candidate; not forked, borrowed from |
| [Folo](https://github.com/RSSNext/Folo) | AGPL-3.0 | TypeScript, React Native | Both | 2026-11-09 | No, needs a Folo account and backend | Yes | Unusable |
| [Twine](https://github.com/msasikanth/twine) | GPL-3.0 | Kotlin, Compose Multiplatform | Both | 2026-11-09 | Yes | None | Unusable (licence) |
| [FeedFlow](https://github.com/prof18/feed-flow) | Apache-2.0 | SwiftUI interface, Kotlin logic | Both, iOS 17+ | 2026-11-10 | Yes | None | Only worthwhile if Android is wanted later |
| [Fluent Reader Lite](https://github.com/yang991178/fluent-reader-lite) | BSD-3-Clause | Flutter | Both | 2026-11-03 | No, requires a sync service | None | Unusable |
| [ReadYou](https://github.com/ReadYouApp/ReadYou) | GPL-3.0 | Kotlin | Android only | 2026-08-11 | — | — | Excluded |
| [RLLM](https://github.com/DanielZhangyc/RLLM) | MIT | SwiftUI, Core Data | Both, iOS 17+ | 2025-02-04 (dormant) | Yes | Summaries, daily summary; several services | Borrow only |
| [Tsukuyomi](https://github.com/kaki-shu/Tsukuyomi) | MIT | SwiftUI | iPhone only, iOS 26+ | 2026-07-08 (single commit) | Yes | Own-key OpenAI-compatible translation and summary | Borrow only |

Notes per project:

- **NetNewsWire.** Each "account" has its own folder, database and OPML, and several local accounts are allowed — a ready-made example of partition isolation. Folders are one level deep. The reader view calls Feedbin's extraction service with keys that are not in the repository, so a fork would have to replace it. Has RSS / Atom / JSON Feed, OPML and background refresh. Trademark terms were not checked.
- **Folo.** The repository holds clients only; the mobile app depends on sign-in and `api.follow.is`. Making it local-only means rewriting the data layer. Its icon directory may not be redistributed.
- **Twine.** The iOS interface is Compose, not SwiftUI. It bundles Readability.js.
- **FeedFlow.** A friendly licence, but all business logic is Kotlin Multiplatform. A fork carries a Gradle toolchain and has to strip Firebase, RevenueCat, TelemetryDeck and other SDKs.
- **RLLM.** A small SwiftUI app on FeedKit. Worth reading for its model-service settings and its daily-summary cache. No translation, OPML, background refresh or folders.
- **Tsukuyomi.** The closest feature match (own-key translation, SwiftSoup extraction, OPML, a Simplified Chinese interface), but a one-commit portfolio project that persists to UserDefaults and files. Worth reading for the own-key setup flow and for keeping image positions while translating a body.

Also looked at and rejected: `joeseesun/qmreader-ios` (depends on its own server), `CHANG-JUI-LIN/Yuedu-reader` (a book reader that needs Firebase), `danielmigueltejedor/prisma` (no licence), the NewsBlur client (needs its server).

## Libraries chosen

| Purpose | Library | Licence | Latest release | Note |
| --- | --- | --- | --- | --- |
| Feed parsing | Our own, on the system's streaming XML parser and JSON decoder | — | — | RSS 2.0 / RSS 1.0 / Atom / JSON Feed. FeedKit (MIT) was chosen first and removed in RD04 for the reasons above |
| Storage | [GRDB.swift](https://github.com/groue/GRDB.swift) | MIT | 7.12.0, 2026-11-01 | SQLite; explicit migrations; full-text search; one database file per partition is straightforward |
| HTML parsing | [SwiftSoup](https://github.com/scinfu/SwiftSoup) | MIT | 2.14.3, 2026-10-16 | Feed discovery; turning body HTML into paragraph blocks |
| Main-text extraction | [mozilla/readability](https://github.com/mozilla/readability) | Apache-2.0 | 0.6.0, 2025-03-03 | The script runs in a web view that is never shown |
| Model client | Our own, on the system networking library | — | — | Two requests are needed: chat and list models. Writing it ourselves is how we guarantee a key only goes to its configured address and no redirect is followed |

Known but not chosen:

- [Ryu0118/swift-readability](https://github.com/Ryu0118/swift-readability) (MIT): a ready-made wrapper that runs Readability.js in a web view. Small and little used; we start from the upstream script and reconsider if our own wrapper proves troublesome.
- [nate-parrott/reeeed](https://github.com/nate-parrott/reeeed) (MIT): a SwiftUI reader-mode component, a fork of which FeedFlow uses. No releases; no commits since 2025-05.
- [MacPaw/OpenAI](https://github.com/MacPaw/OpenAI), [jamesrochabrun/SwiftOpenAI](https://github.com/jamesrochabrun/SwiftOpenAI) (MIT): far more than the two requests we need.
- [huggingface/AnyLanguageModel](https://github.com/huggingface/AnyLanguageModel) (Apache-2.0): one API over Anthropic, Gemini and OpenAI-style services. To be evaluated if native protocols are added (an M3 candidate in the spec).

## What to borrow

Ideas and approaches are read, not code copied. If code from an MIT project is ever reused, its copyright notice is kept and it is listed on the in-app licences page.

| From | What | Used for |
| --- | --- | --- |
| NetNewsWire | One independent store per account as the isolation model; feed discovery; reading and writing OPML; tolerance for malformed feeds | spec N02, N03, N10; per-partition storage in section 6 |
| RLLM | The settings screen for several model services; caching of daily summaries | N07, N08 |
| Tsukuyomi | Entering and testing an own key; keeping image positions while translating a body | N06, N08 |

## The system's on-device translation

Apple's Translation framework could translate without any key. That matters little to the owner, who has keys, and a great deal to a future store audience. What the documentation says:

- `TranslationSession`, which code can call in batches, is available from iOS 18.0. A session is normally obtained through a translation task attached to a view. Creating a session with no interface at all requires iOS 26.0 and throws when the languages are not installed.
- A batch is translated in one call, with results returned in order or streamed one by one. All originals in a batch must share one source language.
- Processing is on the device. The first use of a language needs the user's consent to download it. It does not work in the simulator.
- Japanese, English and Simplified Chinese are all on Apple's system translation language list. **No page was found that states the Japanese → Simplified Chinese pair explicitly**; it has to be queried on a device, and the quality of that pair is unknown.

Handling: not in M1 or M2. The spec's orchestration depends only on "send an array of texts, receive an array of texts", so system translation can later be added as another implementation of that interface. Listed as an M3 candidate.

## Sources

- The GitHub page, README, licence and release history of each repository in the tables above.
- NetNewsWire: `Technotes/Accounts.markdown`, `Shared/Article Extractor/ArticleExtractor.swift`, `Modules/Account/Sources/Account/Folder.swift`.
- FeedFlow: `iosApp/project.yml`, `iosApp/Packages/Reader`. Folo: `apps/mobile/package.json`, `LICENSE`.
- Apple: [Translation](https://developer.apple.com/documentation/translation), [TranslationSession](https://developer.apple.com/documentation/translation/translationsession), [LanguageAvailability](https://developer.apple.com/documentation/translation/languageavailability), [feature availability](https://www.apple.com/ios/feature-availability/).
- GPL and the App Store: [the FSF's account](https://www.fsf.org/blogs/licensing/more-about-the-app-store-gpl-enforcement) (one party's legal reading, not legal advice).
- App Review guidelines 1.1.4, 1.2, 5.1.1, 5.1.2(i): [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/). Age ratings: [Age ratings values and definitions](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/).
