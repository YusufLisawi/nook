#!/bin/bash
set -euo pipefail
plugin_dir="$(cd "$(dirname "$0")" && pwd)"
scratch_dir="$(mktemp -d /tmp/nook-file-search-build.XXXXXX)"
trap 'rm -rf "$scratch_dir"' EXIT # Compiler output in our own /tmp directory only.
mkdir -p "$plugin_dir/bin"
for architecture in arm64 x86_64; do
  xcrun clang -O3 -Wall -Wextra -Werror -target "$architecture-apple-macos14.2" -c "$plugin_dir/native/FileNameIndex.c" -o "$scratch_dir/$architecture.o"
  xcrun swiftc -swift-version 5 -warnings-as-errors -O -parse-as-library -target "$architecture-apple-macos14.2" -import-objc-header "$plugin_dir/native/NookFiles-Bridging.h" "$plugin_dir"/native/*.swift "$scratch_dir/$architecture.o" -o "$scratch_dir/$architecture"
done
xcrun lipo -create "$scratch_dir/arm64" "$scratch_dir/x86_64" -output "$plugin_dir/bin/helper"
codesign --force --sign - --identifier com.yusuf.nook.plugin.file-search "$plugin_dir/bin/helper"
