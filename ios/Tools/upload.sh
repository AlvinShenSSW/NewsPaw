#!/bin/bash
# Upload an archive made by archive.sh to App Store Connect (RD22).
#
# Usage: ios/Tools/upload.sh <archive> --confirm <version>-<build> [--dry-run]
#
# Run only on the owner's authorisation naming the build. The --confirm value
# is copied from the owner's message ("upload 0.1.0-1012"), never derived from
# the archive: the script cannot tell who typed it, so the authority is that
# message, quoted with its date in the build log of docs/reader/testflight.md.
# Never run by a check or by CI. --dry-run makes every check and prints the
# upload command instead of running it. xcodebuild's output is printed with the
# team masked (it may be quoted in public), so the local signing file must be
# in the form archive.sh requires.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
LOCAL="$ROOT/ios/Config/Signing.local.xcconfig"
fail() { echo "upload.sh: $*" >&2; exit 1; }

# The team of the local file: its only line that is neither blank nor a // comment.
local_team() {
  local lines
  lines=$(grep -vE '^[[:space:]]*(//.*)?$' "$LOCAL" || true)
  [ "$(printf '%s' "$lines" | grep -c '^')" = 1 ] || return 0
  printf '%s\n' "$lines" | sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Z0-9]{10})[[:space:]]*$/\1/p'
}

[ -z "${CI:-}" ] && [ -z "${GITHUB_ACTIONS:-}" ] || fail "refusing to upload from CI"

ARCHIVE=""
CONFIRM=""
CONFIRM_SEEN=false
DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --confirm) [ $# -ge 2 ] || fail "--confirm needs <version>-<build>"
      [ "$CONFIRM_SEEN" = false ] || fail "--confirm given twice"
      CONFIRM_SEEN=true; CONFIRM="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -*) fail "unknown option $1" ;;
    *) [ -z "$ARCHIVE" ] || fail "one archive only"; ARCHIVE="$1"; shift ;;
  esac
done
[ -n "$ARCHIVE" ] || fail "usage: upload.sh <archive> --confirm <version>-<build> [--dry-run]"
# One absolute, physical path from here on: the archive checked is the archive uploaded.
[ -d "$ARCHIVE" ] || fail "not a directory: $ARCHIVE"
ARCHIVE=$(cd "$ARCHIVE" && pwd -P)
[ -n "$CONFIRM" ] || fail "no --confirm: give the <version>-<build> named in the owner's authorisation"
[ -f "$ARCHIVE/Info.plist" ] || fail "not an archive: $ARCHIVE"
[ -f "$LOCAL" ] || fail "no ios/Config/Signing.local.xcconfig: the team is needed to mask xcodebuild's output"
TEAM=$(local_team)
[ -n "$TEAM" ] || fail "ios/Config/Signing.local.xcconfig must hold exactly one line besides blank and // comment lines: DEVELOPMENT_TEAM = <ten capital letters or digits>"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' "$ARCHIVE/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' "$ARCHIVE/Info.plist")
[ "$CONFIRM" = "$VERSION-$BUILD" ] || fail "--confirm $CONFIRM does not match this archive ($VERSION-$BUILD)"

# Only an archive made by archive.sh from a commit on main.
INFO="${ARCHIVE%.xcarchive}.build-info.txt"
[ -f "$INFO" ] || fail "no build-info.txt beside the archive: it was not made by archive.sh"
field() { sed -n "s/^$1=//p" "$INFO" | head -1; }
[ "$(field version)" = "$VERSION" ] && [ "$(field build)" = "$BUILD" ] || fail "build-info.txt does not describe this archive"
COMMIT=$(field commit)
cd "$ROOT"
git fetch --quiet origin main || fail "could not fetch origin/main"
git merge-base --is-ancestor "$COMMIT" origin/main 2>/dev/null || fail "the archived commit ${COMMIT:-?} is not on origin/main"

python3 "$ROOT/ios/Tools/check_release.py" --inspect "$ARCHIVE" --build "$BUILD" || fail "the archive failed the Release check"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/newspaw-upload.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
cp "$ROOT/ios/Config/ExportOptions.plist" "$WORK/ExportOptions.plist"
plutil -replace destination -string upload "$WORK/ExportOptions.plist"
COMMAND=(xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$WORK/ExportOptions.plist"
  -exportPath "$WORK/upload" -allowProvisioningUpdates)

if [ "$DRY_RUN" = true ]; then
  echo "Dry run: every check passed for NewsPaw $VERSION ($BUILD) from $COMMIT. Would run:"
  printf '  %q' "${COMMAND[@]}"; echo
  echo "  with the export options' destination set to: $(plutil -extract destination raw -o - "$WORK/ExportOptions.plist")"
  exit 0
fi
"${COMMAND[@]}" 2>&1 | sed -e "s/$TEAM/<team>/g"
echo "Uploaded NewsPaw $VERSION ($BUILD) from $COMMIT on $(date -u +%Y-%m-%dT%H:%M:%SZ)."
echo "Record it in the build log of docs/reader/testflight.md with the owner's authorising message."
