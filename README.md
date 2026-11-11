# NewsPaw

NewsPaw Reader is a news reader for iPhone and iPad that runs entirely on the device. Subscriptions — feeds, GitHub repositories, Hugging Face accounts and bookmarked web pages — are filed into categories, and each category belongs to a normal or an adult partition with its own storage and its own models. Titles are translated automatically, article bodies when opened and web pages in place, using the owner's own model keys; each category can get a short daily overview. There is no server, no account and no cloud sync: devices are aligned by exporting and importing a configuration file.

It is built for one owner and installed through TestFlight. An App Store edition is a distant, unplanned epic.

**Status: early development. The iOS project, the NewsPawKit package and CI exist; the app shows a placeholder screen and no reader feature has been built yet.**

## Documentation

- [Specification](docs/reader/spec.md) — requirements N01–N13, data model, configuration file, technical approach, milestones
- [UI / UX](docs/reader/ux.md) — screens on iPhone and iPad, states, wording, visual design
- [Backlog](docs/reader/backlog.md) — epics and issues
- [Open-source survey](docs/reader/open-source.md) — libraries chosen and why

## Repository layout

```
ios/
  NewsPaw.xcodeproj    the app project (one universal iPhone / iPad target)
  NewsPaw/             app target: SwiftUI interface, assets, string catalog
  NewsPawKit/          Swift package with the core logic and its tests
assets/branding/       the NewsPaw logo
docs/reader/           the reader's specification and backlog
docs/archive/          documents of the retired Mac + Telegram product
```

## Building and testing

Requires Xcode 26 or later (iOS 26 SDK). The minimum system version is iOS / iPadOS 26.

```sh
# Package tests (run on the Mac)
swift test --package-path ios/NewsPawKit

# App build for the iOS simulator
xcodebuild build -project ios/NewsPaw.xcodeproj -scheme NewsPaw \
  -destination 'generic/platform=iOS Simulator' \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO
```

Continuous integration runs both commands on GitHub Actions (`macos-26`, Xcode 26.6). Signing and TestFlight distribution are not set up yet.

## Dependencies

| Library | Version | Licence | Use |
| --- | --- | --- | --- |
| [FeedKit](https://github.com/nmdias/FeedKit) | 10.10.2 | MIT | Feed parsing |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 7.12.0 | MIT | SQLite |
| [SwiftSoup](https://github.com/scinfu/SwiftSoup) | 2.14.3 | MIT | HTML parsing |
| [Readability](https://github.com/mozilla/readability) | 0.6.0 (vendored) | Apache 2.0 | Main-text extraction |

The app contains no analytics, crash reporting or other third-party SDK.

## Privacy

Model keys, the owner's source lists, databases and other private data stay on the owner's devices and are never committed. Tests use synthetic feeds and pages and make no external request.

## The previous product

Until November 2026 NewsPaw was a macOS menu-bar app with a Python backend that sent news digests through Telegram. Its final state is tagged [`mac-v0.6.4-final`](https://github.com/AlvinShenSSW/NewsPaw/tree/mac-v0.6.4-final); its documents are kept, unmaintained, in [`docs/archive/`](docs/archive/README.md).
