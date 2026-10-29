#!/bin/bash
set -euo pipefail
tool_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/opentoolkit-scroll-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
# Synthetic images only; no screen capture, scrolling or user library.
swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 -parse-as-library \
    "$tool_root/Sources/ScrollingCapture.swift" "$tool_root/Sources/LibraryDatabase.swift" \
    "$tool_root/Tests/ScrollingCaptureTests.swift" -module-cache-path "$test_dir/cache" -o "$test_dir/tests"
"$test_dir/tests" "$@"
