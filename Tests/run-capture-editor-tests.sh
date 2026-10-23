#!/bin/bash
set -euo pipefail
tool_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/opentoolkit-editor-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
# Synthetic images only; no capture permissions, speech worker or user library.
# UsageLog.shared stays nil, so no database is opened.
# Pass --snapshots <folder> to save editor window images instead of running checks.
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -parse-as-library \
    "$tool_root/Sources/CaptureEditor.swift" "$tool_root/Sources/CaptureDrawingSurface.swift" "$tool_root/Sources/CaptureTextSnap.swift" \
    "$tool_root/Sources/CaptureItem.swift" "$tool_root/Sources/UsageLog.swift" "$tool_root/Sources/LibraryDatabase.swift" \
    "$tool_root/Tests/CaptureEditorTests.swift" -module-cache-path "$test_dir/cache" -o "$test_dir/tests"
"$test_dir/tests" "$@"
