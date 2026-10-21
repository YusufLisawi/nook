#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../../.."
scratch_dir=$(mktemp -d /tmp/nook-clips-tests.XXXXXX)
trap 'rm -rf "$scratch_dir"' EXIT
for suite in Model ScreenCapture; do
  xcrun swiftc -swift-version 5 -warnings-as-errors store/plugins/clips/tests/RuntimeStubs.swift store/plugins/clips/native/ClipModels.swift $([[ "$suite" == ScreenCapture ]] && echo store/plugins/clips/native/ScreenCaptureIndex.swift) "store/plugins/clips/tests/${suite}Tests.swift" -o "$scratch_dir/$suite"
  "$scratch_dir/$suite"
done
node store/plugins/clips/tests/plugin.test.cjs

bash store/plugins/clips/tests/migration.sh
python3 store/plugins/clips/tests/protocol.py
