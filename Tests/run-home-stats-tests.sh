#!/bin/bash
set -euo pipefail
tool_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/opentoolkit-home-stats-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
# Synthetic dictations and events in a disposable database; never the user's library.
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -parse-as-library \
    "$tool_root/Sources/LibraryDatabase.swift" "$tool_root/Sources/HomeStats.swift" "$tool_root/Tests/HomeStatsTests.swift" \
    -module-cache-path "$test_dir/cache" -o "$test_dir/tests"
"$test_dir/tests" "$tool_root/Voice/library_schema.sql"
