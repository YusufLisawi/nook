#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
test_dir=$(mktemp -d /tmp/nook-windows-tests.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
swiftc -swift-version 5 -warnings-as-errors \
  Nook/Services/Windows/WindowActions.swift \
  Nook/Services/Windows/WindowDesktopPlan.swift \
  Nook/Services/Windows/WindowTargets.swift \
  tests/windows/GeometryTests.swift -o "$test_dir/geometry"
"$test_dir/geometry"
node tests/windows/plugin.test.cjs
