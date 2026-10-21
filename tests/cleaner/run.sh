#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
cleaner_test_dir=$(mktemp -d /tmp/nook-cleaner-tests.XXXXXX)
trap 'rm -rf "$cleaner_test_dir"' EXIT # Generated test executable only.
node tests/cleaner/shell.test.cjs
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.2" -warnings-as-errors \
  Nook/Services/CleanerEngine.swift tests/cleaner/NativeTests.swift -o "$cleaner_test_dir/native-tests"
"$cleaner_test_dir/native-tests"
node tests/cleaner/plugin.test.cjs
