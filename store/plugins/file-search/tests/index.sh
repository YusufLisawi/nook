#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../../.."
files_test_dir=$(mktemp -d /tmp/nook-file-index.XXXXXX)
xcrun clang -std=c11 -O3 -Wall -Wextra -Werror -c store/plugins/file-search/native/FileNameIndex.c -o "$files_test_dir/index.o"
xcrun swiftc -O -swift-version 5 -warnings-as-errors \
  -import-objc-header store/plugins/file-search/native/NookFiles-Bridging.h \
  store/plugins/file-search/tests/RuntimeStubs.swift store/plugins/file-search/native/FileSearchModels.swift store/plugins/file-search/native/FileIndexQuery.swift \
  store/plugins/file-search/native/FileSearchAccessPolicy.swift store/plugins/file-search/tests/IndexTests.swift "$files_test_dir/index.o" -o "$files_test_dir/index-tests"
"$files_test_dir/index-tests" "$@"
