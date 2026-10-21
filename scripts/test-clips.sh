#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
clips_test_dir=$(mktemp -d /tmp/nook-clips-tests.XXXXXX)
trap 'rm -rf "$clips_test_dir"' EXIT
xcrun swiftc -swift-version 5 -warnings-as-errors Nook/Services/Clips/ClipModels.swift Tests/Clips/ModelTests.swift -o "$clips_test_dir/models"
"$clips_test_dir/models"
xcrun swiftc -swift-version 5 -warnings-as-errors Nook/Services/Clips/ClipModels.swift Nook/Services/Clips/ScreenCaptureIndex.swift Tests/Clips/ScreenCaptureTests.swift -o "$clips_test_dir/captures"
"$clips_test_dir/captures"
node Tests/Clips/plugin.test.cjs
