#!/bin/bash
set -euo pipefail
plugin_dir="$(cd "$(dirname "$0")" && pwd)"
scratch_dir="$(mktemp -d /tmp/nook-rust-plugin.XXXXXX)"
trap 'rm -rf "$scratch_dir"' EXIT
cd "$plugin_dir"
mkdir -p bin
for architecture in aarch64 x86_64; do
  MACOSX_DEPLOYMENT_TARGET=14.2 cargo build --release --target "$architecture-apple-darwin" --target-dir "$scratch_dir"
done
xcrun lipo -create "$scratch_dir/aarch64-apple-darwin/release/helper" "$scratch_dir/x86_64-apple-darwin/release/helper" -output bin/helper
codesign --force --sign - bin/helper
