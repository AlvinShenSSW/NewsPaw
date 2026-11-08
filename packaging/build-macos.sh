#!/bin/bash
set -euo pipefail
umask 077

if [[ $# -ne 1 && $# -ne 4 && $# -ne 6 ]]; then
    echo "Usage: build-macos.sh /absolute/output/NewsPaw.app [--ffmpeg /absolute/ffmpeg /absolute/license [--ffprobe /absolute/ffprobe]]" >&2
    exit 2
fi
app="$1"
[[ "$app" = /*/NewsPaw.app && ! -e "$app" && ! -L "$app" ]]
media=
media_license=
media_probe=
if [[ $# -ge 4 ]]; then
    [[ "$2" = --ffmpeg && "$3" = /* && "$4" = /* && -x "$3" && -f "$4" ]]
    media="$3"
    media_license="$4"
fi
if [[ $# -eq 6 ]]; then
    [[ "$5" = --ffprobe && "$6" = /* && -x "$6" ]]
    media_probe="$6"
fi
[[ "$(uname -s)" = Darwin ]]
root="$(cd "$(dirname "$0")/.." && pwd)"
package="$root/macos/NewsPaw"
scratch="$(mktemp -d "$(dirname "$app")/.newspaw-package.XXXXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
staged="$scratch/NewsPaw.app"
contents="$staged/Contents"
helpers="$contents/Helpers"
runtime="$helpers/Python"
mkdir -p "$contents"/{MacOS,Resources,Library/LaunchAgents} "$helpers"

cd "$root"
python="$(uv python find --managed-python 3.13.7)"
python_root="$("$python" -I -c 'import sys; print(sys.base_prefix)')"
[[ "$python_root" = /* && -x "$python_root/bin/python3.13" ]]
ditto "$python_root" "$runtime"
runtime_python="$runtime/bin/python3.13"
site="$("$runtime_python" -I -c 'import sysconfig; print(sysconfig.get_path("purelib"))')"
[[ "$site" = "$runtime/"* ]]
uv export --frozen --no-dev --no-emit-project --output-file "$scratch/requirements.txt"
uv pip install --python "$runtime_python" --target "$site" --require-hashes --no-deps -r "$scratch/requirements.txt"
uv build --wheel --out-dir "$scratch/wheels"
uv pip install --python "$runtime_python" --target "$site" --no-deps "$scratch/wheels/"*.whl

swift build --package-path "$package" --configuration release
products="$(swift build --package-path "$package" --configuration release --show-bin-path)"
cp "$products/NewsPaw" "$contents/MacOS/NewsPaw"
cp "$products/NewsPawResident" "$helpers/NewsPawResident"
ditto "$products/NewsPaw_NewsPaw.bundle" "$contents/Resources/NewsPaw_NewsPaw.bundle"
cp "$root/packaging/NewsPaw.Info.plist" "$contents/Info.plist"
cp "$root/packaging/io.newspaw.resident.plist" "$contents/Library/LaunchAgents/"
if [[ -f "$root/macos/ocr/main.swift" ]]; then
    xcrun swiftc -O "$root/macos/ocr/main.swift" -o "$runtime/bin/newspaw-ocr"
fi
if [[ -n "$media" ]]; then
    cp "$media" "$helpers/ffmpeg"
    cp "$media_license" "$contents/Resources/ffmpeg-license.txt"
    shasum -a 256 "$helpers/ffmpeg" | awk '{print $1}' > "$contents/Resources/ffmpeg.sha256"
fi
if [[ -n "$media_probe" ]]; then
    cp "$media_probe" "$helpers/ffprobe"
    shasum -a 256 "$helpers/ffprobe" | awk '{print $1}' > "$contents/Resources/ffprobe.sha256"
fi

plutil -lint "$contents/Info.plist" "$contents/Library/LaunchAgents/io.newspaw.resident.plist"
"$runtime_python" -I "$root/packaging/validate_bundle.py" "$staged"
env -i PATH=/usr/bin:/bin "$helpers/NewsPawResident" --self-check
mv "$staged" "$app"
printf '%s\n' "$app"
