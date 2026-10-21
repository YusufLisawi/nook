#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
files_test_dir=$(mktemp -d /tmp/nook-files-tests.XXXXXX)
npm install --prefix "$files_test_dir" --no-save --package-lock=false linkedom@0.18.14
cp tests/files/plugin.test.cjs "$files_test_dir/plugin.test.cjs"
node "$files_test_dir/plugin.test.cjs" "$PWD"
xcrun swiftc -O -swift-version 5 -warnings-as-errors -parse-as-library \
  Nook/Core/Extensions.swift Nook/Services/FileSearchModels.swift \
  Nook/Services/FileSearchPreview.swift Nook/Services/FileSearchQuickLook.swift \
  Nook/Services/FileSearchService.swift Nook/Views/FileSearchSettingsPane.swift \
  tests/files/NativeTests.swift -o "$files_test_dir/native-tests"
"$files_test_dir/native-tests"
"$files_test_dir/native-tests" --benchmark
"$files_test_dir/native-tests" --filters
