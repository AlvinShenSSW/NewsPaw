#!/usr/bin/env python3
"""Check a Release archive of NewsPaw before it goes to TestFlight (RD22).

A Release binary must contain no debug seam: no code that exists only for the
UI tests (`#if DEBUG`). The check searches the bytes of every file of the
archived app for needles: names and literals that exist only inside a
`#if DEBUG` block and that survive an archive's stripping and optimisation —
type names, stored instance property names, string literals of 16 bytes or
more, and Objective-C selectors. A function name, an argument label or a
static name lives only in the symbol table, which an archive strips, so it is
never a needle.

The control proves the needles: a Release archive built with DEBUG forced
must contain every one of them. Every Swift file with a `#if DEBUG` block must
be in the needle table or in the exempt list (with the reason it has no
needle), so that a new seam cannot go unlisted.

The archive checks also cover what an upload needs and the project does not
otherwise check: `ITSAppUsesNonExemptEncryption` false, the privacy manifest
with its declarations, and no debug dylib. The repository check fails on
signing material in a tracked file, a team in the project file, and — when
the local signing file exists — its team identifier in any tracked file.

Usage:
  check_release.py --derived-data DIR       build an unsigned Release archive in DIR and check it
  check_release.py --control DIR            build a Release archive with DEBUG forced in DIR; every needle must be found
  check_release.py --inspect ARCHIVE [--build N]   check an existing archive
  check_release.py --inspect-control ARCHIVE       check an existing forced-DEBUG archive

Exit status: 0 when every check passes, 1 when one fails, 2 on bad input or a
failed build.
"""

from __future__ import annotations

import argparse
import fnmatch
import plistlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
PROJECT = ROOT / "ios" / "NewsPaw.xcodeproj"
LOCAL_SIGNING = ROOT / "ios" / "Config" / "Signing.local.xcconfig"
SOURCE_DIRS = [ROOT / "ios" / "NewsPaw", ROOT / "ios" / "NewsPawKit" / "Sources"]

# Each Swift file with a `#if DEBUG` block, and needles taken from inside its
# blocks. Kinds: type name, stored instance property, literal of 16 bytes or
# more, Objective-C selector.
NEEDLES: dict[str, list[str]] = {
    "ios/NewsPaw/UITestIdentifiers.swift": [
        "NEWSPAW_UITEST_LIBRARY_DIRECTORY",  # literal
        "debug.deliverBackgroundRefresh",  # literal
    ],
    "ios/NewsPaw/AppState/DebugLaunchOptions.swift": ["DebugLaunchOptions"],  # type
    "ios/NewsPaw/AppState/FixtureAuthenticator.swift": ["FixtureAuthenticator"],  # type
    "ios/NewsPaw/AppState/OPMLFixture.swift": ["OPMLFixture"],  # type
    "ios/NewsPaw/AppState/ConfigurationFixture.swift": ["ConfigurationFixture"],  # type
    "ios/NewsPaw/AppState/BackgroundRefresh.swift": [
        "DebugClock",  # type
        "RecordingBackgroundScheduler",  # type
    ],
    "ios/NewsPaw/AppState/AppModel.swift": ["showsDebugReport"],  # stored property
    "ios/NewsPaw/AppState/BodyTranslationModel.swift": [
        "holdsFirstPlanUntilBackground",  # stored property
        "changesSlotsAfterReaderTranslated",  # stored property
    ],
    "ios/NewsPaw/AppState/CategoryModel.swift": ["failNextSave"],  # stored property
    "ios/NewsPaw/AppState/SourceModel.swift": ["Simulated failure for a UI test"],  # literal
    "ios/NewsPaw/AppState/ReadingModel.swift": [
        "failNextSearch",  # stored property
        "The UI tests' failing search read",  # literal
    ],
    "ios/NewsPaw/AppState/ConfigurationModel.swift": [
        "ConfigurationExportHold",  # type
        "exportedData",  # stored property
    ],
    "ios/NewsPaw/Browser/BrowserFixtures.swift": [
        "BrowserFixtures",  # type
        "_didPerformRedirection:newRequest:",  # selector (WebKit's private method)
    ],
    "ios/NewsPaw/Browser/PageTranslationFixtures.swift": ["pages.example.invalid"],  # literal (the enum is a namespace: no metadata)
    "ios/NewsPaw/Navigation/RootView.swift": [
        "AdultDebugElement",  # type
        "DeliverBackgroundRefreshButton",  # type
    ],
    "ios/NewsPaw/NewsPawApp.swift": ["setAnimationsEnabled:"],  # selector
    "ios/NewsPawKit/Sources/NewsPawKit/Feeds/FixtureTransport.swift": ["FixtureTransport"],  # type
    "ios/NewsPawKit/Sources/NewsPawKit/AI/FixtureModelHTTP.swift": ["FixtureModelHTTP"],  # type
    "ios/NewsPawKit/Sources/NewsPawKit/Cache/ImageCache.swift": ["storeWillWrite"],  # stored property
    "ios/NewsPawKit/Sources/NewsPawKit/Store/LibraryStore.swift": ["adultOpensForUITests"],  # stored property
    "ios/NewsPawKit/Sources/NewsPawKit/Store/CategoryMove.swift": [
        "DebugOptions",  # type
        "pauseBetweenSteps",  # stored property
    ],
    "ios/NewsPawKit/Sources/NewsPawKit/Store/Library+Categories.swift": [
        "https://example.invalid/ui-test/",  # literal
    ],
    "ios/NewsPawKit/Sources/NewsPawKit/Store/Library+Usage.swift": [
        "SELECT COUNT(*) FROM usage WHERE model = ?",  # literal
    ],
    "ios/NewsPawKit/Sources/NewsPawKit/Overview/Library+Overview.swift": [
        "'fixture-translator', 'done'",  # literal (inside the seeding SQL)
    ],
    "ios/NewsPawKit/Sources/NewsPawKit/Translation/BodyTranslator.swift": ["writesToFail"],  # stored property
}

# Files whose `#if DEBUG` blocks hold nothing that survives an archive, with
# the reason. They stay in the file set, so a new block in them is noticed
# only by reading; their Release behaviour is shown elsewhere.
EXEMPT: dict[str, str] = {
    "ios/NewsPawKit/Sources/NewsPawKit/AI/ModelAddress.swift": (
        "chooses a value: allowsLoopbackHTTPInThisBuild exists in both builds; "
        "Release behaviour is device check A4 and ModelRulesTests"
    ),
    "ios/NewsPawKit/Sources/NewsPawKit/Privacy/KeychainKeyStore.swift": (
        "a debug-only init with an argument label and a short literal; no surviving name"
    ),
    "ios/NewsPawKit/Sources/NewsPawKit/Browser/BrowserDataStores.swift": (
        "a static function with short literals; no surviving name"
    ),
    "ios/NewsPaw/Browser/BrowserModel.swift": (
        "a static counter (static names are not in reflection metadata)"
    ),
    "ios/NewsPaw/Destinations/ReadingView.swift": (
        "a static string and literals of fewer than 16 bytes"
    ),
}

DEBUG_BLOCK = re.compile(r"^\s*#if\b.*\bDEBUG\b", re.MULTILINE)

# The required-reason declarations the app's privacy manifest must hold.
PRIVACY_DECLARATIONS = {
    "NSPrivacyAccessedAPICategoryUserDefaults": "CA92.1",
    "NSPrivacyAccessedAPICategoryFileTimestamp": "C617.1",
}

SIGNING_FILE_PATTERNS = ["*.p12", "*.p8", "*.cer", "*.mobileprovision", "*.provisionprofile"]
PROJECT_SIGNING = re.compile(r"\b(DEVELOPMENT_TEAM|DevelopmentTeam|PROVISIONING_PROFILE\w*|CODE_SIGN_IDENTITY)\b")
TEAM_LINE = re.compile(r"^\s*DEVELOPMENT_TEAM\s*=\s*([A-Z0-9]{10})\s*$", re.MULTILINE)


class BadInput(Exception):
    pass


# MARK: - Building


def build_archive(directory: Path, name: str, force_debug: bool) -> Path:
    """An unsigned Release archive for any iOS device, in `directory`."""
    directory.mkdir(parents=True, exist_ok=True)
    archive = directory / name / "NewsPaw.xcarchive"
    log = directory / f"{name}.log"
    command = [
        "xcodebuild", "archive",
        "-project", str(PROJECT),
        "-scheme", "NewsPaw",
        "-configuration", "Release",
        "-destination", "generic/platform=iOS",
        "-archivePath", str(archive),
        "-derivedDataPath", str(directory / f"{name}-dd"),
        "-disableAutomaticPackageResolution",
        "CODE_SIGNING_ALLOWED=NO",
    ]
    if force_debug:
        command.append("SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG")
    print(f"building {name} archive (log: {log})")
    with log.open("w") as output:
        result = subprocess.run(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT)
    if result.returncode != 0 or not archive.is_dir():
        raise BadInput(f"xcodebuild archive failed ({result.returncode}); see {log}")
    return archive


# MARK: - The archive


def app_in(archive: Path) -> Path:
    app = archive / "Products" / "Applications" / "NewsPaw.app"
    if not app.is_dir():
        raise BadInput(f"no NewsPaw.app in {archive}")
    return app


def needle_hits(app: Path) -> dict[str, list[str]]:
    """For each needle, the files of the app that contain it."""
    wanted = {needle.encode("utf-8"): needle for needles in NEEDLES.values() for needle in needles}
    hits: dict[str, list[str]] = {needle: [] for needle in wanted.values()}
    for path in sorted(app.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        data = path.read_bytes()
        for raw, needle in wanted.items():
            if raw in data:
                hits[needle].append(str(path.relative_to(app)))
    return hits


def source_of(needle: str) -> str:
    return next(file for file, needles in NEEDLES.items() if needle in needles)


def check_release_archive(archive: Path, build: int | None) -> list[str]:
    app = app_in(archive)
    problems: list[str] = []
    for needle, files in needle_hits(app).items():
        if files:
            problems.append(
                f"debug seam in the Release app: {needle!r} (from {source_of(needle)}) in {', '.join(files)}"
            )
    for path in sorted(app.rglob("*")):
        if path.name.endswith(".debug.dylib") or path.name == "__preview.dylib":
            problems.append(f"debug-only file in the Release app: {path.relative_to(app)}")
    info = read_plist(app / "Info.plist")
    if info.get("ITSAppUsesNonExemptEncryption") is not False:
        problems.append(
            f"Info.plist: ITSAppUsesNonExemptEncryption must be false, is {info.get('ITSAppUsesNonExemptEncryption')!r}"
        )
    if build is not None and info.get("CFBundleVersion") != str(build):
        problems.append(f"Info.plist: CFBundleVersion is {info.get('CFBundleVersion')!r}, expected {build}")
    problems += check_privacy_manifest(app / "PrivacyInfo.xcprivacy")
    return problems


def check_privacy_manifest(path: Path) -> list[str]:
    if not path.is_file():
        return [f"no privacy manifest at the app's root ({path.name})"]
    try:
        manifest = plistlib.loads(path.read_bytes())
    except Exception as error:  # noqa: BLE001 - any parse failure is the finding
        return [f"the privacy manifest does not parse: {error}"]
    problems: list[str] = []
    if manifest.get("NSPrivacyTracking") is not False:
        problems.append("privacy manifest: NSPrivacyTracking must be false")
    declared: dict[str, list[str]] = {}
    for entry in manifest.get("NSPrivacyAccessedAPITypes", []):
        if isinstance(entry, dict):
            declared[entry.get("NSPrivacyAccessedAPIType", "")] = entry.get("NSPrivacyAccessedAPITypeReasons", [])
    for category, reason in PRIVACY_DECLARATIONS.items():
        if reason not in declared.get(category, []):
            problems.append(f"privacy manifest: {category} with reason {reason} is not declared")
    return problems


def check_control_archive(archive: Path) -> list[str]:
    app = app_in(archive)
    return [
        f"needle not found in the forced-DEBUG archive: {needle!r} (from {source_of(needle)})"
        for needle, files in needle_hits(app).items()
        if not files
    ]


def read_plist(path: Path) -> dict:
    try:
        return plistlib.loads(path.read_bytes())
    except Exception as error:  # noqa: BLE001
        raise BadInput(f"cannot read {path}: {error}") from error


# MARK: - The repository


def check_seam_files() -> list[str]:
    found = set()
    for directory in SOURCE_DIRS:
        for path in directory.rglob("*.swift"):
            if DEBUG_BLOCK.search(path.read_text(encoding="utf-8")):
                found.add(str(path.relative_to(ROOT)))
    listed = set(NEEDLES) | set(EXEMPT)
    problems = [f"a Swift file with `#if DEBUG` is in neither the needle table nor the exempt list: {file}"
                for file in sorted(found - listed)]
    problems += [f"listed but has no `#if DEBUG` block (or no longer exists): {file}"
                 for file in sorted(listed - found)]
    return problems


def git(*arguments: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(ROOT), *arguments], capture_output=True, text=True)


def check_hygiene() -> list[str]:
    listing = git("ls-files", "-z")
    if listing.returncode != 0:
        raise BadInput(f"git ls-files failed: {listing.stderr.strip()}")
    tracked = [path for path in listing.stdout.split("\0") if path]
    problems: list[str] = []
    for path in tracked:
        name = Path(path).name
        if path == "ios/Config/Signing.local.xcconfig" or any(fnmatch.fnmatch(name, p) for p in SIGNING_FILE_PATTERNS):
            problems.append(f"signing material is tracked: {path}")
    pbxproj = PROJECT / "project.pbxproj"
    for number, line in enumerate(pbxproj.read_text(encoding="utf-8").splitlines(), start=1):
        match = PROJECT_SIGNING.search(line)
        if match:
            problems.append(f"project.pbxproj:{number} sets {match.group(1)}; the team belongs in Signing.local.xcconfig")
    if LOCAL_SIGNING.is_file():
        match = TEAM_LINE.search(LOCAL_SIGNING.read_text(encoding="utf-8"))
        if match:
            # The team itself is never printed.
            result = git("grep", "-F", "-l", "-e", match.group(1))
            if result.returncode == 0:
                for path in result.stdout.split():
                    problems.append(f"the local team identifier appears in a tracked file: {path}")
            elif result.returncode != 1:
                raise BadInput(f"git grep failed: {result.stderr.strip()}")
    return problems


# MARK: - Main


def report(problems: list[str], success: str) -> int:
    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    if problems:
        print(f"{len(problems)} problem(s)", file=sys.stderr)
        return 1
    print(success)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--derived-data", type=Path, help="build an unsigned Release archive here and check it")
    mode.add_argument("--control", type=Path, help="build a Release archive with DEBUG forced here; every needle must be found")
    mode.add_argument("--inspect", type=Path, help="check an existing archive")
    mode.add_argument("--inspect-control", type=Path, help="check an existing forced-DEBUG archive")
    parser.add_argument("--build", type=int, help="with --inspect: the expected CFBundleVersion")
    arguments = parser.parse_args()
    needle_count = sum(len(needles) for needles in NEEDLES.values())
    try:
        problems = check_seam_files()
        if arguments.control or arguments.inspect_control:
            archive = arguments.inspect_control or build_archive(arguments.control.resolve(), "control", force_debug=True)
            problems += check_control_archive(archive)
            return report(problems, f"control: all {needle_count} needles of {len(NEEDLES)} files found in {archive}; "
                                    f"{len(EXEMPT)} files exempt")
        archive = arguments.inspect or build_archive(arguments.derived_data.resolve(), "release", force_debug=False)
        problems += check_hygiene()
        problems += check_release_archive(archive, arguments.build)
        return report(problems, f"release: none of {needle_count} needles in {archive}; encryption key, privacy "
                                f"manifest, no debug dylib; repository hygiene clean")
    except BadInput as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
