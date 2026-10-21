#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
files_test_dir=$(mktemp -d /tmp/nook-file-tab.XXXXXX)
xcrun clang -std=c11 -O3 -Wall -Wextra -Werror -c Nook/Services/Files/FileNameIndex.c -o "$files_test_dir/index.o"
xcrun swiftc -g -swift-version 5 -warnings-as-errors \
  -import-objc-header Nook/Services/Files/NookFiles-Bridging.h \
  Nook/Services/FileSearchModels.swift Nook/Services/Files/FileIndexQuery.swift \
  Nook/Services/Files/FileSearchTab.swift Nook/Views/KeyboardFocus.swift \
  tests/files/TabStateStubs.swift tests/files/TabStateTests.swift \
  "$files_test_dir/index.o" -o "$files_test_dir/tab-tests"
"$files_test_dir/tab-tests"
