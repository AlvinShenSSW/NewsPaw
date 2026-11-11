#!/bin/bash
set -euo pipefail

package_dir="$(cd "$(dirname "$0")" && pwd)"
fixture_socket=
appearance=
while [[ $# -gt 0 ]]; do
    case "$1" in
        --fixture-socket)
            [[ $# -ge 2 && "$2" = /* ]]
            fixture_socket="$2"
            shift 2
            ;;
        --appearance)
            [[ $# -ge 2 && ( "$2" = light || "$2" = dark ) ]]
            appearance="$2"
            shift 2
            ;;
        *)
            printf '%s\n' 'Usage: build-dev-app.sh [--fixture-socket /absolute/socket] [--appearance light|dark]' >&2
            exit 2
            ;;
    esac
done
swift build --package-path "$package_dir"
products="$(swift build --package-path "$package_dir" --show-bin-path)"
test -f "$products/NewsPaw"
test -d "$products/NewsPaw_NewsPaw.bundle"
app="$package_dir/.build/NewsPaw.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$products/NewsPaw" "$app/Contents/MacOS/NewsPaw"
cp -R "$products/NewsPaw_NewsPaw.bundle" "$app/Contents/Resources/"
plist="$app/Contents/Info.plist"
cat > "$plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>NewsPaw</string>
    <key>CFBundleDisplayName</key><string>NewsPaw</string>
    <key>CFBundleIdentifier</key><string>org.newspaw.settings.dev</string>
    <key>CFBundleExecutable</key><string>NewsPaw</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.6.4</string>
    <key>CFBundleVersion</key><string>10</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
if [[ -n "$fixture_socket" ]]; then
    plutil -insert NewsPawDevelopmentSocket -string "$fixture_socket" "$plist"
fi
if [[ -n "$appearance" ]]; then
    plutil -insert NewsPawDevelopmentAppearance -string "$appearance" "$plist"
fi
plutil -lint "$plist"
printf '%s\n' "$app"
