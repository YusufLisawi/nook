#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
files_test_dir=$(mktemp -d /tmp/nook-files-tests.XXXXXX)
npm install --prefix "$files_test_dir" --no-save --package-lock=false linkedom@0.18.14
cp tests/files/plugin.test.cjs "$files_test_dir/plugin.test.cjs"
node "$files_test_dir/plugin.test.cjs" "$PWD"
xcrun clang -std=c11 -O3 -Wall -Wextra -Werror -c Nook/Services/Files/FileNameIndex.c -o "$files_test_dir/index.o"
xcrun swiftc -O -swift-version 5 -warnings-as-errors -parse-as-library \
  -import-objc-header Nook/Services/Files/NookFiles-Bridging.h \
  Nook/Core/Extensions.swift Nook/Services/FileSearchModels.swift \
  Nook/Services/Files/FileIndexQuery.swift Nook/Services/Files/FileNameIndex.swift \
  Nook/Services/Files/FileSpotlightFallback.swift Nook/Services/Files/FileSearchWebShortcuts.swift \
  Nook/Services/FileSearchPreview.swift Nook/Services/FileSearchQuickLook.swift \
  Nook/Services/FileSearchService.swift Nook/Views/FileSearchSettingsPane.swift \
  tests/files/NativeTests.swift "$files_test_dir/index.o" -o "$files_test_dir/native-tests"
"$files_test_dir/native-tests"
bash tests/files/index.sh
bash tests/files/watcher.sh
bash tests/files/tab.sh
# Read-only home-folder and million-name benchmarks: bash tests/files/index.sh --benchmark
