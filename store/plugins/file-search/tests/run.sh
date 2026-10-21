#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../../.."
files_test_dir=$(mktemp -d /tmp/nook-files-tests.XXXXXX)
npm install --prefix "$files_test_dir" --no-save --package-lock=false linkedom@0.18.14
cp store/plugins/file-search/tests/plugin.test.cjs "$files_test_dir/plugin.test.cjs"
node "$files_test_dir/plugin.test.cjs" "$PWD"
xcrun clang -std=c11 -O3 -Wall -Wextra -Werror -c store/plugins/file-search/native/FileNameIndex.c -o "$files_test_dir/index.o"
xcrun swiftc -O -swift-version 5 -warnings-as-errors -parse-as-library \
  -import-objc-header store/plugins/file-search/native/NookFiles-Bridging.h \
  store/plugins/file-search/tests/RuntimeStubs.swift Nook/Core/Extensions.swift store/plugins/file-search/native/FileSearchModels.swift \
  store/plugins/file-search/native/FileIndexQuery.swift store/plugins/file-search/native/FileSearchAccessPolicy.swift store/plugins/file-search/native/FileNameIndex.swift \
  store/plugins/file-search/native/FileSearchAccess.swift store/plugins/file-search/native/FileSpotlightFallback.swift  \
  store/plugins/file-search/native/FileSearchPreview.swift store/plugins/file-search/native/FileSearchQuickLook.swift \
  store/plugins/file-search/native/FileSearchService.swift  \
  store/plugins/file-search/tests/FileAccessTests.swift store/plugins/file-search/tests/NativeTests.swift "$files_test_dir/index.o" -o "$files_test_dir/native-tests"
"$files_test_dir/native-tests"
bash store/plugins/file-search/tests/index.sh
bash store/plugins/file-search/tests/watcher.sh

# Read-only home-folder and million-name benchmarks: bash store/plugins/file-search/tests/index.sh --benchmark

bash store/plugins/file-search/tests/migration.sh
python3 store/plugins/file-search/tests/protocol.py
