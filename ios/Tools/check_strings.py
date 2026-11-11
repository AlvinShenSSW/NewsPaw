#!/usr/bin/env python3
"""Check the app's string catalog against the strings the build extracted.

Every key the app target's Swift code passes to a localising API must be in
`ios/NewsPaw/Localizable.xcstrings` with a Simplified Chinese translation, and
the catalog must hold no key the code no longer uses. Xcode warns about
neither in a command-line build, so this script is the check (criterion 11 of
RD03).

The build writes one `.stringsdata` file per Swift source file and
architecture when `SWIFT_EMIT_LOC_STRINGS` is on. Only the app target's files
are read (not the package's or the UI tests'), and keys are de-duplicated
across architectures. The script sees literal keys only, so the app never
builds a key at run time.

Usage: check_strings.py --derived-data PATH [--catalog PATH]
Exit status: 0 when the catalog matches, 1 when it does not, 2 on bad input.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

LANGUAGE = "zh-Hans"
TABLE = "Localizable"
TARGET_BUILD_DIR = "NewsPaw.build"


def extracted_keys(derived_data: Path) -> set[str]:
    """Keys of the app target's `Localizable` table in every architecture."""
    intermediates = derived_data / "Build" / "Intermediates.noindex" / "NewsPaw.build"
    files = sorted(intermediates.glob(f"*/{TARGET_BUILD_DIR}/Objects-normal/*/*.stringsdata"))
    if not files:
        print(f"error: no .stringsdata files of the app target under {intermediates}; build first", file=sys.stderr)
        raise SystemExit(2)
    keys: set[str] = set()
    for path in files:
        data = json.loads(path.read_text(encoding="utf-8"))
        for entry in data.get("tables", {}).get(TABLE, []):
            keys.add(entry["key"])
    return keys


def is_translated(localization: dict) -> bool:
    """A string unit, or every variation, is translated and not empty."""
    unit = localization.get("stringUnit")
    if unit is not None:
        return unit.get("state") == "translated" and bool(unit.get("value"))
    variations = localization.get("variations")
    if not variations:
        return False
    cases = [case for kind in variations.values() for case in kind.values()]
    return bool(cases) and all(is_translated(case) for case in cases)


def check(catalog_path: Path, keys: set[str]) -> list[str]:
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    strings: dict = catalog.get("strings", {})
    problems: list[str] = []
    for key in sorted(keys):
        entry = strings.get(key)
        if entry is None:
            problems.append(f"missing from the catalog: {key!r}")
        elif not is_translated(entry.get("localizations", {}).get(LANGUAGE, {})):
            problems.append(f"no {LANGUAGE} translation: {key!r}")
    for key in sorted(set(strings) - keys):
        problems.append(f"unused catalog key: {key!r}")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--derived-data", required=True, type=Path, help="the -derivedDataPath of the build")
    default_catalog = Path(__file__).resolve().parent.parent / "NewsPaw" / "Localizable.xcstrings"
    parser.add_argument("--catalog", type=Path, default=default_catalog, help="the app's string catalog")
    arguments = parser.parse_args()
    if not arguments.catalog.is_file():
        print(f"error: no catalog at {arguments.catalog}", file=sys.stderr)
        return 2
    keys = extracted_keys(arguments.derived_data)
    problems = check(arguments.catalog, keys)
    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    if problems:
        print(f"{len(problems)} problem(s) in {arguments.catalog}", file=sys.stderr)
        return 1
    print(f"{len(keys)} extracted keys, all in the catalog with a {LANGUAGE} translation; no unused key")
    return 0


if __name__ == "__main__":
    sys.exit(main())
