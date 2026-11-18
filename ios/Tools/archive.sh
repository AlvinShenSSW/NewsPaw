#!/bin/bash
# Archive NewsPaw for TestFlight and export it locally (RD22). Never uploads.
#
# Usage: ios/Tools/archive.sh
#
# Needs: the owner's Apple Developer account signed in to Xcode, and
# ios/Config/Signing.local.xcconfig with `DEVELOPMENT_TEAM = <Team ID>`.
# Archives only a clean, complete clone at origin/main or an ancestor of it.
# The build number is the commit count of the archived commit.
#
# Writes, outside the repository:
#   ~/Library/Developer/Xcode/Archives/<date>/NewsPaw <version> (<build>).xcarchive   (listed by Xcode's Organizer)
#   ~/Library/Developer/Xcode/Archives/<date>/NewsPaw <version> (<build>).build-info.txt
#   ~/Library/Developer/Xcode/Archives/<date>/NewsPaw <version> (<build>) export/       (the signed .ipa)
# Uploading is ios/Tools/upload.sh, only on the owner's authorisation naming the build.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
LOCAL="$ROOT/ios/Config/Signing.local.xcconfig"
fail() { echo "archive.sh: $*" >&2; exit 1; }

cd "$ROOT"
[ "$(git rev-parse --is-shallow-repository)" = false ] || fail "this is a shallow clone: the build number would be wrong"
[ -z "$(git status --porcelain)" ] || fail "the work tree has changes; commit or stash them first"
git fetch --quiet origin main || fail "could not fetch origin/main"
git merge-base --is-ancestor HEAD origin/main || fail "HEAD is not origin/main or an ancestor of it"
[ -f "$LOCAL" ] || fail "no ios/Config/Signing.local.xcconfig; write one line: DEVELOPMENT_TEAM = <your Team ID>"
TEAM=$(sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Z0-9]{10})[[:space:]]*$/\1/p' "$LOCAL" | head -1)
[ -n "$TEAM" ] || fail "ios/Config/Signing.local.xcconfig has no line DEVELOPMENT_TEAM = <ten capital letters or digits>"

BUILD=$(git rev-list --count HEAD)
COMMIT=$(git rev-parse HEAD)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/newspaw-archive.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Archive into a temporary path; it moves into place only when it is complete and checked.
xcodebuild archive \
  -project "$ROOT/ios/NewsPaw.xcodeproj" -scheme NewsPaw -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$WORK/NewsPaw.xcarchive" -derivedDataPath "$WORK/DerivedData" \
  -disableAutomaticPackageResolution -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$BUILD"
python3 "$ROOT/ios/Tools/check_release.py" --inspect "$WORK/NewsPaw.xcarchive" --build "$BUILD" \
  || fail "the archive failed the Release check; nothing was exported"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' "$WORK/NewsPaw.xcarchive/Info.plist")
DIR="$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)"
NAME="NewsPaw $VERSION ($BUILD)"
ARCHIVE="$DIR/$NAME.xcarchive"
[ ! -e "$ARCHIVE" ] || fail "$ARCHIVE exists already: this commit was archived today"
mkdir -p "$DIR"
mv "$WORK/NewsPaw.xcarchive" "$ARCHIVE"
{
  echo "version=$VERSION"
  echo "build=$BUILD"
  echo "commit=$COMMIT"
  echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "xcode=$(xcodebuild -version | tr '\n' ' ' | sed 's/ *$//')"
} > "$DIR/$NAME.build-info.txt"

EXPORT="$DIR/$NAME export"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$ROOT/ios/Config/ExportOptions.plist" \
  -exportPath "$EXPORT" -allowProvisioningUpdates

# The signed app's entitlements, with the team masked: they are pasted into public places.
IPA=$(find "$EXPORT" -name '*.ipa' -maxdepth 1 | head -1)
[ -n "$IPA" ] || fail "the export wrote no .ipa"
unzip -q "$IPA" -d "$WORK/ipa"
codesign -d --entitlements - --xml "$WORK/ipa/Payload/NewsPaw.app" 2>/dev/null > "$WORK/entitlements.plist"
if [ "$(plutil -extract get-task-allow raw -o - "$WORK/entitlements.plist" 2>/dev/null || echo false)" = true ]; then
  fail "the exported app has get-task-allow: it is a development build"
fi
echo "Entitlements (team masked):"
plutil -p "$WORK/entitlements.plist" | sed "s/$TEAM/<team>/g"
echo
echo "Archived NewsPaw $VERSION ($BUILD) from $COMMIT"
echo "  archive:    $ARCHIVE"
echo "  build info: $DIR/$NAME.build-info.txt"
echo "  export:     $IPA"
echo "Not uploaded. Upload only on the owner's authorisation naming $VERSION-$BUILD:"
echo "  ios/Tools/upload.sh \"$ARCHIVE\" --confirm <the version-build from the owner's message>"
