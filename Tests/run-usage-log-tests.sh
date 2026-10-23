#!/bin/bash
set -euo pipefail
tool_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/opentoolkit-usage-log-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
# Uses a disposable database in the temporary folder; never the user's library.
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -parse-as-library \
    "$tool_root/Sources/LibraryDatabase.swift" "$tool_root/Sources/UsageLog.swift" "$tool_root/Tests/UsageLogTests.swift" \
    -module-cache-path "$test_dir/cache" -o "$test_dir/tests"
"$test_dir/tests" "$tool_root/Voice/library_schema.sql"
