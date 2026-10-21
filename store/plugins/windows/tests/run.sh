#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../../.."
test_dir=$(mktemp -d /tmp/nook-windows-tests.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
swiftc -swift-version 5 -warnings-as-errors \
  store/plugins/windows/native/WindowActions.swift \
  store/plugins/windows/native/WindowDesktopPlan.swift \
  store/plugins/windows/native/WindowTargets.swift \
  store/plugins/windows/tests/GeometryTests.swift -o "$test_dir/geometry"
"$test_dir/geometry"
node store/plugins/windows/tests/plugin.test.cjs

bash store/plugins/windows/tests/migration.sh
python3 store/plugins/windows/tests/protocol.py
