#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
destination="${1:-$root/build}"
app="$destination/Pico.app"
helper="$app/Contents/Helpers/Pico Speech.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Voice" "$helper/Contents/MacOS" "$destination/module-cache"
swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 -module-cache-path "$destination/module-cache" "$root"/Sources/*.swift -o "$app/Contents/MacOS/Pico"
swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 -module-cache-path "$destination/module-cache" "$root/Helpers/SpeechLauncher.swift" -o "$helper/Contents/MacOS/PicoSpeech"
cp "$root/Info.plist" "$app/Contents/Info.plist"
cp "$root/Helpers/Info.plist" "$helper/Contents/Info.plist"
cp "$root/Resources/AppIcon.icns" "$app/Contents/Resources/"
cp "$root"/Voice/*.py "$root"/Voice/*.sql "$app/Contents/Resources/Voice/"
# Explicit local source-build signing. No certificate or trust settings are changed.
identity="${PICO_SIGNING_IDENTITY:--}"
if [[ "$identity" == '-' ]]; then
    echo 'Local ad-hoc build: macOS may require permission again after a rebuild.'
fi
codesign --force --sign "$identity" --timestamp=none "$helper"
codesign --force --sign "$identity" --timestamp=none "$app"
codesign --verify --deep --strict "$app"
echo "Built $app"
