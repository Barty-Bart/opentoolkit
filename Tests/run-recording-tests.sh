#!/bin/bash
set -euo pipefail
tool_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/multitool-recording-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
# Private implementation regression tests are concatenated into one translation unit.
# Inputs are synthetic color pixels and tones; this does not read screen or microphone.
cat "$tool_root/Sources/RecordingTools.swift" "$tool_root/Tests/RecordingTests.swift" > "$test_dir/Tests.swift"
cp "$tool_root/Sources/CursorEffects.swift" "$test_dir/CursorEffects.swift"
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -parse-as-library \
    "$test_dir/Tests.swift" "$test_dir/CursorEffects.swift" -module-cache-path "$test_dir/cache" -o "$test_dir/tests"
"$test_dir/tests" "$test_dir/generated"
