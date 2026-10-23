#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
destination="${1:-$root/build}"
app="$destination/OpenToolkit.app"
helper="$app/Contents/Helpers/OpenToolkit Speech.app"
module_cache="${OPENTOOLKIT_MODULE_CACHE:-$destination/module-cache}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Voice" "$helper/Contents/MacOS" "$module_cache"
swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 -file-prefix-map "$root=OpenToolkit" -module-cache-path "$module_cache" "$root"/Sources/*.swift -o "$app/Contents/MacOS/OpenToolkit"
swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 -file-prefix-map "$root=OpenToolkit" -module-cache-path "$module_cache" "$root/Helpers/SpeechLauncher.swift" -o "$helper/Contents/MacOS/OpenToolkitSpeech"
cp "$root/Info.plist" "$app/Contents/Info.plist"
cp "$root/Helpers/Info.plist" "$helper/Contents/Info.plist"
cp "$root/Resources/AppIcon.icns" "$app/Contents/Resources/"
cp "$root"/Voice/*.py "$root"/Voice/*.sql "$app/Contents/Resources/Voice/"
# Explicit local source-build signing. No certificate or trust settings are changed.
identity="${OPENTOOLKIT_SIGNING_IDENTITY:--}"
if [[ "$identity" == '-' ]]; then
    echo 'Local ad-hoc build: macOS may require permission again after a rebuild.'
fi
if [[ "$identity" == '-' ]]; then
    codesign --force --sign "$identity" --timestamp=none "$helper"
    codesign --force --sign "$identity" --timestamp=none "$app"
else
    codesign --force --sign "$identity" --options runtime --timestamp --entitlements "$root/packaging/app.entitlements.plist" "$helper"
    codesign --force --sign "$identity" --options runtime --timestamp --entitlements "$root/packaging/app.entitlements.plist" "$app"
fi
codesign --verify --deep --strict "$app"
echo "Built $app"
