#!/bin/bash
# Archive NewsPaw for TestFlight and export it locally (RD22). Never uploads.
#
# Usage: ios/Tools/archive.sh
#
# Needs: the owner's Apple Developer account signed in to Xcode, and
# ios/Config/Signing.local.xcconfig whose only line (besides blank and //
# comment lines) is `DEVELOPMENT_TEAM = <Team ID>`. Archives only a clean,
# complete clone at origin/main or an ancestor of it. The build number is the
# commit count of the archived commit.
#
# Everything is built, exported and checked in a temporary folder; only when
# every step has passed are these moved into place, outside the repository:
#   ~/Library/Developer/Xcode/Archives/<date>/NewsPaw <version> (<build>) export/       (the signed .ipa)
#   ~/Library/Developer/Xcode/Archives/<date>/NewsPaw <version> (<build>).build-info.txt
#   ~/Library/Developer/Xcode/Archives/<date>/NewsPaw <version> (<build>).xcarchive     (last; listed by the Organizer)
# A failed or interrupted run leaves none of them, so the next run starts clean.
# Output of xcodebuild is printed with the team masked: it may be quoted in public.
# Uploading is ios/Tools/upload.sh, only on the owner's authorisation naming the build.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
LOCAL="$ROOT/ios/Config/Signing.local.xcconfig"
fail() { echo "archive.sh: $*" >&2; exit 1; }

# The team of the local file: its only line that is neither blank nor a // comment.
local_team() {
  local lines
  lines=$(grep -vE '^[[:space:]]*(//.*)?$' "$LOCAL" || true)
  [ "$(printf '%s' "$lines" | grep -c '^')" = 1 ] || return 0
  printf '%s\n' "$lines" | sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Z0-9]{10})[[:space:]]*$/\1/p'
}

cd "$ROOT"
[ "$(git rev-parse --is-shallow-repository)" = false ] || fail "this is a shallow clone: the build number would be wrong"
[ -z "$(git status --porcelain)" ] || fail "the work tree has changes; commit or stash them first"
git fetch --quiet origin main || fail "could not fetch origin/main"
git merge-base --is-ancestor HEAD origin/main || fail "HEAD is not origin/main or an ancestor of it"
[ -f "$LOCAL" ] || fail "no ios/Config/Signing.local.xcconfig; write one line: DEVELOPMENT_TEAM = <your Team ID>"
TEAM=$(local_team)
[ -n "$TEAM" ] || fail "ios/Config/Signing.local.xcconfig must hold exactly one line besides blank and // comment lines: DEVELOPMENT_TEAM = <ten capital letters or digits>"
mask() { sed -e "s/$TEAM/<team>/g"; }
# Entitlements also carry the App ID prefix, which on older accounts differs from the team.
mask_entitlements() { sed -E -e "s/$TEAM/<team>/g" -e 's/"[A-Z0-9]{10}\./"<prefix>./g'; }

BUILD=$(git rev-list --count HEAD)
COMMIT=$(git rev-parse HEAD)
VERSION=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION = ([0-9.]+);$/\1/p' "$ROOT/ios/NewsPaw.xcodeproj/project.pbxproj" | sort -u)
[ "$(printf '%s\n' "$VERSION" | grep -c '^')" = 1 ] && [ -n "$VERSION" ] || fail "cannot read one MARKETING_VERSION from the project"
DIR="$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)"
NAME="NewsPaw $VERSION ($BUILD)"
ARCHIVE="$DIR/$NAME.xcarchive"
INFO="$DIR/$NAME.build-info.txt"
EXPORT="$DIR/$NAME export"
for path in "$ARCHIVE" "$INFO" "$EXPORT"; do
  [ ! -e "$path" ] || fail "$path exists already: this commit was archived today"
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/newspaw-archive.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

xcodebuild archive \
  -project "$ROOT/ios/NewsPaw.xcodeproj" -scheme NewsPaw -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$WORK/NewsPaw.xcarchive" -derivedDataPath "$WORK/DerivedData" \
  -disableAutomaticPackageResolution -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$BUILD" 2>&1 | mask
python3 "$ROOT/ios/Tools/check_release.py" --inspect "$WORK/NewsPaw.xcarchive" --build "$BUILD" \
  || fail "the archive failed the Release check; nothing was exported"
ARCHIVED=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' "$WORK/NewsPaw.xcarchive/Info.plist")
[ "$ARCHIVED" = "$VERSION" ] || fail "the archive's version $ARCHIVED is not the project's $VERSION"

xcodebuild -exportArchive -archivePath "$WORK/NewsPaw.xcarchive" \
  -exportOptionsPlist "$ROOT/ios/Config/ExportOptions.plist" \
  -exportPath "$WORK/export" -allowProvisioningUpdates 2>&1 | mask

# The signed app's entitlements, masked: they are pasted into public places.
IPA=$(find "$WORK/export" -maxdepth 1 -name '*.ipa' | head -1)
[ -n "$IPA" ] || fail "the export wrote no .ipa"
unzip -q "$IPA" -d "$WORK/ipa"
codesign -d --entitlements - --xml "$WORK/ipa/Payload/NewsPaw.app" 2>/dev/null > "$WORK/entitlements.plist" \
  || fail "cannot read the exported app's entitlements"
if [ "$(plutil -extract get-task-allow raw -o - "$WORK/entitlements.plist" 2>/dev/null || echo false)" = true ]; then
  fail "the exported app has get-task-allow: it is a development build"
fi
echo "Entitlements (team and App ID prefix masked):"
plutil -p "$WORK/entitlements.plist" | mask_entitlements

{
  echo "version=$VERSION"
  echo "build=$BUILD"
  echo "commit=$COMMIT"
  echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "xcode=$(xcodebuild -version | tr '\n' ' ' | sed 's/ *$//')"
} > "$WORK/build-info.txt"

# Every step passed: move into place, the archive last.
mkdir -p "$DIR"
mv "$WORK/export" "$EXPORT"
mv "$WORK/build-info.txt" "$INFO"
mv "$WORK/NewsPaw.xcarchive" "$ARCHIVE"

echo
echo "Archived NewsPaw $VERSION ($BUILD) from $COMMIT"
echo "  archive:    $ARCHIVE"
echo "  build info: $INFO"
echo "  export:     $EXPORT/$(basename "$IPA")"
echo "Not uploaded. Upload only on the owner's authorisation naming $VERSION-$BUILD:"
echo "  ios/Tools/upload.sh \"$ARCHIVE\" --confirm <the version-build from the owner's message>"
