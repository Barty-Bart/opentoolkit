#!/bin/bash
set -euo pipefail
tool_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/multitool-meeting-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
# Uses generated PCM tones only. No stream starts and no privacy permission prompts.
cat "$tool_root/Sources/MeetingAudio.swift" "$tool_root/Tests/MeetingAudioTests.swift" > "$test_dir/Tests.swift"
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -parse-as-library \
    "$test_dir/Tests.swift" -module-cache-path "$test_dir/cache" -o "$test_dir/tests"
"$test_dir/tests" "$test_dir/generated"
